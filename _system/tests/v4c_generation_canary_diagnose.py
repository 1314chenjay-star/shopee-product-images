#!/usr/bin/env python3
import hashlib, json
from collections import Counter, defaultdict
from pathlib import Path

BASE_HEAD='75b6db8431f14dba934cf8d6f92042429fafd865'
STABLE_HEAD='5d49f061e140813b3d229520e9e530f86b27b640'
EXPECTED_SLOTS=549
EXPECTED_PRODUCTS=145
LOCKED={'42833435408','52915734564','57565745174','58015741169'}
ROOT=Path('_system/v4c/generation_payload')
EXEC=ROOT/'execution_ready_queue.jsonl'
PAYLOAD=ROOT/'provider_neutral_payload.jsonl'
READY=ROOT/'product_execution_readiness.jsonl'
PLAN=Path('_system/v4c/generation_plan/product_5slot_plan.jsonl')
CAL=Path('_system/v4c/claim_gate/calibration/calibration_manifest.jsonl')
OUT=Path('_system/v4c/generation_canary_preflight')

def read_jsonl(p):
    rows=[]
    with Path(p).open(encoding='utf-8-sig') as f:
        for i,line in enumerate(f,1):
            if line.strip(): rows.append(json.loads(line))
    return rows

def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()

def key(pid,slot): return str(pid)+':'+str(slot)
def category_bucket(meta):
    sub=str(meta.get('subcategory') or '').lower(); fam=str(meta.get('family') or '').lower()
    if 'apparel' in sub or 'clothes' in sub: return 'apparel'
    if 'bag' in sub: return 'bags'
    if 'footwear' in sub or 'shoe' in sub: return 'footwear'
    if 'outdoor' in sub or 'camp' in sub: return 'outdoor'
    if fam=='sports' or sub: return 'sports'
    return 'general_merchandise'

def load_taxonomy():
    out={}
    if CAL.exists():
        for r in read_jsonl(CAL):
            pid=str(r.get('product_id') or ''); c=r.get('context') or {}
            if pid and pid not in out and (c.get('family') or c.get('subcategory')):
                out[pid]={'family':c.get('family') or 'unclassified','subcategory':c.get('subcategory') or 'unclassified'}
    return out

def localize_needed(p):
    for x in p.get('display_text_allowlist') or []:
        src=str(x.get('source_text') or '').strip(); dst=str(x.get('text') or '').strip()
        if src and dst and src!=dst: return True
    return False

def low_text(p):
    return len([x for x in (p.get('display_text_allowlist') or []) if str(x.get('text') or '').strip()])<=1

def feasibility(products):
    # state=(product_count,paid_slots,feature_mask), keep one deterministic product list
    # bits: derivative,variant,localization,low_text,risk_guard
    bits={'derivative':1,'variant':2,'localization':4,'low_text':8,'risk_guard':16}
    dp={(0,0,0):[]}
    for p in products:
        mask=0
        for n,b in bits.items():
            if p[n]: mask|=b
        updates={}
        for (cnt,slots,m),chosen in list(dp.items()):
            if cnt>=5 or slots+p['paid_slots']>20: continue
            ns=(cnt+1,slots+p['paid_slots'],m|mask); cand=chosen+[p['product_id']]
            if ns not in dp and (ns not in updates or cand<updates[ns]): updates[ns]=cand
        dp.update(updates)
    complete=[]
    for (cnt,slots,m),chosen in dp.items():
        if 1<=cnt<=5 and 15<=slots<=20 and m==31:
            complete.append({'product_count':cnt,'paid_slots':slots,'product_ids':chosen})
    complete.sort(key=lambda x:(-len(x['product_ids']),x['paid_slots'],x['product_ids']))
    return {'feasible':bool(complete),'example':complete[0] if complete else None,'state_count':len(dp)}

