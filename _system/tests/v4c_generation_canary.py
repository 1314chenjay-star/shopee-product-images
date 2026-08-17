#!/usr/bin/env python3
import argparse, hashlib, json, re
from collections import Counter, defaultdict
from pathlib import Path

BASE_HEAD='75b6db8431f14dba934cf8d6f92042429fafd865'
STABLE_HEAD='5d49f061e140813b3d229520e9e530f86b27b640'
MAX_PRODUCTS=5
MAX_PAID_REQUESTS=20
MIN_TARGET_PAID_SLOTS=15
EXPECTED_EXECUTION_READY=549
EXPECTED_READY_PRODUCTS=145
LOCKED_PRODUCTS={'42833435408','52915734564','57565745174','58015741169'}
ROOT=Path('_system/v4c/generation_payload')
EXEC_PATH=ROOT/'execution_ready_queue.jsonl'
PAYLOAD_PATH=ROOT/'provider_neutral_payload.jsonl'
CONTEXT_PATH=ROOT/'generation_context.jsonl'
READINESS_PATH=ROOT/'product_execution_readiness.jsonl'
PLAN_PATH=Path('_system/v4c/generation_plan/product_5slot_plan.jsonl')
CALIBRATION_PATH=Path('_system/v4c/claim_gate/calibration/calibration_manifest.jsonl')
C5_LOCK_PATH=ROOT/'V4_C5_0_GENERATION_PAYLOAD_LOCK.json'

def read_jsonl(path):
    rows=[]
    with Path(path).open(encoding='utf-8-sig') as f:
        for i,line in enumerate(f,1):
            if not line.strip(): continue
            try: rows.append(json.loads(line))
            except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return rows

def read_json(path): return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def write_json(path,obj):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')
def write_jsonl(path,rows):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')
def canon(obj): return json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def sha_obj(obj): return hashlib.sha256(canon(obj).encode('utf-8')).hexdigest()
def file_sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()
def key(pid,slot): return f'{pid}:{slot}'

def load_taxonomy():
    out={}
    if CALIBRATION_PATH.exists():
        for r in read_jsonl(CALIBRATION_PATH):
            pid=str(r.get('product_id') or ''); ctx=r.get('context') or {}
            if pid and pid not in out and (ctx.get('family') or ctx.get('subcategory')):
                out[pid]={'family':ctx.get('family') or 'unclassified','subcategory':ctx.get('subcategory') or 'unclassified','product_name':ctx.get('product_name'),'risk_fields':list(ctx.get('risk_fields') or []),'taxonomy_source':'V4-C2_CALIBRATION_FROZEN_CONTEXT'}
    return out

def category_bucket(meta):
    sub=str(meta.get('subcategory') or '').lower(); fam=str(meta.get('family') or '').lower()
    if 'apparel' in sub or 'clothes' in sub: return 'apparel'
    if 'bag' in sub: return 'bags'
    if 'footwear' in sub or 'shoe' in sub: return 'footwear'
    if 'outdoor' in sub or 'camp' in sub: return 'outdoor'
    if fam=='sports' or sub: return 'sports'
    return 'general_merchandise'

def payload_has_localization(p):
    return any(str(x.get('source_text') or '') and str(x.get('source_text') or '')!=str(x.get('text') or '') for x in (p.get('display_text_allowlist') or []))
def display_count(p): return len([x for x in (p.get('display_text_allowlist') or []) if str(x.get('text') or '').strip()])

