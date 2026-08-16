$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B012 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b011_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b012_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B012') 'batch must be B012.'
Assert-True ($summary.touched_product_count -eq 12) 'B012 must touch twelve products.'
Assert-True ($summary.complete_product_count -eq 12) 'B012 must complete all twelve touched products.'
Assert-True ($summary.partial_product_count -eq 0) 'B012 must end with no partial product.'
Assert-True ($summary.reviewed_source_image_count -eq 53) 'B012 cumulative accounting must include three carried B011 sources.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B012 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 3) 'B012 must carry exactly three B011 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 2) 'B012 must have exactly two edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 10) 'B012 must have ten complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B012 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B012 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B011/B012 chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 3) 'B012 chain must verify all three carried cue sources.'

$cueCarry = Get-V4CSemanticProductGate $current '29445502432'
Assert-True ($cueCarry.product_review_complete -eq $true) '29445502432 must become complete in B012.'
Assert-True ($cueCarry.reviewed_source_image_count -eq 4) '29445502432 must account for all four sources.'
Assert-True ($cueCarry.newly_reviewed_source_image_count -eq 1) '29445502432 must add one B012 source.'
Assert-True ($cueCarry.carried_forward_source_image_count -eq 3) '29445502432 must carry three B011 sources.'
Assert-True ($cueCarry.can_enter_v4b -eq $false) '29445502432 must remain blocked after full review.'
Assert-True ($cueCarry.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') '29445502432 must require 12-option mapping.'
Assert-True ((@($cueCarry.variant_constraints) -join ' ') -match 'full_four_source_set_still_does_not_map') 'full four-source set must preserve unresolved 12-option mapping.'

$poncho = Get-V4CSemanticProductGate $current '29545502432'
Assert-True ($poncho.can_enter_v4b -eq $false) 'mixed poncho/towel listing must stay blocked.'
Assert-True ($poncho.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_VARIANT_MAPPING_REQUIRED') 'poncho/towel listing must use source-catalog conflict block.'
Assert-True ((@($poncho.variant_constraints) -join ' ') -match 'plain_160x80_bath_towel') 'plain bath-towel variant must remain unresolved.'
Assert-True ((@($poncho.blocked_claim_keys) -join ' ') -match 'UPF50_plus_claim') 'UPF50+ claim must remain unverified.'

$waterBag = Get-V4CSemanticProductGate $current '40133358175'
Assert-True ($waterBag.can_enter_v4b -eq $false) 'IPX7/splash-resistant mixed bag listing must stay blocked.'
Assert-True ((@($waterBag.variant_constraints) -join ' ') -match 'IPX7_vs_splash_resistant') 'IPX7 and splash-resistant options must remain isolated.'
Assert-True ((@($waterBag.blocked_claim_keys) -join ' ') -match 'waterproof_certification_badge') 'waterproof certification badge must not be trusted from image copy.'

$sleep = Get-V4CSemanticProductGate $current '40533379329'
Assert-True ($sleep.can_enter_v4b -eq $false) 'sleeping-bag size/model listing must stay blocked.'
Assert-True ((@($sleep.variant_constraints) -join ' ') -match 'LW180_and_LW180_XL') 'LW180 model mapping must remain unresolved.'
Assert-True ((@($sleep.blocked_claim_keys) -join ' ') -match '15C_comfort_temperature_claim') '15C comfort temperature must remain unverified.'

$hammock = Get-V4CSemanticProductGate $current '40633379386'
Assert-True ($hammock.can_enter_v4b -eq $false) 'hammock listing with corrupted dimensions and safety claims must stay blocked.'
Assert-True ($hammock.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS_AND_VARIANT_MAPPING_REQUIRED') 'hammock must use high-risk + mapping block.'
Assert-True ((@($hammock.blocked_claim_keys) -join ' ') -match 'formaldehyde_free_safety_claim') 'formaldehyde-free safety claim must remain blocked.'
Assert-True ((@($hammock.variant_constraints) -join ' ') -match 'corrupted_dimension_text') 'corrupted dimensions must never be guessed.'

$block = Get-V4CSemanticProductGate $current '41483344137'
Assert-True ($block.can_enter_v4b -eq $true) 'color-only yoga block may enter edit-only handoff.'
Assert-True ($block.semantic_verdict -eq 'PASS_EDIT_ONLY') 'yoga block must be edit-only.'
Assert-True ($block.allowed_generation_mode -eq 'EDIT_PRESERVE_LOCALIZE') 'yoga block must stay in edit/preserve/localize mode.'
Assert-True ((@($block.blocked_claim_keys) -join ' ') -match 'flat_foot_correction_claim') 'flat-foot correction claim must be removed.'
Assert-True ((@($block.variant_constraints) -join ' ') -match 'six_catalog_options_are_color_only') 'six color variants must remain source-bound.'

$racket = Get-V4CSemanticProductGate $current '41533381665'
Assert-True ($racket.can_enter_v4b -eq $true) 'five visually covered squash-racket colors may enter edit-only handoff.'
Assert-True ($racket.semantic_verdict -eq 'PASS_EDIT_ONLY') 'squash racket must be edit-only.'
Assert-True ((@($racket.blocked_claim_keys) -join ' ') -match 'full_carbon_fiber_material') 'carbon-fiber material must remain unverified.'
Assert-True ((@($racket.variant_constraints) -join ' ') -match 'five_catalog_options_are_color_only') 'five colors must remain isolated.'

foreach ($id in @('42283370451','42383370437','42683412886','43483370415','43533353179')) {
    $g = Get-V4CSemanticProductGate $current $id
    Assert-True ($g.can_enter_v4b -eq $false) ('product must stay blocked: ' + $id)
}

$paddle = Get-V4CSemanticProductGate $current '42283370451'
Assert-True ((@($paddle.variant_constraints) -join ' ') -match 'four_sources_show_blue_paddle_family_only') 'non-blue paddle variants must remain unresolved.'
Assert-True ((@($paddle.blocked_claim_keys) -join ' ') -match 'does_not_sink_claim') 'does-not-sink claim must remain blocked.'

$leash = Get-V4CSemanticProductGate $current '42383370437'
Assert-True ((@($leash.variant_constraints) -join ' ') -match 'JB_BG_branded_versions') 'JB/BG variants must remain unmapped.'
Assert-True ((@($leash.blocked_claim_keys) -join ' ') -match 'anti_loss_safety_claim') 'anti-loss safety claim must remain blocked.'

$pickle = Get-V4CSemanticProductGate $current '42683412886'
Assert-True ((@($pickle.variant_constraints) -join ' ') -match 'twenty_seven_catalog_options') '27-model pickleball complexity must remain explicit.'
Assert-True ((@($pickle.blocked_claim_keys) -join ' ') -match 'USAPA_certification_claim') 'USAPA certification claim must remain unverified.'

$cue = Get-V4CSemanticProductGate $current '43483370415'
Assert-True ((@($cue.variant_constraints) -join ' ') -match 'qinglin_meishi_and_yinghua') 'three named cue variants must remain unmapped.'
Assert-True ((@($cue.blocked_claim_keys) -join ' ') -match 'white_ash_fore_end_material') 'cue material must remain unverified.'

$posture = Get-V4CSemanticProductGate $current '43533353179'
Assert-True ($posture.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS_AND_VARIANT_MAPPING_REQUIRED') 'posture device must use high-risk + mapping block.'
Assert-True ((@($posture.blocked_claim_keys) -join ' ') -match 'spine_correction_claim') 'spine-correction claim must be blocked.'
Assert-True ((@($posture.blocked_claim_keys) -join ' ') -match 'back_pain_relief_claim') 'pain-relief claim must be blocked.'
Assert-True ((@($posture.variant_constraints) -join ' ') -match 'basic_lock') 'self-lock and basic-lock structures must remain isolated.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

Write-Host 'V4-C0 B012 semantic gate smoke: PASS'
