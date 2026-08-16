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

function Get-V4A21SlotTitle([string]$Slot) {
    switch ($Slot) {
        'detail1' { return '重點細節一覽' }
        'detail2' { return '商品結構與細節展示' }
        'detail3' { return '使用方式參考' }
        'detail4' { return '選購前請確認規格' }
        default { return '' }
    }
}

function Get-V4A2AllowedOutputText($Product, [string]$Slot) {
    # Call the previous layer for compatibility, but construct a smaller final allowlist here.
    $null = @(& $script:V4A21AllowedBase $Product $Slot)
    $facts = @(Get-V4A21LocalizedFactValues $Product $Slot)
    $label = [string](Get-TaiwanProductLabelV4A2 $Product)
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    $isMulti = Test-IsMultiVariantV4A1 $flags
    $hasMultipleQuantities = [bool](Get-V4A1Property $flags 'has_multiple_quantities' $false)
    $stable = @()

    switch ($Slot) {
        'main' {
            if ($label) { $stable += $label }
            $stable += $facts
            if ($hasMultipleQuantities) { $stable += '數量規格可選' }
            elseif ($isMulti) { $stable += '多規格可選' }
        }
        'detail1' {
            if ($label) { $stable += $label }
            $stable += $facts
        }
        'detail2' {
            $stable += (Get-V4A21SlotTitle $Slot)
            $stable += $facts
        }
        'detail3' {
            if ($label) { $stable += $label }
            $stable += $facts
            $stable += (Get-V4A21SlotTitle $Slot)
        }
        'detail4' {
            if ($label) { $stable += $label }
            $stable += $facts
            if ($hasMultipleQuantities) { $stable += '數量規格可選' }
            elseif ($isMulti) { $stable += '多規格可選' }
            $stable += '規格請依選項為準'
        }
        default {
            if ($label) { $stable += $label }
            $stable += $facts
        }
    }

    return [string[]]@($stable | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
}

# Capture the already-hardened + Taiwan-localized builders after installing the stable allowlist above.
$script:V4A21PromptBase = (Get-Command Get-PromptV2 -ErrorAction Stop).ScriptBlock
$script:V4A21CompactBase = (Get-Command Get-CompactTransportPromptV2 -ErrorAction Stop).ScriptBlock

function Get-V4A21TextBudget([string]$Slot) {
    if ($Slot -eq 'detail3' -or $Slot -eq 'detail4') { return 3 }
    return 2
}

function Get-V4A21SlotSpecificTextRule([string]$Slot) {
    switch ($Slot) {
        'main' { return '主圖只保留商品名稱與一行核心已驗證規格；不要加腳註、小字說明或額外徽章文字。' }
        'detail1' { return 'detail1 只做一個主標題與一行已驗證規格。下方圖示只能使用純圖形，不得附加任何文字說明，也不要生成多行規格提醒。' }
        'detail2' { return 'detail2 的局部放大圖與圈選細節全部禁止加文字標籤或零件名稱；只能做無字細節放大。已驗證規格若要顯示，只能集中在單一規格區塊，不要貼在局部圖旁。' }
        'detail3' { return 'detail3 文字只用商品名稱、已驗證規格與「使用方式參考」；不要新增動作效果、訓練效果或小字說明。' }
        'detail4' { return 'detail4 只做精簡規格／選購資訊；沒有共同已驗證規格時只保留商品類別名稱與一條簡短規格提醒。' }
        default { return '只保留必要的短文字，不加小字說明。' }
    }
}

function Get-PromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A21PromptBase $Slot $ProductOrName
    $budget = Get-V4A21TextBudget $Slot
    $slotRule = Get-V4A21SlotSpecificTextRule $Slot
    return ($base + "`n[圖片文字穩定硬限制 V4-A.2.1]`n逐字白名單只是『可使用』清單，不代表每一條都必須畫進成品。整張圖最多使用 $budget 個短文字區塊；其餘寧可留白。任何文字只要無法逐字清楚正確繪製，就整句省略，不得用形近字、同音字、近似字或自行改寫替代。數量提示若需要顯示，只能逐字使用「數量規格可選」。禁止自行為商品局部結構、零件、接口、繩帶或細節命名。$slotRule")
}

function Get-CompactTransportPromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A21CompactBase $Slot $ProductOrName
    $budget = Get-V4A21TextBudget $Slot
    $slotRule = Get-V4A21SlotSpecificTextRule $Slot
    return ($base + " 圖片文字穩定規則：最多 $budget 個短文字區塊；白名單不必全部使用。文字無法逐字正確畫出就整句省略，不得用近似字替代；禁止自行為商品局部結構或零件命名。數量提示需要時只可逐字使用「數量規格可選」。$slotRule")
}
