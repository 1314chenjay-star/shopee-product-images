#!/usr/bin/env python3
from __future__ import annotations
import argparse, base64, hashlib, json, lzma, pathlib, sys, tarfile, tempfile
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '_system' / 'source_truth'))
from source_truth_store import SourceTruthStore  # noqa: E402

EXPECTED_WORKBOOK_SHA = '616d1c0639f34433ebe244678f101458e375c1c095677be7d9f5736b2ccecb9a'
EXPECTED = {'products':375,'gallery_images':2394,'variant_options':2673}

def canon(x): return json.dumps(x, ensure_ascii=False, sort_keys=True, separators=(',',':'))
def sha(b): return hashlib.sha256(b).hexdigest()
def hkey(prefix,*parts): return prefix+'_'+hashlib.sha256('\0'.join(str(x) for x in parts).encode('utf-8')).hexdigest()[:24]

def extract_transport(transport_dir,dest_dir):
    tdir=pathlib.Path(transport_dir); meta=json.loads((tdir/'transport.meta.json').read_text(encoding='utf-8'))
    if meta.get('schema_version')!='tinysnow.c53-manifest-transport.2': raise RuntimeError('TRANSPORT_SCHEMA_VERSION_UNEXPECTED')
    if meta.get('encoding')!='base64(xz(tar))': raise RuntimeError('TRANSPORT_ENCODING_UNEXPECTED')
    if meta.get('contained_manifest_source_file_sha256')!=EXPECTED_WORKBOOK_SHA: raise RuntimeError('TRANSPORT_AUTHORITY_SHA_MISMATCH')
    parts=[]
    for spec in meta.get('parts',[]):
        p=tdir/spec['name']; b=p.read_bytes()
        if len(b)!=spec['chars'] or sha(b)!=spec['sha256']: raise RuntimeError(f"TRANSPORT_PART_INTEGRITY_MISMATCH:{spec['name']}")
        parts.append(b)
    b64=b''.join(parts)
    if len(b64)!=meta['base64_chars'] or sha(b64)!=meta['base64_sha256']: raise RuntimeError('TRANSPORT_BASE64_INTEGRITY_MISMATCH')
    payload=base64.b64decode(b64,validate=True)
    if len(payload)!=meta['transport_bytes'] or sha(payload)!=meta['transport_sha256']: raise RuntimeError('TRANSPORT_PAYLOAD_INTEGRITY_MISMATCH')
    tar_bytes=lzma.decompress(payload,format=lzma.FORMAT_XZ)
    out=pathlib.Path(dest_dir); out.mkdir(parents=True,exist_ok=True); tar_path=out/'manifest.tar'; tar_path.write_bytes(tar_bytes)
    allowed={'m.json','p.jsonl','i.jsonl','v.jsonl'}
    with tarfile.open(tar_path,'r:') as tf:
        names=set(tf.getnames())
        if names!=allowed: raise RuntimeError(f'TRANSPORT_MEMBER_SET_MISMATCH:{sorted(names)}')
        for member in tf.getmembers():
            if member.name not in allowed or not member.isfile(): raise RuntimeError('TRANSPORT_MEMBER_UNSAFE')
        tf.extractall(out,filter='data')
    tar_path.unlink()
    return meta,out

def rows(path):
    return [json.loads(x) for x in pathlib.Path(path).read_text(encoding='utf-8-sig').splitlines() if x.strip()]