def main():
    execution=read_jsonl(EXEC); payloads=read_jsonl(PAYLOAD); readiness=read_jsonl(READY); plans=read_jsonl(PLAN); tax=load_taxonomy()
    if len(execution)!=EXPECTED_SLOTS: raise RuntimeError(f'execution ready count changed {len(execution)}')
    ready_products={str(r['product_id']) for r in readiness if r.get('status')=='PRODUCT_READY_FOR_GENERATION'}
    if len(ready_products)!=EXPECTED_PRODUCTS: raise RuntimeError(f'ready product count changed {len(ready_products)}')
    if any(str(r.get('product_id')) in LOCKED for r in execution): raise RuntimeError('locked product leaked into execution-ready queue')
    pmap={key((p.get('identity') or {}).get('product_id'),(p.get('identity') or {}).get('slot')):p for p in payloads}
    by=defaultdict(list); missing_payload=[]
    for q in execution:
        pid=str(q['product_id']); slot=str(q['slot_role']); p=pmap.get(key(pid,slot))
        if p is None: missing_payload.append(key(pid,slot)); continue
        by[pid].append((q,p))
    if missing_payload: raise RuntimeError('missing provider payloads: '+','.join(missing_payload[:10]))
    products=[]
    for pid,rows in sorted(by.items()):
        meta=tax.get(pid,{'family':'unclassified','subcategory':'unclassified'}); bucket=category_bucket(meta)
        products.append({
            'product_id':pid,'paid_slots':len(rows),'category':meta['family'],'subcategory':meta['subcategory'],'category_bucket':bucket,
            'derivative':any(q.get('action')=='SAFE_DERIVATIVE' for q,p in rows),
            'variant':any(bool(q.get('variant_scope')) for q,p in rows),
            'localization':any(localize_needed(p) for q,p in rows),
            'low_text':any(low_text(p) for q,p in rows),
            'risk_guard':any(bool(p.get('category_risk_guards')) for q,p in rows),
            'variant_scopes':[q.get('variant_scope') for q,p in rows if q.get('variant_scope')],
            'actions':dict(Counter(q.get('action') for q,p in rows))
        })
    hist=Counter(p['paid_slots'] for p in products); buckets=Counter(p['category_bucket'] for p in products)
    variant_products=[p['product_id'] for p in products if p['variant']]
    variant_slots=[{'product_id':str(q['product_id']),'slot_role':q['slot_role'],'source_sequence':q['source_sequence'],'variant_scope':q.get('variant_scope')} for q in execution if q.get('variant_scope')]
    derivative_products=[p['product_id'] for p in products if p['derivative']]
    localization_products=[p['product_id'] for p in products if p['localization']]
    low_text_products=[p['product_id'] for p in products if p['low_text']]
    risk_products=[p['product_id'] for p in products if p['risk_guard']]
    feasible=feasibility(products)
    blocker=None
    if not variant_products: blocker='BLOCK_NO_READY_VARIANT_CANARY_SAMPLE'
    elif not feasible['feasible']: blocker='BLOCK_NO_SAFE_CANARY_COMBINATION_WITHIN_5_PRODUCTS_20_REQUESTS'
    report={
      'schema_version':'v4c5.1.canary-preflight-availability.1','passed':blocker is None,'execution_authorized_by_preflight':blocker is None,'blocker':blocker,
      'base_head':BASE_HEAD,'stable_head':STABLE_HEAD,'frozen_execution_ready_slots':len(execution),'frozen_ready_products':len(ready_products),
      'variant_ready_slots':len(variant_slots),'variant_ready_products':len(variant_products),'variant_product_ids':variant_products,'variant_slot_examples':variant_slots[:20],
      'safe_derivative_products':len(derivative_products),'safe_derivative_product_examples':derivative_products[:20],
      'localization_products':len(localization_products),'localization_product_examples':localization_products[:20],
      'low_or_no_text_products':len(low_text_products),'low_or_no_text_product_examples':low_text_products[:20],
      'category_risk_guard_products':len(risk_products),'category_risk_guard_product_examples':risk_products[:20],
      'paid_slot_count_histogram':dict(sorted(hist.items())),'ready_category_bucket_counts':dict(sorted(buckets.items())),
      'selection_feasibility':feasible,'locked_products_in_execution_ready':0,
      'frozen_fingerprints':{'execution_ready_queue_sha256':sha(EXEC),'provider_neutral_payload_sha256':sha(PAYLOAD),'product_execution_readiness_sha256':sha(READY)},
      'paid_requests_sent':0,'generation_executed':False,'image_generation_api_called':False,'tiny_snow_api_called':False,'vision_api_called':False,'approved_memory_mutation':0,'bulk_generation_authorized':False
    }
    OUT.mkdir(parents=True,exist_ok=True); (OUT/'availability.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    # Keep a compact per-product feature matrix for audit; no source downloads or provider calls.
    with (OUT/'ready_product_feature_matrix.jsonl').open('w',encoding='utf-8',newline='\n') as f:
        for p in products: f.write(json.dumps(p,ensure_ascii=False,separators=(',',':'))+'\n')
    print(json.dumps(report,ensure_ascii=False,separators=(',',':')))
if __name__=='__main__': main()
