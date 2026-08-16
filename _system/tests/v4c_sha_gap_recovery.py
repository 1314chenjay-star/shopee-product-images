#!/usr/bin/env python3
"""V4-C4.1 Legacy SHA Gap Recovery + HOLD-Only Delta Replan.

This stage is intentionally narrow:
- V4-C1..V4-C4.0 are frozen and never rerun.
- The frozen V4-C4.0 191 READY product plans and 660-slot queue are never rewritten.
- Only the 859 source rows without durable SHA256 are recovery targets.
- Zero-source-download recovery is attempted first from frozen repository records and
  historical B001-B018 workflow artifacts.
- Only unresolved target rows may be fetched from their exact source URL.
- SHA recovery alone never creates factual evidence or generation eligibility.
- Only the 184 frozen HOLD products are delta replanned.
"""
import argparse
import csv
import hashlib
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import v4c_generation_plan as planner

SCHEMA = 'v4c4.1.sha-gap-recovery.1'
BASE_HEAD = 'd0eef69eb1b8986e84506608f4eb42905aa6da92'
STABLE_HEAD = '5d49f061e140813b3d229520e9e530f86b27b640'
EXPECTED_PRODUCTS = 375
EXPECTED_SOURCES = 2394
EXPECTED_EXISTING_SHA = 1535
EXPECTED_SHA_GAP = 859
EXPECTED_READY = 191
EXPECTED_HOLD = 184
EXPECTED_FROZEN_QUEUE = 660
CANARY_SIZE = 75
RECOVERED = {'RECOVERED_EXISTING_SHA', 'SHA_RECOVERED'}
TERMINAL = RECOVERED | {'SOURCE_UNAVAILABLE', 'SOURCE_CHANGED_OR_AMBIGUOUS'}
SHA_RE = re.compile(r'^[0-9a-f]{64}$')


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def read_jsonl(path):
    rows = []
    p = Path(path)
    if not p.exists():
        raise RuntimeError(f'Missing required JSONL: {p}')
    with p.open(encoding='utf-8-sig') as f:
        for line_no, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except Exception as exc:
                raise RuntimeError(f'Invalid JSONL {p}:{line_no}: {exc}')
    return rows


def write_json(path, obj):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding='utf-8')


def write_jsonl(path, rows):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open('w', encoding='utf-8', newline='\n') as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n')


