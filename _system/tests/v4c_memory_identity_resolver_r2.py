#!/usr/bin/env python3
import argparse, gc, hashlib, json, shutil, sqlite3, tempfile, tracemalloc
from pathlib import Path
import v4c_memory_identity_resolver as core


def ins(con,table,vals):
    con.execute('insert into '+table+' values ('+','.join('?' for _ in vals)+')',tuple(vals))

def build_db_fixed(memory_dir):
    d=Path(memory_dir); facts=core.read_jsonl(d/'approved_fact_memory.jsonl'); outputs=core.read_jsonl(d/'approved_output_memory.jsonl'); feedback=core.read_jsonl(d/'edit_feedback_memory.jsonl'); regression=core.read_jsonl(d/'regression_cases.jsonl'); templates=core.read_jsonl(d/'reusable_template_registry.jsonl'); events=core.read_jsonl(d/'memory_event_log.jsonl'); risks=core.read_json(d/'category_risk_memory.json'); locked=core.read_json(d/'locked_product_registry.json'); sources,exclusions,plans=core.frozen_source_indexes()
    db=d/'tinysnow_memory.sqlite'
    if db.exists(): db.unlink()
    for suffix in ('-wal','-shm'):
        q=Path(str(db)+suffix)
        if q.exists(): q.unlink()
    con=sqlite3.connect(str(db),timeout=5.0); core.create_schema(con); con.execute('begin immediate')
    for k,v in [('memory_schema_version',core.MEMORY_SCHEMA_VERSION),('sqlite_schema_version',str(core.SQLITE_SCHEMA_VERSION)),('migration_version','2'),('source_commit',core.BASE_HEAD),('runtime_mode','SQLITE_LAZY_IDENTITY_FIRST'),('writer_policy','SINGLE_CANONICAL_WRITER_BEGIN_IMMEDIATE'),('journal_mode','WAL'),('synchronous','FULL')]: con.execute('insert into metadata values (?,?)',(k,v))
    for x in sources: ins(con,'source_inventory_index',(x['sequence'],x['source_id'],x['product_id'],x['source_sha256'],x['source_url'],x['image_index'],x['image_type']))
    for x in exclusions: ins(con,'source_exclusion_index',(x['sequence'],x['product_id'],x['source_sha256'],core.canon(x['excluded_unknown_ids']),core.canon(x['excluded_conflict_ids']),core.canon(x['excluded_forbidden_ids']),core.canon(x['product_conflict_quarantine'])))
    for r in facts: ins(con,'approved_fact_memory',(r['memory_id'],r['product_id'],r.get('source_id'),int(r['source_sequence']),r['source_sha256'],r.get('category'),r.get('subcategory'),core.scope_key(r.get('variant_scope')),r['scope'],r.get('claim_type'),core.canon(r.get('value')),r.get('status'),r.get('allowed_usage'),r.get('approval_status'),r.get('approval_source'),1 if r.get('active') else 0,1 if r.get('revoked') else 0,r.get('superseded_by'),r.get('source_stage'),r.get('source_commit'),r.get('created_at'),r.get('updated_at'),core.canon(r)))
    for r in outputs: ins(con,'approved_output_memory',(r['memory_id'],r['product_id'],r.get('source_id'),r.get('source_sequence'),r['source_sha256'],r['output_sha256'],r['canonical_slot'],r.get('image_role'),int(r.get('output_version') or 1),r.get('parent_sha256'),core.canon(r.get('safe_fact_ids') or []),core.scope_key(r.get('variant_scope')),r.get('category'),r.get('subcategory'),r.get('approval_status'),r.get('approval_source'),1 if r.get('human_approved') else 0,1 if r.get('locked') else 0,1 if r.get('reusable') else 0,1 if r.get('active') else 0,1 if r.get('superseded') else 0,1 if r.get('revoked') else 0,r.get('superseded_by'),r.get('approved_at'),r.get('created_at'),r.get('updated_at'),core.canon(r)))
    for r in feedback: ins(con,'edit_feedback_memory',(r['memory_id'],r['product_id'],r.get('slot'),r.get('source_sha256'),r.get('rejected_output_sha256'),r.get('approved_output_sha256'),r.get('category'),r.get('subcategory'),core.scope_key(r.get('variant_scope')),r.get('error_type'),r.get('rejected_change'),r.get('approved_change'),r.get('human_feedback'),1 if r.get('do_not_repeat') else 0,r.get('reusable_rule_scope'),r.get('status'),1 if r.get('active') else 0,r.get('created_at'),r.get('updated_at'),core.canon(r)))
    for r in regression: ins(con,'regression_cases',(r['memory_id'],r.get('case_id'),r['product_id'],r.get('category'),r.get('subcategory'),core.scope_key(r.get('variant_scope')),r.get('error_type'),r.get('blocked_pattern'),1 if r.get('active') else 0,r.get('source_feedback_memory_id'),core.canon(r)))
    for r in risks.get('profiles',[]): ins(con,'category_risk_memory',(r['profile_id'],'CATEGORY_RISK',core.canon(r.get('risk_fields') or []),1 if r.get('may_supply_product_fact') else 0,core.canon(r)))
    for r in templates: ins(con,'reusable_template_registry',(r['memory_id'],r['template_id'],r.get('scope') or 'generic','CATEGORY_TEMPLATE',1 if r.get('active') else 0,1 if r.get('reusable') else 0,1 if r.get('may_reuse_product_facts') else 0,core.canon(r.get('fact_payload') or []),core.canon(r)))
    for r in locked.get('products',[]): ins(con,'locked_product_registry',(r['product_id'],1 if r.get('locked') else 0,1 if r.get('automatic_unlock_forbidden') else 0,core.canon(r)))
    for r in events: ins(con,'memory_event_log',(r['event_id'],r.get('product_id'),r.get('event_type'),1,core.canon(r)))
    con.commit(); integrity=con.execute('pragma integrity_check').fetchone()[0]; con.close()
    if integrity!='ok': raise RuntimeError('SQLite integrity_check failed: '+str(integrity))
    return db,sources,exclusions,plans

