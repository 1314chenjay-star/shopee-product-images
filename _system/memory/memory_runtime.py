#!/usr/bin/env python3
"""TinySnow persistent memory runtime interface.

All-category, provenance-first memory access. This module never treats category
memory, templates, previous errors, UNKNOWN, conflicts, or forbidden claims as
product facts. It is Python stdlib-only and callable from Windows PowerShell 5.1.
"""
import argparse, hashlib, json, re
from pathlib import Path

MEMORY_SCHEMA_VERSION='tinysnow.memory.v1.0.0'
ACTIONS={'APPROVE','REJECT','REPLACE','LOCK','UNLOCK','SUPERSEDE','REVOKE_FACT'}
SAFE_FACT_STATUS={'VERIFIED_SOURCE','HUMAN_CONFIRMED','LOCKED_APPROVED'}
VALID_SLOTS={'MAIN','DETAIL_1','DETAIL_2','DETAIL_3','DETAIL_4'}

def _read_json(path): return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def _read_jsonl(path):
    p=Path(path); out=[]
    if not p.exists(): return out
    with p.open(encoding='utf-8-sig') as f:
        for line in f:
            if line.strip(): out.append(json.loads(line))
    return out

def _canon(x): return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def _sha(v): return isinstance(v,str) and re.fullmatch(r'[0-9a-fA-F]{64}',v.strip()) is not None
def _active(x): return not x.get('revoked') and not x.get('superseded') and x.get('active',True)
def _variant(v): return list(v or [])
def _id(prefix,payload): return prefix+'_'+hashlib.sha256(_canon(payload).encode('utf-8')).hexdigest()[:24]

def load_memory(memory_dir):
    d=Path(memory_dir)
    return {
      'facts':_read_jsonl(d/'approved_fact_memory.jsonl'),
      'outputs':_read_jsonl(d/'approved_output_memory.jsonl'),
      'feedback':_read_jsonl(d/'edit_feedback_memory.jsonl'),
      'regression':_read_jsonl(d/'regression_cases.jsonl'),
      'templates':_read_jsonl(d/'reusable_template_registry.jsonl'),
      'risks':_read_json(d/'category_risk_memory.json'),
      'locked':_read_json(d/'locked_product_registry.json'),
      'index':_read_json(d/'memory_index.json')
    }

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

def memory_safe_lookup(memory_dir, product_id, source_sha256, variant_scope=None, slot=None, category=None, subcategory=None):
    """Return segregated memory buckets; never concatenate memory into one prompt."""
    if not _sha(source_sha256): raise ValueError('source_sha256 must be exact 64-hex SHA256')
    if slot is not None and slot not in VALID_SLOTS: raise ValueError('invalid slot')
    m=load_memory(memory_dir); scope=_variant(variant_scope); sha=source_sha256.lower(); blocked=[]; reusable=[]
    for r in m['outputs']:
        if not _active(r) or not r.get('reusable') or r.get('approval_status') not in {'LOCKED_APPROVED','HUMAN_CONFIRMED','RULE_VALIDATED'}: continue
        if r.get('source_sha256')!=sha: continue
        if r.get('product_id')!=product_id:
            blocked.append({'memory_id':r.get('memory_id'),'reason':'MEMORY_IDENTITY_CONFLICT','stored_product_id':r.get('product_id')}); continue
        if _variant(r.get('variant_scope'))!=scope:
            blocked.append({'memory_id':r.get('memory_id'),'reason':'MEMORY_VARIANT_SCOPE_MISMATCH'}); continue
        if slot and r.get('canonical_slot')!=slot:
            blocked.append({'memory_id':r.get('memory_id'),'reason':'MEMORY_SLOT_INCOMPATIBLE'}); continue
        reusable.append(r)
    facts=[]
    for r in m['facts']:
        if not _active(r) or not r.get('reusable'): continue
        if r.get('status') not in SAFE_FACT_STATUS: continue
        if r.get('product_id')!=product_id or r.get('source_sha256')!=sha or _variant(r.get('variant_scope'))!=scope: continue
        if r.get('allowed_usage') in (None,'','NONE'): continue
        facts.append(r)
    profile=_risk_profile(category,subcategory)
    risk=[x for x in m['risks'].get('profiles',[]) if x.get('profile_id')==profile]
    templates=[x for x in m['templates'] if x.get('scope') in ('generic',profile) and x.get('reusable') and not x.get('fact_payload')]
    errors=[x for x in m['feedback'] if x.get('product_id')==product_id and x.get('do_not_repeat')]
    return {'reusable_approved_outputs':reusable,'verified_facts':facts,'risk_guards':risk,'layout_templates':templates,'previous_errors':errors,'blocked_memory':blocked}

