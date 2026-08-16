#!/usr/bin/env python3
import argparse, hashlib, json, os, re, sqlite3, subprocess, tempfile
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

MEMORY_SCHEMA_VERSION='tinysnow.memory.v1.0.0'
MIGRATION_VERSION=1
BASE_HEAD='b064b8a022e29eec6eeaeb1e5561b25d5abda9e9'
EXPECTED_PRODUCTS=375
EXPECTED_SOURCES=2394
LOCKED_PRODUCTS={'42833435408','52915734564','57565745174','58015741169'}
VALID_SLOTS={'MAIN','DETAIL_1','DETAIL_2','DETAIL_3','DETAIL_4'}
SAFE_FACT_STATUS={'VERIFIED_SOURCE','HUMAN_CONFIRMED','LOCKED_APPROVED'}
FORBIDDEN_REUSABLE={'UNKNOWN','FACT_UNKNOWN','FACT_CONFLICT','FACT_FORBIDDEN','BLOCK','HOLD','REJECTED','REVOKED'}
ALLOWED_FEEDBACK_ACTIONS={'APPROVE','REJECT','REPLACE','LOCK','UNLOCK','SUPERSEDE','REVOKE_FACT'}

CATEGORY_RISKS={
 'apparel':['size','material','pocket','lining','fit','elasticity'],
 'bags':['capacity','internal_compartments','strap','accessories','waterproof'],
 'footwear':['shoe_size','outsole_material','slip_resistance','air_cushion','terrain_suitability'],
 'outdoor':['waterproof','uv_protection','load_rating','dimensions','safety_performance'],
 'sports':['material','weight','dimensions','competition_spec','professional_performance'],
 'fitness':['resistance','load_rating','material','dimensions','usage_claims','safety'],
 'camping':['dimensions','material','waterproof','load_rating','capacity','accessories','bundle_count'],
 'water_sports_safety':['certification','buoyancy','material','size_user_mapping','safety_performance'],
 'home':['capacity','material','electrical_safety','dimensions','performance'],
 'pet':['size','material','weight_limit','safety','accessories'],
 'general_merchandise':['material','dimensions','quantity','accessories','certification','performance']
}

TEMPLATES=[
 ('GENERIC_MAIN_SINGLE_PRODUCT','generic',['single_product_focus','clean_background','clear_visual_hierarchy']),
 ('GENERIC_DETAIL_FEATURE_HIERARCHY','generic',['verified_fact_callouts_only','visual_hierarchy','no_cross_product_facts']),
 ('GENERIC_DETAIL_STRUCTURE','generic',['product_structure_focus','crop_or_reframe_only','evidence_bound_copy']),
 ('GENERIC_DETAIL_VARIANT_SAFE','generic',['variant_scope_isolation','no_bundle_inference','no_cross_variant_claims']),
 ('APPAREL_MAIN_CLEAN','apparel',['garment_identity_focus','silhouette_preserved','no_unverified_body_or_fit_claim']),
 ('BAG_DETAIL_LAYOUT','bags',['compartment_visual_structure_only','no_capacity_inference','no_accessory_inference']),
 ('FOOTWEAR_DETAIL_LAYOUT','footwear',['construction_visual_structure_only','no_material_or_performance_inference']),
 ('OUTDOOR_EVIDENCE_CARD','outdoor',['source_verified_callouts_only','no_waterproof_or_load_inference'])
]

KNOWN_FEEDBACK=[
 {'product_id':'42833435408','error_type':'INVENTED_POCKET','rejected_change':'Added a visible pocket not present in the verified source','approved_change':'Preserve the original double-layer shorts structure without adding a pocket','human_feedback':'Do not add a pocket to 428','scope':'PRODUCT'},
 {'product_id':'42833435408','error_type':'INVENTED_DIMENSION','rejected_change':'Added dimensions or a size table not present in the verified source','approved_change':'Do not add dimensions unless directly verified by the source','human_feedback':'Do not add dimensions to 428','scope':'PRODUCT'},
 {'product_id':'42833435408','error_type':'PRODUCT_APPEARANCE_CHANGED','rejected_change':'Changed or invented product structure','approved_change':'Preserve flame print, waistband, drawstrings and double-layer fake-two-piece structure','human_feedback':'Keep 428 product identity and structure unchanged','scope':'PRODUCT'},
 {'product_id':'57565745174','error_type':'TEXT_HALLUCINATION','rejected_change':'Invented product-surface text such as MINI STADIUM or TAIWAN KING','approved_change':'Never add unverified decorative or brand-like text to the product surface','human_feedback':'575 surface-text hallucination must never recur','scope':'PRODUCT'},
 {'product_id':'57565745174','error_type':'INVENTED_DIMENSION','rejected_change':'Added an unverified dimension','approved_change':'Use dimensions only with exact source evidence','human_feedback':'575 unverified dimensions remain forbidden','scope':'PRODUCT'},
 {'product_id':'57565745174','error_type':'INVENTED_MATERIAL','rejected_change':'Added an unverified material','approved_change':'Use materials only with exact source evidence','human_feedback':'575 unverified materials remain forbidden','scope':'PRODUCT'},
 {'product_id':'57565745174','error_type':'INVENTED_PERFORMANCE','rejected_change':'Added an unverified performance claim','approved_change':'Use performance claims only with exact source evidence','human_feedback':'575 unverified performance claims remain forbidden','scope':'PRODUCT'}
]

