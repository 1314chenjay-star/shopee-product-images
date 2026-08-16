$ErrorActionPreference = 'Stop'

function Get-V4A2ResolvedProduct($ProductOrName) {
    if ($null -ne $ProductOrName -and -not ($ProductOrName -is [string])) {
        return $ProductOrName
    }
    try {
        $selected = Get-SelectedProductV2
        if ($null -ne $selected) {
            if (-not ($selected.PSObject.Properties.Name -contains 'verified_facts')) {
                $selected = Initialize-ProductFactualDataV4A1 $selected
            }
            return $selected
        }
    }
    catch {}
    return [pscustomobject]@{
        product_id = ''
        product_name = ''
        product_category = ''
        variants = @()
        verified_facts = (Build-ProductVerifiedFactsV4A1 @())
        multi_variant_flags = (Build-MultiVariantFlagsV4A1 @())
        factual_categories = @('universal')
    }
}

function Test-V4A2HighConflictProduct($Product) {
    if ($null -eq $Product) { return $false }
    $facts = @(Get-V4A1Property $Product 'variant_facts' @())
    if ($facts.Count -le 1) { return $false }
    foreach ($name in @('materials','accessories','colors','sizes','models','quantities','resistance_levels','bundle_contents')) {
        if (@(Get-V4A1DistinctSignatures $facts $name).Count -gt 1) { return $true }
    }
    return [bool](Get-V4A1Property (Get-V4A1Property $Product 'multi_variant_flags' $null) 'has_multiple_variants' $false)
}

function Get-V4A2ImageSignal([string]$Path, [int]$Position) {
    Add-Type -AssemblyName System.Drawing
    $source = New-Object Drawing.Bitmap $Path
    $small = New-Object Drawing.Bitmap 48,48
    $graphics = [Drawing.Graphics]::FromImage($small)
    try {
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $graphics.DrawImage($source, 0, 0, 48, 48)
        $gray = @()
        $saturation = @()
        for ($y = 0; $y -lt 48; $y++) {
            for ($x = 0; $x -lt 48; $x++) {
                $pixel = $small.GetPixel($x, $y)
                $gray += [double](0.299 * $pixel.R + 0.587 * $pixel.G + 0.114 * $pixel.B)
                $max = [Math]::Max($pixel.R, [Math]::Max($pixel.G, $pixel.B))
                $min = [Math]::Min($pixel.R, [Math]::Min($pixel.G, $pixel.B))
                $saturation += [double]($max - $min)
            }
        }

        $outerEdge = 0.0; $outerCount = 0; $outerSharp = 0
        $centerEdge = 0.0; $centerCount = 0
        $allEdge = 0.0; $allCount = 0; $allSharp = 0
        $centerSat = 0.0; $centerSatCount = 0
        for ($y = 0; $y -lt 47; $y++) {
            for ($x = 0; $x -lt 47; $x++) {
                $index = $y * 48 + $x
                $edge = [Math]::Min(255.0, [Math]::Abs($gray[$index] - $gray[$index + 1]) + [Math]::Abs($gray[$index] - $gray[$index + 48]))
                $allEdge += $edge; $allCount++
                if ($edge -ge 55) { $allSharp++ }
                $isOuter = ($x -lt 10 -or $x -ge 38 -or $y -lt 10 -or $y -ge 38)
                if ($isOuter) {
                    $outerEdge += $edge; $outerCount++
                    if ($edge -ge 55) { $outerSharp++ }
                }
                elseif ($x -ge 12 -and $x -lt 36 -and $y -ge 12 -and $y -lt 36) {
                    $centerEdge += $edge; $centerCount++
                    $centerSat += $saturation[$index]; $centerSatCount++
                }
            }
        }
        $outerMean = if ($outerCount -gt 0) { $outerEdge / ($outerCount * 255.0) } else { 0.0 }
        $centerMean = if ($centerCount -gt 0) { $centerEdge / ($centerCount * 255.0) } else { 0.0 }
        $allMean = if ($allCount -gt 0) { $allEdge / ($allCount * 255.0) } else { 0.0 }
        $outerSharpRatio = if ($outerCount -gt 0) { $outerSharp / [double]$outerCount } else { 0.0 }
        $allSharpRatio = if ($allCount -gt 0) { $allSharp / [double]$allCount } else { 0.0 }
        $centerSaturation = if ($centerSatCount -gt 0) { $centerSat / ($centerSatCount * 255.0) } else { 0.0 }

        $risk = 0.08
        $risk += [Math]::Min(0.38, $outerSharpRatio * 1.25)
        $risk += [Math]::Min(0.18, [Math]::Max(0.0, $outerMean - $centerMean) * 1.8)
        if ($allSharpRatio -gt 0.24) { $risk += 0.10 }
        if ($Position -eq 0) { $risk += 0.12 }
        $risk = [Math]::Max(0.0, [Math]::Min(1.0, $risk))
        $safe = [Math]::Max(0.0, [Math]::Min(1.0, 1.0 - $risk + [Math]::Min(0.08, $centerMean * 0.25) + [Math]::Min(0.05, $centerSaturation * 0.10)))
        return [pscustomobject]@{
            edge_density = [Math]::Round($allMean,4)
            outer_edge_density = [Math]::Round($outerMean,4)
            center_edge_density = [Math]::Round($centerMean,4)
            outer_sharp_ratio = [Math]::Round($outerSharpRatio,4)
            center_saturation = [Math]::Round($centerSaturation,4)
            local_risk_score = [Math]::Round($risk,4)
            local_safe_score = [Math]::Round($safe,4)
        }
    }
    finally {
        $graphics.Dispose(); $small.Dispose(); $source.Dispose()
    }
}

