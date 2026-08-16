$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B008 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b007_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b008_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B008') 'batch must be B008.'
Assert-True ($summary.touched_product_count -eq 8) 'B008 must touch eight products.'
Assert-True ($summary.complete_product_count -eq 7) 'B008 must have seven complete products.'
Assert-True ($summary.partial_product_count -eq 1) 'B008 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 58) 'B008 cumulative accounting must be fifty-eight with eight carried sources.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B008 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 8) 'B008 must carry exactly eight B007 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 0) 'B008 must not pass any complete product to edit-only.'
Assert-True ($summary.complete_blocked_count -eq 7) 'B008 must have seven complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B008 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B008 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B007/B008 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 8) 'B008 chain must verify exactly eight carried sources.'

$bag = Get-V4CSemanticProductGate $current '54265715317'
Assert-True ($bag.product_review_complete -eq $true) 'racket bag must become complete in B008.'
Assert-True ($bag.reviewed_source_image_count -eq 9) 'racket bag must account for all nine sources.'
Assert-True ($bag.newly_reviewed_source_image_count -eq 1) 'racket bag must add one B008 source.'
Assert-True ($bag.carried_forward_source_image_count -eq 8) 'racket bag must carry eight B007 sources.'
Assert-True ($bag.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'racket bag must remain blocked after full source review.'
Assert-True ($bag.can_enter_v4b -eq $false) 'racket bag may not enter V4-B while capacity/color mapping is unresolved.'
Assert-True ((@($bag.blocked_claim_keys) -join ' ') -match 'greatspeed_brand_authenticity') 'GreatSpeed authenticity must remain blocked.'
Assert-True ((@($bag.blocked_claim_keys) -join ' ') -match '73cm_length_claim') 'visible 73cm dimension must not become a verified common fact.'
Assert-True ((@($bag.variant_constraints) -join ' ') -match 'does_not_establish_whether_pink_item_is_three_racket_or_six_racket') 'final pink source must not falsely resolve 3-racket vs 6-racket option.'

$joola = Get-V4CSemanticProductGate $current '54465698340'
Assert-True ($joola.can_enter_v4b -eq $false) 'JOOLA/ITTF/event-heavy ball listing must stay blocked.'
Assert-True ($joola.semantic_verdict -eq 'BLOCK_BRAND_CERTIFICATION_AND_VARIANT_MAPPING_REQUIRED') 'JOOLA balls must require brand/certification and bundle mapping.'
Assert-True ((@($joola.blocked_claim_keys) -join ' ') -match 'joola_brand_authenticity') 'JOOLA authenticity must be verified.'
Assert-True ((@($joola.blocked_claim_keys) -join ' ') -match 'ittf_certification_or_approval') 'ITTF approval must be verified.'
Assert-True ((@($joola.blocked_claim_keys) -join ' ') -match 'olympic_or_major_event_designated_ball_claim') 'event-designated-ball claim must stay blocked.'
Assert-True ((@($joola.variant_constraints) -join ' ') -match 'twelve_and_eighteen_ball_catalog_bundles_are_not_separately_mapped') '12/18-ball bundles must remain unresolved.'
Assert-True ((@($joola.variant_constraints) -join ' ') -match 'human_athlete_likenesses') 'athlete image rights must remain reviewable.'

$rackets = Get-V4CSemanticProductGate $current '54465698434'
Assert-True ($rackets.can_enter_v4b -eq $false) 'source/catalog-conflicting racket listing must stay blocked.'
Assert-True ($rackets.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_VARIANT_MAPPING_REQUIRED') 'rackets must use source/catalog conflict verdict.'
Assert-True ((@($rackets.blocked_claim_keys) -join ' ') -match 'five_star_rating') '5-star source claim must remain blocked.'
Assert-True ((@($rackets.variant_constraints) -join ' ') -match 'source_p00_promotes_five_star') '5-star source conflict must be explicit.'
Assert-True ((@($rackets.variant_constraints) -join ' ') -match 'catalog_has_no_five_star_option') 'catalog absence of 5-star option must be explicit.'
Assert-True ((@($rackets.blocked_claim_keys) -join ' ') -match 'racket_case_gift') 'case gift may not be generalized.'

$hand = Get-V4CSemanticProductGate $current '56265688661'
Assert-True ($hand.can_enter_v4b -eq $false) 'boxing hand targets must stay blocked until quantity/orientation mapping.'
Assert-True ($hand.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'hand targets must require variant mapping.'
Assert-True ((@($hand.variant_constraints) -join ' ') -match 'one_piece_vs_two_piece') 'one-vs-two piece mapping must remain unresolved.'
Assert-True ((@($hand.blocked_claim_keys) -join ' ') -match 'high_energy_absorption_claim') 'energy-absorption claim must stay blocked.'
Assert-True ((@($hand.blocked_claim_keys) -join ' ') -match 'surface_MYSECK_brand_authenticity') 'surface brand authenticity must not be assumed.'

$weighted = Get-V4CSemanticProductGate $current '56715658363'
Assert-True ($weighted.can_enter_v4b -eq $false) 'weighted baseball listing must stay blocked on source/catalog conflict.'
Assert-True ($weighted.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_VARIANT_MAPPING_REQUIRED') 'weighted balls must use source/catalog conflict verdict.'
Assert-True ((@($weighted.variant_constraints) -join ' ') -match '12oz_source_variant_is_not_present_in_catalog_options') '12oz source absent from catalog must be retained as a conflict.'
Assert-True ((@($weighted.blocked_claim_keys) -join ' ') -match '12oz_weight') '12oz claim must remain blocked.'
Assert-True ((@($weighted.variant_constraints) -join ' ') -match 'three_ball_catalog_bundles_are_not') 'one-vs-three ball bundles must remain unresolved.'

$gloves = Get-V4CSemanticProductGate $current '57315697658'
Assert-True ($gloves.can_enter_v4b -eq $false) '32-option boxing glove listing must stay blocked.'
Assert-True ($gloves.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'boxing gloves must require variant mapping.'
Assert-True ((@($gloves.variant_constraints) -join ' ') -match 'thirty_two_catalog_options') '32-option complexity must be retained.'
Assert-True ((@($gloves.blocked_claim_keys) -join ' ') -match 'impact_protection_claim') 'impact-protection claim must remain blocked.'
Assert-True ((@($gloves.blocked_claim_keys) -join ' ') -match 'human_model_or_person_image_rights') 'human-image rights must remain reviewable.'

$mouth = Get-V4CSemanticProductGate $current '57365552793'
Assert-True ($mouth.can_enter_v4b -eq $false) 'adult/child mouthguard listing must stay blocked.'
Assert-True ($mouth.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS_AND_VARIANT_MAPPING_REQUIRED') 'mouthguard must use combined high-risk/mapping block.'
Assert-True ((@($mouth.blocked_claim_keys) -join ' ') -match 'mouth_or_tooth_protection_claim') 'mouth/tooth protection claim must stay blocked.'
Assert-True ((@($mouth.blocked_claim_keys) -join ' ') -match 'food_grade_material') 'food-grade material claim must be verified.'
Assert-True ((@($mouth.variant_constraints) -join ' ') -match 'child_clear_variant') 'child-clear variant mapping must remain unresolved.'

$partial = Get-V4CSemanticProductGate $current '57515658363'
Assert-True ($partial.product_review_complete -eq $false) '57515658363 must remain incomplete at the B008 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 6) '57515658363 must have six of nine sources reviewed in B008.'
Assert-True ($partial.total_source_image_count -eq 9) '57515658363 total source count must remain nine.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '57515658363 must use partial-source block before B009.'
Assert-True ($partial.can_enter_v4b -eq $false) '57515658363 may not enter V4-B before B009.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'remaining_three_source_images_in_B009') '57515658363 must explicitly request its final three B009 sources.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 6/9 ball sources may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '57515658363' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 8
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 57515658363 at 6/9 sources.'

Write-Host 'V4-C0 B008 semantic gate smoke: PASS'