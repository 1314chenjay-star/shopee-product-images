# V4-A.3 Codex Handoff — Five-Image Planner

## Read this first

This task must start from the exact tested baseline below. Do not switch to an older workspace or older commit.

- Repository: `1314chenjay-star/shopee-product-images`
- GitHub development/target branch: `v4a3-five-image-planner`
- Exact tested baseline commit: `8dadefecc8041d59c2c9c168b04672dbdc4a1045`
- Handoff commit already on target branch: `c48bc29e654339907a3e776e068c8ccbda28eaf4`
- Baseline build: `V4-A.2.1｜圖片文字穩定修正版`
- Transport: `API-R3-120S`
- Stable branch `tinysnow-tool-only` must remain unchanged.
- V4-A source branch `v4a-layout-diversity` must remain unchanged.
- Do not merge anything.

### Important Codex workspace rule

Codex may create a local temporary working branch named `work` or another internal name. **That local branch name alone is NOT a baseline mismatch.**

Proceed when all of the following are true:

1. `HEAD` is `c48bc29e654339907a3e776e068c8ccbda28eaf4` or a descendant of it created for this task.
2. `8dadefecc8041d59c2c9c168b04672dbdc4a1045` remains an ancestor of `HEAD`.
3. `V2_BUILD.txt` still reports `V4-A.2.1｜圖片文字穩定修正版` and `API-R3-120S` before V4-A.3 versioning changes are intentionally made.
4. `_system/start/api_v2.ps1` SHA-256 is `a27d8107b94c7e5d29aa5e170aea1541f7e95cc6cde6a693556d1d0b0b8bdf0f`.
5. The worktree is clean before implementation begins.
6. Final commits are intended for GitHub branch `v4a3-five-image-planner`; do not merge into stable.

STOP only if the commit ancestry/build/transport/fingerprint/worktree checks fail. Do **not** stop merely because `git branch --show-current` returns `work`.

Before editing, verify and report:

1. `git rev-parse HEAD`
2. current local branch name (informational only)
3. `V2_BUILD.txt`
4. `git status --short --branch`
5. `api_v2.ps1` SHA-256
6. `git merge-base --is-ancestor c48bc29e654339907a3e776e068c8ccbda28eaf4 HEAD`
7. `git merge-base --is-ancestor 8dadefecc8041d59c2c9c168b04672dbdc4a1045 HEAD`

---

# Goal

Build **V4-A.3｜Five-Image Planner 五圖整體規劃版**.

The problem to solve is not a single product bug. The current system can generate individually acceptable images, but a 5-image product set can still repeat the same visual composition too much. Example: main/detail1/detail4 may all reuse a similar hand-held product composition.

V4-A.3 must solve this with a product-agnostic planning system that works for future products without product-ID-specific patches.

Core principle:

> Plan the full 5-image set first, then generate each slot according to that plan. After generation, validate the set as a group and redo only failed slots.

Do not add product-ID hardcoding.

---

# Preserve all passed V4-A.2.1 behavior

Do NOT weaken or replace:

- `API-R3-120S` transport
- VerifiedFacts
- MultiVariantFlags
- factual blacklists / exact text allowlist
- Reference Safety
- Taiwan localization
- image text stability
- loader/runtime overwrite protection
- automatic menu return behavior
- Windows PowerShell 5.1 compatibility

Do not modify `_system/start/api_v2.ps1`. It must remain byte-identical / fingerprint-identical.

---

# New architecture

Implement the following generic layers.

## 1. Reference classifier

Create a generic original-image classifier used before slot assignment.

Recommended module:

`_system/start/reference_classifier_v3.ps1`

Each usable source image should receive one or more semantic/use classes, at minimum:

- `pure_product`
- `detail_structure`
- `usage_scene`
- `spec_info`
- `size_info`
- `accessory`
- `packaging`
- `multi_variant`
- `promo_risky`
- `single_variant_risky`

