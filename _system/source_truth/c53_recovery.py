#!/usr/bin/env python3
from __future__ import annotations
import argparse, base64, hashlib, json, pathlib, sqlite3, sys, tarfile, tempfile
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "_system" / "source_truth"))
from source_truth_store import SourceTruthStore  # noqa: E402

EXPECTED_WORKBOOK_SHA = "616d1c0639f34433ebe244678f101458e375c1c095677be7d9f5736b2ccecb9a"
EXPECTED = {"products": 375, "gallery_images": 2394, "variant_options": 2673}

def canon(x):
    return json.dumps(x, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

def sha_bytes(b):
    return hashlib.sha256(b).hexdigest()

def extract_transport(transport_dir, dest_dir):
    tdir=pathlib.Path(transport_dir)
    meta=json.loads((tdir/"transport.meta.json").read_text(encoding="utf-8"))
    if meta.get("schema_version")!="tinysnow.c53-manifest-transport.1": raise RuntimeError("TRANSPORT_SCHEMA_VERSION_UNEXPECTED")
    if meta.get("contained_manifest_source_file_sha256")!=EXPECTED_WORKBOOK_SHA: raise RuntimeError("TRANSPORT_AUTHORITY_SHA_MISMATCH")
    pieces=[]
    for spec in meta.get("parts",[]):
        p=tdir/spec["name"]; b=p.read_bytes()
        if len(b)!=spec["chars"] or sha_bytes(b)!=spec["sha256"]: raise RuntimeError(f"TRANSPORT_PART_INTEGRITY_MISMATCH:{spec['name']}")
        pieces.append(b)
    b64=b"".join(pieces)
    if len(b64)!=meta["base64_chars"] or sha_bytes(b64)!=meta["base64_sha256"]: raise RuntimeError("TRANSPORT_BASE64_INTEGRITY_MISMATCH")
    try: payload=base64.b64decode(b64,validate=True)
    except Exception as e: raise RuntimeError(f"TRANSPORT_BASE64_DECODE_FAILED:{type(e).__name__}")
    if len(payload)!=meta["transport_bytes"] or sha_bytes(payload)!=meta["transport_sha256"]: raise RuntimeError("TRANSPORT_PAYLOAD_INTEGRITY_MISMATCH")
    out=pathlib.Path(dest_dir); out.mkdir(parents=True,exist_ok=True); archive=out/"manifest.tar.gz"; archive.write_bytes(payload)
    with tarfile.open(archive,"r:gz") as tf:
        allowed={"manifest.meta.json","products.jsonl.gz","gallery_images.jsonl.gz","variant_options.jsonl.gz"}; names=set(tf.getnames())
        if names!=allowed: raise RuntimeError(f"TRANSPORT_MEMBER_SET_MISMATCH:{sorted(names)}")
        for member in tf.getmembers():
            if member.name not in allowed or not member.isfile(): raise RuntimeError("TRANSPORT_MEMBER_UNSAFE")
        tf.extractall(out,filter="data")
    archive.unlink(); return out

def read_jsonl(path):
    rows=[]
    with pathlib.Path(path).open("r", encoding="utf-8-sig") as f:
        for n,line in enumerate(f,1):
            if line.strip():
                try: rows.append(json.loads(line))
                except Exception as e: raise RuntimeError(f"BAD_JSONL:{path}:{n}:{type(e).__name__}")
    return rows

def record_hash(obj): return hashlib.sha256(canon(obj).encode("utf-8")).hexdigest()

def verify_manifest(d):
    import gzip
    d=pathlib.Path(d); meta=json.loads((d/"manifest.meta.json").read_text(encoding="utf-8"))
    if meta.get("schema_version")!="tinysnow.c53-source-manifest.2": raise RuntimeError("MANIFEST_SCHEMA_VERSION_UNEXPECTED")
    if meta.get("transport_encoding")!="gzip+jsonl-array": raise RuntimeError("MANIFEST_TRANSPORT_ENCODING_UNEXPECTED")
    if meta.get("source_file_sha256") != EXPECTED_WORKBOOK_SHA: raise RuntimeError("AUTHORITATIVE_WORKBOOK_SHA_MISMATCH")
    if meta.get("row_counts") != EXPECTED: raise RuntimeError(f"MANIFEST_META_COUNT_MISMATCH:{meta.get('row_counts')}")
    forbidden=("sales","traffic","description","category","订单","流量","销售")
    if any(x in canon(meta).lower() for x in forbidden): raise RuntimeError("SANITIZATION_GUARD_FAILED_META")
    raw_arrays={}
    for key in ("products","gallery_images","variant_options"):
        spec=meta["manifest_files"][key]; gzpath=d/spec["path"]; gzbytes=gzpath.read_bytes()
        if sha_bytes(gzbytes)!=spec["compressed_sha256"] or len(gzbytes)!=spec["compressed_bytes"]: raise RuntimeError(f"MANIFEST_COMPRESSED_INTEGRITY_MISMATCH:{key}")
        plain=gzip.decompress(gzbytes)
        if sha_bytes(plain)!=spec["uncompressed_sha256"] or len(plain)!=spec["uncompressed_bytes"]: raise RuntimeError(f"MANIFEST_UNCOMPRESSED_INTEGRITY_MISMATCH:{key}")
        arrays=[]
        for n,line in enumerate(plain.decode("utf-8-sig").splitlines(),1):
            if line.strip():
                row=json.loads(line)
                if not isinstance(row,list) or len(row)!=len(meta["schemas"][key]): raise RuntimeError(f"MANIFEST_ARRAY_SCHEMA_MISMATCH:{key}:{n}")
                arrays.append(row)
        if len(arrays)!=EXPECTED[key]: raise RuntimeError(f"MANIFEST_ROW_COUNT_MISMATCH:{key}:{len(arrays)}")
        raw_arrays[key]=arrays
    products=[]
    for a in raw_arrays["products"]:
        pid,row,title_sha,vc,ic,rh=a
        rec={"product_id":str(pid),"source_sheet":"商品总表","source_row":int(row),"title_sha256":str(title_sha),"variant_count":int(vc),"gallery_image_count":int(ic),"status":"ACTIVE"}
        if record_hash(rec)!=rh: raise RuntimeError(f"PRODUCT_RECORD_HASH_MISMATCH:{pid}:{row}")
        rec["source_record_hash"]=rh; products.append(rec)
    images=[]
    for a in raw_arrays["gallery_images"]:
        pid,pos,seq,url,row,ik,rh=a
        rec={"product_id":str(pid),"image_position":str(pos),"image_sequence":int(seq),"original_source_url":str(url),"normalized_source_url":str(url),"source_sheet":"图片明细","source_row":int(row),"status":"ACTIVE","scope_semantics":"GALLERY_UNSCOPED","scope_status":"VARIANT_MAPPING_UNKNOWN"}
        if "img_"+hashlib.sha256(f"{pid}\0{url}\0{seq}".encode()).hexdigest()[:24] != ik: raise RuntimeError(f"IMAGE_IDENTITY_KEY_MISMATCH:{pid}:{row}")
        if record_hash(rec)!=rh: raise RuntimeError(f"IMAGE_RECORD_HASH_MISMATCH:{pid}:{row}")
        rec["image_identity_key"]=ik; rec["source_record_hash"]=rh; images.append(rec)
    variants=[]
    for a in raw_arrays["variant_options"]:
        pid,vname,idx,oname,url,row,vk,rh=a
        rec={"product_id":str(pid),"variation_name":str(vname),"option_index":int(idx),"option_name":str(oname),"option_image_url":url if url not in ("",None) else None,"option_image_url_normalized":url if url not in ("",None) else None,"source_sheet":"规格明细","source_row":int(row),"status":"ACTIVE"}
        expvk="var_"+hashlib.sha256(f"{pid}\0{vname}\0{idx}\0{oname}".encode()).hexdigest()[:24]
        if expvk!=vk: raise RuntimeError(f"VARIANT_IDENTITY_KEY_MISMATCH:{pid}:{row}")
        if record_hash(rec)!=rh: raise RuntimeError(f"VARIANT_RECORD_HASH_MISMATCH:{pid}:{row}")
        rec["variant_identity_key"]=vk; rec["source_record_hash"]=rh; variants.append(rec)
    files={"products":products,"gallery_images":images,"variant_options":variants}; pids={x["product_id"] for x in products}
    if len(pids)!=EXPECTED["products"]: raise RuntimeError("PRODUCT_ID_UNIQUENESS_MISMATCH")
    if {x["product_id"] for x in images} != pids: raise RuntimeError("GALLERY_PRODUCT_SET_MISMATCH")
    if {x["product_id"] for x in variants} != pids: raise RuntimeError("VARIANT_PRODUCT_SET_MISMATCH")
    return meta,files

def read_evidence(path):
    rows=read_jsonl(path)
    if len(rows)!=EXPECTED["gallery_images"]: raise RuntimeError(f"C1_SOURCE_EVIDENCE_COUNT_MISMATCH:{len(rows)}")
    by_key={}; conflict=[]
    for r in rows:
        k=(str(r.get("product_id","")).strip(), str(r.get("url","")).strip())
        if not all(k): raise RuntimeError("C1_EVIDENCE_ID_OR_URL_MISSING")
        if k in by_key and canon(by_key[k]) != canon(r): conflict.append(k)
        else: by_key[k]=r
        if r.get("paid_api_called") is not False or r.get("image_generation_called") is not False or r.get("tiny_snow_api_called") is not False: raise RuntimeError("C1_FORBIDDEN_CALL_FLAG_NOT_FALSE")
    if conflict: raise RuntimeError(f"C1_EXACT_KEY_CONFLICT:{len(conflict)}")
    return rows,by_key

def bootstrap(meta, files, evidence_path, outdir):
    outdir=pathlib.Path(outdir); outdir.mkdir(parents=True, exist_ok=True); db=outdir/"source_truth.sqlite"
    if db.exists(): db.unlink()
    evidence,evidence_by_key=read_evidence(evidence_path); store=SourceTruthStore(db); batch=meta["source_batch_id"]
    images_by_product_url={}; exact_matches=0; sha_attached=0; missing_exact=[]; duplicate_exact=[]
    with store.writer() as con:
        con.execute("""insert into source_batches (source_batch_id,platform,source_type,original_filename,source_file_sha256,file_size,imported_at,export_timestamp,sheet_inventory_json,row_counts_json,schema_fingerprint,parser_version,capture_status,raw_snapshot_sha256) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",(batch,meta["platform"],meta["source_type"],meta["source_workbook_basename"],meta["source_file_sha256"],meta["source_file_size"],"2026-08-18T00:00:00Z",None,canon(meta["sheet_inventory"]),canon(meta["row_counts"]),sha_bytes(canon(meta["sheet_inventory"]).encode()),"c53-recovery-1","CAPTURED_SANITIZED_MANIFEST",sha_bytes(canon(meta["manifest_files"]).encode())))
        for p in files["products"]:
            pid=p["product_id"]
            con.execute("""insert into source_products (source_batch_id,product_id,parent_sku,original_product_name,original_category,original_description,product_has_variants,variant_count,image_count,raw_record_json,source_record_hash,source_row,status) values(?,?,?,?,?,?,?,?,?,?,?,?,?)""",(batch,pid,None,None,None,None,1,int(p["variant_count"]),int(p["gallery_image_count"]),canon(p),p["source_record_hash"],int(p["source_row"]),"ACTIVE"))
            field_id="fld_"+hashlib.sha256(f"{batch}\0{pid}\0product_id".encode()).hexdigest()[:24]
            con.execute("insert into source_fields (source_batch_id,field_id,product_id,variant_scope_key,field_name,raw_value,normalized_value,authority_type,volatile_business_field,status) values(?,?,?,?,?,?,?,?,?,?)",(batch,field_id,pid,"PRODUCT","product_id",pid,pid,"PLATFORM_RAW_STRUCTURED",0,"ACTIVE"))
            con.execute("insert into source_field_provenance (source_batch_id,field_id,source_file_sha256,sheet_name,source_row,source_column,source_record_hash,source_image_sha256,created_at,superseded_by,status) values(?,?,?,?,?,?,?,?,?,?,?)",(batch,field_id,meta["source_file_sha256"],p["source_sheet"],int(p["source_row"]),"A",p["source_record_hash"],None,"2026-08-18T00:00:00Z",None,"ACTIVE"))
        for v in files["variant_options"]:
            pid=v["product_id"]; vk=v["variant_identity_key"]
            con.execute("insert into source_variants (source_batch_id,variant_identity_key,product_id,variation_name,option_index,option_name,option_image_url,option_image_url_normalized,platform_variant_id,variant_sku,internal_identity,raw_record_json,source_record_hash,source_row,status) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",(batch,vk,pid,v.get("variation_name"),str(v.get("option_index")),v.get("option_name"),v.get("option_image_url"),v.get("option_image_url_normalized"),None,None,1,canon(v),v["source_record_hash"],int(v["source_row"]),"ACTIVE"))
            con.execute("insert into source_variant_options (source_batch_id,variant_identity_key,product_id,dimension_name,option_index,raw_value,normalized_value,source_record_hash,source_row) values(?,?,?,?,?,?,?,?,?)",(batch,vk,pid,v.get("variation_name"),str(v.get("option_index")),v.get("option_name"),v.get("option_name"),v["source_record_hash"],int(v["source_row"])))
            for field_name,raw_value,column in [("variation_name",v.get("variation_name"),"C"),("option_name",v.get("option_name"),"E"),("option_image_url",v.get("option_image_url"),"F")]:
                if raw_value in (None,""): continue
                field_id="fld_"+hashlib.sha256(f"{batch}\0{pid}\0{vk}\0{field_name}".encode()).hexdigest()[:24]
                con.execute("insert into source_fields (source_batch_id,field_id,product_id,variant_scope_key,field_name,raw_value,normalized_value,authority_type,volatile_business_field,status) values(?,?,?,?,?,?,?,?,?,?)",(batch,field_id,pid,vk,field_name,str(raw_value),str(raw_value),"PLATFORM_RAW_STRUCTURED",0,"ACTIVE"))
                con.execute("insert into source_field_provenance (source_batch_id,field_id,source_file_sha256,sheet_name,source_row,source_column,source_record_hash,source_image_sha256,created_at,superseded_by,status) values(?,?,?,?,?,?,?,?,?,?,?)",(batch,field_id,meta["source_file_sha256"],v["source_sheet"],int(v["source_row"]),column,v["source_record_hash"],None,"2026-08-18T00:00:00Z",None,"ACTIVE"))
        for im in files["gallery_images"]:
            pid=im["product_id"]; url=im["normalized_source_url"]; key=(pid,url); ev=evidence_by_key.get(key)
            if ev is None: missing_exact.append(key); source_id=None; seq=None; source_sha=None
            else:
                exact_matches+=1; source_id=ev.get("source_id"); seq=ev.get("sequence"); source_sha=ev.get("sha256")
                if source_sha: sha_attached+=1
            ik=im["image_identity_key"]
            if key in images_by_product_url: duplicate_exact.append(key)
            images_by_product_url[key]=ik
            con.execute("insert into source_images (source_batch_id,image_identity_key,product_id,image_position,image_sequence,original_source_url,normalized_source_url,reconciled_source_id,reconciled_source_sequence,source_sha256,raw_record_json,source_record_hash,source_row,scope_semantics,scope_status) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",(batch,ik,pid,im.get("image_position"),str(im.get("image_sequence")),im["original_source_url"],url,source_id,int(seq) if seq is not None else None,source_sha,canon(im),im["source_record_hash"],int(im["source_row"]),im.get("scope_semantics","GALLERY_UNSCOPED"),im.get("scope_status","VARIANT_MAPPING_UNKNOWN")))
        binding_count=0; unresolved_option_images=0; blank_option_images=0
        for v in files["variant_options"]:
            u=v.get("option_image_url_normalized")
            if not u: blank_option_images += 1; continue
            key=(v["product_id"],u); ik=images_by_product_url.get(key)
            if not ik: unresolved_option_images += 1; continue
            bid="bind_"+hashlib.sha256(f"{batch}\0{v['variant_identity_key']}\0{ik}".encode()).hexdigest()[:24]
            con.execute("insert into source_variant_image_bindings (source_batch_id,binding_id,product_id,image_identity_key,variant_identity_key,binding_type,normalized_source_url,status) values(?,?,?,?,?,?,?,?)",(batch,bid,v["product_id"],ik,v["variant_identity_key"],"EXACT_PLATFORM_URL",u,"ACTIVE")); binding_count += 1
    if missing_exact: raise RuntimeError(f"GALLERY_C1_EXACT_RECONCILIATION_MISSING:{len(missing_exact)}")
    if duplicate_exact: raise RuntimeError(f"GALLERY_MANIFEST_PRODUCT_URL_DUPLICATE:{len(duplicate_exact)}")
    integ=store.integrity()
    if integ["integrity_check"]!="ok" or integ["foreign_key_errors"]!=0: raise RuntimeError(f"SQLITE_INTEGRITY_FAILED:{integ}")
    report={"schema_version":"tinysnow.c53-recovery-report.1","status":"PASS","source_file_sha256":meta["source_file_sha256"],"source_batch_id":batch,"counts":{"products":len(files["products"]),"gallery_images":len(files["gallery_images"]),"variant_options":len(files["variant_options"]),"c1_source_evidence":len(evidence),"gallery_exact_product_url_matches":exact_matches,"gallery_sha_attached":sha_attached,"variant_exact_gallery_bindings":binding_count,"variant_option_image_missing_in_gallery":unresolved_option_images,"variant_option_image_blank":blank_option_images},"sqlite_integrity":integ,"source_truth_rules":{"exact_product_url_only":True,"gallery_not_common_to_all_variants":True,"unknown_not_guessed":True,"source_truth_memory_separate":True},"paid_api_called":False,"image_generation_called":False,"tiny_snow_api_called":False,"stable_mutation":False,"sealed_stage_rerun":False}
    (outdir/"recovery_report.json").write_text(json.dumps(report,ensure_ascii=False,indent=2,sort_keys=True)+"\n",encoding="utf-8"); print(json.dumps(report,ensure_ascii=False,sort_keys=True)); return report

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--transport-dir", required=True); ap.add_argument("--source-evidence", required=True); ap.add_argument("--output-dir", required=True); args=ap.parse_args()
    with tempfile.TemporaryDirectory(prefix="tinysnow-c53-manifest-") as td:
        manifest_dir=extract_transport(args.transport_dir,td); meta,files=verify_manifest(manifest_dir); bootstrap(meta,files,args.source_evidence,args.output_dir)

if __name__=="__main__": raise SystemExit(main())