function Analyze-ProductImagesV2([string]$ProductId, [string[]]$Paths) {
    if ($ProductId -notmatch '^\d{5,30}$') { throw '商品ID格式錯誤。' }
    if ($null -eq $Paths -or $Paths.Count -eq 0) { throw '沒有可分析的原圖。' }
    $product = Get-V4A2ResolvedProduct $null
    $highConflict = Test-V4A2HighConflictProduct $product
    $seen = @{}; $items = @(); $references = @(); $safety = @()

    for ($position = 0; $position -lt $Paths.Count; $position++) {
        $imagePath = [string]$Paths[$position]
        $info = Get-ImageInfoV2 $imagePath
        $duplicate = $seen.ContainsKey($info.hash)
        if (-not $duplicate) { $seen[$info.hash] = $true }
        $ratio = if ($info.height -gt 0) { $info.width / [double]$info.height } else { 0 }
        $signal = Get-V4A2ImageSignal $imagePath $position
        $risk = [double]$signal.local_risk_score
        if ($highConflict -and $position -eq 0) { $risk = [Math]::Min(1.0, $risk + 0.12) }
        $safe = [Math]::Max(0.0, 1.0 - $risk)
        $item = [pscustomobject]@{
            path=$imagePath; file=(Split-Path $imagePath -Leaf); position=$position; width=$info.width; height=$info.height;
            bytes=$info.length; sha256=$info.hash; duplicate=$duplicate; near_square=([Math]::Abs($ratio - 1.0) -le 0.15);
            edge_density=$signal.edge_density; outer_edge_density=$signal.outer_edge_density; center_edge_density=$signal.center_edge_density;
            outer_sharp_ratio=$signal.outer_sharp_ratio; local_risk_score=[Math]::Round($risk,4); local_safe_score=[Math]::Round($safe,4)
        }
        $items += $item
        if (-not $duplicate) {
            $references += $imagePath
            $safety += $item
        }
    }

    $ranked = @($safety | Sort-Object @{Expression='local_risk_score';Ascending=$true}, @{Expression='position';Ascending=$true})
    $analysis = [pscustomobject]@{
        product_id=$ProductId; analyzed_at=(Get-Date).ToString('o'); semantic_check='local_visual_risk_proxy_only_no_ocr';
        all_originals_participated=$true; high_variant_conflict=$highConflict; images=@($items); reference_order=@($references);
        reference_safety=@($ranked); failed=$false
    }
    $folder = Split-Path $Paths[0] -Parent
    $analysis | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'analysis.json') -Encoding UTF8
    $lines = @('商品ID：' + $ProductId, '可用原圖：' + $items.Count + ' 張', '所有可用原圖均已參與 Reference Safety 本地分析。', '本地分析不做 OCR、不假裝能讀懂圖片文字；只用畫面邊緣密度、外圍高頻與多規格結構做風險排序。', '')
    foreach ($item in $ranked) { $lines += ('{0}｜risk={1:N3}｜edge={2:N3}｜outer={3:N3}｜position={4}' -f $item.file,$item.local_risk_score,$item.edge_density,$item.outer_edge_density,$item.position) }
    $lines | Set-Content -LiteralPath (Join-Path $folder 'analysis_summary.txt') -Encoding UTF8
    return $analysis
}

