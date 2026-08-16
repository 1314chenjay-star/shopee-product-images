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
if ($null -eq (Get-Command New-FiveImagePlanV4A3 -ErrorAction SilentlyContinue)) { throw 'V4-A.3 planner runtime layer not loaded.' }

$outDir = Join-Path $systemRoot 'live_e2e_output_v4a3_529'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$config = [pscustomobject]@{
    api_key = $key
    base_url = 'https://tinysnow.one/v1'
    model = 'gpt-image-2'
    quality = 'medium'
    size = '1024x1024'
    safe_test_mode = $true
    max_reference_images = 2
    transport_profile = 'r3_120s_safe'
}

function Assert-V4A3Live([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('V4-A.3 live 529 failed: ' + $Message) }
}

$urls = @(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b0-mrpfuutmlerlbc',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258j-mrpfuvlre87892',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a4-mrpfuwav3oxz61',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257t-mrpfuxgjpnuoca',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a9-mrpfuy40nm6g41',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257s-mrpfuyr5b56v5c',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82597-mrpfv03xg9a855',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82588-mrpfv1k8bpxd4a'
)
$options = @(
    '藍色-常規肌肉貼20片','藍色-常規肌肉貼40片','藍色-護膝貼10片','藍色-護膝貼20片',
    '膚色-常規肌肉貼20片','膚色-常規肌肉貼40片','膚色-護膝貼10片','膚色-護膝貼20片',
    '黑色-常規肌肉貼20片','黑色-常規肌肉貼40片','黑色-護膝貼10片','黑色-護膝貼20片',
    '粉色-常規肌肉貼20片','粉色-常規肌肉貼40片','粉色-護膝貼10片','粉色-護膝貼20片',
    '綠色-護膝貼10片','綠色-護膝貼20片','紫色-護膝貼10片','紫色-護膝貼20片'
)
$header = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image'}
$data = @{0='52915734564';1='';2='運動肌貼 肌肉貼布 高彈力運動機能貼 籃球跑步護膝防護貼 透氣彈性貼布 運動防護用品';3='Sports & Outdoors/Basketball/Others';4=$urls[0]}
for ($i=1; $i -lt $urls.Count; $i++) { $header[4+$i]="ps_item_image.$i"; $data[4+$i]=$urls[$i] }
$header[20]='et_title_variation_1'; $data[20]='顏色/款式'
for ($i=1; $i -le $options.Count; $i++) { $header[20+$i]="et_title_option_${i}_for_variation_1"; $data[20+$i]=$options[$i-1] }
$product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
if ($null -eq $product) { throw '529 fixture construction failed.' }

$selectionDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selectionDir -Force | Out-Null
$product | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $selectionDir 'selected_product.json') -Encoding UTF8

$download = Download-ProductImagesV2 $product
$analysis = Analyze-ProductImagesV2 '52915734564' ([string[]]$download.paths)
$plan = Get-V4A3CurrentPlan
Assert-V4A3Live ($null -ne $plan) 'five-image plan was not created before generation'
Assert-V4A3Live ([bool]$plan.high_variant_conflict) '529 must be treated as high variant conflict'
Assert-V4A3Live ([string]$plan.high_conflict_reference_policy -eq 'same_safest_reference_all_slots') 'high-conflict reference policy changed'

$slot = 'detail4'
$slotPlan = Get-V4A3PlanSlot $plan $slot
Assert-V4A3Live ($null -ne $slotPlan) 'detail4 slot plan missing'
Assert-V4A3Live ([string]$slotPlan.hand_held_style -eq 'blocked_as_primary') 'detail4 must block hand-held primary composition'
$refs = [string[]]@(Get-ReferencesForSlotV2 $analysis $slot 2)
Assert-V4A3Live ($refs.Count -eq 1) 'high-conflict detail4 must use exactly one safest reference'
$prepared = [string[]]@(Get-PreparedApiReferencesV2 '52915734564' $refs)
$prompt = Get-PromptV2 $slot $product
if ($null -ne (Get-Command Get-LayoutRetryPromptV2 -ErrorAction SilentlyContinue)) { $prompt += Get-LayoutRetryPromptV2 $slot 0 }

Assert-V4A3Live ($prompt -match 'V4-A\.3 五圖整體規劃') 'detail4 missing V4-A.3 planner directive'
Assert-V4A3Live ($prompt -match '不得讓手、手指或手掌持拿商品成為主要視覺') 'detail4 missing no-hand-held-primary directive'
Assert-V4A3Live ($prompt -match '圖片文字穩定硬限制 V4-A\.2\.1') 'detail4 lost text-stability layer'
Assert-V4A3Live ($prompt -match '數量規格可選') 'detail4 missing stable quantity selection wording'
Assert-V4A3Live ($prompt -notmatch '多入數可選|多人數可選|20片|40片|10片|防汗防水|親膚黏膠|不傷膝|不傷肌膚') 'detail4 leaked unsafe/unstable wording'

$plan | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $outDir '529_five_image_plan_v4a3.json') -Encoding UTF8
$prompt | Set-Content -LiteralPath (Join-Path $outDir '52915734564_detail4_prompt.txt') -Encoding UTF8
Copy-Item -LiteralPath $refs[0] -Destination (Join-Path $outDir '52915734564_detail4_selected_ref.jpg') -Force

Write-Host '[LIVE] 52915734564 / detail4 only -> TinySnow' -ForegroundColor Cyan
$temporary = Invoke-ImageEditMultiV2 $config $prepared $prompt '1024x1024' 'medium'
Assert-V4A3Live ((Test-Path -LiteralPath $temporary -PathType Leaf) -and (Get-Item -LiteralPath $temporary).Length -gt 10000) 'detail4 TinySnow output invalid'
$output = Join-Path $outDir '52915734564_detail4_live.jpg'
Convert-ToFinalJpegV2 $temporary $output | Out-Null
Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue

[pscustomobject]@{
    version='V4-A.3'; product_id='52915734564'; generated_image_count=1; test_scope=[string[]]@('detail4');
    role=[string]$slotPlan.role; layout_family=[string]$slotPlan.preferred_layout_family;
    hand_held_style=[string]$slotPlan.hand_held_style; selected_reference_count=$refs.Count;
    output_file=(Split-Path $output -Leaf); output_bytes=(Get-Item -LiteralPath $output).Length;
    sha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant(); visual_review_required=$true
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'v4a3_529_live_summary.json') -Encoding UTF8
Write-Host '[PASS] V4-A.3 focused live technical gate completed: 529 detail4 only; visual review required.' -ForegroundColor Green