def sha_file(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def valid_sha(value):
    return isinstance(value, str) and SHA_RE.fullmatch(value.strip().lower()) is not None


def first_value(obj, keys):
    if not isinstance(obj, dict):
        return None
    for k in keys:
        v = obj.get(k)
        if v not in (None, ''):
            return v
    for nested in ('legacy', 'source', 'provenance', 'download', 'manifest', 'record'):
        v = obj.get(nested)
        if isinstance(v, dict):
            found = first_value(v, keys)
            if found not in (None, ''):
                return found
    return None


def direct_sha(obj):
    if not isinstance(obj, dict):
        return None
    for k in ('sha256', 'source_sha256', 'content_sha256', 'image_sha256', 'file_sha256'):
        v = obj.get(k)
        if valid_sha(v):
            return v.strip().lower()
    return None


def normalize_batch(v):
    if v in (None, ''):
        return None
    s = str(v).strip().upper()
    m = re.search(r'B\s*0*(\d{1,3})', s)
    if m:
        return f'B{int(m.group(1)):03d}'
    if s.isdigit():
        return f'B{int(s):03d}'
    return s


def int_or_none(v):
    try:
        return int(v)
    except Exception:
        return None


def api_flags(source_download=False, artifact_download=False):
    return {
        'source_download_called': bool(source_download),
        'artifact_download_called': bool(artifact_download),
        'ocr_executed': False,
        'semantic_inference_executed': False,
        'preservation_reexecuted': False,
        'factual_gate_reexecuted': False,
        'v4c2_retested': False,
        'v4c3_retested': False,
        'v4c3_1_retested': False,
        'v4c3_2_retested': False,
        'v4c4_0_retested': False,
        'image_generation_called': False,
        'tiny_snow_api_called': False,
        'vision_api_called': False,
        'paid_api_called': False,
        'generation_executed': False,
    }


def prepare(args):
    canonical = read_jsonl(args.canonical)
    plans = read_jsonl(args.product_plan)
    queue = read_jsonl(args.queue)
    lock = read_json(args.lock)
    inventory = read_jsonl(args.inventory)
    progress = read_jsonl(args.progress)

    if not lock.get('passed') or not lock.get('v4c4_0_sealed'):
        raise RuntimeError('V4-C4.0 lock is not sealed PASS')
    required_lock = {
        'authoritative_product_count': EXPECTED_PRODUCTS,
        'authoritative_source_image_count': EXPECTED_SOURCES,
        'ready_5_slot_products': EXPECTED_READY,
        'hold_product_count': EXPECTED_HOLD,
        'generation_plan_queue_image_count': EXPECTED_FROZEN_QUEUE,
    }
    for key, expected in required_lock.items():
        if int(lock.get(key, -1)) != expected:
            raise RuntimeError(f'Frozen V4-C4.0 mismatch {key}: expected {expected}, got {lock.get(key)}')
    if len(canonical) != EXPECTED_SOURCES or len(inventory) != EXPECTED_SOURCES:
        raise RuntimeError('Authoritative source inventory changed')
    seqs = [int(r['sequence']) for r in canonical]
    if sorted(seqs) != list(range(1, EXPECTED_SOURCES + 1)) or len(set(seqs)) != EXPECTED_SOURCES:
        raise RuntimeError('Canonical sequence reconciliation failed')
    if len({str(r.get('product_id') or '') for r in canonical}) != EXPECTED_PRODUCTS:
        raise RuntimeError('Canonical product reconciliation failed')
    if len(plans) != EXPECTED_PRODUCTS:
        raise RuntimeError('Frozen product plan count changed')
    ready = [p for p in plans if p.get('product_status') == 'READY_5_SLOT']
    holds = [p for p in plans if p.get('product_status') != 'READY_5_SLOT']
    if len(ready) != EXPECTED_READY or len(holds) != EXPECTED_HOLD:
        raise RuntimeError('Frozen READY/HOLD product counts changed')
    if len(queue) != EXPECTED_FROZEN_QUEUE:
        raise RuntimeError('Frozen generation queue count changed')

    existing = [r for r in canonical if valid_sha(r.get('source_sha256'))]
    missing = [r for r in canonical if not valid_sha(r.get('source_sha256'))]
    if len(existing) != EXPECTED_EXISTING_SHA or len(missing) != EXPECTED_SHA_GAP:
        raise RuntimeError(f'BLOCK_RECONCILIATION: existing={len(existing)} missing={len(missing)}')
    if len(existing) + len(missing) != EXPECTED_SOURCES:
        raise RuntimeError('1535 + 859 != 2394 reconciliation failed')

    progress_by_seq = {int(r['sequence']): r for r in progress if int_or_none(r.get('sequence')) is not None}
    inv_by_seq = {int(r['sequence']): r for r in inventory}
    target = []
    for r in sorted(missing, key=lambda x: int(x['sequence'])):
        seq = int(r['sequence'])
        inv = inv_by_seq.get(seq)
        if not inv:
            raise RuntimeError(f'Missing inventory row for target sequence {seq}')
        if str(inv.get('source_id') or '') != str(r.get('source_id') or '') or str(inv.get('product_id') or '') != str(r.get('product_id') or ''):
            raise RuntimeError(f'Inventory identity mismatch for target sequence {seq}')
        if str(inv.get('url') or '') != str(r.get('source_url') or ''):
            raise RuntimeError(f'Inventory URL mismatch for target sequence {seq}')
        pr = progress_by_seq.get(seq, {})
        legacy_batch = normalize_batch(first_value(pr, ('legacy_batch', 'legacy_batch_id', 'batch_id')))
        legacy_sequence = int_or_none(first_value(pr, ('legacy_sequence', 'legacy_seq', 'historical_sequence', 'batch_sequence')))
        target.append({
            'schema_version': SCHEMA,
            'sequence': seq,
            'source_id': str(r.get('source_id') or ''),
            'product_id': str(r.get('product_id') or ''),
            'source_url': str(r.get('source_url') or ''),
            'image_index': r.get('image_index'),
            'image_type': r.get('image_type'),
            'v4c4_0_state': r.get('canonical_state'),
            'v4c4_0_underlying_state': r.get('underlying_state'),
            'v4c4_0_state_reason': r.get('state_reason'),
            'legacy_batch': legacy_batch,
            'legacy_sequence': legacy_sequence,
            'durable_sha_missing': True,
        })

    ready_ids = sorted(str(p['product_id']) for p in ready)
    hold_ids = sorted(str(p['product_id']) for p in holds)
    canary = target[:CANARY_SIZE]
    write_jsonl(args.target, target)
    write_jsonl(args.canary_target, canary)
    summary = {
        'schema_version': 'v4c4.1.prepare.1',
        'passed': True,
        'authoritative_products': EXPECTED_PRODUCTS,
        'authoritative_sources': EXPECTED_SOURCES,
        'existing_durable_sha': len(existing),
        'sha_gap_target': len(target),
        'reconciliation_1535_plus_859': len(existing) + len(target),
        'original_ready_products': len(ready_ids),
        'original_hold_products': len(hold_ids),
        'frozen_original_queue': len(queue),
        'ready_product_ids_sha256': hashlib.sha256(('\n'.join(ready_ids)).encode()).hexdigest(),
        'hold_product_ids_sha256': hashlib.sha256(('\n'.join(hold_ids)).encode()).hexdigest(),
        'frozen_product_plan_file_sha256': sha_file(args.product_plan),
        'frozen_generation_queue_file_sha256': sha_file(args.queue),
        'canary_size': len(canary),
        'api_flags': api_flags(),
    }
    write_json(args.prepare_summary, summary)
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))


def scan_artifact_refs():
    refs = {}
    for p in sorted(Path('_system/reports').glob('v4c0_b*_semantic_review*.json')):
        try:
            obj = read_json(p)
        except Exception:
            continue
        batch = normalize_batch(obj.get('batch_id') or first_value(obj, ('batch_id',)))
        scope = obj.get('review_scope') if isinstance(obj.get('review_scope'), dict) else {}
        aid = int_or_none(scope.get('source_artifact_id'))
        run_id = int_or_none(scope.get('source_artifact_run_id'))
        if batch and aid:
            refs[(batch, aid)] = {'batch_id': batch, 'artifact_id': aid, 'run_id': run_id, 'report_path': str(p)}
    return [refs[k] for k in sorted(refs)]


