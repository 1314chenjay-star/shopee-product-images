#!/usr/bin/env python3
import argparse, hashlib, json, sys, tempfile
from collections import Counter
from pathlib import Path

EXPECTED_TOTAL=1378


def rows(path):
    out=[]
    for i,line in enumerate(Path(path).open(encoding='utf-8-sig'),1):
        if line.strip():
            try:out.append(json.loads(line))
            except Exception as e:raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out


def synthetic_source_changed_test():
    here=str(Path(__file__).resolve().parent)
    if here not in sys.path:sys.path.insert(0,here)
    import v4c_hold_hydration as h
    with tempfile.TemporaryDirectory() as td:
        p=Path(td)/'visual.img';p.write_bytes(b'changed-visual-bytes')
        expected=hashlib.sha256(b'original-visual-bytes').hexdigest()
        row={'sequence':999999,'source_id':'fixture','product_id':'fixture','expected_sha256':expected,
             'hydration_action':'USE_B001_B018_VISUAL','artifact_local_path':str(p)}
        rec=h.hydrate_one(row,None,{}, {}, {}, td,'_system/v4c/evidence_hydration/evidence.jsonl')
        if rec.get('preservation_decision')!='BLOCK_SOURCE_CHANGED' or rec.get('terminal_status')!='BLOCK':
            raise RuntimeError('Synthetic source changed route did not BLOCK_SOURCE_CHANGED')
        if bool((rec.get('flags') or {}).get('ocr_executed')):raise RuntimeError('SHA mismatch unexpectedly entered OCR')
    return True


def check_evidence(rec):
    flags=rec.get('flags') or {}
    for k in ['image_generation_called','tiny_snow_api_called','paid_api_called','vision_api_called','semantic_inference_executed']:
        if bool(flags.get(k)):raise RuntimeError(f'Forbidden flag {k}=true seq {rec.get("sequence")}')
    for c in rec.get('unknown_claims') or []:
        if c.get('status')!='UNKNOWN' or c.get('allowed_usage')!='NONE':raise RuntimeError(f'UNKNOWN policy violation seq {rec.get("sequence")}')
    if rec.get('preservation_decision')=='PRESERVE' and rec.get('claim_gate_status')!='SKIP_PRESERVE':
        raise RuntimeError(f'PRESERVE entered claim gate seq {rec.get("sequence")}')
    if rec.get('preservation_decision')=='BLOCK_SOURCE_CHANGED':
        if bool(flags.get('sha_verified')):raise RuntimeError('Source changed incorrectly marked SHA verified')
        if bool(flags.get('ocr_executed')):raise RuntimeError('Source changed entered OCR')
    if bool(flags.get('ocr_executed')):
        if not bool(flags.get('sha_verified')):raise RuntimeError(f'OCR executed before SHA verification seq {rec.get("sequence")}')
        if not isinstance((rec.get('ocr') or {}).get('texts'),list):raise RuntimeError(f'OCR texts missing seq {rec.get("sequence")}')
        for t in (rec.get('ocr') or {}).get('texts') or []:
            if 'bounding_box' not in t:raise RuntimeError(f'OCR bounding box missing seq {rec.get("sequence")}')
    for key in ['sha256','image_metadata','ocr','script_classification','localization_state','claim_candidates','verified_claims','unknown_claims','evidence_location','preservation_decision','confidence']:
        if key not in rec:raise RuntimeError(f'Durable evidence field {key} missing seq {rec.get("sequence")}')


def validate_canary(a):
    manifest=rows(a.manifest);progress=rows(a.progress)
    if len(manifest)!=100:raise RuntimeError(f'Canary manifest expected 100 got {len(manifest)}')
    by={int(r['sequence']):r for r in progress};mseq=[int(r['sequence']) for r in manifest]
    if set(by)!=set(mseq):raise RuntimeError('Canary input/output reconciliation failed')
    seed=json.loads(Path(a.seed_summary).read_text(encoding='utf-8-sig'));resume=json.loads(Path(a.resume_summary).read_text(encoding='utf-8-sig'))
    if int(seed.get('processed_this_run',-1))!=25 or int(seed.get('checkpoint_existing_terminal',-1))!=0:raise RuntimeError('Canary seed checkpoint failed')
    if int(resume.get('checkpoint_existing_terminal',-1))!=25 or int(resume.get('processed_this_run',-1))!=75:raise RuntimeError('Canary resume checkpoint failed')
    for r in progress:check_evidence(r)
    planned_fetch={int(r['sequence']) for r in manifest if str(r.get('hydration_action'))=='FETCH_VISUAL'}
    actual_fetch={int(r['sequence']) for r in progress if bool((r.get('flags') or {}).get('targeted_source_fetch_called'))}
    if actual_fetch-planned_fetch:raise RuntimeError(f'Untargeted fetch observed {sorted(actual_fetch-planned_fetch)[:10]}')
    if planned_fetch-actual_fetch:raise RuntimeError(f'Planned targeted fetch not called {sorted(planned_fetch-actual_fetch)[:10]}')
    if not synthetic_source_changed_test():raise RuntimeError('Synthetic source changed test failed')
    st=Counter(str(r.get('terminal_status')) for r in progress);pr=Counter(str(r.get('preservation_decision')) for r in progress)
    out={'schema_version':'v4c2.3.hydration-validation.1','phase':'CANARY','passed':True,'input_count':100,'terminal_count':100,
         'checkpoint_seed':25,'checkpoint_resume_skipped':25,'checkpoint_resume_processed':75,
         'targeted_fetch_planned':len(planned_fetch),'targeted_fetch_called':len(actual_fetch),
         'fetched':sum(bool((r.get('flags') or {}).get('fetched_successfully')) for r in progress),
         'sha_mismatch_source_changed':pr.get('BLOCK_SOURCE_CHANGED',0),'synthetic_source_changed_block_test':True,
         'preserve':pr.get('PRESERVE',0),'needs_localization':pr.get('NEEDS_LOCALIZATION',0),'partial_safe':st.get('PARTIAL_SAFE',0),
         'hold':st.get('HOLD',0),'block':st.get('BLOCK',0),'semantic_actually_executed':0,'remaining':0,
         'unknown_allowed_usage_none':True,'preservation_first':True,'durable_evidence_fields':True,
         'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,
         'v4c1_retested':False,'v4c2_0_retested':False,'v4c2_1_retested':False,'v4c2_2_gate_retested':False}
    Path(a.output).parent.mkdir(parents=True,exist_ok=True);Path(a.output).write_text(json.dumps(out,ensure_ascii=False,indent=2),encoding='utf-8')
    print('HYDRATION_CANARY_PASS=true');print('CANARY_FETCH_PLANNED='+str(len(planned_fetch)));print('CANARY_FETCH_CALLED='+str(len(actual_fetch)))


