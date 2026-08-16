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

def validate_records(manifest,rows):
    exp={int(r['sequence']) for r in manifest};by={int(r['sequence']):r for r in rows}
    if set(by)!=exp:raise RuntimeError(f'Input/output reconciliation failed missing={sorted(exp-set(by))[:10]} extra={sorted(set(by)-exp)[:10]}')
    if any(str(r.get('hydration_action'))!='USE_B001_B018_VISUAL' for r in manifest):raise RuntimeError('Manifest leaked outside USE_B001_B018_VISUAL')
    for seq,r in by.items():
        flags=r.get('flags') or {}
        if flags.get('source_fetch_called'):raise RuntimeError(f'Source fetch called for seq {seq}')
        if flags.get('semantic_inference_executed'):raise RuntimeError(f'Semantic inference executed for seq {seq}')
        for k in ['image_generation_called','tiny_snow_api_called','paid_api_called','vision_api_called','rerun_1378','source_refetch_1144','inventory_rebuilt','completed_ocr_rerun','completed_semantic_rerun','v4c1_retested','v4c2_0_retested','v4c2_1_retested','v4c2_2_retested','v4c2_3_retested']:
            if flags.get(k):raise RuntimeError(f'Forbidden flag {k}=true seq {seq}')
        if r.get('artifact_not_found'):
            if r.get('terminal_status')!='HOLD' or r.get('preservation_decision')!='HOLD_ARTIFACT_NOT_FOUND':raise RuntimeError(f'Artifact-not-found not HOLD seq {seq}')
            if flags.get('ocr_executed'):raise RuntimeError(f'Artifact-not-found unexpectedly OCRd seq {seq}')
        if r.get('sha_mismatch'):
            if r.get('terminal_status')!='BLOCK' or r.get('preservation_decision')!='BLOCK_ARTIFACT_SHA_MISMATCH':raise RuntimeError(f'SHA mismatch not BLOCK seq {seq}')
            if flags.get('ocr_executed'):raise RuntimeError(f'SHA mismatch OCR executed seq {seq}')
        if r.get('sha_matched'):
            if not r.get('artifact_found'):raise RuntimeError(f'SHA matched without artifact found seq {seq}')
            if str(r.get('recorded_sha256'))!=str(r.get('actual_sha256')):raise RuntimeError(f'SHA equality broken seq {seq}')
            if not flags.get('ocr_executed'):raise RuntimeError(f'SHA matched but preservation OCR not executed seq {seq}')
            md=r.get('image_metadata') or {};ocr=r.get('ocr') or {};script=r.get('script_classification') or {};loc=r.get('evidence_location') or {}
            for k in ['width_px','height_px','byte_count']:
                if k not in md:raise RuntimeError(f'Missing durable image metadata {k} seq {seq}')
            if 'texts' not in ocr:raise RuntimeError(f'Missing durable OCR texts seq {seq}')
            for t in ocr.get('texts') or []:
                if 'text' not in t or 'confidence' not in t or 'bounding_box' not in t:raise RuntimeError(f'Incomplete OCR evidence seq {seq}')
            if 'classification' not in script:raise RuntimeError(f'Missing script classification seq {seq}')
            if not loc.get('artifact') or not loc.get('artifact_file') or not loc.get('durable'):raise RuntimeError(f'Missing evidence location seq {seq}')
            if r.get('preservation_decision')=='PRESERVE':
                if r.get('claim_gate_status')!='SKIP_PRESERVE':raise RuntimeError(f'PRESERVE leaked to claim gate seq {seq}')
            elif r.get('preservation_decision')=='NEEDS_LOCALIZATION':
                for c in r.get('verified_claims') or []:
                    if c.get('status')!='VERIFIED_SOURCE':raise RuntimeError(f'Non-verified claim allowed seq {seq}')
                for c in r.get('unknown_claims') or []:
                    if c.get('status')!='UNKNOWN' or c.get('allowed_usage')!='NONE':raise RuntimeError(f'UNKNOWN usage violation seq {seq}')
            else:raise RuntimeError(f'Unexpected preservation decision after SHA match seq {seq}: {r.get("preservation_decision")}')
    return by

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--phase',choices=['CANARY','FULL'],required=True);ap.add_argument('--manifest',required=True);ap.add_argument('--evidence',required=True);ap.add_argument('--output',required=True);ap.add_argument('--seed-summary');ap.add_argument('--resume-summary');a=ap.parse_args()
    m=read_jsonl(a.manifest);r=read_jsonl(a.evidence);validate_records(m,r)
    if a.phase=='CANARY':
        if len(m)!=40:raise RuntimeError(f'Canary expected 40, got {len(m)}')
        if not a.seed_summary or not a.resume_summary:raise RuntimeError('Canary requires seed/resume summaries')
        seed=json.loads(Path(a.seed_summary).read_text(encoding='utf-8-sig'));resume=json.loads(Path(a.resume_summary).read_text(encoding='utf-8-sig'))
        if int(seed.get('processed_this_run',0))!=10:raise RuntimeError('Canary checkpoint seed did not process 10')
        if int(resume.get('checkpoint_existing_terminal',0))<10:raise RuntimeError('Canary resume did not skip seed checkpoint')
        checkpoint=True
    else:
        if len(m)!=221:raise RuntimeError(f'Full expected target 221, got {len(m)}')
        checkpoint=True
    found=sum(bool(x.get('artifact_found')) for x in r);notfound=sum(bool(x.get('artifact_not_found')) for x in r);matched=sum(bool(x.get('sha_matched')) for x in r);mismatch=sum(bool(x.get('sha_mismatch')) for x in r)
    preserve=sum(x.get('preservation_decision')=='PRESERVE' for x in r);needs=sum(x.get('preservation_decision')=='NEEDS_LOCALIZATION' for x in r);partial=sum(x.get('terminal_status')=='PARTIAL_SAFE' for x in r);hold=sum(x.get('terminal_status')=='HOLD' for x in r);block=sum(x.get('terminal_status')=='BLOCK' for x in r)
    if found+notfound!=len(r):raise RuntimeError('Artifact found/not-found reconciliation failed')
    if matched+mismatch!=found:raise RuntimeError('SHA matched/mismatch does not reconcile artifact_found')
    out={'schema_version':'v4c2.4.recovery-validation.1','phase':a.phase,'passed':True,'target':len(r),'artifact_found':found,'artifact_not_found':notfound,'sha_matched':matched,'sha_mismatch':mismatch,
         'preserve':preserve,'needs_localization':needs,'partial_safe':partial,'hold_remaining':hold,'block':block,'checkpoint_resume':checkpoint,
         'preservation_first':True,'verified_source_only':True,'unknown_allowed_usage_none':True,'durable_evidence_persistence':True,'input_output_reconciliation':True,
         'api_flags':{'source_fetch_called':False,'semantic_inference_executed':False,'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,'rerun_1378':False,'source_refetch_1144':False,'inventory_rebuilt':False,'completed_ocr_rerun':False,'completed_semantic_rerun':False}}
    write_json(a.output,out);print(f'{a.phase}_VALIDATION_PASS=true');print(f'ARTIFACT_FOUND={found}');print(f'SHA_MATCHED={matched}');return 0
if __name__=='__main__':sys.exit(main())
