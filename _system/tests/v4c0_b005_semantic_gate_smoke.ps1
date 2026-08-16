$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B005 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b004_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b005_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B005') 'batch must be B005.'
Assert-True ($summary.touched_product_count -eq 10) 'B005 must touch ten products.'
Assert-True ($summary.complete_product_count -eq 9) 'B005 must have nine complete products.'
Assert-True ($summary.partial_product_count -eq 1) 'B005 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 53) 'B005 cumulative product accounting must be fifty-three with three carried sources.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B005 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 3) 'B005 must carry exactly three B004 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 2) 'B005 must have two complete edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 7) 'B005 must have seven complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B005 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B005 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B004/B005 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 3) 'B005 chain must verify exactly three carried sources.'

$life = Get-V4CSemanticProductGate $current '46515609644'
Assert-True ($life.product_review_complete -eq $true) '465 must become complete in B005.'
Assert-True ($life.reviewed_source_image_count -eq 4) '465 must account for all four sources.'
Assert-True ($life.newly_reviewed_source_image_count -eq 1) '465 must add one B005 source.'
Assert-True ($life.carried_forward_source_image_count -eq 3) '465 must carry three B004 sources.'
Assert-True ($life.can_enter_v4b -eq $false) 'completed life jacket must still remain blocked on safety evidence.'
Assert-True ($life.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS') 'completed life jacket must become a high-risk block, not a pass.'
Assert-True ((@($life.blocked_claim_keys) -join ' ') -match '220_jin_110kg_load_claim') 'supported-weight claim must remain blocked.'
Assert-True ((@($life.blocked_claim_keys) -join ' ') -match 'safety_certification') 'safety certification must be required before use.'

$tennis = Get-V4CSemanticProductGate $current '47065731383'
Assert-True ($tennis.can_enter_v4b -eq $true) 'tennis balls may enter edit-only handoff after performance claims are blocked.'
Assert-True ((@($tennis.blocked_claim_keys) -join ' ') -match 'pressureless_ball_claim') 'pressureless claim must remain unverified.'
Assert-True ((@($tennis.blocked_claim_keys) -join ' ') -match 'high_rebound_performance') 'rebound performance must remain blocked.'

$tapeProduct = Get-V4CSemanticReviewProduct $current '47115577538'
Assert-True ([string]$tapeProduct.route -eq 'sports/protective_gear') 'sports kinesiology tape must use product-body protective route.'
$tape = Get-V4CSemanticProductGate $current '47115577538'
Assert-True ($tape.can_enter_v4b -eq $true) 'sports tape may enter edit-only handoff after medical/performance claims are blocked.'
Assert-True ((@($tape.blocked_claim_keys) -join ' ') -match 'strain_relief_claim') 'strain-relief claim must remain blocked.'
Assert-True ((@($tape.blocked_claim_keys) -join ' ') -match '1_8x_stretch_claim') 'exact stretch ratio must remain blocked.'

foreach ($id in @('47315718349','47315735312')) {
    $p = Get-V4CSemanticProductGate $current $id
    Assert-True ($p.can_enter_v4b -eq $false) ('variant-mixed racket-sport listing must stay blocked: ' + $id)
    Assert-True ($p.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') ('variant mapping verdict required: ' + $id)
}

$towelProduct = Get-V4CSemanticReviewProduct $current '47415735250'
Assert-True ([string]$towelProduct.route -eq 'sports/sports_towel') 'tennis-context towel must use sports_towel route.'
$towel = Get-V4CSemanticProductGate $current '47415735250'
Assert-True ($towel.can_enter_v4b -eq $false) 'Wilson/KITH-marked towel must stay blocked until brand rights are verified.'
Assert-True ($towel.semantic_verdict -eq 'BLOCK_BRAND_VERIFICATION_REQUIRED') 'towel must use brand-verification block.'
Assert-True ((@($towel.blocked_claim_keys) -join ' ') -match 'wilson_brand_authenticity') 'Wilson authenticity must be verified.'
Assert-True ((@($towel.blocked_claim_keys) -join ' ') -match 'kith_brand_authenticity') 'KITH authenticity must be verified.'

foreach ($id in @('47565623654','47565623725','47765623719')) {
    $p = Get-V4CSemanticProductGate $current $id
    Assert-True ($p.can_enter_v4b -eq $false) ('life-safety product must stay blocked: ' + $id)
    Assert-True ($p.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS') ('life-safety high-risk verdict required: ' + $id)
    Assert-True ((@($p.blocked_claim_keys) -join ' ') -match 'buoyancy') ('buoyancy claim must stay blocked: ' + $id)
}

$partial = Get-V4CSemanticProductGate $current '48165674449'
Assert-True ($partial.product_review_complete -eq $false) '481 must remain incomplete at the B005 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 4) '481 must have only four of eight sources reviewed in B005.'
Assert-True ($partial.total_source_image_count -eq 8) '481 catalog source count must remain eight.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '481 must use partial-source block before B006.'
Assert-True ($partial.can_enter_v4b -eq $false) '481 may not enter V4-B before remaining sources are reviewed.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'remaining_four_source_images_in_B006') '481 must explicitly request its remaining four B006 sources.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 4/8 glove sources may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '48165674449' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 10
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 481 at 4/8 sources.'

Write-Host 'V4-C0 B005 semantic gate smoke: PASS'