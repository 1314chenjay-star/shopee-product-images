$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B003 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b002_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b003_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B003') 'batch must be B003.'
Assert-True ($summary.touched_product_count -eq 12) 'B003 must touch twelve products.'
Assert-True ($summary.complete_product_count -eq 11) 'B003 must have eleven complete products.'
Assert-True ($summary.partial_product_count -eq 1) 'B003 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 50) 'B003 must account for exactly fifty source images.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B003 must add fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 0) 'B003 must not carry source images from B002.'
Assert-True ($summary.complete_pass_edit_only_count -eq 5) 'B003 must have five complete edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 6) 'B003 must have six complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B003 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B003 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B002/B003 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 0) 'B003 chain must not invent carry-forward images.'

$rabbit = Get-V4CSemanticProductGate $current '47015637630'
Assert-True ($rabbit.can_enter_v4b -eq $true) 'rabbit garden light/incense stand may enter edit-only handoff after risky claims are blocked.'
Assert-True ((@($rabbit.blocked_claim_keys) -join ' ') -match 'outdoor_waterproof_performance') 'rabbit product must block waterproof performance.'

$loki = Get-V4CSemanticProductGate $current '47315718453'
Assert-True ($loki.can_enter_v4b -eq $false) 'LOKI listing with 26 options and multi-model collage must stay blocked.'
Assert-True ($loki.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'LOKI listing requires source-to-option mapping.'
Assert-True ((@($loki.variant_constraints) -join ' ') -match 'twenty_six_options_present') 'LOKI listing must retain 26-option risk.'
Assert-True ((@($loki.variant_constraints) -join ' ') -match 'multiple_racket_models') 'LOKI listing must retain multi-model source risk.'

$wireSaw = Get-V4CSemanticProductGate $current '47715667299'
Assert-True ($wireSaw.can_enter_v4b -eq $true) 'wire saw may enter edit-only handoff.'
Assert-True ((@($wireSaw.blocked_claim_keys) -join ' ') -match 'stainless_steel_material') 'wire saw material must remain unverified.'
Assert-True ((@($wireSaw.blocked_claim_keys) -join ' ') -match 'cutting_performance') 'wire saw cutting performance must remain blocked.'

$mosquito = Get-V4CSemanticProductGate $current '47915667361'
Assert-True ($mosquito.can_enter_v4b -eq $false) 'mosquito killer must stay blocked pending efficacy and safety evidence.'
Assert-True ((@($mosquito.blocked_claim_keys) -join ' ') -match 'mosquito_killing_effectiveness') 'mosquito-killing efficacy must be blocked.'
Assert-True ((@($mosquito.blocked_claim_keys) -join ' ') -match 'electrical_light_safety') 'electrical/light safety must be checked.'

$filter = Get-V4CSemanticProductGate $current '49715667269'
Assert-True ($filter.can_enter_v4b -eq $false) 'drinking-water filter must stay blocked pending test evidence.'
Assert-True ((@($filter.blocked_claim_keys) -join ' ') -match '99_9_percent_removal_rate') 'filter must block exact removal rate.'
Assert-True ((@($filter.blocked_claim_keys) -join ' ') -match '0_01_micrometer_filtration') 'filter must block exact pore-size claim.'
Assert-True ((@($filter.blocked_claim_keys) -join ' ') -match 'sgs_certification') 'filter must block SGS certification until verified.'
Assert-True ((@($filter.blocked_claim_keys) -join ' ') -match 'direct_drinking_safety') 'filter must block direct-drinking safety claim.'

$paddle = Get-V4CSemanticProductGate $current '50815605686'
Assert-True ($paddle.can_enter_v4b -eq $true) 'SUP paddle can enter edit-only handoff.'
Assert-True ((@($paddle.blocked_claim_keys) -join ' ') -match 'aluminum_alloy_material') 'SUP paddle material must stay unverified.'
Assert-True ((@($paddle.blocked_claim_keys) -join ' ') -match 'universal_compatibility') 'SUP paddle universal compatibility must stay blocked.'

foreach ($id in @('51815608511','52765617669')) {
    $repeller = Get-V4CSemanticProductGate $current $id
    Assert-True ($repeller.can_enter_v4b -eq $false) ('repeller must stay blocked: ' + $id)
    Assert-True ((@($repeller.blocked_claim_keys) -join ' ') -match 'animal_repelling_effectiveness') ('repelling efficacy must stay blocked: ' + $id)
}

$trainer = Get-V4CSemanticProductGate $current '53015734584'
Assert-True ($trainer.can_enter_v4b -eq $false) 'basketball finger trainer source-set conflict must stay blocked.'
Assert-True ($trainer.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'basketball trainer requires variant mapping.'
Assert-True ((@($trainer.variant_constraints) -join ' ') -match 'two_different_product_structures') 'basketball trainer must retain two-product-structure conflict.'
Assert-True ((@($trainer.variant_constraints) -join ' ') -match 'twenty_three_options_present') 'basketball trainer must retain 23-option risk.'

$partial = Get-V4CSemanticProductGate $current '53415651688'
Assert-True ($partial.product_review_complete -eq $false) '534 must remain incomplete at the B003 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 1) '534 must have only one reviewed source in B003.'
Assert-True ($partial.total_source_image_count -eq 4) '534 catalog source count must remain four.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '534 must use partial-source block.'
Assert-True ($partial.can_enter_v4b -eq $false) '534 may not enter V4-B before B004 reviews remaining sources.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'remaining_three_source_images_in_B004') '534 must explicitly request the remaining three B004 sources.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 1/4 may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '53415651688' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 12
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 534 at 1/4 sources.'

Write-Host 'V4-C0 B003 semantic gate smoke: PASS'
