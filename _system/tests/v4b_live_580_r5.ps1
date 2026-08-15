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
$outDir = Join-Path $systemRoot 'live_e2e_output_v4b_580_r5'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$config = [pscustomobject]@{api_key=$key;base_url='https://tinysnow.one/v1';model='gpt-image-2';quality='medium';size='1024x1024';safe_test_mode=$true;max_reference_images=2;transport_profile='r3_120s_safe'}
function Assert-R5([bool]$Condition,[string]$Message){if(-not $Condition){throw('V4-B 580 R5 failed: '+$Message)}}

$urls=[string[]]@(
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrpfv1ftvdonbb',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259p-mrpfv1zcms5g87',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b2-mrpfv2mgqn7p69',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82593-mrpfv3ovpjwle0',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a0-mrpfv4hwe0w66e',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv6mpe4n5c7',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259l-mrpfv78r80lhdb')
$h=@{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1';21='et_title_option_1_for_variation_1';22='et_title_option_2_for_variation_1'}
$d=@{0='58015741169';1='';2='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品';3='Sports & Outdoors/Basketball/Training';4=$urls[0];20='規格';21='黑色2米30磅+腰帶一組';22='黑色2米30磅+腰帶各5組'}
for($i=1;$i-lt$urls.Count;$i++){$c=4+$i;$h[$c]="ps_item_image.$i";$d[$c]=$urls[$i]}
$product=@(Convert-ShopeeRowsToProducts @($h,$d))[0]
Assert-R5 ($null-ne$product) 'product parse failed'
$selDir=Get-SelectionWorkspaceV2;New-Item -ItemType Directory -Path $selDir -Force|Out-Null;$product|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$download=Download-ProductImagesV2 $product
$analysis=Analyze-ProductImagesV2 '58015741169' ([string[]]$download.paths)
$plan=Get-V4BCurrentSourcePlan
Assert-R5 ($null-ne$plan) 'source plan missing'
$d4=Get-V4BPlanSlot $plan 'detail4'
Assert-R5 ($null-ne$d4) 'detail4 plan missing'
Assert-R5 (@($d4.source_indices).Count-eq1) 'detail4 must use one original source'
Assert-R5 ([int]$d4.source_indices[0]-eq4) ('expected product-focused source position 4, got '+[string]$d4.source_indices[0])
Assert-R5 ([bool]$d4.text_shield_required) 'detail4 must retain quantity-conflict text shield'
Assert-R5 ([double]$d4.visual_proxy_center_dominance-gt0.09) 'selected source is not sufficiently center-dominant'
Copy-Item -LiteralPath ([string]$d4.source_paths[0]) -Destination (Join-Path $outDir '58015741169_detail4_selected_original.png') -Force
$plan|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $outDir '58015741169_source_plan_v4b.json') -Encoding UTF8

$refs=[string[]]@(Get-ReferencesForSlotV2 $analysis 'detail4' 2)
Assert-R5 ($refs.Count-eq1) 'runtime detail4 must send exactly one shielded reference'
Copy-Item -LiteralPath $refs[0] -Destination (Join-Path $outDir '58015741169_detail4_runtime_ref.jpg') -Force
$prompt=Get-PromptV2 'detail4' $product
foreach($required in @('2公尺','30磅','腰帶','黑色')){Assert-R5 ($prompt-match[regex]::Escape($required)) ('missing common fact: '+$required)}
Assert-R5 ($prompt-notmatch'各5組') 'variant quantity leaked into prompt'
Assert-R5 ($prompt-match'來源文字遮蔽|衝突文字遮蔽') 'text-shield directive missing'
$prompt|Set-Content -LiteralPath (Join-Path $outDir '58015741169_detail4_prompt.txt') -Encoding UTF8

$apiRefs=[string[]]@(Get-PreparedApiReferencesV2 '58015741169' $refs)
Write-Host '[LIVE V4-B R5] 58015741169 / detail4 / product-focused source -> TinySnow' -ForegroundColor Cyan
$tmp=Invoke-ImageEditMultiV2 $config $apiRefs $prompt '1024x1024' 'medium'
Assert-R5 ((Test-Path -LiteralPath $tmp -PathType Leaf)-and(Get-Item -LiteralPath $tmp).Length-gt10000) 'TinySnow output invalid'
$out=Join-Path $outDir '58015741169_detail4_live.jpg';Convert-ToFinalJpegV2 $tmp $out|Out-Null;Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
[pscustomobject]@{version='V4-B R5';product_id='58015741169';slot='detail4';selected_source_index=[int]$d4.source_indices[0];center_dominance=[double]$d4.visual_proxy_center_dominance;product_focus_proxy=[double]$d4.visual_proxy_product_focus;text_shield_required=[bool]$d4.text_shield_required;output_file='58015741169_detail4_live.jpg';sha256=(Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant();visual_review_required=$true}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $outDir 'v4b_580_r5_summary.json') -Encoding UTF8
Write-Host '[PASS] V4-B 580 R5 technical gate: product-focused source position 4 used for one real TinySnow detail4 generation.' -ForegroundColor Green
