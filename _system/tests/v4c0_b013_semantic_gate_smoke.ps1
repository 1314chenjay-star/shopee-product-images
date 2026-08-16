$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B013 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b012_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b013_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B013') 'batch must be B013.'
Assert-True ($summary.touched_product_count -eq 13) 'B013 must touch thirteen products.'
Assert-True ($summary.complete_product_count -eq 12) 'B013 must complete twelve products.'
Assert-True ($summary.partial_product_count -eq 1) 'B013 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 50) 'B013 must account for exactly fifty reviewed source images.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B013 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 0) 'B013 must carry zero sources because B012 ended clean.'
Assert-True ($summary.complete_pass_edit_only_count -eq 4) 'B013 must have four edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 8) 'B013 must have eight complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B013 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B013 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B012/B013 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 0) 'B013 chain must not invent carry-forward images.'

foreach ($id in @('44033353178','44615610572','44915603348','45615609637')) {
    $g = Get-V4CSemanticProductGate $current $id
    Assert-True ($g.can_enter_v4b -eq $true) ('edit-only product should enter V4-B handoff: ' + $id)
    Assert-True ($g.semantic_verdict -eq 'PASS_EDIT_ONLY') ('pass product must be PASS_EDIT_ONLY: ' + $id)
    Assert-True ($g.allowed_generation_mode -eq 'EDIT_PRESERVE_LOCALIZE') ('pass product must stay edit/preserve/localize: ' + $id)
}

$ring = Get-V4CSemanticProductGate $current '44033353178'
Assert-True ((@($ring.blocked_claim_keys) -join ' ') -match 'fiberglass_core_material') 'Pilates ring fiberglass core must stay unverified.'
Assert-True ((@($ring.variant_constraints) -join ' ') -match 'purple_catalog_color_is_not_visually_resolved') 'unseen purple ring color must remain source-bound.'