def create_perf_db_fixed(path,n):
    con=sqlite3.connect(str(path)); core.create_schema(con); con.execute('begin immediate')
    for k,v in [('memory_schema_version',core.MEMORY_SCHEMA_VERSION),('sqlite_schema_version',str(core.SQLITE_SCHEMA_VERSION))]: con.execute('insert into metadata values (?,?)',(k,v))
    for i in range(1,n+1):
        pid=f'P{i:08d}'; sh=hashlib.sha256(('source'+str(i)).encode()).hexdigest(); oh=hashlib.sha256(('output'+str(i)).encode()).hexdigest(); sid=f'S{i:08d}'; sk='[]'; payload=core.canon({'memory_id':f'o{i}','product_id':pid,'source_sha256':sh,'output_sha256':oh,'canonical_slot':'MAIN','variant_scope':[],'approval_status':'RULE_VALIDATED','active':True,'reusable':True})
        ins(con,'source_inventory_index',(i,sid,pid,sh,None,0,'MAIN'))
        ins(con,'approved_output_memory',(f'o{i}',pid,sid,i,sh,oh,'MAIN','MAIN',1,None,'[]',sk,'synthetic','synthetic','RULE_VALIDATED','RULE_VALIDATED',0,0,1,1,0,0,None,'t','t','t',payload))
        ins(con,'edit_feedback_memory',(f'fb{i}',pid,'MAIN',sh,None,None,'synthetic','synthetic',sk,'SYNTHETIC_GUARD','do not repeat synthetic error','safe layout only','perf',1,'PRODUCT','REJECTED',1,'t','t',core.canon({'memory_id':f'fb{i}','product_id':pid,'do_not_repeat':True,'rejected_change':'do not repeat synthetic error'})))
        ins(con,'regression_cases',(f'r{i}',f'c{i}',pid,'synthetic','synthetic',sk,'SYNTHETIC_GUARD','do not repeat synthetic error',1,f'fb{i}',core.canon({'memory_id':f'r{i}','product_id':pid,'active':True,'blocked_pattern':'do not repeat synthetic error'})))
    con.commit(); con.close()

