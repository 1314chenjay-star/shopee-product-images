# TinySnow Rolling Technical Handoff

This public handoff contains technical project state only. Private user/business master context must remain in private storage.

## Current durable checkpoint
- Branch: `v4c-universal-product-engine`
- Captured HEAD: `68b4ad6eb746931b3c35bb5030ec67f45ae66f95`
- Stable expected: `tinysnow-tool-only@5d49f061e140813b3d229520e9e530f86b27b640`
- Latest successful C5.3 checkpoint workflow: `32035192139` — Existing Snapshot Parts Diagnostic Artifact — success.
- Upstream V4-C1 through V4-C5.2 are sealed/frozen; use locks/fingerprints only.

## Permanent execution policy
Read `_system/governance/TINYSNOW_PROJECT_CONSTITUTION.md` and `_system/governance/failure_registry.jsonl` before work.
Use automation-first, fastest-safe-path, delta-only, checkpoint-resume and targeted-repair. Do not rerun sealed stages without regression evidence + affected scope + rerun reason.

## V4-C5.3 existing work to reuse
- Five recovered snapshot transport parts already exist under `_system/source_truth/bootstrap_transport/`.
- Do not re-materialize, re-upload or re-split them.
- `_system/source_truth/source_truth_store.py` already exists and is the reusable SQLite store. Do not redesign/rebuild schema unless a concrete C5.3 test proves a minimal migration is required.
- Existing diagnostic work established deterministic transport fingerprints:
  - 5 parts
  - observed 19,999 characters per part
  - joined Base64 SHA256 `e053cc6c2cac7d774120f3a03b62b07294af6bb9477aa7fd87a188301e814b4c`
  - decoded payload size 74,995 bytes
  - decoded payload SHA256 `86060552697a521b844a989327fa167ca8ff971f273a8a3073e6bca34b0dea6d`
  - representation remains unresolved.
- Multiple unsupported codec probes are not evidence for another blind guess. Use exact bytes/boundaries/provenance and repair only the affected reassembly path.

## V4-C5.3 authoritative targets
Must be proven by actual reconciliation before sealing:
- products = 375
- source image rows = 2394
- variant option rows = 2673
- READY delta scope = 145 products / 549 slots

## Remaining C5.3 delta only
1. Establish deterministic source reconstruction/validation from existing transport/checkpoint.
2. Add reusable Shopee source importer only if still absent.
3. Bootstrap existing SourceTruthStore; no OCR/download/Semantic.
4. Reconcile 375 / 2394 / 2673.
5. Exact option-image bindings only; no inferred single variant.
6. Add SourceTruthResolver with SQLite lazy indexed lookup.
7. Recover only 145 READY / 549-slot variant scope overlay; do not mutate frozen queue/planner/payload.
8. Run C5.3-only synthetic regression tests.
9. Verify frozen fingerprints without rerunning old stages.
10. Persist `V4_C5_3_AUTHORITATIVE_SOURCE_REGISTRY_LOCK.json` only after all gates pass.

## Cost boundary
No paid API, OpenAI API, image generation/editing, Vision, or TinySnow paid API. Do not start Paid Canary.

## Private context
Current environment returned authorization failure when searching Files/Library. Status: `PRIVATE_MASTER_CONTEXT_WRITE_PENDING`. Do not put private user/business history into this public repository and do not block C5.3 because of this.

## Resume behavior
Before each write, fetch branch HEAD. If it advanced, inspect new commits and continue from the latest compatible state. Never force push. A replacement worker should read current_state + this handoff + project constitution + locks + recent workflows, then continue the remaining delta automatically until a paid/generation/stable/high-risk/human-authority boundary is reached.
