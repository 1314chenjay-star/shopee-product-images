$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 semantic result gate smoke failed: {0}" -f $Message) }
}

$reviewPath = Join-Path $root 'reports\v4c0_b001_semantic_review.json'
$review = Import-V4CSemanticReview $reviewPath
$summary = Assert-V4CSemanticReview $review

Assert-True ($summary.batch_id -eq 'B001') 'batch must be B001.'
Assert-True ($summary.product_count -eq 10) 'B001 must contain 10 reviewed products.'
Assert-True ($summary.source_image_count -eq 50) 'B001 must account for all 50 source images.'
Assert-True ($summary.pass_edit_only_count -eq 6) 'B001 must have six PASS_EDIT_ONLY products.'
Assert-True ($summary.blocked_count -eq 4) 'B001 must have four blocked products.'
Assert-True ($summary.image_api_called -eq $false) 'semantic review must remain free-analysis only.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'V4-C0 may not authorize paid generation.'

$blockedIds = @('56115600682','56515600714','42383385337','27145507293')
foreach ($id in $blockedIds) {
    $gate = Get-V4CSemanticProductGate $review $id
    Assert-True ($gate.can_enter_v4b -eq $false) ("blocked product leaked into V4-B: " + $id)
    Assert-True ($gate.allowed_generation_mode -eq 'NONE') ("blocked product mode mismatch: " + $id)
    Assert-True ($gate.final_paid_generation_permission -eq 'HOLD') ("blocked product paid gate mismatch: " + $id)
}

$passIds = @('52365866864','46465681422','42933329403','51515651767','47515735339','48365764139')
foreach ($id in $passIds) {
    $gate = Get-V4CSemanticProductGate $review $id
    Assert-True ($gate.can_enter_v4b -eq $true) ("PASS_EDIT_ONLY should be eligible for V4-B handoff: " + $id)
    Assert-True ($gate.allowed_generation_mode -eq 'EDIT_PRESERVE_LOCALIZE') ("PASS_EDIT_ONLY mode mismatch: " + $id)
    Assert-True ($gate.source_action -eq 'EDIT') ("PASS_EDIT_ONLY must require EDIT: " + $id)
    Assert-True ($gate.final_paid_generation_permission -eq 'HOLD') ("PASS_EDIT_ONLY may not auto-authorize payment: " + $id)
}

$towel = Get-V4CSemanticReviewProduct $review '47515735339'
Assert-True ([string]$towel.route -eq 'sports/sports_towel') 'sports towel semantic route must match structural guard.'
Assert-True ((@($towel.variant_constraints) -join ' ') -match 'one-piece|two-piece|quantity') 'sports towel must retain quantity-variant isolation.'

$bucket = Get-V4CSemanticReviewProduct $review '51515651767'
Assert-True ([string]$bucket.route -eq 'sports/outdoor_camping') 'folding water bucket must remain camping/outdoor.'
Assert-True ((@($bucket.blocked_claims) -join ' ') -match 'food-grade|leakproof') 'water bucket must block unsupported food-contact/leakproof claims.'

$cueTips = Get-V4CSemanticReviewProduct $review '27145507293'
Assert-True ([string]$cueTips.verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'cue-tip variant mapping conflict must block.'
Assert-True ((@($cueTips.variant_constraints) -join ' ') -match '9/10/11/12/13/14mm') 'cue-tip size-variant conflict must remain explicit.'

$life1 = Get-V4CSemanticReviewProduct $review '56115600682'
$life2 = Get-V4CSemanticReviewProduct $review '56515600714'
Assert-True ((@($life1.blocked_claims) -join ' ') -match 'CE|buoyancy') 'first life jacket must block certification/buoyancy claims.'
Assert-True ((@($life2.blocked_claims) -join ' ') -match 'CE|buoyancy') 'second life jacket must block certification/buoyancy claims.'

$purifier = Get-V4CSemanticReviewProduct $review '42383385337'
Assert-True ((@($purifier.blocked_claims) -join ' ') -match 'UV|ozone|sterilization') 'vehicle purifier must block efficacy/ozone/UV claims.'

Write-Host 'V4-C0 B001 semantic result gate smoke: PASS'