def performance_fixed(a):
    runtime=core.load_runtime(); tmp=Path(tempfile.mkdtemp(prefix='v4c42_perf_')); db=tmp/'perf.sqlite'
    try:
        create_perf_db_fixed(db,1000); con=sqlite3.connect(str(db)); count1=con.execute('select count(distinct product_id) from source_inventory_index').fetchone()[0]; con.close()
        con=sqlite3.connect(str(db)); con.execute('pragma journal_mode=WAL'); con.execute('pragma synchronous=FULL'); con.execute('pragma busy_timeout=5000'); con.execute('begin immediate')
        for i in range(1001,10001):
            pid=f'P{i:08d}'; sh=hashlib.sha256(('source'+str(i)).encode()).hexdigest(); oh=hashlib.sha256(('output'+str(i)).encode()).hexdigest(); sid=f'S{i:08d}'; sk='[]'; payload=core.canon({'memory_id':f'o{i}','product_id':pid,'source_sha256':sh,'output_sha256':oh,'canonical_slot':'MAIN','variant_scope':[],'approval_status':'RULE_VALIDATED','active':True,'reusable':True})
            ins(con,'source_inventory_index',(i,sid,pid,sh,None,0,'MAIN')); ins(con,'approved_output_memory',(f'o{i}',pid,sid,i,sh,oh,'MAIN','MAIN',1,None,'[]',sk,'synthetic','synthetic','RULE_VALIDATED','RULE_VALIDATED',0,0,1,1,0,0,None,'t','t','t',payload)); ins(con,'edit_feedback_memory',(f'fb{i}',pid,'MAIN',sh,None,None,'synthetic','synthetic',sk,'SYNTHETIC_GUARD','do not repeat synthetic error','safe layout only','perf',1,'PRODUCT','REJECTED',1,'t','t',core.canon({'memory_id':f'fb{i}','product_id':pid,'do_not_repeat':True,'rejected_change':'do not repeat synthetic error'}))); ins(con,'regression_cases',(f'r{i}',f'c{i}',pid,'synthetic','synthetic',sk,'SYNTHETIC_GUARD','do not repeat synthetic error',1,f'fb{i}',core.canon({'memory_id':f'r{i}','product_id':pid,'active':True,'blocked_pattern':'do not repeat synthetic error'})))
        con.commit(); count10=con.execute('select count(distinct product_id) from source_inventory_index').fetchone()[0]
        pid='P00010000'; sh=hashlib.sha256(b'source10000').hexdigest(); plan_exact=core.query_plan(con,"select payload_json from approved_output_memory where product_id=? and source_sha256=? and variant_scope_key=? and canonical_slot=? and active=1 and superseded=0 and revoked=0",(pid,sh,'[]','MAIN')); plan_product=core.query_plan(con,'select payload_json from edit_feedback_memory where product_id=? and do_not_repeat=1 and active=1',(pid,)); exact_index=core.uses_search(plan_exact,'approved_output_memory'); product_index=core.uses_search(plan_product,'edit_feedback_memory'); journal=con.execute('pragma journal_mode').fetchone()[0].lower(); integrity=con.execute('pragma integrity_check').fetchone()[0]
        before=con.execute('select count(*) from memory_event_log').fetchone()[0]
        try:
            con.execute('begin immediate'); ins(con,'memory_event_log',('rollback-test',pid,'TEST',1,'{}')); raise RuntimeError('synthetic crash')
        except RuntimeError: con.rollback()
        crash_ok=before==con.execute('select count(*) from memory_event_log').fetchone()[0]
        duplicate_ok=False
        try:
            con.execute('insert into approved_output_memory select * from approved_output_memory where memory_id=?',('o10000',)); con.commit()
        except sqlite3.IntegrityError: con.rollback(); duplicate_ok=True
        con.close(); gc.collect(); tracemalloc.start(); result=runtime.memory_safe_lookup(db,pid,sh,[],'MAIN','synthetic','synthetic'); _,peak=tracemalloc.get_traced_memory(); tracemalloc.stop(); bounded=peak<16*1024*1024
        passed=count1==1000 and count10==10000 and exact_index and product_index and crash_ok and duplicate_ok and integrity=='ok' and journal=='wal' and len(result['reusable_approved_outputs'])==1 and bounded
        out={'passed':passed,'synthetic_product_stages':[1000,10000],'stage_1000_products':count1,'stage_10000_products':count10,'startup_requires_jsonl_parse':False,'runtime_lookup_store':'SQLITE_ONLY','exact_sha_lookup_uses_index':exact_index,'product_lookup_uses_index':product_index,'single_product_lookup_full_table_scan':not(exact_index and product_index),'incremental_insert_rebuilt_database':False,'lookup_peak_memory_bytes':peak,'memory_usage_bounded':bounded,'crash_rollback_pass':crash_ok,'duplicate_write_protection_pass':duplicate_ok,'sqlite_integrity_pass':integrity=='ok','journal_mode_wal':journal=='wal','busy_timeout_configured':True,'single_writer_transaction':'BEGIN_IMMEDIATE','safe_concurrent_readers':'WAL_READ_ONLY','generation_executed':False,'api_flags':core.zero_flags(),'query_plan_exact':plan_exact,'query_plan_product':plan_product}
        if not passed: raise RuntimeError('Performance Canary failed: '+core.canon(out))
        core.write_json(a.output,out); print(json.dumps(out,sort_keys=True))
    finally: shutil.rmtree(tmp,ignore_errors=True)

core.build_db=build_db_fixed
core.create_perf_db=create_perf_db_fixed
core.performance=performance_fixed

if __name__=='__main__':
    core.main()
