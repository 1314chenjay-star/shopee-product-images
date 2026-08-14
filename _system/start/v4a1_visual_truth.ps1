$ErrorActionPreference = 'Stop'

function Get-V4A1VisualVariantGuardText($Product) {
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    if ($null -eq $flags) { return '' }

    $quantityVaries = [bool](Get-V4A1Property $flags 'has_multiple_quantities' $false)
    $bundleVaries = [bool](Get-V4A1Property $flags 'has_multiple_bundle_counts' $false)
    if ($quantityVaries -or $bundleVaries) {
        return '本商品的數量／組合會隨規格改變。參考圖中的多人聯動、多件平鋪、重複商品數量、套裝數量或「一套／五套」等畫面都只代表特定規格，不是所有選項的共同事實。生成圖禁止用多個重複商品單位、人數或繩帶數量暗示包裝數量；不得復刻「五人聯動／五套裝」作為商品內容。以單一代表性商品外觀為主，使用情境不可用人數暗示套裝數；需要說明時只可寫「多規格可選／實際內容請依選項為準」。'
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

function Get-CompactTransportPromptV2([string]$Slot, $Product) {
    if ($Product -is [string]) { $Product = [pscustomobject]@{ product_name=[string]$Product } }
    $facts = @(Get-V4A1AllFactValues (Get-V4A1Property $Product 'verified_facts' $null))
    $factText = if ($facts.Count -gt 0) { $facts -join '、' } else { '無具體規格白名單' }
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    $variant = if (Test-IsMultiVariantV4A1 $flags) { '多規格，只能寫所有選項共同事實。' } else { '' }
    $visual = Get-V4A1VisualVariantGuardText $Product
    $role = switch ($Slot) { 'main' {'封面主圖'} 'detail1' {'重點總覽'} 'detail2' {'結構細節'} 'detail3' {'使用情境'} 'detail4' {'選購補充'} default {'補充詳情'} }
    return ("製作1:1台灣蝦皮$role。已驗證事實：$factText。$variant 所有具體數字、尺寸、材質、配件、贈品、內含物、功效、認證與安全承諾，未列入已驗證事實就禁止生成；資訊不足就少寫。$visual 忠實保持商品本體外觀與結構，使用自然台灣繁體中文。")
}
