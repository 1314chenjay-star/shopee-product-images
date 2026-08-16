#!/usr/bin/env python3
import argparse, json
from collections import Counter, defaultdict
from pathlib import Path

SCHEMA = "v4c3.factual-gate.1"
EXPECTED_TOTAL = 1378
EXPECTED_PARTIAL = 1046
EXPECTED_PRESERVE = 280
EXPECTED_HOLD = 39
EXPECTED_BLOCK = 13
ALLOWED_INPUT = {"PARTIAL_SAFE"}
ELIGIBILITY = {"ELIGIBLE_SAFE","ELIGIBLE_PARTIAL","HOLD_FACTUAL","BLOCK_FACTUAL"}

HIGH_RISK_TOKENS = {
    "brand","material","size","dimension","dimensions","weight","accessory","accessories",
    "bundle_count","quantity","count","function","feature","certification","certificate",
    "waterproof","water_resistant","water-resistance","abrasion","medical","safety",
    "performance","load_rating","resistance","capacity","warranty","gift","ingredient",
    "材質","材料","尺寸","規格","品牌","配件","附件","數量","功能","認證","防水","耐磨",
    "醫療","安全","性能","承重","重量","容量","保固","贈品"
}
VARIANT_KEYS = (
    "variant_id","variation_id","variant","variant_name","variant_value",
    "option_id","option_name","option_value","sku","model_id"
)

def read_jsonl(path):
    p=Path(path)
    if not p.exists():
        raise RuntimeError(f"Missing required input: {path}")
    rows=[]
    with p.open(encoding="utf-8-sig") as f:
        for i,line in enumerate(f,1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except Exception as e:
                raise RuntimeError(f"Invalid JSONL {path}:{i}: {e}")
    return rows

def write_jsonl(path, rows):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open("w",encoding="utf-8",newline="\n") as f:
        for r in rows:
            f.write(json.dumps(r,ensure_ascii=False,separators=(",",":"))+"\n")

def write_json(path,obj):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding="utf-8")

def claim_id(c):
    cid=str(c.get("claim_id") or "").strip()
    if cid:
        return cid
    payload=json.dumps({"type":c.get("type"),"value":c.get("value"),"status":c.get("status"),"origin":c.get("origin"),"evidence":c.get("evidence")},ensure_ascii=False,sort_keys=True,separators=(",",":"))
    import hashlib
    return "derived-"+hashlib.sha256(payload.encode("utf-8")).hexdigest()[:20]

def norm_type(c):
    return str(c.get("type") or "unknown").strip().lower()

def norm_value(c):
    v=c.get("value")
    if isinstance(v,(dict,list)):
        return json.dumps(v,ensure_ascii=False,sort_keys=True,separators=(",",":"))
    return str(v if v is not None else "").strip()

def is_high_risk(c):
    t=norm_type(c); v=norm_value(c).lower(); origin=str(c.get("origin") or "").lower()
    hay=f"{t}|{origin}|{v}"
    if t=="risk_field" or t.startswith("risk_"):
        return True
    return any(tok in hay for tok in HIGH_RISK_TOKENS)

def _collect_variant(obj, out):
    if not isinstance(obj,dict):
        return
    for k in VARIANT_KEYS:
        v=obj.get(k)
        if v in (None,"",[],{}):
            continue
        if isinstance(v,list):
            for x in v:
                if x not in (None,""):
                    out.add(f"{k}:{x}")
        else:
            out.add(f"{k}:{v}")

def variant_scope(c):
    out=set(); _collect_variant(c,out)
    for e in c.get("evidence") or []:
        _collect_variant(e,out)
        if isinstance(e,dict):
            _collect_variant(e.get("metadata"),out); _collect_variant(e.get("source"),out)
    return sorted(out)

def evidence_present(c):
    ev=c.get("evidence")
    return isinstance(ev,list) and any(bool(x) for x in ev)

