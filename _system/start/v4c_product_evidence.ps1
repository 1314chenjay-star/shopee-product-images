# TinySnow V4-C0
# Universal Product Evidence layer (free analysis only; no image API calls)

function Get-V4CProperty($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $Default
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function ConvertTo-V4CTextArray($Value) {
    if ($null -eq $Value) { return [string[]]@() }
    $items = @($Value) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    return [string[]]@($items | Select-Object -Unique)
}

function Get-V4CStructuredFacts($Product) {
    $verified = Get-V4CProperty $Product 'verified_facts' $null
    $result = [ordered]@{
        dimensions = @()
        materials = @()
        accessories = @()
        gifts = @()
        bundle_contents = @()
        resistance_levels = @()
        sizes = @()
        features = @()
        use_cases = @()
        certifications = @()
    }
    $map = [ordered]@{
        dimensions = 'verified_dimensions'
        materials = 'verified_materials'
        accessories = 'verified_accessories'
        gifts = 'verified_gifts'
        bundle_contents = 'verified_bundle_contents'
        resistance_levels = 'verified_resistance_levels'
        sizes = 'verified_sizes'
        features = 'verified_features'
        use_cases = 'verified_use_cases'
        certifications = 'verified_certifications'
    }
    foreach ($key in $map.Keys) {
        $result[$key] = @(ConvertTo-V4CTextArray (Get-V4CProperty $verified $map[$key] @()))
    }
    return [pscustomobject]$result
}

function Get-V4CVariantRisk($Product) {
    $flags = Get-V4CProperty $Product 'multi_variant_flags' $null
    $risk = [ordered]@{
        has_multiple_colors = [bool](Get-V4CProperty $flags 'has_multiple_colors' $false)
        has_multiple_sizes = [bool](Get-V4CProperty $flags 'has_multiple_sizes' $false)
        has_multiple_materials = [bool](Get-V4CProperty $flags 'has_multiple_materials' $false)
        has_multiple_quantities = [bool](Get-V4CProperty $flags 'has_multiple_quantities' $false)
        has_multiple_bundle_counts = [bool](Get-V4CProperty $flags 'has_multiple_bundle_counts' $false)
        has_multiple_patterns = [bool](Get-V4CProperty $flags 'has_multiple_patterns' $false)
    }
    $riskCount = @($risk.Keys | Where-Object { [bool]$risk[$_] }).Count
    return [pscustomobject]@{
        flags = [pscustomobject]$risk
        risk_count = $riskCount
        high_conflict = ($riskCount -ge 2 -or $risk.has_multiple_materials -or $risk.has_multiple_quantities -or $risk.has_multiple_bundle_counts)
    }
}

function New-V4CProductEvidence($Product, $Analysis) {
    if ($null -eq $Product) { throw 'V4-C0：缺少 Product。' }
    $productId = [string](Get-V4CProperty $Product 'product_id' (Get-V4CProperty $Analysis 'product_id' ''))
    $title = [string](Get-V4CProperty $Product 'name' (Get-V4CProperty $Product 'title' ''))
    $category = [string](Get-V4CProperty $Product 'category' '')
    $facts = Get-V4CStructuredFacts $Product
    $variantRisk = Get-V4CVariantRisk $Product

    $sourceCount = 0
    if ($null -ne $Analysis) {
        $sources = @(Get-V4CProperty $Analysis 'reference_safety' @())
        if ($sources.Count -eq 0) { $sources = @(Get-V4CProperty $Analysis 'images' @()) }
        $sourceCount = @($sources | Where-Object { -not [bool](Get-V4CProperty $_ 'duplicate' $false) }).Count
    }

    $verifiedCount = 0
    foreach ($name in $facts.PSObject.Properties.Name) { $verifiedCount += @($facts.$name).Count }

    return [pscustomobject]@{
        schema_version = 'v4c0-evidence-1'
        product_id = $productId
        title = $title
        raw_category = $category
        source_image_count = $sourceCount
        verified_facts = $facts
        variant_risk = $variantRisk
        verified_fact_count = $verifiedCount
        evidence_state = if ($sourceCount -gt 0 -or $verifiedCount -gt 0) { 'available' } else { 'sparse' }
        policy = [pscustomobject]@{
            unverified_is_not_fact = $true
            variant_specific_is_not_common_fact = $true
            conflicting_facts_must_block_claims = $true
            no_invention = $true
        }
    }
}
