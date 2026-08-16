$ErrorActionPreference = 'Stop'

# menu_beginner.ps1 in older builds sourced this legacy layer once more after v4a1_guard.ps1.
# If the final V4-A.2 hardening + Taiwan localization layers already exist, return immediately
# so older function definitions cannot overwrite the tested runtime.
if (($null -ne (Get-Command Get-V4A2AllowedOutputText -ErrorAction SilentlyContinue)) -and
    ($null -ne (Get-Command Convert-ToTaiwanCommerceTextV4A2 -ErrorAction SilentlyContinue))) {
    return
}

function Get-V4A1VisualVariantGuardText($Product) {
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    if ($null -eq $flags) { return '' }

    $quantityVaries = [bool](Get-V4A1Property $flags 'has_multiple_quantities' $false)
    $bundleVaries = [bool](Get-V4A1Property $flags 'has_multiple_bundle_counts' $false)
    if ($quantityVaries -or $bundleVaries) {
        return '本商品的數量／組合會隨規格改變。參考圖中的多人使用、多件平鋪、重複商品數量、套裝數量與任何特定組合數，都只代表單一規格，不是所有選項的共同事實。生成圖禁止用多個重複商品單位、人數或繩帶數量暗示包裝數量；禁止照抄參考圖中的特定套裝數量或多人組合文案。以單一代表性商品外觀為主，使用情境不可用人數暗示套裝數；需要說明時只可寫「多規格可選／實際內容請依選項為準」。'
    }

    if (Test-IsMultiVariantV4A1 $flags) {
        return '本商品有多規格。參考圖中的單一規格專屬顏色、尺寸、型號、組合或數量不得被當成所有選項的共同視覺事實；畫面應保持中性，不用重複物件數量暗示規格。'
    }
    return ''
}

function Get-FactualPromptSectionsV4A1($Product, [string]$Slot) {
    $facts = Get-V4A1Property $Product 'verified_facts' $null
    $factValues = @(Get-V4A1AllFactValues $facts)
    $factText = if ($factValues.Count -gt 0) { $factValues -join '、' } else { '無已驗證具體規格；不要自行補數字、材質、配件或功效。' }
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    $variantText = if (Test-IsMultiVariantV4A1 $flags) { '本商品有多規格：只能使用所有規格共同一致的已驗證事實；任何只屬於單一選項的數量、顏色、尺寸、型號、組合或阻力值都禁止寫死，可寫「多規格可選／請依實際選項為準」。' } else { '仍只能使用已驗證事實，不得從商品名稱或常識補規格。' }
    $visualText = Get-V4A1VisualVariantGuardText $Product
    $slotTitle = switch ($Slot) { 'main' {'商品外觀一覽'} 'detail1' {'重點細節一覽'} 'detail2' {'商品細節展示'} 'detail3' {'使用方式參考'} 'detail4' {'選購前請確認規格'} default {'商品資訊'} }
    return [pscustomobject]@{
        facts = $facts
        allowed_factual_text = [string[]]@($factValues + @((Get-V4A1Rules).safe_copy) + @($slotTitle) | Select-Object -Unique)
        text = ("[已驗證可使用事實]`n" + $factText + "`n[硬性文字限制]`n所有文字型具體事實只能取自上方已驗證事實。參考圖只用來忠實保持商品外觀、結構、顏色與使用姿勢；不得因為模型自己看圖就新增未進白名單的尺寸、數字、材質、配件、贈品、內含物、功效、品牌承諾、認證或安全承諾。資訊不足就少寫，不得為填滿版面補內容。`n[多規格限制]`n" + $variantText + "`n[視覺數量限制]`n" + $visualText)
    }
}

function Get-PromptV2([string]$Slot, $Product) {
    if ($Product -is [string]) { $Product = [pscustomobject]@{ product_name=[string]$Product } }
    $factual = Get-FactualPromptSectionsV4A1 $Product $Slot
    $role = switch ($Slot) {
        'main' { '製作1:1台灣蝦皮封面主圖。商品主體清楚完整、手機縮圖可讀；使用一個低風險主標題與少量已驗證資訊。' }
        'detail1' { 'detail1：核心資訊總覽。只整理白名單已驗證資訊與商品本體可見細節，版型不得複製主圖。' }
        'detail2' { 'detail2：商品結構與細節展示。只有白名單確認的配件或內含物才能標成隨附內容；否則只展示商品本體細節。' }
        'detail3' { 'detail3：使用方式或情境展示。可呈現姿勢與場景，但不得自行寫運動效果、醫療效果或性能提升。' }
        'detail4' { 'detail4：規格／選購補充。只有白名單已有數值才可做尺寸規格；沒有就做保守選購提醒，不填假數字。' }
        default { '製作1:1補充詳情圖，只呈現已驗證資訊。' }
    }
    return ("依提供的真實參考圖辨識並忠實保持商品本體；不要把蝦皮完整商品標題當成生圖事實來源，也不要自行補商品名稱中的宣稱。`n$role`n" + $factual.text + "`n文字使用自然台灣繁體中文，不用中國大陸電商浮誇詞。")
}

function Get-CompactTransportPromptV2([string]$Slot, $Product) {
    if ($Product -is [string]) { $Product = [pscustomobject]@{ product_name=[string]$Product } }
    $facts = @(Get-V4A1AllFactValues (Get-V4A1Property $Product 'verified_facts' $null))
    $factText = if ($facts.Count -gt 0) { $facts -join '、' } else { '無具體規格白名單' }
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    $variant = if (Test-IsMultiVariantV4A1 $flags) { '多規格，只能寫所有選項共同事實。' } else { '' }
    $visual = Get-V4A1VisualVariantGuardText $Product
    $role = switch ($Slot) { 'main' {'封面主圖'} 'detail1' {'重點總覽'} 'detail2' {'結構細節'} 'detail3' {'使用情境'} 'detail4' {'選購補充'} default {'補充詳情'} }
    return ("製作1:1台灣蝦皮$role。只依真實參考圖辨識商品本體，不使用完整商品標題補事實。已驗證事實：$factText。$variant 所有具體數字、尺寸、材質、配件、贈品、內含物、功效、認證與安全承諾，未列入已驗證事實就禁止生成；資訊不足就少寫。$visual 忠實保持商品本體外觀與結構，使用自然台灣繁體中文。")
}