def base_fact(c, classification, reason):
    return {"fact_id":claim_id(c),"classification":classification,"claim_type":str(c.get("type") or "unknown"),"value":c.get("value"),"origin":c.get("origin"),"source_status":c.get("status"),"allowed_usage":c.get("allowed_usage"),"variant_scope":variant_scope(c),"evidence":c.get("evidence") or [],"reason":reason}

def classify_claim(c, bucket):
    status=str(c.get("status") or ""); usage=str(c.get("allowed_usage") or "")
    if status in {"CONFLICT","FACT_CONFLICT"}:
        return base_fact(c,"FACT_CONFLICT","EXPLICIT_CONFLICT_IN_DURABLE_EVIDENCE")
    if bucket=="verified":
        if status!="VERIFIED_SOURCE":
            return base_fact(c,"FACT_FORBIDDEN","NOT_VERIFIED_SOURCE")
        if usage in {"","NONE"}:
            return base_fact(c,"FACT_FORBIDDEN","VERIFIED_SOURCE_NOT_ALLOWED_FOR_USAGE")
        if not evidence_present(c):
            return base_fact(c,"FACT_FORBIDDEN","VERIFIED_SOURCE_WITHOUT_DURABLE_EVIDENCE")
        return base_fact(c,"FACT_VERIFIED","EXISTING_VERIFIED_SOURCE_EVIDENCE")
    if status=="VERIFIED_SOURCE" and usage not in {"","NONE"} and evidence_present(c):
        return base_fact(c,"FACT_CONFLICT","CLAIM_BUCKET_STATUS_CONFLICT")
    if usage!="NONE":
        return base_fact(c,"FACT_CONFLICT","UNKNOWN_ALLOWED_USAGE_VIOLATION")
    if is_high_risk(c):
        return base_fact(c,"FACT_FORBIDDEN","HIGH_RISK_CLAIM_WITHOUT_VERIFIED_SOURCE")
    return base_fact(c,"FACT_UNKNOWN","UNKNOWN_ALLOWED_USAGE_NONE")

def fact_key(f):
    return (str(f.get("claim_type") or "").lower(), tuple(f.get("variant_scope") or []))

def detect_verified_conflicts(facts):
    verified=[f for f in facts if f["classification"]=="FACT_VERIFIED"]
    by_scope=defaultdict(list)
    for f in verified:
        by_scope[fact_key(f)].append(f)
    conflict_ids=set(); variant_conflict_ids=set()
    for items in by_scope.values():
        vals={json.dumps(x.get("value"),ensure_ascii=False,sort_keys=True) for x in items}
        if len(vals)>1:
            for x in items:
                conflict_ids.add(x["fact_id"])
    by_type=defaultdict(list)
    for f in verified:
        by_type[str(f.get("claim_type") or "").lower()].append(f)
    for items in by_type.values():
        scoped=[x for x in items if x.get("variant_scope")]; unscoped=[x for x in items if not x.get("variant_scope")]
        if not scoped or not unscoped:
            continue
        scoped_vals={json.dumps(x.get("value"),ensure_ascii=False,sort_keys=True) for x in scoped}
        for u in unscoped:
            uv=json.dumps(u.get("value"),ensure_ascii=False,sort_keys=True)
            if any(sv!=uv for sv in scoped_vals):
                conflict_ids.add(u["fact_id"]); variant_conflict_ids.add(u["fact_id"])
    for f in facts:
        if f["fact_id"] in conflict_ids and f["classification"]=="FACT_VERIFIED":
            f["classification"]="FACT_CONFLICT"
            f["reason"]="VARIANT_SCOPE_CONFLICT_UNSCOPED_FACT" if f["fact_id"] in variant_conflict_ids else "CONFLICTING_VERIFIED_VALUES_SAME_SCOPE"
    return len(variant_conflict_ids)

def exact_text(f):
    val=f.get("value")
    if isinstance(val,(dict,list)):
        val=json.dumps(val,ensure_ascii=False,sort_keys=True,separators=(",",":"))
    else:
        val=str(val if val is not None else "")
    scope=f.get("variant_scope") or []; scope_txt=(" ["+";".join(scope)+"]") if scope else ""
    return f"{f.get('claim_type','unknown')}{scope_txt}: {val}"

