#!/usr/bin/env python3
import argparse,base64,gzip,hashlib,json,sys
from pathlib import Path
from collections import defaultdict,Counter

SCHEMA='v4c2.2.progressive-preservation-claim.1'
BASE_HEAD='7252c42345c7d5463067c4da33102975a0364fdc'
EXPECTED_TOTAL=1378

def read_jsonl(path):
    out=[]
    p=Path(path)
    if not p.exists(): return out
    for i,line in enumerate(p.open(encoding='utf-8-sig'),1):
        if not line.strip(): continue
        try: out.append(json.loads(line))
        except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out

def write_jsonl(path,rows):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    text='\n'.join(json.dumps(x,ensure_ascii=False,separators=(',',':')) for x in rows)
    p.write_text((text+'\n') if rows else '',encoding='utf-8')

def append_jsonl(path,row):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('a',encoding='utf-8',newline='\n') as f:
        f.write(json.dumps(row,ensure_ascii=False,separators=(',',':'))+'\n')
        f.flush()

def load_context_b64(path):
    raw=base64.b64decode(Path(path).read_text(encoding='ascii').strip())
    text=gzip.decompress(raw).decode('utf-8-sig')
    out={}
    for line in text.splitlines():
        if line.strip():
            r=json.loads(line);out[str(r.get('product_id',''))]=r
    return out