def artifact_cache(args):
    cache = Path(args.cache_dir)
    cache.mkdir(parents=True, exist_ok=True)
    token = os.environ.get('GITHUB_TOKEN', '').strip()
    if not token:
        raise RuntimeError('GITHUB_TOKEN missing for historical workflow artifact read')
    refs = scan_artifact_refs()
    downloaded = 0
    failed = []
    extracted_files = 0
    for ref in refs:
        batch = ref['batch_id']
        aid = ref['artifact_id']
        dest = cache / f'{batch}_artifact_{aid}'
        marker = dest / '.done'
        if marker.exists():
            downloaded += 1
            continue
        url = f'https://api.github.com/repos/{args.repo}/actions/artifacts/{aid}/zip'
        req = urllib.request.Request(url, headers={
            'Authorization': f'Bearer {token}',
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'TinySnow-V4-C4.1',
        })
        try:
            with urllib.request.urlopen(req, timeout=90) as resp:
                data = resp.read()
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                dest.mkdir(parents=True, exist_ok=True)
                for info in zf.infolist():
                    if info.is_dir() or info.file_size > 25 * 1024 * 1024:
                        continue
                    low = info.filename.lower()
                    if not low.endswith(('.json', '.jsonl', '.csv', '.txt')):
                        continue
                    # Keep only metadata-like text; no image bytes are materialized.
                    out = dest / Path(info.filename).name
                    if out.exists():
                        out = dest / (str(abs(hash(info.filename))) + '_' + Path(info.filename).name)
                    out.write_bytes(zf.read(info))
                    extracted_files += 1
            marker.write_text(json.dumps(ref), encoding='utf-8')
            downloaded += 1
        except Exception as exc:
            failed.append({'batch_id': batch, 'artifact_id': aid, 'run_id': ref.get('run_id'), 'error': str(exc)[:500]})
    summary = {
        'schema_version': 'v4c4.1.artifact-cache.1',
        'historical_artifact_refs': len(refs),
        'historical_artifact_downloaded': downloaded,
        'historical_artifact_failed': len(failed),
        'extracted_metadata_files': extracted_files,
        'failures': failed,
        'source_download_called': False,
        'artifact_download_called': downloaded > 0,
    }
    write_json(args.summary, summary)
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))


def parse_text_file(path):
    p = Path(path)
    low = p.suffix.lower()
    try:
        if low == '.json':
            return read_json(p)
        if low == '.jsonl':
            return read_jsonl(p)
        if low == '.csv':
            with p.open(encoding='utf-8-sig', newline='') as f:
                return list(csv.DictReader(f))
    except Exception:
        return None
    return None


def inherited_fields(obj, inherited, path):
    ctx = dict(inherited)
    if isinstance(obj, dict):
        pid = first_value(obj, ('product_id', 'item_id', 'shopee_product_id'))
        sid = first_value(obj, ('source_id',))
        batch = first_value(obj, ('batch_id', 'legacy_batch', 'legacy_batch_id'))
        seq = first_value(obj, ('sequence', 'source_sequence', 'legacy_sequence', 'historical_sequence'))
        url = first_value(obj, ('source_url', 'url', 'image_url', 'original_url'))
        if pid not in (None, ''): ctx['product_id'] = str(pid)
        if sid not in (None, ''): ctx['source_id'] = str(sid)
        if batch not in (None, ''): ctx['batch_id'] = normalize_batch(batch)
        if seq not in (None, ''): ctx['sequence'] = int_or_none(seq)
        if url not in (None, ''): ctx['source_url'] = str(url)
    if not ctx.get('batch_id'):
        m = re.search(r'(?i)(?:^|[^A-Z0-9])B(\d{1,3})(?:[^0-9]|$)', str(path))
        if m:
            ctx['batch_id'] = f'B{int(m.group(1)):03d}'
    return ctx


def walk_candidates(obj, path, inherited=None):
    if inherited is None:
        inherited = {}
    ctx = inherited_fields(obj, inherited, path)
    if isinstance(obj, dict):
        sh = direct_sha(obj)
        if sh:
            url = first_value(obj, ('source_url', 'url', 'image_url', 'original_url')) or ctx.get('source_url')
            pid = first_value(obj, ('product_id', 'item_id', 'shopee_product_id')) or ctx.get('product_id')
            sid = first_value(obj, ('source_id',)) or ctx.get('source_id')
            batch = normalize_batch(first_value(obj, ('batch_id', 'legacy_batch', 'legacy_batch_id')) or ctx.get('batch_id'))
            seq = int_or_none(first_value(obj, ('sequence', 'source_sequence', 'legacy_sequence', 'historical_sequence')))
            if seq is None:
                seq = ctx.get('sequence')
            if url and pid:
                yield {
                    'sha256': sh,
                    'source_url': str(url),
                    'product_id': str(pid),
                    'source_id': str(sid) if sid not in (None, '') else None,
                    'batch_id': batch,
                    'sequence': seq,
                    'provenance_path': str(path),
                }
        for value in obj.values():
            if isinstance(value, (dict, list)):
                yield from walk_candidates(value, path, ctx)
    elif isinstance(obj, list):
        for value in obj:
            if isinstance(value, (dict, list)):
                yield from walk_candidates(value, path, ctx)


def candidate_roots(cache_dir):
    roots = [
        Path('_system/v4c/progress'),
        Path('_system/v4c/results'),
        Path('_system/v4c/preservation'),
        Path('_system/v4c/evidence_hydration'),
        Path('_system/v4c/closeout'),
        Path('_system/v4c/factual_gate'),
        Path('_system/reports'),
        Path(cache_dir),
    ]
    files = []
    for root in roots:
        if not root.exists():
            continue
        for p in root.rglob('*'):
            if p.is_file() and p.suffix.lower() in ('.json', '.jsonl', '.csv'):
                if 'sha_gap_recovery' in str(p).replace('\\', '/'):
                    continue
                files.append(p)
    return sorted(set(files))


def build_candidate_index(cache_dir, index_path):
    idx_path = Path(index_path)
    if idx_path.exists():
        return read_jsonl(idx_path)
    candidates = []
    for p in candidate_roots(cache_dir):
        obj = parse_text_file(p)
        if obj is None:
            continue
        candidates.extend(walk_candidates(obj, p))
    # Deduplicate exact candidate evidence rows.
    unique = {}
    for c in candidates:
        key = (c['sha256'], c['source_url'], c['product_id'], c.get('source_id'), c.get('batch_id'), c.get('sequence'), c['provenance_path'])
        unique[key] = c
    rows = list(unique.values())
    write_jsonl(idx_path, rows)
    return rows


