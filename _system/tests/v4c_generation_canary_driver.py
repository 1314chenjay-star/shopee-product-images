#!/usr/bin/env python3
import argparse, importlib.util, json, shutil, tempfile
from pathlib import Path

PERSISTENT=(
 'paid_request_ledger.jsonl','provider_request_manifest.jsonl','generation_results.jsonl',
 'output_provenance.jsonl','deterministic_qa.jsonl','factual_regression_qa.jsonl','human_review_manifest.jsonl'
)

def load_core():
    p=Path(__file__).with_name('v4c_generation_canary.py')
    spec=importlib.util.spec_from_file_location('v4c51_core',p); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

def load_json(p): return json.loads(Path(p).read_text(encoding='utf-8-sig'))
def save_json(p,x): Path(p).write_text(json.dumps(x,ensure_ascii=False,indent=2),encoding='utf-8')

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('select'); p.add_argument('--out',required=True)
    p=sub.add_parser('finalize'); p.add_argument('--out',required=True); p.add_argument('--workflow-run',required=True); p.add_argument('--stable-head',required=True)
    a=ap.parse_args(); core=load_core(); out=Path(a.out)
    if a.cmd=='select':
        backup=Path(tempfile.mkdtemp(prefix='v4c51-ledger-')); existing=[]
        try:
            for name in PERSISTENT:
                src=out/name
                if src.exists() and src.stat().st_size>0:
                    shutil.copy2(src,backup/name); existing.append(name)
            core.select(a)
            for name in existing: shutil.copy2(backup/name,out/name)
        finally: shutil.rmtree(backup,ignore_errors=True)
    else:
        core.finalize(a)
        marker=out/'execution_complete_marker.json'
        if not marker.exists():
            vp=out/'validation.json'; lp=out/'V4_C5_1_GENERATION_CANARY_LOCK.json'
            v=load_json(vp); v['passed']=False; v['canary_execution_complete']=False; v['execution_blocker']='EXECUTOR_DID_NOT_COMPLETE'; save_json(vp,v)
            l=load_json(lp); l['validation_passed']=False; l['canary_execution_complete']=False; l['execution_blocker']='EXECUTOR_DID_NOT_COMPLETE'; save_json(lp,l)
if __name__=='__main__': main()