$ball = Get-V4CSemanticProductGate $current '44233348249'
Assert-True ($ball.can_enter_v4b -eq $false) 'mixed thickened/regular fitness-ball listing must stay blocked.'
Assert-True ($ball.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_VARIANT_MAPPING_REQUIRED') 'fitness ball must use source-catalog conflict block.'
Assert-True ((@($ball.blocked_claim_keys) -join ' ') -match 'anti_burst_safety_claim') 'anti-burst safety claim must remain blocked.'
Assert-True ((@($ball.blocked_claim_keys) -join ' ') -match 'buy_one_get_six_promotion') 'buy-one-get-six promotion must be removed.'
Assert-True ((@($ball.variant_constraints) -join ' ') -match '55cm_65cm_75cm') 'unmapped ball sizes must remain explicit.'

$hanging = Get-V4CSemanticProductGate $current '44515573337'
Assert-True ($hanging.can_enter_v4b -eq $false) 'load-bearing hanging trainer must stay blocked.'
Assert-True ($hanging.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS_AND_VARIANT_MAPPING_REQUIRED') 'hanging trainer must use high-risk + mapping block.'
Assert-True ((@($hanging.blocked_claim_keys) -join ' ') -match '758_jin_load_claim') '758-jin load claim must remain blocked.'
Assert-True ((@($hanging.variant_constraints) -join ' ') -match 'plain_set_pull') 'plain/set/pull configurations must remain unresolved.'

$mat = Get-V4CSemanticProductGate $current '44615610572'
Assert-True ((@($mat.blocked_claim_keys) -join ' ') -match '99_9_percent_antibacterial_claim') '99.9% antibacterial claim must be removed.'
Assert-True ((@($mat.blocked_claim_keys) -join ' ') -match 'authoritative_antibacterial_test_claim') 'image-stated antibacterial testing must not count as verification.'
Assert-True ((@($mat.variant_constraints) -join ' ') -match 'five_color_families') 'folding mat color mapping must remain source-specific.'

$wood = Get-V4CSemanticProductGate $current '44715603381'
Assert-True ($wood.can_enter_v4b -eq $false) '12-structure wooden stretch board listing must stay blocked.'
Assert-True ((@($wood.variant_constraints) -join ' ') -match 'twelve_catalog_options') '12 structural variants must remain explicit.'
Assert-True ((@($wood.blocked_claim_keys) -join ' ') -match 'correction_claim') 'correction claim must remain blocked.'

$simpleBoard = Get-V4CSemanticProductGate $current '44915603348'
Assert-True ((@($simpleBoard.blocked_claim_keys) -join ' ') -match 'rehabilitation_claim') 'rehabilitation claim must be removed from the single-option board.'
Assert-True ((@($simpleBoard.variant_constraints) -join ' ') -match 'single_catalog_option') 'single-option board must remain structurally simple.'

$roller = Get-V4CSemanticProductGate $current '45265569613'
Assert-True ($roller.can_enter_v4b -eq $false) 'foam-roller listing with staged three-device set must stay blocked.'
Assert-True ($roller.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_AND_BUNDLE_VERIFICATION_REQUIRED') 'foam roller must use bundle verification block.'
Assert-True ((@($roller.blocked_claim_keys) -join ' ') -match 'three_piece_bundle_commonality') 'three-piece bundle must not be inferred.'
Assert-True ((@($roller.variant_constraints) -join ' ') -match 'three_product leg_massage kit') 'source/title identity mismatch must remain explicit.'

$pulldown = Get-V4CSemanticProductGate $current '45515572777'
Assert-True ($pulldown.can_enter_v4b -eq $false) '14-option pulldown trainer must stay blocked.'
Assert-True ((@($pulldown.variant_constraints) -join ' ') -match 'fourteen_catalog_options') 'rope-count variants must remain explicit.'
Assert-True ((@($pulldown.blocked_claim_keys) -join ' ') -match '100_jin_max_resistance_claim') '100-jin resistance claim must remain blocked.'
Assert-True ((@($pulldown.blocked_claim_keys) -join ' ') -match 'eleven_piece_bundle_commonality') '11-piece bundle must remain unverified.'

$glove = Get-V4CSemanticProductGate $current '45615609637'
Assert-True ((@($glove.blocked_claim_keys) -join ' ') -match 'puncture_resistance_claim') 'puncture resistance must be stripped in edit-only handoff.'
Assert-True ((@($glove.blocked_claim_keys) -join ' ') -match 'waterproof_claim') 'waterproof claim must remain unverified.'
Assert-True ((@($glove.variant_constraints) -join ' ') -match 'single_catalog_option') 'single glove structure must remain source-bound.'

$squashBall = Get-V4CSemanticProductGate $current '45615672409'
Assert-True ($squashBall.can_enter_v4b -eq $false) 'OLIVER/PRO90 squash-ball source set must stay blocked.'
Assert-True ($squashBall.semantic_verdict -eq 'BLOCK_BRAND_RIGHTS_AND_SOURCE_CATALOG_CONFLICT_REQUIRED') 'squash ball must use brand/source conflict block.'
Assert-True ((@($squashBall.blocked_claim_keys) -join ' ') -match 'OLIVER_brand_authenticity') 'OLIVER authenticity/rights must remain explicit.'
Assert-True ((@($squashBall.variant_constraints) -join ' ') -match 'black_and_white_only') 'black/white catalog vs dot-speed source conflict must remain explicit.'

$shorts = Get-V4CSemanticProductGate $current '45665612353'
Assert-True ($shorts.can_enter_v4b -eq $false) 'single-vs-pair pocket shorts listing must stay blocked.'
Assert-True ((@($shorts.variant_constraints) -join ' ') -match 'two_piece_color_pair_bundles') 'two-piece pair quantities must remain unresolved.'
Assert-True ((@($shorts.blocked_claim_keys) -join ' ') -match 'polyamide_fiber_80_90_percent_material') 'material percentage must remain unverified.'

$racket = Get-V4CSemanticProductGate $current '45715672492'
Assert-True ($racket.can_enter_v4b -eq $false) 'TOUR171 source vs 170/180/181/182 catalog conflict must stay blocked.'
Assert-True ($racket.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_CONFLICT_BRAND_AND_VARIANT_MAPPING_REQUIRED') 'squash racket must use source/model/brand block.'
Assert-True ((@($racket.variant_constraints) -join ' ') -match 'TOUR171') 'TOUR171 conflict must remain explicit.'
Assert-True ((@($racket.blocked_claim_keys) -join ' ') -match 'five_piece_bundle_commonality') 'five-piece racket bundle must not be inferred.'

$partial = Get-V4CSemanticProductGate $current '45915572741'
Assert-True ($partial.product_review_complete -eq $false) '45915572741 must remain incomplete at B013 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 2) '45915572741 must have two reviewed sources in B013.'
Assert-True ($partial.total_source_image_count -eq 4) '45915572741 total source count must remain four.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '45915572741 must use partial-source block.'
Assert-True ($partial.can_enter_v4b -eq $false) '45915572741 may not enter V4-B before B014.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'remaining_two_source_images_in_B014') '45915572741 must explicitly request its final B014 sources.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 2/4 mat sources may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '45915572741' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 13
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 45915572741 at 2/4 sources.'

Write-Host 'V4-C0 B013 semantic gate smoke: PASS'
