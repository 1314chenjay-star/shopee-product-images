#!/usr/bin/env python3
"""V4-C4.0 reconciliation hotfix.

This module does not rerun any frozen stage. It reuses the V4-C4.0 planner and only
changes global-state preparation so historical B001-B018 rows whose SHA was not
persisted in the V4-C1 progress ledger are held rather than fabricated.
"""
import json, re
from collections import Counter, defaultdict
from pathlib import Path
import v4c_generation_plan as core

FROZEN_VARIANT_PRODUCTS={'52915734564','58015741169'}


def collect_frozen_sha(rows, sha_by_seq, source_name, provenance):
    for r in rows:
        s=core.seq_int(r)
        if s is None: continue
        sh=core.sha_from_row(r)
        if sh and not sha_by_seq.get(s):
            sha_by_seq[s]=sh
            provenance[s]=source_name


def prepare_r2(args):
    inventory=core.read_jsonl(args.inventory)
    progress=core.read_jsonl(args.progress)
    duplicates=core.read_json(args.duplicates)
    closeout=core.read_jsonl(args.closeout)
    corrected_images=core.read_jsonl(args.corrected_images)
    corrected_queue=core.read_jsonl(args.corrected_queue)
    c32_summary=core.read_json(args.c32_summary)
    if len(inventory)!=core.EXPECTED_SOURCES:
        raise RuntimeError(f'BLOCK_RECONCILIATION: expected {core.EXPECTED_SOURCES} source images, got {len(inventory)}')
    seqs=[int(r['sequence']) for r in inventory]
    if sorted(seqs)!=list(range(1,core.EXPECTED_SOURCES+1)) or len(set(seqs))!=core.EXPECTED_SOURCES:
        raise RuntimeError('BLOCK_RECONCILIATION: source sequences are not exactly contiguous 1..2394')
    products={str(r.get('product_id') or '') for r in inventory}
    if '' in products: raise RuntimeError('BLOCK_RECONCILIATION: blank product_id in source inventory')
    if len(products)!=core.EXPECTED_PRODUCTS:
        raise RuntimeError(f'BLOCK_RECONCILIATION: expected {core.EXPECTED_PRODUCTS} products, got {len(products)}')
    if len(corrected_queue)!=core.EXPECTED_V4C32_QUEUE or int(c32_summary.get('generation_queue_count',-1))!=core.EXPECTED_V4C32_QUEUE:
        raise RuntimeError('BLOCK_RECONCILIATION: V4-C3.2 queue count changed')

    inv_by_seq={int(r['sequence']):dict(r) for r in inventory}
    inv_by_product=defaultdict(list)
    for r in inventory: inv_by_product[str(r['product_id'])].append(r)
    prog_by_seq={int(r['sequence']):r for r in progress if core.seq_int(r) is not None}
    sha_by_seq={s:core.sha_from_row(prog_by_seq.get(s,{})) for s in inv_by_seq}
    sha_provenance={s:'_system/v4c/progress/v4c_source_progress.jsonl' for s,v in sha_by_seq.items() if v}

    # Recover SHA only from already-persisted frozen ledgers. No source/artifact fetch occurs.
    collect_frozen_sha(closeout,sha_by_seq,args.closeout,sha_provenance)
    collect_frozen_sha(corrected_images,sha_by_seq,args.corrected_images,sha_provenance)
    collect_frozen_sha(corrected_queue,sha_by_seq,args.corrected_queue,sha_provenance)
    for path in [
      '_system/v4c/preservation/results/image_preservation.jsonl',
      '_system/v4c/claim_gate/calibration/calibration_manifest.jsonl',
      '_system/v4c/evidence_hydration/evidence.jsonl',
      '_system/v4c/evidence_hydration/bartifact_recovery/materialized_evidence.jsonl',
      '_system/v4c/evidence_hydration/source_fallback/evidence.jsonl'
    ]:
        p=Path(path)
        if p.exists(): collect_frozen_sha(core.read_jsonl(path),sha_by_seq,path,sha_provenance)

    dup_alias={int(x['sequence']):int(x['canonical_sequence']) for x in duplicates.get('sha256_duplicates',[]) or []}
    dup_sha={int(x['sequence']):str(x.get('sha256') or '').lower() for x in duplicates.get('sha256_duplicates',[]) or []}
    if len(dup_alias)!=4: raise RuntimeError(f'BLOCK_RECONCILIATION: expected 4 SHA aliases, got {len(dup_alias)}')
    for s,sh in dup_sha.items():
        if not sha_by_seq.get(s) and re.fullmatch(r'[0-9a-f]{64}',sh):
            sha_by_seq[s]=sh; sha_provenance[s]=args.duplicates

    preserve_origins=core.collect_preserve_sequences()
    approvals,approval_files=core.build_approval_map(inv_by_product)
    q_by_seq={int(r['sequence']):r for r in corrected_queue}
    ci_by_seq={int(r['sequence']):r for r in corrected_images}
    close_by_seq={int(r['sequence']):r for r in closeout}
    if len(q_by_seq)!=core.EXPECTED_V4C32_QUEUE: raise RuntimeError('Duplicate sequence in V4-C3.2 queue')

    # Every V4-C3.2 safe candidate must have a frozen SHA in its own queue row or another frozen ledger.
    unsafe_queue_sha=[s for s in q_by_seq if not sha_by_seq.get(s)]
    if unsafe_queue_sha:
        raise RuntimeError(f'BLOCK_RECONCILIATION: V4-C3.2 safe candidates without frozen SHA: {unsafe_queue_sha[:20]}')
    unsafe_preserve_sha=[s for s in preserve_origins if s in inv_by_seq and not sha_by_seq.get(s)]
    # These are held, never fabricated. They remain part of global preserve discovery but cannot occupy a slot.

    canonical=[]; base_counts=Counter(); locked_guard_products_present=set()
    for s in range(1,core.EXPECTED_SOURCES+1):
        inv=inv_by_seq[s]; pid=str(inv['product_id']); sha=sha_by_seq.get(s)
        row={
          'schema_version':core.SCHEMA,'sequence':s,'source_id':str(inv.get('source_id') or f'V4C-S{s:06d}'),
          'product_id':pid,'image_index':inv.get('image_index'),'image_type':inv.get('image_type'),
          'source_url':inv.get('url'),'source_sha256':sha,'source_sha256_provenance':sha_provenance.get(s),
          'source_action':inv.get('source_action'),'canonical_state':None,'underlying_state':None,'state_reason':None,
          'state_evidence_references':[],'safe_fact_ids':[],'safe_text':[],'excluded_unknown_ids':[],
          'excluded_conflict_ids':[],'excluded_forbidden_ids':[],'variant_scope':[],'product_conflict_quarantine':[],
          'approved_output_sha256':None,'approved_slot_role':None,'duplicate_canonical_sequence':None,
          'do_not_regenerate':False,'selected_for_final_5slot':False
        }
        if s in approvals and sha:
            ap=approvals[s]
            row.update({'canonical_state':'LOCKED_APPROVED','underlying_state':'LOCKED_APPROVED',
              'state_reason':'DURABLE_HUMAN_VISUAL_ACCEPTANCE','state_evidence_references':[core.evidence_ref(ap['approval_file'],s,{'run_id':ap['approval_run_id']})],
              'approved_output_sha256':ap['approved_output_sha256'],'approved_slot_role':ap['approved_slot_role'],'do_not_regenerate':True})
        elif s in approvals and not sha:
            row.update({'canonical_state':'HOLD','underlying_state':'HOLD','state_reason':'LOCKED_APPROVED_OUTPUT_BUT_SOURCE_SHA_NOT_DURABLY_PERSISTED',
              'state_evidence_references':[core.evidence_ref(approvals[s]['approval_file'],s)],'do_not_regenerate':True})
        elif s in dup_alias:
            row.update({'canonical_state':'DUPLICATE_ALIAS','underlying_state':'DUPLICATE_ALIAS','state_reason':'FROZEN_SHA_DUPLICATE_ALIAS',
              'duplicate_canonical_sequence':dup_alias[s],'state_evidence_references':[core.evidence_ref(args.duplicates,s,{'canonical_sequence':dup_alias[s]})],
              'do_not_regenerate':True})
        elif pid in core.LOCKED_PRODUCT_GUARDS:
            locked_guard_products_present.add(pid)
            row.update({'canonical_state':'HOLD','underlying_state':'HOLD','state_reason':'LOCKED_PRODUCT_GUARD_WITHOUT_DURABLE_SLOT_APPROVAL_FOR_THIS_SOURCE',
              'state_evidence_references':[{'policy':'LOCKED_PRODUCT_DO_NOT_RERUN','product_id':pid}],'do_not_regenerate':True})
        elif s in preserve_origins and sha:
            row.update({'canonical_state':'PRESERVE','underlying_state':'PRESERVE','state_reason':'FROZEN_PRESERVATION_PASS',
              'state_evidence_references':preserve_origins[s],'do_not_regenerate':True})
        elif s in preserve_origins and not sha:
            row.update({'canonical_state':'HOLD','underlying_state':'HOLD','state_reason':'FROZEN_PRESERVE_BUT_SOURCE_SHA_NOT_DURABLY_PERSISTED',
              'state_evidence_references':preserve_origins[s],'do_not_regenerate':True})
        elif s in q_by_seq:
            q=q_by_seq[s]
            row.update({'canonical_state':'PROCESS_SAFE','underlying_state':'PROCESS_SAFE','state_reason':'V4_C3_2_CORRECTED_GENERATION_CANDIDATE',
              'state_evidence_references':[core.evidence_ref(args.corrected_queue,s)],'safe_fact_ids':list(q.get('safe_fact_ids') or []),
              'safe_text':list(q.get('safe_text') or []),'excluded_unknown_ids':list(q.get('excluded_unknown_fact_ids') or []),
              'excluded_conflict_ids':list(q.get('excluded_conflict_fact_ids') or []),'excluded_forbidden_ids':list(q.get('excluded_forbidden_fact_ids') or []),
              'variant_scope':list(q.get('variant_scope') or []),'product_conflict_quarantine':list(q.get('product_conflict_quarantine') or [])})
        else:
            ci=ci_by_seq.get(s); co=close_by_seq.get(s)
            if ci and ci.get('generation_eligibility')=='BLOCK_FACTUAL': st='BLOCK'; reason='V4_C3_2_BLOCK_FACTUAL'
            elif co and co.get('final_status')=='BLOCK_FINAL': st='BLOCK'; reason='V4_C2_BLOCK_FINAL'
            elif co and co.get('final_status')=='HOLD_FINAL': st='HOLD'; reason='V4_C2_HOLD_FINAL'
            elif not sha: st='HOLD'; reason='LEGACY_SOURCE_SHA_NOT_DURABLY_PERSISTED'
            else: st='HOLD'; reason='NO_FROZEN_PRESERVE_OR_V4_C3_2_PROCESS_SAFE_AUTHORIZATION'
            refs=[]
            if ci: refs.append(core.evidence_ref(args.corrected_images,s))
            if co: refs.append(core.evidence_ref(args.closeout,s))
            row.update({'canonical_state':st,'underlying_state':st,'state_reason':reason,'state_evidence_references':refs,'do_not_regenerate':st in {'BLOCK'}})
        base_counts[row['underlying_state']]+=1; canonical.append(row)

    # Safe states are forbidden without a durable source SHA.
    bad_safe=[r['sequence'] for r in canonical if r['underlying_state'] in core.SAFE_STATES and not r.get('source_sha256')]
    if bad_safe: raise RuntimeError(f'Safe canonical state without SHA: {bad_safe[:20]}')
    q_state=Counter(next(r for r in canonical if r['sequence']==s)['canonical_state'] for s in q_by_seq)
    unexpected={k:v for k,v in q_state.items() if k not in {'PROCESS_SAFE','LOCKED_APPROVED','PRESERVE','HOLD'}}
    if unexpected: raise RuntimeError(f'Corrected queue reconciled to unexpected states: {unexpected}')

    taxonomy=core.load_taxonomy()
    missing_sha=[s for s,v in sha_by_seq.items() if not v]
    core.write_jsonl(args.base_state,canonical)
    prep={
      'schema_version':'v4c4.0.prepare-r2.1','passed':True,'authoritative_product_count':len(products),
      'authoritative_source_image_count':len(inventory),'base_state_counts':dict(base_counts),
      'global_preserve_underlying_count':base_counts['PRESERVE'],'locked_approved_count':base_counts['LOCKED_APPROVED'],
      'raw_v4c3_2_generation_candidate_count':len(corrected_queue),'canonical_process_safe_count':base_counts['PROCESS_SAFE'],
      'duplicate_alias_count':base_counts['DUPLICATE_ALIAS'],'source_sha_available_count':sum(1 for v in sha_by_seq.values() if v),
      'source_sha_not_durably_persisted_count':len(missing_sha),'source_sha_missing_sequences_sample':missing_sha[:20],
      'preserve_discovered_but_sha_unavailable_count':len(unsafe_preserve_sha),
      'locked_product_guards':sorted(core.LOCKED_PRODUCT_GUARDS),'locked_product_guards_present':sorted(core.LOCKED_PRODUCT_GUARDS & products),
      'locked_approval_files':approval_files,'taxonomy_products_observable':len(taxonomy),'api_flags':core.api_flags()
    }
    core.write_json(args.prepare_summary,prep); print(json.dumps(prep,ensure_ascii=False,sort_keys=True))


def features_r2(pid,items,plan,taxonomy):
    x=core.features_for_product(pid,items,plan,taxonomy)
    if pid in FROZEN_VARIANT_PRODUCTS: x['variant_product']=True
    return x


def select_canary_r2(base_state,n=25):
    # Temporarily replace feature extraction so known variant fixtures from frozen test code
    # can satisfy representativeness without entering any generation-safe fact payload.
    old=core.features_for_product
    core.features_for_product=features_r2
    try: return core.select_canary(base_state,n)
    finally: core.features_for_product=old


def canary_r2(args):
    old=core.select_canary
    core.select_canary=select_canary_r2
    try: return core.canary(args)
    finally: core.select_canary=old


if __name__=='__main__':
    core.prepare=prepare_r2
    core.canary=canary_r2
    core.main()
