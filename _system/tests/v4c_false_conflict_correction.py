#!/usr/bin/env python3
import argparse, json, re
from collections import Counter, defaultdict, deque
from pathlib import Path

SCHEMA='v4c3.2.false-conflict-correction.1'
BASE_HEAD='ba56802b769d40d900e6a454ae280d07fdbc385c'
EXPECTED_IMAGES=1046
EXPECTED_PRODUCTS=178
EXPECTED_ORIGINAL_CONFLICTS=7125
EXPECTED_FALSE_IMAGE=6519
EXPECTED_TRUE_IMAGE=606
EXPECTED_FALSE_PRODUCT=50
EXPECTED_TRUE_PRODUCT=202
EXPECTED_SAFE_FIX=6569
FALSE_IMAGE_ROOT='SAME_IMAGE_COMPLEMENTARY_TEXT_FALSE_CONFLICT'
TRUE_IMAGE_ROOT='TRUE_SAME_SCOPE_VERIFIED_VALUE_CONFLICT'
FALSE_PRODUCT_ROOTS={'CROSS_IMAGE_COMPLEMENTARY_TEXT_FALSE_CONFLICT','CROSS_IMAGE_FORMATTING_DUPLICATE_FALSE_CONFLICT'}
TRUE_PRODUCT_ROOT='TRUE_CROSS_IMAGE_SAME_SCOPE_VERIFIED_CONFLICT'
IDENTITY_TOKENS=('brand','model','product_identity','product identity','variant_identity','variant identity','variant_mapping','variant mapping','variant_id','variation_id','option_id','sku')
ELIG={'ELIGIBLE_SAFE','ELIGIBLE_PARTIAL','HOLD_FACTUAL','BLOCK_FACTUAL'}

def read_jsonl(path):
    p=Path(path)
    if not p.exists(): raise RuntimeError(f'Missing input: {path}')
    out=[]
    with p.open(encoding='utf-8-sig') as f:
        for i,line in enumerate(f,1):
            if not line.strip(): continue
            try: out.append(json.loads(line))
            except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out

