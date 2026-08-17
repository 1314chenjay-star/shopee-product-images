#!/usr/bin/env python3
import json, re, sqlite3, sys
from pathlib import Path
from collections import Counter, defaultdict

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='backslashreplace')
except Exception:
    pass

BASE = Path('.')
SKIP_DIRS = {'.git', '__pycache__', 'generation_canary', 'generation_canary_preflight'}
TEXT_EXTS = {'.json','.jsonl','.py','.ps1','.yml','.yaml','.md','.txt','.csv'}
VARIANT_WORDS = ('variant','variation','option_id','option_name','option_value','model_id','sku','規格','選項')

def read_jsonl(p):
    out=[]
    with p.open(encoding='utf-8-sig', errors='replace') as f:
        for i,line in enumerate(f,1):
            if line.strip():
                try: out.append(json.loads(line))
                except Exception: pass
    return out

def walk_obj(obj, path='$'):
    if isinstance(obj, dict):
        yield path, obj
        for k,v in obj.items():
            yield from walk_obj(v, path+'.'+str(k))
    elif isinstance(obj, list):
        for i,v in enumerate(obj):
            yield from walk_obj(v, f'{path}[{i}]')

def has_variant_key(d):
    if not isinstance(d,dict): return False
    keys={str(k).lower() for k in d}
    return any(('variant' in k or 'variation' in k or k in {'option_id','option_name','option_value','model_id','sku','規格','選項'}) for k in keys)

def main():
    files=[]
    for p in BASE.rglob('*'):
        if not p.is_file() or p.suffix.lower() not in TEXT_EXTS: continue
        parts=set(p.parts)
        if parts & SKIP_DIRS: continue
        try: size=p.stat().st_size
        except Exception: continue
        if size > 12_000_000: continue
        files.append(p)

    exact_2673=[]; text_variant_files=[]; structured=[]
    for p in files:
        try: txt=p.read_text(encoding='utf-8-sig',errors='replace')
        except Exception: continue
        low=txt.lower()
        if '2673' in txt:
            exact_2673.append(str(p))
        if any(w.lower() in low for w in VARIANT_WORDS):
            text_variant_files.append(str(p))
        if p.suffix.lower()=='.json':
            try: data=json.loads(txt)
            except Exception: continue
            hits=0; pids=set(); sample=[]
            for opath,d in walk_obj(data):
                if not has_variant_key(d): continue
                hits += 1
                pid=str(d.get('product_id') or d.get('item_id') or '')
                if pid: pids.add(pid)
                if len(sample)<3: sample.append({'path':opath,'keys':sorted(map(str,d.keys()))[:30],'product_id':pid})
            if hits: structured.append({'file':str(p),'objects_with_variant_keys':hits,'product_ids':len(pids),'sample':sample})
        elif p.suffix.lower()=='.jsonl':
            hits=0; pids=set(); sample=[]; rows=0
            for r in read_jsonl(p):
                rows += 1
                for opath,d in walk_obj(r):
                    if not has_variant_key(d): continue
                    hits += 1
                    pid=str(d.get('product_id') or r.get('product_id') or d.get('item_id') or '')
                    if pid: pids.add(pid)
                    if len(sample)<3: sample.append({'path':opath,'keys':sorted(map(str,d.keys()))[:30],'product_id':pid})
            if hits: structured.append({'file':str(p),'rows':rows,'objects_with_variant_keys':hits,'product_ids':len(pids),'sample':sample})

    reports=[]; report_products={}; constraints=0
    for p in sorted(Path('_system/reports').glob('v4c0_b*_semantic_review*.json')):
        try: obj=json.loads(p.read_text(encoding='utf-8-sig'))
        except Exception: continue
        for prod in obj.get('products') or []:
            pid=str(prod.get('product_id') or '')
            vc=list(prod.get('variant_constraints') or [])
            if not pid: continue
            if vc:
                constraints += len(vc)
                report_products.setdefault(pid,[]).extend(vc)
                reports.append({'file':str(p),'product_id':pid,'verdict':prod.get('verdict'),'variant_constraints':vc})

    sqlite_info={}
    db=Path('_system/memory/tinysnow_memory.sqlite')
    if db.exists():
        con=sqlite3.connect(f'file:{db.as_posix()}?mode=ro', uri=True)
        try:
            tables=[r[0] for r in con.execute("select name from sqlite_master where type='table' order by name")]
            tinfo=[]
            for t in tables:
                cols=[r[1] for r in con.execute(f'pragma table_info({json.dumps(t)})')]
                vcols=[c for c in cols if 'variant' in c.lower() or 'option' in c.lower()]
                if vcols:
                    count=con.execute(f'select count(*) from "{t}"').fetchone()[0]
                    tinfo.append({'table':t,'row_count':count,'variant_columns':vcols})
            sqlite_info={'variant_tables':tinfo}
        finally: con.close()

    out={
      'exact_2673_files':sorted(exact_2673),
      'variant_text_file_count':len(text_variant_files),
      'variant_text_files':sorted(text_variant_files),
      'structured_variant_sources':structured,
      'v4c0_report_variant_product_count':len(report_products),
      'v4c0_report_variant_constraint_count':constraints,
      'v4c0_report_variant_samples':reports[:25],
      'sqlite':sqlite_info,
    }
    print(json.dumps(out,ensure_ascii=False,indent=2))

if __name__=='__main__': main()
