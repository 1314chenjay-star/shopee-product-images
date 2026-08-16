#!/usr/bin/env python3
import argparse, json, re, hashlib
from collections import Counter, defaultdict
from pathlib import Path

SCHEMA='v4c3.1.factual-conflict-audit.1'
BASE_HEAD='411460f1fff63ba9c1bb3be3f248d7e171996c40'
EXPECTED_IMAGES=1046
EXPECTED_PRODUCTS=178
EXPECTED_CONFLICTS=7125
EXPECTED_ELIGIBLE_PARTIAL=79

TEXT_LIKE_TOKENS={
 'text','source_text','visible_text','ocr_text','title_text','feature_text','description_text',
 'content','copy','label_text','printed_text','detected_text','claim_text','source_claim','visible_claim'
}
HIGH_RISK_TOKENS={
 'brand','material','size','dimension','dimensions','weight','accessory','accessories','bundle_count','quantity',
 'count','function','feature','certification','certificate','waterproof','water_resistant','water-resistance',
 'abrasion','medical','safety','performance','load_rating','resistance','capacity','warranty','gift','ingredient',
 '材質','材料','尺寸','規格','品牌','配件','附件','數量','功能','認證','防水','耐磨','醫療','安全','性能','承重','重量','容量','保固','贈品'
}

def read_jsonl(path):
    p=Path(path)
    if not p.exists(): raise RuntimeError(f'Missing input: {path}')
    rows=[]
    with p.open(encoding='utf-8-sig') as f:
        for i,line in enumerate(f,1):
            if not line.strip(): continue
            try: rows.append(json.loads(line))
            except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return rows

def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def write_json(path,obj):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')

def write_jsonl(path,rows):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')

def zflags():
    return {
      'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,
      'semantic_inference_executed':False,'preservation_reexecuted':False,'image_generation_called':False,
      'tiny_snow_api_called':False,'vision_api_called':False,'paid_api_called':False,
      'v4c1_retested':False,'v4c2_retested':False,'v4c3_retested':False,
      'generation_queue_started':False,'gate_logic_modified':False
    }

def norm_type(f): return str(f.get('claim_type') or '').strip().lower()

def norm_value(v):
    if isinstance(v,(dict,list)): s=json.dumps(v,ensure_ascii=False,sort_keys=True,separators=(',',':'))
    else: s=str(v if v is not None else '')
    s=' '.join(s.strip().lower().split())
    s=re.sub(r'[\s\u3000]+',' ',s)
    return s

def compact_value(v):
    return re.sub(r'[\s\W_]+','',norm_value(v),flags=re.UNICODE)

def scope_tuple(f): return tuple(str(x) for x in (f.get('variant_scope') or []))

def is_text_like(t):
    t=str(t or '').lower()
    return t in TEXT_LIKE_TOKENS or t.endswith('_text') or 'ocr' in t or 'visible' in t or 'description' in t

def is_high_risk(t):
    t=str(t or '').lower()
    return any(x in t for x in HIGH_RISK_TOKENS)

def fact_sig(f):
    return json.dumps({'fact_id':f.get('fact_id'),'claim_type':f.get('claim_type'),'value':f.get('value'),'variant_scope':f.get('variant_scope') or []},ensure_ascii=False,sort_keys=True,separators=(',',':'))

