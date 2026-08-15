$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$outDir = Join-Path $systemRoot 'source_review_v4b_580'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$urls = [string[]]@(
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
$h=@{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1';21='et_title_option_1_for_variation_1';22='et_title_option_2_for_variation_1'}
$d=@{0='58015741169';1='';2='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品';3='Sports & Outdoors/Basketball/Training';4=$urls[0];20='規格';21='黑色2米30磅+腰帶一組';22='黑色2米30磅+腰帶各5組'}
for($i=1;$i-lt$urls.Count;$i++){$c=4+$i;$h[$c]="ps_item_image.$i";$d[$c]=$urls[$i]}
$product=@(Convert-ShopeeRowsToProducts @($h,$d))[0]
if($null-eq$product){throw '580 source-review product parse failed.'}
$selDir=Get-SelectionWorkspaceV2;New-Item -ItemType Directory -Path $selDir -Force|Out-Null;$product|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$download=Download-ProductImagesV2 $product
$paths=[string[]]@($download.paths)
if($paths.Count-ne9){throw("Expected 9 source images, got $($paths.Count).")}
$analysis=Analyze-ProductImagesV2 '58015741169' $paths
for($i=0;$i-lt$paths.Count;$i++){
    Copy-Item -LiteralPath $paths[$i] -Destination (Join-Path $outDir ('source_'+$i+'.png')) -Force
}
$analysis|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $outDir 'analysis.json') -Encoding UTF8
$plan=Get-V4BCurrentSourcePlan
$plan|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $outDir 'source_plan_v4b.json') -Encoding UTF8
Write-Host '[PASS] Downloaded all 9 real 580 source images for no-API visual review.' -ForegroundColor Green
