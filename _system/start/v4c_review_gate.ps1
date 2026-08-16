# TinySnow V4-C0
# Bulk catalog review gate.
# This module prioritizes semantic source-image review; it NEVER approves paid generation by itself.

function Test-V4CRawCategoryRouteMismatch($Evidence, $Route) {
    $raw = [string](Get-V4CProperty $Evidence 'raw_category' '')
    $family = [string](Get-V4CProperty $Route 'family' 'generic')
    if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
    $rawSports = ($raw -match '(?i)Sports\s*&\s*Outdoors')
    if ($rawSports -and $family -notin @('sports','apparel','shoes','bags')) { return $true }
    if (-not $rawSports -and $family -eq 'sports') { return $true }
    return $false
}

function Get-V4CProductSourceCount($Product, $Evidence) {
    $urls = @(Get-V4CProperty $Product 'image_urls' @())
    if ($urls.Count -gt 0) { return @($urls | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique).Count }
    return [int](Get-V4CProperty $Evidence 'source_image_count' 0)
}

function Get-V4COptionCount($Product) {
    $options = @(Get-V4CProperty $Product 'variation_options' @())
    if ($options.Count -gt 0) { return @($options | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique).Count }
    $flags = Get-V4CProperty $Product 'multi_variant_flags' $null
    return [int](Get-V4CProperty $flags 'option_count' 0)
}

function Get-V4CReviewGate($Product, $Evidence, $Route) {
    $sourceCount = Get-V4CProductSourceCount $Product $Evidence
    $optionCount = Get-V4COptionCount $Product
    $variantRisk = Get-V4CProperty $Evidence 'variant_risk' $null
    $highConflict = [bool](Get-V4CProperty $variantRisk 'high_conflict' $false)
    $mismatch = Test-V4CRawCategoryRouteMismatch $Evidence $Route
    $subfamily = [string](Get-V4CProperty $Route 'subfamily' 'unknown')
    $family = [string](Get-V4CProperty $Route 'family' 'generic')
    $routeConfidence = [double](Get-V4CProperty $Route 'confidence' 0.0)

    $highClaimRisk = $subfamily -in @(
        'protective_gear','water_safety_gear','electronics_accessory','auto_accessory','beauty_personal_care'
    )

    $score = 0
    $reasons = @()
    if ($highConflict) { $score += 3; $reasons += 'high_variant_conflict' }
    if ($mismatch) { $score += 3; $reasons += 'raw_category_route_mismatch' }
    if ($sourceCount -lt 5) { $score += 1; $reasons += 'fewer_than_five_source_images' }
    if ($sourceCount -le 3) { $score += 2; $reasons += 'very_few_source_images' }
    if ($highClaimRisk) { $score += 2; $reasons += 'high_claim_risk_category' }
    if ($optionCount -ge 20) { $score += 1; $reasons += 'many_variation_options' }
    if ($routeConfidence -lt 0.55 -or $family -eq 'generic') { $score += 10; $reasons += 'unresolved_route' }

    $tier = if ($score -ge 5) { 'HIGH' } elseif ($score -ge 2) { 'MEDIUM' } else { 'LOW' }
    $queue = if ($family -eq 'generic' -or $sourceCount -le 0) {
        'BLOCK_EXCEL'
    }
    elseif ($tier -eq 'HIGH') { 'PRIORITY_SEMANTIC_REVIEW' }
    elseif ($tier -eq 'MEDIUM') { 'STANDARD_SEMANTIC_REVIEW' }
    else { 'FAST_SEMANTIC_REVIEW' }

    return [pscustomobject]@{
        schema_version = 'v4c0-review-gate-1'
        risk_score = $score
        risk_tier = $tier
        review_queue = $queue
        reasons = [string[]]$reasons
        source_image_count = $sourceCount
        option_count = $optionCount
        high_claim_risk = $highClaimRisk
        category_route_mismatch = $mismatch
        image_semantic_review_required = $true
        semantic_review_state = 'NOT_RUN'
        final_paid_generation_permission = 'HOLD'
        auto_paid_generation_approved = $false
    }
}