def verify_manifest(transport_meta,d):
    d=pathlib.Path(d); m=json.loads((d/'m.json').read_text(encoding='utf-8'))
    if m.get('v')!=1 or m.get('source_file_sha256')!=EXPECTED_WORKBOOK_SHA: raise RuntimeError('MANIFEST_AUTHORITY_MISMATCH')
    if m.get('source_file_size')!=609457: raise RuntimeError('MANIFEST_SOURCE_SIZE_MISMATCH')
    if m.get('counts') != [375,2394,2673]: raise RuntimeError(f"MANIFEST_COUNTS_MISMATCH:{m.get('counts')}")
    if transport_meta.get('contained_manifest_counts')!=EXPECTED: raise RuntimeError('TRANSPORT_COUNT_MISMATCH')
    p=rows(d/'p.jsonl'); i=rows(d/'i.jsonl'); v=rows(d/'v.jsonl')
    if (len(p),len(i),len(v))!=(375,2394,2673): raise RuntimeError('MANIFEST_ROW_COUNT_MISMATCH')
    if any(len(x)!=2 for x in p) or any(len(x)!=4 for x in i) or any(len(x)!=6 for x in v): raise RuntimeError('MANIFEST_ARRAY_SCHEMA_MISMATCH')
    pids=[str(x[0]) for x in p]
    if len(set(pids))!=375: raise RuntimeError('PRODUCT_ID_UNIQUENESS_MISMATCH')
    if {str(x[0]) for x in i}!=set(pids) or {str(x[0]) for x in v}!=set(pids): raise RuntimeError('PRODUCT_SET_MISMATCH')
    gallery_keys=[(str(x[0]),str(x[2])) for x in i]
    if len(set(gallery_keys))!=2394: raise RuntimeError('GALLERY_PRODUCT_URL_DUPLICATE')
    variant_keys=[(str(x[0]),str(x[1]),int(x[2]),str(x[3])) for x in v]
    if len(set(variant_keys))!=2673: raise RuntimeError('VARIANT_IDENTITY_DUPLICATE')
    blank=sum(1 for x in v if x[4] in (None,'')); nonblank=len(v)-blank
    unique_variant_images=len({(str(x[0]),str(x[4])) for x in v if x[4] not in (None,'')})
    if blank!=145 or nonblank!=2528 or unique_variant_images!=2515: raise RuntimeError(f'VARIANT_IMAGE_COUNTS_UNEXPECTED:{blank}:{nonblank}:{unique_variant_images}')
    return m,p,i,v

def read_evidence(path):
    ev=rows(path)
    if len(ev)!=2394: raise RuntimeError(f'C1_SOURCE_EVIDENCE_COUNT_MISMATCH:{len(ev)}')
    by={}; dup=[]
    for r in ev:
        if r.get('paid_api_called') is not False or r.get('image_generation_called') is not False or r.get('tiny_snow_api_called') is not False: raise RuntimeError('C1_FORBIDDEN_CALL_FLAG_NOT_FALSE')
        k=(str(r.get('product_id','')).strip(),str(r.get('url','')).strip())
        if not all(k): raise RuntimeError('C1_EVIDENCE_KEY_MISSING')
        if k in by: dup.append(k)
        else: by[k]=r
    if dup: raise RuntimeError(f'C1_PRODUCT_URL_DUPLICATE:{len(dup)}')
    return ev,by

