$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$slot = ([string]$env:V4B_428_SLOT).Trim().ToLowerInvariant()
if ($slot -notin @('detail2','detail3','detail4')) { throw ('Unsupported R15 slot: ' + $slot) }
$expectedSourceIndex = @{detail2=6;detail3=8;detail4=1}[$slot]
$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$key = [string]$env:TINYSNOW_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { throw 'TINYSNOW_API_KEY repository secret is missing.' }
$artifactName = 'TinySnow-V4-B-428-R15-' + $slot
$outDirName = 'live_e2e_output_v4b_428_r15_' + $slot
$outDir = Join-Path $systemRoot $outDirName
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$config = [pscustomobject]@{api_key=$key;base_url='https://tinysnow.one/v1';model='gpt-image-2';quality='medium';size='1024x1024';safe_test_mode=$true;max_reference_images=2;transport_profile='r3_120s_safe'}
function Assert-R15([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('V4-B 428 R15 ' + $slot + ' failed: ' + $Message) } }

$urls = [string[]]@(
 'https://s-cf-tw.shopeesz.com/file/sg-11134201-825ap-mrpfutt4ncp41f','https://s-cf-tw.shopeesz.com/file/sg-11134201-825au-mrpfuuls51qgc0','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259z-mrpfuvcqstttff','https://s-cf-tw.shopeesz.com/file/sg-11134201-825az-mrpfuvy05b7s56','https://s-cf-tw.shopeesz.com/file/sg-11134201-82587-mrpfux6j2cqqff','https://s-cf-tw.shopeesz.com/file/sg-11134201-8258l-mrpfuxtu721481','https://s-cf-tw.shopeesz.com/file/sg-11134201-82595-mrpfuyp7gsncb8','https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv0wxe32cf0','https://s-cf-tw.shopeesz.com/file/sg-11134201-8257w-mrpfv1qfv1fo7f'
)
$options = [string[]]@('粉標黑色','粉標白色','白標黑色','黑標白色','黑內光板','白內光板','粉標火焰黑','白標火焰黑','粉標火焰白','黑標火焰白','BRRO【粉标】黑色【速干透气】')
$h = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1'}
$d = @{0='42833435408';1='';2='籃球短褲 男款寬鬆五分褲 假兩件設計 速乾透氣運動短褲 夏季籃球訓練休閒褲';3='101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others';4=$urls[0];20='款式'}
for ($i=1; $i -lt $urls.Count; $i++) { $c=4+$i; $h[$c]='ps_item_image.'+$i; $d[$c]=$urls[$i] }
for ($i=1; $i -le $options.Count; $i++) { $c=20+$i; $h[$c]="et_title_option_${i}_for_variation_1"; $d[$c]=$options[$i-1] }
$product = @(Convert-ShopeeRowsToProducts @($h,$d))[0]
Assert-R15 ($null -ne $product) 'product construction failed'
Assert-R15 ([string](Get-V4BSafeProductLabel $product) -eq '籃球短褲') 'safe product label mismatch'
foreach ($property in @('verified_dimensions','verified_materials','verified_accessories','verified_gifts','verified_bundle_contents','verified_colors','verified_sizes','verified_models','verified_quantities','verified_features','verified_use_cases','verified_certifications')) {
 Assert-R15 (@(Get-V4A1Property $product.verified_facts $property @()).Count -eq 0) ('unverified common fact leaked: ' + $property)
}
$selDir=Get-SelectionWorkspaceV2; New-Item -ItemType Directory -Path $selDir -Force|Out-Null
$product|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$download=Download-ProductImagesV2 $product
Assert-R15 (@($download.paths).Count -eq 9) 'did not download all 9 sources'
$analysis=Analyze-ProductImagesV2 '42833435408' ([string[]]$download.paths)
$plan=Get-V4BCurrentSourcePlan
Assert-R15 ([bool](Test-V4BSourcePlan $plan $true).passed) 'source plan validation failed'
$slotPlan=Get-V4BPlanSlot $plan $slot
Assert-R15 ([string]$slotPlan.source_mode -eq 'single_original') 'slot must use one real original'
Assert-R15 (@($slotPlan.source_indices).Count -eq 1) 'slot must use exactly one source'
Assert-R15 ([int]$slotPlan.source_indices[0] -eq [int]$expectedSourceIndex) ('unexpected source index: ' + [string]$slotPlan.source_indices[0])

