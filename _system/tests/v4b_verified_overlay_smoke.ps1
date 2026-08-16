$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$start = Join-Path $root '_system\start'
. (Join-Path $start 'api_v2.ps1')
. (Join-Path $start 'excel_reader.ps1')
. (Join-Path $start 'selection_v2.ps1')
. (Join-Path $start 'image_pipeline_v2.ps1')
. (Join-Path $start 'v4a1_guard.ps1')

function Assert-V4BOverlay([bool]$Condition,[string]$Message){if(-not $Condition){throw('V4-B overlay smoke failed: '+$Message)}}

$product = [pscustomobject]@{
    product_id='90000040001'
    product_name='籃球訓練阻力繩'
    product_category='Sports & Outdoors/Basketball/Training'
    variation_name='規格'
    variants=[object[]]@()
    verified_facts=[pscustomobject]@{
        verified_numbers=[string[]]@('2米','30磅')
        verified_dimensions=[string[]]@('2米')
        verified_materials=[string[]]@()
        verified_accessories=[string[]]@('腰帶')
        verified_gifts=[string[]]@()
        verified_bundle_contents=[string[]]@('腰帶')
        verified_colors=[string[]]@('黑色')
        verified_sizes=[string[]]@()
        verified_models=[string[]]@()
        verified_quantities=[string[]]@()
        verified_resistance_levels=[string[]]@('30磅')
        verified_features=[string[]]@()
        verified_use_cases=[string[]]@()
        verified_certifications=[string[]]@()
        verified_origin=[string[]]@()
    }
    multi_variant_flags=[pscustomobject]@{variant_count=2;has_multiple_variants=$true;has_multiple_sizes=$false;has_multiple_colors=$false;has_multiple_quantities=$true;has_multiple_bundle_counts=$true;has_multiple_models=$false;has_multiple_resistance_levels=$false}
}

$selDir=Get-SelectionWorkspaceV2;New-Item -ItemType Directory -Path $selDir -Force|Out-Null
$product|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$analysis=[pscustomobject]@{product_id='90000040001';high_variant_conflict=$true;reference_safety=[object[]]@([pscustomobject]@{path='C:\refs\product.png';position=0;duplicate=$false;local_risk_score=0.2;local_safe_score=0.8;center_edge_density=0.18;outer_edge_density=0.07});images=[object[]]@([pscustomobject]@{path='C:\refs\product.png';position=0;duplicate=$false;local_risk_score=0.2;local_safe_score=0.8;center_edge_density=0.18;outer_edge_density=0.07})}
$plan=New-V4BSourceImagePlan $product $analysis
$script:V4BSourcePlanCache[[string]$product.product_id]=$plan

foreach($slot in @('main','detail2','detail3','detail4')){
    $slotPlan=Get-V4BPlanSlot $plan $slot
    Assert-V4BOverlay ([bool]$slotPlan.text_shield_required) ($slot+' must use conflict text shield')
    Assert-V4BOverlay ([string]$slotPlan.verified_text_policy -eq 'deterministic_overlay_only') ($slot+' verified-text policy mismatch')
    $slotContent=Get-V4BVerifiedOverlayContent $product $slot
    Assert-V4BOverlay ([string]$slotContent.title-eq'籃球訓練阻力繩') ($slot+' overlay must use the verified Taiwan product label')
    Assert-V4BOverlay ([string]$slotContent.title-notmatch'區域聯防') ($slot+' overlay leaked unsupported source wording')
    $slotPrompt=Get-PromptV2 $slot $product
    Assert-V4BOverlay ($slotPrompt-match'不要生成任何可辨識文字') ($slot+' TinySnow stage must remain text-free')
    Assert-V4BOverlay ($slotPrompt-notmatch'區域聯防') ($slot+' prompt seeded unsupported source wording')
}

$content=Get-V4BVerifiedOverlayContent $product 'detail4'
Assert-V4BOverlay ([string]$content.title -eq '籃球訓練阻力繩') ('unexpected overlay title: '+[string]$content.title)
foreach($required in @('2公尺','30磅','腰帶','黑色')){Assert-V4BOverlay ([string]$content.secondary -match [regex]::Escape($required)) ('verified overlay missing: '+$required)}
Assert-V4BOverlay ([string]$content.secondary -notmatch '5組|五組') 'variant-only bundle count leaked into deterministic overlay'