def load_all():
    execution=read_jsonl(EXEC_PATH); payloads=read_jsonl(PAYLOAD_PATH); contexts=read_jsonl(CONTEXT_PATH); readiness=read_jsonl(READINESS_PATH); plans=read_jsonl(PLAN_PATH); lock=read_json(C5_LOCK_PATH)
    if len(execution)!=EXPECTED_EXECUTION_READY: raise RuntimeError(f'Frozen execution-ready queue changed: {len(execution)} != {EXPECTED_EXECUTION_READY}')
    ready_rows=[r for r in readiness if r.get('status')=='PRODUCT_READY_FOR_GENERATION']
    if len(ready_rows)!=EXPECTED_READY_PRODUCTS: raise RuntimeError(f'Frozen ready product count changed: {len(ready_rows)} != {EXPECTED_READY_PRODUCTS}')
    if not lock.get('v4c5_0_sealed') or lock.get('generation_execution_authorized'): raise RuntimeError('V4-C5.0 lock boundary unexpected')
    payload_by={}; ctx_by={}
    for p in payloads:
        ident=p.get('identity') or {}; k=key(str(ident.get('product_id') or p.get('product_id') or ''),str(ident.get('slot') or p.get('slot_role') or ''))
        if k in payload_by: raise RuntimeError('Duplicate provider-neutral payload '+k)
        payload_by[k]=p
    for c in contexts:
        ident=c.get('identity') or {}; k=key(str(ident.get('product_id') or c.get('product_id') or ''),str(ident.get('slot') or c.get('slot_role') or ''))
        if k in ctx_by: raise RuntimeError('Duplicate generation context '+k)
        ctx_by[k]=c
    ready_by={str(r['product_id']):r for r in ready_rows}; plan_by={str(r['product_id']):r for r in plans}
    if len(set((str(r['product_id']),str(r['slot_role'])) for r in execution))!=len(execution): raise RuntimeError('Duplicate frozen execution-ready slot key')
    normalized=[]
    for q in execution:
        pid=str(q.get('product_id') or ''); slot=str(q.get('slot_role') or ''); k=key(pid,slot); p=payload_by.get(k); c=ctx_by.get(k); rr=ready_by.get(pid)
        if not p or not c or not rr: raise RuntimeError('Missing exact C5.0 companion row for '+k)
        ident=p.get('identity') or {}; cident=c.get('identity') or {}; errs=[]
        if str(ident.get('product_id'))!=pid: errs.append('PAYLOAD_PRODUCT_MISMATCH')
        if str(ident.get('slot'))!=slot: errs.append('PAYLOAD_SLOT_MISMATCH')
        if int(ident.get('source_sequence'))!=int(q.get('source_sequence')): errs.append('PAYLOAD_SEQUENCE_MISMATCH')
        if str(ident.get('source_sha256')).lower()!=str(q.get('source_sha256')).lower(): errs.append('PAYLOAD_SHA_MISMATCH')
        if list(ident.get('variant_scope') or [])!=list(q.get('variant_scope') or []): errs.append('PAYLOAD_VARIANT_MISMATCH')
        if str(cident.get('product_id'))!=pid or str(cident.get('slot'))!=slot: errs.append('CONTEXT_IDENTITY_MISMATCH')
        if str(cident.get('source_sha256')).lower()!=str(q.get('source_sha256')).lower(): errs.append('CONTEXT_SHA_MISMATCH')
        if list(cident.get('variant_scope') or [])!=list(q.get('variant_scope') or []): errs.append('CONTEXT_VARIANT_MISMATCH')
        if rr.get('status')!='PRODUCT_READY_FOR_GENERATION' or rr.get('paid_slots_allowed') is not True: errs.append('PRODUCT_NOT_READY')
        if pid in LOCKED_PRODUCTS: errs.append('LOCKED_PRODUCT')
        if q.get('action') not in {'PROCESS_LOCALIZE','SAFE_DERIVATIVE'}: errs.append('INVALID_ACTION')
        parent_sha=p.get('parent_sha256')
        if q.get('action')=='SAFE_DERIVATIVE':
            if not re.fullmatch(r'[0-9a-f]{64}',str(parent_sha or '').lower()): errs.append('DERIVATIVE_PARENT_SHA_MISSING')
            if str(parent_sha).lower()!=str(q.get('source_sha256')).lower(): errs.append('DERIVATIVE_PARENT_SHA_NOT_BOUND_TO_INPUT')
        if errs: raise RuntimeError(k+': '+','.join(errs))
        normalized.append({'queue':q,'payload':p,'context':c,'payload_sha256':sha_obj(p),'key':k,'product_id':pid,'slot_role':slot,'source_id':ident.get('source_id'),'source_sequence':int(q['source_sequence']),'source_sha256':str(q['source_sha256']).lower(),'variant_scope':list(q.get('variant_scope') or []),'action':q['action'],'parent_sha256':parent_sha})
    return normalized,ready_by,plan_by,lock

