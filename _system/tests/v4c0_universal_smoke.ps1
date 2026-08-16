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

function New-TestAnalysis([string]$ProductId) {
    return [pscustomobject]@{
        product_id = $ProductId
        images = @(
            (New-TestImage ($ProductId + '-1.jpg') 0 0.10),
            (New-TestImage ($ProductId + '-2.jpg') 1 0.18)
        )
    }
}

# 1) Sports equipment gets deep routing.
$productSports = [pscustomobject]@{
    product_id = 'S001'
    name = '籃球訓練球 室內戶外練習用'
    category = 'Sports & Outdoors/Basketball'
    verified_facts = [pscustomobject]@{
        verified_sizes = @('7號')
        verified_features = @('訓練用')
    }
}
$r1 = Invoke-V4C0Analysis $productSports (New-TestAnalysis 'S001')
Assert-True ($r1.route.family -eq 'sports') '籃球本體應路由到 sports。'
Assert-True ($r1.route.subfamily -eq 'ball_sports') '籃球本體應路由到 ball_sports。'
Assert-True ($r1.route.priority -eq 'sports_deep') '運動商品應套 sports_deep。'
Assert-True ($r1.five_image_plan.slots.Count -eq 5) '安全商品必須得到五個 slot。'
Assert-True ($r1.image_api_called -eq $false) 'V4-C0 不得呼叫圖片 API。'

# 2) Product structure outranks sports context: basketball shorts are apparel, not ball equipment.
$product428Like = [pscustomobject]@{
    product_id = '42833435408'
    name = '籃球短褲 男款寬鬆五分褲 假兩件設計'
    category = 'Sports & Outdoors/Basketball/Others'
    verified_facts = [pscustomobject]@{}
}
$r428 = Invoke-V4C0Analysis $product428Like (New-TestAnalysis '42833435408')
Assert-True ($r428.route.family -eq 'apparel') '籃球短褲必須判為 apparel。'
Assert-True ($r428.route.subfamily -eq 'sports_apparel') '籃球短褲應保留 sports_apparel 場景。'
Assert-True (@($r428.five_image_plan.slots | Where-Object { $_.role -match 'dimensions|size' }).Count -eq 0) '沒有尺寸證據時服飾不得安排尺寸圖。'

# 3) Protective gear outranks sport-context words.
$productGuard = [pscustomobject]@{ product_id='G001'; name='籃球護膝 運動護具'; category='Sports'; verified_facts=[pscustomobject]@{} }
$rGuard = Invoke-V4C0Analysis $productGuard (New-TestAnalysis 'G001')
Assert-True ($rGuard.route.subfamily -eq 'protective_gear') '籃球護膝必須優先判為 protective_gear。'

# 4) Non-sports still routes safely.
$productElectronics = [pscustomobject]@{
    product_id = 'E001'
    name = 'Type-C 充電線'
    category = 'Electronics/Accessories'
    verified_facts = [pscustomobject]@{}
}
$r2 = Invoke-V4C0Analysis $productElectronics (New-TestAnalysis 'E001')
Assert-True ($r2.route.family -eq 'electronics') '3C 商品應被安全辨識。'
Assert-True ($r2.route.policy -eq 'universal_safe_fallback') '非運動商品第一階段走通用安全兜底。'

# 5) Mixed-catalog regression: generic "戶外" must NOT imply sports.
$productGardenLight = [pscustomobject]@{
    product_id = '53415651688'
    name = '太陽能戶外庭院燈 拐杖造型地埋景觀燈 花園草坪LED裝飾燈 免插電防水 過道造景照明'
    category = 'Home & Living/Garden'
    verified_facts = [pscustomobject]@{}
}
$rGardenLight = Invoke-V4C0Analysis $productGardenLight (New-TestAnalysis '53415651688')
Assert-True ($rGardenLight.route.family -eq 'home_garden') '戶外庭院燈不得因「戶外」誤判為 sports。'
Assert-True ($rGardenLight.route.subfamily -eq 'lighting') '戶外庭院燈應路由到 home_garden/lighting。'

# 6) Mixed-catalog regression: solar irrigation is home/garden, not outdoor sports.
$productIrrigation = [pscustomobject]@{
    product_id = '40983371866'
    name = '太陽能自動澆花器 免插電滴灌系統 陽台定時澆水器 植物盆栽自動灌溉 太陽能供水'
    category = 'Home & Living/Garden'
    verified_facts = [pscustomobject]@{}
}
$rIrrigation = Invoke-V4C0Analysis $productIrrigation (New-TestAnalysis '40983371866')
Assert-True ($rIrrigation.route.family -eq 'home_garden') '自動澆花器不得誤判為 sports。'
Assert-True ($rIrrigation.route.subfamily -eq 'irrigation') '自動澆花器應路由到 home_garden/irrigation。'

# 7) Explicit camping noun still routes to sports/outdoor_camping.
$productCampingLight = [pscustomobject]@{
    product_id = '46365638146'
    name = '太陽能露營燈 戶外野營應急照明燈 便攜手電筒'
    category = 'Sports & Outdoors/Camping'
    verified_facts = [pscustomobject]@{}
}
$rCampingLight = Invoke-V4C0Analysis $productCampingLight (New-TestAnalysis '46365638146')
Assert-True ($rCampingLight.route.family -eq 'sports') '明確露營燈仍應屬 sports。'
Assert-True ($rCampingLight.route.subfamily -eq 'outdoor_camping') '明確露營燈應屬 outdoor_camping。'
Assert-True ($rCampingLight.route.priority -eq 'sports_deep') '露營商品應使用 sports_deep 規則。'

# 8) Unknown category is not allowed into paid generation automatically.
$productUnknown = [pscustomobject]@{ product_id='U001'; name='神秘商品XYZ'; category='Misc'; verified_facts=[pscustomobject]@{} }
$analysisUnknown = [pscustomobject]@{ product_id='U001'; images=@((New-TestImage 'u1.jpg' 0 0.18)) }
$r3 = Invoke-V4C0Analysis $productUnknown $analysisUnknown
Assert-True ($r3.route.family -eq 'generic') '未知類目應進 generic。'
Assert-True ($r3.can_enter_paid_generation -eq $false) '未知商品不得直接進付費生成。'

# 9) Duplicate source must block that image.
$dup = New-TestImage 'dup.jpg' 0 0.10
$dup.duplicate = $true
$productDup = [pscustomobject]@{ product_id='D001'; name='羽球拍'; category='Sports'; verified_facts=[pscustomobject]@{} }
$analysisDup = [pscustomobject]@{ product_id='D001'; images=@($dup,(New-TestImage 'ok.jpg' 1 0.12)) }
$r4 = Invoke-V4C0Analysis $productDup $analysisDup
Assert-True (@($r4.image_decisions | Where-Object { $_.action -eq 'BLOCK' }).Count -eq 1) '重複來源必須 BLOCK。'

# 10) Unverified dimensions cannot create a dimension slot.
$productNoDims = [pscustomobject]@{ product_id='H001'; name='戶外露營帳篷'; category='Sports/Outdoor'; verified_facts=[pscustomobject]@{} }
$r5 = Invoke-V4C0Analysis $productNoDims (New-TestAnalysis 'H001')
Assert-True (@($r5.five_image_plan.slots | Where-Object { $_.role -match 'dimensions' }).Count -eq 0) '沒有 verified dimensions 時不得安排尺寸圖。'

Write-Host 'V4-C0 universal product engine smoke: PASS'
