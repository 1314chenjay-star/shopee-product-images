#!/usr/bin/env python3
from __future__ import annotations
import base64,bz2,gzip,hashlib,json,lzma,sys,zlib
from pathlib import Path

EXPECTED_PARTS=5
EXPECTED_WORKBOOK_SHA='616d1c0639f34433ebe244678f101458e375c1c095677be7d9f5736b2ccecb9a'
ROOT=Path(__file__).resolve().parents[2] if '_system' in str(Path(__file__).resolve()) else Path.cwd()
PART_DIR=ROOT/'_system/source_truth/bootstrap_transport'
OUT_DIR=ROOT/'_system/v4c/source_truth_bootstrap'
OUT_DIR.mkdir(parents=True,exist_ok=True)
OUT=OUT_DIR/'reassembly_checkpoint.json'

def sha(b:bytes)->str:return hashlib.sha256(b).hexdigest()

def try_json(data:bytes):
    try:
        text=data.decode('utf-8-sig')
        return json.loads(text), text
    except Exception:
        return None,None

def find_scalar(obj,names):
    names={n.lower() for n in names}
    if isinstance(obj,dict):
        for k,v in obj.items():
            if str(k).lower() in names and not isinstance(v,(dict,list)):
                return v
        for v in obj.values():
            r=find_scalar(v,names)
            if r is not None:return r
    elif isinstance(obj,list):
        for v in obj[:50]:
            r=find_scalar(v,names)
            if r is not None:return r
    return None

def list_count(obj,names):
    names={n.lower() for n in names}; hits=[]
    def rec(x,path=''):
        if isinstance(x,dict):
            for k,v in x.items():
                p=f'{path}.{k}' if path else str(k)
                if str(k).lower() in names and isinstance(v,list): hits.append((p,len(v)))
                rec(v,p)
        elif isinstance(x,list):
            for i,v in enumerate(x[:5]): rec(v,f'{path}[{i}]')
    rec(obj); return hits

def main():
    parts=[]; missing=[]
    for i in range(1,EXPECTED_PARTS+1):
        p=PART_DIR/f'recovered_snapshot.b64.part{i:02d}'
        if not p.exists(): missing.append(p.name); continue
        s=''.join(p.read_text(encoding='utf-8').split())
        parts.append({'name':p.name,'chars':len(s),'sha256':hashlib.sha256(s.encode()).hexdigest(),'text':s})
    if missing or len(parts)!=EXPECTED_PARTS:
        raise SystemExit('REASSEMBLY_PARTS_INCOMPLETE:'+','.join(missing))
    joined=''.join(x['text'] for x in parts)
    try: raw=base64.b64decode(joined,validate=True)
    except Exception as e: raise SystemExit('REASSEMBLY_BASE64_INVALID:'+repr(e))
    transforms=[('identity',lambda b:b),('gzip',gzip.decompress),('zlib',zlib.decompress),('raw_deflate',lambda b:zlib.decompress(b,-15)),('bz2',bz2.decompress),('lzma',lzma.decompress)]
    candidates=[]; chosen=None
    for name,fn in transforms:
        try:
            data=fn(raw); obj,_=try_json(data)
            rec={'transform':name,'decoded_size':len(data),'decoded_sha256':sha(data),'json':obj is not None,'magic_hex':data[:16].hex()}
            if obj is not None:
                rec['top_level_type']=type(obj).__name__
                rec['top_level_keys']=sorted(obj.keys())[:50] if isinstance(obj,dict) else None
                if chosen is None: chosen=(name,data,obj,rec)
            candidates.append(rec)
        except Exception as e:
            candidates.append({'transform':name,'error':type(e).__name__+':'+str(e)[:180]})
    result={
      'schema_version':'v4c5.3-reassembly-checkpoint-1','part_sequence_complete':True,'part_count':len(parts),
      'part_metadata':[{k:v for k,v in x.items() if k!='text'} for x in parts],
      'joined_base64_sha256':sha(joined.encode()),'reconstructed_payload_size':len(raw),
      'reconstructed_payload_sha256':sha(raw),'payload_magic_hex':raw[:16].hex(),
      'candidate_transforms':candidates,'expected_workbook_sha256':EXPECTED_WORKBOOK_SHA,'status':'FORMAT_UNRESOLVED'}
    if chosen:
        name,data,obj,rec=chosen
        result['detected_transform']=name; result['structured_snapshot_sha256']=sha(data); result['structured_snapshot_size']=len(data)
        result['top_level_keys']=rec.get('top_level_keys')
        result['embedded_workbook_sha256']=find_scalar(obj,['workbook_sha256','source_file_sha256','source_sha256','file_sha256'])
        result['product_list_candidates']=list_count(obj,['products','product_rows','商品总表','商品總表'])
        result['image_list_candidates']=list_count(obj,['images','image_rows','图片明细','圖片明細'])
        result['variant_list_candidates']=list_count(obj,['variants','variant_options','variant_rows','规格明细','規格明細'])
        result['status']='REASSEMBLED_STRUCTURED_SNAPSHOT'
        (OUT_DIR/'recovered_snapshot.runtime.json').write_bytes(data)
    OUT.write_text(json.dumps(result,ensure_ascii=False,indent=2,sort_keys=True)+'\n',encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False,indent=2,sort_keys=True))
    return 0 if chosen else 2

if __name__=='__main__':sys.exit(main())
