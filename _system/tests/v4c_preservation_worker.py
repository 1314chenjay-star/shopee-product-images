#!/usr/bin/env python3
import argparse, hashlib, json, os, re, sys, time
from pathlib import Path
from urllib.request import Request, urlopen

SCHEMA='v4c2.0.image-preservation.1'
TERMINAL={'PRESERVE','SEMANTIC_REQUIRED','BLOCK'}
CHINESE_RE=re.compile(r'[\u3400-\u9fff]')

def read_jsonl(path):
    p=Path(path); out=[]
    if not p.exists(): return out
    for i,line in enumerate(p.open(encoding='utf-8-sig'),1):
        if line.strip(): out.append(json.loads(line))
    return out

def append_jsonl(path,obj):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('a',encoding='utf-8',newline='\n') as f:
        f.write(json.dumps(obj,ensure_ascii=False,separators=(',',':'))+'\n'); f.flush(); os.fsync(f.fileno())

def load_ocr():
    from PIL import Image
    from rapidocr_onnxruntime import RapidOCR
    from opencc import OpenCC
    return Image, RapidOCR(), OpenCC('s2t'), OpenCC('t2s')

def fetch_verified(record,cache_dir):
    expected=str(record.get('sha256') or '').lower()
    if not re.fullmatch(r'[a-f0-9]{64}',expected):
        raise RuntimeError('V4C1_SHA256_MISSING')
    cache=Path(cache_dir); cache.mkdir(parents=True,exist_ok=True); path=cache/(expected+'.img')
    if path.exists():
        data=path.read_bytes(); actual=hashlib.sha256(data).hexdigest()
        if actual==expected: return path,False,len(data)
        path.unlink()
    url=str(record.get('url') or '')
    if not url.startswith('https://'): raise RuntimeError('INVALID_SOURCE_URL')
    last=None
    for attempt in range(1,4):
        try:
            with urlopen(Request(url,headers={'User-Agent':'TinySnow-V4C2-Preservation/1.0'}),timeout=35) as r: data=r.read()
            actual=hashlib.sha256(data).hexdigest()
            if actual!=expected: raise RuntimeError('SOURCE_SHA_MISMATCH:'+actual)
            tmp=path.with_suffix('.tmp'); tmp.write_bytes(data); os.replace(tmp,path)
            return path,True,len(data)
        except Exception as e:
            last=e
            if attempt<3: time.sleep(attempt)
    raise RuntimeError('FETCH_FAILED:'+str(last))

def ocr_signals(path,models):
    Image,ocr,s2t,t2s=models
    with Image.open(path) as im:
        rgb=im.convert('RGB'); fmt=im.format; w,h=rgb.size
    result,_=ocr(str(path)); texts=[]; trad=0; simp=0; chinese=0
    for row in result or []:
        try: text=str(row[1]); conf=float(row[2])
        except Exception: continue
        if not text.strip(): continue
        texts.append({'text':text[:300],'confidence':round(conf,6)})
        chars=''.join(CHINESE_RE.findall(text)); chinese += len(chars)
        if chars:
            if s2t.convert(chars)!=chars: simp += 1
            if t2s.convert(chars)!=chars: trad += 1
    return {'format':fmt,'width_px':w,'height_px':h,'texts':texts[:80],'ocr_text_count':len(texts),'traditional_signal_count':trad,'simplified_signal_count':simp,'chinese_char_count':chinese}

def clone_for_reuse(record,canonical):
    out=json.loads(json.dumps(canonical,ensure_ascii=False))
    out.update({'sequence':int(record['sequence']),'source_id':str(record['source_id']),'product_id':str(record['product_id']),'image_index':int(record['image_index']),'image_type':str(record['image_type']),'sha256':str(record['sha256']).lower()})
    out['evidence']['method']='SHA_REUSE'; out['evidence']['sha_reuse_from_sequence']=int(canonical['sequence']); out['evidence']['texts']=[]
    out['checkpoint']={'terminal':True,'semantic_required':out['decision']=='SEMANTIC_REQUIRED'}
    return out