def evidence_ref(img,f):
    ev=f.get('evidence') or []
    digest=hashlib.sha256(json.dumps(ev,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode('utf-8')).hexdigest()[:16]
    return {'durable_source':img.get('evidence_source'),'evidence_digest16':digest,'evidence_items':len(ev)}

def same_claim_group(img,f):
    t=norm_type(f); sc=scope_tuple(f)
    pool=[]
    for key in ('verified_facts','conflict_facts'):
        for x in img.get(key) or []:
            if norm_type(x)==t and scope_tuple(x)==sc: pool.append(x)
    return pool

def duplicate_fact_id_in_image(img,f):
    fid=str(f.get('fact_id') or '')
    if not fid: return False
    seen=[]
    for key in ('verified_facts','unknown_facts','conflict_facts','forbidden_facts'):
        for x in img.get(key) or []:
            if str(x.get('fact_id') or '')==fid: seen.append(x)
    return len(seen)>1 and len({fact_sig(x) for x in seen})>1

def classify_image_conflict(img,f):
    reason=str(f.get('reason') or '')
    t=norm_type(f)
    group=same_claim_group(img,f)
    values=[norm_value(x.get('value')) for x in group]
    compact=[compact_value(x.get('value')) for x in group]
    if duplicate_fact_id_in_image(img,f):
        return ('DUPLICATE_FACT_ID_MALFORMED_EVIDENCE',False,'EVIDENCE_NORMALIZATION')
    if reason=='EXPLICIT_CONFLICT_IN_DURABLE_EVIDENCE':
        return ('TRUE_EXPLICIT_SOURCE_CONFLICT',True,'KEEP_BLOCK')
    if reason=='CLAIM_BUCKET_STATUS_CONFLICT':
        return ('MALFORMED_BUCKET_STATUS_CONFLICT',False,'BUCKET_CLASSIFICATION_ONLY')
    if reason=='UNKNOWN_ALLOWED_USAGE_VIOLATION':
        return ('MALFORMED_UNKNOWN_USAGE_CONFLICT',False,'POLICY_CLASSIFICATION_ONLY')
    if reason=='VARIANT_SCOPE_CONFLICT_UNSCOPED_FACT':
        return ('UNSCOPED_VS_VARIANT_SCOPE_COMPARISON',False,'SCOPE_COMPARISON_ONLY')
    if reason=='CONFLICTING_VERIFIED_VALUES_SAME_SCOPE':
        nonempty=[x for x in compact if x]
        if len(set(nonempty))<=1:
            return ('FORMATTING_DUPLICATE_FALSE_CONFLICT',False,'VALUE_NORMALIZATION_ONLY')
        if is_text_like(t):
            return ('SAME_IMAGE_COMPLEMENTARY_TEXT_FALSE_CONFLICT',False,'COMPARISON_SEMANTICS_ONLY')
        # Multiple values for an untyped/generic claim are not safely mergeable, but the audit
        # does not invent semantics; conservatively keep them blocked.
        if t in {'','unknown','claim','fact','value'}:
            return ('AMBIGUOUS_GENERIC_MULTI_VALUE_CONFLICT',True,'KEEP_BLOCK_PENDING_EXPLICIT_SCHEMA')
        return ('TRUE_SAME_SCOPE_VERIFIED_VALUE_CONFLICT',True,'KEEP_BLOCK')
    return ('OTHER_CONSERVATIVE_CONFLICT',True,'KEEP_BLOCK')

def build_image_index(images):
    byprod=defaultdict(list); fact_sources=defaultdict(list)
    for img in images:
        pid=str(img.get('product_id') or ''); byprod[pid].append(img)
        for bucket in ('verified_facts','conflict_facts','unknown_facts','forbidden_facts'):
            for f in img.get(bucket) or []:
                fact_sources[(pid,fact_sig(f))].append((int(img['sequence']),bucket,img,f))
    return byprod,fact_sources

def classify_product_new_conflict(pid,pf,byprod):
    t=norm_type(pf); sc=scope_tuple(pf); val=norm_value(pf.get('value'))
    candidates=[]
    for img in byprod.get(pid,[]):
        for f in img.get('verified_facts') or []:
            if norm_type(f)==t: candidates.append((img,f))
    same_scope=[(i,f) for i,f in candidates if scope_tuple(f)==sc]
    scoped=[(i,f) for i,f in candidates if scope_tuple(f)]
    unscoped=[(i,f) for i,f in candidates if not scope_tuple(f)]
    seqs=sorted({int(i['sequence']) for i,f in same_scope if norm_value(f.get('value'))==val})
    values={norm_value(f.get('value')) for i,f in same_scope}
    if not sc and scoped and unscoped:
        return ('PRODUCT_UNSCOPED_VS_VARIANT_SCOPE_COMPARISON',False,'PRODUCT_SCOPE_COMPARISON_ONLY',seqs)
    if is_text_like(t) and len(values)>1:
        return ('CROSS_IMAGE_COMPLEMENTARY_TEXT_FALSE_CONFLICT',False,'PRODUCT_AGGREGATION_COMPARISON_ONLY',seqs)
    compact={compact_value(f.get('value')) for i,f in same_scope if compact_value(f.get('value'))}
    if len(compact)<=1 and len(same_scope)>1:
        return ('CROSS_IMAGE_FORMATTING_DUPLICATE_FALSE_CONFLICT',False,'VALUE_NORMALIZATION_ONLY',seqs)
    if len(values)>1:
        return ('TRUE_CROSS_IMAGE_SAME_SCOPE_VERIFIED_CONFLICT',True,'KEEP_BLOCK',seqs)
    return ('PRODUCT_AGGREGATION_CARRYOVER_OR_AMBIGUOUS',True,'KEEP_BLOCK',seqs)

def audit(a):
    images=read_jsonl(a.images); products=read_jsonl(a.products); summary=read_json(a.summary); validation=read_json(a.validation); canonical=read_jsonl(a.canonical)
    if len(images)!=EXPECTED_IMAGES: raise RuntimeError(f'Expected {EXPECTED_IMAGES} image rows, got {len(images)}')
    if len(products)!=EXPECTED_PRODUCTS: raise RuntimeError(f'Expected {EXPECTED_PRODUCTS} products, got {len(products)}')
    if int(summary.get('conflict_fact_count',-1))!=EXPECTED_CONFLICTS: raise RuntimeError('Frozen V4-C3 conflict count changed')
    if int((summary.get('eligibility_counts') or {}).get('ELIGIBLE_PARTIAL',-1))!=EXPECTED_ELIGIBLE_PARTIAL: raise RuntimeError('Frozen V4-C3 eligible partial changed')
    if not validation.get('passed'): raise RuntimeError('Frozen V4-C3 validation is not PASS')
    can_part={int(r['sequence']) for r in canonical if r.get('final_status')=='PARTIAL_SAFE'}
    if can_part!={int(r['sequence']) for r in images}: raise RuntimeError('Canonical PARTIAL_SAFE / image gate reconciliation mismatch')
    byprod,fact_sources=build_image_index(images)

    audit_rows=[]; root=Counter(); true_count=false_count=0
    image_conflict_sigs_by_product=defaultdict(set)
    for img in images:
        for f in img.get('conflict_facts') or []:
            rc,truth,fix=classify_image_conflict(img,f)
            root[rc]+=1; true_count+=int(truth); false_count+=int(not truth)
            image_conflict_sigs_by_product[str(img.get('product_id') or '')].add(fact_sig(f))
            audit_rows.append({
              'schema_version':SCHEMA,'audit_level':'IMAGE_CURRENT_CONFLICT','sequence':int(img['sequence']),
              'product_id':str(img.get('product_id') or ''),'fact_id':f.get('fact_id'),'claim_type':f.get('claim_type'),
              'variant_scope':f.get('variant_scope') or [],'current_classification':'FACT_CONFLICT','current_reason':f.get('reason'),
              'root_cause':rc,'true_conflict':bool(truth),'false_conflict':bool(not truth),
              'source_evidence_reference':evidence_ref(img,f),'recommended_fix_scope':fix
            })
    if len(audit_rows)!=EXPECTED_CONFLICTS: raise RuntimeError(f'Image conflict audit reconciliation failed: {len(audit_rows)}')

    # Product aggregation-induced conflicts = facts present as product conflict but not already image conflict.
    aggregation_rows=[]; aggregation_root=Counter(); aggregation_true=aggregation_false=0
    product_by={str(p.get('product_id') or ''):p for p in products}
    for p in products:
        pid=str(p.get('product_id') or '')
        existing=image_conflict_sigs_by_product.get(pid,set())
        for pf in p.get('conflict_facts') or []:
            sig=fact_sig(pf)
            if sig in existing: continue
            rc,truth,fix,seqs=classify_product_new_conflict(pid,pf,byprod)
            aggregation_root[rc]+=1; aggregation_true+=int(truth); aggregation_false+=int(not truth)
            seq=seqs[0] if seqs else (min(p.get('sequences') or [0]))
            srcimg=next((x for x in byprod.get(pid,[]) if int(x['sequence'])==seq),None)
            aggregation_rows.append({
              'schema_version':SCHEMA,'audit_level':'PRODUCT_AGGREGATION_INDUCED','sequence':int(seq),
              'product_id':pid,'fact_id':pf.get('fact_id'),'claim_type':pf.get('claim_type'),
              'variant_scope':pf.get('variant_scope') or [],'current_classification':'FACT_CONFLICT','current_reason':pf.get('reason'),
              'root_cause':rc,'true_conflict':bool(truth),'false_conflict':bool(not truth),
              'source_evidence_reference':evidence_ref(srcimg or {'evidence_source':'unknown'},pf),
              'recommended_fix_scope':fix,'source_sequences':seqs
            })

    # Product block reasons, including the exact any-one-image-block propagation rule.
    p_reason=Counter(); prod_rows=[]
    image_elig_byprod={pid:Counter(str(x.get('generation_eligibility')) for x in items) for pid,items in byprod.items()}
    new_agg_byprod=Counter(r['product_id'] for r in aggregation_rows)
    for p in products:
        pid=str(p.get('product_id') or ''); counts=image_elig_byprod.get(pid,Counter())
        reasons=[]
        if counts.get('BLOCK_FACTUAL',0)>0: reasons.append('SIBLING_IMAGE_BLOCK_PROPAGATION')
        if new_agg_byprod.get(pid,0)>0: reasons.append('PRODUCT_AGGREGATION_INDUCED_CONFLICT')
        if p.get('conflict_facts'): reasons.append('PRODUCT_HAS_CONFLICT_FACTS')
        if not p.get('verified_facts'): reasons.append('PRODUCT_NO_VERIFIED_FACTS')
        if not reasons: reasons.append('NO_BLOCK_REASON')
        for r in reasons: p_reason[r]+=1
        prod_rows.append({'product_id':pid,'generation_eligibility':p.get('generation_eligibility'),'image_eligibility_counts':dict(counts),'block_reasons':reasons,'aggregation_induced_conflicts':int(new_agg_byprod.get(pid,0)),'downstream_generation_allowed':bool(p.get('downstream_generation_allowed'))})

    eligible_imgs=[x for x in images if x.get('generation_eligibility')=='ELIGIBLE_PARTIAL']
    ep_reason=Counter(); ep_products=set(); ep_rows=[]
    for img in eligible_imgs:
        pid=str(img.get('product_id') or ''); p=product_by.get(pid,{})
        ep_products.add(pid); reasons=[]
        sib=[x for x in byprod.get(pid,[]) if int(x['sequence'])!=int(img['sequence'])]
        if any(x.get('generation_eligibility')=='BLOCK_FACTUAL' for x in sib): reasons.append('SIBLING_IMAGE_BLOCK_FACTUAL')
        if new_agg_byprod.get(pid,0)>0: reasons.append('PRODUCT_AGGREGATION_INDUCED_CONFLICT')
        if p.get('generation_eligibility')=='BLOCK_FACTUAL' and not reasons: reasons.append('PRODUCT_EXISTING_CONFLICT_CARRYOVER')
        if p.get('generation_eligibility')=='HOLD_FACTUAL': reasons.append('PRODUCT_HOLD_FACTUAL')
        if p.get('downstream_generation_allowed'): reasons.append('PRODUCT_ALLOWED_UNEXPECTED')
        for r in reasons: ep_reason[r]+=1
        ep_rows.append({'sequence':int(img['sequence']),'product_id':pid,'image_eligibility':'ELIGIBLE_PARTIAL','product_eligibility':p.get('generation_eligibility'),'product_downstream_generation_allowed':bool(p.get('downstream_generation_allowed')),'blocking_reasons':reasons})

    # Distinct audit metrics requested by user.
    cross_image_false=sum(v for k,v in aggregation_root.items() if k.startswith('CROSS_IMAGE_') and 'FALSE' in k)
    variant_scope_false=root.get('UNSCOPED_VS_VARIANT_SCOPE_COMPARISON',0)+aggregation_root.get('PRODUCT_UNSCOPED_VS_VARIANT_SCOPE_COMPARISON',0)
    malformed_false=sum(v for k,v in root.items() if 'MALFORMED' in k or 'DUPLICATE' in k)+sum(v for k,v in aggregation_root.items() if 'DUPLICATE' in k)
    aggregation_induced=len(aggregation_rows)
    safe_fix_image=sum(1 for r in audit_rows if r['false_conflict'])
    safe_fix_agg=sum(1 for r in aggregation_rows if r['false_conflict'])
    safe_fix=safe_fix_image+safe_fix_agg
    keep_block=true_count+aggregation_true

    root_summary={
      'schema_version':'v4c3.1.conflict-root-cause-summary.1','passed':True,
      'current_image_fact_conflicts_total':len(audit_rows),'current_image_root_cause_counts':dict(sorted(root.items())),
      'current_image_true_conflicts':true_count,'current_image_false_conflicts':false_count,
      'product_aggregation_induced_conflicts':aggregation_induced,'product_aggregation_root_cause_counts':dict(sorted(aggregation_root.items())),
      'product_aggregation_true_conflicts':aggregation_true,'product_aggregation_false_conflicts':aggregation_false,
      'cross_image_false_conflicts':cross_image_false,'variant_scope_conflicts':variant_scope_false,
      'malformed_or_duplicate_evidence_conflicts':malformed_false,
      'safely_fixable_by_aggregation_or_comparison_only':safe_fix,'conflicts_requiring_block_or_new_explicit_evidence':keep_block,
      'api_flags':zflags()
    }
    block_summary={
      'schema_version':'v4c3.1.product-block-reason-summary.1','product_count':len(products),
      'product_eligibility_counts':dict(Counter(str(p.get('generation_eligibility')) for p in products)),
      'block_reason_product_counts':dict(sorted(p_reason.items())),
      'any_single_block_image_propagates_product_block':True,
      'products_with_at_least_one_block_image':sum(1 for pid,c in image_elig_byprod.items() if c.get('BLOCK_FACTUAL',0)>0),
      'products_with_aggregation_induced_conflict':sum(1 for pid in product_by if new_agg_byprod.get(pid,0)>0),
      'products':prod_rows,'api_flags':zflags()
    }
    ep={
      'schema_version':'v4c3.1.eligible-partial-block-analysis.1','eligible_partial_images':len(eligible_imgs),
      'eligible_partial_distinct_products':len(ep_products),'generation_queue_count':int(summary.get('downstream_generation_eligible_count',-1)),
      'blocking_reason_image_counts':dict(sorted(ep_reason.items())),
      'explanation':'The queue requires BOTH image-level downstream_generation_allowed and product-level downstream_generation_allowed. Every ELIGIBLE_PARTIAL image belongs to a product that is not downstream-eligible under the frozen V4-C3 product aggregation.',
      'records':ep_rows,'api_flags':zflags()
    }
    write_json(a.root_summary,root_summary)
    write_jsonl(a.audit_out,audit_rows+aggregation_rows)
    write_json(a.product_summary,block_summary)
    write_json(a.eligible_analysis,ep)
    validation_out={
      'schema_version':'v4c3.1.audit-validation.1','passed':True,'image_conflicts_reconciled':len(audit_rows),
      'expected_image_conflicts':EXPECTED_CONFLICTS,'eligible_partial_reconciled':len(eligible_imgs),
      'expected_eligible_partial':EXPECTED_ELIGIBLE_PARTIAL,'audit_did_not_modify_gate':True,'api_flags':zflags()
    }
    write_json(a.validation_out,validation_out)
    print(json.dumps(root_summary,ensure_ascii=False,sort_keys=True))
    print('ELIGIBLE_PARTIAL_IMAGES='+str(len(eligible_imgs)))
    print('ELIGIBLE_PARTIAL_PRODUCTS='+str(len(ep_products)))
    print('GENERATION_QUEUE='+str(summary.get('downstream_generation_eligible_count')))

def main():
    ap=argparse.ArgumentParser();
    ap.add_argument('--images',required=True); ap.add_argument('--products',required=True); ap.add_argument('--summary',required=True); ap.add_argument('--validation',required=True); ap.add_argument('--canonical',required=True)
    ap.add_argument('--root-summary',required=True); ap.add_argument('--audit-out',required=True); ap.add_argument('--product-summary',required=True); ap.add_argument('--eligible-analysis',required=True); ap.add_argument('--validation-out',required=True)
    a=ap.parse_args(); audit(a)

if __name__=='__main__': main()