def load_checkpoint(path):
    p = Path(path)
    if not p.exists():
        return {}
    return {int(r['sequence']): r for r in read_jsonl(p)}


def save_checkpoint(path, cp):
    write_jsonl(path, [cp[s] for s in sorted(cp)])


def identity_match(target, cand):
    if str(cand.get('source_url') or '') != str(target.get('source_url') or ''):
        return False, 'url'
    if str(cand.get('product_id') or '') != str(target.get('product_id') or ''):
        return False, 'product'
    sid = cand.get('source_id')
    if sid and str(sid) == str(target.get('source_id')):
        return True, 'source_id+url+product'
    lb = normalize_batch(target.get('legacy_batch'))
    ls = int_or_none(target.get('legacy_sequence'))
    cb = normalize_batch(cand.get('batch_id'))
    cs = int_or_none(cand.get('sequence'))
    if lb and ls is not None and cb == lb and cs == ls:
        return True, 'historical_batch_sequence+url+product'
    if cs == int(target['sequence']) and 'artifact_' not in str(cand.get('provenance_path') or ''):
        return True, 'current_sequence+url+product'
    return False, 'insufficient_manifest_identity'


def scope_targets(target_path, canary_target_path, scope):
    return read_jsonl(canary_target_path if scope == 'canary' else target_path)


def recover_existing(args):
    targets = scope_targets(args.target, args.canary_target, args.scope)
    cp = load_checkpoint(args.checkpoint)
    candidates = build_candidate_index(args.cache_dir, args.candidate_index)
    by_url_product = defaultdict(list)
    for c in candidates:
        by_url_product[(str(c.get('source_url') or ''), str(c.get('product_id') or ''))].append(c)
    recovered = ambiguous = 0
    for t in targets:
        seq = int(t['sequence'])
        if seq in cp:
            continue
        matched = []
        for c in by_url_product.get((t['source_url'], t['product_id']), []):
            ok, method = identity_match(t, c)
            if ok:
                cc = dict(c)
                cc['identity_method'] = method
                matched.append(cc)
        shas = sorted({c['sha256'] for c in matched if valid_sha(c.get('sha256'))})
        if len(shas) == 1:
            cp[seq] = {
                'schema_version': SCHEMA,
                'sequence': seq,
                'source_id': t['source_id'],
                'product_id': t['product_id'],
                'source_url': t['source_url'],
                'status': 'RECOVERED_EXISTING_SHA',
                'sha256': shas[0],
                'content_length': None,
                'fetch_status': 'NOT_FETCHED_EXISTING_DURABLE_RECORD',
                'recovery_method': 'ZERO_SOURCE_DOWNLOAD_FROZEN_RECORD',
                'identity_crosscheck': True,
                'matched_evidence': matched[:20],
            }
            recovered += 1
        elif len(shas) > 1:
            cp[seq] = {
                'schema_version': SCHEMA,
                'sequence': seq,
                'source_id': t['source_id'],
                'product_id': t['product_id'],
                'source_url': t['source_url'],
                'status': 'SOURCE_CHANGED_OR_AMBIGUOUS',
                'sha256': None,
                'content_length': None,
                'fetch_status': 'NOT_FETCHED_CONFLICTING_FROZEN_SHA_RECORDS',
                'recovery_method': 'ZERO_SOURCE_DOWNLOAD_AMBIGUOUS',
                'identity_crosscheck': True,
                'candidate_sha256': shas,
                'matched_evidence': matched[:20],
            }
            ambiguous += 1
    save_checkpoint(args.checkpoint, cp)
    summary = {
        'schema_version': 'v4c4.1.existing-recovery.1',
        'scope': args.scope,
        'scope_target_count': len(targets),
        'checkpoint_terminal_count': len(cp),
        'new_recovered_existing_sha': recovered,
        'new_ambiguous': ambiguous,
        'candidate_index_count': len(candidates),
        'source_download_called': False,
    }
    write_json(args.summary, summary)
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))


def image_magic_ok(data):
    if data.startswith(b'\xff\xd8\xff'):
        return True
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        return True
    if data.startswith(b'GIF87a') or data.startswith(b'GIF89a'):
        return True
    if len(data) >= 12 and data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        return True
    return False


def fetch_one(t):
    url = str(t['source_url'])
    last_error = None
    for attempt in range(2):
        try:
            req = urllib.request.Request(url, headers={
                'User-Agent': 'Mozilla/5.0 TinySnow-V4-C4.1-SHA-Recovery',
                'Accept': 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8',
            })
            with urllib.request.urlopen(req, timeout=45) as resp:
                data = resp.read()
                http_status = getattr(resp, 'status', 200)
                content_type = str(resp.headers.get('Content-Type') or '')
            if not data or not image_magic_ok(data):
                return {
                    'status': 'SOURCE_UNAVAILABLE', 'sha256': None, 'content_length': len(data),
                    'fetch_status': f'NON_IMAGE_RESPONSE_HTTP_{http_status}', 'http_status': http_status,
                    'content_type': content_type, 'error': 'response body is not recognized image bytes'
                }
            return {
                'status': 'SHA_RECOVERED', 'sha256': hashlib.sha256(data).hexdigest(), 'content_length': len(data),
                'fetch_status': f'HTTP_{http_status}_IMAGE_BYTES', 'http_status': http_status,
                'content_type': content_type, 'error': None
            }
        except Exception as exc:
            last_error = str(exc)
            if attempt == 0:
                time.sleep(0.5)
    return {
        'status': 'SOURCE_UNAVAILABLE', 'sha256': None, 'content_length': None,
        'fetch_status': 'FETCH_FAILED_AFTER_2_ATTEMPTS', 'http_status': None,
        'content_type': None, 'error': (last_error or 'unknown fetch failure')[:500]
    }


