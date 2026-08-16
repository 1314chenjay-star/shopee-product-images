#!/usr/bin/env python3
import argparse, hashlib, json, os, re, sys, time
from collections import Counter, defaultdict
from pathlib import Path
from urllib.request import Request, urlopen

SCHEMA='v4c2.5.targeted-source-fallback.1'
PLAN_SCHEMA='v4c2.5.targeted-source-plan.1'
BASE_HEAD='0bc5a97d0428ecccfcebcc42c35a85e12d3cbe91'
STABLE_HEAD='5d49f061e140813b3d229520e9e530f86b27b640'
EXPECTED_TARGET=187
EXPECTED_FALLBACK=184
EXPECTED_FOUND_HOLD=3
HEX64=re.compile(r'^[0-9a-f]{64}$')


def read_jsonl(path):
    p=Path(path)
    if not p.exists(): return []
    out=[]
    for i,line in enumerate(p.open(encoding='utf-8-sig'),1):
        if not line.strip(): continue
        try: out.append(json.loads(line))
        except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out


def write_jsonl(path,rows):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows:f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')


def append_jsonl(path,row):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('a',encoding='utf-8',newline='\n') as f:
        f.write(json.dumps(row,ensure_ascii=False,separators=(',',':'))+'\n');f.flush();os.fsync(f.fileno())


def write_json(path,obj):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')


def sha_bytes(data):return hashlib.sha256(data).hexdigest()

