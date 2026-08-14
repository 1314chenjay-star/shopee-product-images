$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')
. (Join-Path $startRoot 'v4a1_visual_truth.ps1')

$key = [string]$env:TINYSNOW_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { throw 'TINYSNOW_API_KEY repository secret is missing.' }

$outDir = Join-Path $systemRoot 'live_e2e_output'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$downloadHeaders = @{ 'User-Agent'='Mozilla/5.0' }

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

function Get-LiveReference([string]$Url, [string]$Name) {
    $path = Join-Path $outDir $Name
    Invoke-WebRequest -Uri $Url -OutFile $path -Headers $downloadHeaders -UseBasicParsing -TimeoutSec 60
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Shopee reference download failed: ' + $Name) }
    if ((Get-Item -LiteralPath $path).Length -lt 10000) { throw ('Shopee reference image too small: ' + $Name) }
    return $path
}

function New-LiveProduct([string]$Id, [string]$Name, [string]$Category, [string]$CoverUrl, [string]$DetailUrl, [string]$VariationName, [string[]]$Options) {
    $header = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='ps_item_image.1';6='et_title_variation_1'}
    $data = @{0=$Id;1='';2=$Name;3=$Category;4=$CoverUrl;5=$DetailUrl;6=$VariationName}
    for ($i = 1; $i -le $Options.Count; $i++) {
        $column = 6 + $i
        $header[$column] = "et_title_option_${i}_for_variation_1"
        $data[$column] = [string]$Options[$i - 1]
    }
    $product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
    if ($null -eq $product) { throw ($Id + ' product construction failed.') }
    return $product
}

function Assert-PromptDoesNotContain([string]$Id, [string]$Prompt, [string[]]$Terms) {
    foreach ($term in $Terms) {
        if ($Prompt -match [regex]::Escape($term)) { throw ($Id + ' unsafe/unverified term leaked into prompt: ' + $term) }
    }
}

function Invoke-LiveCase([string]$Id, [string]$Slot, $Product, [string]$CoverUrl, [string]$DetailUrl) {
    $coverPath = Get-LiveReference $CoverUrl ($Id + '_cover.jpg')
    $detailPath = Get-LiveReference $DetailUrl ($Id + '_image1.jpg')
    $prompt = Get-PromptV2 $Slot $Product
    $compact = Get-CompactTransportPromptV2 $Slot $Product
    $prompt | Set-Content -LiteralPath (Join-Path $outDir ($Id + '_prompt.txt')) -Encoding UTF8
    $compact | Set-Content -LiteralPath (Join-Path $outDir ($Id + '_compact_prompt.txt')) -Encoding UTF8
    $Product | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir ($Id + '_verified_product.json')) -Encoding UTF8
    $result = Invoke-ImageEditMultiV2 $config ([string[]]@($coverPath,$detailPath)) $prompt '1024x1024' 'medium'
    if (-not (Test-Path -LiteralPath $result -PathType Leaf)) { throw ($Id + ' TinySnow live API returned no image file.') }
    if ((Get-Item -LiteralPath $result).Length -lt 10000) { throw ($Id + ' TinySnow live API output image is unexpectedly small.') }
    $dest = Join-Path $outDir ($Id + '_' + $Slot + '_live.png')
    Copy-Item -LiteralPath $result -Destination $dest -Force
    return [pscustomobject]@{ id=$Id; slot=$Slot; output=$dest; bytes=(Get-Item -LiteralPath $dest).Length; prompt=$prompt }
}

$results = @()

# 1) 58015741169 — quantity/bundle visual truth regression.
$u580a = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83'
$u580b = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57'
$p580 = New-LiveProduct '58015741169' '籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品' '101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others' $u580a $u580b '規格' @('黑色2米30磅+腰帶一組','黑色2米30磅+腰帶各5組')
foreach ($v in @('2米','30磅','腰帶','黑色')) { if ((Get-PromptV2 'main' $p580) -notmatch [regex]::Escape($v)) { throw ('580 missing common fact: ' + $v) } }
if (@($p580.verified_facts.verified_quantities).Count -ne 0) { throw '580 variant quantity leaked into common facts.' }
if (-not [bool]$p580.multi_variant_flags.has_multiple_bundle_counts) { throw '580 visual bundle guard inactive.' }
Assert-PromptDoesNotContain '58015741169' (Get-PromptV2 'main' $p580) @('一組','5組','五人聯動','32cm','60cm','9cm','尼龍','強化團隊戰術')
$results += ,(Invoke-LiveCase '58015741169' 'main' $p580 $u580a $u580b)

# 2) 57565745174 — model may be used; ball accessory/material/performance claims may not.
$u575a = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259g-mrpfuzzrmcjo62'
$u575b = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv0x43n5t1a'
$p575 = New-LiveProduct '57565745174' '排球訓練器材 墊球阻力帶 排球控球輔助訓練器 傳球墊球練習用品 學生球隊訓練裝備' '101856 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Volleyball/Others' $u575a $u575b '款式' @('美璐捷排球訓練器材(VZJ-004S)')
if (@($p575.verified_facts.verified_models) -notcontains 'VZJ-004S') { throw '575 verified model missing.' }
if (@($p575.verified_facts.verified_accessories) -contains '球') { throw '575 排球→附球 regression.' }
if (@($p575.verified_facts.verified_materials).Count -ne 0) { throw '575 material must remain unverified.' }
if ((Get-PromptV2 'detail1' $p575) -notmatch 'VZJ-004S') { throw '575 prompt missing verified model.' }
Assert-PromptDoesNotContain '57565745174' (Get-PromptV2 'detail1' $p575) @('美璐捷','尼龍','D-ring','D環','附球','提升','專業訓練效果')
$results += ,(Invoke-LiveCase '57565745174' 'detail1' $p575 $u575a $u575b)