def zero_flags():
    return {"source_download_called":False,"artifact_download_called":False,"ocr_executed":False,"semantic_inference_executed":False,"preservation_reexecuted":False,"image_generation_called":False,"tiny_snow_api_called":False,"vision_api_called":False,"paid_api_called":False,"v4c1_retested":False,"v4c2_retested":False}

def gate_image(rec):
    if rec.get("final_status")!="PARTIAL_SAFE":
        raise RuntimeError(f"Non-PARTIAL_SAFE entered V4-C3: seq {rec.get('sequence')}")
    seen=set(); facts=[]
    for bucket,key in (("verified","verified_claims"),("unknown","unknown_claims")):
        for c in rec.get(key) or []:
            sig=(claim_id(c),bucket,json.dumps(c,ensure_ascii=False,sort_keys=True,separators=(",",":")))
            if sig in seen:
                continue
            seen.add(sig); facts.append(classify_claim(c,bucket))
    variant_conflicts=detect_verified_conflicts(facts)
    verified=[x for x in facts if x["classification"]=="FACT_VERIFIED"]
    unknown=[x for x in facts if x["classification"]=="FACT_UNKNOWN"]
    conflicts=[x for x in facts if x["classification"]=="FACT_CONFLICT"]
    forbidden=[x for x in facts if x["classification"]=="FACT_FORBIDDEN"]
    if conflicts:
        eligibility="BLOCK_FACTUAL"
    elif not verified:
        eligibility="HOLD_FACTUAL"
    elif unknown or forbidden:
        eligibility="ELIGIBLE_PARTIAL"
    else:
        eligibility="ELIGIBLE_SAFE"
    return {"schema_version":SCHEMA,"sequence":int(rec["sequence"]),"product_id":str(rec.get("product_id") or ""),"sha256":str(rec.get("sha256") or ""),"source_final_status":"PARTIAL_SAFE","evidence_source":rec.get("evidence_source"),"verified_facts":verified,"unknown_facts":unknown,"conflict_facts":conflicts,"forbidden_facts":forbidden,"generation_safe_text":[exact_text(x) for x in verified],"generation_forbidden_text":[exact_text(x) for x in unknown+conflicts+forbidden],"generation_safe_fact_ids":[x["fact_id"] for x in verified],"generation_eligibility":eligibility,"variant_conflicts":variant_conflicts,"downstream_generation_allowed":eligibility in {"ELIGIBLE_SAFE","ELIGIBLE_PARTIAL"},"api_flags":zero_flags()}

def plan(a):
    rows=read_jsonl(a.canonical)
    if len(rows)!=EXPECTED_TOTAL:
        raise RuntimeError(f"Expected canonical {EXPECTED_TOTAL}, got {len(rows)}")
    counts=Counter(str(r.get("final_status")) for r in rows)
    expected={"PRESERVE":EXPECTED_PRESERVE,"PARTIAL_SAFE":EXPECTED_PARTIAL,"HOLD_FINAL":EXPECTED_HOLD,"BLOCK_FINAL":EXPECTED_BLOCK}
    if dict(counts)!=expected:
        raise RuntimeError(f"Canonical frozen counts changed: {dict(counts)}")
    targets=sorted([r for r in rows if r.get("final_status")=="PARTIAL_SAFE"],key=lambda x:int(x["sequence"]))
    if len(targets)!=EXPECTED_PARTIAL:
        raise RuntimeError("PARTIAL_SAFE target mismatch")
    if any((r.get("downstream_eligibility") or {}).get("downstream_generation_allowed") is not True for r in targets):
        raise RuntimeError("Canonical PARTIAL_SAFE downstream eligibility changed")
    canary=targets[:a.canary_size]; remaining=targets[a.canary_size:]
    write_jsonl(a.target_out,targets); write_jsonl(a.canary_out,canary); write_jsonl(a.remaining_out,remaining)
    write_json(a.summary,{"schema_version":"v4c3.factual-gate-plan.1","passed":True,"canonical_total":len(rows),"canonical_counts":dict(counts),"input_partial_safe":len(targets),"canary_count":len(canary),"remaining_after_canary":len(remaining),"excluded_preserve":counts["PRESERVE"],"excluded_hold_final":counts["HOLD_FINAL"],"excluded_block_final":counts["BLOCK_FINAL"],"api_flags":zero_flags()})
    print(f"INPUT_PARTIAL_SAFE={len(targets)}"); print(f"CANARY={len(canary)}"); print(f"REMAINING={len(remaining)}")

