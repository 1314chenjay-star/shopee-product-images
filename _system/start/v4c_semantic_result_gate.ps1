# TinySnow V4-C0
# Validates completed source-image semantic review results.
# Product completeness is mandatory: a batch may end in the middle of a product.
# This gate never authorizes paid generation by itself; V4-C0 always keeps paid permission at HOLD.

function Import-V4CSemanticReview([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        throw ("V4-C0 semantic review file not found: {0}" -f $Path)
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-V4CSemanticReviewProduct($Review, [string]$ProductId) {
    if ($null -eq $Review) { return $null }
    $matches = @($Review.products | Where-Object { [string]$_.product_id -eq $ProductId } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Assert-V4CSemanticReview($Review) {
    if ($null -eq $Review) { throw 'V4-C0 semantic review is null.' }
    if ([string]$Review.schema_version -ne 'v4c0-semantic-review-2') { throw 'V4-C0 semantic review schema_version mismatch; current gate requires v2.' }
    if ([string]::IsNullOrWhiteSpace([string]$Review.batch_id)) { throw 'V4-C0 semantic review missing batch_id.' }

    $scope = $Review.review_scope
    if ($null -eq $scope) { throw 'V4-C0 semantic review missing review_scope.' }
    if ([bool]$scope.image_api_called) { throw 'V4-C0 semantic review may not report image API usage.' }
    if (-not [bool]$scope.pixel_semantic_review_completed_for_batch) { throw 'V4-C0 semantic batch must complete source-image pixel review before gating.' }
    if ([bool]$scope.generated_output_reviewed) { throw 'V4-C0 source semantic review must not claim generated-output review.' }

    $products = @($Review.products)
    if ($products.Count -ne [int]$scope.touched_product_count) { throw 'V4-C0 semantic review touched_product_count mismatch.' }
    if ($products.Count -lt 1) { throw 'V4-C0 semantic review has no products.' }

    $ids = @{}
    $reviewedImageTotal = 0
    $completeCount = 0
    $partialCount = 0
    $completePassCount = 0
    $completeBlockedCount = 0

    foreach ($p in $products) {
        $id = [string]$p.product_id
        if ([string]::IsNullOrWhiteSpace($id)) { throw 'V4-C0 semantic review product missing product_id.' }
        if ($ids.ContainsKey($id)) { throw ("V4-C0 semantic review duplicate product_id: {0}" -f $id) }
        $ids[$id] = $true

        $reviewedCount = [int]$p.reviewed_source_image_count
        $totalCount = [int]$p.total_source_image_count
        if ($reviewedCount -lt 1 -or $totalCount -lt 1 -or $reviewedCount -gt $totalCount) {
            throw ("V4-C0 semantic review invalid image counts: {0}" -f $id)
        }
        $reviewedImageTotal += $reviewedCount

        $complete = [bool]$p.product_review_complete
        $countComplete = ($reviewedCount -eq $totalCount)
        if ($complete -ne $countComplete) { throw ("V4-C0 semantic product completeness/count mismatch: {0}" -f $id) }
        if ($complete) { $completeCount++ } else { $partialCount++ }

        if ([string]$p.final_paid_generation_permission -ne 'HOLD') {
            throw ("V4-C0 semantic review may not auto-authorize paid generation: {0}" -f $id)
        }

        $verdict = [string]$p.verdict
        if ($verdict -eq 'PASS_EDIT_ONLY') {
            if (-not $complete) { throw ("Partial product cannot PASS_EDIT_ONLY: {0}" -f $id) }
            if (-not [bool]$p.eligible_for_v4b) { throw ("PASS_EDIT_ONLY must be eligible for V4-B handoff: {0}" -f $id) }
            if ([string]$p.source_action -ne 'EDIT') { throw ("PASS_EDIT_ONLY source action must be EDIT: {0}" -f $id) }
            $completePassCount++
        }
        elseif ($verdict.StartsWith('BLOCK_')) {
            if ([bool]$p.eligible_for_v4b) { throw ("Blocked product cannot be eligible for V4-B: {0}" -f $id) }
            if ([string]$p.source_action -ne 'BLOCK') { throw ("Blocked product source action must be BLOCK: {0}" -f $id) }
            if (@($p.next_evidence_required).Count -lt 1) { throw ("Blocked product must say what evidence is required next: {0}" -f $id) }
            if ($verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') {
                if ($complete) { throw ("BLOCK_PARTIAL_SOURCE_SET must be incomplete: {0}" -f $id) }
            }
            elseif (-not $complete) {
                throw ("Incomplete product must use BLOCK_PARTIAL_SOURCE_SET: {0}" -f $id)
            }
            else {
                $completeBlockedCount++
            }
        }
        else {
            throw ("Unknown V4-C0 semantic verdict: {0} / {1}" -f $id,$verdict)
        }

        if ($null -eq $p.blocked_claim_keys) { throw ("Semantic result missing blocked_claim_keys: {0}" -f $id) }
        if ($null -eq $p.variant_constraints) { throw ("Semantic result missing variant_constraints: {0}" -f $id) }
    }

    if ($reviewedImageTotal -ne [int]$scope.reviewed_source_image_count) { throw 'V4-C0 semantic review reviewed_source_image_count mismatch.' }
    if ($completeCount -ne [int]$scope.complete_product_count) { throw 'V4-C0 semantic review complete_product_count mismatch.' }
    if ($partialCount -ne [int]$scope.partial_product_count) { throw 'V4-C0 semantic review partial_product_count mismatch.' }

    return [pscustomobject]@{
        valid = $true
        batch_id = [string]$Review.batch_id
        touched_product_count = $products.Count
        complete_product_count = $completeCount
        partial_product_count = $partialCount
        reviewed_source_image_count = $reviewedImageTotal
        complete_pass_edit_only_count = $completePassCount
        complete_blocked_count = $completeBlockedCount
        image_api_called = $false
        final_paid_generation_permission = 'HOLD'
    }
}

function Get-V4CSemanticProductGate($Review, [string]$ProductId) {
    $null = Assert-V4CSemanticReview $Review
    $p = Get-V4CSemanticReviewProduct $Review $ProductId
    if ($null -eq $p) { throw ("V4-C0 semantic product not found: {0}" -f $ProductId) }

    $complete = [bool]$p.product_review_complete
    $pass = ($complete -and [string]$p.verdict -eq 'PASS_EDIT_ONLY' -and [bool]$p.eligible_for_v4b)
    return [pscustomobject]@{
        product_id = [string]$p.product_id
        product_review_complete = $complete
        reviewed_source_image_count = [int]$p.reviewed_source_image_count
        total_source_image_count = [int]$p.total_source_image_count
        semantic_verdict = [string]$p.verdict
        can_enter_v4b = $pass
        allowed_generation_mode = if ($pass) { 'EDIT_PRESERVE_LOCALIZE' } else { 'NONE' }
        source_action = [string]$p.source_action
        blocked_claim_keys = [object[]]@($p.blocked_claim_keys)
        variant_constraints = [object[]]@($p.variant_constraints)
        next_evidence_required = [object[]]@($p.next_evidence_required)
        final_paid_generation_permission = 'HOLD'
        image_api_called = $false
    }
}