$prompt=Get-PromptV2 'detail4' $product
Assert-V4BOverlay ($prompt -match '程式化驗證文字覆蓋') 'shielded prompt must enable deterministic overlay'
Assert-V4BOverlay ($prompt -match '不要生成任何可辨識文字') 'TinySnow shielded stage must be text-free'
Assert-V4BOverlay ($null -ne $script:V4BPendingOverlay) 'prompt did not stage pending overlay'

Add-Type -AssemblyName System.Drawing
$tempDir=Join-Path $env:TEMP ('v4b_overlay_'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tempDir -Force|Out-Null
try{
    $source=Join-Path $tempDir 'source.jpg';$target=Join-Path $tempDir 'target.jpg'
    $bmp=New-Object Drawing.Bitmap 1024,1024;$g=[Drawing.Graphics]::FromImage($bmp)
    try{$g.Clear([Drawing.Color]::White);$brush=New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(35,35,35));try{$g.FillEllipse($brush,260,180,500,560)}finally{$brush.Dispose()};$bmp.Save($source,[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$g.Dispose();$bmp.Dispose()}
    $before=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $info=Convert-ToFinalJpegV2 $source $target
    Assert-V4BOverlay ((Test-Path -LiteralPath $target)-and$info.width-eq1024-and$info.height-eq1024) 'overlay output invalid'
    $after=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    Assert-V4BOverlay ($before-ne$after) 'deterministic overlay did not change output image'
    Assert-V4BOverlay ($null -eq $script:V4BPendingOverlay) 'pending overlay state was not consumed'
    $check=New-Object Drawing.Bitmap $target
    try{
        $bottom=$check.GetPixel(30,980);$top=$check.GetPixel(30,30)
        $bottomBrightness=($bottom.R+$bottom.G+$bottom.B)/3.0;$topBrightness=($top.R+$top.G+$top.B)/3.0
        Assert-V4BOverlay ($bottomBrightness-lt$topBrightness-60) 'bottom verified-info card was not rendered'
    }finally{$check.Dispose()}
}
finally{Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue}

$product529=[pscustomobject]@{
    product_id='90000040002';product_name='運動肌貼';product_category='Sports/Training';variation_name='顏色/款式';variants=[object[]]@();
    verified_facts=[pscustomobject]@{verified_numbers=[string[]]@();verified_dimensions=[string[]]@();verified_materials=[string[]]@();verified_accessories=[string[]]@();verified_gifts=[string[]]@();verified_bundle_contents=[string[]]@();verified_colors=[string[]]@();verified_sizes=[string[]]@();verified_models=[string[]]@();verified_quantities=[string[]]@();verified_resistance_levels=[string[]]@();verified_features=[string[]]@();verified_use_cases=[string[]]@();verified_certifications=[string[]]@();verified_origin=[string[]]@()};
    multi_variant_flags=[pscustomobject]@{variant_count=4;has_multiple_variants=$true;has_multiple_sizes=$false;has_multiple_colors=$true;has_multiple_quantities=$true;has_multiple_bundle_counts=$true;has_multiple_models=$false;has_multiple_resistance_levels=$false}
}
$content529=Get-V4BVerifiedOverlayContent $product529 'detail4'
Assert-V4BOverlay ([string]$content529.title -eq '運動肌貼') '529-like overlay title must remain neutral product label'
Assert-V4BOverlay ([string]$content529.secondary -match '選購前請確認規格|實際規格請依商品選項為準') '529-like no-common-fact overlay must fall back to safe shopping guidance'
Assert-V4BOverlay ([string]$content529.secondary -notmatch '\d+片|低敏|親膚|包退') '529-like overlay invented unsafe text'

$apiBlob=(& git -C $root hash-object -- '_system/start/api_v2.ps1').Trim().ToLowerInvariant()
Assert-V4BOverlay ($apiBlob-eq'9e81a9c4a0769d5e41b4c1e7dba4b92266c49187') ('API-R3 transport changed: '+$apiBlob)
Write-Host 'V4-B deterministic verified-text overlay smoke: PASS' -ForegroundColor Green
