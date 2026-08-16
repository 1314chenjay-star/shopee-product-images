#!/usr/bin/env python3
"""TinySnow Identity-First Persistent Memory Runtime.

Runtime queries SQLite lazily. JSONL is audit/backup/migration only and is never
parsed during normal single-product lookup. Facts are retrieved only after exact
product + source SHA + variant scope identity is fixed. Category/template memory
is returned in separate guard/layout buckets and can never become product facts.
"""
import argparse, hashlib, json, re, sqlite3
from pathlib import Path

MEMORY_SCHEMA_VERSION='tinysnow.memory.v1.1.0'
SQLITE_SCHEMA_VERSION=2
VALID_SLOTS={'MAIN','DETAIL_1','DETAIL_2','DETAIL_3','DETAIL_4'}
ACTIONS={'APPROVE','REJECT','REPLACE','LOCK','UNLOCK','SUPERSEDE','REVOKE_FACT'}
SAFE_FACT_STATUS={'VERIFIED_SOURCE','HUMAN_CONFIRMED','LOCKED_APPROVED'}
IDENTITY_CLAIMS={'brand','model','product_identity','variant_identity','variant_mapping','sku'}

def _canon(x): return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def _sha(v): return isinstance(v,str) and re.fullmatch(r'[0-9a-fA-F]{64}',v.strip()) is not None
def _scope_key(v): return _canon(sorted(str(x) for x in (v or [])))
def _loads(v,default):
    if v in (None,''): return default
    return json.loads(v)
def _id(prefix,payload): return prefix+'_'+hashlib.sha256(_canon(payload).encode('utf-8')).hexdigest()[:24]
def _db_path(memory):
    p=Path(memory)
    return p if p.suffix.lower() in {'.sqlite','.db'} else p/'tinysnow_memory.sqlite'
def _connect(memory,readonly=True):
    p=_db_path(memory)
    if not p.exists(): raise FileNotFoundError(str(p))
    if readonly:
        con=sqlite3.connect('file:'+p.resolve().as_posix()+'?mode=ro',uri=True,timeout=5.0)
        con.execute('pragma query_only=ON')
    else:
        con=sqlite3.connect(str(p),timeout=5.0)
    con.row_factory=sqlite3.Row
    con.execute('pragma busy_timeout=5000')
    con.execute('pragma foreign_keys=ON')
    return con

def _payload(row): return json.loads(row['payload_json'])
def _risk_profile(category,subcategory):
    s=(' '.join([str(category or ''),str(subcategory or '')])).lower()
    if 'apparel' in s or 'clothes' in s: return 'apparel'
    if 'bag' in s: return 'bags'
    if 'footwear' in s or 'shoe' in s: return 'footwear'
    if 'camp' in s: return 'camping'
    if 'water' in s or 'life' in s: return 'water_sports_safety'
    if 'fitness' in s: return 'fitness'
    if 'outdoor' in s: return 'outdoor'
    if 'sport' in s or 'ball' in s or 'racket' in s or 'billiard' in s or 'golf' in s: return 'sports'
    if 'pet' in s: return 'pet'
    if 'home' in s or 'garden' in s: return 'home'
    return 'general_merchandise'