def fetch_targets(args):
    targets = scope_targets(args.target, args.canary_target, args.scope)
    cp = load_checkpoint(args.checkpoint)
    before = len(cp)
    unresolved = [t for t in targets if int(t['sequence']) not in cp]
    if args.max_new is not None:
        unresolved = unresolved[:args.max_new]
    existing_sha_sequences = {int(r['sequence']) for r in read_jsonl(args.canonical) if valid_sha(r.get('source_sha256'))}
    bad = [int(t['sequence']) for t in unresolved if int(t['sequence']) in existing_sha_sequences]
    if bad:
        raise RuntimeError(f'Existing durable SHA source would be re-fetched: {bad[:20]}')
    results = {}
    if unresolved:
        workers = max(1, min(int(args.workers), 8))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {pool.submit(fetch_one, t): t for t in unresolved}
            for fut in as_completed(futures):
                t = futures[fut]
                fr = fut.result()
                results[int(t['sequence'])] = {
                    'schema_version': SCHEMA,
                    'sequence': int(t['sequence']),
                    'source_id': t['source_id'],
                    'product_id': t['product_id'],
                    'source_url': t['source_url'],
                    'status': fr['status'],
                    'sha256': fr['sha256'],
                    'content_length': fr['content_length'],
                    'fetch_status': fr['fetch_status'],
                    'http_status': fr.get('http_status'),
                    'content_type': fr.get('content_type'),
                    'error': fr.get('error'),
                    'recovery_method': 'TARGETED_SOURCE_FETCH',
                    'identity_crosscheck': True,
                }
    cp.update(results)
    save_checkpoint(args.checkpoint, cp)
    success = sum(1 for r in results.values() if r['status'] == 'SHA_RECOVERED')
    failed = sum(1 for r in results.values() if r['status'] == 'SOURCE_UNAVAILABLE')
    summary = {
        'schema_version': 'v4c4.1.targeted-fetch.1',
        'scope': args.scope,
        'scope_target_count': len(targets),
        'checkpoint_terminal_before': before,
        'already_terminal_in_scope_before': sum(1 for t in targets if int(t['sequence']) in load_checkpoint(args.checkpoint) and int(t['sequence']) not in results),
        'new_targeted_fetch_attempts': len(results),
        'new_targeted_fetch_success': success,
        'new_targeted_fetch_failed': failed,
        'checkpoint_terminal_after': len(cp),
        'existing_sha_source_refetch': 0,
        'generation_executed': False,
    }
    write_json(args.summary, summary)
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))


def canary_validate(args):
    canary = read_jsonl(args.canary_target)
    cp = load_checkpoint(args.checkpoint)
    seed = read_json(args.seed_summary)
    resume = read_json(args.resume_summary)
    prepare_summary = read_json(args.prepare_summary)
    product_plan_hash = sha_file(args.product_plan)
    queue_hash = sha_file(args.queue)
    terminal = [cp.get(int(t['sequence'])) for t in canary]
    missing_terminal = [t['sequence'] for t, r in zip(canary, terminal) if not r or r.get('status') not in TERMINAL]
    bad_sha = [r['sequence'] for r in terminal if r and r.get('status') in RECOVERED and not valid_sha(r.get('sha256'))]
    mapping_bad = [r['sequence'] for r in terminal if r and not r.get('identity_crosscheck')]
    if missing_terminal or bad_sha or mapping_bad:
        raise RuntimeError(f'Canary terminal/sha/mapping validation failed missing={missing_terminal[:10]} bad_sha={bad_sha[:10]} mapping={mapping_bad[:10]}')
    if int(seed.get('existing_sha_source_refetch', -1)) != 0 or int(resume.get('existing_sha_source_refetch', -1)) != 0:
        raise RuntimeError('Canary existing SHA source re-fetch was nonzero')
    # checkpoint/resume is demonstrated by the second fetch pass observing terminal rows from
    # zero-download recovery and/or the first fetch seed.
    if int(resume.get('checkpoint_terminal_before', 0)) <= 0:
        raise RuntimeError('Canary checkpoint/resume was not exercised')
    if product_plan_hash != prepare_summary['frozen_product_plan_file_sha256']:
        raise RuntimeError('Original 375 product plan mutated during Canary')
    if queue_hash != prepare_summary['frozen_generation_queue_file_sha256']:
        raise RuntimeError('Original 660 queue mutated during Canary')
    failed = [r for r in terminal if r and r.get('status') == 'SOURCE_UNAVAILABLE']
    if any(r.get('sha256') for r in failed):
        raise RuntimeError('Fetch failure incorrectly received SHA')
    val = {
        'schema_version': 'v4c4.1.canary-validation.1',
        'passed': True,
        'canary_target_count': len(canary),
        'existing_sha_source_refetch': 0,
        'recovery_mapping_cross_source_error': 0,
        'sha_format_errors': 0,
        'sequence_source_reconciliation': True,
        'fetch_failure_remains_hold_capable': True,
        'checkpoint_resume': True,
        'original_ready_plan_mutations': 0,
        'original_660_queue_mutations': 0,
        'generation_executed': False,
        'api_flags': api_flags(source_download=(int(seed.get('new_targeted_fetch_attempts', 0)) + int(resume.get('new_targeted_fetch_attempts', 0)) > 0)),
    }
    write_json(args.validation, val)
    print(json.dumps(val, ensure_ascii=False, sort_keys=True))


