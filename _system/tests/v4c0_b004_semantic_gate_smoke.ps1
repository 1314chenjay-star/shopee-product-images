$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B004 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b003_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b004_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B004') 'batch must be B004.'
Assert-True ($summary.touched_product_count -eq 11) 'B004 must touch eleven products.'
Assert-True ($summary.complete_product_count -eq 10) 'B004 must have ten complete products.'
Assert-True ($summary.partial_product_count -eq 1) 'B004 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 51) 'B004 cumulative product accounting must be fifty-one with one carried source.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B004 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 1) 'B004 must carry exactly one B003 source.'
Assert-True ($summary.complete_pass_edit_only_count -eq 3) 'B004 must have three complete edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 7) 'B004 must have seven complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B004 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B004 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B003/B004 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 1) 'B004 chain must verify exactly one carried source.'

$lamp = Get-V4CSemanticProductGate $current '53415651688'
Assert-True ($lamp.product_review_complete -eq $true) '534 must become complete in B004.'
Assert-True ($lamp.reviewed_source_image_count -eq 4) '534 must account for all four sources.'
Assert-True ($lamp.newly_reviewed_source_image_count -eq 3) '534 must add three B004 sources.'
Assert-True ($lamp.carried_forward_source_image_count -eq 1) '534 must carry one B003 source.'
Assert-True ($lamp.can_enter_v4b -eq $true) '534 may enter edit-only handoff after risky lighting claims are blocked.'
Assert-True ((@($lamp.blocked_claim_keys) -join ' ') -match 'ip55_rating') '534 must not treat visible IP55 text as verified.'

$repeller = Get-V4CSemanticProductGate $current '54715608524'
Assert-True ($repeller.can_enter_v4b -eq $false) 'animal repeller must stay blocked.'
Assert-True ($repeller.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS') 'animal repeller must use high-risk block.'
Assert-True ((@($repeller.blocked_claim_keys) -join ' ') -match 'animal_repelling_effectiveness') 'animal-repelling efficacy must stay blocked.'
Assert-True ((@($repeller.blocked_claim_keys) -join ' ') -match 'ip66_rating') 'IP66 must remain unverified.'

$filter = Get-V4CSemanticProductGate $current '55215651786'
Assert-True ($filter.can_enter_v4b -eq $false) 'portable drinking-water filter must stay blocked.'
Assert-True ((@($filter.blocked_claim_keys) -join ' ') -match '0_01_micrometer_filtration') 'filter pore-size claim must be blocked.'
Assert-True ((@($filter.blocked_claim_keys) -join ' ') -match '99_9_percent_bacteria_removal') 'bacteria-removal claim must be blocked.'
Assert-True ((@($filter.blocked_claim_keys) -join ' ') -match 'direct_drinking_safety') 'direct-drinking safety must be blocked.'

$legRing = Get-V4CSemanticProductGate $current '55615585947'
Assert-True ($legRing.can_enter_v4b -eq $false) 'leg ring mixed one/two-piece and color variants must stay blocked.'
Assert-True ($legRing.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'leg ring requires variant mapping.'
Assert-True ((@($legRing.blocked_claim_keys) -join ' ') -match 'blood_circulation_improvement') 'circulation claim must not survive localization.'

$entryRacket = Get-V4CSemanticProductGate $current '26295530370'
Assert-True ($entryRacket.can_enter_v4b -eq $false) 'entry table-tennis racket bundle must stay blocked until option mapping.'
Assert-True ((@($entryRacket.variant_constraints) -join ' ') -match 'one_racket_two_rackets') 'racket bundle count conflict must be explicit.'

$rollerProduct = Get-V4CSemanticReviewProduct $current '28195530371'
Assert-True ([string]$rollerProduct.route -eq 'tools/sports_maintenance_tool') 'glue roller must follow latest product-body route.'
$roller = Get-V4CSemanticProductGate $current '28195530371'
Assert-True ($roller.can_enter_v4b -eq $false) 'glue roller plastic/aluminum options require mapping.'
Assert-True ((@($roller.variant_constraints) -join ' ') -match 'plastic_and_aluminum') 'glue roller must retain material-variant split.'

$nineStar = Get-V4CSemanticProductGate $current '28595530368'
Assert-True ($nineStar.can_enter_v4b -eq $false) 'nine-star racket listing must stay blocked.'
Assert-True ((@($nineStar.blocked_claim_keys) -join ' ') -match 'ittf_certification') 'ITTF claim must be verified before use.'
Assert-True ((@($nineStar.variant_constraints) -join ' ') -match 'one_racket_two_rackets') 'nine-star bundle count must be mapped.'

$bucketProduct = Get-V4CSemanticReviewProduct $current '28845515575'
Assert-True ([string]$bucketProduct.route -eq 'bags/sports_bag') 'table-tennis storage bucket must follow latest product-body route.'
$bucket = Get-V4CSemanticProductGate $current '28845515575'
Assert-True ($bucket.can_enter_v4b -eq $true) 'storage bucket may enter edit-only handoff.'
Assert-True ((@($bucket.blocked_claim_keys) -join ' ') -match 'balls_included') 'source balls must not become an included-bundle claim.'
Assert-True ((@($bucket.variant_constraints) -join ' ') -match 'final_edit_must_not_imply_balls_are_included') 'final bucket edit must not imply balls are included.'

$brandRacket = Get-V4CSemanticProductGate $current '28945515585'
Assert-True ($brandRacket.can_enter_v4b -eq $false) 'brand/certification-heavy racket must stay blocked.'
Assert-True ($brandRacket.semantic_verdict -eq 'BLOCK_BRAND_CERTIFICATION_VERIFICATION_REQUIRED') 'brand racket must require verification.'
Assert-True ((@($brandRacket.blocked_claim_keys) -join ' ') -match 'butterfly_brand_authenticity') 'brand authenticity must be verified.'
Assert-True ((@($brandRacket.blocked_claim_keys) -join ' ') -match 'celebrity_endorsement_or_likeness_claim') 'person-likeness endorsement must not be assumed.'

$pushup = Get-V4CSemanticProductGate $current '41783329441'
Assert-True ($pushup.can_enter_v4b -eq $true) 'single-option push-up board may enter edit-only handoff.'
Assert-True ((@($pushup.blocked_claim_keys) -join ' ') -match 'thirty_pose_count') 'exact pose count must remain blocked.'
Assert-True ((@($pushup.blocked_claim_keys) -join ' ') -match 'smart_counting_function') 'counter functionality must not be promised without verification.'

$life = Get-V4CSemanticProductGate $current '46515609644'
Assert-True ($life.product_review_complete -eq $false) 'life jacket must remain incomplete at the B004 boundary.'
Assert-True ($life.reviewed_source_image_count -eq 3) 'life jacket must have only three of four sources reviewed in B004.'
Assert-True ($life.total_source_image_count -eq 4) 'life jacket catalog source count must remain four.'
Assert-True ($life.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') 'life jacket must use partial-source block before B005.'
Assert-True ($life.can_enter_v4b -eq $false) 'life jacket may not enter V4-B before the final source and safety evidence are reviewed.'
Assert-True ((@($life.next_evidence_required) -join ' ') -match 'remaining_one_source_image_in_B005') 'life jacket must explicitly request its final B005 source.'
Assert-True ((@($life.blocked_claim_keys) -join ' ') -match '220_jin_110kg_load_claim') 'safety-critical supported-weight claim must stay blocked.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 3/4 life-jacket sources may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '46515609644' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 11
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of life jacket at 3/4 sources.'

Write-Host 'V4-C0 B004 semantic gate smoke: PASS'