def memory_safe_lookup(memory,product_id,source_sha256,variant_scope=None,slot=None,category=None,subcategory=None):
    """Identity-first lazy lookup returning strictly segregated memory buckets."""
    if not _sha(source_sha256): raise ValueError('source_sha256 must be exact 64-hex SHA256')
    if slot is not None and slot not in VALID_SLOTS: raise ValueError('invalid canonical slot')
    sha=source_sha256.lower(); scope=list(variant_scope or []); sk=_scope_key(scope)
    con=_connect(memory,True)
    try:
        exact_rows=con.execute('''select payload_json from active_approved_outputs
          where product_id=? and source_sha256=? and variant_scope_key=? and canonical_slot=?''',(product_id,sha,sk,slot)).fetchall() if slot else []
        exact=[_payload(r) for r in exact_rows]
        conflict_rows=con.execute('''select memory_id,product_id,variant_scope_key,canonical_slot from active_approved_outputs
          where source_sha256=? and (product_id<>? or variant_scope_key<>? or (? is not null and canonical_slot<>?))''',(sha,product_id,sk,slot,slot)).fetchall()
        identity_conflicts=[{'memory_id':r['memory_id'],'stored_product_id':r['product_id'],'reason':'MEMORY_IDENTITY_CONFLICT' if r['product_id']!=product_id else ('MEMORY_VARIANT_SCOPE_MISMATCH' if r['variant_scope_key']!=sk else 'MEMORY_SLOT_INCOMPATIBLE')} for r in conflict_rows]
        fact_rows=con.execute('''select payload_json from active_verified_facts
          where product_id=? and source_sha256=? and variant_scope_key=?''',(product_id,sha,sk)).fetchall()
        facts=[_payload(r) for r in fact_rows]
        product_facts=[x for x in facts if x.get('scope')=='PRODUCT']
        variant_facts=[x for x in facts if x.get('scope')=='VARIANT']
        image_facts=[x for x in facts if x.get('scope') in {'IMAGE','SLOT'}]
        immutable=[x for x in facts if str(x.get('claim_type') or '').lower() in IDENTITY_CLAIMS]
        profile=_risk_profile(category,subcategory)
        risk_rows=con.execute('select payload_json from category_risk_memory where profile_id=?',(profile,)).fetchall()
        risks=[_payload(r) for r in risk_rows]
        template_rows=con.execute('''select payload_json from active_layout_templates
          where template_scope in ('generic',?) order by case when template_scope='generic' then 0 else 1 end, template_id''',(profile,)).fetchall()
        templates=[_payload(r) for r in template_rows]
        feedback_rows=con.execute('''select payload_json from edit_feedback_memory
          where product_id=? and do_not_repeat=1 order by created_at,memory_id''',(product_id,)).fetchall()
        errors=[_payload(r) for r in feedback_rows]
        locked=con.execute('select payload_json from locked_product_registry where product_id=? and locked=1',(product_id,)).fetchone()
        provenance=[{'memory_id':x.get('memory_id'),'source_stage':x.get('source_stage'),'source_commit':x.get('source_commit'),'evidence_reference':x.get('evidence_reference')} for x in facts]
        blocked=list(identity_conflicts)
        return {'reusable_approved_outputs':exact,'verified_product_facts':product_facts,'verified_variant_facts':variant_facts,'verified_image_facts':image_facts,'immutable_fields':immutable,'category_risk_guards':risks,'previous_error_guards':errors,'layout_templates':templates,'blocked_memory':blocked,'identity_conflicts':identity_conflicts,'provenance':provenance,'locked_product':_payload(locked) if locked else None,'resolver_mode':'SQLITE_LAZY_IDENTITY_FIRST'}
    finally: con.close()

def pre_generation_regression_check(memory,product_id,category=None,subcategory=None,variant_scope=None):
    con=_connect(memory,True); profile=_risk_profile(category,subcategory)
    try:
        patterns=[r['blocked_pattern'] for r in con.execute('select blocked_pattern from active_regression_cases where product_id=?',(product_id,)).fetchall()]
        guards=[r['rejected_change'] for r in con.execute('select rejected_change from edit_feedback_memory where product_id=? and do_not_repeat=1',(product_id,)).fetchall()]
        risk=con.execute('select risk_fields_json from category_risk_memory where profile_id=?',(profile,)).fetchone()
        locked=con.execute('select 1 from locked_product_registry where product_id=? and locked=1',(product_id,)).fetchone() is not None
        return {'blocked_error_patterns':patterns,'product_specific_guards':guards,'category_risk_guards':_loads(risk['risk_fields_json'],[]) if risk else [],'immutable_fields':['product_identity','brand','model','variant_mapping'] if locked else [],'previous_rejected_changes':guards,'locked_product':locked,'variant_scope':list(variant_scope or [])}
    finally: con.close()