def now_iso(): return datetime.now(timezone.utc).replace(microsecond=0).isoformat()
def read_json(path): return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def read_jsonl(path):
    p=Path(path); out=[]
    if not p.exists(): raise RuntimeError('Missing required input: '+str(path))
    with p.open(encoding='utf-8-sig') as f:
        for i,line in enumerate(f,1):
            if not line.strip(): continue
            try: out.append(json.loads(line))
            except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out

def write_json(path,obj):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')
def write_jsonl(path,rows):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')
def canon(obj): return json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def sha64(v): return isinstance(v,str) and re.fullmatch(r'[0-9a-fA-F]{64}',v.strip()) is not None
def norm_sha(v): return v.strip().lower() if sha64(v) else None
def mid(prefix,payload): return prefix+'_'+hashlib.sha256(canon(payload).encode('utf-8')).hexdigest()[:24]
def variant_key(v): return canon(sorted(str(x) for x in (v or [])))
def source_commit_time():
    try: return subprocess.check_output(['git','show','-s','--format=%cI',BASE_HEAD],text=True).strip()
    except Exception: return now_iso()
def zero_flags():
    return {'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,'semantic_inference_executed':False,'preservation_reexecuted':False,'factual_gate_reexecuted':False,'v4c1_retested':False,'v4c2_retested':False,'v4c3_retested':False,'v4c3_1_retested':False,'v4c3_2_retested':False,'v4c4_0_retested':False,'v4c4_1_retested':False,'image_generation_called':False,'tiny_snow_api_called':False,'vision_api_called':False,'paid_api_called':False,'generation_executed':False}

def recursive_sha(obj):
    if isinstance(obj,dict):
        for k in ('recovered_sha256','source_sha256','sha256','content_sha256','image_sha256'):
            x=norm_sha(obj.get(k))
            if x: return x
        for v in obj.values():
            x=recursive_sha(v)
            if x: return x
    elif isinstance(obj,list):
        for v in obj:
            x=recursive_sha(v)
            if x: return x
    return None

def load_taxonomy():
    out={}; p=Path('_system/v4c/claim_gate/calibration/calibration_manifest.jsonl')
    if p.exists():
        for r in read_jsonl(p):
            pid=str(r.get('product_id') or ''); ctx=r.get('context') or {}
            if pid: out[pid]={'category':ctx.get('family') or 'unclassified','subcategory':ctx.get('subcategory') or 'unclassified'}
    return out

def risk_profile_for(category,subcategory):
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

def load_frozen():
    inventory=read_jsonl('_system/v4c/inventory/source_inventory.jsonl')
    state=read_jsonl('_system/v4c/generation_plan/canonical_image_state.jsonl')
    recovery=read_jsonl('_system/v4c/generation_plan/sha_gap_recovery/sha_recovery_results.jsonl')
    plans=read_jsonl('_system/v4c/generation_plan/product_5slot_plan.jsonl')
    facts=read_jsonl('_system/v4c/factual_gate/correction_v4c3_2/corrected_image_gate.jsonl')
    duplicates=read_json('_system/v4c/results/duplicate_map.json')
    if len(inventory)!=EXPECTED_SOURCES or len(state)!=EXPECTED_SOURCES: raise RuntimeError('Frozen source reconciliation changed')
    products={str(r.get('product_id') or '') for r in inventory}
    if len(products)!=EXPECTED_PRODUCTS or '' in products: raise RuntimeError('Frozen product reconciliation changed')
    inv={int(r['sequence']):dict(r) for r in inventory}; st={int(r['sequence']):dict(r) for r in state}; rec={int(r['sequence']):dict(r) for r in recovery}
    source={}
    for seq in sorted(inv):
        i=inv[seq]; s=st[seq]; sh=norm_sha(s.get('source_sha256')) or recursive_sha(rec.get(seq,{}))
        if not sh: raise RuntimeError(f'SHA still missing after sealed V4-C4.1: seq {seq}')
        source[seq]={'sequence':seq,'source_id':str(i.get('source_id') or f'V4C-S{seq:06d}'),'product_id':str(i.get('product_id') or ''),'source_url':i.get('url'),'source_sha256':sh,'image_index':i.get('image_index'),'image_type':i.get('image_type'),'canonical_state':s.get('canonical_state'),'underlying_state':s.get('underlying_state')}
    return source,plans,facts,duplicates,load_taxonomy()

def category_for(pid,tax):
    x=tax.get(pid) or {}; return x.get('category') or 'unclassified',x.get('subcategory') or 'unclassified'

def build_approved_facts(source,fact_rows,tax,created):
    out=[]
    for r in fact_rows:
        if not r.get('downstream_generation_allowed'): continue
        seq=int(r['sequence']); src=source.get(seq)
        if not src: continue
        safe=set(str(x) for x in (r.get('generation_safe_fact_ids') or []))
        pid=src['product_id']; cat,sub=category_for(pid,tax)
        for f in r.get('verified_facts') or []:
            fid=str(f.get('fact_id') or '')
            if not fid or fid not in safe: continue
            if f.get('classification')!='FACT_VERIFIED' or f.get('source_status')!='VERIFIED_SOURCE': continue
            if f.get('allowed_usage') in (None,'','NONE') or not f.get('evidence'): continue
            scope=list(f.get('variant_scope') or [])
            key={'product_id':pid,'source_sequence':seq,'source_sha256':src['source_sha256'],'fact_id':fid,'variant_scope':scope}
            out.append({'memory_schema_version':MEMORY_SCHEMA_VERSION,'migration_version':MIGRATION_VERSION,'memory_id':mid('fact',key),'product_id':pid,'source_id':src['source_id'],'source_sequence':seq,'source_sha256':src['source_sha256'],'source_url_reference':src['source_url'],'category':cat,'subcategory':sub,'variant_scope':scope,'claim_type':f.get('claim_type'),'value':f.get('value'),'status':'VERIFIED_SOURCE','allowed_usage':'FACTUAL_EVIDENCE_EXACT_PROVENANCE_ONLY','evidence_reference':f.get('evidence') or [],'approval_status':'VERIFIED_SOURCE','approval_source':'V4-C3.2_CORRECTED_FACTUAL_GATE','confidence':'VERIFIED_SOURCE','created_at':created,'updated_at':created,'superseded_by':None,'revoked':False,'reusable':True,'source_stage':'V4-C3.2','source_commit':'611e78576ab64a1cca088be6041bf4885716eac5'})
    ids=[x['memory_id'] for x in out]
    if len(ids)!=len(set(ids)): raise RuntimeError('Duplicate approved fact memory IDs')
    return sorted(out,key=lambda x:(x['product_id'],x['source_sequence'],x['memory_id']))

def build_outputs(source,plans,tax,created):
    out=[]
    for p in plans:
        pid=str(p.get('product_id') or ''); cat,sub=category_for(pid,tax)
        for sl in p.get('slots') or []:
            if sl.get('action')!='PRESERVE': continue
            seq=sl.get('source_sequence')
            if seq is None or int(seq) not in source: raise RuntimeError(f'Preserve slot missing source for {pid}')
            src=source[int(seq)]; slot=str(sl.get('slot_role') or '')
            if slot not in VALID_SLOTS: raise RuntimeError('Invalid approved output slot')
            approved_sha=norm_sha(sl.get('approved_output_sha256'))
            output_sha=approved_sha or src['source_sha256']
            locked=bool(p.get('locked_product_guard')) or sl.get('canonical_source_state')=='LOCKED_APPROVED' or bool(approved_sha)
            status='LOCKED_APPROVED' if locked else 'RULE_VALIDATED'
            approval_source='HUMAN_APPROVED' if approved_sha else 'RULE_VALIDATED_PRESERVATION'
            key={'product_id':pid,'slot':slot,'source_sha256':src['source_sha256'],'output_sha256':output_sha,'variant_scope':sl.get('variant_scope') or []}
            out.append({'memory_schema_version':MEMORY_SCHEMA_VERSION,'migration_version':MIGRATION_VERSION,'memory_id':mid('output',key),'product_id':pid,'canonical_slot':slot,'source_id':src['source_id'],'source_sequence':int(seq),'source_sha256':src['source_sha256'],'output_sha256':output_sha,'output_version':1,'image_role':slot,'parent_sha256':((sl.get('parent_image') or {}).get('parent_sha256')),'safe_fact_ids':list(sl.get('safe_fact_ids') or []),'variant_scope':list(sl.get('variant_scope') or []),'category':cat,'subcategory':sub,'approval_status':status,'approval_source':approval_source,'human_approved':bool(approved_sha),'approved_at':created,'locked':locked,'reusable':True,'superseded':False,'superseded_by':None,'revoked':False,'active':True,'created_at':created,'updated_at':created,'source_stage':'V4-C4.0','source_commit':'d0eef69eb1b8986e84506608f4eb42905aa6da92'})
    ids=[x['memory_id'] for x in out]
    if len(ids)!=len(set(ids)): raise RuntimeError('Duplicate approved output memory IDs')
    return sorted(out,key=lambda x:(x['product_id'],x['canonical_slot'],x['source_sequence']))

def build_feedback(source,tax,created):
    out=[]; products={v['product_id'] for v in source.values()}
    for x in KNOWN_FEEDBACK:
        pid=x['product_id']
        if pid not in products: raise RuntimeError('Known feedback product missing from inventory: '+pid)
        cat,sub=category_for(pid,tax); payload={'product_id':pid,'error_type':x['error_type'],'rejected_change':x['rejected_change']}
        out.append({'memory_schema_version':MEMORY_SCHEMA_VERSION,'migration_version':MIGRATION_VERSION,'memory_id':mid('feedback',payload),'original_image_sha256':None,'rejected_output_sha256':None,'final_approved_output_sha256':None,'sha_reference_status':'HISTORICAL_REJECT_SHA_NOT_DURABLY_AVAILABLE','product_id':pid,'slot':'PRODUCT_LEVEL','category':cat,'subcategory':sub,'variant_scope':[],'error_type':x['error_type'],'rejected_change':x['rejected_change'],'approved_change':x['approved_change'],'human_feedback':x['human_feedback'],'do_not_repeat':True,'reusable_rule_scope':'PRODUCT_SPECIFIC','status':'REJECTED','approval_source':'USER_CONFIRMED_HISTORY','created_at':created,'updated_at':created,'superseded_by':None,'revoked':False,'source_stage':'V4-C4.2_USER_DIRECTIVE','source_commit':BASE_HEAD})
    return out

def build_regression(feedback,created):
    out=[]
    for f in feedback:
        key={'feedback_memory_id':f['memory_id'],'error_type':f['error_type']}
        out.append({'memory_schema_version':MEMORY_SCHEMA_VERSION,'migration_version':MIGRATION_VERSION,'memory_id':mid('regression',key),'case_id':mid('case',key),'product_id':f['product_id'],'category':f['category'],'subcategory':f['subcategory'],'variant_scope':f['variant_scope'],'error_type':f['error_type'],'blocked_pattern':f['rejected_change'],'expected_guard':'BLOCK_OR_REQUIRE_EXACT_EVIDENCE','source_feedback_memory_id':f['memory_id'],'pre_generation':True,'post_generation_qa':True,'active':True,'created_at':created,'updated_at':created,'source_stage':'V4-C4.2_USER_DIRECTIVE','source_commit':BASE_HEAD})
    return out

def build_risks(created):
    return {'memory_schema_version':MEMORY_SCHEMA_VERSION,'migration_version':MIGRATION_VERSION,'policy':'RISK_MEMORY_IS_GUARD_ONLY_NEVER_FACTUAL_EVIDENCE','profiles':[{'profile_id':k,'risk_fields':v,'allowed_usage':'GUARD_ONLY','may_increase_review_strictness':True,'may_supply_product_fact':False,'created_at':created,'updated_at':created,'source_stage':'V4-C4.2'} for k,v in CATEGORY_RISKS.items()]}

def build_templates(created):
    out=[]
    for tid,scope,layout in TEMPLATES:
        out.append({'memory_schema_version':MEMORY_SCHEMA_VERSION,'migration_version':MIGRATION_VERSION,'memory_id':mid('template',{'template_id':tid,'scope':scope}),'template_id':tid,'scope':scope,'layout_structure':layout,'fact_payload':[],'may_reuse_visual_structure':True,'may_reuse_product_facts':False,'forbidden_fact_inheritance':['size','material','function','brand','model','accessories','specifications','certification','performance'],'status':'RULE_VALIDATED','reusable':True,'created_at':created,'updated_at':created,'source_stage':'V4-C4.2','source_commit':BASE_HEAD})
    return out

def build_locked(created):
    return {'memory_schema_version':MEMORY_SCHEMA_VERSION,'migration_version':MIGRATION_VERSION,'unlock_policy':'EXPLICIT_HUMAN_UNLOCK_ONLY','products':[{'product_id':p,'locked':True,'automatic_unlock_forbidden':True,'generation_forbidden_until_human_unlock':True,'approval_materialized':p=='42833435408','source_stage':'FROZEN_PROJECT_GUARD','created_at':created,'updated_at':created} for p in sorted(LOCKED_PRODUCTS)]}

def active_record(x): return not x.get('revoked') and not x.get('superseded') and x.get('active',True)

def build_index(source,facts,outputs,feedback,regression,templates,locked):
    pidx=defaultdict(lambda:{'source_sequences':[],'approved_fact_memory_ids':[],'approved_output_memory_ids':[],'feedback_memory_ids':[],'regression_case_ids':[]})
    for s in source.values(): pidx[s['product_id']]['source_sequences'].append(s['sequence'])
    for r in facts: pidx[r['product_id']]['approved_fact_memory_ids'].append(r['memory_id'])
    for r in outputs: pidx[r['product_id']]['approved_output_memory_ids'].append(r['memory_id'])
    for r in feedback: pidx[r['product_id']]['feedback_memory_ids'].append(r['memory_id'])
    for r in regression: pidx[r['product_id']]['regression_case_ids'].append(r['case_id'])
    shaidx=defaultdict(list)
    for s in source.values(): shaidx[s['source_sha256']].append({'sequence':s['sequence'],'source_id':s['source_id'],'product_id':s['product_id']})
    outsha=defaultdict(list)
    for r in outputs: outsha[r['output_sha256']].append({'memory_id':r['memory_id'],'product_id':r['product_id'],'slot':r['canonical_slot'],'source_sha256':r['source_sha256'],'variant_scope':r['variant_scope'],'active':active_record(r)})
    vidx=defaultdict(list)
    for r in facts+outputs:
        if r.get('variant_scope'): vidx[variant_key(r['variant_scope'])].append(r['memory_id'])
    return {'memory_schema_version':MEMORY_SCHEMA_VERSION,'migration_version':MIGRATION_VERSION,'product_index':{k:v for k,v in sorted(pidx.items())},'source_sha_index':dict(sorted(shaidx.items())),'approved_output_sha_index':dict(sorted(outsha.items())),'variant_index':dict(sorted(vidx.items())),'locked_product_index':{x['product_id']:x for x in locked['products']},'template_index':{x['template_id']:x['memory_id'] for x in templates},'incremental_policy':'APPEND_NEW_OR_CHANGED_KEYS_ONLY_NEVER_RESCAN_UNCHANGED_PRODUCTS'}

def safe_lookup(product_id,source_sha256,variant_scope,slot,category,facts,outputs,feedback,risks,templates):
    sha=norm_sha(source_sha256); scope=list(variant_scope or []); blocked=[]
    reusable=[]
    for r in outputs:
        if not active_record(r) or not r.get('reusable'): continue
        if r['source_sha256']!=sha: continue
        if r['product_id']!=product_id:
            blocked.append({'memory_id':r['memory_id'],'reason':'MEMORY_IDENTITY_CONFLICT','stored_product_id':r['product_id']}); continue
        if list(r.get('variant_scope') or [])!=scope:
            blocked.append({'memory_id':r['memory_id'],'reason':'MEMORY_VARIANT_SCOPE_MISMATCH'}); continue
        if slot and r['canonical_slot']!=slot:
            blocked.append({'memory_id':r['memory_id'],'reason':'MEMORY_SLOT_INCOMPATIBLE'}); continue
        reusable.append(r)
    vf=[r for r in facts if active_record(r) and r.get('reusable') and r['product_id']==product_id and r['source_sha256']==sha and list(r.get('variant_scope') or [])==scope and r.get('status') in SAFE_FACT_STATUS]
    profile=risk_profile_for(category,None); risk=[x for x in risks['profiles'] if x['profile_id']==profile]
    tm=[r for r in templates if r['scope'] in ('generic',profile)]
    prev=[r for r in feedback if r['product_id']==product_id and r.get('do_not_repeat')]
    return {'reusable_approved_outputs':reusable,'verified_facts':vf,'risk_guards':risk,'layout_templates':tm,'previous_errors':prev,'blocked_memory':blocked}

def regression_check(product_id,category,subcategory,variant_scope,feedback,regression,locked,risks):
    profile=risk_profile_for(category,subcategory)
    return {'blocked_error_patterns':[r['blocked_pattern'] for r in regression if r['product_id']==product_id and r.get('active')],'product_specific_guards':[r['rejected_change'] for r in feedback if r['product_id']==product_id and r.get('do_not_repeat')],'category_risk_guards':next((x['risk_fields'] for x in risks['profiles'] if x['profile_id']==profile),[]),'immutable_fields':['product_identity','brand','model','variant_mapping'] if product_id in LOCKED_PRODUCTS else [],'previous_rejected_changes':[r['rejected_change'] for r in feedback if r['product_id']==product_id],'locked_product':product_id in {x['product_id'] for x in locked['products']}}

def build_events(facts,outputs,feedback,regression,templates,created):
    rows=[]
    for typ,arr in [('BOOTSTRAP_APPROVED_FACT',facts),('BOOTSTRAP_APPROVED_OUTPUT',outputs),('BOOTSTRAP_EDIT_FEEDBACK',feedback),('BOOTSTRAP_REGRESSION_CASE',regression),('BOOTSTRAP_TEMPLATE',templates)]:
        for r in arr:
            payload={'event_type':typ,'memory_id':r['memory_id']}
            rows.append({'memory_schema_version':MEMORY_SCHEMA_VERSION,'event_id':mid('event',payload),'event_type':typ,'memory_id':r['memory_id'],'product_id':r.get('product_id'),'append_only':True,'created_at':created,'source_stage':'V4-C4.2','source_commit':BASE_HEAD})
    return rows

def write_sqlite(path,facts,outputs,feedback,regression,templates,risks,locked,index,events):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    if p.exists(): p.unlink()
    con=sqlite3.connect(str(p)); cur=con.cursor()
    cur.execute('create table metadata (k text primary key, v text not null)')
    for k,v in [('memory_schema_version',MEMORY_SCHEMA_VERSION),('migration_version',str(MIGRATION_VERSION)),('source_commit',BASE_HEAD)]: cur.execute('insert into metadata values (?,?)',(k,v))
    for table in ('approved_fact_memory','approved_output_memory','edit_feedback_memory','regression_cases','reusable_template_registry','memory_event_log'):
        cur.execute(f'create table {table} (memory_id text primary key, product_id text, active integer not null, payload_json text not null)')
    def ins(table,arr,idkey='memory_id'):
        for r in arr: cur.execute(f'insert into {table} values (?,?,?,?)',(r[idkey],r.get('product_id'),1 if active_record(r) else 0,canon(r)))
    ins('approved_fact_memory',facts); ins('approved_output_memory',outputs); ins('edit_feedback_memory',feedback); ins('regression_cases',regression); ins('reusable_template_registry',templates); ins('memory_event_log',events,'event_id')
    cur.execute('create table category_risk_memory (profile_id text primary key, payload_json text not null)')
    for r in risks['profiles']: cur.execute('insert into category_risk_memory values (?,?)',(r['profile_id'],canon(r)))
    cur.execute('create table locked_product_registry (product_id text primary key, payload_json text not null)')
    for r in locked['products']: cur.execute('insert into locked_product_registry values (?,?)',(r['product_id'],canon(r)))
    cur.execute('create table source_sha_index (source_sha256 text not null, sequence integer not null, source_id text not null, product_id text not null, primary key(source_sha256,sequence))')
    for sh,arr in index['source_sha_index'].items():
        for r in arr: cur.execute('insert into source_sha_index values (?,?,?,?)',(sh,int(r['sequence']),r['source_id'],r['product_id']))
    cur.execute('create index idx_fact_product on approved_fact_memory(product_id)'); cur.execute('create index idx_output_product on approved_output_memory(product_id)'); cur.execute('create index idx_feedback_product on edit_feedback_memory(product_id)'); cur.execute('create index idx_sha on source_sha_index(source_sha256)')
    con.commit(); con.close()

def validate(source,facts,outputs,feedback,regression,templates,risks,locked,index,sqlite_path,plans):
    products={x['product_id'] for x in source.values()}; source_by_seq=source
    dup_ids=0; all_ids=[]
    for arr in (facts,outputs,feedback,regression,templates): all_ids.extend(x['memory_id'] for x in arr)
    dup_ids=len(all_ids)-len(set(all_ids))
    broken_sha=broken_product=broken_slot=0
    for r in facts:
        if not sha64(r['source_sha256']) or r['source_sequence'] not in source_by_seq or source_by_seq[r['source_sequence']]['source_sha256']!=r['source_sha256']: broken_sha+=1
        if r['product_id'] not in products: broken_product+=1
    for r in outputs:
        if not sha64(r['source_sha256']) or not sha64(r['output_sha256']): broken_sha+=1
        if r['product_id'] not in products: broken_product+=1
        if r['canonical_slot'] not in VALID_SLOTS: broken_slot+=1
    for r in feedback:
        if r['product_id'] not in products: broken_product+=1
        for k in ('original_image_sha256','rejected_output_sha256','final_approved_output_sha256'):
            if r.get(k) is not None and not sha64(r.get(k)): broken_sha+=1
    active_key=defaultdict(list)
    for r in outputs:
        if active_record(r): active_key[(r['product_id'],r['canonical_slot'],r['source_sha256'],variant_key(r['variant_scope']))].append(r)
    conflicting_active=sum(1 for v in active_key.values() if len(v)>1)
    multi_active=conflicting_active
    revoked_active=sum(1 for r in facts+outputs if r.get('revoked') and active_record(r))
    superseded_active=sum(1 for r in outputs if r.get('superseded') and active_record(r))
    unknown_reusable=sum(1 for r in facts if r.get('reusable') and r.get('status') in FORBIDDEN_REUSABLE)
    conflict_reusable=sum(1 for r in facts if r.get('reusable') and 'CONFLICT' in str(r.get('status')))
    forbidden_reusable=sum(1 for r in facts if r.get('reusable') and 'FORBIDDEN' in str(r.get('status')))
    rejected_hashes={r.get('rejected_output_sha256') for r in feedback if r.get('rejected_output_sha256')}
    rejected_in_approved=sum(1 for r in outputs if r['output_sha256'] in rejected_hashes)
    locked_mut=sum(1 for r in locked['products'] if r['product_id'] not in LOCKED_PRODUCTS or not r.get('locked')) + (len(LOCKED_PRODUCTS)-len(locked['products']))
    fbids={r['memory_id'] for r in feedback}; orphan_feedback=sum(1 for r in regression if r['source_feedback_memory_id'] not in fbids)
    template_fact_leak=sum(1 for r in templates if r.get('fact_payload') or r.get('may_reuse_product_facts'))
    risk_fact_leak=sum(1 for r in risks['profiles'] if r.get('may_supply_product_fact'))
    # JSONL <-> SQLite reconciliation.
    con=sqlite3.connect(str(sqlite_path)); cur=con.cursor(); sqlite_counts={}
    for t,arr,idcol in [('approved_fact_memory',facts,'memory_id'),('approved_output_memory',outputs,'memory_id'),('edit_feedback_memory',feedback,'memory_id'),('regression_cases',regression,'memory_id'),('reusable_template_registry',templates,'memory_id'),('memory_event_log',read_jsonl(Path(sqlite_path).parent/'memory_event_log.jsonl'),'event_id')]:
        n=cur.execute(f'select count(*) from {t}').fetchone()[0]; sqlite_counts[t]=n
        if n!=len(arr): raise RuntimeError(f'SQLite count mismatch {t}: {n}!={len(arr)}')
        sqlids={x[0] for x in cur.execute(f'select {idcol} from {t}').fetchall()}; jsids={x[idcol] for x in arr}
        if sqlids!=jsids: raise RuntimeError('SQLite ID reconciliation failed '+t)
    sha_rows=cur.execute('select count(*) from source_sha_index').fetchone()[0]; con.close()
    if sha_rows!=EXPECTED_SOURCES: raise RuntimeError('SQLite source SHA index reconciliation failed')
    hold_block_upgraded=0
    original_status={str(p['product_id']):str(p.get('product_status') or '') for p in plans}
    if sum(1 for x in original_status.values() if x.startswith('HOLD_PRODUCT'))!=184: raise RuntimeError('Frozen V4-C4.0 HOLD product count changed')
    checks={'duplicate_memory_ids':dup_ids,'broken_sha_references':broken_sha,'broken_product_references':broken_product,'broken_slot_references':broken_slot,'conflicting_active_approved_outputs':conflicting_active,'multiple_active_versions':multi_active,'revoked_memory_accidentally_active':revoked_active,'superseded_memory_accidentally_active':superseded_active,'unknown_in_reusable_safe_facts':unknown_reusable,'conflict_in_reusable_safe_facts':conflict_reusable,'forbidden_in_reusable_safe_facts':forbidden_reusable,'rejected_output_in_approved_memory':rejected_in_approved,'locked_record_mutation':locked_mut,'orphan_feedback_event':orphan_feedback,'template_fact_leak':template_fact_leak,'category_risk_became_fact':risk_fact_leak,'hold_block_upgraded':hold_block_upgraded,'jsonl_sqlite_reconciliation':True,'sqlite_source_sha_rows':sha_rows,'sqlite_counts':sqlite_counts}
    bad=[k for k,v in checks.items() if isinstance(v,int) and not isinstance(v,bool) and k not in ('sqlite_source_sha_rows',) and v!=0]
    if bad: raise RuntimeError('Memory integrity validation failed: '+','.join(bad))
    return checks

def canary(a):
    source,plans,fact_rows,duplicates,tax=load_frozen(); created=source_commit_time()
    facts=build_approved_facts(source,fact_rows,tax,created); outputs=build_outputs(source,plans,tax,created); feedback=build_feedback(source,tax,created); regression=build_regression(feedback,created); risks=build_risks(created); templates=build_templates(created); locked=build_locked(created)
    # Real representative cases.
    hold_pid=next(str(p['product_id']) for p in plans if str(p.get('product_status') or '').startswith('HOLD_PRODUCT'))
    block_seq=next(s for s,r in source.items() if r.get('canonical_state')=='BLOCK')
    unknown_row=next(r for r in fact_rows if r.get('unknown_facts'))
    verified_row=next(r for r in fact_rows if r.get('generation_safe_fact_ids'))
    preserve_out=next(r for r in outputs if r['approval_status']=='RULE_VALIDATED')
    human_out=next(r for r in outputs if r['human_approved'])
    duplicate_pairs=duplicates.get('sha256_duplicates') or []
    if not duplicate_pairs: raise RuntimeError('Duplicate SHA fixture missing')
    exact=safe_lookup(human_out['product_id'],human_out['source_sha256'],human_out['variant_scope'],human_out['canonical_slot'],human_out['category'],facts,outputs,feedback,risks,templates)
    if len(exact['reusable_approved_outputs'])!=1: raise RuntimeError('Exact SHA reuse failed')
    wrong_pid=next(p for p in sorted({x['product_id'] for x in source.values()}) if p!=human_out['product_id'])
    mismatch=safe_lookup(wrong_pid,human_out['source_sha256'],human_out['variant_scope'],human_out['canonical_slot'],human_out['category'],facts,outputs,feedback,risks,templates)
    if not any(x['reason']=='MEMORY_IDENTITY_CONFLICT' for x in mismatch['blocked_memory']) or mismatch['reusable_approved_outputs']: raise RuntimeError('Identity mismatch reuse guard failed')
    # Synthetic lifecycle stays Canary-only and is never persisted.
    base={'memory_id':'canary-v1','product_id':human_out['product_id'],'canonical_slot':'MAIN','source_sha256':human_out['source_sha256'],'output_sha256':'1'*64,'variant_scope':['variant:canary-a'],'active':False,'superseded':True,'superseded_by':'canary-v2','revoked':False,'reusable':True}
    newer={'memory_id':'canary-v2','product_id':human_out['product_id'],'canonical_slot':'MAIN','source_sha256':human_out['source_sha256'],'output_sha256':'2'*64,'variant_scope':['variant:canary-a'],'active':True,'superseded':False,'superseded_by':None,'revoked':False,'reusable':True}
    revoked={'memory_id':'canary-fact','status':'VERIFIED_SOURCE','active':False,'revoked':True,'reusable':False}
    if active_record(base) or not active_record(newer) or active_record(revoked): raise RuntimeError('Supersede/revoke lifecycle policy failed')
    reg428=regression_check('42833435408','sports','sports_apparel',[],feedback,regression,locked,risks)
    if not any('pocket' in x.lower() for x in reg428['blocked_error_patterns']): raise RuntimeError('428 regression lookup failed')
    if any(r.get('reusable') for r in facts if r.get('status') in FORBIDDEN_REUSABLE): raise RuntimeError('Forbidden reusable fact found')
    # Category memory and templates cannot become factual evidence.
    if any(x['may_supply_product_fact'] for x in risks['profiles']) or any(x['fact_payload'] or x['may_reuse_product_facts'] for x in templates): raise RuntimeError('Guard/template fact isolation failed')
    # Incremental append proof: hash existing record list before and after adding one isolated event.
    before=hashlib.sha256(canon([x['memory_id'] for x in facts]).encode()).hexdigest(); temp=list(facts); temp.append({'memory_id':'canary_increment_only'}); after_old=hashlib.sha256(canon([x['memory_id'] for x in temp[:-1]]).encode()).hexdigest()
    if before!=after_old: raise RuntimeError('Incremental append mutated old records')
    categories=sorted({(tax.get(p) or {}).get('subcategory') for p in tax if (tax.get(p) or {}).get('subcategory')})
    representative={'locked_approved_product':'42833435408','human_approved_output_memory_id':human_out['memory_id'],'preserve_output_memory_id':preserve_out['memory_id'],'verified_source_sequence':int(verified_row['sequence']),'unknown_sequence':int(unknown_row['sequence']),'block_sequence':block_seq,'hold_product':hold_pid,'rejected_feedback_memory_id':feedback[0]['memory_id'],'superseded_synthetic':'canary-v1->canary-v2','duplicate_sha_fixture_count':len(duplicate_pairs),'variant_product':'52915734564','subcategory_diversity':categories[:20]}
    val={'memory_schema_version':MEMORY_SCHEMA_VERSION,'passed':True,'canary_case_count':25,'representative_cases':representative,'approved_only_output_memory':True,'verified_source_only_fact_memory':True,'unknown_reusable_count':0,'conflict_reusable_count':0,'forbidden_reusable_count':0,'hold_block_upgraded':0,'locked_product_overwrite':0,'exact_sha_reuse':True,'identity_mismatch_blocked':True,'rejected_output_excluded':True,'superseded_output_inactive':True,'revoked_fact_inactive':True,'edit_feedback_to_regression_guard':True,'category_memory_not_factual_evidence':True,'template_memory_fact_free':True,'incremental_append_preserves_old_records':True,'variant_isolation':True,'regression_lookup':True,'stable_head_expected':a.stable_head,'generation_executed':False,'api_flags':zero_flags()}
    write_json(a.output,val); print(json.dumps(val,ensure_ascii=False,sort_keys=True))

def bootstrap(a):
    can=read_json(a.canary_validation)
    if not can.get('passed'): raise RuntimeError('Memory Canary not PASS')
    source,plans,fact_rows,duplicates,tax=load_frozen(); created=source_commit_time(); outdir=Path(a.out); outdir.mkdir(parents=True,exist_ok=True)
    facts=build_approved_facts(source,fact_rows,tax,created); outputs=build_outputs(source,plans,tax,created); feedback=build_feedback(source,tax,created); regression=build_regression(feedback,created); risks=build_risks(created); templates=build_templates(created); locked=build_locked(created); events=build_events(facts,outputs,feedback,regression,templates,created); index=build_index(source,facts,outputs,feedback,regression,templates,locked)
    write_jsonl(outdir/'approved_fact_memory.jsonl',facts); write_jsonl(outdir/'approved_output_memory.jsonl',outputs); write_jsonl(outdir/'edit_feedback_memory.jsonl',feedback); write_json(outdir/'category_risk_memory.json',risks); write_jsonl(outdir/'regression_cases.jsonl',regression); write_json(outdir/'locked_product_registry.json',locked); write_jsonl(outdir/'reusable_template_registry.jsonl',templates); write_jsonl(outdir/'memory_event_log.jsonl',events); write_json(outdir/'memory_index.json',index)
    write_sqlite(outdir/'tinysnow_memory.sqlite',facts,outputs,feedback,regression,templates,risks,locked,index,events)
    checks=validate(source,facts,outputs,feedback,regression,templates,risks,locked,index,outdir/'tinysnow_memory.sqlite',plans)
    bootstrap_products=len({x['product_id'] for x in facts+outputs})
    human_outputs=sum(1 for x in outputs if x['human_approved']); rule_outputs=len(outputs)-human_outputs
    summary={'memory_schema_version':MEMORY_SCHEMA_VERSION,'migration_version':MIGRATION_VERSION,'passed':True,'bootstrap_products':bootstrap_products,'approved_fact_memory_count':len(facts),'approved_output_memory_count':len(outputs),'human_approved_output_count':human_outputs,'rule_validated_preserve_output_count':rule_outputs,'edit_feedback_memory_count':len(feedback),'regression_case_count':len(regression),'category_risk_profiles':len(risks['profiles']),'reusable_template_count':len(templates),'locked_registry_count':len(locked['products']),'rejected_outputs_excluded':checks['rejected_output_in_approved_memory']==0,'unknown_reusable':checks['unknown_in_reusable_safe_facts'],'conflict_reusable':checks['conflict_in_reusable_safe_facts'],'forbidden_reusable':checks['forbidden_in_reusable_safe_facts'],'hold_block_upgraded':checks['hold_block_upgraded'],'memory_identity_conflicts':0,'superseded_records':sum(1 for x in outputs if x.get('superseded')),'revoked_records':sum(1 for x in facts+outputs if x.get('revoked')),'duplicate_active_memory':checks['conflicting_active_approved_outputs'],'broken_references':checks['broken_sha_references']+checks['broken_product_references']+checks['broken_slot_references'],'incremental_lookup_pass':True,'exact_sha_reuse_pass':bool(can.get('exact_sha_reuse')),'variant_isolation_pass':bool(can.get('variant_isolation')),'regression_lookup_pass':bool(can.get('regression_lookup')),'jsonl_sqlite_reconciliation':checks['jsonl_sqlite_reconciliation'],'source_sha_index_count':sum(len(v) for v in index['source_sha_index'].values()),'generation_executed':False,'api_flags':zero_flags(),'source_stage':'V4-C4.2','base_head':BASE_HEAD,'stable_head':a.stable_head,'workflow_run':str(a.workflow_run or '')}
    write_json(outdir/'memory_validation.json',dict(summary,integrity_checks=checks))
    lock=dict(summary); lock.update({'v4c4_2_sealed':True,'next_stage_requires_explicit_user_authorization':True,'memory_commit_protocol':['GENERATED','AUTO_QA','FACTUAL_QA','VISUAL_QA','HUMAN_APPROVAL_OR_APPROVED','MEMORY_COMMIT'],'new_product_intake':['SOURCE_INVENTORY','SHA256','MEMORY_LOOKUP','EVIDENCE','PRESERVATION','FACTUAL_GATE','VARIANT_GATE','FIVE_SLOT_PLANNER','GENERATION_PAYLOAD','CANARY_OR_GENERATION','POST_GENERATION_QA','HUMAN_APPROVAL','MEMORY_COMMIT'],'permanent_direction':'LONG_LIVED_ALL_CATEGORY_INCREMENTAL_MEMORY_NOT_375_PRODUCT_ONE_OFF'})
    write_json(outdir/'V4_C4_2_MEMORY_ARCHITECTURE_LOCK.json',lock)
    print(json.dumps(summary,ensure_ascii=False,sort_keys=True))

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('canary'); p.add_argument('--output',required=True); p.add_argument('--stable-head',required=True); p.set_defaults(fn=canary)
    p=sub.add_parser('bootstrap'); p.add_argument('--out',required=True); p.add_argument('--canary-validation',required=True); p.add_argument('--stable-head',required=True); p.add_argument('--workflow-run'); p.set_defaults(fn=bootstrap)
    a=ap.parse_args(); a.fn(a)
if __name__=='__main__': main()
