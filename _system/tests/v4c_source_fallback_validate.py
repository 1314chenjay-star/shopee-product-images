#!/usr/bin/env python3
import argparse,json,sys
from pathlib import Path


def read_jsonl(path):
    p=Path(path);out=[]
    if not p.exists():return out
    for line in p.open(encoding='utf-8-sig'):
        if line.strip():out.append(json.loads(line))
    return out

def write_json(path,obj):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')

def validate_fallback(manifest,rows,phase):
    exp={int(r['sequence']) for r in manifest};by={int(r['sequence']):r for r in rows}
    if set(by)!=exp:raise RuntimeError(f'{phase} reconciliation failed missing={sorted(exp-set(by))[:10]} extra={sorted(set(by)-exp)[:10]}')
    for seq,r in by.items():
        if not r.get('targeted_source_fetch_planned'):raise RuntimeError(f'Non-fallback row leaked seq {seq}')
        f=r.get('flags') or {}
        if not f.get('targeted_source_fetch_called'):raise RuntimeError(f'Fallback fetch not attempted seq {seq}')
        for k in ['artifact_search_called','artifact_download_called','completed_ocr_rerun','semantic_inference_executed','completed_semantic_rerun','image_generation_called','tiny_snow_api_called','paid_api_called','vision_api_called','rerun_1378','source_refetch_1144','inventory_rebuilt','old_gate_modified','v4c1_retested','v4c2_0_retested','v4c2_1_retested','v4c2_2_retested','v4c2_3_retested','v4c2_4_retested']:
            if f.get(k):raise RuntimeError(f'Forbidden flag {k}=true seq {seq}')
        if r.get('fetch_failed'):
            if r.get('terminal_status')!='HOLD' or r.get('preservation_decision')!='HOLD_SOURCE_UNAVAILABLE':raise RuntimeError(f'Fetch failure not HOLD_SOURCE_UNAVAILABLE seq {seq}')
            if f.get('new_missing_evidence_ocr_executed'):raise RuntimeError(f'Fetch failure unexpectedly OCRd seq {seq}')
        if r.get('sha_mismatch'):
            if r.get('terminal_status')!='BLOCK' or r.get('preservation_decision')!='BLOCK_SOURCE_CHANGED':raise RuntimeError(f'SHA mismatch not BLOCK_SOURCE_CHANGED seq {seq}')
            if f.get('new_missing_evidence_ocr_executed'):raise RuntimeError(f'SHA mismatch unexpectedly OCRd seq {seq}')
        if r.get('sha_matched'):
            if str(r.get('expected_sha256'))!=str(r.get('actual_sha256')):raise RuntimeError(f'SHA equality broken seq {seq}')
            if not f.get('new_missing_evidence_ocr_executed'):raise RuntimeError(f'SHA match missing new OCR seq {seq}')
            if r.get('preservation_decision')=='PRESERVE':
                if r.get('claim_gate_status')!='SKIP_PRESERVE':raise RuntimeError(f'PRESERVE entered claim gate seq {seq}')
            elif r.get('preservation_decision')=='NEEDS_LOCALIZATION':
                for c in r.get('verified_claims') or []:
                    if c.get('status')!='VERIFIED_SOURCE':raise RuntimeError(f'Non VERIFIED_SOURCE allowed seq {seq}')
                for c in r.get('unknown_claims') or []:
                    if c.get('status')!='UNKNOWN' or c.get('allowed_usage')!='NONE':raise RuntimeError(f'UNKNOWN usage violation seq {seq}')
            else:raise RuntimeError(f'Unexpected matched preservation decision seq {seq}: {r.get("preservation_decision")}')
    success=sum(bool(r.get('fetch_success')) for r in rows);failed=sum(bool(r.get('fetch_failed')) for r in rows);matched=sum(bool(r.get('sha_matched')) for r in rows);mismatch=sum(bool(r.get('sha_mismatch')) for r in rows)
    if success+failed!=len(rows):raise RuntimeError('Fetch success/failed reconciliation failed')
    if matched+mismatch!=success:raise RuntimeError('SHA/fetch success reconciliation failed')
    return {'fetch_success':success,'fetch_failed':failed,'sha_matched':matched,'sha_mismatch':mismatch}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--phase',choices=['CANARY','FALLBACK_FULL','FINAL'],required=True);ap.add_argument('--manifest',required=True);ap.add_argument('--evidence',required=True);ap.add_argument('--output',required=True);ap.add_argument('--seed-summary');ap.add_argument('--resume-summary');ap.add_argument('--found-resolution');a=ap.parse_args()
    m=read_jsonl(a.manifest);r=read_jsonl(a.evidence)
    if a.phase=='CANARY':
        if len(m)!=40:raise RuntimeError(f'Canary expected 40, got {len(m)}')
        stats=validate_fallback(m,r,a.phase)
        if not a.seed_summary or not a.resume_summary:raise RuntimeError('Canary requires checkpoint summaries')
        seed=json.loads(Path(a.seed_summary).read_text(encoding='utf-8-sig'));resume=json.loads(Path(a.resume_summary).read_text(encoding='utf-8-sig'))
        if int(seed.get('processed_this_run',0))!=10:raise RuntimeError('Canary seed did not process 10')
        if int(resume.get('checkpoint_existing_terminal',0))<10:raise RuntimeError('Canary resume did not skip seed 10')
        out={'schema_version':'v4c2.5.validation.1','phase':'CANARY','passed':True,'target':40,**stats,'checkpoint_resume':True}
    elif a.phase=='FALLBACK_FULL':
        if len(m)!=184:raise RuntimeError(f'Fallback full expected 184, got {len(m)}')
        stats=validate_fallback(m,r,a.phase);out={'schema_version':'v4c2.5.validation.1','phase':'FALLBACK_FULL','passed':True,'target':184,**stats}
    else:
        if len(m)!=187 or len(r)!=187:raise RuntimeError(f'Final expected 187, got manifest={len(m)} evidence={len(r)}')
        fallback=[x for x in r if x.get('targeted_source_fetch_planned')]
        found=[x for x in r if x.get('evidence_origin')=='V4C2_4_DURABLE_EVIDENCE_REUSE']
        if len(fallback)!=184 or len(found)!=3:raise RuntimeError('Final 184+3 partition failed')
        fbmanifest=[x for x in m if x.get('fallback_action')=='TARGETED_SOURCE_FETCH'];stats=validate_fallback(fbmanifest,fallback,'FINAL_FALLBACK')
        for x in found:
            f=x.get('flags') or {}
            if f.get('targeted_source_fetch_called') or f.get('new_missing_evidence_ocr_executed'):raise RuntimeError(f'Found-HOLD was downloaded/OCRd seq {x.get("sequence")}')
            if x.get('terminal_status') not in {'PARTIAL_SAFE','HOLD'}:raise RuntimeError(f'Unexpected found-HOLD resolution seq {x.get("sequence")}')
            for c in x.get('unknown_claims') or []:
                if c.get('allowed_usage')!='NONE':raise RuntimeError(f'Found-HOLD UNKNOWN usage violation seq {x.get("sequence")}')
        out={'schema_version':'v4c2.5.validation.1','phase':'FINAL','passed':True,'target':187,**stats,'found_hold_target':3,
             'found_hold_upgraded':sum(x.get('terminal_status')=='PARTIAL_SAFE' for x in found),'found_hold_retained':sum(x.get('terminal_status')=='HOLD' for x in found),
             'original_13_block_touched':False,'rerun_1378':False,'source_refetch_1144':False,'completed_ocr_rerun':False,'semantic_rerun':False,'inventory_rebuilt':False}
    write_json(a.output,out);print(a.phase+'_VALIDATION_PASS=true');print('FETCH_SUCCESS='+str(out.get('fetch_success',0)));print('SHA_MATCHED='+str(out.get('sha_matched',0)));return 0
if __name__=='__main__':sys.exit(main())
