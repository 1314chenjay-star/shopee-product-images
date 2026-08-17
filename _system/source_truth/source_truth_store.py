#!/usr/bin/env python3
"""TinySnow Authoritative Source Truth store.

Source Truth is permanently separate from Memory. Runtime reads SQLite lazily;
JSONL is audit/backup/migration only. Raw source records are immutable.
"""
from __future__ import annotations
import contextlib, hashlib, json, sqlite3
from pathlib import Path

SCHEMA_VERSION = 1

def canon(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

def digest(prefix, payload, length=24):
    return prefix + "_" + hashlib.sha256(canon(payload).encode("utf-8")).hexdigest()[:length]

def connect(db_path, readonly=False):
    p = Path(db_path)
    if readonly:
        con = sqlite3.connect("file:" + p.resolve().as_posix() + "?mode=ro", uri=True, timeout=5.0)
        con.execute("pragma query_only=ON")
    else:
        p.parent.mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(str(p), timeout=5.0)
    con.row_factory = sqlite3.Row
    con.execute("pragma foreign_keys=ON")
    con.execute("pragma busy_timeout=5000")
    return con

def init_schema(db_path):
    con = connect(db_path, False)
    try:
        con.execute("pragma journal_mode=WAL")
        con.execute("pragma synchronous=FULL")
        con.executescript("""
        create table if not exists source_batches(
          source_batch_id text primary key,
          platform text not null,
          source_type text not null,
          original_filename text not null,
          source_file_sha256 text not null unique,
          file_size integer not null,
          imported_at text not null,
          export_timestamp text,
          sheet_inventory_json text not null,
          row_counts_json text not null,
          schema_fingerprint text not null,
          parser_version text not null,
          capture_status text not null,
          raw_snapshot_sha256 text
        );
        create table if not exists source_products(
          source_batch_id text not null,
          product_id text not null,
          parent_sku text,
          original_product_name text,
          original_category text,
          original_description text,
          product_has_variants integer,
          variant_count integer not null,
          image_count integer not null,
          raw_record_json text not null,
          source_record_hash text not null,
          source_row integer not null,
          status text not null,
          primary key(source_batch_id, product_id),
          foreign key(source_batch_id) references source_batches(source_batch_id)
        );
        create table if not exists source_variants(
          source_batch_id text not null,
          variant_identity_key text not null,
          product_id text not null,
          variation_name text,
          option_index text,
          option_name text,
          option_image_url text,
          option_image_url_normalized text,
          platform_variant_id text,
          variant_sku text,
          internal_identity integer not null,
          raw_record_json text not null,
          source_record_hash text not null,
          source_row integer not null,
          status text not null,
          primary key(source_batch_id, variant_identity_key),
          foreign key(source_batch_id, product_id) references source_products(source_batch_id, product_id)
        );
        create table if not exists source_variant_options(
          source_batch_id text not null,
          variant_identity_key text not null,
          product_id text not null,
          dimension_name text,
          option_index text,
          raw_value text,
          normalized_value text,
          source_record_hash text not null,
          source_row integer not null,
          primary key(source_batch_id, variant_identity_key, dimension_name),
          foreign key(source_batch_id, variant_identity_key) references source_variants(source_batch_id, variant_identity_key)
        );
        create table if not exists source_images(
          source_batch_id text not null,
          image_identity_key text not null,
          product_id text not null,
          image_position text,
          image_sequence text,
          original_source_url text not null,
          normalized_source_url text not null,
          reconciled_source_id text,
          reconciled_source_sequence integer,
          source_sha256 text,
          raw_record_json text not null,
          source_record_hash text not null,
          source_row integer not null,
          scope_semantics text not null,
          scope_status text not null,
          primary key(source_batch_id, image_identity_key),
          foreign key(source_batch_id, product_id) references source_products(source_batch_id, product_id)
        );
        create table if not exists source_variant_image_bindings(
          source_batch_id text not null,
          binding_id text not null,
          product_id text not null,
          image_identity_key text not null,
          variant_identity_key text not null,
          binding_type text not null,
          normalized_source_url text not null,
          status text not null,
          primary key(source_batch_id, binding_id),
          foreign key(source_batch_id, image_identity_key) references source_images(source_batch_id, image_identity_key),
          foreign key(source_batch_id, variant_identity_key) references source_variants(source_batch_id, variant_identity_key)
        );
        create table if not exists source_fields(
          source_batch_id text not null,
          field_id text not null,
          product_id text not null,
          variant_scope_key text not null,
          field_name text not null,
          raw_value text,
          normalized_value text,
          authority_type text not null,
          volatile_business_field integer not null default 0,
          status text not null,
          primary key(source_batch_id, field_id)
        );
        create table if not exists source_field_provenance(
          source_batch_id text not null,
          field_id text not null,
          source_file_sha256 text not null,
          sheet_name text,
          source_row integer,
          source_column text,
          source_record_hash text,
          source_image_sha256 text,
          created_at text not null,
          superseded_by text,
          status text not null,
          primary key(source_batch_id, field_id),
          foreign key(source_batch_id, field_id) references source_fields(source_batch_id, field_id)
        );
        create table if not exists source_conflicts(
          conflict_id text primary key,
          source_batch_id text,
          product_id text,
          conflict_type text not null,
          identity_key text,
          details_json text not null,
          status text not null
        );
        create table if not exists source_versions(
          version_event_id text primary key,
          product_id text,
          previous_source_batch_id text,
          new_source_batch_id text not null,
          field_name text,
          old_raw_value text,
          new_raw_value text,
          status text not null
        );
        create index if not exists idx_products_product on source_products(product_id);
        create index if not exists idx_variants_product on source_variants(product_id);
        create index if not exists idx_variants_identity on source_variants(variant_identity_key);
        create index if not exists idx_variants_sku on source_variants(variant_sku);
        create index if not exists idx_variant_options_dim_value on source_variant_options(product_id, dimension_name, normalized_value);
        create index if not exists idx_images_product on source_images(product_id);
        create index if not exists idx_images_url on source_images(product_id, normalized_source_url);
        create index if not exists idx_images_sha on source_images(source_sha256);
        create index if not exists idx_bind_product_image on source_variant_image_bindings(product_id, image_identity_key);
        create index if not exists idx_fields_product_name on source_fields(product_id, field_name);
        create index if not exists idx_fields_authority on source_fields(authority_type);
        create index if not exists idx_prov_source_sha on source_field_provenance(source_image_sha256);
        """)
        con.execute(f"pragma user_version={SCHEMA_VERSION}")
        con.commit()
    finally:
        con.close()

class SourceTruthStore:
    def __init__(self, db_path):
        self.db_path = Path(db_path)
        init_schema(self.db_path)

    @contextlib.contextmanager
    def writer(self):
        con = connect(self.db_path, False)
        try:
            con.execute("pragma journal_mode=WAL")
            con.execute("pragma synchronous=FULL")
            con.execute("begin immediate")
            yield con
            con.commit()
        except Exception:
            con.rollback()
            raise
        finally:
            con.close()

    def batch_by_sha(self, source_file_sha256):
        con = connect(self.db_path, True)
        try:
            r = con.execute("select * from source_batches where source_file_sha256=?", (source_file_sha256.lower(),)).fetchone()
            return dict(r) if r else None
        finally:
            con.close()

    def product(self, product_id):
        con = connect(self.db_path, True)
        try:
            r = con.execute("""select p.*, b.platform,b.source_file_sha256,b.capture_status
                               from source_products p join source_batches b using(source_batch_id)
                               where p.product_id=? order by b.imported_at desc, p.source_batch_id desc limit 1""",
                            (str(product_id),)).fetchone()
            return dict(r) if r else None
        finally:
            con.close()

    def variants(self, product_id):
        con = connect(self.db_path, True)
        try:
            return [dict(r) for r in con.execute(
                "select * from source_variants where product_id=? order by variation_name, option_index, variant_identity_key",
                (str(product_id),)).fetchall()]
        finally:
            con.close()

    def images(self, product_id):
        con = connect(self.db_path, True)
        try:
            return [dict(r) for r in con.execute(
                "select * from source_images where product_id=? order by cast(image_sequence as integer), image_identity_key",
                (str(product_id),)).fetchall()]
        finally:
            con.close()

    def integrity(self):
        con = connect(self.db_path, True)
        try:
            check = con.execute("pragma integrity_check").fetchone()[0]
            fk = con.execute("pragma foreign_key_check").fetchall()
            return {"integrity_check": check, "foreign_key_errors": len(fk)}
        finally:
            con.close()
