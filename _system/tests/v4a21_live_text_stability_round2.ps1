$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$key = [string]$env:TINYSNOW_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { throw 'TINYSNOW_API_KEY repository secret is missing.' }
$outDir = Join-Path $systemRoot 'live_e2e_output_v4a21_r2'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$config = [pscustomobject]@{ api_key=$key; base_url='https://tinysnow.one/v1'; model='gpt-image-2'; quality='medium'; size='1024x1024'; safe_test_mode=$true; max_reference_images=2; transport_profile='r3_120s_safe' }

$header = @{0='et_title_product_id';1='et_title_product_name';2='et_title_product_category';3='ps_item_cover_image'}
$urls = @(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrpfv1ftvdonbb',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259p-mrpfv1zcms5g87',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b2-mrpfv2mgqn7p69',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82593-mrpfv3ovpjwle0',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a0-mrpfv4hwe0w66e',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv6mpe4n5c7',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259l-mrpfv78r80lhdb'
)
$data = @{0='58015741169';1='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品';2='Sports & Outdoors/Basketball/Training';3=$urls[0]}
for ($i=1; $i -lt $urls.Count; $i++) { $column=3+$i; $header[$column]="ps_item_image.$i"; $data[$column]=$urls[$i] }
$variationColumn=20; $header[$variationColumn]='et_title_variation_1'; $data[$variationColumn]='規格'
$header[21]='et_title_option_1_for_variation_1'; $data[21]='黑色2米30磅+腰帶一組'
$header[22]='et_title_option_2_for_variation_1'; $data[22]='黑色2米30磅+腰帶各5組'
$product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
if ($null -eq $product) { throw '580 product construction failed.' }
$selectionDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selectionDir -Force | Out-Null
$product | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $selectionDir 'selected_product.json') -Encoding UTF8
$download = Download-ProductImagesV2 $product
$analysis = Analyze-ProductImagesV2 '58015741169' ([string[]]$download.paths)

$summary=@()
foreach ($slot in @('detail1','detail2')) {
    $allowed=@(Get-V4A2AllowedOutputText $product $slot)
    if ($slot -eq 'detail1') {
        foreach ($bad in @('多規格可選','數量規格可選','請依實際選項為準','實際內容請依選項為準','不同規格內容可能不同','款式可選')) { if ($allowed -contains $bad) { throw ('detail1 microcopy still allowed: '+$bad) } }
    }
    if ($slot -eq 'detail2') {
        foreach ($bad in @('籃球訓練阻力繩','多規格可選','數量規格可選','彈力繩','連接扣')) { if ($allowed -contains $bad) { throw ('detail2 extra label still allowed: '+$bad) } }
    }
    $prompt=Get-PromptV2 $slot ([string]$product.product_name)
    if ($prompt -match '(?<!公)2米|5組|五人聯動|32cm|60cm|9cm|尼龍|橡膠|金屬') { throw ('unsafe fact leaked in '+$slot) }
    if ($slot -eq 'detail2' -and $prompt -notmatch '局部放大圖與圈選細節全部禁止加文字標籤') { throw 'detail2 no-caption rule missing.' }
    $selected=[string[]]@(Get-ReferencesForSlotV2 $analysis $slot 2)
    $prepared=[string[]]@(Get-PreparedApiReferencesV2 '58015741169' $selected)
    $prompt | Set-Content -LiteralPath (Join-Path $outDir ('58015741169_'+$slot+'_prompt.txt')) -Encoding UTF8
    for ($i=0; $i -lt $selected.Count; $i++) { Copy-Item -LiteralPath $selected[$i] -Destination (Join-Path $outDir ('58015741169_'+$slot+'_selected_ref'+($i+1)+'.jpg')) -Force }
    Write-Host ('[LIVE R2] 58015741169 / '+$slot) -ForegroundColor Cyan
    $result=Invoke-ImageEditMultiV2 $config $prepared $prompt '1024x1024' 'medium'
    if (-not (Test-Path -LiteralPath $result -PathType Leaf) -or (Get-Item -LiteralPath $result).Length -lt 10000) { throw ('invalid output: '+$slot) }
    $output=Join-Path $outDir ('58015741169_'+$slot+'_live.png')
    Copy-Item -LiteralPath $result -Destination $output -Force
    $summary += [pscustomobject]@{product_id='58015741169';slot=$slot;allowed_text=$allowed;selected_reference_count=$selected.Count;output_bytes=(Get-Item -LiteralPath $output).Length}
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'v4a21_round2_summary.json') -Encoding UTF8
Write-Host '[PASS] V4-A.2.1 round-two live test generated clean-candidate detail1/detail2 images.' -ForegroundColor Green
