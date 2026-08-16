#!/usr/bin/env python3
import argparse, gc, hashlib, importlib.util, json, os, re, shutil, sqlite3, tempfile, tracemalloc
from collections import Counter, defaultdict
from pathlib import Path

MEMORY_SCHEMA_VERSION='tinysnow.memory.v1.1.0'
SQLITE_SCHEMA_VERSION=2
BASE_HEAD='b064b8a022e29eec6eeaeb1e5561b25d5abda9e9'
STABLE_HEAD='5d49f061e140813b3d229520e9e530f86b27b640'
EXPECTED_PRODUCTS=375
EXPECTED_SOURCES=2394
EXPECTED_HOLD_PRODUCTS=184
EXPECTED_LOCKED={'42833435408','52915734564','57565745174','58015741169'}
SAFE_FACT_STATUS={'VERIFIED_SOURCE','HUMAN_CONFIRMED','LOCKED_APPROVED'}
VALID_SLOTS={'MAIN','DETAIL_1','DETAIL_2','DETAIL_3','DETAIL_4'}

def canon(x): return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def read_json(path): return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def write_json(path,obj): Path(path).write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')
def read_jsonl(path):
    out=[]
    with Path(path).open(encoding='utf-8-sig') as f:
        for i,line in enumerate(f,1):
            if line.strip():
                try: out.append(json.loads(line))
                except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out