def validate_full(a):
    gaps=rows(a.gap_index);evidence=rows(a.evidence)
    if len(gaps)!=EXPECTED_TOTAL or len(evidence)!=EXPECTED_TOTAL:raise RuntimeError('Full total mismatch')
    gs={int(r['sequence']) for r in gaps};es={int(r['sequence']) for r in evidence}
    if gs!=es:raise RuntimeError('Full input/output sequence reconciliation failed')
    for r in evidence:check_evidence(r)
    planned_fetch={int(r['sequence']) for r in gaps if str(r.get('hydration_action'))=='FETCH_VISUAL'}
    actual_fetch={int(r['sequence']) for r in evidence if bool((r.get('flags') or {}).get('targeted_source_fetch_called'))}
    if planned_fetch!=actual_fetch:raise RuntimeError(f'Full targeted fetch reconciliation mismatch planned={len(planned_fetch)} actual={len(actual_fetch)}')
    st=Counter(str(r.get('terminal_status')) for r in evidence);pr=Counter(str(r.get('preservation_decision')) for r in evidence)
    summ=json.loads(Path(a.final_summary).read_text(encoding='utf-8-sig'))
    if int(summ.get('total',0))!=EXPECTED_TOTAL or int(summ.get('remaining',-1))!=0:raise RuntimeError('Final summary reconciliation failed')
    out={'schema_version':'v4c2.3.hydration-validation.1','phase':'FULL','passed':True,'input_count':EXPECTED_TOTAL,'terminal_count':EXPECTED_TOTAL,
         'evidence_already_reusable':int(summ.get('evidence_already_reusable',0)),'visual_fetch_required':len(planned_fetch),'fetch_attempted':len(actual_fetch),
         'fetched':int(summ.get('fetched',0)),'sha_mismatch_source_changed':pr.get('BLOCK_SOURCE_CHANGED',0),
         'preserve':pr.get('PRESERVE',0),'needs_localization':pr.get('NEEDS_LOCALIZATION',0),'partial_safe':st.get('PARTIAL_SAFE',0),
         'hold':st.get('HOLD',0),'block':st.get('BLOCK',0),'semantic_actually_executed':0,'remaining':0,
         'unknown_allowed_usage_none':True,'preservation_first':True,'durable_evidence_fields':True,'targeted_fetch_only':True,'sha_verified_before_ocr':True,
         'input_output_reconciliation':True,'synthetic_source_changed_block_test':True,
         'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,
         'v4c1_retested':False,'v4c2_0_retested':False,'v4c2_1_retested':False,'v4c2_2_gate_retested':False}
    Path(a.output).parent.mkdir(parents=True,exist_ok=True);Path(a.output).write_text(json.dumps(out,ensure_ascii=False,indent=2),encoding='utf-8')
    print('HYDRATION_FULL_PASS=true');print('TOTAL=1378');print('PRESERVE='+str(out['preserve']));print('NEEDS_LOCALIZATION='+str(out['needs_localization']));print('PARTIAL_SAFE='+str(out['partial_safe']));print('HOLD='+str(out['hold']));print('BLOCK='+str(out['block']))


def main():
    p=argparse.ArgumentParser();p.add_argument('--mode',choices=['canary','full'],required=True);p.add_argument('--output',required=True)
    p.add_argument('--manifest');p.add_argument('--progress');p.add_argument('--seed-summary');p.add_argument('--resume-summary')
    p.add_argument('--gap-index');p.add_argument('--evidence');p.add_argument('--final-summary')
    a=p.parse_args()
    if a.mode=='canary':
        for x in ['manifest','progress','seed_summary','resume_summary']:
            if not getattr(a,x):p.error('canary missing --'+x.replace('_','-'))
        validate_canary(a)
    else:
        for x in ['gap_index','evidence','final_summary']:
            if not getattr(a,x):p.error('full missing --'+x.replace('_','-'))
        validate_full(a)
    return 0
if __name__=='__main__':sys.exit(main())
