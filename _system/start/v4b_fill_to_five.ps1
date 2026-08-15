$ErrorActionPreference = 'Stop'

function Get-V4BSafeGenericCopyConfig {
    return (Get-V4BConfigJson 'v4b_safe_generic_copy.json')
}

function Get-V4BAllSafeGenericCopy {
    $config = Get-V4BSafeGenericCopyConfig
    $values = @($config.unconditional)
    foreach ($property in $config.slot_defaults.PSObject.Properties) { $values += @($property.Value) }
    foreach ($property in $config.conditional.PSObject.Properties) { $values += @($property.Value) }
    return [string[]]@($values | ForEach-Object { Convert-ToTaiwanCommerceTextV4B ([string]$_) } | Where-Object { $_ } | Select-Object -Unique)
}

function Get-V4BConditionalGenericCopy($Product) {
    if ($null -eq $Product) { return [string[]]@() }
    $config = Get-V4BSafeGenericCopyConfig
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    $facts = Get-V4A1Property $Product 'verified_facts' $null
    $result = @()

    if (Test-IsMultiVariantV4A1 $flags) {
        $result += @($config.conditional.multi_variant)
    }
    if ([bool](Get-V4A1Property $flags 'has_multiple_colors' $false)) {
        $result += @($config.conditional.multi_color)
    }
    if ([bool](Get-V4A1Property $flags 'has_multiple_sizes' $false)) {
        $result += @($config.conditional.multi_size)
    }
    $variationName = [string](Get-V4A1Property $Product 'variation_name' '')
    if ((Test-IsMultiVariantV4A1 $flags) -and $variationName -match '款式|樣式|型式|style') {
        $result += @($config.conditional.multi_style)
    }
    if ($null -ne $facts -and @(Get-V4A1Property $facts 'verified_dimensions' @()).Count -gt 0) {
        $result += @($config.conditional.has_verified_dimensions)
    }
    return [string[]]@($result | ForEach-Object { Convert-ToTaiwanCommerceTextV4B ([string]$_) } | Where-Object { $_ } | Select-Object -Unique)
}

function Get-V4BGenericCopyForSlot($Product, [string]$Slot, [bool]$IsFill) {
    $config = Get-V4BSafeGenericCopyConfig
    $result = @()
    if ($config.slot_defaults.PSObject.Properties.Name -contains $Slot) {
        $result += @($config.slot_defaults.$Slot)
    }
    if ($IsFill) {
        if ($Slot -eq 'detail4') { $result += '圖片僅供參考，請以實際收到商品為準' }
        elseif ($Slot -eq 'detail1' -or $Slot -eq 'detail2') { $result += '商品細節如圖所示' }
    }
    $result += @(Get-V4BConditionalGenericCopy $Product)
    return [string[]]@($result | ForEach-Object { Convert-ToTaiwanCommerceTextV4B ([string]$_) } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 3)
}

function Test-V4BGenericCopyAllowed([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return (@(Get-V4BAllSafeGenericCopy) -contains (Convert-ToTaiwanCommerceTextV4B $Text))
}
