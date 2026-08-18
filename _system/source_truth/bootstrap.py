#!/usr/bin/env python3
"""TinySnow V4-C5.3 privacy-safe SourceTruth manifest bootstrap.

Imports the verified public structured transport into the existing
SourceTruthStore schema. It never touches sealed product/image outputs and
never calls network, paid, image-generation, or image-editing APIs.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import lzma
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Mapping, Sequence, Tuple

try:
    from .source_truth_store import SourceTruthStore, canon, connect, digest
except ImportError:
    from source_truth_store import SourceTruthStore, canon, connect, digest

BOOTSTRAP_PARSER_VERSION = "v4c5.3-structured-transport-v1"
EXPECTED_SCHEMA_VERSION = "tinysnow.source-truth-bootstrap-manifest.3-text-transport"
TRANSPORT_LAYOUTS = {
    "products.jsona.xz.b64": 5,
    "images.jsona.xz.b64": 5,
    "variants.jsona.xz.b64": 6,
}


class BootstrapError(RuntimeError):
    pass


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def _url(value: Any) -> str | None:
    value = _text(value)
    return value or None


def _record_hash(row: Sequence[Any]) -> str:
    return _sha256(canon(list(row)).encode("utf-8"))


def _load_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        raise BootstrapError(f"cannot parse JSON: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise BootstrapError(f"expected JSON object: {path}")
    return value


def _decode_transport(
    path: Path, spec: Mapping[str, Any], expected_columns: int
) -> List[List[Any]]:
    raw = path.read_bytes()
    if len(raw) != int(spec["encoded_bytes"]):
        raise BootstrapError(f"{path.name}: encoded byte count mismatch")
    if _sha256(raw) != spec["encoded_sha256"]:
        raise BootstrapError(f"{path.name}: encoded SHA256 mismatch")

    try:
        compressed = base64.b64decode(raw)
    except Exception as exc:
        raise BootstrapError(f"{path.name}: invalid base64: {exc}") from exc
    if len(compressed) != int(spec["compressed_bytes"]):
        raise BootstrapError(f"{path.name}: compressed byte count mismatch")
    if _sha256(compressed) != spec["compressed_sha256"]:
        raise BootstrapError(f"{path.name}: compressed SHA256 mismatch")

    try:
        decoded = lzma.decompress(compressed)
    except Exception as exc:
        raise BootstrapError(f"{path.name}: invalid XZ payload: {exc}") from exc
    if len(decoded) != int(spec["decompressed_bytes"]):
        raise BootstrapError(f"{path.name}: decompressed byte count mismatch")
    if _sha256(decoded) != spec["decompressed_sha256"]:
        raise BootstrapError(f"{path.name}: decompressed SHA256 mismatch")

    lines = decoded.splitlines()
    if len(lines) != int(spec["rows"]):
        raise BootstrapError(f"{path.name}: row count mismatch")

    rows: List[List[Any]] = []
    for index, line in enumerate(lines, start=1):
        try:
            row = json.loads(line)
        except Exception as exc:
            raise BootstrapError(f"{path.name}: invalid JSONA row {index}: {exc}") from exc
        if not isinstance(row, list) or len(row) != expected_columns:
            raise BootstrapError(
                f"{path.name}: row {index} expected {expected_columns} columns"
            )
        rows.append(row)
    return rows


def load_verified_manifest(
    manifest_dir: str | Path,
) -> Tuple[Dict[str, Any], Dict[str, List[List[Any]]]]:
    root = Path(manifest_dir)
    manifest = _load_json(root / "manifest.json")
    if manifest.get("schema_version") != EXPECTED_SCHEMA_VERSION:
        raise BootstrapError("unsupported bootstrap manifest schema")
    if manifest.get("paid_api_called") is not False:
        raise BootstrapError("paid_api_called must remain false")
    if manifest.get("generation_called") is not False:
        raise BootstrapError("generation_called must remain false")
    if manifest.get("sealed_stage_rerun") is not False:
        raise BootstrapError("sealed_stage_rerun must remain false")
    if manifest.get("source_download_rerun") is not False:
        raise BootstrapError("source_download_rerun must remain false")

    workbook = manifest.get("authoritative_workbook") or {}
    workbook_sha = workbook.get("sha256")
    if not isinstance(workbook_sha, str) or len(workbook_sha) != 64:
        raise BootstrapError("missing authoritative workbook SHA256")
    if workbook.get("source_available_in_public_repo") is not False:
        raise BootstrapError("privacy rule violation: raw workbook must stay private")

    specs = manifest.get("transport_files") or {}
    rows: Dict[str, List[List[Any]]] = {}
    for filename, columns in TRANSPORT_LAYOUTS.items():
        spec = specs.get(filename)
        if not isinstance(spec, dict):
            raise BootstrapError(f"manifest missing transport spec: {filename}")
        rows[filename] = _decode_transport(root / filename, spec, columns)

    expected = manifest.get("row_counts") or {}
    actual = {
        "products": len(rows["products.jsona.xz.b64"]),
        "gallery_images": len(rows["images.jsona.xz.b64"]),
        "variant_options": len(rows["variants.jsona.xz.b64"]),
    }
    if actual != {
        "products": int(expected.get("products", -1)),
        "gallery_images": int(expected.get("gallery_images", -1)),
        "variant_options": int(expected.get("variant_options", -1)),
    }:
        raise BootstrapError(f"row counts disagree with manifest: {actual}")

    _validate_internal_reconciliation(manifest, rows)
    return manifest, rows


def _validate_internal_reconciliation(
    manifest: Mapping[str, Any], rows: Mapping[str, List[List[Any]]]
) -> None:
    products = rows["products.jsona.xz.b64"]
    images = rows["images.jsona.xz.b64"]
    variants = rows["variants.jsona.xz.b64"]

    product_ids = [_text(row[0]) for row in products]
    if any(not product_id for product_id in product_ids):
        raise BootstrapError("empty product ID in product transport")
    duplicates = [key for key, count in Counter(product_ids).items() if count > 1]
    if duplicates:
        raise BootstrapError(f"duplicate product IDs: {duplicates[:5]}")

    product_set = set(product_ids)
    image_counts = Counter(_text(row[0]) for row in images)
    variant_counts = Counter(_text(row[0]) for row in variants)
    if set(image_counts) - product_set:
        raise BootstrapError("gallery image references unknown product")
    if set(variant_counts) - product_set:
        raise BootstrapError("variant references unknown product")

    for row in products:
        product_id = _text(row[0])
        declared_variants = int(row[2])
        declared_images = int(row[3])
        if image_counts[product_id] != declared_images:
            raise BootstrapError(f"{product_id}: declared gallery count mismatch")
        if variant_counts[product_id] != declared_variants:
            raise BootstrapError(f"{product_id}: declared variant count mismatch")
        if bool(row[1]) != (declared_variants > 0):
            raise BootstrapError(f"{product_id}: has_variants mismatch")

    option_urls = [_url(row[4]) for row in variants]
    present = sum(bool(value) for value in option_urls)
    missing = len(option_urls) - present
    unique_urls = len({value for value in option_urls if value})
    expected = manifest.get("variant_option_image") or {}
    if (
        present != int(expected.get("present", -1))
        or missing != int(expected.get("missing", -1))
        or unique_urls != int(expected.get("unique_urls", -1))
    ):
        raise BootstrapError("variant option image reconciliation mismatch")


def _batch_id(workbook_sha: str) -> str:
    return "batch_" + workbook_sha[:24]


def _snapshot_sha(manifest: Mapping[str, Any]) -> str:
    specs = manifest["transport_files"]
    payload = {
        name: {
            "encoded_sha256": specs[name]["encoded_sha256"],
            "decompressed_sha256": specs[name]["decompressed_sha256"],
        }
        for name in sorted(TRANSPORT_LAYOUTS)
    }
    return _sha256(canon(payload).encode("utf-8"))


def _counts(db_path: str | Path, source_batch_id: str) -> Dict[str, int]:
    con = connect(db_path, True)
    try:
        def count(table: str) -> int:
            return int(
                con.execute(
                    f"select count(*) from {table} where source_batch_id=?",
                    (source_batch_id,),
                ).fetchone()[0]
            )
        return {
            "products": count("source_products"),
            "gallery_images": count("source_images"),
            "variant_options": count("source_variants"),
        }
    finally:
        con.close()


def _complete_existing(
    db_path: str | Path, source_batch_id: str, manifest: Mapping[str, Any]
) -> bool:
    counts = _counts(db_path, source_batch_id)
    expected = manifest["row_counts"]
    return counts == {
        "products": int(expected["products"]),
        "gallery_images": int(expected["gallery_images"]),
        "variant_options": int(expected["variant_options"]),
    }


def _delete_incomplete_batch(store: SourceTruthStore, source_batch_id: str) -> None:
    with store.writer() as con:
        con.execute(
            "delete from source_variant_image_bindings where source_batch_id=?",
            (source_batch_id,),
        )
        con.execute(
            "delete from source_variant_options where source_batch_id=?",
            (source_batch_id,),
        )
        con.execute(
            "delete from source_field_provenance where source_batch_id=?",
            (source_batch_id,),
        )
        con.execute("delete from source_fields where source_batch_id=?", (source_batch_id,))
        con.execute("delete from source_images where source_batch_id=?", (source_batch_id,))
        con.execute("delete from source_variants where source_batch_id=?", (source_batch_id,))
        con.execute("delete from source_products where source_batch_id=?", (source_batch_id,))
        con.execute("delete from source_conflicts where source_batch_id=?", (source_batch_id,))
        con.execute("delete from source_batches where source_batch_id=?", (source_batch_id,))


def bootstrap_database(
    manifest_dir: str | Path, database_path: str | Path
) -> Dict[str, Any]:
    manifest, rows = load_verified_manifest(manifest_dir)
    workbook = manifest["authoritative_workbook"]
    workbook_sha = workbook["sha256"].lower()
    source_batch_id = _batch_id(workbook_sha)
    store = SourceTruthStore(database_path)

    existing = store.batch_by_sha(workbook_sha)
    if existing:
        existing_batch_id = str(existing["source_batch_id"])
        if _complete_existing(database_path, existing_batch_id, manifest):
            return bootstrap_stats(
                database_path, existing_batch_id, manifest, idempotent=True
            )
        _delete_incomplete_batch(store, existing_batch_id)

    products = rows["products.jsona.xz.b64"]
    images = rows["images.jsona.xz.b64"]
    variants = rows["variants.jsona.xz.b64"]
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    with store.writer() as con:
        con.execute(
            """
            insert into source_batches(
              source_batch_id, platform, source_type, original_filename,
              source_file_sha256, file_size, imported_at, export_timestamp,
              sheet_inventory_json, row_counts_json, schema_fingerprint,
              parser_version, capture_status, raw_snapshot_sha256
            ) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                source_batch_id,
                manifest.get("platform") or "Shopee Taiwan",
                manifest.get("source_type") or "authoritative workbook",
                workbook["original_filename"],
                workbook_sha,
                int(workbook["file_size"]),
                now,
                None,
                canon({"transport": sorted(TRANSPORT_LAYOUTS), "raw_workbook_public": False}),
                canon(manifest["row_counts"]),
                _sha256(EXPECTED_SCHEMA_VERSION.encode("utf-8")),
                BOOTSTRAP_PARSER_VERSION,
                "AUTHORITATIVE",
                _snapshot_sha(manifest),
            ),
        )

        con.executemany(
            """
            insert into source_products(
              source_batch_id, product_id, parent_sku, original_product_name,
              original_category, original_description, product_has_variants,
              variant_count, image_count, raw_record_json, source_record_hash,
              source_row, status
            ) values(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                (
                    source_batch_id,
                    _text(row[0]),
                    None,
                    None,
                    None,
                    None,
                    1 if bool(row[1]) else 0,
                    int(row[2]),
                    int(row[3]),
                    canon(row),
                    _record_hash(row),
                    int(row[4]),
                    "AUTHORITATIVE",
                )
                for row in products
            ],
        )

        variant_records = []
        for row in variants:
            product_id = _text(row[0])
            variation_name = _text(row[1])
            option_index = _text(row[2])
            option_name = _text(row[3])
            option_url = _url(row[4])
            identity = digest(
                "variant",
                [source_batch_id, product_id, variation_name, option_index, option_name],
            )
            variant_records.append(
                (
                    source_batch_id,
                    identity,
                    product_id,
                    variation_name,
                    option_index,
                    option_name,
                    option_url,
                    option_url,
                    None,
                    None,
                    int(row[5]),
                    canon(row),
                    _record_hash(row),
                    int(row[5]),
                    "AUTHORITATIVE",
                )
            )
        con.executemany(
            """
            insert into source_variants(
              source_batch_id, variant_identity_key, product_id, variation_name,
              option_index, option_name, option_image_url,
              option_image_url_normalized, platform_variant_id, variant_sku,
              internal_identity, raw_record_json, source_record_hash,
              source_row, status
            ) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            variant_records,
        )

        image_records = []
        for row in images:
            product_id = _text(row[0])
            position = _text(row[1])
            sequence = _text(row[2])
            original_url = _text(row[3])
            identity = digest(
                "image",
                [source_batch_id, product_id, position, sequence, original_url],
            )
            image_records.append(
                (
                    source_batch_id,
                    identity,
                    product_id,
                    position,
                    sequence,
                    original_url,
                    original_url,
                    None,
                    None,
                    None,
                    canon(row),
                    _record_hash(row),
                    int(row[4]),
                    "PRODUCT_GALLERY",
                    "AUTHORITATIVE",
                )
            )
        con.executemany(
            """
            insert into source_images(
              source_batch_id, image_identity_key, product_id, image_position,
              image_sequence, original_source_url, normalized_source_url,
              reconciled_source_id, reconciled_source_sequence, source_sha256,
              raw_record_json, source_record_hash, source_row,
              scope_semantics, scope_status
            ) values(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            image_records,
        )

    return bootstrap_stats(database_path, source_batch_id, manifest, idempotent=False)


def bootstrap_stats(
    database_path: str | Path,
    source_batch_id: str,
    manifest: Mapping[str, Any],
    *,
    idempotent: bool,
) -> Dict[str, Any]:
    con = connect(database_path, True)
    try:
        row = con.execute(
            """
            select
              sum(case when option_image_url is null or trim(option_image_url)='' then 1 else 0 end),
              sum(case when option_image_url is not null and trim(option_image_url)<>'' then 1 else 0 end),
              count(distinct case when option_image_url is not null and trim(option_image_url)<>'' then option_image_url end)
            from source_variants where source_batch_id=?
            """,
            (source_batch_id,),
        ).fetchone()
    finally:
        con.close()
    return {
        "source_batch_id": source_batch_id,
        "source_sha256": manifest["authoritative_workbook"]["sha256"],
        "schema_version": manifest["schema_version"],
        "counts": _counts(database_path, source_batch_id),
        "variant_option_image": {
            "missing": int(row[0] or 0),
            "present": int(row[1] or 0),
            "unique_urls": int(row[2] or 0),
        },
        "idempotent_existing_batch": bool(idempotent),
        "paid_api_called": False,
        "generation_called": False,
        "sealed_stage_rerun": False,
        "source_download_rerun": False,
    }


class SourceTruthResolver:
    """Strict resolver over the existing SourceTruthStore read APIs."""

    def __init__(self, database_path: str | Path):
        self.store = SourceTruthStore(database_path)

    def close(self) -> None:
        return None

    def product(self, product_id: str) -> Dict[str, Any] | None:
        return self.store.product(_text(product_id))

    def gallery(self, product_id: str) -> Dict[str, Any]:
        product = self.store.product(_text(product_id))
        if product is None:
            return {
                "status": "HOLD",
                "reason": "UNKNOWN_PRODUCT",
                "product_id": _text(product_id),
                "images": [],
            }
        images = self.store.images(_text(product_id))
        expected = int(product["image_count"])
        if len(images) != expected:
            return {
                "status": "HOLD",
                "reason": "AUTHORITATIVE_GALLERY_COUNT_MISMATCH",
                "product_id": _text(product_id),
                "expected_image_count": expected,
                "images": images,
            }
        return {
            "status": "RESOLVED",
            "source_confidence": "AUTHORITATIVE",
            "product_id": _text(product_id),
            "expected_image_count": expected,
            "images": images,
        }

    def variant_options(self, product_id: str) -> List[Dict[str, Any]]:
        return self.store.variants(_text(product_id))

    def variant_image(
        self, product_id: str, variation_name: str, option_index: int
    ) -> Dict[str, Any]:
        wanted_name = _text(variation_name)
        wanted_index = _text(option_index)
        for row in self.store.variants(_text(product_id)):
            if _text(row.get("variation_name")) != wanted_name:
                continue
            if _text(row.get("option_index")) != wanted_index:
                continue
            result = dict(row)
            if not _url(result.get("option_image_url")):
                result.update(
                    status="HOLD",
                    reason="MISSING_AUTHORITATIVE_VARIANT_IMAGE",
                )
                return result
            result.update(status="RESOLVED", confidence="AUTHORITATIVE")
            return result
        return {
            "status": "HOLD",
            "reason": "UNKNOWN_VARIANT_OPTION",
            "product_id": _text(product_id),
            "variation_name": wanted_name,
            "option_index": int(option_index),
        }


def _default_manifest_dir() -> Path:
    return Path(__file__).resolve().parent / "bootstrap_manifest"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-dir", default=str(_default_manifest_dir()))
    parser.add_argument("--db")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args(argv)

    if args.verify_only:
        manifest, _ = load_verified_manifest(args.manifest_dir)
        output = {
            "status": "VERIFIED",
            "schema_version": manifest["schema_version"],
            "row_counts": manifest["row_counts"],
            "variant_option_image": manifest["variant_option_image"],
            "paid_api_called": False,
            "generation_called": False,
            "sealed_stage_rerun": False,
            "source_download_rerun": False,
        }
    else:
        if not args.db:
            parser.error("--db is required unless --verify-only is used")
        output = bootstrap_database(args.manifest_dir, args.db)
        output["status"] = "BOOTSTRAPPED"

    print(json.dumps(output, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
