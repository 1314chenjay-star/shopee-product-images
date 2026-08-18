#!/usr/bin/env python3
"""TinySnow V4-C5.3 privacy-safe SourceTruth manifest bootstrap.

This module imports the verified public structured transport into the existing
SourceTruthStore without touching sealed product/image outputs or calling
network/paid/generation APIs.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import lzma
from datetime import datetime, timezone
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple

try:
    from .source_truth_store import SourceTruthStore, canonical_json, digest_key, normalize_text
except ImportError:  # direct script execution from repository root
    from source_truth_store import SourceTruthStore, canonical_json, digest_key, normalize_text


BOOTSTRAP_PARSER_VERSION = "v4c5.3-structured-transport-v1"
EXPECTED_SCHEMA_VERSION = "tinysnow.source-truth-bootstrap-manifest.3-text-transport"
TRANSPORT_LAYOUTS = {
    "products.jsona.xz.b64": 5,
    "images.jsona.xz.b64": 5,
    "variants.jsona.xz.b64": 6,
}


class BootstrapError(RuntimeError):
    """Raised when transport or bootstrap invariants fail."""


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _normalize_url(value: Any) -> str | None:
    text = normalize_text(value)
    return text or None


def _record_hash(row: Sequence[Any]) -> str:
    return _sha256(canonical_json(list(row)).encode("utf-8"))


def _load_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        raise BootstrapError(f"cannot parse JSON: {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise BootstrapError(f"expected JSON object: {path}")
    return value


def _decode_transport(path: Path, spec: Mapping[str, Any], expected_columns: int) -> List[List[Any]]:
    raw = path.read_bytes()
    if len(raw) != int(spec["encoded_bytes"]):
        raise BootstrapError(f"{path.name}: encoded byte count mismatch")
    if _sha256(raw) != spec["encoded_sha256"]:
        raise BootstrapError(f"{path.name}: encoded SHA256 mismatch")

    try:
        compressed = base64.b64decode(raw)
    except Exception as exc:
        raise BootstrapError(f"{path.name}: invalid base64 transport: {exc}") from exc
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


def load_verified_manifest(manifest_dir: str | Path) -> Tuple[Dict[str, Any], Dict[str, List[List[Any]]]]:
    root = Path(manifest_dir)
    manifest = _load_json(root / "manifest.json")
    if manifest.get("schema_version") != EXPECTED_SCHEMA_VERSION:
        raise BootstrapError("unsupported bootstrap manifest schema")
    if manifest.get("paid_api_called") is not False:
        raise BootstrapError("bootstrap manifest must prove paid_api_called=false")
    if manifest.get("generation_called") is not False:
        raise BootstrapError("bootstrap manifest must prove generation_called=false")
    if manifest.get("sealed_stage_rerun") is not False:
        raise BootstrapError("bootstrap may not rerun a sealed stage")
    if manifest.get("source_download_rerun") is not False:
        raise BootstrapError("bootstrap may not redownload authoritative source")

    workbook = manifest.get("authoritative_workbook") or {}
    workbook_sha = workbook.get("sha256")
    if not isinstance(workbook_sha, str) or len(workbook_sha) != 64:
        raise BootstrapError("missing authoritative workbook SHA256")
    if workbook.get("source_available_in_public_repo") is not False:
        raise BootstrapError("privacy rule violation: raw workbook must stay private")

    transport_specs = manifest.get("transport_files") or {}
    rows: Dict[str, List[List[Any]]] = {}
    for filename, columns in TRANSPORT_LAYOUTS.items():
        spec = transport_specs.get(filename)
        if not isinstance(spec, dict):
            raise BootstrapError(f"manifest missing transport spec: {filename}")
        rows[filename] = _decode_transport(root / filename, spec, columns)

    expected_counts = manifest.get("row_counts") or {}
    if len(rows["products.jsona.xz.b64"]) != int(expected_counts.get("products", -1)):
        raise BootstrapError("product row count disagrees with manifest")
    if len(rows["images.jsona.xz.b64"]) != int(expected_counts.get("gallery_images", -1)):
        raise BootstrapError("gallery image row count disagrees with manifest")
    if len(rows["variants.jsona.xz.b64"]) != int(expected_counts.get("variant_options", -1)):
        raise BootstrapError("variant row count disagrees with manifest")

    _validate_internal_reconciliation(manifest, rows)
    return manifest, rows


def _validate_internal_reconciliation(
    manifest: Mapping[str, Any], rows: Mapping[str, List[List[Any]]]
) -> None:
    products = rows["products.jsona.xz.b64"]
    images = rows["images.jsona.xz.b64"]
    variants = rows["variants.jsona.xz.b64"]

    product_ids = [normalize_text(row[0]) for row in products]
    if any(not product_id for product_id in product_ids):
        raise BootstrapError("empty product ID in product transport")
    duplicate_products = [key for key, count in Counter(product_ids).items() if count > 1]
    if duplicate_products:
        raise BootstrapError(f"duplicate product IDs: {duplicate_products[:5]}")

    product_set = set(product_ids)
    image_counts = Counter(normalize_text(row[0]) for row in images)
    variant_counts = Counter(normalize_text(row[0]) for row in variants)
    if set(image_counts) - product_set:
        raise BootstrapError("gallery image references unknown product")
    if set(variant_counts) - product_set:
        raise BootstrapError("variant references unknown product")

    for row in products:
        product_id = normalize_text(row[0])
        has_variants = bool(row[1])
        declared_variants = int(row[2])
        declared_images = int(row[3])
        if image_counts[product_id] != declared_images:
            raise BootstrapError(f"{product_id}: declared gallery count mismatch")
        if variant_counts[product_id] != declared_variants:
            raise BootstrapError(f"{product_id}: declared variant count mismatch")
        if has_variants != (declared_variants > 0):
            raise BootstrapError(f"{product_id}: has_variants mismatch")

    variant_urls = [_normalize_url(row[4]) for row in variants]
    present = sum(1 for value in variant_urls if value)
    missing = len(variant_urls) - present
    unique_urls = len({value for value in variant_urls if value})
    expected_variant = manifest.get("variant_option_image") or {}
    if (
        present != int(expected_variant.get("present", -1))
        or missing != int(expected_variant.get("missing", -1))
        or unique_urls != int(expected_variant.get("unique_urls", -1))
    ):
        raise BootstrapError("variant option image reconciliation mismatch")


def _batch_id(workbook_sha: str) -> str:
    return "batch_" + workbook_sha[:24]


def _snapshot_sha(manifest: Mapping[str, Any]) -> str:
    transport = manifest["transport_files"]
    payload = {
        name: {
            "encoded_sha256": transport[name]["encoded_sha256"],
            "decompressed_sha256": transport[name]["decompressed_sha256"],
        }
        for name in sorted(TRANSPORT_LAYOUTS)
    }
    return _sha256(canonical_json(payload).encode("utf-8"))


def _source_counts(store: SourceTruthStore, source_batch_id: str) -> Dict[str, int]:
    conn = store.connection
    def count(table: str) -> int:
        return int(
            conn.execute(
                f"SELECT COUNT(*) FROM {table} WHERE source_batch_id=?",
                (source_batch_id,),
            ).fetchone()[0]
        )
    return {
        "products": count("source_products"),
        "gallery_images": count("source_images"),
        "variant_options": count("source_variants"),
        "gallery_scopes": count("source_image_scope_semantics"),
    }


def _is_complete_existing_batch(
    store: SourceTruthStore, source_batch_id: str, manifest: Mapping[str, Any]
) -> bool:
    counts = _source_counts(store, source_batch_id)
    expected = manifest["row_counts"]
    return (
        counts["products"] == int(expected["products"])
        and counts["gallery_images"] == int(expected["gallery_images"])
        and counts["variant_options"] == int(expected["variant_options"])
        and counts["gallery_scopes"] == int(expected["products"])
    )


def bootstrap_database(
    manifest_dir: str | Path,
    database_path: str | Path,
) -> Dict[str, Any]:
    manifest, rows = load_verified_manifest(manifest_dir)
    workbook = manifest["authoritative_workbook"]
    workbook_sha = workbook["sha256"]
    source_batch_id = _batch_id(workbook_sha)
    store = SourceTruthStore(database_path)
    try:
        existing = store.batch_by_sha256(workbook_sha)
        if existing:
            existing_batch_id = str(existing["source_batch_id"])
            if _is_complete_existing_batch(store, existing_batch_id, manifest):
                return bootstrap_stats(store, existing_batch_id, manifest, idempotent=True)
            store.connection.execute(
                "DELETE FROM source_batches WHERE source_batch_id=?",
                (existing_batch_id,),
            )
            store.connection.commit()

        schema_fingerprint = _sha256(
            EXPECTED_SCHEMA_VERSION.encode("utf-8")
        )
        store.import_batch(
            source_batch_id=source_batch_id,
            original_filename=workbook["original_filename"],
            file_size=int(workbook["file_size"]),
            imported_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            sheet_inventory={
                "transport": sorted(TRANSPORT_LAYOUTS),
                "raw_workbook_public": False,
            },
            row_counts=manifest["row_counts"],
            schema_fingerprint=schema_fingerprint,
            parser_version=BOOTSTRAP_PARSER_VERSION,
            capture_status="AUTHORITATIVE",
            source_type=manifest.get("source_type"),
            platform=manifest.get("platform"),
            file_sha256=workbook_sha,
            raw_snapshot_sha256=_snapshot_sha(manifest),
        )

        products = rows["products.jsona.xz.b64"]
        images = rows["images.jsona.xz.b64"]
        variants = rows["variants.jsona.xz.b64"]

        images_by_product: Dict[str, List[List[Any]]] = defaultdict(list)
        for row in images:
            images_by_product[normalize_text(row[0])].append(row)

        for row in products:
            product_id = normalize_text(row[0])
            store.insert_source_product(
                source_batch_id=source_batch_id,
                product_id=product_id,
                parent_sku=None,
                shop_category=None,
                original_title=None,
                original_description=None,
                has_variants=bool(row[1]),
                variant_count=int(row[2]),
                image_count=int(row[3]),
                source_row=int(row[4]),
                source_record_hash=_record_hash(row),
                source_status="AUTHORITATIVE",
            )
            declared_images = int(row[3])
            store.insert_image_scope_semantics(
                source_batch_id=source_batch_id,
                product_id=product_id,
                expected_image_count=declared_images,
                image_count_raw=declared_images,
                parser_count=len(images_by_product.get(product_id, [])),
                sheet_count=len(images_by_product.get(product_id, [])),
                scope_status="AUTHORITATIVE",
                scope_note="Verified privacy-safe C5.3 manifest transport",
            )

        for row in variants:
            product_id = normalize_text(row[0])
            spec_name = normalize_text(row[1])
            option_index = int(row[2])
            option_name = normalize_text(row[3])
            option_url = _normalize_url(row[4])
            identity_key = digest_key(
                "variant",
                [source_batch_id, product_id, spec_name, option_index, option_name],
            )
            store.insert_source_variant(
                source_batch_id=source_batch_id,
                variant_identity_key=identity_key,
                product_id=product_id,
                spec_name=spec_name,
                option_index=option_index,
                option_name=option_name,
                option_image_url=option_url,
                source_row=int(row[5]),
                source_record_hash=_record_hash(row),
                source_status="AUTHORITATIVE",
            )

        for row in images:
            product_id = normalize_text(row[0])
            image_position = normalize_text(row[1])
            image_sequence = int(row[2])
            original_url = normalize_text(row[3])
            identity_key = digest_key(
                "image",
                [source_batch_id, product_id, image_position, image_sequence, original_url],
            )
            store.insert_source_image(
                source_batch_id=source_batch_id,
                image_identity_key=identity_key,
                product_id=product_id,
                image_position=image_position,
                image_sequence=image_sequence,
                original_url=original_url,
                normalized_url=_normalize_url(original_url),
                source_row=int(row[4]),
                source_record_hash=_record_hash(row),
                source_status="AUTHORITATIVE",
            )

        return bootstrap_stats(store, source_batch_id, manifest, idempotent=False)
    finally:
        store.close()


def bootstrap_stats(
    store: SourceTruthStore,
    source_batch_id: str,
    manifest: Mapping[str, Any],
    *,
    idempotent: bool,
) -> Dict[str, Any]:
    counts = _source_counts(store, source_batch_id)
    row = store.connection.execute(
        """
        SELECT
          SUM(CASE WHEN option_image_url IS NULL OR TRIM(option_image_url)='' THEN 1 ELSE 0 END),
          SUM(CASE WHEN option_image_url IS NOT NULL AND TRIM(option_image_url)<>'' THEN 1 ELSE 0 END),
          COUNT(DISTINCT CASE WHEN option_image_url IS NOT NULL AND TRIM(option_image_url)<>'' THEN option_image_url END)
        FROM source_variants WHERE source_batch_id=?
        """,
        (source_batch_id,),
    ).fetchone()
    return {
        "source_batch_id": source_batch_id,
        "source_sha256": manifest["authoritative_workbook"]["sha256"],
        "schema_version": manifest["schema_version"],
        "counts": counts,
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
    """Strict resolver over a bootstrapped SourceTruthStore."""

    def __init__(self, database_path: str | Path):
        self.store = SourceTruthStore(database_path)

    def close(self) -> None:
        self.store.close()

    def product(self, product_id: str) -> Dict[str, Any] | None:
        return self.store.resolve_product(product_id)

    def gallery(self, product_id: str) -> Dict[str, Any]:
        return self.store.resolve_gallery_images(product_id)

    def variant_options(self, product_id: str) -> List[Dict[str, Any]]:
        rows = self.store.connection.execute(
            """
            SELECT source_batch_id, variant_identity_key, product_id, spec_name,
                   option_index, option_name, option_image_url, source_row,
                   source_record_hash, source_status
            FROM source_variants
            WHERE product_id=? AND source_status IN ('AUTHORITATIVE','VERIFIED')
            ORDER BY spec_name, option_index, source_row
            """,
            (normalize_text(product_id),),
        ).fetchall()
        return [dict(row) for row in rows]

    def variant_image(
        self, product_id: str, spec_name: str, option_index: int
    ) -> Dict[str, Any]:
        row = self.store.connection.execute(
            """
            SELECT source_batch_id, variant_identity_key, product_id, spec_name,
                   option_index, option_name, option_image_url, source_row,
                   source_record_hash, source_status
            FROM source_variants
            WHERE product_id=? AND spec_name=? AND option_index=?
              AND source_status IN ('AUTHORITATIVE','VERIFIED')
            ORDER BY source_row DESC LIMIT 1
            """,
            (normalize_text(product_id), normalize_text(spec_name), int(option_index)),
        ).fetchone()
        if row is None:
            return {
                "status": "HOLD",
                "reason": "UNKNOWN_VARIANT_OPTION",
                "product_id": normalize_text(product_id),
                "spec_name": normalize_text(spec_name),
                "option_index": int(option_index),
            }
        result = dict(row)
        if not _normalize_url(result.get("option_image_url")):
            result.update(
                status="HOLD",
                reason="MISSING_AUTHORITATIVE_VARIANT_IMAGE",
            )
            return result
        result.update(status="RESOLVED", confidence="AUTHORITATIVE")
        return result


def _default_manifest_dir() -> Path:
    return Path(__file__).resolve().parent / "bootstrap_manifest"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest-dir", default=str(_default_manifest_dir()))
    parser.add_argument("--db")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args(argv)

    if args.verify_only:
        manifest, rows = load_verified_manifest(args.manifest_dir)
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
