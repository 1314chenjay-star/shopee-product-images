#!/usr/bin/env python3
"""V4-C5.0 narrow correction wrapper.

Keeps the original V4-C5.0 dry-run implementation intact, fixes only the
new-stage display provenance adapter, prevents Python bytecode writes into the
frozen Memory tree, and strengthens Canary requirements. No frozen pipeline is
re-executed.
"""
import argparse, importlib.util, json, sqlite3, sys
from pathlib import Path

sys.dont_write_bytecode=True
BASE=Path(__file__).with_name('v4c_generation_payload_dry_run.py').resolve()
spec=importlib.util.spec_from_file_location('v4c50_payload_base',BASE)
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

REQUIRED_RISK_PROFILES={'apparel','bags','footwear','sports','outdoor','general_merchandise'}

def fixed_build_display_allowlist(q,safe_facts):
    rows=[]; safe_text=list(q.get('safe_text') or []); ids=list(q.get('safe_fact_ids') or [])
    fact_by_id={str(f.get('fact_id')):f for f in safe_facts}
    for i,text in enumerate(safe_text):
        fid=ids[i] if i<len(ids) else None; f=fact_by_id.get(str(fid)) if fid else None
        prefix=str(text).split(':',1)[0].strip().lower() if ':' in str(text) else ''
        if prefix=='risk_field':
            rows.append({'fact_id':fid,'source_text':text,'display_allowed':False,'reason':'NON_DISPLAY_META_FACT','localized_text':None}); continue
        localized=m.conservative_localize(text)
        rows.append({'fact_id':fid,'source_text':text,'display_allowed':True,'localized_text':localized,'transform':'DETERMINISTIC_SIMPLIFIED_TO_TRADITIONAL_ONLY' if localized!=text else 'PRESERVE_VERIFIED_TEXT','ascii_numeric_tokens_preserved':m.ascii_numeric_tokens(localized)==m.ascii_numeric_tokens(text),'evidence_reference':(f or {}).get('evidence_reference') or []})
    return rows

m.build_display_allowlist=fixed_build_display_allowlist

def strengthen_canary(path):
    p=Path(path); c=json.loads(p.read_text(encoding='utf-8-sig'))
    statuses=c.get('sample_status_counts') or {}
    c['actual_sample_has_payload_ready']=int(statuses.get('EXECUTION_READY',0))+int(statuses.get('MEMORY_REUSE',0))>0
    db=m.MEMORY_DIR/'tinysnow_memory.sqlite'; con=sqlite3.connect(str(db))
    try:
        profiles={r[0] for r in con.execute('select profile_id from category_risk_memory').fetchall()}
    finally: con.close()
    c['required_category_risk_profiles']=sorted(REQUIRED_RISK_PROFILES)
    c['category_risk_profile_canary_coverage']=sorted(REQUIRED_RISK_PROFILES & profiles)
    c['multi_category_guard_coverage_pass']=REQUIRED_RISK_PROFILES.issubset(profiles)
    c['category_profiles_are_guard_only']=True
    c['general_merchandise_guard_covered']='general_merchandise' in profiles
    c['outdoor_guard_covered']='outdoor' in profiles
    c['apparel_guard_covered']='apparel' in profiles
    c['passed']=bool(c.get('passed')) and c['actual_sample_has_payload_ready'] and c['multi_category_guard_coverage_pass']
    p.write_text(json.dumps(c,ensure_ascii=False,indent=2),encoding='utf-8')
    if not c['passed']: raise RuntimeError('Strengthened V4-C5.0 Canary failed: '+m.canon(c))
    print(m.canon(c))

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('canary'); p.add_argument('--output',required=True); p.add_argument('--size',type=int,default=50)
    p=sub.add_parser('full'); p.add_argument('--out',required=True); p.add_argument('--stable-head',required=True); p.add_argument('--workflow-run',required=True)
    a=ap.parse_args()
    if a.cmd=='canary':
        m.canary(a); strengthen_canary(a.output)
    else:
        m.full(a)
if __name__=='__main__': main()