$prompt=Get-PromptV2 $slot $product
$prompt += "`n[428 九張原圖人工驗收硬限制｜$slot]`n只保留本 slot 真實來源款式的外層短褲、較長內層、腰頭、抽繩、下擺條紋，以及來源原本存在的火焰／裝飾印花與字樣。不得把其他 variant 的顏色、火焰或字樣套到本款。九張來源均沒有清楚可驗證的口袋開口，因此不得新增任何可見口袋、拉鍊袋或側袋。不得新增尺寸、材質、品牌、Logo、功能、配件、贈品、認證或性能宣稱。商品表面既有裝飾字樣若存在，只能忠實保留原有視覺，不得改寫成新的品牌式英文、地名或不同文字；原圖中央賣場浮水印不是商品屬性，可清理移除。"
Assert-R15 ($prompt -match 'EDIT / PRESERVE / LOCALIZE') 'preservation mode missing'
Assert-R15 ($prompt -match '不得新增任何可見口袋') 'pocket guard missing'
Assert-R15 ($prompt -notmatch 'BRRO') 'variant-only token seeded into prompt'

$analysis|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $outDir ('42833435408_analysis_r15_'+$slot+'.json')) -Encoding UTF8
$slotPlan|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $outDir ('42833435408_'+$slot+'_slot_plan.json')) -Encoding UTF8
$prompt|Set-Content -LiteralPath (Join-Path $outDir ('42833435408_'+$slot+'_prompt.txt')) -Encoding UTF8
Copy-Item -LiteralPath ([string]$slotPlan.source_paths[0]) -Destination (Join-Path $outDir ('42833435408_'+$slot+'_selected_original.png')) -Force
$runtimeRefs=[string[]]@(Get-ReferencesForSlotV2 $analysis $slot 2)
Assert-R15 ($runtimeRefs.Count -eq 1) 'slot must use one runtime reference'
Copy-Item -LiteralPath $runtimeRefs[0] -Destination (Join-Path $outDir ('42833435408_'+$slot+'_runtime_ref.jpg')) -Force
$apiRefs=[string[]]@(Get-PreparedApiReferencesV2 '42833435408' $runtimeRefs)
Write-Host ('[LIVE V4-B 428 R15] 42833435408 / ' + $slot) -ForegroundColor Cyan
$tmp=Invoke-ImageEditMultiV2 $config $apiRefs $prompt '1024x1024' 'medium'
$output=Join-Path $outDir ('42833435408_'+$slot+'_live.jpg')
Convert-ToFinalJpegV2 $tmp $output|Out-Null; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
Assert-R15 ((Test-Path -LiteralPath $output -PathType Leaf) -and (Get-Item -LiteralPath $output).Length -gt 10000) 'output missing'
$hash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{schema_version=2;version='V4-B 428 R15';round='R15';slot=$slot;head_sha=[string]$env:GITHUB_SHA;run_id=[string]$env:GITHUB_RUN_ID;repository=[string]$env:GITHUB_REPOSITORY;artifact_name=$artifactName;test_scope=[string[]]@('42833435408/'+$slot);generated_image_count=1;source_index=[int]$slotPlan.source_indices[0];source_review_count=9;locked_prior_slots=[string[]]@('main:R14','detail1:R13');output_file=(Split-Path $output -Leaf);bytes=(Get-Item -LiteralPath $output).Length;sha256=$hash;visual_review_required=$true}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $outDir ('v4b_428_r15_'+$slot+'_summary.json')) -Encoding UTF8
Write-Host ('[PASS] V4-B 428 R15 '+$slot+' technical gate. Human visual review required.') -ForegroundColor Green
