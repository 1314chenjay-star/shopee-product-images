# TinySnow Generator MVP Contract

## Goal
Convert the validated protected canary flow into a repeatable generation pipeline.

## Pipeline

product_task.json

-> source validation

-> protected region loading

-> generation worker

-> protected region restore

-> deterministic QA

-> artifact/result output

## Task contract

Required fields:

- product_id
- variant_id
- source_image
- generation_mode
- protected_regions

## Output contract

Every job must produce:

- source reference
- generated output reference
- protected output reference
- QA result
- execution metadata

## Safety rules

- No stable mutation
- No automatic paid retry
- No bulk generation before MVP validation
- Protected regions must be restored before promotion