def process(a):
    manifest=read_jsonl(a.manifest)
    existing=read_jsonl(a.progress) if Path(a.progress).exists() else []
    byseq={int(r["sequence"]):r for r in existing}; before=len(byseq); processed=0
    for rec in manifest:
        seq=int(rec["sequence"])
        if seq in byseq:
            continue
        if a.max_items is not None and processed>=a.max_items:
            break
        byseq[seq]=gate_image(rec); processed+=1
    ordered=[byseq[k] for k in sorted(byseq)]; write_jsonl(a.progress,ordered)
    covered=sum(1 for r in manifest if int(r["sequence"]) in byseq)
    s={"schema_version":"v4c3.factual-gate-process.1","manifest_count":len(manifest),"checkpoint_existing_terminal":before,"processed_this_run":processed,"covered_after_run":covered}
    write_json(a.summary,s); print(json.dumps(s,sort_keys=True))

def validate_rows(rows):
    for r in rows:
        if r.get("source_final_status")!="PARTIAL_SAFE":
            raise RuntimeError(f"Non-PARTIAL_SAFE output seq {r.get('sequence')}")
        if r.get("generation_eligibility") not in ELIGIBILITY:
            raise RuntimeError(f"Bad eligibility seq {r.get('sequence')}")
        verified=r.get("verified_facts") or []; unknown=r.get("unknown_facts") or []; conflicts=r.get("conflict_facts") or []; forbidden=r.get("forbidden_facts") or []
        safeids=set(r.get("generation_safe_fact_ids") or [])
        if safeids!={x.get("fact_id") for x in verified}:
            raise RuntimeError(f"Safe fact id mismatch seq {r.get('sequence')}")
        if len(r.get("generation_safe_text") or [])!=len(verified):
            raise RuntimeError(f"Safe text not derived only from verified facts seq {r.get('sequence')}")
        for f in verified:
            if f.get("source_status")!="VERIFIED_SOURCE" or f.get("allowed_usage") in {None,"","NONE"} or not f.get("evidence"):
                raise RuntimeError(f"FACT_VERIFIED without durable VERIFIED_SOURCE seq {r.get('sequence')}")
        for f in unknown:
            if f.get("allowed_usage")!="NONE":
                raise RuntimeError(f"FACT_UNKNOWN allowed_usage violation seq {r.get('sequence')}")
            if is_high_risk({"type":f.get("claim_type"),"value":f.get("value"),"origin":f.get("origin")}):
                raise RuntimeError(f"High risk claim left FACT_UNKNOWN seq {r.get('sequence')}")
        for f in forbidden:
            if f.get("reason")=="HIGH_RISK_CLAIM_WITHOUT_VERIFIED_SOURCE" and f.get("allowed_usage")!="NONE":
                raise RuntimeError(f"Forbidden high-risk usage violation seq {r.get('sequence')}")
        if conflicts and r.get("generation_eligibility")!="BLOCK_FACTUAL":
            raise RuntimeError(f"Conflict did not block seq {r.get('sequence')}")
        if not verified and r.get("generation_eligibility") not in {"HOLD_FACTUAL","BLOCK_FACTUAL"}:
            raise RuntimeError(f"No verified fact but eligible seq {r.get('sequence')}")
        flags=r.get("api_flags") or {}
        if any(flags.values()):
            raise RuntimeError(f"Forbidden API/retest flag true seq {r.get('sequence')}: {flags}")

