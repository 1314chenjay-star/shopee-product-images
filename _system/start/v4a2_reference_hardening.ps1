$ErrorActionPreference = 'Stop'

function New-V4A2ReferenceProxy([string]$ProductId, [string]$Source, [double]$Risk, [bool]$HighConflict) {
    $dir = Join-Path (Get-V2Workspace) ('safe_refs\' + $ProductId)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $target = Join-Path $dir (([IO.Path]::GetFileNameWithoutExtension($Source)) + '_safe.jpg')
    $edge = 512
    if ($HighConflict) { $edge = 320 }
    elseif ($Risk -ge 0.50) { $edge = 320 }
    elseif ($Risk -ge 0.32) { $edge = 384 }

    Add-Type -AssemblyName System.Drawing
    $stream=[IO.File]::OpenRead($Source); $sourceImage=$null; $bitmap=$null; $graphics=$null
    try {
        $sourceImage=[Drawing.Image]::FromStream($stream,$true,$true)
        $largest=[Math]::Max($sourceImage.Width,$sourceImage.Height)
        if ($largest -le 0) { throw 'Reference image size invalid.' }
        $scale=[Math]::Min(1.0,$edge/[double]$largest)
        $width=[Math]::Max(1,[int][Math]::Round($sourceImage.Width*$scale)); $height=[Math]::Max(1,[int][Math]::Round($sourceImage.Height*$scale))
        $bitmap=New-Object Drawing.Bitmap $width,$height; $graphics=[Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([Drawing.Color]::White); $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $graphics.DrawImage($sourceImage,0,0,$width,$height); $bitmap.Save($target,[Drawing.Imaging.ImageFormat]::Jpeg)
    }
    finally { if($null-ne$graphics){$graphics.Dispose()}; if($null-ne$bitmap){$bitmap.Dispose()}; if($null-ne$sourceImage){$sourceImage.Dispose()}; $stream.Dispose() }
    return $target
}

function Get-ReferencesForSlotV2($Analysis, [string]$Slot, [int]$Maximum) {
    $ranked = @($Analysis.reference_safety)
    if ($ranked.Count -eq 0) {
        $ranked = @($Analysis.reference_order | ForEach-Object { [pscustomobject]@{ path=[string]$_; position=0; local_risk_score=0.5 } })
    }
    if ($ranked.Count -eq 0) { throw '沒有可用參考圖。' }
    $maximum = [Math]::Min([Math]::Max(1,$Maximum), [Math]::Min(2,$ranked.Count))
    $highConflict = [bool](Get-V4A1Property $Analysis 'high_variant_conflict' $false)
    if ($highConflict) { $maximum = 1 }

    # Safety is the primary rule. Do not rotate past the safest reference merely for slot variety.
    $picked = @()
    foreach ($candidate in @($ranked | Select-Object -First $maximum)) {
        $proxy = New-V4A2ReferenceProxy ([string]$Analysis.product_id) ([string]$candidate.path) ([double]$candidate.local_risk_score) $highConflict
        if ($picked -notcontains $proxy) { $picked += $proxy }
    }
    return [string[]]$picked
}

function Get-V4A2AllowedOutputText($Product, [string]$Slot) {
    $facts = Get-V4A1Property $Product 'verified_facts' $null
    $allowed = @(Get-V4A1AllFactValues $facts)
    $title = switch ($Slot) {
        'main' {'商品外觀一覽'}
        'detail1' {'重點細節一覽'}
        'detail2' {'商品結構與細節展示'}
        'detail3' {'使用方式參考'}
        'detail4' {'選購前請確認規格'}
        default {'商品資訊'}
    }
    $allowed += $title
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    if (Test-IsMultiVariantV4A1 $flags) {
        $allowed += @('多規格可選','請依實際選項為準','實際內容請依選項為準','不同規格內容可能不同','款式可選')
    }
    if ([bool](Get-V4A1Property $flags 'has_multiple_colors' $false)) { $allowed += '多色可選' }
    if ([bool](Get-V4A1Property $flags 'has_multiple_sizes' $false)) { $allowed += '多尺寸可選' }
    if ([bool](Get-V4A1Property $flags 'has_multiple_quantities' $false)) { $allowed += '多入數可選' }
    return [string[]]@($allowed | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
}

function Get-V4A2ReferenceSafetyPromptText($Product) {
    $highConflict = Test-V4A2HighConflictProduct $Product
    $text = '參考圖內既有的標題、規格字、促銷字、角標、圖示文字、贈品標示、品牌名稱、Logo字樣、英文印刷、數字印刷、品牌承諾與套裝文字全部視為未驗證。只要沒有出現在「成品允許文字逐字白名單」，就禁止照抄、改寫、翻譯、猜測或重新排版。若商品表面本身有未驗證品牌字、英文、縮寫、數字或標章，生成時請省略，或處理成不可辨識的中性紋理；不要重建可讀文字，也不要自行創造替代品牌。參考圖只負責商品本體輪廓、基本結構、可見配色與合理使用姿勢。'
    if ($highConflict) { $text += ' 本商品有跨規格衝突，參考圖可能只代表其中一個選項；不得把單一參考圖的顏色、材質、數量、配件、贈品、型號、表面印刷或功能當成所有規格共同事實。畫面以單一代表性商品本體為主，不用重複物件數量暗示套裝內容。' }
    return $text
}

function Get-PromptV2([string]$Slot, $ProductOrName) {
    $product = Get-V4A2ResolvedProduct $ProductOrName
    $factual = Get-FactualPromptSectionsV4A1 $product $Slot
    $allowed = @(Get-V4A2AllowedOutputText $product $Slot)
    $allowedText = if ($allowed.Count -gt 0) { $allowed -join '｜' } else { '（不生成任何可辨識文字）' }
    $role = switch ($Slot) {
        'main' { '製作1:1台灣蝦皮封面主圖。商品主體清楚完整、手機縮圖可讀。' }
        'detail1' { 'detail1：核心資訊總覽，版型不得複製主圖。' }
        'detail2' { 'detail2：商品結構與細節展示。' }
        'detail3' { 'detail3：使用方式或情境展示，可呈現合理姿勢與場景。' }
        'detail4' { 'detail4：規格／選購補充；沒有白名單規格時只做保守選購提醒。' }
        default { '製作1:1補充詳情圖。' }
    }
    return ($role + "`n" + $factual.text + "`n[成品允許文字逐字白名單]`n" + $allowedText + "`n[逐字白名單硬限制]`n成品中任何可辨識的繁中、簡中、英文、字母、數字、縮寫、品牌字樣、Logo文字、圖標文字與標章文字，都只能逐字使用上方清單。清單以外一律不要生成；不要為了版面完整自行增加『穩定支撐、彈力調節、訓練輔助、防滑、耐磨、官方、專業、室內外』等看似合理的說明。`n[Reference Safety]`n" + (Get-V4A2ReferenceSafetyPromptText $product) + "`n資訊不足寧可留白、用純視覺構圖，不得補寫。文字使用自然台灣繁體中文。")
}

function Get-CompactTransportPromptV2([string]$Slot, $ProductOrName) {
    $product = Get-V4A2ResolvedProduct $ProductOrName
    $allowed = @(Get-V4A2AllowedOutputText $product $Slot)
    $allowedText = if ($allowed.Count -gt 0) { $allowed -join '｜' } else { '不生成文字' }
    $visual = Get-V4A1VisualVariantGuardText $product
    $role = switch ($Slot) { 'main' {'封面主圖'} 'detail1' {'重點總覽'} 'detail2' {'結構細節'} 'detail3' {'使用情境'} 'detail4' {'選購補充'} default {'補充詳情'} }
    return ("製作1:1台灣蝦皮$role。成品唯一允許的可辨識文字：$allowedText。除此之外所有繁中、簡中、英文、字母、數字、縮寫、品牌、Logo文字、商品表面印刷、圖標文字都禁止生成或重建；未驗證表面字樣請省略或做成不可辨識中性紋理。$visual " + (Get-V4A2ReferenceSafetyPromptText $product) + ' 資訊不足就留白，不得補寫。')
}
