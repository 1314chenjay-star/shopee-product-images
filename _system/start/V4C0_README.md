# TinySnow V4-C0 development note

Goal: sports-first, all-category-safe product image preprocessing.

V4-C0 is a free-analysis layer that runs before paid image generation.
It must not call the image API.

Flow:
Shopee product + source analysis
-> product evidence
-> category route
-> per-image PRESERVE / LOCALIZE / EDIT / REBUILD / BLOCK decision
-> adaptive five-image plan
-> allow or block entry to paid V4-B generation.

Priority policy:
- Sports categories receive deeper routing/risk fields first.
- Other categories receive conservative universal fallback rules.
- Unknown or sparse products require human review before paid generation.
- Unverified facts are never promoted into image claims.