def bootstrap(m,p_rows,i_rows,v_rows,evidence_path,outdir):
    outdir=pathlib.Path(outdir); outdir.mkdir(parents=True,exist_ok=True); db=outdir/'source_truth.sqlite'
    if db.exists(): db.unlink()
    evidence,evidence_by_key=read_evidence(evidence_path)
    gallery_by_pid=Counter(str(x[0]) for x in i_rows); vars_by_pid=Counter(str(x[0]) for x in v_rows)
    store=SourceTruthStore(db); batch=hkey('batch',EXPECTED_WORKBOOK_SHA)
    variant_image_key_by_product_url={}; gallery_exact=0; gallery_sha=0; missing_gallery=[]
    with store.writer() as con:
        con.execute("""insert into source_batches (source_batch_id,platform,source_type,original_filename,source_file_sha256,file_size,imported_at,export_timestamp,sheet_inventory_json,row_counts_json,schema_fingerprint,parser_version,capture_status,raw_snapshot_sha256) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
          (batch,'SHOPEE_TW','PLATFORM_RAW_STRUCTURED','TinySnow_V4C0_375_authoritative.xlsx',EXPECTED_WORKBOOK_SHA,609457,'2026-08-18T00:00:00Z',None,canon(['商品总表','图片明细','规格明细']),canon(EXPECTED),sha(canon(m.get('schemas')).encode()),'c53-recovery-2','CAPTURED_SANITIZED_MANIFEST',sha(canon(m).encode())))
        for pid,row in p_rows:
            pid=str(pid); src={'product_id':pid,'source_sheet':'商品总表','source_row':int(row)}; rh=sha(canon(src).encode())
            con.execute("insert into source_products (source_batch_id,product_id,parent_sku,original_product_name,original_category,original_description,product_has_variants,variant_count,image_count,raw_record_json,source_record_hash,source_row,status) values(?,?,?,?,?,?,?,?,?,?,?,?,?)",
              (batch,pid,None,None,None,None,1,int(vars_by_pid[pid]),int(gallery_by_pid[pid]),canon(src),rh,int(row),'ACTIVE'))
            fid=hkey('fld',batch,pid,'PRODUCT','product_id')
            con.execute("insert into source_fields (source_batch_id,field_id,product_id,variant_scope_key,field_name,raw_value,normalized_value,authority_type,volatile_business_field,status) values(?,?,?,?,?,?,?,?,?,?)",(batch,fid,pid,'PRODUCT','product_id',pid,pid,'PLATFORM_RAW_STRUCTURED',0,'ACTIVE'))
            con.execute("insert into source_field_provenance (source_batch_id,field_id,source_file_sha256,sheet_name,source_row,source_column,source_record_hash,source_image_sha256,created_at,superseded_by,status) values(?,?,?,?,?,?,?,?,?,?,?)",(batch,fid,EXPECTED_WORKBOOK_SHA,'商品总表',int(row),'A',rh,None,'2026-08-18T00:00:00Z',None,'ACTIVE'))
        for pid,seq,url,row in i_rows:
            pid=str(pid); url=str(url); seq=int(seq); row=int(row); ev=evidence_by_key.get((pid,url))
            if ev is None: missing_gallery.append((pid,url)); source_id=None; source_seq=None; source_sha=None
            else:
                gallery_exact+=1; source_id=ev.get('source_id'); source_seq=ev.get('sequence'); source_sha=ev.get('sha256')
                if source_sha: gallery_sha+=1
            ik=hkey('img_g',pid,url,seq); src={'product_id':pid,'image_sequence':seq,'url':url,'source_sheet':'图片明细','source_row':row}; rh=sha(canon(src).encode())
            con.execute("insert into source_images (source_batch_id,image_identity_key,product_id,image_position,image_sequence,original_source_url,normalized_source_url,reconciled_source_id,reconciled_source_sequence,source_sha256,raw_record_json,source_record_hash,source_row,scope_semantics,scope_status) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
              (batch,ik,pid,'GALLERY',str(seq),url,url,source_id,int(source_seq) if source_seq is not None else None,source_sha,canon(src),rh,row,'GALLERY_UNSCOPED','VARIANT_MAPPING_UNKNOWN'))
        for pid,vname,idx,oname,opt_url,row in v_rows:
            pid=str(pid); vname=str(vname); idx=int(idx); oname=str(oname); row=int(row); opt_url=None if opt_url in (None,'') else str(opt_url)
            vk=hkey('var',pid,vname,idx,oname); src={'product_id':pid,'variation_name':vname,'option_index':idx,'option_name':oname,'option_image_url':opt_url,'source_sheet':'规格明细','source_row':row}; rh=sha(canon(src).encode())
            con.execute("insert into source_variants (source_batch_id,variant_identity_key,product_id,variation_name,option_index,option_name,option_image_url,option_image_url_normalized,platform_variant_id,variant_sku,internal_identity,raw_record_json,source_record_hash,source_row,status) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
              (batch,vk,pid,vname,str(idx),oname,opt_url,opt_url,None,None,1,canon(src),rh,row,'ACTIVE'))
            con.execute("insert into source_variant_options (source_batch_id,variant_identity_key,product_id,dimension_name,option_index,raw_value,normalized_value,source_record_hash,source_row) values(?,?,?,?,?,?,?,?,?)",(batch,vk,pid,vname,str(idx),oname,oname,rh,row))
            for field_name,val,col in [('variation_name',vname,'C'),('option_name',oname,'E'),('option_image_url',opt_url,'F')]:
                if val in (None,''): continue
                fid=hkey('fld',batch,pid,vk,field_name)
                con.execute("insert into source_fields (source_batch_id,field_id,product_id,variant_scope_key,field_name,raw_value,normalized_value,authority_type,volatile_business_field,status) values(?,?,?,?,?,?,?,?,?,?)",(batch,fid,pid,vk,field_name,str(val),str(val),'PLATFORM_RAW_STRUCTURED',0,'ACTIVE'))
                con.execute("insert into source_field_provenance (source_batch_id,field_id,source_file_sha256,sheet_name,source_row,source_column,source_record_hash,source_image_sha256,created_at,superseded_by,status) values(?,?,?,?,?,?,?,?,?,?,?)",(batch,fid,EXPECTED_WORKBOOK_SHA,'规格明细',row,col,rh,None,'2026-08-18T00:00:00Z',None,'ACTIVE'))
            if opt_url:
                k=(pid,opt_url); ik=variant_image_key_by_product_url.get(k)
                if ik is None:
                    ik=hkey('img_v',pid,opt_url); variant_image_key_by_product_url[k]=ik; isrc={'product_id':pid,'url':opt_url,'source_sheet':'规格明细','source_row':row,'source_kind':'VARIANT_OPTION_IMAGE'}; irh=sha(canon(isrc).encode())
                    con.execute("insert into source_images (source_batch_id,image_identity_key,product_id,image_position,image_sequence,original_source_url,normalized_source_url,reconciled_source_id,reconciled_source_sequence,source_sha256,raw_record_json,source_record_hash,source_row,scope_semantics,scope_status) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                      (batch,ik,pid,'VARIANT_OPTION_IMAGE',None,opt_url,opt_url,None,None,None,canon(isrc),irh,row,'VARIANT_OPTION_SOURCE','SPECIFIC_VARIANT'))
                bid=hkey('bind',batch,vk,ik)
                con.execute("insert into source_variant_image_bindings (source_batch_id,binding_id,product_id,image_identity_key,variant_identity_key,binding_type,normalized_source_url,status) values(?,?,?,?,?,?,?,?)",(batch,bid,pid,ik,vk,'EXACT_PLATFORM_VARIANT_OPTION_URL',opt_url,'ACTIVE'))
    if missing_gallery: raise RuntimeError(f'GALLERY_C1_EXACT_RECONCILIATION_MISSING:{len(missing_gallery)}')
    integ=store.integrity()
    if integ['integrity_check']!='ok' or integ['foreign_key_errors']!=0: raise RuntimeError(f'SQLITE_INTEGRITY_FAILED:{integ}')
    report={
      'schema_version':'tinysnow.c53-recovery-report.2','status':'PASS','source_file_sha256':EXPECTED_WORKBOOK_SHA,'source_batch_id':batch,
      'counts':{'products':375,'gallery_images':2394,'variant_options':2673,'c1_source_evidence':len(evidence),'gallery_exact_product_url_matches':gallery_exact,'gallery_sha_attached':gallery_sha,'variant_option_image_nonblank':2528,'variant_option_image_blank':145,'variant_unique_source_images':len(variant_image_key_by_product_url),'variant_exact_bindings':2528,'canonical_source_images_total':2394+len(variant_image_key_by_product_url)},
      'sqlite_integrity':integ,'source_truth_rules':{'gallery_c1_exact_product_url_only':True,'gallery_not_common_to_all_variants':True,'variant_option_url_is_platform_structured_authority':True,'variant_option_images_are_specific_variant_scope':True,'unknown_not_guessed':True,'source_truth_memory_separate':True},
      'paid_api_called':False,'image_generation_called':False,'tiny_snow_api_called':False,'stable_mutation':False,'sealed_stage_rerun':False}
    (outdir/'recovery_report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2,sort_keys=True)+'\n',encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,sort_keys=True))
    return report

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--transport-dir',required=True); ap.add_argument('--source-evidence',required=True); ap.add_argument('--output-dir',required=True); args=ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='tinysnow-c53-manifest-') as td:
        tmeta,d=extract_transport(args.transport_dir,td); m,p,i,v=verify_manifest(tmeta,d); bootstrap(m,p,i,v,args.source_evidence,args.output_dir)
if __name__=='__main__': raise SystemExit(main())