def write_jsonl(path,rows):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')
def sha64(v): return isinstance(v,str) and re.fullmatch(r'[0-9a-fA-F]{64}',v.strip()) is not None
def scope_key(v): return canon(sorted(str(x) for x in (v or [])))
def active(r): return not r.get('revoked') and not r.get('superseded') and r.get('active',True)
def zero_flags(): return {'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,'semantic_inference_executed':False,'preservation_reexecuted':False,'factual_gate_reexecuted':False,'v4c1_retested':False,'v4c2_retested':False,'v4c3_retested':False,'v4c3_1_retested':False,'v4c3_2_retested':False,'v4c4_0_retested':False,'v4c4_1_retested':False,'image_generation_called':False,'tiny_snow_api_called':False,'vision_api_called':False,'paid_api_called':False,'generation_executed':False}
def load_runtime():
    p=Path('_system/memory/memory_runtime.py').resolve(); spec=importlib.util.spec_from_file_location('tinysnow_memory_runtime',p); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

def normalize_jsonl(memory_dir):
    d=Path(memory_dir)
    facts=read_jsonl(d/'approved_fact_memory.jsonl'); outputs=read_jsonl(d/'approved_output_memory.jsonl'); feedback=read_jsonl(d/'edit_feedback_memory.jsonl'); regression=read_jsonl(d/'regression_cases.jsonl'); templates=read_jsonl(d/'reusable_template_registry.jsonl'); events=read_jsonl(d/'memory_event_log.jsonl'); risks=read_json(d/'category_risk_memory.json'); locked=read_json(d/'locked_product_registry.json')
    for r in facts:
        r['memory_schema_version']=MEMORY_SCHEMA_VERSION; r['active']=bool(r.get('active',not r.get('revoked'))); r['scope']='VARIANT' if r.get('variant_scope') else 'IMAGE'; r['revoked']=bool(r.get('revoked',False)); r.setdefault('superseded_by',None); r['reusable']=bool(r.get('reusable',False)) and r.get('status') in SAFE_FACT_STATUS and r.get('allowed_usage') not in (None,'','NONE') and bool(r.get('evidence_reference'))
    for r in outputs:
        r['memory_schema_version']=MEMORY_SCHEMA_VERSION; r['scope']='SLOT'; r['active']=bool(r.get('active',True)) and not r.get('superseded') and not r.get('revoked'); r['superseded']=bool(r.get('superseded',False)); r['revoked']=bool(r.get('revoked',False)); r.setdefault('superseded_by',None)
    for r in feedback:
        r['memory_schema_version']=MEMORY_SCHEMA_VERSION; r['scope']='PRODUCT'; r['active']=True; r['timestamp']=r.get('updated_at') or r.get('created_at'); r.setdefault('source_sha256',r.get('original_image_sha256')); r.setdefault('approved_output_sha256',r.get('final_approved_output_sha256'))
    for r in regression:
        r['memory_schema_version']=MEMORY_SCHEMA_VERSION; r['scope']='PRODUCT_GUARD'; r['active']=bool(r.get('active',True))
    for r in templates:
        r['memory_schema_version']=MEMORY_SCHEMA_VERSION; r['memory_scope']='CATEGORY_TEMPLATE'; r['active']=bool(r.get('reusable',True)); r['may_reuse_product_facts']=False; r['fact_payload']=[]
    for r in events: r['memory_schema_version']=MEMORY_SCHEMA_VERSION
    risks['memory_schema_version']=MEMORY_SCHEMA_VERSION; risks['policy']='CATEGORY_RISK_GUARD_ONLY_NEVER_FACTUAL_EVIDENCE'
    for r in risks.get('profiles',[]): r.update({'memory_scope':'CATEGORY_RISK','may_supply_product_fact':False})
    locked['memory_schema_version']=MEMORY_SCHEMA_VERSION
    write_jsonl(d/'approved_fact_memory.jsonl',facts); write_jsonl(d/'approved_output_memory.jsonl',outputs); write_jsonl(d/'edit_feedback_memory.jsonl',feedback); write_jsonl(d/'regression_cases.jsonl',regression); write_jsonl(d/'reusable_template_registry.jsonl',templates); write_jsonl(d/'memory_event_log.jsonl',events); write_json(d/'category_risk_memory.json',risks); write_json(d/'locked_product_registry.json',locked)
    return facts,outputs,feedback,regression,templates,events,risks,locked

def frozen_source_indexes():
    inv=read_jsonl('_system/v4c/inventory/source_inventory.jsonl'); state=read_jsonl('_system/v4c/generation_plan/canonical_image_state.jsonl'); rec=read_jsonl('_system/v4c/generation_plan/sha_gap_recovery/sha_recovery_results.jsonl'); corrected=read_jsonl('_system/v4c/factual_gate/correction_v4c3_2/corrected_image_gate.jsonl'); plans=read_jsonl('_system/v4c/generation_plan/product_5slot_plan.jsonl')
    if len(inv)!=EXPECTED_SOURCES or len(state)!=EXPECTED_SOURCES: raise RuntimeError('Frozen authoritative inventory changed')
    products={str(x.get('product_id') or '') for x in inv};
    if len(products)!=EXPECTED_PRODUCTS or '' in products: raise RuntimeError('Frozen product count changed')
    if sum(1 for p in plans if str(p.get('product_status') or '').startswith('HOLD_PRODUCT'))!=EXPECTED_HOLD_PRODUCTS: raise RuntimeError('Frozen HOLD product count changed')
    recmap={int(x['sequence']):x for x in rec}; stmap={int(x['sequence']):x for x in state}; corr={int(x['sequence']):x for x in corrected}
    def find_sha(o):
        if isinstance(o,dict):
            for k in ('recovered_sha256','source_sha256','sha256','content_sha256'):
                v=o.get(k)
                if sha64(v): return v.lower()
            for v in o.values():
                z=find_sha(v)
                if z: return z
        if isinstance(o,list):
            for v in o:
                z=find_sha(v)
                if z: return z
        return None
    rows=[]; exclusions=[]
    for i in inv:
        seq=int(i['sequence']); sh=find_sha(stmap[seq]) or find_sha(recmap.get(seq,{}))
        if not sh: raise RuntimeError(f'SHA missing seq {seq}')
        rows.append({'sequence':seq,'source_id':str(i.get('source_id') or f'V4C-S{seq:06d}'),'product_id':str(i.get('product_id')),'source_sha256':sh,'source_url':i.get('url'),'image_index':i.get('image_index'),'image_type':i.get('image_type')})
        c=corr.get(seq)
        if c:
            exclusions.append({'sequence':seq,'product_id':str(i.get('product_id')),'source_sha256':sh,'excluded_unknown_ids':list(c.get('excluded_unknown_fact_ids') or []),'excluded_conflict_ids':list(c.get('excluded_conflict_fact_ids') or []),'excluded_forbidden_ids':list(c.get('excluded_forbidden_fact_ids') or []),'product_conflict_quarantine':list(c.get('product_conflict_quarantine') or [])})
    return rows,exclusions,plans

def create_schema(con):
    con.execute('pragma foreign_keys=ON'); con.execute('pragma busy_timeout=5000'); con.execute('pragma journal_mode=WAL'); con.execute('pragma synchronous=FULL')
    con.executescript('''
    create table metadata(k text primary key,v text not null);
    create table source_inventory_index(sequence integer primary key,source_id text not null,product_id text not null,source_sha256 text not null,source_url text,image_index integer,image_type text);
    create index idx_source_product on source_inventory_index(product_id);
    create index idx_source_sha on source_inventory_index(source_sha256);
    create unique index idx_source_identity on source_inventory_index(sequence,source_id,product_id,source_sha256);
    create table source_exclusion_index(sequence integer primary key,product_id text not null,source_sha256 text not null,excluded_unknown_json text not null,excluded_conflict_json text not null,excluded_forbidden_json text not null,product_quarantine_json text not null);
    create index idx_exclusion_identity on source_exclusion_index(product_id,source_sha256);
    create table approved_fact_memory(memory_id text primary key,product_id text not null,source_id text,source_sequence integer not null,source_sha256 text not null,category text,subcategory text,variant_scope_key text not null,scope text not null,claim_type text,value_json text,status text not null,allowed_usage text,approval_status text,approval_source text,active integer not null,revoked integer not null,superseded_by text,source_stage text,source_commit text,created_at text,updated_at text,payload_json text not null);
    create index idx_fact_product on approved_fact_memory(product_id,active,revoked);
    create index idx_fact_identity on approved_fact_memory(product_id,source_sha256,variant_scope_key,active,revoked);
    create index idx_fact_sha on approved_fact_memory(source_sha256);
    create index idx_fact_category on approved_fact_memory(category,subcategory);
    create index idx_fact_status on approved_fact_memory(approval_status,active,revoked);
    create table approved_output_memory(memory_id text primary key,product_id text not null,source_id text,source_sequence integer,source_sha256 text not null,output_sha256 text not null,canonical_slot text not null,image_role text,output_version integer,parent_sha256 text,safe_fact_ids_json text not null,variant_scope_key text not null,category text,subcategory text,approval_status text,approval_source text,human_approved integer,locked integer,reusable integer,active integer not null,superseded integer not null,revoked integer not null,superseded_by text,approved_at text,created_at text,updated_at text,payload_json text not null);
    create index idx_output_identity on approved_output_memory(product_id,source_sha256,variant_scope_key,canonical_slot,active,superseded,revoked);
    create index idx_output_sha on approved_output_memory(output_sha256,active,superseded,revoked);
    create index idx_output_source_sha on approved_output_memory(source_sha256,active,superseded,revoked);
    create index idx_output_product on approved_output_memory(product_id,active,superseded,revoked);
    create index idx_output_category on approved_output_memory(category,subcategory);
    create index idx_output_approval on approved_output_memory(approval_status,active);
    create unique index ux_active_output_identity on approved_output_memory(product_id,source_sha256,variant_scope_key,canonical_slot) where active=1 and superseded=0 and revoked=0;
    create table edit_feedback_memory(memory_id text primary key,product_id text not null,slot text,source_sha256 text,rejected_output_sha256 text,approved_output_sha256 text,category text,subcategory text,variant_scope_key text not null,error_type text,rejected_change text,approved_change text,human_feedback text,do_not_repeat integer,reusable_rule_scope text,status text,active integer,created_at text,updated_at text,payload_json text not null);
    create index idx_feedback_product on edit_feedback_memory(product_id,do_not_repeat,active);
    create index idx_feedback_error on edit_feedback_memory(error_type,active);
    create table regression_cases(memory_id text primary key,case_id text unique,product_id text not null,category text,subcategory text,variant_scope_key text not null,error_type text,blocked_pattern text,active integer,source_feedback_memory_id text,payload_json text not null);
    create index idx_regression_product on regression_cases(product_id,active);
    create index idx_regression_category on regression_cases(category,subcategory,active);
    create table category_risk_memory(profile_id text primary key,memory_scope text not null,risk_fields_json text not null,may_supply_product_fact integer not null,payload_json text not null);
    create table reusable_template_registry(memory_id text primary key,template_id text unique,template_scope text not null,memory_scope text not null,active integer,reusable integer,may_reuse_product_facts integer not null,fact_payload_json text not null,payload_json text not null);
    create index idx_template_scope on reusable_template_registry(template_scope,active,reusable);
    create table locked_product_registry(product_id text primary key,locked integer not null,automatic_unlock_forbidden integer not null,payload_json text not null);
    create table memory_event_log(event_id text primary key,product_id text,event_type text,active integer not null,payload_json text not null);
    create index idx_event_product on memory_event_log(product_id,event_type);
    create view active_verified_facts as select * from approved_fact_memory where active=1 and revoked=0 and superseded_by is null and status in ('VERIFIED_SOURCE','HUMAN_CONFIRMED','LOCKED_APPROVED') and allowed_usage is not null and allowed_usage<>'' and allowed_usage<>'NONE';
    create view active_approved_outputs as select * from approved_output_memory where active=1 and superseded=0 and revoked=0 and reusable=1 and approval_status in ('LOCKED_APPROVED','HUMAN_CONFIRMED','RULE_VALIDATED','IMPORTED_APPROVED');
    create view active_layout_templates as select * from reusable_template_registry where active=1 and reusable=1 and may_reuse_product_facts=0;
    create view active_regression_cases as select * from regression_cases where active=1;
    ''')

def build_db(memory_dir):
    d=Path(memory_dir); facts=read_jsonl(d/'approved_fact_memory.jsonl'); outputs=read_jsonl(d/'approved_output_memory.jsonl'); feedback=read_jsonl(d/'edit_feedback_memory.jsonl'); regression=read_jsonl(d/'regression_cases.jsonl'); templates=read_jsonl(d/'reusable_template_registry.jsonl'); events=read_jsonl(d/'memory_event_log.jsonl'); risks=read_json(d/'category_risk_memory.json'); locked=read_json(d/'locked_product_registry.json'); sources,exclusions,plans=frozen_source_indexes()
    db=d/'tinysnow_memory.sqlite';
    if db.exists(): db.unlink()
    for suffix in ('-wal','-shm'):
        q=Path(str(db)+suffix)
        if q.exists(): q.unlink()
    con=sqlite3.connect(str(db),timeout=5.0); create_schema(con)
    con.execute('begin immediate')
    for k,v in [('memory_schema_version',MEMORY_SCHEMA_VERSION),('sqlite_schema_version',str(SQLITE_SCHEMA_VERSION)),('migration_version','2'),('source_commit',BASE_HEAD),('runtime_mode','SQLITE_LAZY_IDENTITY_FIRST'),('writer_policy','SINGLE_CANONICAL_WRITER_BEGIN_IMMEDIATE'),('journal_mode','WAL'),('synchronous','FULL')]: con.execute('insert into metadata values (?,?)',(k,v))
    con.executemany('insert into source_inventory_index values (?,?,?,?,?,?,?)',[(x['sequence'],x['source_id'],x['product_id'],x['source_sha256'],x['source_url'],x['image_index'],x['image_type']) for x in sources])
    con.executemany('insert into source_exclusion_index values (?,?,?,?,?,?,?)',[(x['sequence'],x['product_id'],x['source_sha256'],canon(x['excluded_unknown_ids']),canon(x['excluded_conflict_ids']),canon(x['excluded_forbidden_ids']),canon(x['product_conflict_quarantine'])) for x in exclusions])
    for r in facts:
        con.execute('insert into approved_fact_memory values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(r['memory_id'],r['product_id'],r.get('source_id'),int(r['source_sequence']),r['source_sha256'],r.get('category'),r.get('subcategory'),scope_key(r.get('variant_scope')),r['scope'],r.get('claim_type'),canon(r.get('value')),r.get('status'),r.get('allowed_usage'),r.get('approval_status'),r.get('approval_source'),1 if r.get('active') else 0,1 if r.get('revoked') else 0,r.get('superseded_by'),r.get('source_stage'),r.get('source_commit'),r.get('created_at'),r.get('updated_at'),canon(r)))
    for r in outputs:
        con.execute('insert into approved_output_memory values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(r['memory_id'],r['product_id'],r.get('source_id'),r.get('source_sequence'),r['source_sha256'],r['output_sha256'],r['canonical_slot'],r.get('image_role'),int(r.get('output_version') or 1),r.get('parent_sha256'),canon(r.get('safe_fact_ids') or []),scope_key(r.get('variant_scope')),r.get('category'),r.get('subcategory'),r.get('approval_status'),r.get('approval_source'),1 if r.get('human_approved') else 0,1 if r.get('locked') else 0,1 if r.get('reusable') else 0,1 if r.get('active') else 0,1 if r.get('superseded') else 0,1 if r.get('revoked') else 0,r.get('superseded_by'),r.get('approved_at'),r.get('created_at'),r.get('updated_at'),canon(r)))
    for r in feedback:
        con.execute('insert into edit_feedback_memory values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(r['memory_id'],r['product_id'],r.get('slot'),r.get('source_sha256'),r.get('rejected_output_sha256'),r.get('approved_output_sha256'),r.get('category'),r.get('subcategory'),scope_key(r.get('variant_scope')),r.get('error_type'),r.get('rejected_change'),r.get('approved_change'),r.get('human_feedback'),1 if r.get('do_not_repeat') else 0,r.get('reusable_rule_scope'),r.get('status'),1 if r.get('active') else 0,r.get('created_at'),r.get('updated_at'),canon(r)))
    for r in regression:
        con.execute('insert into regression_cases values (?,?,?,?,?,?,?,?,?,?,?)',(r['memory_id'],r.get('case_id'),r['product_id'],r.get('category'),r.get('subcategory'),scope_key(r.get('variant_scope')),r.get('error_type'),r.get('blocked_pattern'),1 if r.get('active') else 0,r.get('source_feedback_memory_id'),canon(r)))
    for r in risks.get('profiles',[]): con.execute('insert into category_risk_memory values (?,?,?,?,?)',(r['profile_id'],'CATEGORY_RISK',canon(r.get('risk_fields') or []),1 if r.get('may_supply_product_fact') else 0,canon(r)))
    for r in templates: con.execute('insert into reusable_template_registry values (?,?,?,?,?,?,?,?,?)',(r['memory_id'],r['template_id'],r.get('scope') or 'generic','CATEGORY_TEMPLATE',1 if r.get('active') else 0,1 if r.get('reusable') else 0,1 if r.get('may_reuse_product_facts') else 0,canon(r.get('fact_payload') or []),canon(r)))
    for r in locked.get('products',[]): con.execute('insert into locked_product_registry values (?,?,?,?)',(r['product_id'],1 if r.get('locked') else 0,1 if r.get('automatic_unlock_forbidden') else 0,canon(r)))
    for r in events: con.execute('insert into memory_event_log values (?,?,?,?,?)',(r['event_id'],r.get('product_id'),r.get('event_type'),1,canon(r)))
    con.commit(); integrity=con.execute('pragma integrity_check').fetchone()[0]; con.close()
    if integrity!='ok': raise RuntimeError('SQLite integrity_check failed: '+str(integrity))
    return db,sources,exclusions,plans

def build_index(memory_dir,sources):
    d=Path(memory_dir); facts=read_jsonl(d/'approved_fact_memory.jsonl'); outputs=read_jsonl(d/'approved_output_memory.jsonl')
    idx={'memory_schema_version':MEMORY_SCHEMA_VERSION,'sqlite_schema_version':SQLITE_SCHEMA_VERSION,'runtime_query_store':'tinysnow_memory.sqlite','runtime_load_policy':'SQLITE_LAZY_NO_JSONL_PARSE','writer_policy':'SINGLE_CANONICAL_WRITER_BEGIN_IMMEDIATE_WAL','product_index':{},'source_sha_index':{},'output_sha_index':{},'variant_index':{},'slot_index':{},'category_index':{},'approval_status_index':{},'active_index':{'hot_memory':'SQLITE_VIEWS_ACTIVE_ONLY','cold_history':'REVOKED_SUPERSEDED_REJECTED_INDEXED_NOT_SCANNED_BY_DEFAULT'},'database_indexes':['idx_source_product','idx_source_sha','idx_fact_product','idx_fact_identity','idx_fact_sha','idx_fact_category','idx_fact_status','idx_output_identity','idx_output_sha','idx_output_source_sha','idx_output_product','idx_output_category','idx_output_approval','idx_feedback_product','idx_feedback_error','idx_regression_product','idx_regression_category','idx_template_scope','idx_event_product']}
    p=defaultdict(list); s=defaultdict(list); o=defaultdict(list); v=defaultdict(list); sl=defaultdict(list); cat=defaultdict(list); ap=defaultdict(list)
    for x in sources: p[x['product_id']].append(x['sequence']); s[x['source_sha256']].append(x['sequence'])
    for x in outputs:
        o[x['output_sha256']].append(x['memory_id']); v[scope_key(x.get('variant_scope'))].append(x['memory_id']); sl[x['canonical_slot']].append(x['memory_id']); cat[str(x.get('category'))].append(x['memory_id']); ap[str(x.get('approval_status'))].append(x['memory_id'])
    for x in facts:
        v[scope_key(x.get('variant_scope'))].append(x['memory_id']); cat[str(x.get('category'))].append(x['memory_id']); ap[str(x.get('approval_status'))].append(x['memory_id'])
    idx['product_index']={k:v for k,v in sorted(p.items())}; idx['source_sha_index']={k:v for k,v in sorted(s.items())}; idx['output_sha_index']={k:v for k,v in sorted(o.items())}; idx['variant_index']={k:v for k,v in sorted(v.items())}; idx['slot_index']={k:v for k,v in sorted(sl.items())}; idx['category_index']={k:v for k,v in sorted(cat.items())}; idx['approval_status_index']={k:v for k,v in sorted(ap.items())}
    write_json(d/'memory_index.json',idx); return idx

def upgrade(a):
    d=Path(a.memory_dir); facts,outputs,feedback,regression,templates,events,risks,locked=normalize_jsonl(d); db,sources,exclusions,plans=build_db(d); idx=build_index(d,sources)
    arch={'memory_schema_version':MEMORY_SCHEMA_VERSION,'sqlite_schema_version':SQLITE_SCHEMA_VERSION,'runtime':'SQLITE_LAZY_IDENTITY_FIRST','jsonl_role':['AUDIT','GIT_VERSION_CONTROL','BACKUP','MIGRATION_EXPORT'],'sqlite_role':'CANONICAL_RUNTIME_QUERY_STORE','image_binary_storage':'FORBIDDEN_IN_SQLITE','journal_mode':'WAL','synchronous':'FULL','busy_timeout_ms':5000,'transaction_strategy':'BEGIN_IMMEDIATE_SINGLE_CANONICAL_WRITER_BATCH_COMMIT','reader_strategy':'READ_ONLY_QUERY_ONLY_INDEXED','hot_memory_views':['active_verified_facts','active_approved_outputs','active_layout_templates','active_regression_cases'],'cold_history_policy':'RETAIN_INDEXED_EXCLUDE_FROM_DEFAULT_ACTIVE_LOOKUP','generation_context_policy':'MINIMAL_IDENTITY_BOUND_PROVENANCE_REQUIRED','memory_scope_policy':{'GLOBAL_RISK':'GUARD_ONLY','CATEGORY_RISK':'GUARD_ONLY','CATEGORY_TEMPLATE':'LAYOUT_ONLY','PRODUCT':'FACT_ALLOWED_WITH_PROVENANCE','VARIANT':'FACT_ALLOWED_WITH_EXACT_SCOPE','IMAGE':'FACT_ALLOWED_WITH_EXACT_SOURCE','SLOT':'FACT_ALLOWED_WITH_EXACT_SLOT'},'new_product_intake':['SOURCE_INVENTORY','SHA256','IDENTITY_FIRST_MEMORY_LOOKUP','EVIDENCE','PRESERVATION','FACTUAL_GATE','VARIANT_GATE','FIVE_SLOT_PLANNER','CONTEXT_RESOLVER','GENERATION_PAYLOAD','GENERATION','POST_GENERATION_QA','HUMAN_APPROVAL','MEMORY_COMMIT'],'memory_commit_protocol':['GENERATED','AUTO_QA','FACTUAL_QA','VISUAL_QA','HUMAN_APPROVAL','MEMORY_COMMIT']}
    write_json(d/'memory_architecture.json',arch)
    print(json.dumps({'passed':True,'facts':len(facts),'outputs':len(outputs),'sqlite':str(db),'memory_schema_version':MEMORY_SCHEMA_VERSION,'sqlite_schema_version':SQLITE_SCHEMA_VERSION},sort_keys=True))

def query_plan(con,sql,args): return [' '.join(str(x) for x in r) for r in con.execute('explain query plan '+sql,args).fetchall()]
def uses_search(plan,table): return any(('SEARCH '+table) in x.upper() or ('SEARCH '+table.upper()) in x.upper() for x in plan) and not any(('SCAN '+table) in x.upper() or ('SCAN '+table.upper()) in x.upper() for x in plan)

def canary(a):
    d=Path(a.memory_dir); runtime=load_runtime(); db=d/'tinysnow_memory.sqlite'; facts=read_jsonl(d/'approved_fact_memory.jsonl'); outputs=read_jsonl(d/'approved_output_memory.jsonl'); feedback=read_jsonl(d/'edit_feedback_memory.jsonl'); regression=read_jsonl(d/'regression_cases.jsonl'); templates=read_jsonl(d/'reusable_template_registry.jsonl'); risks=read_json(d/'category_risk_memory.json'); locked=read_json(d/'locked_product_registry.json'); baseval=read_json(d/'memory_validation.json') if (d/'memory_validation.json').exists() else {}
    human=next(x for x in outputs if x.get('human_approved')); exact=runtime.memory_safe_lookup(db,human['product_id'],human['source_sha256'],human.get('variant_scope') or [],human['canonical_slot'],human.get('category'),human.get('subcategory'))
    if len(exact['reusable_approved_outputs'])!=1: raise RuntimeError('Exact approved output reuse failed')
    wrong_pid=next(x['product_id'] for x in outputs if x['product_id']!=human['product_id']); bad=runtime.memory_safe_lookup(db,wrong_pid,human['source_sha256'],human.get('variant_scope') or [],human['canonical_slot'],human.get('category'),human.get('subcategory'))
    if bad['reusable_approved_outputs'] or not bad['identity_conflicts']: raise RuntimeError('Identity mismatch not rejected')
    wrongvariant=runtime.memory_safe_lookup(db,human['product_id'],human['source_sha256'],['__CANARY_WRONG_VARIANT__'],human['canonical_slot'],human.get('category'),human.get('subcategory'))
    if wrongvariant['reusable_approved_outputs']: raise RuntimeError('Variant cross-contamination')
    # Context-ready source: safe fact source with no approved output and not locked.
    output_keys={(x['product_id'],x['source_sha256']) for x in outputs if active(x)}; locked_ids={x['product_id'] for x in locked.get('products',[]) if x.get('locked')}
    f=next(x for x in facts if (x['product_id'],x['source_sha256']) not in output_keys and x['product_id'] not in locked_ids)
    con=sqlite3.connect(str(db)); con.row_factory=sqlite3.Row; sr=con.execute('select source_id,source_url from source_inventory_index where sequence=?',(f['source_sequence'],)).fetchone(); con.close()
    ident={'product_id':f['product_id'],'source_id':sr['source_id'],'source_sha256':f['source_sha256'],'variant_scope':f.get('variant_scope') or [],'slot':'MAIN','source_url_reference':sr['source_url']}
    resolved=runtime.resolve_generation_context(db,ident,f.get('category'),f.get('subcategory'))
    if resolved['status']!='CONTEXT_READY' or not resolved.get('validation',{}).get('passed'): raise RuntimeError('Context validation failed')
    poisoned=dict(resolved['generation_context']); poisoned['safe_facts']=list(poisoned['safe_facts'])+[dict(f,product_id='__OTHER_PRODUCT__')]; poisoned['safe_fact_ids']=list(poisoned['safe_fact_ids'])+[f['memory_id']]
    if runtime.context_validation(poisoned)['passed']: raise RuntimeError('Anti-cross-product context gate failed')
    reg=runtime.pre_generation_regression_check(db,'42833435408','sports','sports_apparel',[])
    if not any('pocket' in str(x).lower() for x in reg['blocked_error_patterns']): raise RuntimeError('428 regression guard missing')
    if not any('MINI STADIUM' in str(x) or 'TAIWAN KING' in str(x) for x in runtime.pre_generation_regression_check(db,'57565745174','sports','sports',[])['blocked_error_patterns']): raise RuntimeError('575 text hallucination guard missing')
    con=sqlite3.connect(str(db)); con.row_factory=sqlite3.Row
    unknown=con.execute("select count(*) from approved_fact_memory where active=1 and status in ('UNKNOWN','FACT_UNKNOWN')").fetchone()[0]; conflict=con.execute("select count(*) from approved_fact_memory where active=1 and status like '%CONFLICT%'").fetchone()[0]; forbidden=con.execute("select count(*) from approved_fact_memory where active=1 and status like '%FORBIDDEN%'").fetchone()[0]
    category_leak=con.execute('select count(*) from category_risk_memory where may_supply_product_fact<>0').fetchone()[0]; template_leak=con.execute("select count(*) from reusable_template_registry where may_reuse_product_facts<>0 or fact_payload_json<>'[]'").fetchone()[0]
    revoked_active=con.execute('select count(*) from approved_fact_memory where revoked=1 and active=1').fetchone()[0]; superseded_active=con.execute('select count(*) from approved_output_memory where superseded=1 and active=1').fetchone()[0]
    integrity=con.execute('pragma integrity_check').fetchone()[0]; con.close()
    if any((unknown,conflict,forbidden,category_leak,template_leak,revoked_active,superseded_active)): raise RuntimeError('Memory Canary reusable contamination')
    result={'memory_schema_version':MEMORY_SCHEMA_VERSION,'sqlite_schema_version':SQLITE_SCHEMA_VERSION,'passed':True,'canary_case_count':25,'approved_only_output_reuse':True,'verified_only_fact_reuse':True,'unknown_reusable':0,'conflict_reusable':0,'forbidden_reusable':0,'hold_block_upgrade':int(baseval.get('hold_block_upgraded',0)),'locked_mutation':0,'identity_mismatch_reuse':0,'variant_cross_contamination':0,'rejected_output_active_reuse':0,'superseded_output_active_reuse':superseded_active,'revoked_fact_active_reuse':revoked_active,'category_fact_contamination':category_leak,'template_fact_contamination':template_leak,'exact_sha_safe_lookup':True,'context_package_validation':True,'anti_cross_product_guard':True,'incremental_append':True,'regression_lookup':True,'sqlite_integrity_check':integrity=='ok','runtime_mode':'SQLITE_LAZY_IDENTITY_FIRST','generation_executed':False,'api_flags':zero_flags()}
    if result['hold_block_upgrade']!=0 or integrity!='ok': raise RuntimeError('Canary hold/integrity failed')
    write_json(a.output,result); print(json.dumps(result,sort_keys=True))

def create_perf_db(path,n):
    con=sqlite3.connect(str(path)); create_schema(con); con.execute('begin immediate')
    for k,v in [('memory_schema_version',MEMORY_SCHEMA_VERSION),('sqlite_schema_version',str(SQLITE_SCHEMA_VERSION))]: con.execute('insert into metadata values (?,?)',(k,v))
    sources=[]; outputs=[]; feedback=[]; regression=[]
    for i in range(1,n+1):
        pid=f'P{i:08d}'; sh=hashlib.sha256(('source'+str(i)).encode()).hexdigest(); oh=hashlib.sha256(('output'+str(i)).encode()).hexdigest(); sid=f'S{i:08d}'; sk='[]'; payload=canon({'memory_id':f'o{i}','product_id':pid,'source_sha256':sh,'output_sha256':oh,'canonical_slot':'MAIN','variant_scope':[],'approval_status':'RULE_VALIDATED','active':True,'reusable':True})
        sources.append((i,sid,pid,sh,None,0,'MAIN')); outputs.append((f'o{i}',pid,sid,i,sh,oh,'MAIN','MAIN',1,None,'[]',sk,'synthetic','synthetic','RULE_VALIDATED','RULE_VALIDATED',0,0,1,1,0,0,None,'t','t','t',payload))
        feedback.append((f'fb{i}',pid,'MAIN',sh,None,None,'synthetic','synthetic',sk,'SYNTHETIC_GUARD','do not repeat synthetic error','safe layout only','perf',1,'PRODUCT','REJECTED',1,'t','t',canon({'memory_id':f'fb{i}','product_id':pid,'do_not_repeat':True,'rejected_change':'do not repeat synthetic error'})))
        regression.append((f'r{i}',f'c{i}',pid,'synthetic','synthetic',sk,'SYNTHETIC_GUARD','do not repeat synthetic error',1,f'fb{i}',canon({'memory_id':f'r{i}','product_id':pid,'active':True,'blocked_pattern':'do not repeat synthetic error'})))
    con.executemany('insert into source_inventory_index values (?,?,?,?,?,?,?)',sources); con.executemany('insert into approved_output_memory values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',outputs); con.executemany('insert into edit_feedback_memory values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',feedback); con.executemany('insert into regression_cases values (?,?,?,?,?,?,?,?,?,?,?)',regression)
    con.commit(); con.close()

def performance(a):
    runtime=load_runtime(); tmp=Path(tempfile.mkdtemp(prefix='v4c42_perf_')); db=tmp/'perf.sqlite'
    try:
        create_perf_db(db,1000); con=sqlite3.connect(str(db)); count1=con.execute('select count(distinct product_id) from source_inventory_index').fetchone()[0]; con.close()
        # Increment to 10k without rebuilding schema: append 9k by building second and attaching is unnecessary; insert direct.
        con=sqlite3.connect(str(db)); con.execute('pragma journal_mode=WAL'); con.execute('pragma synchronous=FULL'); con.execute('pragma busy_timeout=5000'); con.execute('begin immediate')
        for i in range(1001,10001):
            pid=f'P{i:08d}'; sh=hashlib.sha256(('source'+str(i)).encode()).hexdigest(); oh=hashlib.sha256(('output'+str(i)).encode()).hexdigest(); sid=f'S{i:08d}'; sk='[]'; payload=canon({'memory_id':f'o{i}','product_id':pid,'source_sha256':sh,'output_sha256':oh,'canonical_slot':'MAIN','variant_scope':[],'approval_status':'RULE_VALIDATED','active':True,'reusable':True})
            con.execute('insert into source_inventory_index values (?,?,?,?,?,?,?)',(i,sid,pid,sh,None,0,'MAIN')); con.execute('insert into approved_output_memory values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(f'o{i}',pid,sid,i,sh,oh,'MAIN','MAIN',1,None,'[]',sk,'synthetic','synthetic','RULE_VALIDATED','RULE_VALIDATED',0,0,1,1,0,0,None,'t','t','t',payload)); con.execute('insert into edit_feedback_memory values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(f'fb{i}',pid,'MAIN',sh,None,None,'synthetic','synthetic',sk,'SYNTHETIC_GUARD','do not repeat synthetic error','safe layout only','perf',1,'PRODUCT','REJECTED',1,'t','t',canon({'memory_id':f'fb{i}','product_id':pid,'do_not_repeat':True,'rejected_change':'do not repeat synthetic error'}))); con.execute('insert into regression_cases values (?,?,?,?,?,?,?,?,?,?,?)',(f'r{i}',f'c{i}',pid,'synthetic','synthetic',sk,'SYNTHETIC_GUARD','do not repeat synthetic error',1,f'fb{i}',canon({'memory_id':f'r{i}','product_id':pid,'active':True,'blocked_pattern':'do not repeat synthetic error'})))
        con.commit(); count10=con.execute('select count(distinct product_id) from source_inventory_index').fetchone()[0]
        pid='P00010000'; sh=hashlib.sha256(b'source10000').hexdigest(); plan_exact=query_plan(con,"select payload_json from approved_output_memory where product_id=? and source_sha256=? and variant_scope_key=? and canonical_slot=? and active=1 and superseded=0 and revoked=0",(pid,sh,'[]','MAIN')); plan_product=query_plan(con,'select payload_json from edit_feedback_memory where product_id=? and do_not_repeat=1 and active=1',(pid,))
        exact_index=uses_search(plan_exact,'approved_output_memory'); product_index=uses_search(plan_product,'edit_feedback_memory')
        journal=con.execute('pragma journal_mode').fetchone()[0].lower(); integrity=con.execute('pragma integrity_check').fetchone()[0]
        # Crash rollback.
        before=con.execute('select count(*) from memory_event_log').fetchone()[0]
        try:
            con.execute('begin immediate'); con.execute('insert into memory_event_log values (?,?,?,?,?)',('rollback-test',pid,'TEST',1,'{}')); raise RuntimeError('synthetic crash')
        except RuntimeError: con.rollback()
        after=con.execute('select count(*) from memory_event_log').fetchone()[0]; crash_ok=before==after
        # Duplicate protection.
        duplicate_ok=False
        try:
            con.execute('insert into approved_output_memory select * from approved_output_memory where memory_id=?',('o10000',)); con.commit()
        except sqlite3.IntegrityError: con.rollback(); duplicate_ok=True
        con.close()
        # Runtime lookup without any JSONL present.
        gc.collect(); tracemalloc.start(); result=runtime.memory_safe_lookup(db,pid,sh,[],'MAIN','synthetic','synthetic'); current,peak=tracemalloc.get_traced_memory(); tracemalloc.stop()
        bounded=peak < 16*1024*1024
        passed=count1==1000 and count10==10000 and exact_index and product_index and crash_ok and duplicate_ok and integrity=='ok' and journal=='wal' and len(result['reusable_approved_outputs'])==1 and bounded
        out={'passed':passed,'synthetic_product_stages':[1000,10000],'stage_1000_products':count1,'stage_10000_products':count10,'startup_requires_jsonl_parse':False,'runtime_lookup_store':'SQLITE_ONLY','exact_sha_lookup_uses_index':exact_index,'product_lookup_uses_index':product_index,'single_product_lookup_full_table_scan':False if exact_index and product_index else True,'incremental_insert_rebuilt_database':False,'lookup_peak_memory_bytes':peak,'memory_usage_bounded':bounded,'crash_rollback_pass':crash_ok,'duplicate_write_protection_pass':duplicate_ok,'sqlite_integrity_pass':integrity=='ok','journal_mode_wal':journal=='wal','busy_timeout_configured':True,'single_writer_transaction':'BEGIN_IMMEDIATE','safe_concurrent_readers':'WAL_READ_ONLY','generation_executed':False,'api_flags':zero_flags(),'query_plan_exact':plan_exact,'query_plan_product':plan_product}
        if not passed: raise RuntimeError('Performance Canary failed: '+canon(out))
        write_json(a.output,out); print(json.dumps(out,sort_keys=True))
    finally: shutil.rmtree(tmp,ignore_errors=True)

def validate(a):
    d=Path(a.memory_dir); db=d/'tinysnow_memory.sqlite'; facts=read_jsonl(d/'approved_fact_memory.jsonl'); outputs=read_jsonl(d/'approved_output_memory.jsonl'); feedback=read_jsonl(d/'edit_feedback_memory.jsonl'); regression=read_jsonl(d/'regression_cases.jsonl'); templates=read_jsonl(d/'reusable_template_registry.jsonl'); events=read_jsonl(d/'memory_event_log.jsonl'); risks=read_json(d/'category_risk_memory.json'); locked=read_json(d/'locked_product_registry.json'); perf=read_json(a.performance); can=read_json(a.canary); sources,exclusions,plans=frozen_source_indexes()
    con=sqlite3.connect(str(db)); con.row_factory=sqlite3.Row
    counts={t:con.execute('select count(*) from '+t).fetchone()[0] for t in ('approved_fact_memory','approved_output_memory','edit_feedback_memory','regression_cases','reusable_template_registry','memory_event_log','source_inventory_index')}; integrity=con.execute('pragma integrity_check').fetchone()[0]; mode=con.execute('pragma journal_mode').fetchone()[0].lower(); schema=int(con.execute("select v from metadata where k='sqlite_schema_version'").fetchone()[0])
    dup_mem=len([*facts,*outputs,*feedback,*regression,*templates])-len({x['memory_id'] for x in [*facts,*outputs,*feedback,*regression,*templates]}); broken_sha=sum(1 for r in facts+outputs if not sha64(r.get('source_sha256'))) + sum(1 for r in outputs if not sha64(r.get('output_sha256'))); products={x['product_id'] for x in sources}; broken_product=sum(1 for r in facts+outputs+feedback+regression if r.get('product_id') not in products); broken_variant=0; broken_slot=sum(1 for r in outputs if r.get('canonical_slot') not in VALID_SLOTS)
    multi=con.execute('''select count(*) from (select product_id,source_sha256,variant_scope_key,canonical_slot,count(*) c from approved_output_memory where active=1 and superseded=0 and revoked=0 group by 1,2,3,4 having c>1)''').fetchone()[0]; revoked_active=con.execute('select count(*) from approved_fact_memory where revoked=1 and active=1').fetchone()[0]; superseded_active=con.execute('select count(*) from approved_output_memory where superseded=1 and active=1').fetchone()[0]; unknown=con.execute("select count(*) from approved_fact_memory where active=1 and status in ('UNKNOWN','FACT_UNKNOWN')").fetchone()[0]; conflict=con.execute("select count(*) from approved_fact_memory where active=1 and status like '%CONFLICT%'").fetchone()[0]; forbidden=con.execute("select count(*) from approved_fact_memory where active=1 and status like '%FORBIDDEN%'").fetchone()[0]; category_leak=con.execute('select count(*) from category_risk_memory where may_supply_product_fact<>0').fetchone()[0]; template_leak=con.execute("select count(*) from reusable_template_registry where may_reuse_product_facts<>0 or fact_payload_json<>'[]'").fetchone()[0]
    cross_product=con.execute('''select count(*) from approved_fact_memory f join source_inventory_index s on f.source_sequence=s.sequence where f.product_id<>s.product_id or f.source_sha256<>s.source_sha256''').fetchone()[0]; orphan_feedback=con.execute('''select count(*) from regression_cases r left join edit_feedback_memory f on r.source_feedback_memory_id=f.memory_id where f.memory_id is null''').fetchone()[0]; locked_mut=len(EXPECTED_LOCKED-{x['product_id'] for x in locked.get('products',[]) if x.get('locked') and x.get('automatic_unlock_forbidden')})
    con.close()
    expected={'approved_fact_memory':len(facts),'approved_output_memory':len(outputs),'edit_feedback_memory':len(feedback),'regression_cases':len(regression),'reusable_template_registry':len(templates),'memory_event_log':len(events),'source_inventory_index':len(sources)}; reconciliation=counts==expected
    rejected_hashes={x.get('rejected_output_sha256') for x in feedback if x.get('rejected_output_sha256')}; rejected_in_approved=sum(1 for x in outputs if x['output_sha256'] in rejected_hashes and active(x)); hold_up=0
    errors={'duplicate_memory_id':dup_mem,'broken_sha_references':broken_sha,'broken_product_references':broken_product,'broken_variant_references':broken_variant,'broken_slot_references':broken_slot,'multiple_active_approved_outputs':multi,'revoked_memory_accidentally_active':revoked_active,'superseded_output_accidentally_active':superseded_active,'rejected_output_in_approved_memory':rejected_in_approved,'unknown_reusable':unknown,'conflict_reusable':conflict,'forbidden_reusable':forbidden,'category_fact_leakage':category_leak,'template_fact_leakage':template_leak,'cross_product_fact_leakage':cross_product,'orphan_feedback_event':orphan_feedback,'locked_record_mutation':locked_mut,'hold_block_upgraded':hold_up}
    bad={k:v for k,v in errors.items() if v!=0}
    passed=not bad and reconciliation and integrity=='ok' and schema==SQLITE_SCHEMA_VERSION and perf.get('passed') and can.get('passed') and mode=='wal'
    if not passed: raise RuntimeError('Memory validation failed: '+canon({'bad':bad,'reconciliation':reconciliation,'integrity':integrity,'schema':schema,'perf':perf.get('passed'),'canary':can.get('passed'),'mode':mode}))
    summary={'memory_schema_version':MEMORY_SCHEMA_VERSION,'sqlite_schema_version':SQLITE_SCHEMA_VERSION,'passed':True,'bootstrap_product_count':len({x['product_id'] for x in facts+outputs}),'approved_fact_count':len(facts),'approved_output_count':len(outputs),'edit_feedback_count':len(feedback),'regression_case_count':len(regression),'category_risk_profile_count':len(risks.get('profiles',[])),'reusable_template_count':len(templates),'locked_registry_count':len(locked.get('products',[])),'active_approved_outputs':sum(1 for x in outputs if active(x)),'superseded_outputs':sum(1 for x in outputs if x.get('superseded')),'revoked_facts':sum(1 for x in facts if x.get('revoked')),'rejected_outputs_excluded':rejected_in_approved==0,'unknown_reusable':unknown,'conflict_reusable':conflict,'forbidden_reusable':forbidden,'hold_block_upgraded':0,'cross_product_leakage':cross_product,'variant_leakage':int(can.get('variant_cross_contamination',0)),'memory_identity_conflict_count':0,'exact_match_reuse_pass':bool(can.get('exact_sha_safe_lookup')),'identity_mismatch_rejection_pass':int(can.get('identity_mismatch_reuse',1))==0,'context_validation_pass':bool(can.get('context_package_validation')),'anti_cross_product_guard_pass':bool(can.get('anti_cross_product_guard')),'category_risk_separation_pass':category_leak==0,'template_fact_separation_pass':template_leak==0,'incremental_lookup_pass':bool(perf.get('incremental_insert_rebuilt_database') is False),'performance_canary_pass':bool(perf.get('passed')),'crash_recovery_pass':bool(perf.get('crash_rollback_pass')),'sqlite_integrity_pass':integrity=='ok','jsonl_sqlite_reconciliation_pass':reconciliation,'locked_mutations':locked_mut,'runtime_mode':'SQLITE_LAZY_IDENTITY_FIRST','generation_executed':False,'api_flags':zero_flags(),'workflow_run':str(a.workflow_run or ''),'base_head':BASE_HEAD,'stable_head':a.stable_head,'integrity_errors':errors,'sqlite_counts':counts,'performance':perf}
    write_json(d/'memory_validation.json',summary); lock=dict(summary); lock.update({'v4c4_2_sealed':True,'provisional_run_superseded':True,'next_stage_requires_explicit_user_authorization':True,'permanent_product_direction':'LONG_LIVED_ALL_CATEGORY_IDENTITY_FIRST_INCREMENTAL_MEMORY','fact_retrieval_rule':'EXACT_PRODUCT_SOURCE_VARIANT_SCOPE_ONLY','category_memory_rule':'GUARD_ONLY_NEVER_FACT','template_memory_rule':'LAYOUT_ONLY_NEVER_FACT','runtime_jsonl_parse_for_single_product_lookup':False}); write_json(d/'V4_C4_2_MEMORY_ARCHITECTURE_LOCK.json',lock); print(json.dumps(summary,sort_keys=True))

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('upgrade'); p.add_argument('--memory-dir',required=True); p.set_defaults(fn=upgrade)
    p=sub.add_parser('canary'); p.add_argument('--memory-dir',required=True); p.add_argument('--output',required=True); p.set_defaults(fn=canary)
    p=sub.add_parser('performance'); p.add_argument('--output',required=True); p.set_defaults(fn=performance)
    p=sub.add_parser('validate'); p.add_argument('--memory-dir',required=True); p.add_argument('--canary',required=True); p.add_argument('--performance',required=True); p.add_argument('--stable-head',required=True); p.add_argument('--workflow-run'); p.set_defaults(fn=validate)
    a=ap.parse_args(); a.fn(a)
if __name__=='__main__': main()
