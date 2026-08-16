$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B006 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b005_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b006_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B006') 'batch must be B006.'
Assert-True ($summary.touched_product_count -eq 8) 'B006 must touch eight products.'
Assert-True ($summary.complete_product_count -eq 7) 'B006 must have seven complete products.'
Assert-True ($summary.partial_product_count -eq 1) 'B006 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 54) 'B006 cumulative accounting must be fifty-four with four carried sources.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B006 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 4) 'B006 must carry exactly four B005 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 2) 'B006 must have two complete edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 5) 'B006 must have five complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B006 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B006 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B005/B006 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 4) 'B006 chain must verify exactly four carried sources.'

$glove = Get-V4CSemanticProductGate $current '48165674449'
Assert-True ($glove.product_review_complete -eq $true) '481 must become complete in B006.'
Assert-True ($glove.reviewed_source_image_count -eq 8) '481 must account for all eight sources.'
Assert-True ($glove.newly_reviewed_source_image_count -eq 4) '481 must add four B006 sources.'
Assert-True ($glove.carried_forward_source_image_count -eq 4) '481 must carry four B005 sources.'
Assert-True ($glove.can_enter_v4b -eq $true) '481 may enter edit-only handoff after full source review.'
Assert-True ((@($glove.blocked_claim_keys) -join ' ') -match 'silicone_anti_slip_material') '481 material must remain unverified.'
Assert-True ((@($glove.blocked_claim_keys) -join ' ') -match 'brand_authenticity_beyond_visible_boodun_marking') '481 brand authenticity must remain blocked beyond visible source marking.'

$multiGlove = Get-V4CSemanticProductGate $current '48465674451'
Assert-True ($multiGlove.can_enter_v4b -eq $false) '18-option sports glove listing must stay blocked.'
Assert-True ($multiGlove.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') '484 must require variant mapping.'
Assert-True ((@($multiGlove.variant_constraints) -join ' ') -match 'eighteen_options') '484 must retain 18-option risk.'

$racket = Get-V4CSemanticProductGate $current '49765714479'
Assert-True ($racket.can_enter_v4b -eq $false) 'mixed 9-star/6-star table-tennis listing must stay blocked.'
Assert-True ($racket.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') '497 must require variant mapping.'
Assert-True ((@($racket.blocked_claim_keys) -join ' ') -match 'nano_carbon_material') 'nano-carbon material must not be assumed.'
Assert-True ((@($racket.blocked_claim_keys) -join ' ') -match 'six_ball_gift_bundle') 'gift-ball bundle must not be generalized.'

$jewelryProduct = Get-V4CSemanticReviewProduct $current '49865764122'
Assert-True ([string]$jewelryProduct.route -eq 'jewelry/jewelry') 'basketball-themed necklace must route by jewelry product body.'
$jewelry = Get-V4CSemanticProductGate $current '49865764122'
Assert-True ($jewelry.can_enter_v4b -eq $false) 'NBA/player-themed jewelry must stay blocked until rights are verified.'
Assert-True ($jewelry.semantic_verdict -eq 'BLOCK_IP_RIGHTS_VERIFICATION_REQUIRED') '498 must use IP-rights verification block.'
Assert-True ((@($jewelry.blocked_claim_keys) -join ' ') -match 'nba_mark_or_brand_rights') 'NBA-related rights must be verified.'
Assert-True ((@($jewelry.blocked_claim_keys) -join ' ') -match 'player_likeness_or_endorsement_rights') 'player likeness/endorsement rights must be verified.'

$butterfly = Get-V4CSemanticProductGate $current '50365698867'
Assert-True ($butterfly.can_enter_v4b -eq $false) 'Butterfly/athlete/certification-heavy racket must stay blocked.'
Assert-True ($butterfly.semantic_verdict -eq 'BLOCK_BRAND_CERTIFICATION_VERIFICATION_REQUIRED') '503 must require brand/certification verification.'
Assert-True ((@($butterfly.blocked_claim_keys) -join ' ') -match 'ittf_certification') 'ITTF claim must remain blocked.'
Assert-True ((@($butterfly.blocked_claim_keys) -join ' ') -match 'named_athlete_surface_text_and_likeness_rights') 'athlete surface-text/likeness rights must be verified.'

$dhs = Get-V4CSemanticProductGate $current '50465698911'
Assert-True ($dhs.can_enter_v4b -eq $false) 'DHS multi-model athlete listing must stay blocked.'
Assert-True ($dhs.semantic_verdict -eq 'BLOCK_BRAND_CERTIFICATION_VERIFICATION_REQUIRED') '504 must require brand/certification verification.'
Assert-True ((@($dhs.blocked_claim_keys) -join ' ') -match 'dhs_brand_authenticity') 'DHS authenticity must be verified.'
Assert-True ((@($dhs.variant_constraints) -join ' ') -match 'sixteen_options') '504 must retain 16-option risk.'

$trainer = Get-V4CSemanticProductGate $current '50515875664'
Assert-True ($trainer.can_enter_v4b -eq $true) 'single-option volleyball trainer may enter edit-only handoff.'
Assert-True ((@($trainer.blocked_claim_keys) -join ' ') -match 'automatic_rebound_performance') 'automatic rebound performance must remain blocked.'
Assert-True ((@($trainer.blocked_claim_keys) -join ' ') -match '18cm_ball_diameter') 'visible dimension copy must not become a verified fact automatically.'

$targetProduct = Get-V4CSemanticReviewProduct $current '50565689852'
Assert-True ([string]$targetProduct.route -eq 'sports/combat_martial_arts') 'kick target must use combat training route, not protective gear.'
$partial = Get-V4CSemanticProductGate $current '50565689852'
Assert-True ($partial.product_review_complete -eq $false) '505656 must remain incomplete at the B006 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 4) '505656 must have only four of seven sources reviewed in B006.'
Assert-True ($partial.total_source_image_count -eq 7) '505656 catalog source count must remain seven.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '505656 must use partial-source block before B007.'
Assert-True ($partial.can_enter_v4b -eq $false) '505656 may not enter V4-B before remaining sources are reviewed.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'remaining_three_source_images_in_B007') '505656 must explicitly request its remaining three B007 sources.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 4/7 kick-target sources may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '50565689852' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 8
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 505656 at 4/7 sources.'

Write-Host 'V4-C0 B006 semantic gate smoke: PASS'