# TinySnow V4-C0
# Source-image semantic review manifest.
# Builds a deterministic review queue only. It does NOT inspect image pixels and does NOT call any image API.

function Get-V4CReviewTierRank([string]$Tier) {
    switch ($Tier) {
        'HIGH' { return 0 }
        'MEDIUM' { return 1 }
        'LOW' { return 2 }
        'LOCKED' { return 9 }
        default { return 8 }
    }
}

function Get-V4CCheckpointState($CheckpointStates, [string]$ProductId) {
    if ($null -eq $CheckpointStates) { return '' }
    if ($CheckpointStates -is [hashtable] -and $CheckpointStates.ContainsKey($ProductId)) { return [string]$CheckpointStates[$ProductId] }
    if ($CheckpointStates.PSObject.Properties.Name -contains $ProductId) { return [string]$CheckpointStates.PSObject.Properties[$ProductId].Value }
    return ''
}

function Get-V4CManifestProductRank($Product, $CheckpointStates) {
    $productId = [string]$Product.product_id
    $checkpoint = Get-V4CCheckpointState $CheckpointStates $productId
    if (-not [string]::IsNullOrWhiteSpace($checkpoint)) { return 9 }
    return Get-V4CReviewTierRank ([string]$Product.review_gate.risk_tier)
}

function New-V4CSemanticReviewManifest($CatalogAnalysis, $CheckpointStates = $null, [int]$BatchSize = 50) {
    if ($null -eq $CatalogAnalysis) { throw 'V4-C0 semantic manifest：缺少 CatalogAnalysis。' }
    if ($BatchSize -lt 1) { throw 'V4-C0 semantic manifest：BatchSize 必須大於 0。' }

    $products = @($CatalogAnalysis.products)
    $ordered = @($products | Sort-Object @{Expression={ Get-V4CManifestProductRank $_ $CheckpointStates };Ascending=$true}, @{Expression={ -[int]$_.review_gate.risk_score };Ascending=$true}, @{Expression={ [string]$_.product_id };Ascending=$true})

    $rows = @()
    $sequence = 0
    foreach ($product in $ordered) {
        $productId = [string]$product.product_id
        $checkpoint = Get-V4CCheckpointState $CheckpointStates $productId
        $locked = (-not [string]::IsNullOrWhiteSpace($checkpoint))
        $riskFields = @($product.route.risk_fields)
        $checks = @('product_identity','product_surface_text','promotional_text','seller_watermark','taiwan_localization','variant_consistency') + $riskFields
        $checks = @($checks | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

        foreach ($source in @($product.excel_only_image_actions | Sort-Object position)) {
            $sequence++
            $batchNumber = [int]([Math]::Floor(($sequence - 1) / $BatchSize) + 1)
            $batchId = 'B' + $batchNumber.ToString('000', [System.Globalization.CultureInfo]::InvariantCulture)
            $rows += [pscustomobject]@{
                sequence = $sequence
                batch_id = $batchId
                product_id = $productId
                title = [string]$product.title
                route_family = [string]$product.route.family
                route_subfamily = [string]$product.route.subfamily
                risk_tier = if ($locked) { 'LOCKED' } else { [string]$product.review_gate.risk_tier }
                risk_score = if ($locked) { 0 } else { [int]$product.review_gate.risk_score }
                review_queue = if ($locked) { 'SKIP_LOCKED_CHECKPOINT' } else { [string]$product.review_gate.review_queue }
                source_position = [int]$source.position
                source_url = [string]$source.path
                required_checks = [string[]]$checks
                semantic_review_state = if ($locked) { 'CHECKPOINT_ACCEPTED' } else { 'NOT_RUN' }
                semantic_action = if ($locked) { 'REUSE_ACCEPTED_OUTPUT' } else { 'UNDECIDED' }
                final_paid_generation_permission = if ($locked) { 'NO_RERUN_LOCKED' } else { 'HOLD' }
                checkpoint_state = $checkpoint
                image_api_called = $false
            }
        }
    }

    return [pscustomobject]@{
        schema_version = 'v4c0-semantic-manifest-1'
        mode = 'manifest_only_no_pixel_review'
        image_api_called = $false
        batch_size = $BatchSize
        product_count = $products.Count
        image_count = $rows.Count
        pending_image_count = @($rows | Where-Object { $_.semantic_review_state -eq 'NOT_RUN' }).Count
        locked_image_count = @($rows | Where-Object { $_.semantic_review_state -eq 'CHECKPOINT_ACCEPTED' }).Count
        rows = [object[]]$rows
    }
}