def pre_generation_regression_check(memory_dir, product_id, category=None, subcategory=None, variant_scope=None):
    m=load_memory(memory_dir); profile=_risk_profile(category,subcategory); locked={x.get('product_id') for x in m['locked'].get('products',[]) if x.get('locked')}
    return {'blocked_error_patterns':[x.get('blocked_pattern') for x in m['regression'] if x.get('product_id')==product_id and x.get('active')],'product_specific_guards':[x.get('rejected_change') for x in m['feedback'] if x.get('product_id')==product_id and x.get('do_not_repeat')],'category_risk_guards':next((x.get('risk_fields',[]) for x in m['risks'].get('profiles',[]) if x.get('profile_id')==profile),[]),'immutable_fields':['product_identity','brand','model','variant_mapping'] if product_id in locked else [],'previous_rejected_changes':[x.get('rejected_change') for x in m['feedback'] if x.get('product_id')==product_id],'locked_product':product_id in locked,'variant_scope':_variant(variant_scope)}

def validate_memory_action(action,payload):
    action=str(action or '').upper()
    if action not in ACTIONS: raise ValueError('unsupported action')
    if action=='APPROVE':
        if payload.get('human_approved') is not True: raise ValueError('APPROVE requires explicit human_approved=true')
        if not all(payload.get(x) is True for x in ('auto_qa_passed','factual_qa_passed','visual_qa_passed')): raise ValueError('APPROVE requires all QA gates PASS')
        if payload.get('canonical_slot') not in VALID_SLOTS: raise ValueError('APPROVE requires canonical slot')
        for k in ('source_sha256','output_sha256'):
            if not _sha(payload.get(k)): raise ValueError('APPROVE requires valid '+k)
    if action=='REJECT' and not payload.get('error_type'): raise ValueError('REJECT requires error_type')
    if action=='UNLOCK' and payload.get('explicit_human_unlock') is not True: raise ValueError('UNLOCK requires explicit_human_unlock=true')
    if action=='REVOKE_FACT' and not payload.get('memory_id'): raise ValueError('REVOKE_FACT requires memory_id')
    return True

def record_memory_action(memory_dir, action, payload):
    """Append an auditable event. State-materialization is a later transactional step."""
    validate_memory_action(action,payload); d=Path(memory_dir); path=d/'memory_event_log.jsonl'; action=str(action).upper()
    event={'memory_schema_version':MEMORY_SCHEMA_VERSION,'event_id':_id('event_action',{'action':action,'payload':payload}),'event_type':'USER_'+action,'action':action,'product_id':payload.get('product_id'),'payload':payload,'append_only':True}
    with path.open('a',encoding='utf-8',newline='\n') as f: f.write(json.dumps(event,ensure_ascii=False,separators=(',',':'))+'\n')
    return event

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('lookup'); p.add_argument('--memory-dir',required=True); p.add_argument('--product-id',required=True); p.add_argument('--source-sha256',required=True); p.add_argument('--slot'); p.add_argument('--category'); p.add_argument('--subcategory'); p.add_argument('--variant-scope-json',default='[]')
    p=sub.add_parser('regression'); p.add_argument('--memory-dir',required=True); p.add_argument('--product-id',required=True); p.add_argument('--category'); p.add_argument('--subcategory'); p.add_argument('--variant-scope-json',default='[]')
    p=sub.add_parser('event'); p.add_argument('--memory-dir',required=True); p.add_argument('--action',required=True); p.add_argument('--payload-json',required=True)
    a=ap.parse_args()
    if a.cmd=='lookup': result=memory_safe_lookup(a.memory_dir,a.product_id,a.source_sha256,json.loads(a.variant_scope_json),a.slot,a.category,a.subcategory)
    elif a.cmd=='regression': result=pre_generation_regression_check(a.memory_dir,a.product_id,a.category,a.subcategory,json.loads(a.variant_scope_json))
    else: result=record_memory_action(a.memory_dir,a.action,json.loads(a.payload_json))
    print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__': main()
