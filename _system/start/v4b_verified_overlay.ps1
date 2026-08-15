$ErrorActionPreference = 'Stop'

$script:V4BOverlayPromptBase = (Get-Command Get-PromptV2 -ErrorAction Stop).ScriptBlock
$script:V4BOverlayCompactBase = (Get-Command Get-CompactTransportPromptV2 -ErrorAction Stop).ScriptBlock
$script:V4BFinalJpegBase = (Get-Command Convert-ToFinalJpegV2 -ErrorAction Stop).ScriptBlock
$script:V4BPendingOverlay = $null

function Get-V4BOverlayFactValues($Product, [string]$Slot) {
    if ($null -eq $Product) { return [string[]]@() }
    $facts = Get-V4A1Property $Product 'verified_facts' $null
    if ($null -eq $facts) { return [string[]]@() }
    $priority = @('verified_dimensions','verified_resistance_levels','verified_models','verified_sizes','verified_materials','verified_accessories','verified_colors','verified_bundle_contents','verified_features')
    $values = @()
    foreach ($name in $priority) {
        foreach ($raw in @(Get-V4A1Property $facts $name @())) {
            $text = Convert-ToTaiwanCommerceTextV4B ([string]$raw)
            if (-not [string]::IsNullOrWhiteSpace($text) -and $values -notcontains $text) { $values += $text }
        }
    }
    return [string[]]@($values | Select-Object -First 4)
}

function Get-V4BVerifiedOverlayContent($Product, [string]$Slot) {
    $title = Get-V4BSafeProductLabel $Product
    if ([string]::IsNullOrWhiteSpace($title) -or $title -eq '商品') { $title = if ($Slot -eq 'main') { '商品展示' } else { '商品資訊' } }
    $facts = @(Get-V4BOverlayFactValues $Product $Slot)
    $secondary = ''
    if ($facts.Count -gt 0) { $secondary = $facts -join ' ・ ' }
    else {
        $generic = @(Get-V4BGenericCopyForSlot $Product $Slot $true)
        if ($generic.Count -gt 0) { $secondary = (@($generic | Select-Object -First 2) -join ' ・ ') }
    }
    return [pscustomobject]@{title=Convert-ToTaiwanCommerceTextV4B ([string]$title);secondary=Convert-ToTaiwanCommerceTextV4B ([string]$secondary);facts=[string[]]$facts;deterministic=$true}
}

function Set-V4BPendingOverlay($Product, [string]$Slot) {
    $plan = Get-V4BCurrentSourcePlan
    $slotPlan = Get-V4BPlanSlot $plan $Slot
    if ($null -ne $slotPlan -and [bool](Get-V4A1Property $slotPlan 'text_shield_required' $false)) {
        $script:V4BPendingOverlay = [pscustomobject]@{product=$Product;slot=$Slot;product_id=[string](Get-V4A1Property $Product 'product_id' '');content=Get-V4BVerifiedOverlayContent $Product $Slot}
        return $true
    }
    $script:V4BPendingOverlay = $null
    return $false
}