function New-V4A2ReferenceProxy([string]$ProductId, [string]$Source, [double]$Risk, [bool]$HighConflict) {
    if (-not $HighConflict -and $Risk -lt 0.36) { return $Source }
    $dir = Join-Path (Get-V2Workspace) ('safe_refs\' + $ProductId)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $target = Join-Path $dir (([IO.Path]::GetFileNameWithoutExtension($Source)) + '_safe.jpg')
    $edge = if ($Risk -ge 0.58) { 384 } elseif ($HighConflict) { 512 } else { 768 }
    Add-Type -AssemblyName System.Drawing
    $stream=[IO.File]::OpenRead($Source); $sourceImage=$null; $bitmap=$null; $graphics=$null
    try {
        $sourceImage=[Drawing.Image]::FromStream($stream,$true,$true)
        $largest=[Math]::Max($sourceImage.Width,$sourceImage.Height)
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
    $maximum = [Math]::Min([Math]::Max(1,$Maximum), $ranked.Count)
    $highConflict = [bool](Get-V4A1Property $Analysis 'high_variant_conflict' $false)
    if ($highConflict) { $maximum = 1 }
    $offsets = @{ main=0; detail1=1; detail2=2; detail3=3; detail4=4 }
    $offset = if ($offsets.ContainsKey($Slot)) { [int]$offsets[$Slot] } else { 0 }
    $poolCount = [Math]::Min([Math]::Max(1, [Math]::Min(5,$ranked.Count)), $ranked.Count)
    $pool = @($ranked | Select-Object -First $poolCount)
    $picked = @()
    for ($i=0; $i -lt $pool.Count -and $picked.Count -lt $maximum; $i++) {
        $candidate = $pool[($offset + $i) % $pool.Count]
        $proxy = New-V4A2ReferenceProxy ([string]$Analysis.product_id) ([string]$candidate.path) ([double]$candidate.local_risk_score) $highConflict
        if ($picked -notcontains $proxy) { $picked += $proxy }
    }
    return [string[]]$picked
}

function Get-V4A2ReferenceSafetyPromptText($Product) {
    $highConflict = Test-V4A2HighConflictProduct $Product
    $text = '參考圖內既有的標題、規格字、促銷字、角標、功能圖示、贈品標示、品牌承諾與套裝文字一律視為未驗證，不得照抄、改寫或重新排版；只有已驗證事實白名單中的文字可以出現在成品。參考圖只負責商品本體外觀、基本結構與合理使用姿勢。'
    if ($highConflict) { $text += ' 本商品有跨規格衝突，參考圖可能只代表其中一個選項；不得把單一參考圖的顏色、材質、數量、配件、贈品、型號或功能當成所有規格共同事實。畫面以單一代表性商品本體為主，不用重複物件數量暗示套裝內容。' }
    return $text
}

function Get-PromptV2([string]$Slot, $ProductOrName) {
    $product = Get-V4A2ResolvedProduct $ProductOrName
    $factual = Get-FactualPromptSectionsV4A1 $product $Slot
    $role = switch ($Slot) {
        'main' { '製作1:1台灣蝦皮封面主圖。商品主體清楚完整、手機縮圖可讀；只用低風險標題與白名單資訊。' }
        'detail1' { 'detail1：核心資訊總覽。只整理白名單已驗證資訊與商品本體可見細節，版型不得複製主圖。' }
        'detail2' { 'detail2：商品結構與細節展示。只有白名單確認的配件或內含物才能標成隨附內容。' }
        'detail3' { 'detail3：使用方式或情境展示。可呈現姿勢與場景，不得自行寫運動效果、醫療效果或性能提升。' }
        'detail4' { 'detail4：規格／選購補充。只有白名單已有數值才可做尺寸規格；沒有就做保守選購提醒。' }
        default { '製作1:1補充詳情圖，只呈現已驗證資訊。' }
    }
    return ($role + "`n" + $factual.text + "`n[Reference Safety]`n" + (Get-V4A2ReferenceSafetyPromptText $product) + "`n文字使用自然台灣繁體中文，不用中國大陸電商浮誇詞。")
}

function Get-CompactTransportPromptV2([string]$Slot, $ProductOrName) {
    $product = Get-V4A2ResolvedProduct $ProductOrName
    $facts = @(Get-V4A1AllFactValues (Get-V4A1Property $product 'verified_facts' $null))
    $factText = if ($facts.Count -gt 0) { $facts -join '、' } else { '無具體規格白名單' }
    $flags = Get-V4A1Property $product 'multi_variant_flags' $null
    $variant = if (Test-IsMultiVariantV4A1 $flags) { '多規格，只能寫所有選項共同事實。' } else { '' }
    $visual = Get-V4A1VisualVariantGuardText $product
    $role = switch ($Slot) { 'main' {'封面主圖'} 'detail1' {'重點總覽'} 'detail2' {'結構細節'} 'detail3' {'使用情境'} 'detail4' {'選購補充'} default {'補充詳情'} }
    return ("製作1:1台灣蝦皮$role。已驗證事實：$factText。$variant 所有具體數字、尺寸、材質、配件、贈品、內含物、功效、認證與安全承諾，未列入已驗證事實就禁止生成；資訊不足就少寫。$visual " + (Get-V4A2ReferenceSafetyPromptText $product) + ' 使用自然台灣繁體中文。')
}