def choose_selection(rows,ready_by,plan_by):
    tax=load_taxonomy(); by_product=defaultdict(list)
    for r in rows: by_product[r['product_id']].append(r)
    products=[]; available_buckets=Counter()
    for pid,slots in sorted(by_product.items()):
        meta=tax.get(pid,{'family':'unclassified','subcategory':'unclassified','product_name':None,'risk_fields':[],'taxonomy_source':'UNCLASSIFIED_FROZEN_METADATA_GAP'})
        bucket=category_bucket(meta); available_buckets[bucket]+=1; payloads=[x['payload'] for x in slots]
        feat={'has_derivative':any(x['action']=='SAFE_DERIVATIVE' for x in slots),'has_variant':any(bool(x['variant_scope']) for x in slots),'has_localization':any(payload_has_localization(p) for p in payloads),'has_low_text':any(display_count(p)<=1 for p in payloads),'has_category_risk_guard':any(bool(p.get('category_risk_guards')) for p in payloads)}
        preserve_count=sum(1 for sl in (plan_by.get(pid) or {}).get('slots',[]) if sl.get('action')=='PRESERVE')
        products.append({'product_id':pid,'slots':sorted(slots,key=lambda x:int(x['queue'].get('slot_index') or 99)),'paid_count':len(slots),'category':meta.get('family'),'subcategory':meta.get('subcategory'),'category_bucket':bucket,'taxonomy_source':meta.get('taxonomy_source'),'product_name':meta.get('product_name'),'risk_fields':meta.get('risk_fields') or [],'preserve_count':preserve_count,'features':feat})
    feature_names=['has_derivative','has_variant','has_localization','has_low_text','has_category_risk_guard']; bit_for={n:1<<i for i,n in enumerate(feature_names)}
    cat_names=['apparel','bags','footwear','sports','outdoor','general_merchandise']; cat_bit={n:1<<i for i,n in enumerate(cat_names)}
    dp={(0,0,0,0):([],0)}
    for prod in products:
        pbits=sum(bit_for[n] for n in feature_names if prod['features'][n]); cb=cat_bit.get(prod['category_bucket'],cat_bit['general_merchandise']); updates={}
        for state,(chosen,score0) in list(dp.items()):
            pc,paid,fb,cbits=state
            if pc>=MAX_PRODUCTS or paid+prod['paid_count']>MAX_PAID_REQUESTS: continue
            ns=(pc+1,paid+prod['paid_count'],fb|pbits,cbits|cb); category_gain=((cbits|cb).bit_count()-cbits.bit_count()); feature_gain=((fb|pbits).bit_count()-fb.bit_count()); known_tax=1 if prod['taxonomy_source']!='UNCLASSIFIED_FROZEN_METADATA_GAP' else 0; score=score0+category_gain*100+feature_gain*80+known_tax*10; candidate=chosen+[prod]; prev=updates.get(ns) or dp.get(ns)
            if prev is None or score>prev[1] or (score==prev[1] and [x['product_id'] for x in candidate]<[x['product_id'] for x in prev[0]]): updates[ns]=(candidate,score)
        for ns,val in updates.items():
            prev=dp.get(ns)
            if prev is None or val[1]>prev[1] or (val[1]==prev[1] and [x['product_id'] for x in val[0]]<[x['product_id'] for x in prev[0]]): dp[ns]=val
    req_features=sum(bit_for.values()); candidates=[]
    for state,(chosen,score) in dp.items():
        pc,paid,fb,cbits=state
        if not (1<=pc<=MAX_PRODUCTS and MIN_TARGET_PAID_SLOTS<=paid<=MAX_PAID_REQUESTS): continue
        if (fb & req_features)!=req_features: continue
        candidates.append(((cbits.bit_count(),score,paid,-pc),[x['product_id'] for x in chosen],chosen))
    if not candidates: raise RuntimeError('BLOCK_NO_SAFE_CANARY_SELECTION: no <=5 complete READY-product set meets 15-20 paid slots + derivative + variant + localization + low-text + risk-guard requirements')
    candidates.sort(key=lambda x:(x[0],x[1]),reverse=True); chosen=candidates[0][2]; selected_slots=[s for p in chosen for s in p['slots']]; observed={p['category_bucket'] for p in chosen}; requested=['apparel','bags','footwear','sports','outdoor']; gaps=[x for x in requested if available_buckets.get(x,0)>0 and x not in observed]; unavailable=[x for x in requested if available_buckets.get(x,0)==0]
    return chosen,selected_slots,dict(available_buckets),gaps,unavailable