def synthetic_policy_tests():
    ev=[{"source":"synthetic","text":"explicit"}]
    c={"claim_id":"v","type":"material","value":"cotton","status":"VERIFIED_SOURCE","allowed_usage":"FACT_EXACT_ONLY","evidence":ev}
    assert classify_claim(c,"verified")["classification"]=="FACT_VERIFIED"
    c2={"claim_id":"u","type":"title_text","value":"x","status":"UNKNOWN","allowed_usage":"NONE","evidence":[]}
    assert classify_claim(c2,"unknown")["classification"]=="FACT_UNKNOWN"
    c3={"claim_id":"h","type":"material","value":"cotton","status":"UNKNOWN","allowed_usage":"NONE","evidence":[]}
    assert classify_claim(c3,"unknown")["classification"]=="FACT_FORBIDDEN"
    a=base_fact({"claim_id":"r","type":"size","value":"M","status":"VERIFIED_SOURCE","allowed_usage":"FACT_EXACT_ONLY","evidence":[{"variant_id":"red"}]},"FACT_VERIFIED","x")
    b=base_fact({"claim_id":"b","type":"size","value":"L","status":"VERIFIED_SOURCE","allowed_usage":"FACT_EXACT_ONLY","evidence":[{"variant_id":"blue"}]},"FACT_VERIFIED","x")
    facts=[a,b]
    assert detect_verified_conflicts(facts)==0 and all(x["classification"]=="FACT_VERIFIED" for x in facts)
    u=base_fact({"claim_id":"g","type":"size","value":"XL","status":"VERIFIED_SOURCE","allowed_usage":"FACT_EXACT_ONLY","evidence":[{"source":"x"}]},"FACT_VERIFIED","x")
    facts=[a,b,u]
    assert detect_verified_conflicts(facts)==1 and u["classification"]=="FACT_CONFLICT"
    return True

def self_test(_a=None):
    synthetic_policy_tests(); print("V4_C3_SELF_TEST=PASS")

def validate_canary(a):
    manifest=read_jsonl(a.manifest); out=read_jsonl(a.evidence)
    seed=json.loads(Path(a.seed_summary).read_text(encoding="utf-8-sig")); resume=json.loads(Path(a.resume_summary).read_text(encoding="utf-8-sig"))
    if len(manifest)!=a.expected or len(out)!=a.expected:
        raise RuntimeError("Canary input/output reconciliation failed")
    if set(int(x["sequence"]) for x in manifest)!=set(int(x["sequence"]) for x in out):
        raise RuntimeError("Canary sequence reconciliation failed")
    if seed.get("covered_after_run")!=a.seed:
        raise RuntimeError("Canary seed checkpoint mismatch")
    if resume.get("checkpoint_existing_terminal")!=a.seed or resume.get("covered_after_run")!=a.expected:
        raise RuntimeError("Canary resume checkpoint mismatch")
    validate_rows(out); synthetic_policy_tests()
    write_json(a.output,{"schema_version":"v4c3.factual-gate-canary-validation.1","passed":True,"input":len(manifest),"terminal":len(out),"checkpoint_seed":a.seed,"checkpoint_resume_skipped":resume.get("checkpoint_existing_terminal"),"checkpoint_resume_processed":resume.get("processed_this_run"),"verified_source_only":True,"unknown_never_generation_safe":True,"variant_isolation":True,"high_risk_without_source_forbidden":True,"non_partial_excluded":True,"input_output_reconciliation":True,"api_flags":zero_flags()})
    print("V4_C3_CANARY=PASS")

