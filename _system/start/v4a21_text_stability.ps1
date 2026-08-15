$ErrorActionPreference = 'Stop'

# V4-A.2.1 final text-stability layer.
# Keep source facts untouched. Only reduce/normalize the text that may be rendered into generated images.
$script:V4A21AllowedBase = (Get-Command Get-V4A2AllowedOutputText -ErrorAction Stop).ScriptBlock

function Get-V4A21LocalizedFactValues($Product, [string]$Slot) {
    if ($null -eq $Product) { return [string[]]@() }
    $facts = Get-V4A1Property $Product 'verified_facts' $null
    $values = @()
    if ($null -ne $facts) {
        $values += @(Get-V4A1AllFactValues $facts | ForEach-Object { Convert-ToTaiwanCommerceTextV4A2 ([string]$_) })
    }
    $values += @(Get-V4A2TaiwanLengthAliases $Product $Slot)
    return [string[]]@($values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

function Get-V4A2AllowedOutputText($Product, [string]$Slot) {
    $base = @(& $script:V4A21AllowedBase $Product $Slot)
    $normalized = @()
    foreach ($item in $base) {
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -eq '多入數可選') { $text = '數量規格可選' }
        $normalized += $text
    }
    $normalized = @($normalized | Select-Object -Unique)

    # detail4 is the highest text-density slot. Keep it deliberately short.
    if ($Slot -eq 'detail4') {
        $facts = @(Get-V4A21LocalizedFactValues $Product $Slot)
        $label = [string](Get-TaiwanProductLabelV4A2 $Product)
        $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
        $isMulti = Test-IsMultiVariantV4A1 $flags
        $hasMultipleQuantities = [bool](Get-V4A1Property $flags 'has_multiple_quantities' $false)

        $stable = @()
        if (-not [string]::IsNullOrWhiteSpace($label)) { $stable += $label }

        if ($facts.Count -gt 0) {
            $stable += $facts
            if ($hasMultipleQuantities) { $stable += '數量規格可選' }
            elseif ($isMulti) { $stable += '多規格可選' }
            if ($isMulti) { $stable += '規格請依選項為準' }
        }
        else {
            if ($hasMultipleQuantities) { $stable += '數量規格可選' }
            elseif ($isMulti) { $stable += '多規格可選' }
            $stable += '規格請依選項為準'
        }

        return [string[]]@($stable | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    }

    return [string[]]$normalized
}

# Capture the already-hardened + Taiwan-localized builders after installing the stable allowlist above.
$script:V4A21PromptBase = (Get-Command Get-PromptV2 -ErrorAction Stop).ScriptBlock
$script:V4A21CompactBase = (Get-Command Get-CompactTransportPromptV2 -ErrorAction Stop).ScriptBlock

function Get-V4A21TextBudget([string]$Slot) {
    if ($Slot -eq 'detail4') { return 3 }
    return 2
}

function Get-PromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A21PromptBase $Slot $ProductOrName
    $budget = Get-V4A21TextBudget $Slot
    return ($base + "`n[圖片文字穩定硬限制 V4-A.2.1]`n逐字白名單只是『可使用』清單，不代表每一條都必須畫進成品。整張圖最多使用 $budget 個短文字區塊；優先使用台灣商品名稱與最重要的已驗證規格，其餘寧可留白。任何文字只要無法逐字清楚正確繪製，就整句省略，不得用形近字、同音字、近似字或自行改寫替代。數量提示若需要顯示，只能逐字使用「數量規格可選」。detail4 若沒有已驗證共同規格，只保留商品類別名稱與一條簡短規格提醒，不堆疊多條說明。")
}

function Get-CompactTransportPromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A21CompactBase $Slot $ProductOrName
    $budget = Get-V4A21TextBudget $Slot
    return ($base + " 圖片文字穩定規則：最多 $budget 個短文字區塊；白名單不必全部使用。文字無法逐字正確畫出就整句省略，不得用近似字替代。數量提示需要時只可逐字使用「數量規格可選」。")
}
