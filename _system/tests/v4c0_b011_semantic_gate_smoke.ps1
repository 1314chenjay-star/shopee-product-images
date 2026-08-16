$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B011 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b010_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b011_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B011') 'batch must be B011.'
Assert-True ($summary.touched_product_count -eq 10) 'B011 must touch ten products.'
Assert-True ($summary.complete_product_count -eq 9) 'B011 must have nine complete products.'
Assert-True ($summary.partial_product_count -eq 1) 'B011 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 57) 'B011 cumulative accounting must include seven carried B010 sources.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B011 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 7) 'B011 must carry exactly seven B010 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 2) 'B011 must have exactly two complete edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 7) 'B011 must have seven complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B011 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B011 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B010/B011 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 7) 'B011 chain must verify all seven carried glove sources.'

$glove = Get-V4CSemanticProductGate $current '52315693192'
Assert-True ($glove.product_review_complete -eq $true) '52315693192 must become complete in B011.'
Assert-True ($glove.reviewed_source_image_count -eq 9) '52315693192 must account for all nine sources.'
Assert-True ($glove.newly_reviewed_source_image_count -eq 2) '52315693192 must add two B011 sources.'
Assert-True ($glove.carried_forward_source_image_count -eq 7) '52315693192 must carry seven B010 sources.'
Assert-True ($glove.can_enter_v4b -eq $false) '52315693192 must remain blocked because four catalog colorways are not mapped.'
Assert-True ($glove.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') '52315693192 must use variant mapping block after 9/9 review.'
Assert-True ((@($glove.variant_constraints) -join ' ') -match 'full_nine_source_set_still_does_not_map') 'full source set must explicitly preserve unresolved color mapping.'
Assert-True ((@($glove.blocked_claim_keys) -join ' ') -match 'finger_padding_protection_claim') 'final-source finger protection claim must remain blocked.'

$bag = Get-V4CSemanticProductGate $current '53315594082'
Assert-True ($bag.can_enter_v4b -eq $false) '35-option dry-bag/backpack listing must stay blocked.'
Assert-True ($bag.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_VARIANT_MAPPING_REQUIRED') 'mixed bag bodies must use source-catalog conflict block.'
Assert-True ((@($bag.blocked_claim_keys) -join ' ') -match 'ipx6_waterproof_rating') 'IPX6 must remain unverified.'
Assert-True ((@($bag.blocked_claim_keys) -join ' ') -match '20m_waterproof_claim') '20m waterproof claim must remain unverified.'
Assert-True ((@($bag.variant_constraints) -join ' ') -match 'phone_pouches_roll_top_dry_bags_and_large_backpacks') 'multiple bag bodies must remain explicit.'

$twins = Get-V4CSemanticProductGate $current '54915693067'
Assert-True ($twins.can_enter_v4b -eq $false) 'TWINS-marked wraps must wait for brand-rights verification.'
Assert-True ($twins.semantic_verdict -eq 'BLOCK_BRAND_RIGHTS_VERIFICATION_REQUIRED') 'TWINS-marked wraps must use brand-rights block.'
Assert-True ((@($twins.blocked_claim_keys) -join ' ') -match 'TWINS_SPECIAL_brand_authenticity') 'TWINS authenticity/rights must remain explicit.'
Assert-True ((@($twins.variant_constraints) -join ' ') -match 'six_catalog_options_are_white_black_red_yellow_blue_and_pink') 'all six color options must remain mapped as color-only variants.'

$yoga = Get-V4CSemanticProductGate $current '57215596207'
Assert-True ($yoga.can_enter_v4b -eq $false) 'yoga towel must stay blocked until pattern/size/set mapping is known.'
Assert-True ((@($yoga.variant_constraints) -join ' ') -match 'twenty_catalog_options_mix_plum_and_four_leaf_patterns') '20-option pattern/size complexity must remain explicit.'
Assert-True ((@($yoga.blocked_claim_keys) -join ' ') -match '185x82cm_dimension_commonality') '185x82 visible size must not generalize.'

$ufc = Get-V4CSemanticProductGate $current '57215697684'
Assert-True ($ufc.can_enter_v4b -eq $false) 'UFC-marked gloves must stay blocked.'
Assert-True ($ufc.semantic_verdict -eq 'BLOCK_IP_RIGHTS_AND_VARIANT_MAPPING_REQUIRED') 'UFC gloves must use IP-rights and variant block.'
Assert-True ((@($ufc.blocked_claim_keys) -join ' ') -match 'UFC_mark_rights') 'UFC rights must be verified.'
Assert-True ((@($ufc.blocked_claim_keys) -join ' ') -match '20_wan_bend_no_crack_claim') '20-wan bend durability claim must remain blocked.'

$ankle = Get-V4CSemanticProductGate $current '57465745148'
Assert-True ($ankle.can_enter_v4b -eq $false) 'TMT ankle support must stay blocked.'
Assert-True ((@($ankle.variant_constraints) -join ' ') -match 'left_foot_single_and_one_pair') 'single-vs-pair quantity mapping must remain explicit.'
Assert-True ((@($ankle.blocked_claim_keys) -join ' ') -match 'sprain_prevention_claim') 'sprain prevention claim must remain blocked.'
Assert-True ((@($ankle.blocked_claim_keys) -join ' ') -match '0_9mm_thickness_claim') '0.9mm claim must remain unverified.'

$monghu = Get-V4CSemanticProductGate $current '57915697690'
Assert-True ($monghu.can_enter_v4b -eq $false) 'MONGHU wraps must stay blocked because catalog color-only options do not resolve length.'
Assert-True ($monghu.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_VARIANT_MAPPING_REQUIRED') 'MONGHU wraps must use source-catalog conflict block.'
Assert-True ((@($monghu.variant_constraints) -join ' ') -match 'catalog_variations_do_not_map_length') 'length mismatch must remain explicit.'
Assert-True ((@($monghu.blocked_claim_keys) -join ' ') -match 'price_promotion_claim') 'price promotion must be removed.'

$trainer = Get-V4CSemanticProductGate $current '26795502043'
Assert-True ($trainer.can_enter_v4b -eq $true) 'single-option pink training device may enter edit-only handoff.'
Assert-True ($trainer.semantic_verdict -eq 'PASS_EDIT_ONLY') 'training device must be edit-only.'
Assert-True ($trainer.allowed_generation_mode -eq 'EDIT_PRESERVE_LOCALIZE') 'training device must stay in edit/preserve/localize mode.'
Assert-True ((@($trainer.blocked_claim_keys) -join ' ') -match 'arm_slimming_claim') 'arm slimming claim must be removed.'
Assert-True ((@($trainer.blocked_claim_keys) -join ' ') -match 'non_toxic_safety_claim') 'non-toxic claim must remain unverified.'

$chalk = Get-V4CSemanticProductGate $current '29445502431'
Assert-True ($chalk.can_enter_v4b -eq $true) 'pink/black chalk holder may enter edit-only handoff.'
Assert-True ($chalk.semantic_verdict -eq 'PASS_EDIT_ONLY') 'chalk holder must be edit-only.'
Assert-True ((@($chalk.variant_constraints) -join ' ') -match 'two_catalog_options_are_pink_and_black') 'pink/black variants must remain isolated.'
Assert-True ((@($chalk.blocked_claim_keys) -join ' ') -match 'five_piece_bundle_commonality') 'five-piece bundle must not be generalized.'

$partial = Get-V4CSemanticProductGate $current '29445502432'
Assert-True ($partial.product_review_complete -eq $false) '29445502432 must remain incomplete at the B011 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 3) '29445502432 must have three of four sources reviewed.'
Assert-True ($partial.total_source_image_count -eq 4) '29445502432 total source count must remain four.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '29445502432 must use partial-source block before B012.'
Assert-True ($partial.can_enter_v4b -eq $false) '29445502432 may not enter V4-B before B012.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'remaining_one_source_image_in_B012') '29445502432 must request its final B012 source.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 3/4 cue sources may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '29445502432' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 10
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 29445502432 at 3/4 sources.'

Write-Host 'V4-C0 B011 semantic gate smoke: PASS'