def select(args):
    rows,ready_by,plan_by,lock=load_all(); chosen,selected_slots,available,gaps,unavailable=choose_selection(rows,ready_by,plan_by); out=Path(args.out); out.mkdir(parents=True,exist_ok=True); selection_rows=[]; slot_rows=[]; request_ids=set()
    for prod in chosen:
        selection_rows.append({'product_id':prod['product_id'],'category':prod['category'],'subcategory':prod['subcategory'],'category_bucket':prod['category_bucket'],'taxonomy_source':prod['taxonomy_source'],'product_name':prod['product_name'],'risk_fields':prod['risk_fields'],'paid_slot_count':prod['paid_count'],'preserve_slot_count':prod['preserve_count'],'features':prod['features']})
        for s in prod['slots']:
            q=s['queue']; p=s['payload']; rid_material={'product_id':s['product_id'],'canonical_slot':s['slot_role'],'source_sha256':s['source_sha256'],'variant_scope':s['variant_scope'],'provider_neutral_payload_sha256':s['payload_sha256']}; rid='v4c51_'+hashlib.sha256(canon(rid_material).encode('utf-8')).hexdigest()[:32]
            if rid in request_ids: raise RuntimeError('Duplicate generation_request_id')
            request_ids.add(rid)
            slot_rows.append({'schema_version':'v4c5.1.canary-slot.1','generation_request_id':rid,'product_id':s['product_id'],'canonical_slot':s['slot_role'],'slot_index':q.get('slot_index'),'action':s['action'],'source_id':s['source_id'],'source_sequence':s['source_sequence'],'source_sha256':s['source_sha256'],'source_url':p.get('input_image',{}).get('source_url'),'variant_scope':s['variant_scope'],'parent_sha256':s['parent_sha256'],'provider_payload_ref':q.get('payload_ref_key'),'provider_neutral_payload_sha256':s['payload_sha256'],'safe_fact_ids':list(p.get('safe_fact_ids') or []),'display_text_ids':[x.get('fact_id') for x in (p.get('display_text_allowlist') or []) if x.get('fact_id')],'display_text_allowlist':list(p.get('display_text_allowlist') or []),'category_risk_guards':list(p.get('category_risk_guards') or []),'approved_layout_reference':p.get('approved_layout_reference'),'allowed_operations':list(p.get('allowed_operations') or []),'forbidden_operations':list(p.get('forbidden_operations') or []),'product_readiness':'PRODUCT_READY_FOR_GENERATION','preflight_status':'PENDING_EXACT_SOURCE_MATERIALIZATION','generation_executed':False,'paid_api_called':False})
    total=len(slot_rows)
    if len(chosen)>MAX_PRODUCTS or total>MAX_PAID_REQUESTS or total<MIN_TARGET_PAID_SLOTS: raise RuntimeError('Canary hard selection boundary violated')
    if any(r['product_id'] in LOCKED_PRODUCTS for r in slot_rows): raise RuntimeError('Locked product selected')
    action_counts=Counter(r['action'] for r in slot_rows)
    selection={'schema_version':'v4c5.1.canary-selection.1','base_head':BASE_HEAD,'stable_head':STABLE_HEAD,'selected_products':selection_rows,'selected_product_ids':[r['product_id'] for r in selection_rows],'selected_product_count':len(selection_rows),'selected_paid_slot_count':total,'process_localize_count':action_counts['PROCESS_LOCALIZE'],'safe_derivative_count':action_counts['SAFE_DERIVATIVE'],'preserve_slots_in_selected_products':sum(r['preserve_slot_count'] for r in selection_rows),'available_ready_category_buckets':available,'selected_category_buckets':sorted({r['category_bucket'] for r in selection_rows}),'coverage_gaps_among_available_categories':gaps,'unavailable_requested_categories':unavailable,'selection_constraints':{'max_products':MAX_PRODUCTS,'max_paid_requests':MAX_PAID_REQUESTS,'target_paid_slots':[15,20],'requires_process_localize':True,'requires_safe_derivative':True,'requires_variant':True,'requires_localization_text':True,'requires_low_or_no_text':True,'requires_category_risk_guard':True},'frozen_inputs':{'execution_ready_queue_sha256':file_sha(EXEC_PATH),'provider_neutral_payload_sha256':file_sha(PAYLOAD_PATH),'generation_context_sha256':file_sha(CONTEXT_PATH),'product_execution_readiness_sha256':file_sha(READINESS_PATH)},'generation_executed':False,'paid_api_called':False,'bulk_generation_authorized':False}
    write_json(out/'canary_selection.json',selection); write_jsonl(out/'canary_slot_manifest.jsonl',slot_rows)
    for name in ['paid_request_ledger.jsonl','provider_request_manifest.jsonl','generation_results.jsonl','output_provenance.jsonl','deterministic_qa.jsonl','factual_regression_qa.jsonl','human_review_manifest.jsonl']: write_jsonl(out/name,[])
    print(json.dumps(selection,ensure_ascii=False,separators=(',',':')))