def resolve_generation_context(memory,identity,category=None,subcategory=None):
    required=('product_id','source_id','source_sha256','slot')
    for k in required:
        if not identity.get(k): return {'status':'HOLD_CONTEXT','reasons':['MISSING_IDENTITY_'+k.upper()],'generation_context':None}
    scope=list(identity.get('variant_scope') or [])
    look=memory_safe_lookup(memory,identity['product_id'],identity['source_sha256'],scope,identity['slot'],category,subcategory)
    if look['reusable_approved_outputs']:
        return {'status':'MEMORY_REUSE','reasons':[],'approved_output':look['reusable_approved_outputs'][0],'generation_context':None,'identity_conflicts':look['identity_conflicts']}
    if look['locked_product']:
        return {'status':'HOLD_CONTEXT','reasons':['LOCKED_PRODUCT_REGENERATION_FORBIDDEN'],'generation_context':None,'identity_conflicts':look['identity_conflicts']}
    facts=look['verified_product_facts']+look['verified_variant_facts']+look['verified_image_facts']
    safe_ids=[x['memory_id'] for x in facts]
    excluded_unknown=[]; excluded_conflict=[]; excluded_forbidden=[]
    ctx={'memory_schema_version':MEMORY_SCHEMA_VERSION,'identity':{'product_id':identity['product_id'],'source_id':identity['source_id'],'source_sha256':identity['source_sha256'].lower(),'variant_scope':scope,'slot':identity['slot']},'exact_source_reference':identity.get('source_url_reference'),'safe_facts':facts,'safe_fact_ids':safe_ids,'immutable_fields':look['immutable_fields'],'excluded_unknown_ids':excluded_unknown,'excluded_conflict_ids':excluded_conflict,'excluded_forbidden_ids':excluded_forbidden,'previous_error_guards':look['previous_error_guards'],'category_risk_guards':look['category_risk_guards'],'approved_layout_template':look['layout_templates'][0] if look['layout_templates'] else None,'provenance':look['provenance'],'identity_conflicts':look['identity_conflicts'],'context_minimized':True}
    v=context_validation(ctx)
    return {'status':'CONTEXT_READY' if v['passed'] else 'HOLD_CONTEXT','reasons':v['reasons'],'generation_context':ctx if v['passed'] else None,'validation':v,'identity_conflicts':look['identity_conflicts']}

def context_validation(ctx):
    reasons=[]; ident=ctx.get('identity') or {}; pid=str(ident.get('product_id') or ''); sha=str(ident.get('source_sha256') or '').lower(); scope=list(ident.get('variant_scope') or []); slot=ident.get('slot')
    if not pid: reasons.append('PRODUCT_ID_MISSING')
    if not _sha(sha): reasons.append('SOURCE_SHA_MISMATCH_OR_INVALID')
    if slot not in VALID_SLOTS: reasons.append('SLOT_MISMATCH_OR_INVALID')
    fact_ids=set(ctx.get('safe_fact_ids') or [])
    for f in ctx.get('safe_facts') or []:
        if f.get('memory_id') not in fact_ids: reasons.append('FACT_ID_PAYLOAD_MISMATCH')
        if f.get('product_id')!=pid: reasons.append('MEMORY_BELONGS_TO_ANOTHER_PRODUCT')
        if f.get('source_sha256')!=sha: reasons.append('SOURCE_SHA_MISMATCH')
        if list(f.get('variant_scope') or [])!=scope: reasons.append('VARIANT_MISMATCH')
        if f.get('status') not in SAFE_FACT_STATUS: reasons.append('UNKNOWN_CONFLICT_OR_FORBIDDEN_FACT_INCLUDED')
        if f.get('allowed_usage') in (None,'','NONE'): reasons.append('FACT_NOT_ALLOWED_FOR_USE')
        if not f.get('evidence_reference'): reasons.append('FACT_MISSING_PROVENANCE')
        if f.get('revoked'): reasons.append('REVOKED_FACT_INCLUDED')
        if f.get('superseded_by'): reasons.append('SUPERSEDED_FACT_INCLUDED')
        if f.get('scope') not in {'PRODUCT','VARIANT','IMAGE','SLOT'}: reasons.append('NON_FACT_MEMORY_IN_FACT_PAYLOAD')
    if ctx.get('identity_conflicts'): reasons.append('IDENTITY_CRITICAL_MISMATCH')
    for t in (ctx.get('category_risk_guards') or []):
        if t.get('may_supply_product_fact'): reasons.append('CATEGORY_FACT_CONTAMINATION')
    tpl=ctx.get('approved_layout_template')
    if tpl and (tpl.get('fact_payload') or tpl.get('may_reuse_product_facts')): reasons.append('TEMPLATE_FACT_CONTAMINATION')
    return {'passed':len(reasons)==0,'status':'PASS' if not reasons else 'HOLD_CONTEXT','reasons':sorted(set(reasons))}