def aggregate_product(rows):
    byprod=defaultdict(list)
    for r in rows:
        byprod[str(r.get("product_id") or "")].append(r)
    products=[]
    for pid,items in sorted(byprod.items()):
        v={};u={};c={};f={}
        for r in items:
            for dest,key in ((v,"verified_facts"),(u,"unknown_facts"),(c,"conflict_facts"),(f,"forbidden_facts")):
                for fact in r.get(key) or []:
                    stable=json.dumps({"fact_id":fact.get("fact_id"),"classification":fact.get("classification"),"claim_type":fact.get("claim_type"),"value":fact.get("value"),"variant_scope":fact.get("variant_scope")},ensure_ascii=False,sort_keys=True)
                    dest[stable]=fact
        verified=list(v.values()); unknown=list(u.values()); conflicts=list(c.values()); forbidden=list(f.values())
        product_fact_pool=[dict(x) for x in verified]
        product_variant_conflicts=detect_verified_conflicts(product_fact_pool)
        newly_conflicted=[x for x in product_fact_pool if x.get("classification")=="FACT_CONFLICT"]
        if newly_conflicted:
            bad_ids={x.get("fact_id") for x in newly_conflicted}
            verified=[x for x in verified if x.get("fact_id") not in bad_ids]
            existing_conflict_ids={x.get("fact_id") for x in conflicts}
            conflicts.extend(x for x in newly_conflicted if x.get("fact_id") not in existing_conflict_ids)
        if conflicts or any(x.get("generation_eligibility")=="BLOCK_FACTUAL" for x in items):
            elig="BLOCK_FACTUAL"
        elif not verified:
            elig="HOLD_FACTUAL"
        elif all(x.get("generation_eligibility")=="ELIGIBLE_SAFE" for x in items):
            elig="ELIGIBLE_SAFE"
        else:
            elig="ELIGIBLE_PARTIAL"
        products.append({"schema_version":"v4c3.factual-gate-product.1","product_id":pid,"sequences":[int(x["sequence"]) for x in sorted(items,key=lambda z:int(z["sequence"]))],"verified_facts":verified,"unknown_facts":unknown,"conflict_facts":conflicts,"forbidden_facts":forbidden,"generation_safe_text":[exact_text(x) for x in verified],"generation_forbidden_text":[exact_text(x) for x in unknown+conflicts+forbidden],"generation_eligibility":elig,"variant_conflicts":product_variant_conflicts,"downstream_generation_allowed":elig in {"ELIGIBLE_SAFE","ELIGIBLE_PARTIAL"}})
    return products

def aggregate(a):
    target=read_jsonl(a.target_manifest); canary=read_jsonl(a.canary_progress); full=read_jsonl(a.full_progress)
    rows=sorted(canary+full,key=lambda x:int(x["sequence"]))
    if len(target)!=EXPECTED_PARTIAL or len(rows)!=EXPECTED_PARTIAL:
        raise RuntimeError("Full V4-C3 reconciliation count mismatch")
    if len({int(x["sequence"]) for x in rows})!=EXPECTED_PARTIAL:
        raise RuntimeError("Duplicate/missing image output sequence")
    if {int(x["sequence"]) for x in rows}!={int(x["sequence"]) for x in target}:
        raise RuntimeError("Target/output sequence mismatch")
    validate_rows(rows); products=aggregate_product(rows)
    write_jsonl(a.image_out,rows); write_jsonl(a.product_out,products)
    product_by_id={p["product_id"]:p for p in products}
    queue=[r for r in rows if r.get("downstream_generation_allowed") and (product_by_id.get(str(r.get("product_id") or "")) or {}).get("downstream_generation_allowed")]
    write_jsonl(a.queue_out,queue)
    ec=Counter(r["generation_eligibility"] for r in rows)
    eligibility_counts={k:int(ec.get(k,0)) for k in sorted(ELIGIBILITY)}
    verified=sum(len(r.get("verified_facts") or []) for r in rows); unknown=sum(len(r.get("unknown_facts") or []) for r in rows); conflicts=sum(len(r.get("conflict_facts") or []) for r in rows); forbidden=sum(len(r.get("forbidden_facts") or []) for r in rows)
    variant_conflicts=sum(int(r.get("variant_conflicts") or 0) for r in rows)
    s={"schema_version":"v4c3.factual-gate-summary.1","passed":True,"input_partial_safe":EXPECTED_PARTIAL,"eligibility_counts":eligibility_counts,"verified_fact_count":verified,"unknown_fact_count":unknown,"conflict_fact_count":conflicts,"forbidden_fact_count":forbidden,"variant_conflicts":variant_conflicts+sum(int(p.get("variant_conflicts") or 0) for p in products),"downstream_generation_eligible_count":len(queue),"product_count":len(products),"api_flags":zero_flags()}
    write_json(a.summary,s); print(json.dumps(s,ensure_ascii=False,sort_keys=True))

