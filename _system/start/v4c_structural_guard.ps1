# TinySnow V4-C0
# Product-body structural guard.
# This layer corrects context-word routing only when the structural noun is the primary product body near the title start.

function Get-V4CStructuralHead([string]$Title, [int]$Length = 28) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return '' }
    $clean = $Title.Trim()
    return $clean.Substring(0, [Math]::Min($Length, $clean.Length))
}

function Test-V4CStructuralSportContext([string]$Title, [string]$Category) {
    $text = ($Title + ' ' + $Category)
    return Test-V4CAnyKeyword $text @(
        'Sports','運動','运动','籃球','篮球','排球','足球','棒球','壘球','垒球','羽球','羽毛球','網球','网球','桌球','乒乓',
        '匹克球','壁球','跑步','健身','瑜伽','普拉提','露營','露营','登山','游泳','拳擊','拳击','武術','武术','太極','太极'
    )
}

function Test-V4CPrimaryProtectiveBody([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    # Allow a short brand/sport prefix (e.g. 籃球護腿套), but not a late accessory/description mention.
    # A training target such as 護腰靶 is explicitly excluded.
    return ($Title.Trim() -match '^(?:.{0,8})?(護膝|护膝|護腕|护腕|護肘|护肘|護踝|护踝|護腿|护腿|護腰|护腰|護肩|护肩|護背|护背|護胸|护胸|護臂|护臂|護掌|护掌|護指|护指|護齒|护齿|牙套|頭盔|头盔|拳擊手套|拳击手套|拳套|纏手帶|缠手带|綁手帶|绑手带|運動肌貼|运动肌贴|肌內效貼|肌内效贴)(?!靶)')
}

function Test-V4CPrimaryApparelBody([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    # Product-form noun must appear early enough to describe the item itself, not a bundled accessory later in the title.
    return ($Title.Trim() -match '^(?:.{0,10})?(短褲|短裤|長褲|长裤|褲子|裤子|內褲|内裤|三角褲|三角裤|內衣|内衣|打底褲|打底裤|上衣|外套|背心|T恤|t恤|球衣|運動服|运动服|泳衣|裙|襪|袜|襪子|袜子|瑜伽襪|瑜伽袜|普拉提襪|普拉提袜)')
}

function Test-V4CPrimaryRacketCaseBody([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    $clean = $Title.Trim()
    # "球拍套組 / 拍套裝" means a racket set, not a racket cover.
    if ($clean -match '^(?:.{0,6})?(球拍套組|球拍套组|拍套裝|拍套装)') { return $false }
    return ($clean -match '^(?:.{0,6})?(桌球拍保護套|桌球拍保护套|乒乓球拍保護套|乒乓球拍保护套|球拍保護套|球拍保护套|球拍盒|拍盒|球拍袋|球拍包|拍套|球桿包|球杆包|撞球桿包|撞球杆包)')
}

function Test-V4CPrimarySportsTowelBody([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    $clean = $Title.Trim()
    return ($clean -match '^(?:.{0,8})?(運動吸汗毛巾|运动吸汗毛巾|運動毛巾|运动毛巾|健身毛巾|跑步毛巾|擦汗巾|吸汗巾|毛巾)')
}

function Test-V4CPrimaryCampingWaterContainer([string]$Title, [string]$Category) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    $clean = $Title.Trim()
    $body = ($clean -match '^(?:.{0,6})?(戶外折疊水桶|户外折叠水桶|折疊水桶|折叠水桶|伸縮水桶|伸缩水桶|儲水桶|储水桶|露營水桶|露营水桶|折疊儲水桶|折叠储水桶)')
    if (-not $body) { return $false }
    return Test-V4CAnyKeyword ($clean + ' ' + $Category) @('露營','露营','Camping','野營','野营','戶外','户外')
}

function Resolve-V4CStructuralRoute($Product, $Evidence, $CurrentRoute) {
    $title = [string](Get-V4CProperty $Evidence 'title' (Get-V4CProperty $Product 'name' ''))
    $category = [string](Get-V4CProperty $Evidence 'raw_category' (Get-V4CProperty $Product 'category' ''))
    $head = Get-V4CStructuralHead $title 32
    $sport = Test-V4CStructuralSportContext $title $category

    # Life-safety products remain in their dedicated route.
    if (Test-V4CAnyKeyword $head @('救生衣','救生背心','浮力背心','助浮衣','浮力衣')) { return $CurrentRoute }

    if (Test-V4CPrimaryProtectiveBody $title) {
        return New-V4CRoute 'sports' 'protective_gear' 0.98 @('size','material','support_level','protection_claims','medical_claims','certification') 'sports_deep'
    }

    if (Test-V4CPrimaryApparelBody $title) {
        $sub = if ($sport) { 'sports_apparel' } else { 'apparel' }
        $priority = if ($sport) { 'sports_deep' } else { 'standard' }
        return New-V4CRoute 'apparel' $sub 0.97 @('pockets','zipper','lining','fit','sleeve','hem','print','size','material','color_variant') $priority
    }

    if (Test-V4CPrimaryRacketCaseBody $title) {
        $bagSub = if ($sport) { 'sports_bag' } else { 'bags' }
        $bagPriority = if ($sport) { 'sports_deep' } else { 'standard' }
        return New-V4CRoute 'bags' $bagSub 0.97 @('capacity','dimensions','material','pockets','compartments','zipper','strap','load_rating','waterproof_claims') $bagPriority
    }

    # Secondary car-use wording must not turn a sports towel into an auto accessory.
    if ((Test-V4CPrimarySportsTowelBody $title) -and $sport) {
        return New-V4CRoute 'sports' 'sports_towel' 0.97 @('dimensions','material','absorbency_claims','quick_dry_claims','cooling_claims','bundle_count','color_variant') 'sports_deep'
    }

    # A camping folding water bucket remains outdoor/camping even if the title also says 車載/车载.
    if (Test-V4CPrimaryCampingWaterContainer $title $category) {
        return New-V4CRoute 'sports' 'outdoor_camping' 0.97 @('capacity','dimensions','material','leakproof_claims','food_contact_claims','temperature_rating','accessories','bundle_count') 'sports_deep'
    }

    return $CurrentRoute
}

function Get-V4CFinalCategoryRoute($Product, $Evidence) {
    $base = Get-V4CCategoryRoute $Product $Evidence
    return Resolve-V4CStructuralRoute $Product $Evidence $base
}