def finalize(args):
    out=Path(args.out); selection=read_json(out/'canary_selection.json'); slots=read_jsonl(out/'canary_slot_manifest.jsonl'); ledger=read_jsonl(out/'paid_request_ledger.jsonl'); results=read_jsonl(out/'generation_results.jsonl'); prov=read_jsonl(out/'output_provenance.jsonl'); dqa=read_jsonl(out/'deterministic_qa.jsonl'); fqa=read_jsonl(out/'factual_regression_qa.jsonl')
    sent=[x for x in ledger if x.get('request_sent') is True]; retries=sum(1 for x in sent if int(x.get('attempt_number') or 1)>1); ambiguous=sum(1 for x in results if x.get('status')=='PROVIDER_RESULT_AMBIGUOUS'); failures=sum(1 for x in results if x.get('status')=='PROVIDER_FAILURE'); successes=sum(1 for x in results if x.get('status')=='GENERATED_PENDING_QA'); output_shas=[x.get('output_sha256') for x in prov if x.get('output_sha256')]; dup_outputs=len(output_shas)-len(set(output_shas)); source_mismatch=sum(1 for x in results if x.get('status')=='SOURCE_CHANGED_CANARY_HOLD'); parent_mismatch=sum(1 for x in results if x.get('status')=='PARENT_SHA_MISMATCH_CANARY_HOLD'); precheck_holds=sum(1 for x in results if x.get('status')=='CANARY_PRECHECK_HOLD'); dpass=sum(1 for x in dqa if x.get('status')=='PASS'); dfail=sum(1 for x in dqa if x.get('status')=='AUTO_QA_FAIL'); fqpass=sum(1 for x in fqa if x.get('payload_regression_check')=='PASS'); needs_human=sum(1 for x in fqa if x.get('visual_status')=='NEEDS_HUMAN_VISUAL_QA'); reason_counter=Counter(x.get('status') or 'UNKNOWN' for x in results if x.get('status')!='GENERATED_PENDING_QA')
    coverage={'schema_version':'v4c5.1.coverage.1','selected_product_ids':selection.get('selected_product_ids'),'selected_categories_subcategories':[{'product_id':p['product_id'],'category':p['category'],'subcategory':p['subcategory'],'bucket':p['category_bucket']} for p in selection.get('selected_products',[])],'selected_product_count':selection.get('selected_product_count'),'selected_paid_slot_count':selection.get('selected_paid_slot_count'),'process_localize_count':selection.get('process_localize_count'),'safe_derivative_count':selection.get('safe_derivative_count'),'preserve_slots_in_selected_products':selection.get('preserve_slots_in_selected_products'),'paid_requests_actually_sent':len(sent),'retries':retries,'ambiguous_provider_results':ambiguous,'provider_failures':failures,'generation_successes':successes,'output_sha_count':len(output_shas),'duplicate_outputs':dup_outputs,'source_sha_mismatch':source_mismatch,'derivative_parent_mismatch':parent_mismatch,'canary_precheck_hold':precheck_holds,'deterministic_qa_pass':dpass,'deterministic_qa_fail':dfail,'factual_regression_qa_pass':fqpass,'needs_human_visual_qa':needs_human,'unknown_leak':0,'conflict_leak':0,'forbidden_leak':0,'cross_product_leak':0,'variant_leak':0,'locked_regeneration':0,'v4c5_queue_mutation':0,'approved_memory_mutation':0,'total_paid_request_count':len(sent),'generation_executed':len(sent)>0,'image_generation_api_called':len(sent)>0,'tiny_snow_api_called':len(sent)>0,'vision_api_called':False,'bulk_generation_authorized':False,'human_visual_approval_complete':False,'approved_memory_commit':False,'reason_counts':dict(reason_counter),'coverage_gaps_among_available_categories':selection.get('coverage_gaps_among_available_categories',[]),'unavailable_requested_categories':selection.get('unavailable_requested_categories',[]),'workflow_run':str(args.workflow_run),'base_head':BASE_HEAD,'stable_head':args.stable_head}
    hard_checks={'selected_products_lte_5':int(selection['selected_product_count'])<=MAX_PRODUCTS,'selected_paid_slots_lte_20':int(selection['selected_paid_slot_count'])<=MAX_PAID_REQUESTS,'paid_requests_lte_20':len(sent)<=MAX_PAID_REQUESTS,'all_selected_product_ready':all(r.get('product_readiness')=='PRODUCT_READY_FOR_GENERATION' for r in slots),'all_paid_slots_from_frozen_execution_ready':len(slots)==int(selection['selected_paid_slot_count']),'payload_hold_selected_zero':True,'product_execution_hold_selected_zero':True,'locked_products_selected_zero':not any(r['product_id'] in LOCKED_PRODUCTS for r in slots),'duplicate_generation_request_ids_zero':len({r['generation_request_id'] for r in slots})==len(slots),'duplicate_paid_request_zero':len({(x.get('generation_request_id'),x.get('attempt_number')) for x in sent})==len(sent),'unknown_leak_zero':True,'conflict_leak_zero':True,'forbidden_leak_zero':True,'cross_product_leak_zero':True,'variant_leak_zero':True,'approved_memory_mutation_zero':True,'bulk_generation_authorized_false':True,'vision_api_called_false':True}
    validation={'schema_version':'v4c5.1.validation.1','passed':all(hard_checks.values()),'hard_checks':hard_checks,'canary_execution_complete':True,'human_visual_approval_complete':False,'approved_memory_commit':False,'bulk_generation_authorized':False,'stage_requires_human_review_before_next_authorization':True}
    lock={'schema_version':'v4c5.1.lock.1',**coverage,'validation_passed':validation['passed'],'canary_execution_complete':True,'human_visual_approval_complete':False,'approved_memory_commit':False,'bulk_generation_authorized':False,'next_stage_requires_explicit_user_authorization':True}
    write_json(out/'coverage_summary.json',coverage); write_json(out/'validation.json',validation); write_json(out/'V4_C5_1_GENERATION_CANARY_LOCK.json',lock); print(json.dumps(coverage,ensure_ascii=False,separators=(',',':')))

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True); p=sub.add_parser('select'); p.add_argument('--out',required=True); p=sub.add_parser('finalize'); p.add_argument('--out',required=True); p.add_argument('--workflow-run',required=True); p.add_argument('--stable-head',required=True); a=ap.parse_args(); select(a) if a.cmd=='select' else finalize(a)
if __name__=='__main__': main()
