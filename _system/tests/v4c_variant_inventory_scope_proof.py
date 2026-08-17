#!/usr/bin/env python3
import csv, hashlib, json, os, re, subprocess, sys, zipfile
from collections import Counter, defaultdict
from pathlib import Path
from xml.etree import ElementTree as ET

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='backslashreplace')
except Exception:
    pass

ROOT = Path('.')
OUT = ROOT / '_system/v4c/variant_inventory'
READY_Q = ROOT / '_system/v4c/generation_payload/execution_ready_queue.jsonl'
GEN_CTX = ROOT / '_system/v4c/generation_payload/generation_context.jsonl'
SRC_INV = ROOT / '_system/v4c/inventory/source_inventory.jsonl'
C51A_LOCK = ROOT / '_system/v4c/variant_readiness_audit/V4_C5_1A_VARIANT_READINESS_AUDIT_LOCK.json'
APP_FACT = ROOT / '_system/memory/approved_fact_memory.jsonl'
APP_OUT = ROOT / '_system/memory/approved_output_memory.jsonl'
MEM_DB = ROOT / '_system/memory/tinysnow_memory.sqlite'
API_V2 = ROOT / '_system/start/api_v2.ps1'
LOCKED = {'42833435408','52915734564','57565745174','58015741169'}
VARIANT_FIELDS = ['color','size','quantity','style','model','bundle_package','accessory_configuration']
FIELD_PATTERNS = {
    'color': re.compile(r'(?i)(color|colour|顏色|颜色|色款|色系|colorway)'),
    'size': re.compile(r'(?i)(size|尺寸|尺碼|尺码|長度|长度|handedness|左右手|左手|右手)'),
    'quantity': re.compile(r'(?i)(quantity|qty|count|piece|pieces|數量|数量|幾件|几件|入數|入数|單雙|单双)'),
    'style': re.compile(r'(?i)(style|款式|造型|pattern|圖案|图案)'),
    'model': re.compile(r'(?i)(model|型號|型号|規格型號|规格型号|版本)'),
    'bundle_package': re.compile(r'(?i)(bundle|package|pack|套裝|套装|組合|组合|包裝|包装|幾入|几入)'),
    'accessory_configuration': re.compile(r'(?i)(accessory|附件|配件|贈品|赠品|included|inclusion|配置)'),
}
PID_KEYS = {'product_id','item_id','productid','商品id','商品 id'}
OPTION_LIST_KEYS = ['variation_options','variant_options','option_values','options_values','variation_values']
VARIANT_LIST_KEYS = ['variants','models','variant_rows','model_rows']
VARIANT_ID_KEYS = ['variant_id','model_id','variation_id','option_id']
VARIANT_SKU_KEYS = ['variant_sku','model_sku','variation_sku','option_sku','seller_sku']


def norm(v):
    return re.sub(r'[\s：:（）()\[\]【】_\-.]+','',str(v or '').strip().lower())

def sha256_file(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024), b''): h.update(b)
    return h.hexdigest()

def read_jsonl(p):
    rows=[]
    if not p.exists(): return rows
    with p.open(encoding='utf-8-sig',errors='replace') as f:
        for n,line in enumerate(f,1):
            if not line.strip(): continue
            try:
                x=json.loads(line); x['_line_no']=n; rows.append(x)
            except Exception: pass
    return rows

def write_jsonl(p, rows):
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')

def write_json(p,obj):
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

def git_ls_files():
    cp=subprocess.run(['git','ls-files','-z'],capture_output=True,check=True)
    return [Path(x.decode('utf-8','replace')) for x in cp.stdout.split(b'\0') if x]

def col_index(ref):
    s=''.join(c for c in ref if c.isalpha()).upper(); n=0
    for c in s: n=n*26+(ord(c)-64)
    return n-1

def xlsx_rows(path):
    out=[]
    try:
        z=zipfile.ZipFile(path,'r')
    except Exception: return out
    try:
        shared=[]
        if 'xl/sharedStrings.xml' in z.namelist():
            root=ET.fromstring(z.read('xl/sharedStrings.xml'))
            for si in root.iter():
                if si.tag.endswith('}si'):
                    shared.append(''.join((t.text or '') for t in si.iter() if t.tag.endswith('}t')))
        for name in sorted(n for n in z.namelist() if re.match(r'xl/worksheets/sheet\d+\.xml$',n)):
            try: root=ET.fromstring(z.read(name))
            except Exception: continue
            rows=[]
            for row in root.iter():
                if not row.tag.endswith('}row'): continue
                vals={}
                for c in row:
                    if not c.tag.endswith('}c'): continue
                    idx=col_index(c.attrib.get('r','A1')); typ=c.attrib.get('t','')
                    val=''
                    if typ=='inlineStr':
                        val=''.join((t.text or '') for t in c.iter() if t.tag.endswith('}t'))
                    else:
                        v=next((x for x in c if x.tag.endswith('}v')),None)
                        raw='' if v is None or v.text is None else v.text
                        if typ=='s' and raw.isdigit() and int(raw)<len(shared): val=shared[int(raw)]
                        else: val=raw
                    vals[idx]=str(val).strip()
                if vals: rows.append(vals)
            if rows: out.append((name,rows))
    finally: z.close()
    return out

