$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B009 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b008_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b009_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B009') 'batch must be B009.'
Assert-True ($summary.touched_product_count -eq 8) 'B009 must touch eight products.'
Assert-True ($summary.complete_product_count -eq 7) 'B009 must have seven complete products.'
Assert-True ($summary.partial_product_count -eq 1) 'B009 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 56) 'B009 cumulative accounting must be fifty-six with six carried sources.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B009 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 6) 'B009 must carry exactly six B008 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 0) 'B009 must not pass any complete product to edit-only.'
Assert-True ($summary.complete_blocked_count -eq 7) 'B009 must have seven complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B009 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B009 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B008/B009 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 6) 'B009 chain must verify exactly six carried sources.'

$balls = Get-V4CSemanticProductGate $current '57515658363'
Assert-True ($balls.product_review_complete -eq $true) '57515658363 must become complete in B009.'
Assert-True ($balls.reviewed_source_image_count -eq 9) '57515658363 must account for all nine sources.'
Assert-True ($balls.newly_reviewed_source_image_count -eq 3) '57515658363 must add three B009 sources.'
Assert-True ($balls.carried_forward_source_image_count -eq 6) '57515658363 must carry six B008 sources.'
Assert-True ($balls.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_VARIANT_MAPPING_REQUIRED') '57515658363 must remain blocked after full source review.'
Assert-True ($balls.can_enter_v4b -eq $false) '57515658363 may not enter V4-B while hard/soft/size/quantity mapping is unresolved.'
Assert-True ((@($balls.variant_constraints) -join ' ') -match '11_inch_softball_catalog_variant_remains') '11-inch softball source gap must remain explicit.'
Assert-True ((@($balls.variant_constraints) -join ' ') -match 'hard_vs_soft_ball_identity_is_not_reliably_resolved') 'hard-vs-soft identity must remain unresolved.'
Assert-True ((@($balls.blocked_claim_keys) -join ' ') -match 'synthetic_cover_material') 'visible synthetic-cover material claim must remain unverified.'
Assert-True ((@($balls.blocked_claim_keys) -join ' ') -match 'split_leather_material') 'visible split-leather material claim must remain unverified.'

$jewelryProduct = Get-V4CSemanticReviewProduct $current '57615741194'
Assert-True ([string]$jewelryProduct.route -eq 'jewelry/jewelry') 'basketball-star necklace listing must route by jewelry product body.'
$jewelry = Get-V4CSemanticProductGate $current '57615741194'
Assert-True ($jewelry.can_enter_v4b -eq $false) 'NBA/player-themed jewelry must stay blocked.'
Assert-True ($jewelry.semantic_verdict -eq 'BLOCK_IP_RIGHTS_AND_VARIANT_MAPPING_REQUIRED') 'basketball-star jewelry must require IP rights and bundle mapping.'
Assert-True ((@($jewelry.blocked_claim_keys) -join ' ') -match 'nba_mark_or_brand_rights') 'NBA-related rights must be verified.'
Assert-True ((@($jewelry.blocked_claim_keys) -join ' ') -match 'stephen_curry_rights') 'named-player rights must be explicitly blocked.'
Assert-True ((@($jewelry.variant_constraints) -join ' ') -match 'five_catalog_options_mix_necklace') 'five jewelry bundle configurations must remain isolated.'
Assert-True ((@($jewelry.variant_constraints) -join ' ') -match 'sports_context_does_not_change_primary_product_body_from_jewelry') 'sports wording must not steal jewelry routing.'

$tape = Get-V4CSemanticProductGate $current '27395531774'
Assert-True ($tape.can_enter_v4b -eq $false) 'finger protection tape must stay blocked on protection claims and option levels.'
Assert-True ($tape.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS_AND_VARIANT_MAPPING_REQUIRED') 'finger tape must use combined high-risk/mapping verdict.'
Assert-True ((@($tape.blocked_claim_keys) -join ' ') -match 'finger_injury_prevention_claim') 'finger-injury prevention claim must remain blocked.'
Assert-True ((@($tape.blocked_claim_keys) -join ' ') -match 'waterproof_claim') 'waterproof claim must remain unverified.'
Assert-True ((@($tape.variant_constraints) -join ' ') -match 'light_daily_medium_sport_and_heavy_combat_levels') 'light/medium/heavy catalog levels must not be treated as measured protection ratings.'

$mma = Get-V4CSemanticProductGate $current '28095515598'
Assert-True ($mma.can_enter_v4b -eq $false) 'MMA glove listing must stay blocked.'
Assert-True ($mma.semantic_verdict -eq 'BLOCK_IP_RIGHTS_AND_VARIANT_MAPPING_REQUIRED') 'MMA gloves must require rights and mapping.'
Assert-True ((@($mma.blocked_claim_keys) -join ' ') -match 'UFC_mark_rights') 'UFC rights must be verified.'
Assert-True ((@($mma.blocked_claim_keys) -join ' ') -match '45cm_wrist_length_claim') '45cm wrist-length claim must remain unverified.'
Assert-True ((@($mma.variant_constraints) -join ' ') -match 'seventeen_catalog_options') '17-option complexity must remain explicit.'
Assert-True ((@($mma.variant_constraints) -join ' ') -match 'very_young_child_option') 'very-young-child option must not inherit adult source fit.'

$wraps = Get-V4CSemanticProductGate $current '41883399860'
Assert-True ($wraps.can_enter_v4b -eq $false) 'UFC/VENUM-marked wraps must stay blocked until rights are verified.'
Assert-True ($wraps.semantic_verdict -eq 'BLOCK_IP_RIGHTS_VERIFICATION_REQUIRED') 'wraps must use IP-rights verification verdict.'
Assert-True ((@($wraps.blocked_claim_keys) -join ' ') -match 'UFC_VENUM_collaboration_or_official_product_implication') 'UFC/VENUM collaboration implication must remain blocked.'
Assert-True ((@($wraps.blocked_claim_keys) -join ' ') -match 'human_athlete_image_rights') 'human fighter image rights must be verified.'
Assert-True ((@($wraps.variant_constraints) -join ' ') -match 'black_and_white_5m_elastic_wraps') 'black/white catalog mapping may be noted without authorizing claims.'

$knee = Get-V4CSemanticProductGate $current '42233435403'
Assert-True ($knee.can_enter_v4b -eq $false) 'ASICS-marked knee pads must stay blocked.'
Assert-True ($knee.semantic_verdict -eq 'BLOCK_BRAND_RIGHTS_AND_VARIANT_MAPPING_REQUIRED') 'knee pads must require brand rights and option mapping.'
Assert-True ((@($knee.blocked_claim_keys) -join ' ') -match 'ASICS_trademark_and_product_rights') 'ASICS rights must be verified.'
Assert-True ((@($knee.blocked_claim_keys) -join ' ') -match 'impact_protection_claim') 'impact-protection claim must remain blocked.'
Assert-True ((@($knee.variant_constraints) -join ' ') -match 'historical_high_risk_generated_outputs_remain_locked') 'historical high-risk generated output must remain locked.'

$brush = Get-V4CSemanticProductGate $current '42283370452'
Assert-True ($brush.can_enter_v4b -eq $false) '23-option billiard brush listing must stay blocked.'
Assert-True ($brush.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'billiard brush must require variant mapping.'
Assert-True ((@($brush.variant_constraints) -join ' ') -match 'twenty_three_catalog_options') '23-option brush complexity must remain explicit.'
Assert-True ((@($brush.blocked_claim_keys) -join ' ') -match 'horsehair_material') 'horsehair material must remain unverified.'
Assert-True ((@($brush.variant_constraints) -join ' ') -match 'single_brush_and_combo_set_options_are_not_mapped') 'single-vs-combo brush quantity must remain unresolved.'

$partial = Get-V4CSemanticProductGate $current '42483370431'
Assert-True ($partial.product_review_complete -eq $false) '42483370431 must remain incomplete at the B009 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 1) '42483370431 must have only one of four sources reviewed in B009.'
Assert-True ($partial.total_source_image_count -eq 4) '42483370431 total source count must remain four.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '42483370431 must use partial-source block before B010.'
Assert-True ($partial.can_enter_v4b -eq $false) '42483370431 may not enter V4-B before B010.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'remaining_three_source_images_in_B010') '42483370431 must explicitly request its final three B010 sources.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 1/4 rest-stick sources may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '42483370431' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 8
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 42483370431 at 1/4 sources.'

Write-Host 'V4-C0 B009 semantic gate smoke: PASS'