def finalize_recovery(args):
    target = read_jsonl(args.target)
    cp = load_checkpoint(args.checkpoint)
    if len(cp) != EXPECTED_SHA_GAP:
        missing = [int(t['sequence']) for t in target if int(t['sequence']) not in cp]
        raise RuntimeError(f'Full SHA-gap recovery did not terminalize 859 targets; checkpoint={len(cp)} missing={missing[:20]}')
    results = []
    for t in target:
        r = cp[int(t['sequence'])]
        if r.get('status') not in TERMINAL:
            raise RuntimeError(f'Invalid terminal status sequence {t["sequence"]}: {r.get("status")}')
        if r.get('status') in RECOVERED and not valid_sha(r.get('sha256')):
            raise RuntimeError(f'Invalid recovered SHA sequence {t["sequence"]}')
        if str(r.get('source_id')) != str(t.get('source_id')) or str(r.get('product_id')) != str(t.get('product_id')) or str(r.get('source_url')) != str(t.get('source_url')):
            raise RuntimeError(f'Recovery identity drift sequence {t["sequence"]}')
        results.append(r)
    failed = [r for r in results if r['status'] in {'SOURCE_UNAVAILABLE', 'SOURCE_CHANGED_OR_AMBIGUOUS'}]
    write_jsonl(args.results, results)
    write_jsonl(args.failed, failed)
    counts = Counter(r['status'] for r in results)
    summary = {
        'schema_version': 'v4c4.1.recovery-final.1',
        'sha_gap_target': len(results),
        'zero_download_sha_recovered': counts['RECOVERED_EXISTING_SHA'],
        'targeted_fetch_planned': counts['SHA_RECOVERED'] + counts['SOURCE_UNAVAILABLE'],
        'targeted_fetch_success': counts['SHA_RECOVERED'],
        'fetch_failed': counts['SOURCE_UNAVAILABLE'],
        'sha_recovered_total': counts['RECOVERED_EXISTING_SHA'] + counts['SHA_RECOVERED'],
        'sha_still_missing': counts['SOURCE_UNAVAILABLE'] + counts['SOURCE_CHANGED_OR_AMBIGUOUS'],
        'source_changed_or_ambiguous': counts['SOURCE_CHANGED_OR_AMBIGUOUS'],
    }
    write_json(args.summary, summary)
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))


def queue_row(pid, slot):
    return {
        'schema_version': 'v4c4.1.delta-generation-queue.1',
        'product_id': pid,
        'slot_index': slot['slot_index'],
        'slot_role': slot['slot_role'],
        'action': slot['action'],
        'source_sequence': slot['source_sequence'],
        'source_id': slot['source_id'],
        'source_sha256': slot['source_sha256'],
        'safe_fact_ids': slot.get('safe_fact_ids') or [],
        'safe_text': slot.get('safe_text') or [],
        'excluded_unknown_ids': slot.get('excluded_unknown_ids') or [],
        'excluded_conflict_ids': slot.get('excluded_conflict_ids') or [],
        'excluded_forbidden_ids': slot.get('excluded_forbidden_ids') or [],
        'product_conflict_quarantine': slot.get('product_conflict_quarantine') or [],
        'variant_scope': slot.get('variant_scope') or [],
        'parent_image': slot.get('parent_image'),
        'planning_only': True,
        'generation_executed': False,
        'delta_stage': 'V4-C4.1',
    }


