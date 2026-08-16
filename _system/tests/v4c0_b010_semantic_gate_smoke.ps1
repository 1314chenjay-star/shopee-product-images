$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B010 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b009_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b010_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B010') 'batch must be B010.'
Assert-True ($summary.touched_product_count -eq 9) 'B010 must touch nine products.'
Assert-True ($summary.complete_product_count -eq 8) 'B010 must have eight complete products.'
Assert-True ($summary.partial_product_count -eq 1) 'B010 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 51) 'B010 cumulative accounting must be fifty-one with one carried source.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B010 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 1) 'B010 must carry exactly one B009 source.'
Assert-True ($summary.complete_pass_edit_only_count -eq 2) 'B010 must have exactly two complete edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 6) 'B010 must have six complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B010 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B010 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B009/B010 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 1) 'B010 chain must verify exactly one carried source.'

$rest = Get-V4CSemanticProductGate $current '42483370431'
Assert-True ($rest.product_review_complete -eq $true) '42483370431 must become complete in B010.'
Assert-True ($rest.reviewed_source_image_count -eq 4) '42483370431 must account for all four sources.'
Assert-True ($rest.newly_reviewed_source_image_count -eq 3) '42483370431 must add three B010 sources.'
Assert-True ($rest.carried_forward_source_image_count -eq 1) '42483370431 must carry one B009 source.'
Assert-True ($rest.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'rest-stick listing must remain blocked on 24-option mapping.'
Assert-True ($rest.can_enter_v4b -eq $false) 'rest-stick listing may not enter V4-B before rod/head bundle mapping.'
Assert-True ((@($rest.variant_constraints) -join ' ') -match 'rod_only_and_head_only_catalog_configurations') 'rod-only/head-only configurations must remain unresolved.'
Assert-True ((@($rest.blocked_claim_keys) -join ' ') -match 'carbon_fiber_material') 'carbon-fiber material must remain unverified.'

$cue = Get-V4CSemanticProductGate $current '45765626893'
Assert-True ($cue.can_enter_v4b -eq $false) '39-option billiard cue listing must stay blocked.'
Assert-True ($cue.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'billiard cue must require variant mapping.'
Assert-True ((@($cue.variant_constraints) -join ' ') -match 'thirty_nine_catalog_options') '39-option cue complexity must remain explicit.'
Assert-True ((@($cue.blocked_claim_keys) -join ' ') -match '11_5mm_tip_size_commonality') '11.5mm tip size must not be generalized.'
Assert-True ((@($cue.blocked_claim_keys) -join ' ') -match 'cue_case_bag_tube_box_bundle_commonality') 'case/bag/tube/box bundles must remain unverified.'

$shinchan = Get-V4CSemanticProductGate $current '46465569573'
Assert-True ($shinchan.can_enter_v4b -eq $false) 'Crayon Shinchan yoga mat must stay blocked until rights and option mapping are verified.'
Assert-True ($shinchan.semantic_verdict -eq 'BLOCK_IP_RIGHTS_AND_VARIANT_MAPPING_REQUIRED') 'character mat must use IP-rights and mapping verdict.'
Assert-True ((@($shinchan.blocked_claim_keys) -join ' ') -match 'crayon_shinchan_character_rights') 'character artwork rights must be explicit.'
Assert-True ((@($shinchan.blocked_claim_keys) -join ' ') -match 'copyrighted_character_artwork_reuse_rights') 'copyright reuse rights must be explicit.'
Assert-True ((@($shinchan.variant_constraints) -join ' ') -match 'thirty_nine_catalog_options') 'character mat size/design option complexity must remain explicit.'

$wrist = Get-V4CSemanticProductGate $current '48365764158'
Assert-True ($wrist.can_enter_v4b -eq $false) 'TMT-marked youth/adult wrist guards must stay blocked.'
Assert-True ($wrist.semantic_verdict -eq 'BLOCK_BRAND_RIGHTS_HIGH_RISK_CLAIMS_AND_VARIANT_MAPPING_REQUIRED') 'wrist guards must require brand, claim, and variant review.'
Assert-True ((@($wrist.blocked_claim_keys) -join ' ') -match 'child_model_image_rights') 'child model rights must be checked.'
Assert-True ((@($wrist.variant_constraints) -join ' ') -match 'youth_black_youth_pink_youth_blue_and_adult_black') 'youth/adult/color variants must remain isolated.'

$mma = Get-V4CSemanticProductGate $current '50965689797'
Assert-True ($mma.can_enter_v4b -eq $true) 'three visually covered MMA glove variants may enter edit-only handoff.'
Assert-True ($mma.semantic_verdict -eq 'PASS_EDIT_ONLY') '50965689797 must be edit-only, not free generation.'
Assert-True ($mma.allowed_generation_mode -eq 'EDIT_PRESERVE_LOCALIZE') '50965689797 must stay in edit/preserve/localize mode.'
Assert-True ((@($mma.blocked_claim_keys) -join ' ') -match 'five_year_quality_warranty_or_seller_promise') 'seller warranty promise must be removed.'
Assert-True ((@($mma.variant_constraints) -join ' ') -match 'long striped wrist wrap must not be generalized') 'long-wrist structure must not leak to normal variants.'

$mixed = Get-V4CSemanticProductGate $current '51315693106'
Assert-True ($mixed.can_enter_v4b -eq $false) 'glove/foot-guard mixed catalog listing must stay blocked.'
Assert-True ($mixed.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_VARIANT_MAPPING_REQUIRED') 'mixed glove/foot-guard listing must use source-catalog conflict verdict.'
Assert-True ((@($mixed.variant_constraints) -join ' ') -match 'do not show the catalog foot_guard product family') 'missing foot-guard source family must remain explicit.'
Assert-True ((@($mixed.blocked_claim_keys) -join ' ') -match 'returns_compensation_or_after_sales_promise') 'after-sales promise must remain blocked.'

$bootsProduct = Get-V4CSemanticReviewProduct $current '51515600702'
Assert-True ([string]$bootsProduct.route -eq 'sports/water_sports') 'diving boot route must stay water_sports under current router.'
$boots = Get-V4CSemanticProductGate $current '51515600702'
Assert-True ($boots.can_enter_v4b -eq $false) '35-option diving-boot listing must stay blocked.'
Assert-True ($boots.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_VARIANT_MAPPING_REQUIRED') 'diving boots must require model/thickness/size mapping.'
Assert-True ((@($boots.variant_constraints) -join ' ') -match 'one black high_top 5mm boot family') 'source family limitation must remain explicit.'
Assert-True ((@($boots.blocked_claim_keys) -join ' ') -match 'neoprene_material') 'Neoprene material must remain unverified.'

$blanket = Get-V4CSemanticProductGate $current '51715596221'
Assert-True ($blanket.can_enter_v4b -eq $true) 'common-structure yoga blanket may enter edit-only handoff.'
Assert-True ($blanket.semantic_verdict -eq 'PASS_EDIT_ONLY') 'yoga blanket must be edit-only.'
Assert-True ((@($blanket.blocked_claim_keys) -join ' ') -match '200x150cm_dimension_commonality') 'visible 200x150cm dimension must not be generalized.'
Assert-True ((@($blanket.variant_constraints) -join ' ') -match 'thirty_catalog_options_are_color_variants') '30 catalog colors must remain isolated.'

$partial = Get-V4CSemanticProductGate $current '52315693192'
Assert-True ($partial.product_review_complete -eq $false) '52315693192 must remain incomplete at the B010 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 7) '52315693192 must have seven of nine sources reviewed in B010.'
Assert-True ($partial.total_source_image_count -eq 9) '52315693192 total source count must remain nine.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '52315693192 must use partial-source block before B011.'
Assert-True ($partial.can_enter_v4b -eq $false) '52315693192 may not enter V4-B before B011.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'remaining_two_source_images_in_B011') '52315693192 must explicitly request its final two B011 sources.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 7/9 glove sources may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '52315693192' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 9
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 52315693192 at 7/9 sources.'

Write-Host 'V4-C0 B010 semantic gate smoke: PASS'
