# TinySnow V4-C0
# Validates completed source-image semantic review results.
# This gate never authorizes paid generation by itself: V4-C0 always keeps paid permission at HOLD.

function Import-V4CSemanticReview([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        throw ("V4-C0 semantic review file not found: {0}" -f $Path)
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-V4CSemanticReviewProduct($Review, [string]$ProductId) {
    if ($null -eq $Review) { return $null }
    return @($Review.products | Where-Object { [string]$_.product_id -eq $ProductId } | Select-Object -First 1)[0]
}

function Assert-V4CSemanticReview($Review) {
    if ($null -eq $Review) { throw 'V4-C0 semantic review is null.' }
    if ([string]$Review.schema_version -ne 'v4c0-semantic-review-1') { throw 'V4-C0 semantic review schema_version mismatch.' }
    if ([string]::IsNullOrWhiteSpace([string]$Review.batch_id)) { throw 'V4-C0 semantic review missing batch_id.' }

    $scope = $Review.review_scope
    if ($null -eq $scope) { throw 'V4-C0 semantic review missing review_scope.' }
    if ([bool]$scope.image_api_called) { throw 'V4-C0 semantic review may not report image API usage.' }
    if (-not [bool]$scope.pixel_semantic_review_completed) { throw 'V4-C0 semantic review must be pixel-reviewed before semantic gating.' }
    if ([bool]$scope.generated_output_reviewed) { throw 'V4-C0 source semantic review must not claim generated-output review.' }

    $products = @($Review.products)
    if ($products.Count -ne [int]$scope.product_count) { throw 'V4-C0 semantic review product_count mismatch.' }
    if ($products.Count -lt 1) { throw 'V4-C0 semantic review has no products.' }

    $ids = @{}
    $sourceTotal = 0
    $passCount = 0
    $blockCount = 0
    foreach ($p in $products) {
        $id = [string]$p.product_id
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'V4-C0 semantic review product missing product_id.' }
        if ($ids.ContainsKey($id)) { throw ("V4-C0 semantic review duplicate product_id: {0}" -f $id) }
        $ids[$id] = $true

        $sourceCount = [int]$p.source_image_count
        if ($sourceCount -lt 1) { throw ("V4-C0 semantic review invalid source_image_count: {0}" -f $id) }
        $sourceTotal += $sourceCount

        if ([string]$p.final_paid_generation_permission -ne 'HOLD') {
            throw ("V4-C0 semantic review may not auto-authorize paid generation: {0}" -f $id)
        }

        $verdict = [string]$p.verdict
        if ($verdict -eq 'PASS_EDIT_ONLY') {
            $passCount++
            if (-not [bool]$p.eligible_for_v4b) { throw ("PASS_EDIT_ONLY must be eligible for V4-B handoff: {0}" -f $id) }
            if ([string]$p.required_generation_mode -ne 'EDIT_PRESERVE_LOCALIZE') { throw ("PASS_EDIT_ONLY mode mismatch: {0}" -f $id) }
            if ([string]$p.source_action -ne 'EDIT') { throw ("PASS_EDIT_ONLY source action must be EDIT: {0}" -f $id) }
        }
        elseif ($verdict.StartsWith('BLOCK_')) {
            $blockCount++
            if ([bool]$p.eligible_for_v4b) { throw ("Blocked product cannot be eligible for V4-B: {0}" -f $id) }
            if ([string]$p.required_generation_mode -ne 'NONE') { throw ("Blocked product generation mode must be NONE: {0}" -f $id) }
            if ([string]$p.source_action -ne 'BLOCK') { throw ("Blocked product source action must be BLOCK: {0}" -f $id) }
            if (@($p.next_evidence_required).Count -lt 1) { throw ("Blocked product must say what evidence is required next: {0}" -f $id) }
        }
        else {
            throw ("Unknown V4-C0 semantic verdict: {0} / {1}" -f $id,$verdict)
        }

        if (@($p.safe_visual_facts).Count -lt 1) { throw ("Semantic result must keep at least one safe visual fact: {0}" -f $id) }
        if ($null -eq $p.blocked_claims) { throw ("Semantic result missing blocked_claims: {0}" -f $id) }
        if ($null -eq $p.variant_constraints) { throw ("Semantic result missing variant_constraints: {0}" -f $id) }
    }

    if ($sourceTotal -ne [int]$scope.source_image_count) { throw 'V4-C0 semantic review source_image_count mismatch.' }

    return [pscustomobject]@{
        valid = $true
        batch_id = [string]$Review.batch_id
        product_count = $products.Count
        source_image_count = $sourceTotal
        pass_edit_only_count = $passCount
        blocked_count = $blockCount
        image_api_called = $false
        final_paid_generation_permission = 'HOLD'
    }
}

function Get-V4CSemanticProductGate($Review, [string]$ProductId) {
    $null = Assert-V4CSemanticReview $Review
    $p = Get-V4CSemanticReviewProduct $Review $ProductId
    if ($null -eq $p) { throw ("V4-C0 semantic product not found: {0}" -f $ProductId) }

    $pass = ([string]$p.verdict -eq 'PASS_EDIT_ONLY')
    return [pscustomobject]@{
        product_id = [string]$p.product_id
        semantic_verdict = [string]$p.verdict
        can_enter_v4b = ($pass -and [bool]$p.eligible_for_v4b)
        allowed_generation_mode = if ($pass) { 'EDIT_PRESERVE_LOCALIZE' } else { 'NONE' }
        source_action = [string]$p.source_action
        blocked_claims = [object[]]@($p.blocked_claims)
        variant_constraints = [object[]]@($p.variant_constraints)
        next_evidence_required = [object[]]@($p.next_evidence_required)
        final_paid_generation_permission = 'HOLD'
        image_api_called = $false
    }
}