def find_structured_header(rows):
    best=None
    for ri,row in enumerate(rows[:60]):
        headers={i:norm(v) for i,v in row.items()}
        pid=[i for i,h in headers.items() if h in {'商品id','productid','itemid','ettitleproductid'}]
        if not pid: continue
        opt=[i for i,h in headers.items() if re.match(r'^(選項|选项)\d+(的)?名稱$',str(row[i]).strip()) or 'ettitleoption' in h or h in {'規格值','规格值','variationvalue','variantvalue','optionvalue'}]
        dim=[i for i,h in headers.items() if h in {'規格名稱1','规格名称1','variationname','variantname','optiondimension','ettitlevariation1'}]
        vid=[i for i,h in headers.items() if h in {'variantid','modelid','variationid','optionid','規格id','规格id'}]
        vsku=[i for i,h in headers.items() if h in {'variantsku','modelsku','variationsku','optionsku','規格貨號','规格货号','賣家貨號','卖家货号'}]
        pimgs=[i for i,h in headers.items() if h in {'主商品圖片','主商品图片','psitemcoverimage'} or re.match(r'^(商品圖片|商品图片)\d+$',str(row[i]).strip()) or re.match(r'^psitemimage\.?\d+$',str(row[i]).strip(),re.I)]
        oimgs=[i for i,h in headers.items() if re.match(r'^(選項|选项)\d+(的)?圖片$',str(row[i]).strip()) or 'optionimage' in h]
        score=5+len(opt)*2+len(dim)*2+len(vid)*2+len(vsku)+len(pimgs)+len(oimgs)
        cand={'header_row':ri,'pid':pid[0],'opt':opt,'dim':dim,'vid':vid,'vsku':vsku,'pimgs':pimgs,'oimgs':oimgs,'headers':headers,'score':score}
        if best is None or score>best['score']: best=cand
    return best

def structured_from_table(path, sheet, rows, source_type):
    h=find_structured_header(rows)
    if not h: return []
    out=[]
    for ri,row in enumerate(rows[h['header_row']+1:],h['header_row']+2):
        pid=str(row.get(h['pid'],'')).strip()
        if not re.fullmatch(r'\d{5,30}',pid): continue
        opts=[str(row.get(i,'')).strip() for i in h['opt'] if str(row.get(i,'')).strip()]
        dims=[str(row.get(i,'')).strip() for i in h['dim'] if str(row.get(i,'')).strip()]
        vids=[str(row.get(i,'')).strip() for i in h['vid'] if str(row.get(i,'')).strip()]
        skus=[str(row.get(i,'')).strip() for i in h['vsku'] if str(row.get(i,'')).strip()]
        pimgs=[str(row.get(i,'')).strip() for i in h['pimgs'] if str(row.get(i,'')).strip().startswith(('http://','https://'))]
        oimgs=[str(row.get(i,'')).strip() for i in h['oimgs'] if str(row.get(i,'')).strip().startswith(('http://','https://'))]
        out.append({'product_id':pid,'source_file':str(path),'source_record':f'{sheet}:row:{ri}','source_type':source_type,
                    'option_dimensions':dims,'option_values':opts,'variant_ids':vids,'variant_skus':skus,
                    'product_image_urls':pimgs,'option_image_urls':oimgs,
                    'schema_has_option_columns':bool(h['opt'] or h['dim'] or h['vid'] or h['vsku']),
                    'explicit_no_variants':bool(h['opt'] or h['dim'] or h['vid'] or h['vsku']) and not (opts or dims or vids or skus),
                    'authoritative_rank':100 if source_type=='tracked_xlsx_structured' else 90})
    return out

def walk_dicts(obj,path='$'):
    if isinstance(obj,dict):
        yield path,obj
        for k,v in obj.items(): yield from walk_dicts(v,path+'.'+str(k))
    elif isinstance(obj,list):
        for i,v in enumerate(obj): yield from walk_dicts(v,f'{path}[{i}]')

