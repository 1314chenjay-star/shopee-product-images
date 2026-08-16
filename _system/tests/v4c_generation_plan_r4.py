#!/usr/bin/env python3
"""V4-C4.0 planner wrapper r4.

Fixes only the new-stage representative Canary wrapper recursion. It preserves
all r3 reconciliation behavior and does not rerun or alter any frozen V4-C
stage. Known variant fixture IDs are used only to choose a representative
Canary product; they never add generation-safe facts.
"""
import v4c_generation_plan as core
import v4c_generation_plan_r3 as r3

# Capture untouched core functions once, before any temporary monkey-patching.
ORIGINAL_FEATURES_FOR_PRODUCT = core.features_for_product
ORIGINAL_SELECT_CANARY = core.select_canary
ORIGINAL_CANARY = core.canary

FROZEN_VARIANT_PRODUCTS = {'52915734564','58015741169'}


def feature_r4(pid, items, plan, taxonomy):
    f = ORIGINAL_FEATURES_FOR_PRODUCT(pid, items, plan, taxonomy)
    if pid in FROZEN_VARIANT_PRODUCTS:
        f['variant_product'] = True
        f['variant_evidence_reference'] = (
            'frozen V4-A.3/V4-B variant test fixture used only for Canary '
            'representativeness; never copied into generation-safe facts'
        )
    return f


def select_canary_r4(base_state, n=25):
    old_feature = core.features_for_product
    core.features_for_product = feature_r4
    try:
        return ORIGINAL_SELECT_CANARY(base_state, n)
    finally:
        core.features_for_product = old_feature


def canary_r4(args):
    old_select = core.select_canary
    core.select_canary = select_canary_r4
    try:
        return ORIGINAL_CANARY(args)
    finally:
        core.select_canary = old_select


if __name__ == '__main__':
    core.prepare = r3.prepare_r3
    core.canary = canary_r4
    core.main()
