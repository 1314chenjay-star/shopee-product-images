#!/usr/bin/env python3
"""V4-C2 semantic worker policy shim.

Keeps the frozen V4-C1 queue immutable. Records with no V4-C1 SHA256 are
BLOCKed without touching the source URL. Records with a V4-C1 SHA use the
local worker and must match that frozen digest before semantic inference.
No image generation, paid vision API, TinySnow API, or source-pipeline rerun.
"""
import re
import v4c_semantic_worker as base

_SHA = re.compile(r"^[a-f0-9]{64}$")
_original_blocked = base.blocked
_original_analyze = base.analyze


def _sha(record):
    value = str(record.get("sha256") or "").lower()
    return value if _SHA.fullmatch(value) else None


def blocked(record, context, reason, byte=None, fetched=False):
    out = _original_blocked(record, context, reason, byte, fetched)
    digest = _sha(record)
    out["sha256"] = digest
    prov = out["provenance"]
    prov["sha256_state"] = "VERIFIED_V4C1" if digest else "MISSING_V4C1"
    prov["semantic_image_fetch"] = bool(fetched)
    prov["source_pipeline_redownload"] = False
    out["flags"]["image_generation_called"] = False
    out["flags"]["tiny_snow_api_called"] = False
    out["flags"]["paid_api_called"] = False
    out["flags"]["vision_api_called"] = False
    out["flags"]["local_model_only"] = True
    return out


def analyze(record, context, cache, models):
    digest = _sha(record)
    if digest is None:
        return blocked(
            record,
            context,
            "V4C1_SHA256_MISSING_NO_REDOWNLOAD",
            byte=None,
            fetched=False,
        )
    out = _original_analyze(record, context, cache, models)
    out["sha256"] = digest
    out["provenance"]["sha256_state"] = "VERIFIED_V4C1"
    out["provenance"]["source_pipeline_redownload"] = False
    return out


# base.main resolves these names from its module globals at runtime.
base.blocked = blocked
base.analyze = analyze

if __name__ == "__main__":
    raise SystemExit(base.main())