def validate_final(a):
    images=read_jsonl(a.images); products=read_jsonl(a.products); queue=read_jsonl(a.queue)
    s=json.loads(Path(a.summary).read_text(encoding="utf-8-sig"))
    if len(images)!=EXPECTED_PARTIAL:
        raise RuntimeError("Final image gate count mismatch")
    validate_rows(images)
    product_by_id={p["product_id"]:p for p in products}
    expected={int(x["sequence"]) for x in images if x.get("generation_eligibility") in {"ELIGIBLE_SAFE","ELIGIBLE_PARTIAL"} and (product_by_id.get(str(x.get("product_id") or "")) or {}).get("generation_eligibility") in {"ELIGIBLE_SAFE","ELIGIBLE_PARTIAL"}}
    if len(queue)!=len(expected):
        raise RuntimeError("Generation queue reconciliation failed")
    qseq={int(x["sequence"]) for x in queue}
    if qseq!=expected:
        raise RuntimeError("Generation queue contains ineligible/missing records")
    for p in products:
        if p.get("generation_eligibility") in {"HOLD_FACTUAL","BLOCK_FACTUAL"} and p.get("downstream_generation_allowed") is not False:
            raise RuntimeError(f"Ineligible product allowed: {p.get('product_id')}")
    if any((s.get("api_flags") or {}).values()):
        raise RuntimeError("Forbidden API/retest flag true in summary")
    write_json(a.output,{"schema_version":"v4c3.factual-gate-validation.1","passed":True,"input_partial_safe":len(images),"eligibility_counts":s.get("eligibility_counts"),"verified_fact_count":s.get("verified_fact_count"),"unknown_fact_count":s.get("unknown_fact_count"),"conflict_fact_count":s.get("conflict_fact_count"),"forbidden_fact_count":s.get("forbidden_fact_count"),"variant_conflicts":s.get("variant_conflicts"),"downstream_generation_eligible_count":len(queue),"product_count":len(products),"api_flags":s.get("api_flags")})
    print("V4_C3_FINAL_VALIDATION=PASS")

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest="cmd",required=True)
    p=sub.add_parser("self-test"); p.set_defaults(fn=self_test)
    p=sub.add_parser("plan"); p.add_argument("--canonical",required=True); p.add_argument("--target-out",required=True); p.add_argument("--canary-out",required=True); p.add_argument("--remaining-out",required=True); p.add_argument("--summary",required=True); p.add_argument("--canary-size",type=int,default=120); p.set_defaults(fn=plan)
    p=sub.add_parser("process"); p.add_argument("--manifest",required=True); p.add_argument("--progress",required=True); p.add_argument("--summary",required=True); p.add_argument("--max-items",type=int); p.set_defaults(fn=process)
    p=sub.add_parser("validate-canary"); p.add_argument("--manifest",required=True); p.add_argument("--evidence",required=True); p.add_argument("--seed-summary",required=True); p.add_argument("--resume-summary",required=True); p.add_argument("--expected",type=int,default=120); p.add_argument("--seed",type=int,default=30); p.add_argument("--output",required=True); p.set_defaults(fn=validate_canary)
    p=sub.add_parser("aggregate"); p.add_argument("--target-manifest",required=True); p.add_argument("--canary-progress",required=True); p.add_argument("--full-progress",required=True); p.add_argument("--image-out",required=True); p.add_argument("--product-out",required=True); p.add_argument("--queue-out",required=True); p.add_argument("--summary",required=True); p.set_defaults(fn=aggregate)
    p=sub.add_parser("validate-final"); p.add_argument("--images",required=True); p.add_argument("--products",required=True); p.add_argument("--queue",required=True); p.add_argument("--summary",required=True); p.add_argument("--output",required=True); p.set_defaults(fn=validate_final)
    a=ap.parse_args(); a.fn(a)

if __name__=="__main__":
    main()
