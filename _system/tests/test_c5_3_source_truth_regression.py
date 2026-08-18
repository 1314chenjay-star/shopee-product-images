#!/usr/bin/env python3
from __future__ import annotations
import base64, json, lzma, pathlib, sqlite3, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SEALED_REF = "c59db"

def load(path):
    return json.loads((ROOT/path).read_text(encoding="utf-8-sig"))

def git_json(path):
    raw = subprocess.check_output(["git","show",f"{SEALED_REF}:{path}"], cwd=ROOT)
    return json.loads(raw.decode("utf-8-sig"))

def git_jsonl(path):
    raw = subprocess.check_output(["git","show",f"{SEALED_REF}:{path}"], cwd=ROOT).decode("utf-8-sig")
    return [json.loads(x) for x in raw.splitlines() if x.strip()]

def first_record_list(value):
    if isinstance(value,list) and all(isinstance(x,dict) for x in value): return value
    if isinstance(value,dict):
        for v in value.values():
            got=first_record_list(v)
            if got is not None: return got
    return None

def main():
    manifest=load("_system/source_truth/bootstrap_manifest/manifest.json")
    bootstrap=load("_system/source_truth/bootstrap_validation.json")
    recon=load("_system/source_truth/reconciliation_validation.json")
    overlay=load("_system/source_truth/ready_scope_overlay.json")

    assert manifest["authoritative_workbook"]["sha256"] == "616d1c0639f34433ebe244678f101458e375c1c095677be7d9f5736b2ccecb9a"
    assert manifest["row_counts"] == {"gallery_images":2394,"products":375,"variant_options":2673}
    assert manifest["variant_option_image"] == {"missing":145,"present":2528,"unique_urls":2515}

    assert bootstrap["status"] == "PASS"
    assert bootstrap["source_batch_sha256"] == manifest["authoritative_workbook"]["sha256"]
    assert bootstrap["counts"]["source_products"] == 375
    assert bootstrap["counts"]["source_images"] == 2394
    assert bootstrap["counts"]["source_variant_options"] == 2673
    assert bootstrap["store_integrity"] == {"foreign_key_violations":0,"sqlite_integrity":"ok"}
    assert bootstrap["variant_option_image"]["missing"] == 145
    assert bootstrap["variant_option_image"]["missing_policy"] == "HOLD"

    assert recon["status"] == "PASS"
    assert recon["expected"] == recon["observed"] == {"products":375,"gallery_images":2394,"variant_options":2673}
    assert all(recon["matches"].values())

    assert overlay["status"] == "PASS"
    assert overlay["sealed_scope_counts"] == {"product_ready":145,"execution_ready_slots":549,"hold_slots":3445,"exact_variant_image_bindings":25}
    assert overlay["overlay_result"]["product_ready"] == 145
    assert overlay["overlay_result"]["execution_ready_slots"] == 549
    assert overlay["overlay_result"]["scope_membership_changed"] is False
    assert overlay["overlay_result"]["slot_count_changed"] is False
    assert overlay["overlay_result"]["provenance_upgraded_to_source_truth"] is True
    assert overlay["overlay_result"]["unknown_or_conflict_promoted_to_ready"] is False
    assert overlay["authority_rules"]["memory_or_inference_may_override_source_truth"] is False
    assert overlay["authority_rules"]["unknown_or_conflict_action"] == "HOLD"
    assert overlay["authority_rules"]["variant_mapping_guessing_allowed"] is False
    assert overlay["important_non_equivalence"]["same_number_means_same_population"] is False

    sealed_summary=git_json("_system/v4c/ready_product_scope_summary.json")
    assert sealed_summary["product_ready_count"] == 145
    assert sealed_summary["execution_ready_slot_count"] == 549
    assert sealed_summary["hold_slot_count"] == 3445

    sealed_records=git_jsonl("_system/v4c/ready_product_scope_recovery.jsonl")
    assert len(sealed_records) == 145
    assert len({str(x["product_id"]) for x in sealed_records}) == 145
    assert all(x.get("overall_status") == "PRODUCT_READY" for x in sealed_records)
    assert all(x.get("generation_eligible") == "YES" for x in sealed_records)

    exact=git_json("_system/v4c/exact_variant_image_binding_ready.json")
    rows=first_record_list(exact)
    assert rows is not None and len(rows) == 25

    snap=ROOT/"_system/source_truth/bootstrap_store.sqlite.xz.b64"
    packed=base64.b64decode(snap.read_bytes())
    db_bytes=lzma.decompress(packed)
    with tempfile.NamedTemporaryFile(suffix=".sqlite") as tf:
        tf.write(db_bytes); tf.flush()
        con=sqlite3.connect(tf.name)
        try:
            assert con.execute("pragma integrity_check").fetchone()[0] == "ok"
            assert len(con.execute("pragma foreign_key_check").fetchall()) == 0
            assert con.execute("select count(*) from source_products").fetchone()[0] == 375
            assert con.execute("select count(*) from source_images").fetchone()[0] == 2394
            assert con.execute("select count(*) from source_variant_options").fetchone()[0] == 2673
        finally:
            con.close()

    for safety in (recon["safety"], overlay["safety"]):
        assert not any(bool(v) for v in safety.values())

    print("C5_3_SOURCE_TRUTH_REGRESSION_PASS", json.dumps({
        "source_truth":[375,2394,2673],
        "sealed_scope":[145,549,3445],
        "exact_bindings":25,
        "missing_option_images_hold":145
    }, sort_keys=True))

if __name__ == "__main__":
    main()