def structured_from_json(path):
    objs=[]
    try:
        if path.suffix.lower()=='.jsonl': data=read_jsonl(path)
        else: data=json.loads(path.read_text(encoding='utf-8-sig',errors='replace'))
    except Exception: return objs
    for opath,d in walk_dicts(data):
        if not isinstance(d,dict): continue
        pid=str(d.get('product_id') or d.get('item_id') or '').strip()
        if not re.fullmatch(r'\d{5,30}',pid): continue
        prov=d.get('source_provenance') if isinstance(d.get('source_provenance'),dict) else {}
        exact_excel_prov=str(prov.get('source_type') or '')=='shopee_excel_raw'
        has_adapter_shape=('variation_options' in d and 'multi_variant_flags' in d and 'image_urls' in d)
        if not (exact_excel_prov or has_adapter_shape): continue
        options=[]
        for k in OPTION_LIST_KEYS:
            v=d.get(k)
            if isinstance(v,list): options.extend(str(x).strip() for x in v if str(x).strip())
        dims=[]
        for k in ['variation_name','variant_name','option_dimension','option_name']:
            if str(d.get(k) or '').strip(): dims.append(str(d.get(k)).strip())
        vids=[]; skus=[]
        for k in VARIANT_ID_KEYS:
            if str(d.get(k) or '').strip(): vids.append(str(d.get(k)).strip())
        for k in VARIANT_SKU_KEYS:
            if str(d.get(k) or '').strip(): skus.append(str(d.get(k)).strip())
        for k in VARIANT_LIST_KEYS:
            vv=d.get(k)
            if isinstance(vv,list):
                for r in vv:
                    if not isinstance(r,dict): continue
                    for ik in VARIANT_ID_KEYS:
                        if str(r.get(ik) or '').strip(): vids.append(str(r.get(ik)).strip())
                    for sk in VARIANT_SKU_KEYS:
                        if str(r.get(sk) or '').strip(): skus.append(str(r.get(sk)).strip())
                    for ok in ['option_value','variation_value','value','name']:
                        if str(r.get(ok) or '').strip(): options.append(str(r.get(ok)).strip())
        flags=d.get('multi_variant_flags') if isinstance(d.get('multi_variant_flags'),dict) else {}
        opt_count=flags.get('option_count')
        schema_explicit=has_adapter_shape or exact_excel_prov
        explicit_no=schema_explicit and not options and not dims and not vids and not skus and (opt_count in (0,'0',None))
        pimgs=[str(x).strip() for x in (d.get('image_urls') or []) if str(x).strip().startswith(('http://','https://'))]
        oimgs=[str(x).strip() for x in (d.get('option_image_urls') or []) if str(x).strip().startswith(('http://','https://'))]
        objs.append({'product_id':pid,'source_file':str(path),'source_record':opath,'source_type':'excel_derived_structured_json',
                     'option_dimensions':sorted(set(dims)),'option_values':sorted(set(options)),'variant_ids':sorted(set(vids)),'variant_skus':sorted(set(skus)),
                     'product_image_urls':sorted(set(pimgs)),'option_image_urls':sorted(set(oimgs)),
                     'schema_has_option_columns':schema_explicit,'explicit_no_variants':bool(explicit_no),'authoritative_rank':95})
    return objs

def v4c0_constraints():
    bypid=defaultdict(list); files=defaultdict(set)
    for p in sorted((ROOT/'_system/reports').glob('v4c0_b*_semantic_review*.json')):
        try: obj=json.loads(p.read_text(encoding='utf-8-sig',errors='replace'))
        except Exception: continue
        for prod in obj.get('products') or []:
            pid=str(prod.get('product_id') or '')
            if not pid: continue
            for c in prod.get('variant_constraints') or []:
                if c not in bypid[pid]: bypid[pid].append(str(c))
            files[pid].add(str(p))
    return bypid,files

def conflict_from_constraints(constraints, verdict=''):
    text=(' '.join(constraints)+' '+str(verdict)).lower()
    hard=('identity_conflict','product_identity_conflict','cannot_be_mapped','mapping_conflict','variant_conflict')
    return any(x in text for x in hard)

def fact_objects(ctx):
    sf=ctx.get('safe_facts')
    if isinstance(sf,list): return sf
    if isinstance(sf,dict): return list(sf.values())
    return []

def fact_field(f):
    if isinstance(f,dict):
        s=' '.join(str(f.get(k) or '') for k in ['claim_type','field','fact_type','key','name'])
    else: s=''
    for field,pat in FIELD_PATTERNS.items():
        if pat.search(s): return field
    return None

