$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B014 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b013_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b014_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B014') 'batch must be B014.'
Assert-True ($summary.touched_product_count -eq 12) 'B014 must touch twelve products.'
Assert-True ($summary.complete_product_count -eq 11) 'B014 must complete eleven products.'
Assert-True ($summary.partial_product_count -eq 1) 'B014 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 52) 'B014 must account for fifty new plus two carried sources.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B014 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 2) 'B014 must carry exactly two B013 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 2) 'B014 must have two edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 9) 'B014 must have nine complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B014 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B014 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B013/B014 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 2) 'B014 chain must verify two carried sources.'

$mat = Get-V4CSemanticProductGate $current '45915572741'
Assert-True ($mat.product_review_complete -eq $true) '45915572741 must complete at 4/4 in B014.'
Assert-True ($mat.reviewed_source_image_count -eq 4) '45915572741 must have four reviewed sources.'
Assert-True ($mat.newly_reviewed_source_image_count -eq 2) '45915572741 must add two B014 sources.'
Assert-True ($mat.carried_forward_source_image_count -eq 2) '45915572741 must carry two B013 sources.'
Assert-True ($mat.can_enter_v4b -eq $true) '45915572741 may enter V4-B edit-only handoff after complete review.'
Assert-True ($mat.semantic_verdict -eq 'PASS_EDIT_ONLY') '45915572741 must be PASS_EDIT_ONLY.'
Assert-True ((@($mat.blocked_claim_keys) -join ' ') -match 'deerskin_velvet_material') 'mat material must remain unverified.'
Assert-True ((@($mat.blocked_claim_keys) -join ' ') -match 'noise_reduction_claim') 'noise reduction must remain unverified.'
Assert-True ((@($mat.blocked_claim_keys) -join ' ') -match 'surface_JUMP_mark_authenticity') 'JUMP surface mark authenticity must remain unverified.'
Assert-True ((@($mat.variant_constraints) -join ' ') -match 'navy_black_orange_catalog_colors_remain_unseen') 'unseen catalog colors may not be synthesized.'

$cue = Get-V4CSemanticProductGate $current '46965635276'
Assert-True ($cue.can_enter_v4b -eq $true) '46965635276 should enter edit-only handoff.'
Assert-True ($cue.semantic_verdict -eq 'PASS_EDIT_ONLY') '46965635276 must be PASS_EDIT_ONLY.'
Assert-True ((@($cue.blocked_claim_keys) -join ' ') -match 'carbon_material') 'cue carbon material must remain unverified.'
Assert-True ((@($cue.variant_constraints) -join ' ') -match '13mm_11_5mm_10mm') 'source-visible cue tip sizes must remain exact.'

$case = Get-V4CSemanticProductGate $current '46115672530'
Assert-True ($case.can_enter_v4b -eq $false) 'multi-shape ball cases must stay blocked.'
Assert-True ((@($case.variant_constraints) -join ' ') -match 'one_two_three_ball_capacity') 'case capacity mapping must remain unresolved.'
Assert-True ((@($case.blocked_claim_keys) -join ' ') -match 'LECHONG_surface_brand_authenticity') 'LECHONG surface text must not become verified brand.'

$lamp = Get-V4CSemanticProductGate $current '46365638146'
Assert-True ($lamp.can_enter_v4b -eq $false) '3-mode vs 5-mode lantern conflict must stay blocked.'
Assert-True ((@($lamp.variant_constraints) -join ' ') -match 'three_brightness_modes_conflicts_with_source_five_modes') 'lantern mode conflict must remain explicit.'

$cue2 = Get-V4CSemanticProductGate $current '46465635147'
Assert-True ($cue2.can_enter_v4b -eq $false) 'PREQAI vs catalog cue identity must stay blocked.'
Assert-True ((@($cue2.variant_constraints) -join ' ') -match '12_8_11_5_10_5_9_5mm') 'four cue tip-size variants must remain explicit.'

$football = Get-V4CSemanticProductGate $current '46465638190'
Assert-True ($football.can_enter_v4b -eq $false) 'youth-vs-adult football conflict must stay blocked.'
Assert-True ((@($football.variant_constraints) -join ' ') -match 'source_youth_positioning_conflicts_with_catalog_adult') 'football audience conflict must remain explicit.'

$reformer = Get-V4CSemanticProductGate $current '46515609628'
Assert-True ($reformer.can_enter_v4b -eq $false) 'load-bearing Pilates machine must stay blocked.'
Assert-True ((@($reformer.blocked_claim_keys) -join ' ') -match 'load_bearing_stability_claim') 'load-bearing claim must remain blocked.'

$climb = Get-V4CSemanticProductGate $current '46615609572'
Assert-True ($climb.can_enter_v4b -eq $false) 'climbing/high-altitude protective gloves must stay blocked.'
Assert-True ((@($climb.blocked_claim_keys) -join ' ') -match 'high_altitude_work_safety_claim') 'high-altitude safety claim must remain blocked.'

$fold = Get-V4CSemanticProductGate $current '46715572826'
Assert-True ($fold.can_enter_v4b -eq $false) 'folding mat source/catalog pattern-thickness conflict must stay blocked.'
Assert-True ((@($fold.variant_constraints) -join ' ') -match 'catalog_character_pattern_not_resolved') 'unseen character pattern must remain unresolved.'

$fish = Get-V4CSemanticProductGate $current '46915609704'
Assert-True ($fish.can_enter_v4b -eq $false) 'fishing glove brand/safety conflict must stay blocked.'
Assert-True ((@($fish.blocked_claim_keys) -join ' ') -match 'puncture_resistance_claim') 'puncture resistance must remain blocked.'
Assert-True ((@($fish.variant_constraints) -join ' ') -match 'NING_YUN_conflicts') 'source/catalog brand conflict must remain explicit.'

$racket = Get-V4CSemanticProductGate $current '47465669144'
Assert-True ($racket.can_enter_v4b -eq $false) 'squash racket bundle conflict must stay blocked.'
Assert-True ((@($racket.variant_constraints) -join ' ') -match 'catalog_mentions_grip_and_wristband') 'racket bundle mismatch must remain explicit.'

$partial = Get-V4CSemanticProductGate $current '47515718388'
Assert-True ($partial.product_review_complete -eq $false) '47515718388 must remain incomplete at B014 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 8) '47515718388 must have eight reviewed sources in B014.'
Assert-True ($partial.total_source_image_count -eq 9) '47515718388 total source count must remain nine.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '47515718388 must use partial-source block.'
Assert-True ($partial.can_enter_v4b -eq $false) '47515718388 may not enter V4-B before B015.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'sequence_701') '47515718388 must explicitly request sequence 701 in B015.'
Assert-True ((@($partial.variant_constraints) -join ' ') -match 'cartoon_paddle_family_not_catalog_professional') 'source/catalog product identity conflict must remain explicit.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary: 8/9 sources may never be falsely marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '47515718388' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 12
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 47515718388 at 8/9 sources.'

Write-Host 'V4-C0 B014 semantic gate smoke: PASS'