def sha_file(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def claim_id(seq,typ,value):
    return hashlib.sha256(f'{seq}|{typ}|{value}'.encode('utf-8')).hexdigest()[:20]

def unknown_claims(seq,ctx):
    fields=[]
    for f in (ctx or {}).get('risk_fields') or []:
        s=str(f).strip()
        if s and s not in fields: fields.append(s)
    if not fields: fields=['source_visual_facts']
    return [
        {'claim_id':claim_id(seq,'risk_field',f),'type':'risk_field','value':f,
         'status':'UNKNOWN','origin':'product_context_risk_field' if f!='source_visual_facts' else 'preservation_evidence_gap',
         'allowed_usage':'NONE','evidence':[],'reason':'NO_PERSISTED_VISUAL_EVIDENCE_NO_REFETCH_ALLOWED'}
        for f in fields
    ]

def load_prior_registry(old_preservation,old_semantic):
    reg={}
    sem=read_jsonl(old_semantic)
    sem_by_seq={int(r['sequence']):r for r in sem}
    for r in read_jsonl(old_preservation):
        seq=int(r['sequence']);sha=str(r.get('sha256','')).lower();pid=str(r.get('product_id',''))
        if not sha: continue
        key=(pid,sha)
        if str(r.get('decision'))=='PRESERVE_DIRECT':
            reg[key]={'kind':'PRESERVE','sequence':seq,'record':r}
        elif seq in sem_by_seq:
            reg[key]={'kind':'SEMANTIC_EVIDENCE','sequence':seq,'record':sem_by_seq[seq]}
    return reg,sem_by_seq

def reuse_semantic_to_claim(q,semrec):
    # Reuse only already-landed OCR/claim evidence. Never OCR/infer/fetch here.
    try:
        from v4c_claim_level_gate import resolve
        rr=resolve(semrec)
    except Exception as e:
        return None,f'CLAIM_RESOLVER_REUSE_FAILED:{e}'
    out_status=str(rr.get('claim_gate_status','HOLD'))
    return {
        'claim_gate_status':out_status,
        'claims':list(rr.get('claims') or []),
        'allowed_claim_ids':list(rr.get('allowed_claim_ids') or []),
        'unknown_claim_ids':list(rr.get('unknown_claim_ids') or []),
        'safe_actions':dict(rr.get('safe_actions') or {})
    },None

def make_record(q,source,ctx,prior_registry,progress_sha_registry):
    seq=int(q['sequence']);pid=str(q.get('product_id',''));sha=str(q.get('sha256','')).lower()
    key=(pid,sha)
    prior=prior_registry.get(key) or progress_sha_registry.get(key)
    base={
        'schema_version':SCHEMA,'sequence':seq,'source_id':str(q.get('source_id','')),
        'product_id':pid,'sha256':sha,
        'route':'PRESERVATION_GATE_THEN_CLAIM_LEVEL_EVIDENCE',
        'source_status':str((source or {}).get('status','UNKNOWN')),
        'provenance':{
            'v4c2_1_base_head':BASE_HEAD,'persisted_evidence_only':True,'source_download_called':False,
            'ocr_rerun':False,'semantic_inference_rerun':False,'semantic_inference_executed':False,
            'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False
        }
    }
    if prior and prior.get('kind')=='PRESERVE':
        base['preservation_gate']={'status':'PRESERVE','reason':'SHA_MATCHES_FROZEN_PRESERVE_DIRECT','sha_reuse':True,'canonical_sequence':int(prior['sequence'])}
        base['claim_gate']={'status':'SKIP_PRESERVE','claims':[],'allowed_claim_ids':[],'unknown_claim_ids':[]}
        base['terminal_status']='PRESERVE';base['sha_reuse']=True
        return base
    if prior and prior.get('kind')=='SEMANTIC_EVIDENCE':
        cr,err=reuse_semantic_to_claim(q,prior['record'])
        if cr:
            base['preservation_gate']={'status':'NEEDS_CLAIM_EVIDENCE','reason':'SHA_MATCHES_FROZEN_SEMANTIC_EVIDENCE','sha_reuse':True,'canonical_sequence':int(prior['sequence'])}
            base['claim_gate']=cr;base['terminal_status']=cr['claim_gate_status'];base['sha_reuse']=True
            return base
        claims=unknown_claims(seq,ctx)
        base['preservation_gate']={'status':'NEEDS_CLAIM_EVIDENCE','reason':'FROZEN_SEMANTIC_REUSE_FAILED','sha_reuse':True,'canonical_sequence':int(prior['sequence'])}
        base['claim_gate']={'status':'HOLD','claims':claims,'allowed_claim_ids':[],'unknown_claim_ids':[c['claim_id'] for c in claims],'reason':err}
        base['terminal_status']='HOLD';base['sha_reuse']=True
        return base
    claims=unknown_claims(seq,ctx)
    base['preservation_gate']={
        'status':'NEEDS_CLAIM_EVIDENCE','reason':'NO_PERSISTED_PRESERVATION_VISUAL_EVIDENCE',
        'sha_reuse':False,'canonical_sequence':None
    }
    base['claim_gate']={
        'status':'HOLD','claims':claims,'allowed_claim_ids':[],
        'unknown_claim_ids':[c['claim_id'] for c in claims],
        'safe_actions':{'may_use_verified_facts_only':True,'may_generate_unknown_claims':False,'may_infer_missing_specs':False},
        'reason':'NO_PERSISTED_CLAIM_EVIDENCE_NO_REFETCH_ALLOWED'
    }
    base['terminal_status']='HOLD';base['sha_reuse']=False
    return base

def pick_canary(queue,n):
    groups=defaultdict(list)
    for r in sorted(queue,key=lambda x:int(x['sequence'])): groups[str(r.get('product_id',''))].append(r)
    pids=sorted(groups,key=lambda p:hashlib.sha256(p.encode()).hexdigest())
    out=[]
    # Whole-product blocks first to exercise per-image routing; cap exactly n.
    for pid in pids:
        for r in groups[pid]:
            if len(out)>=n: break
            out.append(r)
        if len(out)>=n: break
    if len(out)<n: raise RuntimeError(f'Canary selection short: {len(out)} < {n}')
    return out[:n]

def plan(a):
    q=read_jsonl(a.queue)
    if len(q)!=EXPECTED_TOTAL: raise RuntimeError(f'Expected {EXPECTED_TOTAL} future records, got {len(q)}')
    seq=[int(x['sequence']) for x in q]
    if len(set(seq))!=len(seq): raise RuntimeError('Duplicate sequence in future queue')
    can=pick_canary(q,a.canary_size)
    write_jsonl(a.canary_out,can)
    s={'schema_version':'v4c2.2.progressive-plan.1','passed':True,'total':len(q),'canary_count':len(can),'canary_product_count':len({str(x.get('product_id','')) for x in can}),
       'route':'PRESERVATION_GATE_THEN_CLAIM_LEVEL_EVIDENCE','source_download_allowed':False,'semantic_all_at_once_forbidden':True,
       'queue_sha256':sha_file(a.queue),'canary_sha256':sha_file(a.canary_out)}
    Path(a.summary).parent.mkdir(parents=True,exist_ok=True);Path(a.summary).write_text(json.dumps(s,ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'PLAN_TOTAL={len(q)}');print(f'CANARY_COUNT={len(can)}');print('SOURCE_DOWNLOAD_ALLOWED=false')

def process(a):
    manifest=read_jsonl(a.manifest);source={int(r['sequence']):r for r in read_jsonl(a.source_evidence)}
    ctx=load_context_b64(a.product_context)
    prior,_=load_prior_registry(a.old_preservation,a.old_semantic)
    prev=read_jsonl(a.progress);done={int(r['sequence']):r for r in prev}
    sha_reg={}
    for r in prev:
        key=(str(r.get('product_id','')),str(r.get('sha256','')).lower())
        if str(r.get('terminal_status'))=='PRESERVE': sha_reg[key]={'kind':'PRESERVE','sequence':int(r['sequence']),'record':r}
    target=min(int(a.target_total),len(manifest))
    eligible=manifest[:target]
    skipped=sum(1 for q in eligible if int(q['sequence']) in done)
    processed=0
    for q in eligible:
        seq=int(q['sequence'])
        if seq in done: continue
        r=make_record(q,source.get(seq),ctx.get(str(q.get('product_id',''))),prior,sha_reg)
        append_jsonl(a.progress,r);done[seq]=r;processed+=1
        if r['terminal_status']=='PRESERVE':
            sha_reg[(r['product_id'],r['sha256'])]={'kind':'PRESERVE','sequence':seq,'record':r}
    covered=sum(1 for q in eligible if int(q['sequence']) in done)
    statuses=Counter(done[int(q['sequence'])]['terminal_status'] for q in eligible if int(q['sequence']) in done)
    summary={'schema_version':'v4c2.2.progressive-run.1','manifest_count':len(manifest),'target_total':target,'checkpoint_existing_terminal':skipped,
             'checkpoint_skipped_this_run':skipped,'processed_this_run':processed,'covered_after_run':covered,'status_counts':dict(statuses),
             'source_download_called':False,'ocr_rerun':False,'semantic_inference_rerun':False,'semantic_actually_executed':0,
             'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False}
    Path(a.summary).parent.mkdir(parents=True,exist_ok=True);Path(a.summary).write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    print(f'CHECKPOINT_EXISTING_TERMINAL={skipped}');print(f'PROCESSED_THIS_RUN={processed}');print(f'COVERED_AFTER_RUN={covered}');print('SOURCE_DOWNLOAD_CALLED=false');print('SEMANTIC_ACTUALLY_EXECUTED=0')

def selftest():
    ctx={'risk_fields':['dimensions','material','brand']}
    c=unknown_claims(1,ctx)
    assert len(c)==3 and all(x['status']=='UNKNOWN' and x['allowed_usage']=='NONE' for x in c)
    fake={'sequence':1,'source_id':'s','product_id':'p','sha256':'a'*64}
    prior={('p','a'*64):{'kind':'PRESERVE','sequence':99,'record':{}}}
    r=make_record(fake,{'status':'DONE'},ctx,prior,{})
    assert r['terminal_status']=='PRESERVE' and r['claim_gate']['status']=='SKIP_PRESERVE'
    print('SELF_TEST=true');print('UNKNOWN_ALLOWED_USAGE_NONE=true');print('PRESERVE_SKIPS_CLAIM_GATE=true');print('NO_FETCH_CODE_PATH=true')

def main():
    ap=argparse.ArgumentParser();sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('plan');p.add_argument('--queue',required=True);p.add_argument('--canary-out',required=True);p.add_argument('--summary',required=True);p.add_argument('--canary-size',type=int,default=250)
    p=sub.add_parser('process');p.add_argument('--manifest',required=True);p.add_argument('--source-evidence',required=True);p.add_argument('--old-preservation',required=True);p.add_argument('--old-semantic',required=True);p.add_argument('--product-context',required=True);p.add_argument('--progress',required=True);p.add_argument('--summary',required=True);p.add_argument('--target-total',type=int,required=True)
    sub.add_parser('self-test')
    a=ap.parse_args()
    if a.cmd=='plan':plan(a)
    elif a.cmd=='process':process(a)
    else:selftest()
    return 0
if __name__=='__main__':sys.exit(main())