$ErrorActionPreference = 'Stop'

# Preserve the fully-hardened prompt builders, then add a final icon/surface-text rule.
$script:V4A2PromptR1 = (Get-Command Get-PromptV2 -ErrorAction Stop).ScriptBlock
$script:V4A2CompactR1 = (Get-Command Get-CompactTransportPromptV2 -ErrorAction Stop).ScriptBlock

function Get-PromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A2PromptR1 $Slot $ProductOrName
    return ($base + "`n[圖示與單位硬限制]`n不要生成任何含可辨識文字、拉丁字母、數字或單位縮寫的圖示／徽章／icon。已驗證規格若需要顯示，直接使用逐字白名單中的完整文字，不要另外配任何帶字母、數字或單位的圖示。純圖形圖示可以使用，但圖示內不得有任何文字。`n[商品表面印字硬限制]`n若逐字白名單沒有品牌或表面印字，商品表面的中文、英文、數字、縮寫、品牌名稱、Logo 字母與標章必須省略或模糊成不可辨識的中性紋理；禁止重建、猜測或補全任何可讀字樣，也不要在負面提示中複述參考圖上的實際字詞。")
}

function Get-CompactTransportPromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A2CompactR1 $Slot $ProductOrName
    return ($base + ' 禁止任何含可辨識文字、拉丁字母、數字或單位縮寫的圖示／徽章；已驗證規格只能直接使用逐字白名單中的完整文字。未列入白名單的商品表面品牌、Logo、中文、英文、縮寫、數字與標章必須省略或做成不可辨識中性紋理，禁止重建、猜測或補全可讀字樣。')
}

function New-V4A2ReferenceProxy([string]$ProductId, [string]$Source, [double]$Risk, [bool]$HighConflict) {
    $dir = Join-Path (Get-V2Workspace) ('safe_refs\' + $ProductId)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $target = Join-Path $dir (([IO.Path]::GetFileNameWithoutExtension($Source)) + '_safe.jpg')

    $outputEdge = if ($HighConflict) { 320 } else { 512 }
    $stageEdge = if ($HighConflict) { 128 } elseif ($Risk -ge 0.50) { 160 } elseif ($Risk -ge 0.32) { 256 } else { 384 }

    Add-Type -AssemblyName System.Drawing
    $stream=[IO.File]::OpenRead($Source)
    $sourceImage=$null; $stage=$null; $stageGraphics=$null; $output=$null; $outputGraphics=$null
    try {
        $sourceImage=[Drawing.Image]::FromStream($stream,$true,$true)
        $largest=[Math]::Max($sourceImage.Width,$sourceImage.Height)
        if ($largest -le 0) { throw 'Reference image size invalid.' }

        $stageScale=[Math]::Min(1.0,$stageEdge/[double]$largest)
        $stageW=[Math]::Max(1,[int][Math]::Round($sourceImage.Width*$stageScale))
        $stageH=[Math]::Max(1,[int][Math]::Round($sourceImage.Height*$stageScale))
        $stage=New-Object Drawing.Bitmap $stageW,$stageH
        $stageGraphics=[Drawing.Graphics]::FromImage($stage)
        $stageGraphics.Clear([Drawing.Color]::White)
        $stageGraphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $stageGraphics.DrawImage($sourceImage,0,0,$stageW,$stageH)

        $outputScale=$outputEdge/[double][Math]::Max($stageW,$stageH)
        $outputW=[Math]::Max(1,[int][Math]::Round($stageW*$outputScale))
        $outputH=[Math]::Max(1,[int][Math]::Round($stageH*$outputScale))
        $output=New-Object Drawing.Bitmap $outputW,$outputH
        $outputGraphics=[Drawing.Graphics]::FromImage($output)
        $outputGraphics.Clear([Drawing.Color]::White)
        $outputGraphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $outputGraphics.DrawImage($stage,0,0,$outputW,$outputH)
        $output.Save($target,[Drawing.Imaging.ImageFormat]::Jpeg)
    }
    finally {
        if($null-ne$outputGraphics){$outputGraphics.Dispose()}
        if($null-ne$output){$output.Dispose()}
        if($null-ne$stageGraphics){$stageGraphics.Dispose()}
        if($null-ne$stage){$stage.Dispose()}
        if($null-ne$sourceImage){$sourceImage.Dispose()}
        $stream.Dispose()
    }
    return $target
}