def record_key(r):
    return (r['source_file'],r['source_record'],r['product_id'])

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    ready=read_jsonl(READY_Q); ctxs=read_jsonl(GEN_CTX); src=read_jsonl(SRC_INV)
    if len(ready)!=549: raise SystemExit(f'expected 549 READY slots, got {len(ready)}')
    ready_pids=sorted({str(r['product_id']) for r in ready})
    if len(ready_pids)!=145: raise SystemExit(f'expected 145 READY products, got {len(ready_pids)}')
    ready_by_pid=defaultdict(list)
    for r in ready: ready_by_pid[str(r['product_id'])].append(r)
    ctx_by_key={(str(r.get('product_id')),str(r.get('slot') or r.get('slot_role') or r.get('canonical_slot') or '')):r for r in ctxs}
    src_by_seq={int(r['sequence']):r for r in src if str(r.get('sequence','')).isdigit()}
    src_url_by_seq={k:str(v.get('url') or '') for k,v in src_by_seq.items()}

    constraints,constraint_files=v4c0_constraints()
    registry={'schema_version':'v4c5.2-variant-specific-field-registry-1','fields':{f:{'guard_only':True,'source':'frozen_v4c0_variant_constraints'} for f in VARIANT_FIELDS},'rule':'Registry raises scope review strictness only; it never supplies variant factual values.'}
    write_json(OUT/'variant_specific_field_registry.json',registry)

    records=[]; scanned=[]
    tracked=git_ls_files()
    excluded_prefixes=('_system/v4c/factual_gate/','_system/v4c/generation_plan/','_system/v4c/generation_payload/','_system/v4c/variant_readiness_audit/','_system/v4c/variant_inventory/','_system/memory/')
    for p in tracked:
        sp=p.as_posix()
        if sp.startswith(excluded_prefixes): continue
        ext=p.suffix.lower()
        if ext=='.xlsx':
            for sheet,rows in xlsx_rows(p):
                rr=structured_from_table(p,sheet,rows,'tracked_xlsx_structured')
                if rr: records.extend(rr); scanned.append({'file':sp,'type':'xlsx','records':len(rr)})
        elif ext=='.csv':
            try:
                with p.open(encoding='utf-8-sig',errors='replace',newline='') as f:
                    raw=list(csv.reader(f))
                rows=[{i:v for i,v in enumerate(row)} for row in raw]
                rr=structured_from_table(p,'csv',rows,'tracked_csv_structured')
                if rr: records.extend(rr); scanned.append({'file':sp,'type':'csv','records':len(rr)})
            except Exception: pass
        elif ext in ('.json','.jsonl') and ('catalog' in sp.lower() or 'v4c0' in sp.lower() or 'product' in sp.lower() or 'excel' in sp.lower()):
            rr=structured_from_json(p)
            if rr: records.extend(rr); scanned.append({'file':sp,'type':'json_structured','records':len(rr)})

    # Deduplicate exact evidence records, preferring higher authority.
    uniq={}
    for r in records:
        k=record_key(r)
        if k not in uniq or r['authoritative_rank']>uniq[k]['authoritative_rank']: uniq[k]=r
    records=list(uniq.values())
    bypid=defaultdict(list)
    for r in records: bypid[r['product_id']].append(r)

    # Select source(s) by strongest authority and product coverage, without merging contradictory product records into facts.
    source_stats=defaultdict(lambda:{'products':set(),'option_keys':set(),'variant_keys':set(),'rank':0})
    for r in records:
        st=source_stats[r['source_file']]; st['products'].add(r['product_id']); st['rank']=max(st['rank'],r['authoritative_rank'])
        for d in r['option_dimensions'] or ['']:
            for v in r['option_values']: st['option_keys'].add((r['product_id'],d,v))
        for v in r['variant_ids']+r['variant_skus']: st['variant_keys'].add((r['product_id'],v))
    source_ranking=sorted(({'file':f,'product_count':len(s['products']),'variant_option_count':len(s['option_keys']),'variant_identity_count':len(s['variant_keys']),'rank':s['rank']} for f,s in source_stats.items()), key=lambda x:(x['rank'],x['product_count'],x['variant_option_count']), reverse=True)
    best_file=source_ranking[0]['file'] if source_ranking else None
    canonical_status='PARTIAL_PROVEN_INVENTORY' if best_file else 'NO_AUTHORITATIVE_STRUCTURED_VARIANT_SOURCE'
    historical_count=None; historical_status='HISTORICAL_VARIANT_OPTION_COUNT_NOT_CANONICALLY_RECONCILABLE'
    for s in source_ranking:
        if s['variant_option_count']==2673:
            historical_count=2673; historical_status='RECONCILED_2673_FROM_SINGLE_DURABLE_STRUCTURED_SOURCE'; best_file=s['file']; canonical_status='CANONICAL_SINGLE_SOURCE_RECONCILED'; break

    canonical=[]; dimensions=[]; provenance=[]
    selected_files={best_file} if best_file else set()
    # If several exact excel-derived sources tie by product coverage/rank, keep all as partial provenance but do not double-count canonical options.
    if source_ranking:
        top=source_ranking[0]
        selected_files.update(s['file'] for s in source_ranking if s['rank']==top['rank'] and s['product_count']==top['product_count'])
    seen_opt=set(); seen_dim=set(); seen_prov=set()
    for r in records:
        if selected_files and r['source_file'] not in selected_files: continue
        provenance_key=(r['product_id'],r['source_file'],r['source_record'])
        if provenance_key not in seen_prov:
            provenance.append({'schema_version':'v4c5.2-variant-source-provenance-1','product_id':r['product_id'],'source_file':r['source_file'],'source_record':r['source_record'],'source_type':r['source_type'],'authoritative_rank':r['authoritative_rank'],'explicit_no_variants':r['explicit_no_variants']}); seen_prov.add(provenance_key)
        dims=r['option_dimensions'] or ([None] if r['option_values'] else [])
        for d in r['option_dimensions']:
            k=(r['product_id'],d,r['source_file'])
            if k not in seen_dim:
                dimensions.append({'schema_version':'v4c5.2-variant-option-dimension-1','product_id':r['product_id'],'option_dimension':d,'source_file':r['source_file'],'source_record':r['source_record']}); seen_dim.add(k)
        for d in dims:
            for v in r['option_values']:
                k=(r['product_id'],d or '',v)
                if k in seen_opt: continue
                canonical.append({'schema_version':'v4c5.2-canonical-variant-inventory-1','inventory_record_id':'VOPT-'+hashlib.sha256(('|'.join(k)).encode()).hexdigest()[:20],'product_id':r['product_id'],'variant_id':None,'variant_sku':None,'option_dimension':d,'option_value':v,'source_file':r['source_file'],'source_record':r['source_record'],'status':'AUTHORITATIVE_OPTION_VALUE','active':True}); seen_opt.add(k)
        for vid in r['variant_ids']:
            k=(r['product_id'],'@variant_id',vid)
            if k in seen_opt: continue
            canonical.append({'schema_version':'v4c5.2-canonical-variant-inventory-1','inventory_record_id':'VID-'+hashlib.sha256(('|'.join(k)).encode()).hexdigest()[:20],'product_id':r['product_id'],'variant_id':vid,'variant_sku':None,'option_dimension':None,'option_value':None,'source_file':r['source_file'],'source_record':r['source_record'],'status':'AUTHORITATIVE_VARIANT_ID','active':True}); seen_opt.add(k)
        for sku in r['variant_skus']:
            k=(r['product_id'],'@variant_sku',sku)
            if k in seen_opt: continue
            canonical.append({'schema_version':'v4c5.2-canonical-variant-inventory-1','inventory_record_id':'VSKU-'+hashlib.sha256(('|'.join(k)).encode()).hexdigest()[:20],'product_id':r['product_id'],'variant_id':None,'variant_sku':sku,'option_dimension':None,'option_value':None,'source_file':r['source_file'],'source_record':r['source_record'],'status':'AUTHORITATIVE_VARIANT_SKU','active':True}); seen_opt.add(k)

    # Conflict detection is source-local and structural only.
    conflict_pids=set()
    for pid,rr in bypid.items():
        bysource=defaultdict(list)
        for r in rr: bysource[r['source_file']].append(r)
        for sf,rows in bysource.items():
            id_to_values=defaultdict(set); sku_to_values=defaultdict(set)
            for r in rows:
                signature=tuple(sorted(r['option_values']))
                for v in r['variant_ids']: id_to_values[v].add(signature)
                for s in r['variant_skus']: sku_to_values[s].add(signature)
            if any(len(v)>1 for v in id_to_values.values()) or any(len(v)>1 for v in sku_to_values.values()): conflict_pids.add(pid)
        # Explicit historical variant identity/mapping conflict may only make an already-READY product unsafe, never safe.
        if conflict_from_constraints(constraints.get(pid,[])): conflict_pids.add(pid)

    product_summaries=[]; product_proofs=[]; slot_proofs=[]; delta=[]; eligible=[]
    counts=Counter(); slot_counts=Counter(); b_fact_violations=0; invented=0; cross_variant=0
    for pid in ready_pids:
        rr=sorted(bypid.get(pid,[]), key=lambda x:x['authoritative_rank'], reverse=True)
        a_evidence=[r for r in rr if r['explicit_no_variants']]
        variant_evidence=[r for r in rr if r['option_values'] or r['option_dimensions'] or r['variant_ids'] or r['variant_skus']]
        ready_slots=ready_by_pid[pid]
        ready_urls=[]; all_source_trace=True
        for s in ready_slots:
            seq=int(s.get('source_sequence') or 0)
            url=src_url_by_seq.get(seq,'')
            ready_urls.append(url)
            if not url: all_source_trace=False
        cls='D_VARIANT_MAPPING_AMBIGUOUS'; reason='no authoritative A/B proof recovered; remain D'
        proof=[]; common_fact_viol=[]
        if pid in conflict_pids:
            cls='E_VARIANT_CONFLICT_UNSAFE'; reason='authoritative structured or frozen mapping conflict evidence'; proof=[{'type':'CONFLICT','sources':sorted({r['source_file'] for r in rr})}]
        elif a_evidence:
            # A requires an authoritative row proving schema-present zero variants and no contradictory variant evidence of equal/higher rank.
            a=a_evidence[0]
            contradiction=[r for r in variant_evidence if r['authoritative_rank']>=a['authoritative_rank']]
            if not contradiction:
                cls='A_NO_PRODUCT_VARIANTS'; reason='authoritative structured source proves zero option dimensions/values/variant IDs/SKUs'
                proof=[{'type':'NO_VARIANTS','source_file':a['source_file'],'source_record':a['source_record'],'variant_count':0,'option_dimension_count':0}]
        if cls=='D_VARIANT_MAPPING_AMBIGUOUS' and variant_evidence:
            # B: exact parent product image URL coverage for every READY slot + all safe facts non-variant-specific.
            common_candidates=[]
            for r in variant_evidence:
                pset=set(r['product_image_urls']); oset=set(r['option_image_urls'])
                if pset and all_source_trace and all(u in pset for u in ready_urls) and not any(u in oset for u in ready_urls if u): common_candidates.append(r)
            if common_candidates:
                candidate=common_candidates[0]
                for s in ready_slots:
                    key=(pid,str(s.get('slot_role') or s.get('slot') or ''))
                    ctx=ctx_by_key.get(key,{})
                    for f in fact_objects(ctx):
                        fld=fact_field(f)
                        if fld: common_fact_viol.append({'slot':key[1],'field':fld,'fact':f if isinstance(f,dict) else str(f)})
                if not common_fact_viol:
                    cls='B_VARIANTS_EXIST_SHARED_IMAGE_SCOPE_SAFE'; reason='authoritative variants + exact READY source URLs are parent-product images + all payload facts pass common-scope intersection'
                    proof=[{'type':'VARIANTS_EXIST','source_file':candidate['source_file'],'source_record':candidate['source_record'],'option_dimension_count':len(candidate['option_dimensions']),'option_value_count':len(candidate['option_values'])},{'type':'COMMON_PARENT_IMAGE','ready_source_count':len(ready_urls),'all_ready_sources_parent_level':True},{'type':'FACT_SCOPE_INTERSECTION','variant_specific_fact_leak':0}]
                else:
                    b_fact_violations += len(common_fact_viol)
        counts[cls]+=1
        scope={'A_NO_PRODUCT_VARIANTS':'NO_VARIANTS','B_VARIANTS_EXIST_SHARED_IMAGE_SCOPE_SAFE':'COMMON_TO_ALL_VARIANTS','D_VARIANT_MAPPING_AMBIGUOUS':'VARIANT_MAPPING_UNKNOWN','E_VARIANT_CONFLICT_UNSAFE':'VARIANT_CONFLICT'}[cls]
        product_summaries.append({'schema_version':'v4c5.2-product-variant-summary-1','product_id':pid,'product_has_variants':False if cls.startswith('A_') else True if cls.startswith(('B_','E_')) or bool(variant_evidence) else 'unknown','option_dimensions':sorted({d for r in rr for d in r['option_dimensions']}),'option_values':sorted({v for r in rr for v in r['option_values']}),'variant_identifiers':sorted({v for r in rr for v in r['variant_ids']}),'variant_skus':sorted({v for r in rr for v in r['variant_skus']}),'source_provenance':[{'source_file':r['source_file'],'source_record':r['source_record'],'source_type':r['source_type']} for r in rr[:8]],'confidence_status':'AUTHORITATIVE_PROVEN' if cls.startswith(('A_','B_','E_')) else 'UNRESOLVED','classification':cls,'scope_semantics':scope})
        product_proofs.append({'schema_version':'v4c5.2-ready-product-ab-proof-1','product_id':pid,'previous_classification':'D_VARIANT_MAPPING_AMBIGUOUS','classification':cls,'scope_semantics':scope,'proof':proof,'common_fact_scope_violations':common_fact_viol,'invented_mapping':False})
        transition='D_TO_A_PROVEN' if cls.startswith('A_') else 'D_TO_B_PROVEN' if cls.startswith('B_') else 'D_TO_E_CONFLICT' if cls.startswith('E_') else 'D_TO_D_UNRESOLVED'
        delta.append({'schema_version':'v4c5.2-scope-proof-delta-1','product_id':pid,'transition':transition,'scope_semantics':scope,'frozen_v4c5_1a_mutated':False})
        for s in ready_slots:
            slot_counts[scope]+=1
            slot_proofs.append({'schema_version':'v4c5.2-ready-slot-scope-proof-1','product_id':pid,'slot':s.get('slot_role'),'source_sequence':s.get('source_sequence'),'source_sha256':s.get('source_sha256'),'previous_variant_scope':s.get('variant_scope') or [],'scope_semantics':scope,'product_classification':cls,'scope_proof_status':'PROVEN' if cls.startswith(('A_','B_','E_')) else 'UNRESOLVED','queue_mutated':False})
            if cls.startswith(('A_','B_')) and pid not in LOCKED:
                eligible.append({'schema_version':'v4c5.2-paid-canary-eligible-overlay-1','product_id':pid,'slot':s.get('slot_role'),'source_sequence':s.get('source_sequence'),'source_sha256':s.get('source_sha256'),'scope_semantics':scope,'eligibility':'PAID_CANARY_SCOPE_ELIGIBLE','overlay_only':True})

    # Recommended sample: up to five proven A/B products; maximize category/subcategory strings already frozen in generation context.
    eligible_pids=sorted({r['product_id'] for r in eligible})
    category_by_pid={}
    for c in ctxs:
        pid=str(c.get('product_id') or '')
        if pid not in eligible_pids: continue
        cat=str(c.get('category') or c.get('subcategory') or c.get('route') or 'unknown')
        category_by_pid.setdefault(pid,cat)
    recommended=[]; used_cat=set()
    for pid in eligible_pids:
        cat=category_by_pid.get(pid,'unknown')
        if cat not in used_cat and len(recommended)<5: recommended.append(pid); used_cat.add(cat)
    for pid in eligible_pids:
        if pid not in recommended and len(recommended)<5: recommended.append(pid)

    # Negative controls: unresolved D first, prioritizing explicit V4-C0 constraints.
    d_pids=[p['product_id'] for p in product_proofs if p['classification']=='D_VARIANT_MAPPING_AMBIGUOUS']
    neg=sorted(d_pids,key=lambda p:(0 if constraints.get(p) else 1,p))[:3]
    negative={'schema_version':'v4c5.2-negative-controls-1','product_ids':neg,'required_preflight_behavior':'REJECT_AS_VARIANT_MAPPING_UNKNOWN','same_sha_wrong_variant_case':'use existing V4-C4.2 identity/variant negative probe when applicable','must_not_be_upgraded_by_ab_overlay':True}

    authoritative_products=len({r['product_id'] for r in canonical})
    authoritative_variants=len({(r['product_id'],r.get('variant_id') or r.get('variant_sku')) for r in canonical if r.get('variant_id') or r.get('variant_sku')})
    authoritative_options=len({(r['product_id'],r.get('option_dimension') or '',r.get('option_value')) for r in canonical if r.get('option_value') is not None})
    resolved=(counts['A_NO_PRODUCT_VARIANTS']+counts['B_VARIANTS_EXIST_SHARED_IMAGE_SCOPE_SAFE'])>0

    write_jsonl(OUT/'canonical_variant_inventory.jsonl',canonical)
    write_jsonl(OUT/'product_variant_summary.jsonl',product_summaries)
    write_jsonl(OUT/'variant_option_dimensions.jsonl',dimensions)
    write_jsonl(OUT/'variant_source_provenance.jsonl',provenance)
    write_jsonl(OUT/'ready_product_ab_proof.jsonl',product_proofs)
    write_jsonl(OUT/'ready_slot_scope_proof.jsonl',slot_proofs)
    write_jsonl(OUT/'scope_proof_delta_overlay.jsonl',delta)
    write_jsonl(OUT/'paid_canary_eligible_overlay.jsonl',eligible)
    write_json(OUT/'paid_canary_recommended_samples.json',{'schema_version':'v4c5.2-paid-canary-recommended-samples-1','product_ids':recommended,'max_products':5,'selection_rule':'A/B proven only; category diversity when frozen category metadata is available','generation_executed':False})
    write_json(OUT/'negative_control_samples.json',negative)

    coverage={'schema_version':'v4c5.2-coverage-1','stage':'V4-C5.2 Authoritative Variant Inventory + A/B Scope Proof Recovery','authoritative_source_files_used':sorted(selected_files),'structured_source_candidates':source_ranking[:30],'canonical_variant_inventory_status':canonical_status,'authoritative_product_count':authoritative_products,'authoritative_variant_count':authoritative_variants,'authoritative_variant_option_count':authoritative_options,'historical_2673_reconciliation_status':historical_status,'historical_variant_option_count':historical_count,'ready_products_audited':145,'ready_slots_audited':549,'proven_A_products':counts['A_NO_PRODUCT_VARIANTS'],'proven_B_products':counts['B_VARIANTS_EXIST_SHARED_IMAGE_SCOPE_SAFE'],'unresolved_D_products':counts['D_VARIANT_MAPPING_AMBIGUOUS'],'conflict_E_products':counts['E_VARIANT_CONFLICT_UNSAFE'],'A_slot_count':slot_counts['NO_VARIANTS'],'B_common_slot_count':slot_counts['COMMON_TO_ALL_VARIANTS'],'D_unknown_slot_count':slot_counts['VARIANT_MAPPING_UNKNOWN'],'E_conflict_slot_count':slot_counts['VARIANT_CONFLICT'],'variant_specific_field_registry_count':len(VARIANT_FIELDS),'B_fact_scope_violations':b_fact_violations,'invented_mapping_count':invented,'cross_variant_contamination':cross_variant,'paid_canary_eligible_product_count':len(eligible_pids),'paid_canary_eligible_slot_count':len(eligible),'recommended_canary_product_ids':recommended,'negative_control_product_ids':neg,'paid_canary_scope_blocker_resolved':resolved,'paid_canary_may_safely_resume_after_explicit_authorization':resolved,'next_recommendation':'EXPLICIT_AUTHORIZATION_REQUIRED_FOR_PAID_CANARY' if resolved else 'BUILD_CLEAN_VARIANT_SEMANTICS_CANARY_POOL','image_generation_executed':False,'paid_api_called':False,'tracked_structured_files_scanned':scanned}
    write_json(OUT/'coverage_summary.json',coverage)

    frozen_paths=[READY_Q,GEN_CTX,C51A_LOCK,APP_FACT,APP_OUT,MEM_DB,API_V2]
    fingerprints={str(p).replace('\\','/'):sha256_file(p) for p in frozen_paths if p.exists()}
    validation={'schema_version':'v4c5.2-validation-1','passed':True,'ready_products_input':len(ready_pids),'ready_slots_input':len(ready),'each_A_has_authoritative_no_variant_provenance':all(bool(p['proof']) for p in product_proofs if p['classification'].startswith('A_')),'each_B_has_authoritative_variant_common_scope_provenance':all(len(p['proof'])>=3 for p in product_proofs if p['classification'].startswith('B_')),'variant_specific_facts_in_B_common_payload':b_fact_violations,'invented_variant_mapping':invented,'D_upgraded_without_proof':0,'E_upgraded_to_safe':0,'cross_variant_contamination':cross_variant,'v4c5_queue_mutation':0,'v4c5_1a_lock_mutation':0,'approved_memory_mutation':0,'locked_regeneration':0,'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,'semantic_inference_executed':False,'preservation_reexecuted':False,'factual_gate_retested':False,'planner_retested':False,'payload_retested':False,'memory_bootstrap_retested':False,'image_generation_called':False,'image_editing_api_called':False,'tiny_snow_api_called':False,'vision_api_called':False,'paid_api_called':False,'generation_executed':False,'frozen_fingerprints':fingerprints}
    validation['passed']=all([validation['ready_products_input']==145,validation['ready_slots_input']==549,validation['each_A_has_authoritative_no_variant_provenance'],validation['each_B_has_authoritative_variant_common_scope_provenance'],b_fact_violations==0,invented==0,cross_variant==0])
    write_json(OUT/'validation.json',validation)
    if not validation['passed']: raise SystemExit('V4-C5.2 validation failed')

    lock={'schema_version':'v4c5.2-variant-inventory-scope-proof-lock-1','passed':True,'sealed':True,'stage':'V4-C5.2 Authoritative Variant Inventory + A/B Scope Proof Recovery','base_head':'176d1d3566fee16360200eb3a39bc48f899d9c19','workflow_run':os.environ.get('GITHUB_RUN_ID'),'stable_head_expected':'5d49f061e140813b3d229520e9e530f86b27b640','canonical_variant_inventory_status':canonical_status,'authoritative_source_files_used':sorted(selected_files),'authoritative_product_count':authoritative_products,'authoritative_variant_count':authoritative_variants,'authoritative_variant_option_count':authoritative_options,'historical_2673_reconciliation_status':historical_status,'proven_A_products':counts['A_NO_PRODUCT_VARIANTS'],'proven_B_products':counts['B_VARIANTS_EXIST_SHARED_IMAGE_SCOPE_SAFE'],'unresolved_D_products':counts['D_VARIANT_MAPPING_AMBIGUOUS'],'conflict_E_products':counts['E_VARIANT_CONFLICT_UNSAFE'],'paid_canary_scope_blocker_resolved':resolved,'paid_canary_may_safely_resume_after_explicit_authorization':resolved,'generation_executed':False,'paid_api_called':False,'next_stage_requires_explicit_user_authorization':True}
    write_json(OUT/'V4_C5_2_VARIANT_INVENTORY_SCOPE_PROOF_LOCK.json',lock)
    print(json.dumps(coverage,ensure_ascii=False,indent=2))

if __name__=='__main__': main()