# 3) 52915734564 — 20 variants, multiple colors and quantities; no medical/material/performance claims.
$u529a = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b0-mrpfuutmlerlbc'
$u529b = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258j-mrpfuvlre87892'
$opts529 = @(
    '藍色-常規肌肉貼20片','藍色-常規肌肉貼40片','藍色-護膝貼10片','藍色-護膝貼20片',
    '膚色-常規肌肉貼20片','膚色-常規肌肉貼40片','膚色-護膝貼10片','膚色-護膝貼20片',
    '黑色-常規肌肉貼20片','黑色-常規肌肉貼40片','黑色-護膝貼10片','黑色-護膝貼20片',
    '粉色-常規肌肉貼20片','粉色-常規肌肉貼40片','粉色-護膝貼10片','粉色-護膝貼20片',
    '綠色-護膝貼10片','綠色-護膝貼20片','紫色-護膝貼10片','紫色-護膝貼20片'
)
$p529 = New-LiveProduct '52915734564' '運動肌貼 肌肉貼布 高彈力運動機能貼 籃球跑步護膝防護貼 透氣彈性貼布 運動防護用品' '101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others' $u529a $u529b '顏色/款式' $opts529
if (@($p529.variants).Count -ne 20) { throw '529 expected 20 variants.' }
if (-not [bool]$p529.multi_variant_flags.has_multiple_quantities -or -not [bool]$p529.multi_variant_flags.has_multiple_colors) { throw '529 multi-variant guards inactive.' }
if (@($p529.verified_facts.verified_quantities).Count -ne 0 -or @($p529.verified_facts.verified_colors).Count -ne 0) { throw '529 color/quantity must not be common facts.' }
Assert-PromptDoesNotContain '52915734564' (Get-PromptV2 'detail4' $p529) @('高彈力','透氣','不傷膝','不傷肌膚','降低不適','不留痕','高彈棉質','親膚黏膠','防汗','防水','10片','20片','40片','藍色','黑色','粉色','膚色')
$results += ,(Invoke-LiveCase '52915734564' 'detail4' $p529 $u529a $u529b)

# 4) 53615734484 — mixed night-glow / non-night-glow / color-changing variants; no variant-specific feature may leak from title.
$u536a = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b4-mrpfuzn6rv29cc'
$u536b = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-825ak-mrpfv0zc8tmpf9'
$opts536 = @(
    '馬卡龍夜光限定-淺粉','馬卡龍夜光限定-淺粉藍','馬卡龍夜光限定-淺蘭','馬卡龍夜光限定-清新紫',
    '馬卡龍夜光限定-清新綠','幻彩變色科技-光照變色','幻彩變色科技-黑白感溫','非夜光基礎款-V8001淺粉',
    '非夜光基礎款-V8001淺藍','非夜光基礎款-V8001淺紫','非夜光基礎款-V8001淺綠','數碼彩印排球-喵嗚藍',
    '數碼彩印排球-呱呱綠','數碼彩印排球-小熊黃','LED夜光燈球-星空粉','LED夜光燈球-星空紫'
)
$p536 = New-LiveProduct '53615734484' '夜光排球 5號標準排球 馬卡龍配色學生訓練球 柔軟手感耐磨排球 室內外運動用品 夜間發光球' '101854 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Volleyball/Volley Balls' $u536a $u536b '型號' $opts536
if (@($p536.variants).Count -ne 16) { throw '536 expected 16 variants.' }
if (-not [bool]$p536.multi_variant_flags.has_multiple_variants) { throw '536 multi-variant guard inactive.' }
if (@($p536.verified_facts.verified_colors).Count -ne 0) { throw '536 must not lock one common color.' }
Assert-PromptDoesNotContain '53615734484' (Get-PromptV2 'main' $p536) @('夜光','發光','光照變色','感溫','V8001','5號','耐磨','柔軟','室內外','馬卡龍')
$results += ,(Invoke-LiveCase '53615734484' 'main' $p536 $u536a $u536b)

# 5) 53215734553 — 真皮 only belongs to one variant; must not leak as common material or from title.
$u532a = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259r-mrpfuvd4m2v6a3'
$u532b = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259h-mrpfuw6vsbggb5'
$p532 = New-LiveProduct '53215734553' '真皮籃球 7號成人標準比賽球 室內外籃球 耐磨防滑柔軟手感 專業訓練用球' '101851 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Basket Balls' $u532a $u532b '款式' @('真皮加厚款','基礎款')
if (-not [bool]$p532.multi_variant_flags.has_multiple_variants) { throw '532 multi-variant guard inactive.' }
if (@($p532.verified_facts.verified_materials).Count -ne 0) { throw '532 真皮 must remain variant-specific, not common.' }
Assert-PromptDoesNotContain '53215734553' (Get-PromptV2 'detail2' $p532) @('真皮','7號','比賽球','耐磨','防滑','柔軟','專業訓練','室內外')
$results += ,(Invoke-LiveCase '53215734553' 'detail2' $p532 $u532a $u532b)

$summary = [pscustomobject]@{
    tested_at = (Get-Date).ToString('o')
    count = $results.Count
    results = $results | ForEach-Object { [pscustomobject]@{ id=$_.id; slot=$_.slot; output=[IO.Path]::GetFileName($_.output); bytes=$_.bytes } }
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $outDir 'batch_summary.json') -Encoding UTF8
if ($results.Count -ne 5) { throw ('Expected five live results, got ' + $results.Count) }
Write-Host ('[PASS] Five-product real Shopee TinySnow batch completed: ' + (($results | ForEach-Object { $_.id + '=' + $_.bytes }) -join '; ')) -ForegroundColor Green