def history_record(record):
    return {'schema_version':SCHEMA,'sequence':int(record['sequence']),'source_id':str(record['source_id']),'product_id':str(record['product_id']),'image_index':int(record['image_index']),'image_type':str(record['image_type']),'is_main_image':int(record['image_index'])==0,'sha256':str(record['sha256']).lower(),'decision':'PRESERVE','localization_state':'HISTORY_CONFIRMED','evidence':{'method':'SHA_HISTORY','ocr_text_count':0,'traditional_signal_count':0,'simplified_signal_count':0,'chinese_char_count':0,'sha_reuse_from_sequence':None,'texts':[]},'checkpoint':{'terminal':True,'semantic_required':False},'flags':{'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'source_pipeline_redownload':False}}

def block_record(record,reason):
    return {'schema_version':SCHEMA,'sequence':int(record['sequence']),'source_id':str(record['source_id']),'product_id':str(record['product_id']),'image_index':int(record['image_index']),'image_type':str(record['image_type']),'is_main_image':int(record['image_index'])==0,'sha256':str(record.get('sha256') or '').lower(),'decision':'BLOCK','localization_state':'SOURCE_FAILED','evidence':{'method':'LOCAL_OCR','ocr_text_count':0,'traditional_signal_count':0,'simplified_signal_count':0,'chinese_char_count':0,'sha_reuse_from_sequence':None,'texts':[],'reason':reason},'checkpoint':{'terminal':True,'semantic_required':False},'flags':{'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'source_pipeline_redownload':False}}

def analyze(record,models,cache):
    try: path,fetched,byte_count=fetch_verified(record,cache)
    except Exception as e: return block_record(record,str(e)),False,False
    try: sig=ocr_signals(path,models)
    except Exception as e:
        out=block_record(record,'OCR_FAILED:'+str(e)); out['localization_state']='OCR_FAILED'; return out,fetched,True
    trad,simp,chi=sig['traditional_signal_count'],sig['simplified_signal_count'],sig['chinese_char_count']
    if chi==0:
        decision,state='PRESERVE','NO_CHINESE_TEXT'
    elif simp>0 and trad==0:
        decision,state='SEMANTIC_REQUIRED','SIMPLIFIED_DETECTED'
    elif trad>0 and simp==0:
        decision,state='PRESERVE','TRADITIONAL_CONFIRMED'
    elif trad>0 and simp>0:
        decision,state='SEMANTIC_REQUIRED','MIXED_SCRIPT'
    else:
        decision,state='SEMANTIC_REQUIRED','CHINESE_AMBIGUOUS'
    out={'schema_version':SCHEMA,'sequence':int(record['sequence']),'source_id':str(record['source_id']),'product_id':str(record['product_id']),'image_index':int(record['image_index']),'image_type':str(record['image_type']),'is_main_image':int(record['image_index'])==0,'sha256':str(record['sha256']).lower(),'decision':decision,'localization_state':state,'evidence':{'method':'LOCAL_OCR','ocr_text_count':sig['ocr_text_count'],'traditional_signal_count':trad,'simplified_signal_count':simp,'chinese_char_count':chi,'sha_reuse_from_sequence':None,'texts':sig['texts'],'format':sig['format'],'width_px':sig['width_px'],'height_px':sig['height_px'],'byte_count':byte_count,'semantic_image_fetch':fetched},'checkpoint':{'terminal':True,'semantic_required':decision=='SEMANTIC_REQUIRED'},'flags':{'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'source_pipeline_redownload':False}}
    return out,fetched,True

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--manifest',required=True); ap.add_argument('--progress',required=True); ap.add_argument('--confirmed-sha',default=''); ap.add_argument('--cache-dir',default='artifacts/preservation-cache'); ap.add_argument('--summary',required=True); ap.add_argument('--max-items',type=int,default=0); a=ap.parse_args()
    manifest=read_jsonl(a.manifest); existing=read_jsonl(a.progress); byseq={int(r['sequence']):r for r in existing if str(r.get('decision')) in TERMINAL}; bysha={str(r.get('sha256') or '').lower():r for r in existing if re.fullmatch(r'[a-f0-9]{64}',str(r.get('sha256') or '').lower())}
    confirmed={str(r.get('sha256') or '').lower() for r in read_jsonl(a.confirmed_sha) if re.fullmatch(r'[a-f0-9]{64}',str(r.get('sha256') or '').lower())}
    pending=[r for r in manifest if int(r['sequence']) not in byseq]; pending=pending[:a.max_items] if a.max_items else pending
    models=None; processed=history=sha_reuse=fetched=ocr_count=0
    for r in pending:
        sha=str(r.get('sha256') or '').lower()
        if sha in confirmed:
            rec=history_record(r); history+=1
        elif sha in bysha:
            rec=clone_for_reuse(r,bysha[sha]); sha_reuse+=1
        else:
            if models is None: models=load_ocr(); print('LOCAL_PRESERVATION_OCR_READY=true',flush=True)
            rec,did_fetch,did_ocr=analyze(r,models,a.cache_dir); fetched+=1 if did_fetch else 0; ocr_count+=1 if did_ocr else 0
        append_jsonl(a.progress,rec); byseq[int(rec['sequence'])]=rec
        if re.fullmatch(r'[a-f0-9]{64}',str(rec.get('sha256') or '').lower()): bysha[str(rec['sha256']).lower()]=rec
        processed+=1; print(f"PRESERVATION sequence={rec['sequence']} decision={rec['decision']} state={rec['localization_state']} method={rec['evidence']['method']}",flush=True)
    final=read_jsonl(a.progress); covered=sum(1 for r in manifest if int(r['sequence']) in {int(x['sequence']) for x in final})
    summary={'schema_version':'v4c2.0.preservation-worker.1','manifest_count':len(manifest),'checkpoint_existing_terminal':len(existing),'checkpoint_skipped_this_run':len(manifest)-len(pending) if not a.max_items else len(existing),'processed_this_run':processed,'covered_after_run':covered,'history_skip_this_run':history,'sha_reuse_this_run':sha_reuse,'network_fetch_this_run':fetched,'ocr_this_run':ocr_count,'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'source_pipeline_redownload':False}
    Path(a.summary).parent.mkdir(parents=True,exist_ok=True); Path(a.summary).write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    print('WORKER_SUMMARY='+json.dumps(summary,separators=(',',':')),flush=True)
    return 0

if __name__=='__main__': sys.exit(main())
