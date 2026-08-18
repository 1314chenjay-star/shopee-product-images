#!/usr/bin/env python3
"""Focused V4-C5.3 SourceTruth importer/resolver/bootstrap regression.

Zero-paid, no network, no generation, no sealed-stage rerun.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from _system.source_truth.bootstrap import (  # noqa: E402
    SourceTruthResolver,
    bootstrap_database,
    load_verified_manifest,
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def run() -> dict:
    manifest_dir = ROOT / "_system" / "source_truth" / "bootstrap_manifest"
    manifest, rows = load_verified_manifest(manifest_dir)
    products = rows["products.jsona.xz.b64"]
    variants = rows["variants.jsona.xz.b64"]

    require(manifest["row_counts"] == {
        "products": 375,
        "gallery_images": 2394,
        "variant_options": 2673,
    }, "authoritative row counts changed")
    require(manifest["variant_option_image"] == {
        "missing": 145,
        "present": 2528,
        "unique_urls": 2515,
    }, "authoritative variant-image counts changed")

    with tempfile.TemporaryDirectory(prefix="tinysnow-c53-") as temp_dir:
        db_path = Path(temp_dir) / "source_truth.sqlite3"
        first = bootstrap_database(manifest_dir, db_path)
        second = bootstrap_database(manifest_dir, db_path)

        require(first["counts"] == {
            "products": 375,
            "gallery_images": 2394,
            "variant_options": 2673,
        }, "bootstrap database counts mismatch")
        require(first["variant_option_image"] == manifest["variant_option_image"],
                "bootstrap variant-image counts mismatch")
        require(first["idempotent_existing_batch"] is False,
                "first bootstrap unexpectedly treated as existing")
        require(second["idempotent_existing_batch"] is True,
                "second bootstrap did not skip complete authoritative batch")
        require(second["counts"] == first["counts"],
                "idempotent bootstrap changed counts")

        resolver = SourceTruthResolver(db_path)
        first_product = products[0]
        product_id = str(first_product[0])
        product = resolver.product(product_id)
        require(product is not None, "resolver cannot resolve known product")
        require(product["capture_status"] == "AUTHORITATIVE",
                "product resolver lost authoritative capture status")
        require(int(product["image_count"]) == int(first_product[3]),
                "product image count changed")
        require(int(product["variant_count"]) == int(first_product[2]),
                "product variant count changed")

        gallery = resolver.gallery(product_id)
        require(gallery["status"] == "RESOLVED",
                "known product gallery did not resolve")
        require(gallery["source_confidence"] == "AUTHORITATIVE",
                "gallery resolver lost authoritative confidence")
        require(len(gallery["images"]) == int(first_product[3]),
                "gallery resolver count mismatch")

        product_variants = resolver.variant_options(product_id)
        require(len(product_variants) == int(first_product[2]),
                "variant resolver count mismatch")

        missing_row = next(row for row in variants if not row[4])
        missing = resolver.variant_image(
            str(missing_row[0]), str(missing_row[1]), int(missing_row[2])
        )
        require(missing["status"] == "HOLD", "missing variant image was not held")
        require(missing["reason"] == "MISSING_AUTHORITATIVE_VARIANT_IMAGE",
                "missing variant image got wrong HOLD reason")

        present_row = next(row for row in variants if row[4])
        present = resolver.variant_image(
            str(present_row[0]), str(present_row[1]), int(present_row[2])
        )
        require(present["status"] == "RESOLVED",
                "known variant image did not resolve")
        require(present["confidence"] == "AUTHORITATIVE",
                "known variant image lost authoritative confidence")
        require(present["option_image_url"] == present_row[4],
                "variant image URL changed")

        unknown = resolver.variant_image("__unknown__", "__unknown__", 1)
        require(unknown["status"] == "HOLD", "unknown variant was not held")
        require(unknown["reason"] == "UNKNOWN_VARIANT_OPTION",
                "unknown variant got wrong HOLD reason")

        integrity = resolver.store.integrity()
        require(integrity["integrity_check"] == "ok",
                f"sqlite integrity_check failed: {integrity}")
        require(integrity["foreign_key_errors"] == 0,
                f"sqlite foreign_key_check failed: {integrity}")

    return {
        "status": "PASS",
        "stage": "V4-C5.3 SourceTruth importer/resolver/bootstrap",
        "source_sha256": manifest["authoritative_workbook"]["sha256"],
        "row_counts": manifest["row_counts"],
        "variant_option_image": manifest["variant_option_image"],
        "sqlite_integrity": "ok",
        "foreign_key_violations": 0,
        "idempotent_resume": True,
        "missing_variant_image_policy": "HOLD",
        "paid_api_called": False,
        "generation_called": False,
        "sealed_stage_rerun": False,
        "source_download_rerun": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json-out")
    args = parser.parse_args()
    result = run()
    payload = json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    if args.json_out:
        Path(args.json_out).write_text(payload, encoding="utf-8")
    print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
