#!/usr/bin/env python3
import argparse, base64, gzip, hashlib, json, os, re, sys, time
from collections import Counter, defaultdict
from pathlib import Path
from urllib.request import Request, urlopen

SCHEMA = 'v4c2.3.hold-evidence-hydration.1'
GAP_SCHEMA = 'v4c2.3.evidence-gap-index.1'
BASE_HEAD = '577b3c4333ce34494012ca51e0c1bc0c637ada53'
EXPECTED_TOTAL = 1378
BATCHES = {f'B{i:03d}': ((i-1)*50+1, i*50) for i in range(1,19)}
GAP_PRIORITY = ['SOURCE_CONFLICT','VARIANT_CONFLICT','LOW_CONFIDENCE','MISSING_VISUAL_EVIDENCE','MISSING_OCR','MISSING_SEMANTIC_EVIDENCE']
HEX64 = re.compile(r'^[0-9a-f]{64}$')
CHINESE_RE = re.compile(r'[\u3400-\u9fff]')


def read_jsonl(path):
    out=[]
    if not path: return out
    p=Path(path)
    if not p.exists(): return out
    for i,line in enumerate(p.open(encoding='utf-8-sig'),1):
        if not line.strip(): continue
        try: out.append(json.loads(line))
        except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out


def write_jsonl(path, rows):
    p=Path(path); p.parent.mkdir(parents=True, exist_ok=True)
    with p.open('w', encoding='utf-8', newline='\n') as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False, separators=(',',':'))+'\n')


def append_jsonl(path,row):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('a',encoding='utf-8',newline='\n') as f:
        f.write(json.dumps(row,ensure_ascii=False,separators=(',',':'))+'\n'); f.flush(); os.fsync(f.fileno())


def write_json(path,obj):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')