def sha_file(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def choose_canary(rows,n):
    buckets=defaultdict(list)
    for r in rows:buckets[str(r.get('product_id') or '')].append(r)
    for k in buckets:buckets[k]=sorted(buckets[k],key=lambda x:int(x['sequence']))
    keys=sorted(buckets,key=lambda x:hashlib.sha256(x.encode()).hexdigest())
    chosen=[]
    while len(chosen)<n:
        moved=False
        for k in keys:
            if buckets[k] and len(chosen)<n:
                chosen.append(buckets[k].pop(0));moved=True
        if not moved:break
    if len(chosen)!=n:raise RuntimeError(f'Cannot choose {n} fallback canary rows')
    return chosen


def plan(a):
    prior=read_jsonl(a.bartifact_evidence)
    if len(prior)!=221:raise RuntimeError(f'Expected frozen V4-C2.4 evidence 221, got {len(prior)}')
    holds=[r for r in prior if str(r.get('terminal_status'))=='HOLD']
    if len(holds)!=EXPECTED_TARGET:raise RuntimeError(f'Expected {EXPECTED_TARGET} V4-C2.4 HOLD rows, got {len(holds)}')
    fallback=[r for r in holds if bool(r.get('artifact_not_found')) and str(r.get('preservation_decision'))=='HOLD_ARTIFACT_NOT_FOUND']
    found_hold=[r for r in holds if bool(r.get('artifact_found'))]
    if len(fallback)!=EXPECTED_FALLBACK:raise RuntimeError(f'Expected {EXPECTED_FALLBACK} artifact-not-found HOLD, got {len(fallback)}')
    if len(found_hold)!=EXPECTED_FOUND_HOLD:raise RuntimeError(f'Expected {EXPECTED_FOUND_HOLD} artifact-found HOLD, got {len(found_hold)}')
    if any(r.get('sha_mismatch') for r in found_hold):raise RuntimeError('Artifact-found HOLD unexpectedly includes SHA mismatch')
    out_fallback=[]
    for r in sorted(fallback,key=lambda x:int(x['sequence'])):
        sha=str(r.get('recorded_sha256') or '').lower();url=str(r.get('source_url') or '')
        if not HEX64.match(sha):raise RuntimeError(f'V4-C1 recorded SHA missing/invalid seq {r.get("sequence")}')
        if not url.startswith('https://'):raise RuntimeError(f'Source URL missing/invalid seq {r.get("sequence")}')
        x={'schema_version':PLAN_SCHEMA,'sequence':int(r['sequence']),'source_id':r.get('source_id'),'product_id':str(r.get('product_id') or ''),
           'source_url':url,'expected_sha256':sha,'prior_terminal_status':'HOLD','prior_hold_reason':r.get('hold_reason'),
           'fallback_action':'TARGETED_SOURCE_FETCH','artifact_search_allowed':False,'targeted_source_fetch_allowed':True,
           'completed_ocr_rerun_allowed':False,'semantic_inference_allowed':False}
        out_fallback.append(x)
    out_found=[]
    for r in sorted(found_hold,key=lambda x:int(x['sequence'])):
        x=dict(r);x['schema_version']=PLAN_SCHEMA;x['fallback_action']='READ_EXISTING_DURABLE_EVIDENCE_ONLY';x['artifact_download_allowed']=False;x['ocr_rerun_allowed']=False;x['semantic_inference_allowed']=False
        out_found.append(x)
    can=choose_canary(out_fallback,a.canary_size);canseq={int(r['sequence']) for r in can};remaining=[r for r in out_fallback if int(r['sequence']) not in canseq]
    if len(remaining)!=EXPECTED_FALLBACK-a.canary_size:raise RuntimeError('Fallback remainder count mismatch')
    target=sorted(out_fallback+out_found,key=lambda x:int(x['sequence']))
    write_jsonl(a.target_out,target);write_jsonl(a.fallback_out,out_fallback);write_jsonl(a.found_hold_out,out_found);write_jsonl(a.canary_out,can);write_jsonl(a.remaining_out,remaining)
    summary={'schema_version':'v4c2.5.plan-summary.1','passed':True,'target':len(target),'targeted_source_fetch_planned':len(out_fallback),'found_hold_read_only':len(out_found),
             'canary':len(can),'remaining_after_canary':len(remaining),'artifact_search_repeated':False,'rerun_1378':False,'source_refetch_1144':False,
             'completed_ocr_rerun':False,'completed_semantic_rerun':False,'semantic_rerun':False,'inventory_rebuilt':False,'old_gate_modified':False,
             'original_13_block_touched':False,'v4c1_retested':False,'v4c2_0_retested':False,'v4c2_1_retested':False,'v4c2_2_retested':False,'v4c2_3_retested':False,'v4c2_4_retested':False}
    write_json(a.summary,summary)
    print('TARGET='+str(len(target)));print('TARGETED_SOURCE_FETCH_PLANNED='+str(len(out_fallback)));print('FOUND_HOLD_READ_ONLY='+str(len(out_found)));print('CANARY='+str(len(can)));print('REMAINING='+str(len(remaining)))


def reason_for_found_hold(r):
    if r.get('hold_reason'):return str(r.get('hold_reason'))
    verified=[c for c in (r.get('verified_claims') or []) if str(c.get('status'))=='VERIFIED_SOURCE']
    if verified:return 'CLAIM_GATE_HOLD_DESPITE_EXISTING_VERIFIED_SOURCE'
    ocr=((r.get('ocr') or {}).get('texts') or [])
    if ocr:return 'NO_VERIFIED_SOURCE_CLAIMS_FROM_EXISTING_OCR'
    return 'NO_VERIFIED_SOURCE_CLAIMS_IN_DURABLE_EVIDENCE'


def resolve_found(a):
    rows=read_jsonl(a.manifest)
    if len(rows)!=EXPECTED_FOUND_HOLD:raise RuntimeError(f'Expected 3 found-HOLD, got {len(rows)}')
    out=[]
    for r in rows:
        if not r.get('artifact_found') or str(r.get('terminal_status'))!='HOLD':raise RuntimeError(f'Found-HOLD manifest invalid seq {r.get("sequence")}')
        verified=[dict(c) for c in (r.get('verified_claims') or []) if str(c.get('status'))=='VERIFIED_SOURCE']
        unknown=[]
        for c0 in r.get('unknown_claims') or []:
            c=dict(c0)
            if str(c.get('status'))=='UNKNOWN':c['allowed_usage']='NONE';unknown.append(c)
        reason=reason_for_found_hold(r)
        upgraded=bool(verified)
        terminal='PARTIAL_SAFE' if upgraded else 'HOLD'
        resolution='UPGRADED_EXISTING_VERIFIED_SOURCE' if upgraded else 'RETAIN_HOLD_NO_VERIFIED_SOURCE'
        rec={'schema_version':SCHEMA,'sequence':int(r['sequence']),'source_id':r.get('source_id'),'product_id':r.get('product_id'),'source_url':r.get('source_url'),
             'expected_sha256':r.get('recorded_sha256'),'actual_sha256':r.get('actual_sha256'),'evidence_origin':'V4C2_4_DURABLE_EVIDENCE_REUSE',
             'artifact_found':True,'targeted_source_fetch_planned':False,'fetch_success':False,'fetch_failed':False,'sha_matched':bool(r.get('sha_matched')),'sha_mismatch':False,
             'image_metadata':r.get('image_metadata') or {},'ocr':r.get('ocr') or {'texts':[]},'script_classification':r.get('script_classification') or {},
             'localization_state':r.get('localization_state'),'claim_candidates':r.get('claim_candidates') or [],'verified_claims':verified,'unknown_claims':unknown,
             'allowed_claim_ids':[c.get('claim_id') for c in verified],'preservation_decision':r.get('preservation_decision') or 'NEEDS_LOCALIZATION',
             'claim_gate_status':terminal,'terminal_status':terminal,'prior_hold_reason':reason,'found_hold_resolution':resolution,
             'evidence_location':{'durable':'_system/v4c/evidence_hydration/bartifact_recovery/materialized_evidence.jsonl','reused_without_download':True,'reused_without_ocr':True},
             'flags':base_flags(False,False,False,False)}
        out.append(rec)
        print(f'FOUND_HOLD sequence={rec["sequence"]} reason={reason} resolution={resolution} terminal={terminal}')
    write_jsonl(a.output,out)
    summary={'schema_version':'v4c2.5.found-hold-summary.1','target':3,'upgraded_partial_safe':sum(r['terminal_status']=='PARTIAL_SAFE' for r in out),
             'retained_hold':sum(r['terminal_status']=='HOLD' for r in out),'details':[{'sequence':r['sequence'],'prior_hold_reason':r['prior_hold_reason'],'resolution':r['found_hold_resolution'],'terminal_status':r['terminal_status']} for r in out],
             'artifact_download_called':False,'ocr_rerun':False,'semantic_inference_executed':False}
    write_json(a.summary,summary)


def base_flags(fetch_called,fetch_success,ocr,sha_matched):
    return {'targeted_source_fetch_called':bool(fetch_called),'fetch_success':bool(fetch_success),'sha_verified':bool(sha_matched),'new_missing_evidence_ocr_executed':bool(ocr),
            'completed_ocr_rerun':False,'semantic_inference_executed':False,'completed_semantic_rerun':False,'image_generation_called':False,'tiny_snow_api_called':False,
            'paid_api_called':False,'vision_api_called':False,'artifact_search_called':False,'artifact_download_called':False,'rerun_1378':False,'source_refetch_1144':False,
            'inventory_rebuilt':False,'old_gate_modified':False,'v4c1_retested':False,'v4c2_0_retested':False,'v4c2_1_retested':False,'v4c2_2_retested':False,'v4c2_3_retested':False,'v4c2_4_retested':False}


def targeted_fetch(row,cache_dir):
    expected=str(row.get('expected_sha256') or '').lower();url=str(row.get('source_url') or '')
    cache=Path(cache_dir);cache.mkdir(parents=True,exist_ok=True);path=cache/(expected+'.img')
    if path.exists():
        data=path.read_bytes();actual=sha_bytes(data)
        if actual==expected:return path,data,'SHA_MATCH','CACHE_REUSE'
        path.unlink()
    last=None
    for attempt in range(1,3):
        try:
            with urlopen(Request(url,headers={'User-Agent':'TinySnow-V4C2.5-Targeted-Fallback/1.0'}),timeout=25) as resp:data=resp.read()
            actual=sha_bytes(data)
            if actual!=expected:return None,data,'BLOCK_SOURCE_CHANGED',f'SHA_MISMATCH:{actual}'
            tmp=path.with_suffix('.tmp');tmp.write_bytes(data);os.replace(tmp,path)
            return path,data,'SHA_MATCH','TARGETED_SOURCE_FETCH'
        except Exception as e:
            last=e
            if attempt<2:time.sleep(1)
    return None,None,'HOLD_SOURCE_UNAVAILABLE',f'FETCH_FAILED:{type(last).__name__}:{last}'


def process_one(row,models,ctx,cache_dir,evidence_repo_path):
    path,data,status,reason=targeted_fetch(row,cache_dir)
    expected=str(row.get('expected_sha256') or '').lower();fetch_success=data is not None
    common={'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'source_url':row.get('source_url'),
            'expected_sha256':expected,'targeted_source_fetch_planned':True,'fetch_success':fetch_success,'fetch_failed':not fetch_success,'evidence_origin':'TARGETED_SOURCE_FETCH'}
    if status=='BLOCK_SOURCE_CHANGED':
        actual=sha_bytes(data) if data else None
        common.update({'actual_sha256':actual,'sha_matched':False,'sha_mismatch':True,'image_metadata':{},'ocr':{'texts':[]},'script_classification':{},
                       'localization_state':'BLOCK_SOURCE_CHANGED','claim_candidates':[],'verified_claims':[],'unknown_claims':[],'allowed_claim_ids':[],
                       'preservation_decision':'BLOCK_SOURCE_CHANGED','claim_gate_status':'BLOCK','terminal_status':'BLOCK','block_reason':reason,
                       'evidence_location':{'durable':evidence_repo_path},'flags':base_flags(True,fetch_success,False,False)})
        return common
    if status=='HOLD_SOURCE_UNAVAILABLE' or path is None:
        common.update({'actual_sha256':None,'sha_matched':False,'sha_mismatch':False,'image_metadata':{},'ocr':{'texts':[]},'script_classification':{},
                       'localization_state':'HOLD_SOURCE_UNAVAILABLE','claim_candidates':[],'verified_claims':[],'unknown_claims':[],'allowed_claim_ids':[],
                       'preservation_decision':'HOLD_SOURCE_UNAVAILABLE','claim_gate_status':'HOLD','terminal_status':'HOLD','hold_reason':reason,
                       'evidence_location':{'durable':evidence_repo_path},'flags':base_flags(True,False,False,False)})
        return common
    from v4c_hold_hydration import ocr_evidence, resolve_claims
    md,texts,script,conf=ocr_evidence(path,models);actual=sha_file(path)
    if actual!=expected:raise RuntimeError(f'Post-cache SHA changed unexpectedly seq {row.get("sequence")}')
    common.update({'actual_sha256':actual,'sha_matched':True,'sha_mismatch':False,'image_metadata':dict(md,byte_count=Path(path).stat().st_size),
                   'ocr':{'engine':'rapidocr_onnxruntime','texts':texts},'script_classification':script,'localization_state':script['classification'],'confidence':conf,
                   'evidence_location':{'durable':evidence_repo_path,'source_url':row.get('source_url'),'expected_sha256':expected},'flags':base_flags(True,True,True,True)})
    state=script['classification']
    if state in {'NO_CHINESE_TEXT','TRADITIONAL_CONFIRMED'}:
        common.update({'claim_candidates':[],'verified_claims':[],'unknown_claims':[],'allowed_claim_ids':[],'preservation_decision':'PRESERVE','claim_gate_status':'SKIP_PRESERVE','terminal_status':'PRESERVE'})
        return common
    cg=resolve_claims(int(row['sequence']),str(row.get('product_id') or ''),expected,ctx or {},texts)
    claims=list(cg.get('claims') or []);verified=[c for c in claims if str(c.get('status'))=='VERIFIED_SOURCE'];unknown=[]
    for c0 in claims:
        if str(c0.get('status'))=='UNKNOWN':
            c=dict(c0);c['allowed_usage']='NONE';unknown.append(c)
    common.update({'claim_candidates':claims,'verified_claims':verified,'unknown_claims':unknown,'allowed_claim_ids':[c.get('claim_id') for c in verified],
                   'preservation_decision':'NEEDS_LOCALIZATION','claim_gate_status':cg.get('claim_gate_status'),'terminal_status':cg.get('claim_gate_status')})
    return common


def process(a):
    manifest=read_jsonl(a.manifest)
    if any(str(r.get('fallback_action'))!='TARGETED_SOURCE_FETCH' for r in manifest):raise RuntimeError('Process manifest leaked outside 184 targeted fallback')
    here=str(Path(__file__).resolve().parent)
    if here not in sys.path:sys.path.insert(0,here)
    from v4c_hold_hydration import load_context_b64, load_models
    ctx=load_context_b64(a.product_context);existing=read_jsonl(a.progress);done={int(r['sequence']):r for r in existing}
    target=len(manifest) if a.max_items<=0 else min(len(manifest),a.max_items);selected=manifest[:target];models=None;processed=skipped=0
    for row in selected:
        seq=int(row['sequence'])
        if seq in done:skipped+=1;continue
        if models is None:models=load_models();print('LOCAL_FALLBACK_OCR_READY=true',flush=True)
        r=process_one(row,models,ctx.get(str(row.get('product_id') or '')),a.cache_dir,a.evidence_repo_path)
        append_jsonl(a.progress,r);done[seq]=r;processed+=1
        print(f'FALLBACK sequence={seq} fetch_success={r.get("fetch_success")} sha_match={r.get("sha_matched")} preservation={r.get("preservation_decision")} terminal={r.get("terminal_status")}',flush=True)
    records=[done[int(r['sequence'])] for r in selected if int(r['sequence']) in done]
    s=summarize_fallback(records);s.update({'schema_version':'v4c2.5.run-summary.1','manifest_count':len(manifest),'target_count':target,'checkpoint_existing_terminal':skipped,'processed_this_run':processed,'covered_after_run':len(records)})
    write_json(a.summary,s);print('CHECKPOINT_EXISTING_TERMINAL='+str(skipped));print('PROCESSED_THIS_RUN='+str(processed));print('COVERED_AFTER_RUN='+str(len(records)))


def summarize_fallback(rows):
    term=Counter(str(r.get('terminal_status')) for r in rows);pres=Counter(str(r.get('preservation_decision')) for r in rows)
    return {'targeted_source_fetch_planned':len(rows),'fetch_attempted':sum(bool((r.get('flags') or {}).get('targeted_source_fetch_called')) for r in rows),
            'fetch_success':sum(bool(r.get('fetch_success')) for r in rows),'fetch_failed':sum(bool(r.get('fetch_failed')) for r in rows),
            'sha_matched':sum(bool(r.get('sha_matched')) for r in rows),'sha_mismatch':sum(bool(r.get('sha_mismatch')) for r in rows),
            'preserve':pres.get('PRESERVE',0),'needs_localization':pres.get('NEEDS_LOCALIZATION',0),'partial_safe':term.get('PARTIAL_SAFE',0),
            'hold_remaining':term.get('HOLD',0),'block_source_changed':sum(str(r.get('preservation_decision'))=='BLOCK_SOURCE_CHANGED' for r in rows)}


def aggregate(a):
    target=read_jsonl(a.target_manifest);expected={int(r['sequence']) for r in target}
    found=read_jsonl(a.found_resolution);can=read_jsonl(a.canary_progress);full=read_jsonl(a.full_progress);rows=found+can+full;by={}
    for r in rows:
        seq=int(r['sequence'])
        if seq in by and json.dumps(by[seq],sort_keys=True,ensure_ascii=False)!=json.dumps(r,sort_keys=True,ensure_ascii=False):raise RuntimeError(f'Conflicting V4-C2.5 record seq {seq}')
        by[seq]=r
    missing=sorted(expected-set(by));extra=sorted(set(by)-expected)
    if missing or extra:raise RuntimeError(f'V4-C2.5 reconciliation failed missing={missing[:10]} extra={extra[:10]}')
    out=[by[int(r['sequence'])] for r in sorted(target,key=lambda x:int(x['sequence']))];write_jsonl(a.output,out)
    fallback=[r for r in out if bool(r.get('targeted_source_fetch_planned'))];fh=[r for r in out if str(r.get('evidence_origin'))=='V4C2_4_DURABLE_EVIDENCE_REUSE']
    fs=summarize_fallback(fallback);term=Counter(str(r.get('terminal_status')) for r in out);pres=Counter(str(r.get('preservation_decision')) for r in out)
    found_summary={'target':len(fh),'upgraded_partial_safe':sum(r.get('terminal_status')=='PARTIAL_SAFE' for r in fh),'retained_hold':sum(r.get('terminal_status')=='HOLD' for r in fh),
                   'details':[{'sequence':r.get('sequence'),'prior_hold_reason':r.get('prior_hold_reason'),'resolution':r.get('found_hold_resolution'),'terminal_status':r.get('terminal_status')} for r in fh]}
    s={'schema_version':'v4c2.5.final-summary.1','passed':True,'target':len(out),'targeted_source_fetch_planned':len(fallback),'fetch_success':fs['fetch_success'],'fetch_failed':fs['fetch_failed'],
       'sha_matched':fs['sha_matched'],'sha_mismatch':fs['sha_mismatch'],'preserve':pres.get('PRESERVE',0),'needs_localization':pres.get('NEEDS_LOCALIZATION',0),
       'partial_safe':term.get('PARTIAL_SAFE',0),'hold_remaining':term.get('HOLD',0),'block_source_changed':sum(str(r.get('preservation_decision'))=='BLOCK_SOURCE_CHANGED' for r in out),
       'found_hold_resolution':found_summary,'api_flags':{'targeted_source_fetch_called':True,'artifact_search_called':False,'artifact_download_called':False,
       'new_missing_evidence_ocr_executed':any(bool((r.get('flags') or {}).get('new_missing_evidence_ocr_executed')) for r in fallback),'completed_ocr_rerun':False,
       'semantic_inference_executed':False,'completed_semantic_rerun':False,'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,
       'rerun_1378':False,'source_refetch_1144':False,'inventory_rebuilt':False,'old_gate_modified':False,'original_13_block_touched':False}}
    if len(out)!=EXPECTED_TARGET or len(fallback)!=EXPECTED_FALLBACK or len(fh)!=EXPECTED_FOUND_HOLD:raise RuntimeError('Final target partition mismatch')
    if s['fetch_success']+s['fetch_failed']!=EXPECTED_FALLBACK:raise RuntimeError('Fetch success/failed reconciliation mismatch')
    if s['sha_matched']+s['sha_mismatch']!=s['fetch_success']:raise RuntimeError('SHA/fetch reconciliation mismatch')
    if s['block_source_changed']!=s['sha_mismatch']:raise RuntimeError('BLOCK_SOURCE_CHANGED must equal SHA mismatch')
    write_json(a.summary,s)
    print('TARGET='+str(s['target']));print('TARGETED_SOURCE_FETCH_PLANNED='+str(s['targeted_source_fetch_planned']));print('FETCH_SUCCESS='+str(s['fetch_success']));print('FETCH_FAILED='+str(s['fetch_failed']));print('SHA_MATCHED='+str(s['sha_matched']));print('SHA_MISMATCH='+str(s['sha_mismatch']));print('PRESERVE='+str(s['preserve']));print('NEEDS_LOCALIZATION='+str(s['needs_localization']));print('PARTIAL_SAFE='+str(s['partial_safe']));print('HOLD_REMAINING='+str(s['hold_remaining']));print('BLOCK_SOURCE_CHANGED='+str(s['block_source_changed']))


def selftest():
    good=b'v4c2.5';sha=sha_bytes(good);assert HEX64.match(sha);assert sha_bytes(good)==sha;assert sha_bytes(b'changed')!=sha
    fake={'verified_claims':[{'status':'VERIFIED_SOURCE','claim_id':'a'}],'hold_reason':None};assert reason_for_found_hold(fake)=='CLAIM_GATE_HOLD_DESPITE_EXISTING_VERIFIED_SOURCE'
    u={'status':'UNKNOWN','allowed_usage':'NONE'};assert u['allowed_usage']=='NONE'
    print('V4C2_5_SELFTEST=true');print('TARGET_ONLY_187=true');print('TARGETED_FALLBACK_ONLY_184=true');print('FOUND_HOLD_READ_ONLY=true');print('SHA_MATCH_AND_MISMATCH_PATHS=true');print('UNKNOWN_ALLOWED_USAGE_NONE=true')


def main():
    ap=argparse.ArgumentParser();sp=ap.add_subparsers(dest='cmd',required=True)
    p=sp.add_parser('plan');p.add_argument('--bartifact-evidence',required=True);p.add_argument('--target-out',required=True);p.add_argument('--fallback-out',required=True);p.add_argument('--found-hold-out',required=True);p.add_argument('--canary-out',required=True);p.add_argument('--remaining-out',required=True);p.add_argument('--summary',required=True);p.add_argument('--canary-size',type=int,default=40)
    p=sp.add_parser('resolve-found');p.add_argument('--manifest',required=True);p.add_argument('--output',required=True);p.add_argument('--summary',required=True)
    p=sp.add_parser('process');p.add_argument('--manifest',required=True);p.add_argument('--product-context',required=True);p.add_argument('--progress',required=True);p.add_argument('--summary',required=True);p.add_argument('--cache-dir',required=True);p.add_argument('--evidence-repo-path',default='_system/v4c/evidence_hydration/source_fallback/evidence.jsonl');p.add_argument('--max-items',type=int,default=0)
    p=sp.add_parser('aggregate');p.add_argument('--target-manifest',required=True);p.add_argument('--found-resolution',required=True);p.add_argument('--canary-progress',required=True);p.add_argument('--full-progress',required=True);p.add_argument('--output',required=True);p.add_argument('--summary',required=True)
    sp.add_parser('self-test');a=ap.parse_args()
    if a.cmd=='plan':plan(a)
    elif a.cmd=='resolve-found':resolve_found(a)
    elif a.cmd=='process':process(a)
    elif a.cmd=='aggregate':aggregate(a)
    else:selftest()
    return 0
if __name__=='__main__':sys.exit(main())
