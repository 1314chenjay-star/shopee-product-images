#!/usr/bin/env python3
from __future__ import annotations
import base64, json, lzma, pathlib, sqlite3, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE_SHA = "616d1c0639f34433ebe244678f101458e375c1c095677be7d9f5736b2ccecb9a"

def load(path):
    return json.loads((ROOT/path).read_text(encoding="utf-8-sig"))

def main():
    manifest=load("_system/source_truth/bootstrap_manifest/manifest.json")
    bootstrap=load("_system/source_truth/bootstrap_validation.json")
    recon=load("_system/source_truth/reconciliation_validation.json")
    overlay=load("_system/source_truth/ready_scope_overlay.json")
    binding=load("_system/source_truth/c5_3_exact_binding_evidence.json")
    payload_cov=load("_system/v4c/generation_payload/coverage_summary.json")
    canary_preflight=load("_system/v4c/generation_canary_preflight/availability.json")

    assert manifest["authoritative_workbook"]["sha256"] == SOURCE_SHA
    assert manifest["row_counts"] == {"gallery_images":2394,"products":375,"variant_options":2673}
    assert manifest["variant_option_image"] == {"missing":145,"present":2528,"unique_urls":2515}

    assert bootstrap["status"] == "PASS"
    assert bootstrap["source_sha256"] == SOURCE_SHA
    assert bootstrap["row_counts"] == {"gallery_images":2394,"products":375,"variant_options":2673}
    assert bootstrap["foreign_key_violations"] == 0
    assert bootstrap["sqlite_integrity"] == "ok"
    assert bootstrap["variant_option_image"] == {"missing":145,"present":2528,"unique_urls":2515}
    assert bootstrap["missing_variant_image_policy"] == "HOLD"
    assert bootstrap["idempotent_resume"] is True

    assert recon["status"] == "PASS"
    assert recon["expected"] == recon["observed"] == {"products":375,"gallery_images":2394,"variant_options":2673}
    assert all(recon["matches"].values())

    # Frozen ready membership is not recomputed in C5.3.
    assert payload_cov["product_ready_for_generation"] == 145
    assert payload_cov["final_paid_execution_candidate_products"] == 145
    assert payload_cov["final_paid_execution_candidate_slots"] == 549
    assert canary_preflight["frozen_ready_products"] == 145
    assert canary_preflight["frozen_execution_ready_slots"] == 549

    # Historical C5.2 exact-binding claim is not authoritative because its ref is unavailable.
    assert overlay["status"] == "PASS"
    assert overlay["historical_sealed_scope_claim"]["product_ready"] == 145
    assert overlay["historical_sealed_scope_claim"]["execution_ready_slots"] == 549
    assert overlay["historical_sealed_scope_claim"]["hold_slots"] == 3445
    assert overlay["historical_sealed_scope_claim"]["exact_variant_image_bindings"] == 25
    assert overlay["sealed_scope_input"]["ref_resolvable_in_current_repository"] is False
    assert overlay["overlay_result"]["scope_membership_changed"] is False
    assert overlay["overlay_result"]["slot_count_changed"] is False
    assert overlay["overlay_result"]["unknown_or_conflict_promoted_to_ready"] is False

    # Source Truth exact-binding recovery is the current authority: 0/549 exact option-image bindings.
    assert binding["status"] == "PASS"
    assert binding["source_truth_sha256"] == SOURCE_SHA
    assert binding["frozen_ready_products"] == 145
    assert binding["frozen_execution_ready_slots"] == 549
    assert binding["exact_variant_image_binding_slots"] == 0
    assert binding["non_binding_slots"] == 549
    assert overlay["authoritative_variant_binding_result"]["exact_variant_image_binding_slots"] == 0
    assert overlay["authoritative_variant_binding_result"]["variant_paid_canary_exact_binding_available"] is False
    assert overlay["authority_rules"]["variant_mapping_guessing_allowed"] is False
    assert overlay["authority_rules"]["unknown_or_conflict_action"] == "HOLD"
    assert overlay["authority_rules"]["unresolvable_historical_ref_may_override_source_truth"] is False
    assert overlay["important_non_equivalence"]["same_number_means_same_population"] is False

    snap=ROOT/"_system/source_truth/bootstrap_store.sqlite.xz.b64"
    db_bytes=lzma.decompress(base64.b64decode(snap.read_bytes()))
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

    for safety in (recon["safety"], overlay["safety"], binding["safety"]):
        assert not any(bool(v) for v in safety.values())

    print("C5_3_SOURCE_TRUTH_REGRESSION_PASS", json.dumps({
        "source_truth":[375,2394,2673],
        "frozen_ready_scope":[145,549],
        "historical_unverified_exact_bindings":25,
        "authoritative_exact_bindings":0,
        "missing_option_images_hold":145,
        "variant_paid_canary":"HOLD"
    }, sort_keys=True))

if __name__ == "__main__":
    main()
