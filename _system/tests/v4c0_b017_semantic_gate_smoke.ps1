$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B017 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b016_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b017_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B017') 'batch must be B017.'
Assert-True ($summary.touched_product_count -eq 12) 'B017 must touch twelve products.'
Assert-True ($summary.complete_product_count -eq 11) 'B017 must complete eleven products.'
Assert-True ($summary.partial_product_count -eq 1) 'B017 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 54) 'B017 must account for 50 new + 4 carried images.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B017 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 4) 'B017 must carry exactly four B016 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 4) 'B017 must have four edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 7) 'B017 must have seven complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B017 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B017 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B016/B017 chain must be valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 4) 'B017 chain must verify four carried sources.'

$glove = Get-V4CSemanticProductGate $current '50765665403'
Assert-True ($glove.product_review_complete -eq $true) '50765665403 must complete 6/6.'
Assert-True ($glove.reviewed_source_image_count -eq 6) '50765665403 must have six reviewed sources.'
Assert-True ($glove.newly_reviewed_source_image_count -eq 2) '50765665403 must add sequences 801-802.'
Assert-True ($glove.carried_forward_source_image_count -eq 4) '50765665403 must carry four B016 sources.'
Assert-True ($glove.can_enter_v4b -eq $false) '50765665403 must stay blocked after complete review.'
Assert-True ((@($glove.blocked_claim_keys) -join ' ') -match 'leather_material_claim') 'prior leather block must be preserved.'
Assert-True ((@($glove.variant_constraints) -join ' ') -match 'B016_reviews_only_first_four_of_six') 'prior partial constraint must be preserved.'
Assert-True ((@($glove.variant_constraints) -join ' ') -match 'twenty_four_catalog_options_require_size_color_handedness_mapping') '24-option mapping must remain explicit.'

$identity = Get-V4CSemanticProductGate $current '51715657054'
Assert-True ($identity.can_enter_v4b -eq $false) 'squash-title/golf-source identity conflict must stay blocked.'
Assert-True ($identity.semantic_verdict -eq 'BLOCK_SOURCE_CATALOG_PRODUCT_IDENTITY_CONFLICT_REQUIRED') 'identity conflict verdict must remain explicit.'
Assert-True ((@($identity.variant_constraints) -join ' ') -match 'catalog_title_and_category_describe_squash_balls_but_all_four_reviewed_sources_show_golf_club_head_cover_or_slip_protection_products') 'source/catalog body conflict must remain explicit.'

foreach ($id in @('51115596167','51415657062','51515651767','51715651765')) {
    $g = Get-V4CSemanticProductGate $current $id
    Assert-True ($g.can_enter_v4b -eq $true) ('edit-only product should enter V4-B handoff: ' + $id)
    Assert-True ($g.semantic_verdict -eq 'PASS_EDIT_ONLY') ('pass product must be PASS_EDIT_ONLY: ' + $id)
    Assert-True ($g.allowed_generation_mode -eq 'EDIT_PRESERVE_LOCALIZE') ('pass product must stay edit/preserve/localize: ' + $id)
}

foreach ($id in @('51265588414','51365553407','51415651743','51615651754','51715657054','51715689069')) {
    $g = Get-V4CSemanticProductGate $current $id
    Assert-True ($g.can_enter_v4b -eq $false) ('blocked product may not enter V4-B: ' + $id)
    Assert-True ($g.source_action -eq 'BLOCK') ('blocked product must keep BLOCK source action: ' + $id)
}

$bracelet = Get-V4CSemanticProductGate $current '51615651754'
Assert-True ((@($bracelet.blocked_claim_keys) -join ' ') -match 'glass_breaker_effectiveness') 'glass-breaker effectiveness must stay blocked.'
Assert-True ((@($bracelet.blocked_claim_keys) -join ' ') -match 'survival_safety_claim') 'survival safety must stay blocked.'

$whip = Get-V4CSemanticProductGate $current '51715689069'
Assert-True ((@($whip.blocked_claim_keys) -join ' ') -match 'municipal_intangible_cultural_heritage_certification_claim') 'cultural-heritage certification must not be inferred from source image.'
Assert-True ((@($whip.variant_constraints) -join ' ') -match 'twenty_seven_catalog_options_require_length_color_handle_core_and_customization_mapping') '27-option whip mapping must stay explicit.'

$partial = Get-V4CSemanticProductGate $current '51765547764'
Assert-True ($partial.product_review_complete -eq $false) '51765547764 must remain incomplete at B017 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 3) '51765547764 must have three reviewed sources in B017.'
Assert-True ($partial.total_source_image_count -eq 4) '51765547764 total source count must remain four.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '51765547764 must use partial-source block.'
Assert-True ($partial.can_enter_v4b -eq $false) '51765547764 may not enter V4-B before B018.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match '851') '51765547764 must explicitly request B018 sequence 851.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary: 3/4 may never be false-completed.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '51765547764' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 12
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 51765547764 at 3/4 sources.'

Write-Host 'V4-C0 B017 semantic gate smoke: PASS'