function Get-V4BInstalledOverlayFontName {
    Add-Type -AssemblyName System.Drawing
    foreach ($name in @('Microsoft JhengHei UI','Microsoft JhengHei','Noto Sans CJK TC','Arial Unicode MS','Arial')) {
        $font = $null
        try {
            $fontArgs = @([string]$name,[single]12,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
            $font = New-Object Drawing.Font -ArgumentList $fontArgs
            if ($null -ne $font -and -not [string]::IsNullOrWhiteSpace($font.Name)) {
                $resolved = [string]$font.Name
                $font.Dispose()
                return $resolved
            }
        }
        catch { if ($null -ne $font) { $font.Dispose() } }
    }
    return 'Arial'
}

function New-V4BFittedFont($Graphics, [string]$FontName, [string]$Text, [float]$StartSize, [float]$MinSize, [float]$MaxWidth, [bool]$Bold) {
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $size = $StartSize
    while ($size -ge $MinSize) {
        $fontArgs = @([string]$FontName,[single]$size,$style,[Drawing.GraphicsUnit]::Pixel)
        $font = New-Object Drawing.Font -ArgumentList $fontArgs
        $measured = $Graphics.MeasureString($Text,$font)
        if ($measured.Width -le $MaxWidth) { return $font }
        $font.Dispose()
        $size -= 2
    }
    $minArgs = @([string]$FontName,[single]$MinSize,$style,[Drawing.GraphicsUnit]::Pixel)
    return (New-Object Drawing.Font -ArgumentList $minArgs)
}

function Add-V4BVerifiedOverlay([string]$Path, $Content) {
    if ($null -eq $Content -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    Add-Type -AssemblyName System.Drawing
    $source = New-Object Drawing.Bitmap $Path
    $bitmap = New-Object Drawing.Bitmap $source.Width,$source.Height
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $background = $null; $titleBrush = $null; $secondaryBrush = $null; $borderPen = $null; $titleFont = $null; $secondaryFont = $null
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.DrawImage($source,0,0,$source.Width,$source.Height)
        $width = [float]$source.Width; $height = [float]$source.Height
        $cardHeight = [Math]::Max(132.0,[Math]::Round($height*0.17)); $cardY = $height-$cardHeight
        $paddingX = [Math]::Max(28.0,[Math]::Round($width*0.04)); $maxTextWidth = $width-2.0*$paddingX
        $background = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(205,18,18,18)); $graphics.FillRectangle($background,0,$cardY,$width,$cardHeight)
        $penArgs = @([Drawing.Color]::FromArgb(120,255,255,255),[single]1)
        $borderPen = New-Object Drawing.Pen -ArgumentList $penArgs; $graphics.DrawLine($borderPen,0,$cardY,$width,$cardY)
        $fontName = Get-V4BInstalledOverlayFontName
        $title=[string](Get-V4A1Property $Content 'title' '');$secondary=[string](Get-V4A1Property $Content 'secondary' '')
        $titleFont=New-V4BFittedFont $graphics $fontName $title ([float]($height*0.045)) ([float]24) $maxTextWidth $true
        $secondaryFont=New-V4BFittedFont $graphics $fontName $secondary ([float]($height*0.030)) ([float]18) $maxTextWidth $false
        $titleBrush=New-Object Drawing.SolidBrush ([Drawing.Color]::White);$secondaryBrush=New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(235,235,235))
        $titleY=$cardY+[Math]::Max(12.0,[Math]::Round($cardHeight*0.13));$graphics.DrawString($title,$titleFont,$titleBrush,[float]$paddingX,[float]$titleY)
        if(-not[string]::IsNullOrWhiteSpace($secondary)){$secondaryY=$titleY+$titleFont.Height+[Math]::Max(7.0,[Math]::Round($cardHeight*0.05));$graphics.DrawString($secondary,$secondaryFont,$secondaryBrush,[float]$paddingX,[float]$secondaryY)}
        $temp=$Path+'.v4b_overlay.jpg';$bitmap.Save($temp,[Drawing.Imaging.ImageFormat]::Jpeg)
        $source.Dispose();$source=$null;$graphics.Dispose();$graphics=$null;$bitmap.Dispose();$bitmap=$null;Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        if($null-ne$secondaryFont){$secondaryFont.Dispose()};if($null-ne$titleFont){$titleFont.Dispose()};if($null-ne$borderPen){$borderPen.Dispose()};if($null-ne$secondaryBrush){$secondaryBrush.Dispose()};if($null-ne$titleBrush){$titleBrush.Dispose()};if($null-ne$background){$background.Dispose()};if($null-ne$graphics){$graphics.Dispose()};if($null-ne$bitmap){$bitmap.Dispose()};if($null-ne$source){$source.Dispose()}
    }
}

function Get-PromptV2([string]$Slot, $ProductOrName) {
    $product=Get-V4BResolvedProduct $ProductOrName;$base=& $script:V4BOverlayPromptBase $Slot $ProductOrName;$shielded=Set-V4BPendingOverlay $product $Slot
    if($shielded){$base+="`n[V4-B 程式化驗證文字覆蓋]`n本張 TinySnow 階段只製作乾淨、忠實的商品視覺。不要生成任何可辨識文字、數字、單位、徽章、icon 字母或標題；請保留畫面下方約 17% 的乾淨空間或簡潔背景。生成完成後，Windows 程式會自行疊加共同已驗證的台灣繁體文字，因此不要自行補任何文字。"}
    return $base
}

function Get-CompactTransportPromptV2([string]$Slot, $ProductOrName) {
    $product=Get-V4BResolvedProduct $ProductOrName;$base=& $script:V4BOverlayCompactBase $Slot $ProductOrName;$shielded=Set-V4BPendingOverlay $product $Slot
    if($shielded){$base+=' 本張 TinySnow 只輸出乾淨商品視覺，不生成任何可讀文字、數字、單位或帶字母 icon；下方留乾淨空間，驗證文字由 Windows 程式後處理疊加。'}
    return $base
}

function Convert-ToFinalJpegV2([string]$Source, [string]$Target) {
    $result=& $script:V4BFinalJpegBase $Source $Target;$pending=$script:V4BPendingOverlay;$script:V4BPendingOverlay=$null
    if($null-ne$pending){Add-V4BVerifiedOverlay $Target $pending.content;return(Get-ImageInfoV2 $Target)}
    return $result
}
