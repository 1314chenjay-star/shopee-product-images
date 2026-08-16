#!/usr/bin/env python3
"""V4-C4.2 SQLite schema correction only.
Keeps the memory architecture/bootstrap semantics unchanged and gives the append-only
event log its own event_id primary key so JSONL <-> SQLite can reconcile IDs.
"""
import sqlite3
from pathlib import Path
import v4c_memory_architecture as core


def write_sqlite_fixed(path,facts,outputs,feedback,regression,templates,risks,locked,index,events):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    if p.exists(): p.unlink()
    con=sqlite3.connect(str(p)); cur=con.cursor()
    cur.execute('create table metadata (k text primary key, v text not null)')
    for k,v in [('memory_schema_version',core.MEMORY_SCHEMA_VERSION),('migration_version',str(core.MIGRATION_VERSION)),('source_commit',core.BASE_HEAD)]:
        cur.execute('insert into metadata values (?,?)',(k,v))
    for table in ('approved_fact_memory','approved_output_memory','edit_feedback_memory','regression_cases','reusable_template_registry'):
        cur.execute(f'create table {table} (memory_id text primary key, product_id text, active integer not null, payload_json text not null)')
    cur.execute('create table memory_event_log (event_id text primary key, product_id text, active integer not null, payload_json text not null)')
    def ins(table,arr):
        for r in arr:
            cur.execute(f'insert into {table} values (?,?,?,?)',(r['memory_id'],r.get('product_id'),1 if core.active_record(r) else 0,core.canon(r)))
    ins('approved_fact_memory',facts); ins('approved_output_memory',outputs); ins('edit_feedback_memory',feedback); ins('regression_cases',regression); ins('reusable_template_registry',templates)
    for r in events:
        cur.execute('insert into memory_event_log values (?,?,?,?)',(r['event_id'],r.get('product_id'),1,core.canon(r)))
    cur.execute('create table category_risk_memory (profile_id text primary key, payload_json text not null)')
    for r in risks['profiles']: cur.execute('insert into category_risk_memory values (?,?)',(r['profile_id'],core.canon(r)))
    cur.execute('create table locked_product_registry (product_id text primary key, payload_json text not null)')
    for r in locked['products']: cur.execute('insert into locked_product_registry values (?,?)',(r['product_id'],core.canon(r)))
    cur.execute('create table source_sha_index (source_sha256 text not null, sequence integer not null, source_id text not null, product_id text not null, primary key(source_sha256,sequence))')
    for sh,arr in index['source_sha_index'].items():
        for r in arr: cur.execute('insert into source_sha_index values (?,?,?,?)',(sh,int(r['sequence']),r['source_id'],r['product_id']))
    cur.execute('create index idx_fact_product on approved_fact_memory(product_id)')
    cur.execute('create index idx_output_product on approved_output_memory(product_id)')
    cur.execute('create index idx_feedback_product on edit_feedback_memory(product_id)')
    cur.execute('create index idx_sha on source_sha_index(source_sha256)')
    con.commit(); con.close()

if __name__=='__main__':
    core.write_sqlite=write_sqlite_fixed
    core.main()