def validate_memory_action(action,payload):
    action=str(action or '').upper()
    if action not in ACTIONS: raise ValueError('unsupported action')
    if action=='APPROVE':
        if payload.get('human_approved') is not True: raise ValueError('APPROVE requires explicit human_approved=true')
        if not all(payload.get(x) is True for x in ('auto_qa_passed','factual_qa_passed','visual_qa_passed')): raise ValueError('APPROVE requires AUTO_QA + FACTUAL_QA + VISUAL_QA PASS')
        if payload.get('canonical_slot') not in VALID_SLOTS: raise ValueError('APPROVE requires canonical slot')
        for k in ('source_sha256','output_sha256'):
            if not _sha(payload.get(k)): raise ValueError('APPROVE requires valid '+k)
    if action=='REJECT' and not payload.get('error_type'): raise ValueError('REJECT requires error_type')
    if action=='UNLOCK' and payload.get('explicit_human_unlock') is not True: raise ValueError('UNLOCK requires explicit_human_unlock=true')
    if action=='REVOKE_FACT' and not payload.get('memory_id'): raise ValueError('REVOKE_FACT requires memory_id')
    return True

def record_memory_action(memory,action,payload):
    """Transactional single-writer append. JSONL export is produced by maintenance/export, not runtime lookup."""
    validate_memory_action(action,payload); action=str(action).upper(); eid=_id('event_action',{'action':action,'payload':payload})
    event={'memory_schema_version':MEMORY_SCHEMA_VERSION,'event_id':eid,'event_type':'USER_'+action,'action':action,'product_id':payload.get('product_id'),'payload':payload,'append_only':True}
    con=_connect(memory,False)
    try:
        con.execute('pragma journal_mode=WAL'); con.execute('pragma synchronous=FULL'); con.execute('begin immediate')
        con.execute('insert into memory_event_log(event_id,product_id,event_type,active,payload_json) values (?,?,?,?,?)',(eid,payload.get('product_id'),'USER_'+action,1,_canon(event)))
        con.commit(); return event
    except Exception:
        con.rollback(); raise
    finally: con.close()

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('lookup'); p.add_argument('--memory',required=True); p.add_argument('--product-id',required=True); p.add_argument('--source-sha256',required=True); p.add_argument('--slot'); p.add_argument('--category'); p.add_argument('--subcategory'); p.add_argument('--variant-scope-json',default='[]')
    p=sub.add_parser('regression'); p.add_argument('--memory',required=True); p.add_argument('--product-id',required=True); p.add_argument('--category'); p.add_argument('--subcategory'); p.add_argument('--variant-scope-json',default='[]')
    p=sub.add_parser('context'); p.add_argument('--memory',required=True); p.add_argument('--identity-json',required=True); p.add_argument('--category'); p.add_argument('--subcategory')
    p=sub.add_parser('event'); p.add_argument('--memory',required=True); p.add_argument('--action',required=True); p.add_argument('--payload-json',required=True)
    a=ap.parse_args()
    if a.cmd=='lookup': result=memory_safe_lookup(a.memory,a.product_id,a.source_sha256,json.loads(a.variant_scope_json),a.slot,a.category,a.subcategory)
    elif a.cmd=='regression': result=pre_generation_regression_check(a.memory,a.product_id,a.category,a.subcategory,json.loads(a.variant_scope_json))
    elif a.cmd=='context': result=resolve_generation_context(a.memory,json.loads(a.identity_json),a.category,a.subcategory)
    else: result=record_memory_action(a.memory,a.action,json.loads(a.payload_json))
    print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__': main()