Do not pretend local OCR/vision is perfect if runtime evidence is insufficient. Use deterministic evidence and existing safe heuristics/proxies. If a class cannot be known confidently, mark it unknown/low confidence instead of inventing certainty.

All usable originals should participate in analysis/scoring, but do not send all originals to TinySnow. Per slot, continue sending only the safest relevant subset, max 1–2 refs consistent with current transport protections.

## 2. Five-Image Planner

Recommended module:

`_system/start/five_image_planner_v3.ps1`

Before any generation, create one plan containing all five output slots.

Every slot plan should include at least:

- `slot`
- `role`
- `content_goal`
- `preferred_reference_classes`
- `blocked_reference_classes`
- `preferred_layout_family`
- `blocked_visual_patterns`
- `must_differ_from_slots`
- `text_priority`
- `verified_fact_priority`
- `reference_candidates`
- `selected_reference_ids/paths`

Slot roles:

### main
- primary conversion / hero image
- product immediately recognizable
- avoid overloading with small detail panels
- normally avoid usage-scene-first composition unless product type requires it

### detail1
- selling-point / visual-detail overview
- should not clone main composition
- prefer alternate angle, macro/detail, or structured overview

### detail2
- structure / product detail / included verified parts / packaging when verified
- local-detail or breakdown layout is preferred when safe
- must not invent names for unlabeled parts

### detail3
- usage / scene / operation reference
- prioritize usage-scene source imagery when available
- for multi-variant products, keep the scene variant-neutral when possible

### detail4
- spec / size / model / buying clarification
- if verified common specs exist, prioritize those
- if there are no common verified specs, use conservative purchase guidance rather than invented specs
- use information-card layout instead of another hero-style product composition

The planner must adapt content to the product; these are roles, not fixed visual templates.

## 3. Slot-aware reference assignment

Replace any remaining behavior equivalent to “take the first one/two originals” with planner-driven selection.

General rules:

- `main`: prefer safe pure-product references
- `detail1`: prefer detail/alternate-angle references
- `detail2`: prefer structure/accessory/packaging references only when verified and safe
- `detail3`: prefer usage-scene references
- `detail4`: prefer verified spec/size/model references
- high multi-variant conflict: do not let a single-variant image define common facts
- do not reuse the same primary reference for multiple slots when safe alternatives exist
- safety always outranks diversity

## 4. Layout memory / visual dedup memory

Recommended module:

`_system/start/layout_memory_v3.ps1`

After each generated slot, persist a compact visual-plan fingerprint. At minimum track:

- `main_subject_type`
- `has_person`
- `dominant_layout_family`
- `product_angle_type`
- `product_position`
- `visual_theme`
- `hand_held_style`
- `primary_reference_source`
- `reference_class`

Before generating the next slot, require meaningful difference from earlier completed slots.

Target rule: later slots should differ from prior images in at least 2 meaningful visual dimensions when doing so does not reduce factual/reference safety.

Do not optimize diversity by selecting a riskier source image.

## 5. Group-level five-image validator

Recommended module:

`_system/start/group_validation_v3.ps1`

Add a validator that evaluates the five-image set as a group, not only each image independently.

Detect at minimum:

- excessive reuse of the same primary reference
- repeated hand-held composition across too many slots
- repeated hero-layout family across too many slots
- too many slots with the same product position/angle
- slot-role mismatch
- detail slot provides no new information compared with main
- repeated spec text across unnecessary slots

Return structured results with at least:

- `passed`
- `failed_slots`
- `reasons_by_slot`
- `group_warnings`
- `retry_priority`

If only one or two slots fail, only those slots may be regenerated. Already-passed slots must remain untouched.

---

# Integration

Prefer adding small modules and wiring them into the existing runtime rather than rewriting the whole pipeline.

Recommended new modules:

- `_system/start/reference_classifier_v3.ps1`
- `_system/start/five_image_planner_v3.ps1`
- `_system/start/layout_memory_v3.ps1`
- `_system/start/group_validation_v3.ps1`

Update loader/self-check/package workflow so these files are included and syntax-checked.

Do not create a parallel fake test-only implementation that the normal `START.bat` path does not load. The real beginner-menu/runtime path must load and use the V4-A.3 planner.

---

# No product-ID special cases

The following product IDs are test fixtures only, never runtime branches:

- `52915734564`
- `58015741169`
- `53615734484`
- `53215734553`
- `57565745174`

Do not write runtime logic like `if ProductId == ...`.

---

# Test strategy — incremental only

The user explicitly does NOT want full regression/live reruns after every small change.

Use targeted tests based on what changed.

## Primary functional test: 52915734564

Purpose: prove five-image visual dedup.

Known regression target:

- main/detail1/detail4 had too much repeated “hand holding blue rolled tape” composition.

Acceptance target:

- five roles are visibly distinct at planning level
- main/detail1/detail4 are not assigned the same primary composition when safe alternatives exist
- detail1/detail4 provide new visual information compared with main

Do not treat decorative icons as a failure condition; user explicitly said those icons do not matter for this issue.

## Primary non-regression test: 58015741169

Must preserve verified display facts:

- `2公尺`
- `30磅`
- `腰帶`
- `黑色`

Must not reintroduce:

- `2米`
- 5-set / five-person implications
- invented materials/dimensions
- invented local part labels in detail2

## Optional targeted samples only when needed

- `53615734484`: multi-variant feature conflict
- `53215734553`: variant-only material conflict
- `57565745174`: model `VZJ-004S` preservation

Do not live-generate all of these unless a change actually touches the relevant logic.

---

# Live API policy

Before using TinySnow quota:

1. PowerShell/static smoke must pass.
2. Planner data structures must be inspectable without image generation.
3. Reference allocation must be inspectable without image generation.
4. Group validator unit/synthetic tests must pass.

Then use the minimum necessary live generations.

Recommended first live gate after implementation:

- `529`: only the slots whose planner assignments changed materially
- `580`: only enough slots to confirm no regression

Do not automatically rerun all 5 products or all 5 slots unless necessary.

---

# Windows / encoding constraints

Preserve existing safeguards:

- executable PowerShell `.ps1` files must remain Windows PowerShell 5.1 safe
- UTF-8 BOM normalization remains in startup/CI flow
- product IDs remain strings
- do not use `$PID`
- no Generic.List dependency if arrays suffice
- no Python runtime dependency for the end user
- no API keys in repo/artifacts/logs
- do not expose repository secret

---

# Completion criteria

V4-A.3 is complete only when:

1. all five slots are planned before generation
2. slot-specific reference assignment is active in the real runtime
3. same primary composition/reference is not unnecessarily repeated across the set
4. safety outranks diversity
5. group-level validator exists and reports failed slots
6. retry path regenerates only failed slots
7. `529` demonstrates improved set-level diversity
8. `580` does not regress
9. V4-A.2.1 factual/Taiwan/text-stability protections remain intact
10. `api_v2.ps1` remains unchanged / R3 fingerprint remains identical
11. Windows smoke passes
12. no merge is performed

---

# Required final report

When done, report:

1. starting baseline SHA
2. final HEAD SHA
3. local branch name and GitHub target branch
4. modified/new file list
5. planner output schema/example
6. reference-classification schema/example
7. group-validator schema/example
8. targeted tests actually run and why
9. targeted tests intentionally not run and why
10. whether live TinySnow was used and exact number of images generated
11. result for 529 regression target
12. result for 580 non-regression target
13. `api_v2.ps1` fingerprint before/after
14. `git status --short --branch`
15. Windows CI result
16. confirmation that no merge occurred

Do not create a final ZIP merely for handoff. Work through GitHub commits targeting `v4a3-five-image-planner`.