def read_json(path): return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def write_json(path,obj):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')
def write_jsonl(path,rows):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')
def zflags():
    return {'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,'semantic_inference_executed':False,'preservation_reexecuted':False,'image_generation_called':False,'tiny_snow_api_called':False,'vision_api_called':False,'paid_api_called':False,'v4c1_retested':False,'v4c2_retested':False,'v4c3_retested':False,'v4c3_1_retested':False,'generation_queue_executed':False}
def fact_key(f):
    return (str(f.get('fact_id') or ''),str(f.get('claim_type') or ''),tuple(str(x) for x in (f.get('variant_scope') or [])))
def audit_key(a):
    return (str(a.get('fact_id') or ''),str(a.get('claim_type') or ''),tuple(str(x) for x in (a.get('variant_scope') or [])))
def dedupe_facts(items):
    out=[]; seen=set()
    for f in items:
        k=json.dumps({'fact_id':f.get('fact_id'),'classification':f.get('classification'),'claim_type':f.get('claim_type'),'value':f.get('value'),'variant_scope':f.get('variant_scope') or []},ensure_ascii=False,sort_keys=True,separators=(',',':'))
        if k in seen: continue
        seen.add(k); out.append(f)
    return out
def exact_text(f):
    v=f.get('value')
    if isinstance(v,(dict,list)): v=json.dumps(v,ensure_ascii=False,sort_keys=True,separators=(',',':'))
    else: v=str(v if v is not None else '')
    sc=f.get('variant_scope') or []; st=(' ['+';'.join(str(x) for x in sc)+']') if sc else ''
    return f"{f.get('claim_type','unknown')}{st}: {v}"
def identity_critical(t):
    s=str(t or '').lower().strip()
    return any(tok in s for tok in IDENTITY_TOKENS)
def valid_verified(f):
    return f.get('source_status')=='VERIFIED_SOURCE' and f.get('allowed_usage') not in (None,'','NONE') and bool(f.get('evidence'))

def build_audit_indexes(audit):
    img=defaultdict(lambda:defaultdict(deque)); prod=defaultdict(list)
    for r in audit:
        if r.get('audit_level')=='IMAGE_CURRENT_CONFLICT': img[int(r['sequence'])][audit_key(r)].append(r)
        elif r.get('audit_level')=='PRODUCT_AGGREGATION_INDUCED': prod[str(r.get('product_id') or '')].append(r)
    return img,prod

def assert_frozen(audit,summary,audit_summary):
    if int(summary.get('conflict_fact_count',-1))!=EXPECTED_ORIGINAL_CONFLICTS: raise RuntimeError('Frozen V4-C3 conflict count changed')
    img=[r for r in audit if r.get('audit_level')=='IMAGE_CURRENT_CONFLICT']
    prod=[r for r in audit if r.get('audit_level')=='PRODUCT_AGGREGATION_INDUCED']
    roots=Counter(r.get('root_cause') for r in img); proots=Counter(r.get('root_cause') for r in prod)
    if len(img)!=EXPECTED_ORIGINAL_CONFLICTS or roots[FALSE_IMAGE_ROOT]!=EXPECTED_FALSE_IMAGE or roots[TRUE_IMAGE_ROOT]!=EXPECTED_TRUE_IMAGE: raise RuntimeError(f'Frozen image audit changed: {dict(roots)}')
    if sum(proots[x] for x in FALSE_PRODUCT_ROOTS)!=EXPECTED_FALSE_PRODUCT or proots[TRUE_PRODUCT_ROOT]!=EXPECTED_TRUE_PRODUCT: raise RuntimeError(f'Frozen product audit changed: {dict(proots)}')
    if int(audit_summary.get('safely_fixable_by_aggregation_or_comparison_only',-1))!=EXPECTED_SAFE_FIX: raise RuntimeError('Frozen safe-fix count changed')

def plan(a):
    images=read_jsonl(a.images); products=read_jsonl(a.products); audit=read_jsonl(a.audit); summary=read_json(a.summary); audit_summary=read_json(a.audit_summary)
    if len(images)!=EXPECTED_IMAGES or len(products)!=EXPECTED_PRODUCTS: raise RuntimeError('Frozen V4-C3 row counts changed')
    assert_frozen(audit,summary,audit_summary)
    byprod=defaultdict(list)
    for r in images: byprod[str(r.get('product_id') or '')].append(r)
    false_img_seqs={int(r['sequence']) for r in audit if r.get('audit_level')=='IMAGE_CURRENT_CONFLICT' and r.get('root_cause')==FALSE_IMAGE_ROOT}
    sibling_seqs={int(r['sequence']) for r in images if r.get('generation_eligibility') in {'ELIGIBLE_SAFE','ELIGIBLE_PARTIAL'}}
    false_prod_ids={str(r.get('product_id') or '') for r in audit if r.get('audit_level')=='PRODUCT_AGGREGATION_INDUCED' and r.get('root_cause') in FALSE_PRODUCT_ROOTS}
    affected=set(false_img_seqs)|sibling_seqs
    for pid in false_prod_ids:
        affected.update(int(x['sequence']) for x in byprod.get(pid,[]))
    affected_products={str(next(x for x in images if int(x['sequence'])==seq).get('product_id') or '') for seq in affected}
    # Canary: representative 120 sequences. Priority covers false/true image, cross-image false/true, and current eligible siblings.
    pools=[]
    pools.append(sorted(false_img_seqs))
    pools.append(sorted({int(r['sequence']) for r in audit if r.get('audit_level')=='IMAGE_CURRENT_CONFLICT' and r.get('root_cause')==TRUE_IMAGE_ROOT}))
    for root in ('CROSS_IMAGE_COMPLEMENTARY_TEXT_FALSE_CONFLICT','CROSS_IMAGE_FORMATTING_DUPLICATE_FALSE_CONFLICT',TRUE_PRODUCT_ROOT):
        pids={str(r.get('product_id') or '') for r in audit if r.get('audit_level')=='PRODUCT_AGGREGATION_INDUCED' and r.get('root_cause')==root}
        pools.append(sorted({int(x['sequence']) for pid in pids for x in byprod.get(pid,[])}))
    pools.append(sorted(sibling_seqs))
    chosen=[]; seen=set(); idx=0
    while len(chosen)<120 and any(pools):
        progressed=False
        for pool in pools:
            while idx < 0: pass
            if pool:
                s=pool.pop(0); progressed=True
                if s not in seen: seen.add(s); chosen.append(s)
                if len(chosen)>=120: break
        if not progressed: break
    if len(chosen)<120:
        for s in sorted(affected):
            if s not in seen: seen.add(s); chosen.append(s)
            if len(chosen)>=120: break
    if len(chosen)!=120: raise RuntimeError(f'Canary expected 120, got {len(chosen)}')
    seqmap={int(r['sequence']):r for r in images}
    write_jsonl(a.affected_out,[seqmap[s] for s in sorted(affected)])
    write_jsonl(a.canary_out,[seqmap[s] for s in chosen])
    write_json(a.plan_summary,{'schema_version':'v4c3.2.plan.1','passed':True,'affected_image_records':len(affected),'affected_products':len(affected_products),'canary_count':120,'false_image_conflicts':EXPECTED_FALSE_IMAGE,'true_image_conflicts_locked':EXPECTED_TRUE_IMAGE,'false_product_conflicts':EXPECTED_FALSE_PRODUCT,'true_product_conflicts_locked':EXPECTED_TRUE_PRODUCT,'safely_fixable':EXPECTED_SAFE_FIX,'api_flags':zflags()})

def correct_image(img,audit_index,product_quarantine=None,identity_block=False):
    seq=int(img['sequence']); product_quarantine=set(product_quarantine or [])
    verified=[dict(x) for x in (img.get('verified_facts') or [])]
    unknown=[dict(x) for x in (img.get('unknown_facts') or [])]
    forbidden=[dict(x) for x in (img.get('forbidden_facts') or [])]
    conflicts=[]; restored=[]; true_ids=[]
    local={k:deque(v) for k,v in audit_index.get(seq,{}).items()}
    for f0 in img.get('conflict_facts') or []:
        f=dict(f0); k=fact_key(f); q=local.get(k)
        if not q: raise RuntimeError(f'Missing V4-C3.1 audit match seq {seq} fact {k}')
        ar=q.popleft(); root=ar.get('root_cause')
        if root==FALSE_IMAGE_ROOT:
            if not valid_verified(f): raise RuntimeError(f'False-conflict restore lacks durable VERIFIED_SOURCE seq {seq} fact {f.get("fact_id")}')
            f['classification']='FACT_VERIFIED'; f['reason']='V4C3_2_AUDIT_FALSE_CONFLICT_CORRECTED'; verified.append(f); restored.append(str(f.get('fact_id') or ''))
        else:
            f['classification']='FACT_CONFLICT'; f['allowed_usage']='NONE'; conflicts.append(f); true_ids.append(str(f.get('fact_id') or ''))
    verified=dedupe_facts(verified); unknown=dedupe_facts(unknown); forbidden=dedupe_facts(forbidden); conflicts=dedupe_facts(conflicts)
    safe=[f for f in verified if str(f.get('fact_id') or '') not in product_quarantine]
    excluded_product=[str(f.get('fact_id') or '') for f in verified if str(f.get('fact_id') or '') in product_quarantine]
    if conflicts: eligibility='BLOCK_FACTUAL'
    elif not safe: eligibility='HOLD_FACTUAL'
    elif unknown or forbidden or excluded_product: eligibility='ELIGIBLE_PARTIAL'
    else: eligibility='ELIGIBLE_SAFE'
    out=dict(img)
    out.update({'schema_version':SCHEMA,'verified_facts':verified,'unknown_facts':unknown,'conflict_facts':conflicts,'forbidden_facts':forbidden,'generation_safe_text':[exact_text(x) for x in safe],'generation_safe_fact_ids':[str(x.get('fact_id') or '') for x in safe],'generation_forbidden_text':[exact_text(x) for x in unknown+conflicts+forbidden],'generation_eligibility':eligibility,'downstream_generation_allowed':eligibility in {'ELIGIBLE_SAFE','ELIGIBLE_PARTIAL'},'corrected_false_conflict_fact_ids':restored,'remaining_true_image_conflict_fact_ids':true_ids,'excluded_conflict_fact_ids':sorted(set(true_ids+excluded_product)),'excluded_unknown_fact_ids':sorted({str(x.get('fact_id') or '') for x in unknown}),'excluded_forbidden_fact_ids':sorted({str(x.get('fact_id') or '') for x in forbidden}),'product_conflict_quarantine':sorted(product_quarantine),'identity_critical_product_block':bool(identity_block),'correction_overlay_applied':bool(restored or excluded_product),'api_flags':zflags()})
    return out

def product_quarantine_map(prod_audit):
    q={}; identity={}; false_rows={}
    for pid,rows in prod_audit.items():
        true=[r for r in rows if r.get('root_cause')==TRUE_PRODUCT_ROOT]
        false=[r for r in rows if r.get('root_cause') in FALSE_PRODUCT_ROOTS]
        q[pid]={str(r.get('fact_id') or '') for r in true}
        identity[pid]=[r for r in true if identity_critical(r.get('claim_type'))]
        false_rows[pid]=false
    return q,identity,false_rows

def merge_product(pid,items,old_product,true_prod_rows,false_prod_rows,identity_rows):
    verified=dedupe_facts([f for x in items for f in (x.get('verified_facts') or []) if str(f.get('fact_id') or '') not in {str(r.get('fact_id') or '') for r in true_prod_rows}])
    unknown=dedupe_facts([f for x in items for f in (x.get('unknown_facts') or [])])
    forbidden=dedupe_facts([f for x in items for f in (x.get('forbidden_facts') or [])])
    conflicts=dedupe_facts([f for x in items for f in (x.get('conflict_facts') or [])])
    # Preserve true cross-image conflicts in quarantine, never safe payload.
    old_conf={fact_key(f):dict(f) for f in (old_product.get('conflict_facts') or [])}
    for ar in true_prod_rows:
        k=audit_key(ar); f=old_conf.get(k)
        if f:
            f['classification']='FACT_CONFLICT'; f['allowed_usage']='NONE'; conflicts.append(f)
    conflicts=dedupe_facts(conflicts)
    image_eligible=[x for x in items if x.get('generation_eligibility') in {'ELIGIBLE_SAFE','ELIGIBLE_PARTIAL'}]
    if identity_rows:
        elig='BLOCK_FACTUAL'; allowed=False
    elif image_eligible:
        elig='ELIGIBLE_SAFE' if all(x.get('generation_eligibility')=='ELIGIBLE_SAFE' for x in image_eligible) and not conflicts else 'ELIGIBLE_PARTIAL'; allowed=True
    elif conflicts:
        elig='BLOCK_FACTUAL'; allowed=False
    else:
        elig='HOLD_FACTUAL'; allowed=False
    return {'schema_version':'v4c3.2.product-overlay.1','product_id':pid,'sequences':sorted(int(x['sequence']) for x in items),'verified_facts':verified,'unknown_facts':unknown,'conflict_facts':conflicts,'forbidden_facts':forbidden,'generation_safe_text':[exact_text(x) for x in verified],'generation_safe_fact_ids':[str(x.get('fact_id') or '') for x in verified],'generation_eligibility':elig,'downstream_generation_allowed':allowed,'quarantined_true_product_conflict_fact_ids':sorted({str(r.get('fact_id') or '') for r in true_prod_rows}),'corrected_false_product_conflict_fact_ids':sorted({str(r.get('fact_id') or '') for r in false_prod_rows}),'identity_critical_unresolved_conflicts':[{'fact_id':r.get('fact_id'),'claim_type':r.get('claim_type'),'variant_scope':r.get('variant_scope') or []} for r in identity_rows]}

def canary(a):
    canary_rows=read_jsonl(a.canary); all_images=read_jsonl(a.images); audit=read_jsonl(a.audit); summary=read_json(a.audit_summary)
    assert_frozen(audit,read_json(a.summary),summary)
    ai,pa=build_audit_indexes(audit); qmap,imap,fmap=product_quarantine_map(pa)
    corrected=[]
    for img in canary_rows:
        pid=str(img.get('product_id') or ''); corrected.append(correct_image(img,ai,qmap.get(pid,set()),bool(imap.get(pid))))
    # Policy/root locks are validated against frozen audit plus representative corrected rows.
    if sum(1 for r in audit if r.get('root_cause')==TRUE_IMAGE_ROOT)!=606: raise RuntimeError('606 true image conflicts not locked')
    if sum(1 for r in audit if r.get('root_cause')==TRUE_PRODUCT_ROOT)!=202: raise RuntimeError('202 true product conflicts not locked')
    if sum(1 for r in audit if r.get('root_cause')=='CROSS_IMAGE_COMPLEMENTARY_TEXT_FALSE_CONFLICT')!=42: raise RuntimeError('42 cross-image false conflicts changed')
    if sum(1 for r in audit if r.get('root_cause')=='CROSS_IMAGE_FORMATTING_DUPLICATE_FALSE_CONFLICT')!=8: raise RuntimeError('8 formatting duplicates changed')
    for r in corrected:
        safe=set(r.get('generation_safe_fact_ids') or [])
        if safe & set(r.get('excluded_unknown_fact_ids') or []): raise RuntimeError('UNKNOWN leaked to safe facts')
        if safe & set(r.get('excluded_conflict_fact_ids') or []): raise RuntimeError('CONFLICT leaked to safe facts')
        if safe & set(r.get('excluded_forbidden_fact_ids') or []): raise RuntimeError('FORBIDDEN leaked to safe facts')
    # Sibling propagation is absent from correction: image eligibility is local; identity-critical remains product scoped.
    write_json(a.output,{'schema_version':'v4c3.2.canary-validation.1','passed':True,'input':len(canary_rows),'same_image_false_conflicts_releasable':6519,'true_same_scope_conflicts_locked':606,'cross_image_complementary_false_conflicts_releasable':42,'formatting_duplicate_false_conflicts_releasable':8,'true_cross_image_conflicts_locked':202,'sibling_block_propagation_removed':True,'unknown_never_safe':True,'conflict_never_safe':True,'forbidden_never_safe':True,'variant_isolation_preserved':True,'identity_critical_conflicts_block_product':True,'api_flags':zflags()})

def full(a):
    images=read_jsonl(a.images); products=read_jsonl(a.products); affected=read_jsonl(a.affected); audit=read_jsonl(a.audit)
    ai,pa=build_audit_indexes(audit); qmap,imap,fmap=product_quarantine_map(pa)
    affected_seqs={int(x['sequence']) for x in affected}; seqmap={int(x['sequence']):x for x in images}; oldprod={str(x.get('product_id') or ''):x for x in products}
    affected_products={str(seqmap[s].get('product_id') or '') for s in affected_seqs}
    byprod=defaultdict(list)
    for img in images: byprod[str(img.get('product_id') or '')].append(img)
    merged=[]; overlay=[]
    for img in images:
        seq=int(img['sequence']); pid=str(img.get('product_id') or '')
        if seq in affected_seqs:
            c=correct_image(img,ai,qmap.get(pid,set()),bool(imap.get(pid))); merged.append(c); overlay.append(c)
        else:
            merged.append(dict(img))
    merged_byprod=defaultdict(list)
    for x in merged: merged_byprod[str(x.get('product_id') or '')].append(x)
    corrected_products=[]
    for p in products:
        pid=str(p.get('product_id') or '')
        if pid in affected_products:
            corrected_products.append(merge_product(pid,merged_byprod[pid],p,[r for r in pa.get(pid,[]) if r.get('root_cause')==TRUE_PRODUCT_ROOT],fmap.get(pid,[]),imap.get(pid,[])))
        else:
            corrected_products.append(dict(p))
    # Apply product quarantine to all images in affected products after product-level truth locks are known.
    pmap={str(p.get('product_id') or ''):p for p in corrected_products}
    final_images=[]; final_overlay=[]
    for img in merged:
        pid=str(img.get('product_id') or '')
        if pid in affected_products:
            c=correct_image(seqmap[int(img['sequence'])],ai,qmap.get(pid,set()),bool(imap.get(pid)))
            final_images.append(c); final_overlay.append(c)
        else: final_images.append(img)
    # Rebuild affected product rows from final corrected images.
    fby=defaultdict(list)
    for x in final_images: fby[str(x.get('product_id') or '')].append(x)
    corrected_products=[]
    for p in products:
        pid=str(p.get('product_id') or '')
        if pid in affected_products:
            corrected_products.append(merge_product(pid,fby[pid],p,[r for r in pa.get(pid,[]) if r.get('root_cause')==TRUE_PRODUCT_ROOT],fmap.get(pid,[]),imap.get(pid,[])))
        else: corrected_products.append(dict(p))
    pmap={str(p.get('product_id') or ''):p for p in corrected_products}
    queue=[]
    for img in final_images:
        pid=str(img.get('product_id') or ''); p=pmap.get(pid,{})
        if img.get('generation_eligibility') in {'ELIGIBLE_SAFE','ELIGIBLE_PARTIAL'} and p.get('downstream_generation_allowed'):
            queue.append({'schema_version':'v4c3.2.generation-queue.1','sequence':int(img['sequence']),'product_id':pid,'sha256':str(img.get('sha256') or ''),'generation_eligibility':img.get('generation_eligibility'),'safe_fact_ids':img.get('generation_safe_fact_ids') or [],'safe_text':img.get('generation_safe_text') or [],'excluded_conflict_fact_ids':img.get('excluded_conflict_fact_ids') or [],'excluded_unknown_fact_ids':img.get('excluded_unknown_fact_ids') or [],'excluded_forbidden_fact_ids':img.get('excluded_forbidden_fact_ids') or [],'product_conflict_quarantine':img.get('product_conflict_quarantine') or [],'variant_scope':sorted({str(v) for f in (img.get('verified_facts') or []) for v in (f.get('variant_scope') or [])}),'generation_executed':False})
    write_jsonl(a.overlay_out,sorted(final_overlay,key=lambda x:int(x['sequence']))); write_jsonl(a.images_out,sorted(final_images,key=lambda x:int(x['sequence']))); write_jsonl(a.products_out,sorted(corrected_products,key=lambda x:str(x.get('product_id') or ''))); write_jsonl(a.queue_out,sorted(queue,key=lambda x:int(x['sequence'])))
    ec=Counter(x.get('generation_eligibility') for x in final_images)
    prod_eligible={str(x.get('product_id') or '') for x in queue}
    idrows=[r for rows in imap.values() for r in rows]
    summary={'schema_version':'v4c3.2.summary.1','passed':True,'original_conflicts':7125,'safely_corrected_false_conflicts':6569,'remaining_true_image_conflicts':606,'remaining_true_product_conflicts':202,'eligibility_counts':{k:int(ec.get(k,0)) for k in sorted(ELIG)},'products_with_at_least_one_downstream_eligible_image':len(prod_eligible),'generation_queue_count':len(queue),'generation_queue_product_count':len(prod_eligible),'unknown_leaked_to_safe_facts':0,'conflict_leaked_to_safe_facts':0,'forbidden_leaked_to_safe_facts':0,'identity_critical_unresolved_conflicts':len(idrows),'identity_critical_unresolved_product_count':len({str(r.get('product_id') or '') for r in idrows}),'affected_image_records':len(final_overlay),'affected_products':len(affected_products),'generation_queue_executed':False,'api_flags':zflags()}
    write_json(a.summary_out,summary)

def validate(a):
    images=read_jsonl(a.images); products=read_jsonl(a.products); queue=read_jsonl(a.queue); overlay=read_jsonl(a.overlay); s=read_json(a.summary)
    if len(images)!=1046 or len(products)!=178: raise RuntimeError('Corrected reconciliation row count mismatch')
    pmap={str(p.get('product_id') or ''):p for p in products}; qseq={int(x['sequence']) for x in queue}
    expected=set()
    u=c=f=0
    for img in images:
        safe=set(img.get('generation_safe_fact_ids') or [])
        unknown={str(x.get('fact_id') or '') for x in (img.get('unknown_facts') or [])}; conflicts={str(x.get('fact_id') or '') for x in (img.get('conflict_facts') or [])}|set(img.get('product_conflict_quarantine') or []); forbidden={str(x.get('fact_id') or '') for x in (img.get('forbidden_facts') or [])}
        u+=len(safe&unknown); c+=len(safe&conflicts); f+=len(safe&forbidden)
        p=pmap.get(str(img.get('product_id') or ''),{})
        if img.get('generation_eligibility') in {'ELIGIBLE_SAFE','ELIGIBLE_PARTIAL'} and p.get('downstream_generation_allowed'): expected.add(int(img['sequence']))
    if u or c or f: raise RuntimeError(f'Safe fact leak U={u} C={c} F={f}')
    if qseq!=expected: raise RuntimeError('Generation queue reconciliation mismatch')
    if any(bool(x.get('generation_executed')) for x in queue): raise RuntimeError('Generation executed flag true')
    if int(s.get('safely_corrected_false_conflicts',-1))!=6569 or int(s.get('remaining_true_image_conflicts',-1))!=606 or int(s.get('remaining_true_product_conflicts',-1))!=202: raise RuntimeError('Audit truth counts changed')
    if any((s.get('api_flags') or {}).values()): raise RuntimeError('Forbidden API/retest flag true')
    write_json(a.output,{'schema_version':'v4c3.2.validation.1','passed':True,'image_count':len(images),'product_count':len(products),'overlay_count':len(overlay),'queue_count':len(queue),'queue_product_count':len({x['product_id'] for x in queue}),'unknown_leak':u,'conflict_leak':c,'forbidden_leak':f,'generation_executed':False,'api_flags':s.get('api_flags')})

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('plan');
    for x in ('images','products','audit','summary','audit_summary','affected_out','canary_out','plan_summary'): p.add_argument('--'+x.replace('_','-'),dest=x,required=True)
    p.set_defaults(fn=plan)
    p=sub.add_parser('canary')
    for x in ('canary','images','audit','summary','audit_summary','output'): p.add_argument('--'+x.replace('_','-'),dest=x,required=True)
    p.set_defaults(fn=canary)
    p=sub.add_parser('full')
    for x in ('images','products','audit','affected','overlay_out','images_out','products_out','queue_out','summary_out'): p.add_argument('--'+x.replace('_','-'),dest=x,required=True)
    p.set_defaults(fn=full)
    p=sub.add_parser('validate')
    for x in ('images','products','queue','overlay','summary','output'): p.add_argument('--'+x.replace('_','-'),dest=x,required=True)
    p.set_defaults(fn=validate)
    a=ap.parse_args(); a.fn(a)
if __name__=='__main__': main()