def delta_replan(args):
    canonical = read_jsonl(args.canonical)
    frozen_plans = read_jsonl(args.product_plan)
    frozen_queue = read_jsonl(args.queue)
    recovery = read_jsonl(args.recovery_results)
    rec_by_seq = {int(r['sequence']): r for r in recovery}
    prep = read_json(args.prepare_summary)
    rec_summary = read_json(args.recovery_summary)
    artifact_summary = read_json(args.artifact_summary)

    if sha_file(args.product_plan) != prep['frozen_product_plan_file_sha256']:
        raise RuntimeError('Frozen product plan mutated before delta replan')
    if sha_file(args.queue) != prep['frozen_generation_queue_file_sha256']:
        raise RuntimeError('Frozen original generation queue mutated before delta replan')

    ready_old = [p for p in frozen_plans if p.get('product_status') == 'READY_5_SLOT']
    hold_old = [p for p in frozen_plans if p.get('product_status') != 'READY_5_SLOT']
    if len(ready_old) != EXPECTED_READY or len(hold_old) != EXPECTED_HOLD or len(frozen_queue) != EXPECTED_FROZEN_QUEUE:
        raise RuntimeError('Frozen V4-C4.0 counts changed before delta replan')
    hold_ids = {str(p['product_id']) for p in hold_old}
    ready_ids = {str(p['product_id']) for p in ready_old}

    updated = []
    upgraded_sequences = []
    recovered_sha_attached = 0
    for row in canonical:
        r = dict(row)
        seq = int(r['sequence'])
        rr = rec_by_seq.get(seq)
        if rr and rr.get('status') in RECOVERED:
            if valid_sha(r.get('source_sha256')):
                raise RuntimeError(f'Recovery target unexpectedly already had frozen SHA seq {seq}')
            r['source_sha256'] = rr['sha256']
            r['source_sha256_provenance'] = f'_system/v4c/generation_plan/sha_gap_recovery/sha_recovery_results.jsonl#{seq}'
            r['sha_recovery_status'] = rr['status']
            recovered_sha_attached += 1
            # SHA is traceability only. Upgrade state exclusively when frozen V4-C4.0
            # explicitly says the only missing requirement was source SHA for an already
            # PRESERVE/LOCKED_APPROVED item.
            reason = str(r.get('state_reason') or '')
            if reason == 'FROZEN_PRESERVE_BUT_SOURCE_SHA_NOT_DURABLY_PERSISTED':
                r['canonical_state'] = 'PRESERVE'
                r['underlying_state'] = 'PRESERVE'
                r['state_reason'] = 'FROZEN_PRESERVE_RESTORED_AFTER_SHA_TRACEABILITY_RECOVERY'
                r['do_not_regenerate'] = True
                upgraded_sequences.append(seq)
            elif reason == 'LOCKED_APPROVED_OUTPUT_BUT_SOURCE_SHA_NOT_DURABLY_PERSISTED':
                r['canonical_state'] = 'LOCKED_APPROVED'
                r['underlying_state'] = 'LOCKED_APPROVED'
                r['state_reason'] = 'LOCKED_APPROVED_RESTORED_AFTER_SHA_TRACEABILITY_RECOVERY'
                r['do_not_regenerate'] = True
                upgraded_sequences.append(seq)
            else:
                r['sha_recovery_note'] = 'SHA_RECOVERED_BUT_NO_NEW_FACTUAL_OR_PRESERVATION_AUTHORIZATION'
        elif rr and rr.get('status') not in RECOVERED:
            r['sha_recovery_status'] = rr.get('status')
        updated.append(r)

    by_product = defaultdict(list)
    for r in updated:
        by_product[str(r['product_id'])].append(r)
    delta_plans = []
    delta_queue = []
    newly_ready = []
    remaining_hold = []
    for old in sorted(hold_old, key=lambda p: str(p['product_id'])):
        pid = str(old['product_id'])
        new_plan = planner.plan_product(pid, by_product[pid])
        is_ready = new_plan.get('product_status') == 'READY_5_SLOT'
        reasons = sorted({str(r.get('state_reason') or '') for r in by_product[pid] if r.get('underlying_state') not in planner.SAFE_STATES})
        record = {
            'schema_version': 'v4c4.1.hold-delta-plan.1',
            'product_id': pid,
            'original_product_status': old.get('product_status'),
            'delta_status': 'READY_DELTA' if is_ready else 'HOLD',
            'new_product_status': new_plan.get('product_status'),
            'recovered_sha_source_count': sum(1 for r in by_product[pid] if r.get('sha_recovery_status') in RECOVERED),
            'state_upgraded_source_count': sum(1 for r in by_product[pid] if int(r['sequence']) in upgraded_sequences),
            'remaining_hold_reasons': [] if is_ready else reasons,
            'slots': new_plan.get('slots') or [],
            'selected_direct_sequences': new_plan.get('selected_direct_sequences') or [],
            'safe_not_selected_sequences': new_plan.get('safe_not_selected_sequences') or [],
            'derivative_slot_count': new_plan.get('derivative_slot_count', 0),
            'locked_product_guard': new_plan.get('locked_product_guard', False),
        }
        delta_plans.append(record)
        if is_ready:
            newly_ready.append(pid)
            for slot in new_plan.get('slots') or []:
                if slot.get('action') in {'PROCESS_LOCALIZE', 'SAFE_DERIVATIVE'}:
                    delta_queue.append(queue_row(pid, slot))
        else:
            remaining_hold.append(pid)

    # Safety validation is performed only over the 184 HOLD-product delta plans.
    planner_shape = []
    for d in delta_plans:
        planner_shape.append({
            'product_id': d['product_id'],
            'slots': d['slots'],
            'locked_product_guard': d['locked_product_guard'],
        })
    base_by_seq = {int(r['sequence']): r for r in updated}
    checks = planner.validate_plan_rows(planner_shape, base_by_seq)
    if any(checks[k] for k in ('unknown_leak', 'conflict_leak', 'forbidden_leak', 'block_factual_selected', 'locked_product_regeneration', 'duplicate_direct_slot_assignment')):
        raise RuntimeError(f'Delta planning safety failure: {checks}')

    orig_keys = {(str(q['product_id']), int(q['slot_index']), str(q['slot_role'])) for q in frozen_queue}
    delta_keys = {(str(q['product_id']), int(q['slot_index']), str(q['slot_role'])) for q in delta_queue}
    if len(orig_keys) != len(frozen_queue) or len(delta_keys) != len(delta_queue):
        raise RuntimeError('Duplicate queue entry within original or delta queue')
    overlap = orig_keys & delta_keys
    if overlap:
        raise RuntimeError(f'Delta queue overlaps frozen queue: {sorted(overlap)[:10]}')
    merged = list(frozen_queue) + delta_queue
    merged_keys = {(str(q['product_id']), int(q['slot_index']), str(q['slot_role'])) for q in merged}
    duplicate_queue_entries = len(merged) - len(merged_keys)
    if duplicate_queue_entries:
        raise RuntimeError('Merged queue duplicate entries nonzero')
    if ready_ids & set(newly_ready):
        raise RuntimeError('READY_DELTA unexpectedly contains an original READY product')
    if len(newly_ready) + len(remaining_hold) != EXPECTED_HOLD:
        raise RuntimeError('184 HOLD delta reconciliation failed')

    source_download_called = int(rec_summary.get('targeted_fetch_planned', 0)) > 0
    artifact_download_called = int(artifact_summary.get('historical_artifact_downloaded', 0)) > 0
    flags = api_flags(source_download_called, artifact_download_called)
    summary = {
        'schema_version': 'v4c4.1.merged-coverage-summary.1',
        'passed': True,
        'sha_gap_target': EXPECTED_SHA_GAP,
        'zero_download_sha_recovered': int(rec_summary.get('zero_download_sha_recovered', 0)),
        'targeted_fetch_planned': int(rec_summary.get('targeted_fetch_planned', 0)),
        'targeted_fetch_success': int(rec_summary.get('targeted_fetch_success', 0)),
        'fetch_failed': int(rec_summary.get('fetch_failed', 0)),
        'sha_recovered_total': int(rec_summary.get('sha_recovered_total', 0)),
        'sha_still_missing': int(rec_summary.get('sha_still_missing', 0)),
        'source_changed_or_ambiguous': int(rec_summary.get('source_changed_or_ambiguous', 0)),
        'original_ready_products': EXPECTED_READY,
        'newly_ready_products': len(newly_ready),
        'final_ready_products': EXPECTED_READY + len(newly_ready),
        'original_hold_products': EXPECTED_HOLD,
        'remaining_hold_products': len(remaining_hold),
        'frozen_original_queue': EXPECTED_FROZEN_QUEUE,
        'new_delta_queue': len(delta_queue),
        'final_merged_queue': len(merged),
        'duplicate_queue_entries': duplicate_queue_entries,
        'original_ready_plan_mutations': 0,
        'original_frozen_queue_mutations': 0,
        'locked_regeneration': checks['locked_product_regeneration'],
        'unknown_leak': checks['unknown_leak'],
        'conflict_leak': checks['conflict_leak'],
        'forbidden_leak': checks['forbidden_leak'],
        'block_factual_selected': checks['block_factual_selected'],
        'state_upgraded_source_count': len(upgraded_sequences),
        'recovered_sha_attached_count': recovered_sha_attached,
        'historical_artifact_downloaded': int(artifact_summary.get('historical_artifact_downloaded', 0)),
        'generation_executed': False,
        'api_flags': flags,
    }
    validation = {
        'schema_version': 'v4c4.1.validation.1',
        'passed': True,
        'sha_gap_exact_859': True,
        'existing_sha_exact_1535': True,
        'source_reconciliation_2394': True,
        'hold_only_replan_count': len(delta_plans),
        'original_ready_plan_mutations': 0,
        'original_frozen_queue_mutations': 0,
        'duplicate_queue_entries': duplicate_queue_entries,
        'unknown_leak': checks['unknown_leak'],
        'conflict_leak': checks['conflict_leak'],
        'forbidden_leak': checks['forbidden_leak'],
        'block_factual_selected': checks['block_factual_selected'],
        'locked_regeneration': checks['locked_product_regeneration'],
        'generation_executed': False,
        'api_flags': flags,
    }
    if args.workflow_run:
        summary['workflow_run'] = str(args.workflow_run)
    lock = dict(summary)
    lock.update({
        'schema_version': 'v4c4.1.sha-gap-recovery-lock.1',
        'base_head': BASE_HEAD,
        'stable_head': str(args.stable_head or STABLE_HEAD),
        'v4c4_1_sealed': True,
        'next_stage_requires_explicit_user_authorization': True,
    })
    write_jsonl(args.delta_plan, delta_plans)
    write_jsonl(args.delta_queue, delta_queue)
    write_jsonl(args.merged_queue, merged)
    write_json(args.merged_summary, summary)
    write_json(args.validation, validation)
    write_json(args.lock_out, lock)
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)

    p = sub.add_parser('prepare')
    for name in ('canonical', 'product-plan', 'queue', 'lock', 'inventory', 'progress', 'target', 'canary-target', 'prepare-summary'):
        p.add_argument('--' + name, required=True)
    p.set_defaults(fn=prepare)

    p = sub.add_parser('artifact-cache')
    p.add_argument('--repo', required=True)
    p.add_argument('--cache-dir', required=True)
    p.add_argument('--summary', required=True)
    p.set_defaults(fn=artifact_cache)

    p = sub.add_parser('recover-existing')
    p.add_argument('--target', required=True)
    p.add_argument('--canary-target', required=True)
    p.add_argument('--scope', choices=('canary', 'full'), required=True)
    p.add_argument('--cache-dir', required=True)
    p.add_argument('--candidate-index', required=True)
    p.add_argument('--checkpoint', required=True)
    p.add_argument('--summary', required=True)
    p.set_defaults(fn=recover_existing)

    p = sub.add_parser('fetch')
    p.add_argument('--target', required=True)
    p.add_argument('--canary-target', required=True)
    p.add_argument('--scope', choices=('canary', 'full'), required=True)
    p.add_argument('--canonical', required=True)
    p.add_argument('--checkpoint', required=True)
    p.add_argument('--summary', required=True)
    p.add_argument('--max-new', type=int)
    p.add_argument('--workers', type=int, default=6)
    p.set_defaults(fn=fetch_targets)

    p = sub.add_parser('canary-validate')
    for name in ('canary-target', 'checkpoint', 'seed-summary', 'resume-summary', 'prepare-summary', 'product-plan', 'queue', 'validation'):
        p.add_argument('--' + name, required=True)
    p.set_defaults(fn=canary_validate)

    p = sub.add_parser('finalize-recovery')
    for name in ('target', 'checkpoint', 'results', 'failed', 'summary'):
        p.add_argument('--' + name, required=True)
    p.set_defaults(fn=finalize_recovery)

    p = sub.add_parser('delta-replan')
    for name in ('canonical', 'product-plan', 'queue', 'recovery-results', 'recovery-summary', 'artifact-summary', 'prepare-summary',
                 'delta-plan', 'delta-queue', 'merged-queue', 'merged-summary', 'validation', 'lock-out'):
        p.add_argument('--' + name, required=True)
    p.add_argument('--workflow-run')
    p.add_argument('--stable-head')
    p.set_defaults(fn=delta_replan)

    args = ap.parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