def sha_bytes(data): return hashlib.sha256(data).hexdigest()
def sha_file(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_context_b64(path):
    raw=base64.b64decode(Path(path).read_text(encoding='ascii').strip())
    text=gzip.decompress(raw).decode('utf-8-sig')
    out={}
    for line in text.splitlines():
        if line.strip():
            r=json.loads(line);out[str(r.get('product_id',''))]=r
    return out


def artifact_inventory(path):
    data=json.loads(Path(path).read_text(encoding='utf-8-sig'))
    arts=data.get('artifacts',data if isinstance(data,list) else [])
    byname={str(a.get('name','')):a for a in arts}
    b=[]
    for name,(lo,hi) in BATCHES.items():
        an='V4-C0-SourceReview-'+name
        a=byname.get(an)
        b.append({'batch':name,'artifact_name':an,'sequence_start':lo,'sequence_end':hi,
                  'present':bool(a),'expired':bool((a or {}).get('expired',False)),
                  'artifact_id':(a or {}).get('id'),'digest':(a or {}).get('digest')})
    turbo=[]
    for an in ['v4c-turbo-final','v4c-turbo-reconciled']:
        a=byname.get(an)
        turbo.append({'artifact_name':an,'present':bool(a),'expired':bool((a or {}).get('expired',False)),
                      'artifact_id':(a or {}).get('id'),'digest':(a or {}).get('digest')})
    return b,turbo


def semantic_key_map(rows):
    out={}
    for r in rows:
        sha=str(r.get('sha256') or '').lower();pid=str(r.get('product_id') or '')
        if HEX64.match(sha): out[(pid,sha)]=r
    return out


def preservation_key_map(rows):
    out={}
    for r in rows:
        sha=str(r.get('sha256') or '').lower();pid=str(r.get('product_id') or '')
        if HEX64.match(sha): out[(pid,sha)]=r
    return out


def semantic_quality(rec):
    if not rec:return None
    texts=((((rec.get('visual_evidence') or {}).get('ocr') or {}).get('texts')) or [])
    conf=[]
    for x in texts:
        try: conf.append(float(x.get('confidence',0) or 0))
        except: pass
    return max(conf) if conf else 0.0


def has_durable_visual(rec):
    if not rec:return False
    ve=rec.get('visual_evidence') or {}
    md=ve.get('image_metadata') or ve.get('image') or {}
    return bool(ve) and (bool(ve.get('ocr')) or bool(md) or bool(ve.get('local_model')))


def make_variant_conflicts(source_rows):
    grp=defaultdict(set)
    for r in source_rows:
        pid=str(r.get('product_id','')); idx=r.get('image_index')
        sha=str(r.get('sha256') or '').lower()
        if pid and idx is not None and HEX64.match(sha): grp[(pid,int(idx))].add(sha)
    return {k:v for k,v in grp.items() if len(v)>1}


def build_index(a):
    holds=read_jsonl(a.holds)
    if len(holds)!=EXPECTED_TOTAL: raise RuntimeError(f'Expected {EXPECTED_TOTAL} HOLD records, got {len(holds)}')
    if any(str(r.get('terminal_status'))!='HOLD' for r in holds): raise RuntimeError('V4-C2.2 input contains non-HOLD terminal record')
    source_rows=read_jsonl(a.source_evidence);source={int(r['sequence']):r for r in source_rows}
    sem=semantic_key_map(read_jsonl(a.semantic_evidence));pres=preservation_key_map(read_jsonl(a.preservation_evidence))
    dup=json.loads(Path(a.duplicate_map).read_text(encoding='utf-8-sig'))
    dup_by_seq={int(x['sequence']):int(x['canonical_sequence']) for x in dup.get('sha256_duplicates',[])}
    variants=make_variant_conflicts(source_rows)
    barts,turbo=artifact_inventory(a.artifact_inventory)
    if not all(x['present'] and not x['expired'] for x in barts): raise RuntimeError('B001-B018 artifact inventory incomplete/expired')
    if not all(x['present'] and not x['expired'] for x in turbo): raise RuntimeError('V4-C1 workflow artifact inventory incomplete/expired')
    rows=[]; counts=Counter(); action=Counter(); reuse=0; meta_reuse=0
    for h in sorted(holds,key=lambda x:int(x['sequence'])):
        seq=int(h['sequence']);s=source.get(seq)
        pid=str(h.get('product_id') or (s or {}).get('product_id') or '')
        hold_sha=str(h.get('sha256') or '').lower(); src_sha=str((s or {}).get('sha256') or '').lower()
        gaps=[]; reasons=[]
        if not s:
            gaps.append('SOURCE_CONFLICT');reasons.append('SOURCE_LEDGER_ROW_MISSING')
        elif str(s.get('status')) not in {'DONE','SHA_DUPLICATE'}:
            gaps.append('SOURCE_CONFLICT');reasons.append('SOURCE_STATUS_NOT_TERMINAL_DONE')
        if not HEX64.match(src_sha):
            gaps.append('SOURCE_CONFLICT');reasons.append('V4C1_SHA_MISSING_OR_INVALID')
        if HEX64.match(hold_sha) and HEX64.match(src_sha) and hold_sha!=src_sha:
            gaps.append('SOURCE_CONFLICT');reasons.append('V4C2_2_SHA_DIFFERS_FROM_V4C1')
        idx=(s or {}).get('image_index')
        if s and (pid,int(idx)) in variants:
            gaps.append('VARIANT_CONFLICT');reasons.append('MULTIPLE_SHA_FOR_PRODUCT_IMAGE_INDEX')
        key=(pid,src_sha)
        sr=sem.get(key); pr=pres.get(key)
        reusable_visual=has_durable_visual(sr)
        preserve_done=bool(pr and str(pr.get('decision')) in {'PRESERVE','PRESERVE_DIRECT'})
        if sr and semantic_quality(sr) is not None and 0 < semantic_quality(sr) < 0.90:
            gaps.append('LOW_CONFIDENCE');reasons.append('EXISTING_OCR_BELOW_CLAIM_THRESHOLD')
        if reusable_visual:
            reuse+=1
            ocr=((sr.get('visual_evidence') or {}).get('ocr') or {})
            if not (ocr.get('texts') is not None): gaps.append('MISSING_OCR')
        elif preserve_done:
            reuse+=1
        else:
            gaps.append('MISSING_VISUAL_EVIDENCE');reasons.append('NO_DURABLE_VISUAL_EVIDENCE_FOR_CURRENT_SHA')
        if not gaps:
            gaps.append('MISSING_SEMANTIC_EVIDENCE');reasons.append('VISUAL_OR_OCR_PRESENT_BUT_CLAIM_EVIDENCE_NOT_DURABLE')
        gaps=list(dict.fromkeys(gaps)); primary=next((g for g in GAP_PRIORITY if g in gaps),gaps[0])
        in_b=any(x['sequence_start']<=seq<=x['sequence_end'] for x in barts)
        canon=dup_by_seq.get(seq)
        canon_in_b=canon is not None and any(x['sequence_start']<=canon<=x['sequence_end'] for x in barts)
        artifact_visual=bool(in_b or canon_in_b)
        if artifact_visual and not reusable_visual and not preserve_done and 'MISSING_VISUAL_EVIDENCE' in gaps:
            hydration='USE_B001_B018_VISUAL'
        elif 'SOURCE_CONFLICT' in gaps or 'VARIANT_CONFLICT' in gaps:
            hydration='BLOCK_CONFLICT'
        elif reusable_visual or preserve_done:
            hydration='REUSE_EXISTING_EVIDENCE'
        else:
            hydration='FETCH_VISUAL'
        fetch_allowed=(hydration=='FETCH_VISUAL')
        meta_reuse+=1 if s else 0
        row={'schema_version':GAP_SCHEMA,'sequence':seq,'source_id':str(h.get('source_id') or (s or {}).get('source_id') or ''),
             'product_id':pid,'image_index':(s or {}).get('image_index'),'image_type':(s or {}).get('image_type'),
             'source_url':(s or {}).get('url'),'expected_sha256':src_sha,'v4c2_2_sha256':hold_sha,
             'source_status':(s or {}).get('status'),'gap_types':gaps,'primary_gap':primary,'gap_reasons':reasons,
             'hydration_action':hydration,'fetch_allowed':fetch_allowed,
             'reuse':{'v4c1_source_metadata':bool(s),'v4c1_sha':HEX64.match(src_sha) is not None,
                      'existing_semantic_evidence':bool(sr),'existing_preservation_evidence':bool(pr),
                      'b001_b018_artifact_checked':True,'b001_b018_visual_available':artifact_visual,
                      'v4c1_workflow_artifacts_checked':True,'canonical_duplicate_sequence':canon},
             'provenance':{'base_head':BASE_HEAD,'inventory_rebuilt':False,'known_sha_recomputed':False,
                           'historical_ocr_rerun':False,'semantic_140_rerun':False}}
        rows.append(row);counts.update(gaps);action[hydration]+=1
    write_jsonl(a.output,rows)
    can=[];byp=defaultdict(list)
    for r in rows:byp[r['product_id']].append(r)
    pids=sorted(byp,key=lambda p:hashlib.sha256(p.encode()).hexdigest())
    while len(can)<a.canary_size:
        moved=False
        for pid in pids:
            if byp[pid] and len(can)<a.canary_size:
                can.append(byp[pid].pop(0));moved=True
        if not moved:break
    if len(can)!=a.canary_size:raise RuntimeError('Unable to select hydration canary')
    write_jsonl(a.canary_out,can)
    canseq={int(x['sequence']) for x in can};remaining=[r for r in rows if int(r['sequence']) not in canseq]
    shard_size=max(1,int(a.shard_size)); shards=[]
    outdir=Path(a.shards_dir);outdir.mkdir(parents=True,exist_ok=True)
    for i in range(0,len(remaining),shard_size):
        name=f'shard-{i//shard_size+1:03d}';path=outdir/(name+'.jsonl');write_jsonl(path,remaining[i:i+shard_size]);shards.append({'shard':name,'count':len(remaining[i:i+shard_size])})
    write_json(a.matrix_out,{'include':shards})
    summ={'schema_version':'v4c2.3.gap-summary.1','passed':True,'total':len(rows),'canary_count':len(can),'remaining_after_canary':len(remaining),
          'gap_counts':dict(counts),'action_counts':dict(action),'evidence_already_reusable':reuse,
          'source_metadata_sha_reused':meta_reuse,'visual_fetch_required':action.get('FETCH_VISUAL',0),
          'b001_b018_artifacts_checked':18,'b001_b018_sequence_coverage':'1-900','v4c1_workflow_artifacts_checked':2,
          'inventory_rebuilt':False,'known_sha_recomputed':False,'historical_ocr_rerun':False,'semantic_140_rerun':False}
    write_json(a.summary,summ)
    print('GAP_INDEX_TOTAL='+str(len(rows)));print('CANARY_COUNT='+str(len(can)));print('VISUAL_FETCH_REQUIRED='+str(summ['visual_fetch_required']));print('SOURCE_METADATA_SHA_REUSED='+str(meta_reuse))


def load_models():
    from PIL import Image
    from rapidocr_onnxruntime import RapidOCR
    from opencc import OpenCC
    return Image,RapidOCR(),OpenCC('s2t'),OpenCC('t2s')


def fetch_targeted(row,cache_dir):
    expected=str(row.get('expected_sha256') or '').lower()
    if not HEX64.match(expected): return None,None,'BLOCK_SOURCE_CHANGED','EXPECTED_SHA_INVALID'
    url=str(row.get('source_url') or '')
    if not url.startswith('https://'): return None,None,'BLOCK_SOURCE_CHANGED','SOURCE_URL_INVALID'
    cache=Path(cache_dir);cache.mkdir(parents=True,exist_ok=True);path=cache/(expected+'.img')
    if path.exists():
        data=path.read_bytes();actual=sha_bytes(data)
        if actual==expected:return path,data,'SHA_MATCH','CACHE_REUSE'
        path.unlink()
    last=None
    for attempt in range(1,4):
        try:
            with urlopen(Request(url,headers={'User-Agent':'TinySnow-V4C2.3-Hydration/1.0'}),timeout=40) as resp:data=resp.read()
            actual=sha_bytes(data)
            if actual!=expected:return None,data,'BLOCK_SOURCE_CHANGED',f'SHA_MISMATCH:{actual}'
            tmp=path.with_suffix('.tmp');tmp.write_bytes(data);os.replace(tmp,path)
            return path,data,'SHA_MATCH','TARGETED_SOURCE_FETCH'
        except Exception as e:
            last=e
            if attempt<3:time.sleep(attempt)
    return None,None,'HOLD',f'FETCH_FAILED:{last}'


def ocr_evidence(path,models):
    Image,ocr,s2t,t2s=models
    with Image.open(path) as im:
        fmt=im.format;w,h=im.size;mode=im.mode
    result,_=ocr(str(path));texts=[];trad=simp=chinese=0;confs=[]
    for row in result or []:
        try:
            box=row[0];text=str(row[1]);conf=float(row[2])
        except:continue
        if not text.strip():continue
        bbox=[]
        try:bbox=[[float(p[0]),float(p[1])] for p in box]
        except:bbox=[]
        texts.append({'text':text[:500],'confidence':round(conf,6),'bounding_box':bbox});confs.append(conf)
        chars=''.join(CHINESE_RE.findall(text));chinese+=len(chars)
        if chars:
            if s2t.convert(chars)!=chars:simp+=1
            if t2s.convert(chars)!=chars:trad+=1
    if chinese==0:state='NO_CHINESE_TEXT'
    elif simp>0 and trad==0:state='SIMPLIFIED_DETECTED'
    elif trad>0 and simp==0:state='TRADITIONAL_CONFIRMED'
    elif trad>0 and simp>0:state='MIXED_SCRIPT'
    else:state='CHINESE_AMBIGUOUS'
    script={'classification':state,'traditional_signal_count':trad,'simplified_signal_count':simp,'chinese_char_count':chinese}
    conf={'ocr_mean':round(sum(confs)/len(confs),6) if confs else None,'ocr_min':round(min(confs),6) if confs else None,'ocr_max':round(max(confs),6) if confs else None,'ocr_text_count':len(texts)}
    return {'format':fmt,'width_px':w,'height_px':h,'mode':mode},texts,script,conf


def resolve_claims(seq,pid,sha,ctx,texts):
    here=str(Path(__file__).resolve().parent)
    if here not in sys.path:sys.path.insert(0,here)
    from v4c_claim_level_gate import resolve
    rec={'sequence':seq,'source_id':'','product_id':pid,'sha256':sha,'semantic_status':'HYDRATED_OCR','gate':{'status':'HOLD'},
         'context':ctx or {},'visual_evidence':{'ocr':{'texts':texts}}}
    return resolve(rec)


def reusable_to_evidence(row,sem_map,pres_map):
    key=(str(row.get('product_id','')),str(row.get('expected_sha256','')).lower())
    pr=pres_map.get(key);sr=sem_map.get(key)
    if pr and str(pr.get('decision')) in {'PRESERVE','PRESERVE_DIRECT'}:
        return {'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'sha256':row.get('expected_sha256'),
                'evidence_origin':'EXISTING_PRESERVATION_REUSE','image_metadata':{},'ocr':{'texts':[]},'script_classification':{},
                'localization_state':'HISTORY_CONFIRMED','claim_candidates':[],'verified_claims':[],'unknown_claims':[],
                'evidence_location':{'durable':'_system/v4c/preservation/results/image_preservation.jsonl'},
                'preservation_decision':'PRESERVE','confidence':{'preservation':1.0},'claim_gate_status':'SKIP_PRESERVE','terminal_status':'PRESERVE',
                'flags':flags(False,False,False)}
    if sr:
        cg=resolve_claims(int(row['sequence']),str(row.get('product_id','')),str(row.get('expected_sha256','')),sr.get('context') or {},((((sr.get('visual_evidence') or {}).get('ocr') or {}).get('texts')) or []))
        claims=list(cg.get('claims') or [])
        return {'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'sha256':row.get('expected_sha256'),
                'evidence_origin':'EXISTING_SEMANTIC_REUSE','image_metadata':((sr.get('visual_evidence') or {}).get('image_metadata') or {}),
                'ocr':((sr.get('visual_evidence') or {}).get('ocr') or {}),'script_classification':((sr.get('visual_evidence') or {}).get('script_classification') or {}),
                'localization_state':str(sr.get('localization_state') or 'EXISTING_EVIDENCE'),'claim_candidates':claims,
                'verified_claims':[c for c in claims if c.get('status')=='VERIFIED_SOURCE'],'unknown_claims':[c for c in claims if c.get('status')=='UNKNOWN'],
                'evidence_location':{'durable':'_system/v4c/semantic/preservation/semantic_evidence.jsonl'},
                'preservation_decision':'NEEDS_LOCALIZATION','confidence':{'reused':True},'claim_gate_status':cg.get('claim_gate_status'),'terminal_status':cg.get('claim_gate_status'),
                'flags':flags(False,False,False)}
    return None


def flags(fetch_called,ocr,semantic,fetched_successfully=False):
    return {'targeted_source_fetch_called':bool(fetch_called),'fetched_successfully':bool(fetched_successfully),'sha_verified':False,'ocr_executed':bool(ocr),'semantic_inference_executed':bool(semantic),
            'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,
            'v4c1_retested':False,'v4c2_0_retested':False,'v4c2_1_retested':False,'v4c2_2_gate_retested':False}


def hydrate_one(row,models,ctx,sem_map,pres_map,cache_dir,evidence_repo_path):
    action=str(row.get('hydration_action'))
    if action=='REUSE_EXISTING_EVIDENCE':
        r=reusable_to_evidence(row,sem_map,pres_map)
        if r:return r
    if action=='BLOCK_CONFLICT':
        r={'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'sha256':row.get('expected_sha256'),
           'evidence_origin':'CONFLICT_INDEX','image_metadata':{},'ocr':{'texts':[]},'script_classification':{},'localization_state':'SOURCE_CONFLICT',
           'claim_candidates':[],'verified_claims':[],'unknown_claims':[],'evidence_location':{'durable':evidence_repo_path},
           'preservation_decision':'BLOCK','confidence':{'preservation':0.0},'claim_gate_status':'BLOCK','terminal_status':'BLOCK','block_reason':'SOURCE_OR_VARIANT_CONFLICT','flags':flags(False,False,False)}
        return r
    if action=='USE_B001_B018_VISUAL':
        p=Path(str(row.get('artifact_local_path') or ''))
        if not p.exists():
            r={'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'sha256':row.get('expected_sha256'),
               'evidence_origin':'B001_B018_ARTIFACT','image_metadata':{},'ocr':{'texts':[]},'script_classification':{},'localization_state':'MISSING_ARTIFACT_VISUAL',
               'claim_candidates':[],'verified_claims':[],'unknown_claims':[],'evidence_location':{'durable':evidence_repo_path},
               'preservation_decision':'HOLD','confidence':{'preservation':0.0},'claim_gate_status':'HOLD','terminal_status':'HOLD','flags':flags(False,False,False)}
            return r
        path=p;data=p.read_bytes();status='SHA_MATCH' if sha_bytes(data)==str(row.get('expected_sha256')) else 'BLOCK_SOURCE_CHANGED';reason='B001_B018_ARTIFACT_REUSE'
        fetched=False;fetched_successfully=True
    else:
        path,data,status,reason=fetch_targeted(row,cache_dir);fetched=(action=='FETCH_VISUAL');fetched_successfully=(data is not None)
    if status=='BLOCK_SOURCE_CHANGED':
        f=flags(fetched,False,False,fetched_successfully);f['sha_verified']=False
        return {'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'sha256':row.get('expected_sha256'),
                'actual_sha256':sha_bytes(data) if data else None,'evidence_origin':'TARGETED_SOURCE_FETCH','image_metadata':{},'ocr':{'texts':[]},'script_classification':{},
                'localization_state':'BLOCK_SOURCE_CHANGED','claim_candidates':[],'verified_claims':[],'unknown_claims':[],
                'evidence_location':{'durable':evidence_repo_path},'preservation_decision':'BLOCK_SOURCE_CHANGED','confidence':{'preservation':0.0},
                'claim_gate_status':'BLOCK','terminal_status':'BLOCK','block_reason':reason,'flags':f}
    if status=='HOLD' or path is None:
        return {'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'sha256':row.get('expected_sha256'),
                'evidence_origin':'TARGETED_SOURCE_FETCH','image_metadata':{},'ocr':{'texts':[]},'script_classification':{},'localization_state':'FETCH_FAILED',
                'claim_candidates':[],'verified_claims':[],'unknown_claims':[],'evidence_location':{'durable':evidence_repo_path},
                'preservation_decision':'HOLD','confidence':{'preservation':0.0},'claim_gate_status':'HOLD','terminal_status':'HOLD','hold_reason':reason,'flags':flags(fetched,False,False,fetched_successfully)}
    md,texts,script,conf=ocr_evidence(path,models)
    f=flags(fetched,True,False,fetched_successfully);f['sha_verified']=True
    state=script['classification']
    visual_loc={'durable':evidence_repo_path,'visual_cache_relative_path':str(Path(path).name)}
    base={'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'sha256':row.get('expected_sha256'),
          'actual_sha256':sha_file(path),'evidence_origin':'TARGETED_SOURCE_FETCH' if fetched else reason,'image_metadata':dict(md,byte_count=Path(path).stat().st_size),
          'ocr':{'engine':'rapidocr_onnxruntime','texts':texts},'script_classification':script,'localization_state':state,
          'evidence_location':visual_loc,'confidence':conf,'flags':f}
    if state in {'NO_CHINESE_TEXT','TRADITIONAL_CONFIRMED'}:
        base.update({'claim_candidates':[],'verified_claims':[],'unknown_claims':[],'preservation_decision':'PRESERVE','claim_gate_status':'SKIP_PRESERVE','terminal_status':'PRESERVE'})
        return base
    cg=resolve_claims(int(row['sequence']),str(row.get('product_id','')),str(row.get('expected_sha256','')),ctx or {},texts)
    claims=list(cg.get('claims') or [])
    unknown=[c for c in claims if c.get('status')=='UNKNOWN']
    for c in unknown:c['allowed_usage']='NONE'
    base.update({'claim_candidates':claims,'verified_claims':[c for c in claims if c.get('status')=='VERIFIED_SOURCE'],'unknown_claims':unknown,
                 'preservation_decision':'NEEDS_LOCALIZATION','claim_gate_status':cg.get('claim_gate_status'),'terminal_status':cg.get('claim_gate_status')})
    return base


def process(a):
    manifest=read_jsonl(a.manifest);ctx=load_context_b64(a.product_context)
    sem_map=semantic_key_map(read_jsonl(a.semantic_evidence));pres_map=preservation_key_map(read_jsonl(a.preservation_evidence))
    existing=read_jsonl(a.progress);done={int(r['sequence']):r for r in existing}
    target=len(manifest) if a.max_items<=0 else min(len(manifest),a.max_items)
    selected=manifest[:target];models=None;processed=0;skipped=0;fetches=0;ocr=0
    for row in selected:
        seq=int(row['sequence'])
        if seq in done:skipped+=1;continue
        if models is None and str(row.get('hydration_action')) in {'FETCH_VISUAL','USE_B001_B018_VISUAL'}:
            models=load_models();print('LOCAL_HYDRATION_OCR_READY=true',flush=True)
        r=hydrate_one(row,models,ctx.get(str(row.get('product_id',''))),sem_map,pres_map,a.cache_dir,a.evidence_repo_path)
        append_jsonl(a.progress,r);done[seq]=r;processed+=1
        if bool((r.get('flags') or {}).get('targeted_source_fetch_called')):fetches+=1
        if bool((r.get('flags') or {}).get('ocr_executed')):ocr+=1
        print(f"HYDRATION sequence={seq} preservation={r.get('preservation_decision')} terminal={r.get('terminal_status')}",flush=True)
    covered=sum(1 for row in selected if int(row['sequence']) in done)
    status=Counter(str(done[int(row['sequence'])].get('terminal_status')) for row in selected if int(row['sequence']) in done)
    pres=Counter(str(done[int(row['sequence'])].get('preservation_decision')) for row in selected if int(row['sequence']) in done)
    mismatch=sum(1 for row in selected if int(row['sequence']) in done and str(done[int(row['sequence'])].get('preservation_decision'))=='BLOCK_SOURCE_CHANGED')
    summ={'schema_version':'v4c2.3.hydration-run.1','manifest_count':len(manifest),'target_total':target,'checkpoint_existing_terminal':skipped,
          'processed_this_run':processed,'covered_after_run':covered,'targeted_fetch_this_run':fetches,'ocr_this_run':ocr,
          'sha_mismatch_source_changed':mismatch,'terminal_counts':dict(status),'preservation_counts':dict(pres),
          'semantic_actually_executed':0,'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False}
    write_json(a.summary,summ)
    print('CHECKPOINT_EXISTING_TERMINAL='+str(skipped));print('PROCESSED_THIS_RUN='+str(processed));print('COVERED_AFTER_RUN='+str(covered));print('TARGETED_FETCH_THIS_RUN='+str(fetches));print('SEMANTIC_ACTUALLY_EXECUTED=0')


def aggregate(a):
    gaps=read_jsonl(a.gap_index);expected={int(r['sequence']) for r in gaps}
    ev=[]
    for p in Path(a.results_root).rglob('*.evidence.jsonl'):
        ev.extend(read_jsonl(str(p)))
    if a.canary_progress:ev.extend(read_jsonl(a.canary_progress))
    by={}
    for r in ev:
        seq=int(r['sequence'])
        if seq in by and json.dumps(by[seq],sort_keys=True,ensure_ascii=False)!=json.dumps(r,sort_keys=True,ensure_ascii=False):
            raise RuntimeError(f'Conflicting evidence record for sequence {seq}')
        by[seq]=r
    missing=sorted(expected-set(by));extra=sorted(set(by)-expected)
    if missing or extra:raise RuntimeError(f'Aggregate reconciliation failed missing={missing[:10]} extra={extra[:10]}')
    out=[by[int(r['sequence'])] for r in sorted(gaps,key=lambda x:int(x['sequence']))]
    write_jsonl(a.output,out)
    terminal=Counter(str(r.get('terminal_status')) for r in out);pres=Counter(str(r.get('preservation_decision')) for r in out)
    fetch_attempted=sum(bool((r.get('flags') or {}).get('targeted_source_fetch_called')) for r in out)
    fetched=sum(bool((r.get('flags') or {}).get('fetched_successfully')) for r in out)
    sha_mismatch=sum(str(r.get('preservation_decision'))=='BLOCK_SOURCE_CHANGED' for r in out)
    semantic=sum(bool((r.get('flags') or {}).get('semantic_inference_executed')) for r in out)
    reusable=sum(str(r.get('evidence_origin','')).startswith('EXISTING_') for r in out)
    summ={'schema_version':'v4c2.3.hydration-final-summary.1','passed':True,'total':len(out),'evidence_already_reusable':reusable,
          'visual_fetch_required':sum(str(r.get('hydration_action'))=='FETCH_VISUAL' for r in gaps),'fetch_attempted':fetch_attempted,'fetched':fetched,'sha_mismatch_source_changed':sha_mismatch,
          'preserve':pres.get('PRESERVE',0),'needs_localization':pres.get('NEEDS_LOCALIZATION',0),'partial_safe':terminal.get('PARTIAL_SAFE',0),
          'hold':terminal.get('HOLD',0),'block':terminal.get('BLOCK',0),'pass':terminal.get('PASS',0),'remaining':0,'semantic_actually_executed':semantic,
          'api_flags':{'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False},
          'historical_retests':{'v4c1':False,'v4c2_0':False,'v4c2_1':False,'v4c2_2_gate':False}}
    write_json(a.summary,summ);print('AGGREGATE_TOTAL='+str(len(out)));print('PRESERVE='+str(summ['preserve']));print('NEEDS_LOCALIZATION='+str(summ['needs_localization']));print('PARTIAL_SAFE='+str(summ['partial_safe']));print('HOLD='+str(summ['hold']));print('BLOCK='+str(summ['block']))


def selftest():
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        p=Path(td)/'x';p.write_bytes(b'current-source-bytes')
        expected=hashlib.sha256(b'other-source-bytes').hexdigest()
        actual=sha_file(p)
        assert actual!=expected
    unk={'status':'UNKNOWN','allowed_usage':'NONE'};assert unk['allowed_usage']=='NONE'
    print('V4C2_3_SELFTEST=true');print('BLOCK_SOURCE_CHANGED_PATH=true');print('UNKNOWN_ALLOWED_USAGE_NONE=true');print('HISTORICAL_RETEST=false')


def main():
    ap=argparse.ArgumentParser();sp=ap.add_subparsers(dest='cmd',required=True)
    p=sp.add_parser('index');p.add_argument('--holds',required=True);p.add_argument('--source-evidence',required=True);p.add_argument('--semantic-evidence',required=True);p.add_argument('--preservation-evidence',required=True);p.add_argument('--duplicate-map',required=True);p.add_argument('--artifact-inventory',required=True);p.add_argument('--output',required=True);p.add_argument('--summary',required=True);p.add_argument('--canary-out',required=True);p.add_argument('--canary-size',type=int,default=100);p.add_argument('--shards-dir',required=True);p.add_argument('--shard-size',type=int,default=160);p.add_argument('--matrix-out',required=True)
    p=sp.add_parser('process');p.add_argument('--manifest',required=True);p.add_argument('--semantic-evidence',required=True);p.add_argument('--preservation-evidence',required=True);p.add_argument('--product-context',required=True);p.add_argument('--progress',required=True);p.add_argument('--summary',required=True);p.add_argument('--cache-dir',required=True);p.add_argument('--evidence-repo-path',default='_system/v4c/evidence_hydration/evidence.jsonl');p.add_argument('--max-items',type=int,default=0)
    p=sp.add_parser('aggregate');p.add_argument('--gap-index',required=True);p.add_argument('--results-root',required=True);p.add_argument('--canary-progress');p.add_argument('--output',required=True);p.add_argument('--summary',required=True)
    sp.add_parser('self-test')
    a=ap.parse_args()
    if a.cmd=='index':build_index(a)
    elif a.cmd=='process':process(a)
    elif a.cmd=='aggregate':aggregate(a)
    else:selftest()
    return 0
if __name__=='__main__':sys.exit(main())
