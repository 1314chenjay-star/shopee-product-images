$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'

& (Join-Path $startRoot 'self_check.ps1')
if ($LASTEXITCODE -ne 0) { throw 'self_check failed' }

. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')

$workspace = Join-Path $systemRoot 'workspace'
Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $workspace -Force | Out-Null

$tempRoot = Join-Path $env:TEMP ('shopee_v2_smoke_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    # 1) Build a minimal XLSX ZIP containing Shopee-like rows.
    $xlsxRoot = Join-Path $tempRoot 'xlsx'
    $sheetDir = Join-Path $xlsxRoot 'xl\worksheets'
    New-Item -ItemType Directory -Path $sheetDir -Force | Out-Null

    $sheetXml = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData>
    <row r="1"><c r="A1" t="inlineStr"><is><t>internal</t></is></c></row>
    <row r="3"><c r="A3" t="inlineStr"><is><t>商品ID</t></is></c><c r="C3" t="inlineStr"><is><t>商品名稱</t></is></c><c r="E3" t="inlineStr"><is><t>主商品圖片</t></is></c></row>
    <row r="7">
      <c r="A7" t="inlineStr"><is><t>58015741169</t></is></c>
      <c r="C7" t="inlineStr"><is><t>測試商品一</t></is></c>
      <c r="E7" t="inlineStr"><is><t>https://example.com/main.jpg</t></is></c>
      <c r="F7" t="inlineStr"><is><t>https://example.com/detail1.jpg</t></is></c>
    </row>
    <row r="8">
      <c r="A8" t="inlineStr"><is><t>48565764183</t></is></c>
      <c r="C8" t="inlineStr"><is><t>測試商品二</t></is></c>
      <c r="E8" t="inlineStr"><is><t>https://example.com/main2.jpg</t></is></c>
    </row>
  </sheetData>
</worksheet>
'@
    Set-Content -LiteralPath (Join-Path $sheetDir 'sheet1.xml') -Value $sheetXml -Encoding UTF8

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $xlsxPath = Join-Path $tempRoot 'shopee_test.xlsx'
    [IO.Compression.ZipFile]::CreateFromDirectory($xlsxRoot, $xlsxPath)

    $products = @(Save-ImportedCatalogV2 $xlsxPath)
    if ($products.Count -ne 2) { throw ('Excel import expected 2 products, got ' + $products.Count) }
    if ([string]$products[1].product_id -ne '48565764183') { throw '11-digit product ID was not preserved as text.' }

    # 2) Selection must accept long numeric IDs without Int32 conversion.
    $selected = Select-ShopeeProductV2 '48565764183'
    if ([string]$selected.product_id -ne '48565764183') { throw 'Product selection failed.' }
    $selectedAgain = Get-SelectedProductV2
    if ([string]$selectedAgain.product_id -ne '48565764183') { throw 'Selected product persistence failed.' }

    # 3) Local image analysis with duplicate detection.
    Add-Type -AssemblyName System.Drawing
    $imageDir = Join-Path $tempRoot 'images'
    New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
    $img1 = Join-Path $imageDir 'a.png'
    $img2 = Join-Path $imageDir 'b.png'
    $bmp = New-Object Drawing.Bitmap 1024,1024
    try {
        $bmp.SetPixel(0,0,[Drawing.Color]::Black)
        $bmp.Save($img1,[Drawing.Imaging.ImageFormat]::Png)
        Copy-Item -LiteralPath $img1 -Destination $img2
    }
    finally { $bmp.Dispose() }

    $analysis = Analyze-ProductImagesV2 '48565764183' ([string[]]@($img1,$img2))
    if (@($analysis.images).Count -ne 2) { throw 'Image analysis item count failed.' }
    if (@($analysis.reference_order).Count -ne 1) { throw 'Duplicate image detection failed.' }

    # 4) Checkpoint must create exactly five slots.
    $checkpoint = Get-CheckpointV2 '48565764183'
    $slotCount = @($checkpoint.states.PSObject.Properties).Count
    if ($slotCount -ne 5) { throw ('Checkpoint expected 5 slots, got ' + $slotCount) }

    # 5) Prompt templates must load.
    $prompt = Get-PromptV2 'main' '測試商品'
    if ([string]::IsNullOrWhiteSpace($prompt)) { throw 'Prompt template load failed.' }

    # 6) Final images must be flat in 已生成圖片 beside START.bat; no ZIP is created.
    $finalDir = Get-GeneratedImagesDirectoryV2
    $names = @('main','detail1','detail2','detail3','detail4')
    foreach ($slot in $names) {
        $target = Join-Path $finalDir ('48565764183_' + $slot + '.jpg')
        $bitmap = New-Object Drawing.Bitmap 1024,1024
        try { $bitmap.Save($target,[Drawing.Imaging.ImageFormat]::Jpeg) }
        finally { $bitmap.Dispose() }
    }
    if ((Split-Path $finalDir -Parent) -ne (Get-V2ProjectRoot)) { throw 'Final output is not beside START.bat.' }
    if (Get-Command New-ProductZipV2 -ErrorAction SilentlyContinue) { throw 'ZIP function should have been removed.' }

    # 7) Progress summary exposes six understandable steps and counters.
    $checkpoint = Get-CheckpointV2 '48565764183'
    $checkpoint.download_complete = $true
    $checkpoint.analysis_complete = $true
    $checkpoint.finalization_complete = $true
    foreach ($slot in $names) { $checkpoint.states.$slot.status = 'done' }
    Set-CheckpointActivityV2 $checkpoint '已完成' '測試完成'
    $progress = Get-ProgressSummaryV2 $selected
    if ($progress.completed_steps -ne 6 -or $progress.generated -ne 5 -or $progress.failed -ne 0) { throw 'Progress summary failed.' }

    Write-Host '[PASS] Windows V2 smoke test passed: Excel -> selection -> image analysis -> checkpoint -> flat output -> progress.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($slot in @('main','detail1','detail2','detail3','detail4')) {
        Remove-Item -LiteralPath (Join-Path (Get-GeneratedImagesDirectoryV2) ('48565764183_' + $slot + '.jpg')) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}
