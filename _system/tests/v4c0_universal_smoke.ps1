$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_product_evidence.ps1')
. (Join-Path $root 'start\v4c_category_router.ps1')
. (Join-Path $root 'start\v4c_image_decision.ps1')
. (Join-Path $root 'start\v4c_adaptive_five_planner.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "V4-C0 smoke failed: $Message" }
}

function New-TestImage([string]$Path, [int]$Position, [double]$Risk = 0.20) {
    return [pscustomobject]@{
        path = $Path
        position = $Position
        duplicate = $false
        local_risk_score = $Risk
        local_safe_score = (1.0 - $Risk)
        near_square = $true
    }
}

# 1) Sports gets deep routing.
$productSports = [pscustomobject]@{
    product_id = 'S001'
    name = '籃球訓練球 室內戶外練習用'
    category = 'Sports & Outdoors/Basketball'
    verified_facts = [pscustomobject]@{
        verified_sizes = @('7號')
        verified_features = @('訓練用')
    }
}
$analysisSports = [pscustomobject]@{
    product_id = 'S001'
    images = @(
        (New-TestImage 's1.jpg' 0 0.10),
        (New-TestImage 's2.jpg' 1 0.18),
        (New-TestImage 's3.jpg' 2 0.22)
    )
}
$r1 = Invoke-V4C0Analysis $productSports $analysisSports
Assert-True ($r1.route.family -eq 'sports') '籃球應路由到 sports。'
Assert-True ($r1.route.subfamily -eq 'ball_sports') '籃球應路由到 ball_sports。'
Assert-True ($r1.route.priority -eq 'sports_deep') '運動商品應套 sports_deep。'
Assert-True ($r1.five_image_plan.slots.Count -eq 5) '安全商品必須得到五個 slot。'
Assert-True ($r1.image_api_called -eq $false) 'V4-C0 不得呼叫圖片 API。'

# 2) Non-sports still routes safely.
$productElectronics = [pscustomobject]@{
    product_id = 'E001'
    name = 'Type-C 充電線'
    category = 'Electronics/Accessories'
    verified_facts = [pscustomobject]@{}
}
$analysisElectronics = [pscustomobject]@{ product_id='E001'; images=@((New-TestImage 'e1.jpg' 0 0.12),(New-TestImage 'e2.jpg' 1 0.20)) }
$r2 = Invoke-V4C0Analysis $productElectronics $analysisElectronics
Assert-True ($r2.route.family -eq 'electronics') '3C 商品應被安全辨識。'
Assert-True ($r2.route.policy -eq 'universal_safe_fallback') '非運動商品第一階段走通用安全兜底。'

# 3) Unknown category is not allowed into paid generation automatically.
$productUnknown = [pscustomobject]@{ product_id='U001'; name='神秘商品XYZ'; category='Misc'; verified_facts=[pscustomobject]@{} }
$analysisUnknown = [pscustomobject]@{ product_id='U001'; images=@((New-TestImage 'u1.jpg' 0 0.18)) }
$r3 = Invoke-V4C0Analysis $productUnknown $analysisUnknown
Assert-True ($r3.route.family -eq 'generic') '未知類目應進 generic。'
Assert-True ($r3.can_enter_paid_generation -eq $false) '未知商品不得直接進付費生成。'

# 4) Duplicate source must block that image.
$dup = New-TestImage 'dup.jpg' 0 0.10
$dup.duplicate = $true
$productDup = [pscustomobject]@{ product_id='D001'; name='羽球拍'; category='Sports'; verified_facts=[pscustomobject]@{} }
$analysisDup = [pscustomobject]@{ product_id='D001'; images=@($dup,(New-TestImage 'ok.jpg' 1 0.12)) }
$r4 = Invoke-V4C0Analysis $productDup $analysisDup
Assert-True (@($r4.image_decisions | Where-Object { $_.action -eq 'BLOCK' }).Count -eq 1) '重複來源必須 BLOCK。'

# 5) Unverified dimensions cannot create a dimension slot.
$productNoDims = [pscustomobject]@{ product_id='H001'; name='戶外露營帳篷'; category='Sports/Outdoor'; verified_facts=[pscustomobject]@{} }
$analysisNoDims = [pscustomobject]@{ product_id='H001'; images=@((New-TestImage 'h1.jpg' 0 0.10),(New-TestImage 'h2.jpg' 1 0.16)) }
$r5 = Invoke-V4C0Analysis $productNoDims $analysisNoDims
Assert-True (@($r5.five_image_plan.slots | Where-Object { $_.role -match 'dimensions' }).Count -eq 0) '沒有 verified dimensions 時不得安排尺寸圖。'

Write-Host 'V4-C0 universal product engine smoke: PASS'
