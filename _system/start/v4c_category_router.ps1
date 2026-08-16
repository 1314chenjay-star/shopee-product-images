# TinySnow V4-C0
# Sports-first universal category router.
# Product structure wins over sport-context words. Generic words like "戶外" alone never imply sports/camping.

function Test-V4CAnyKeyword([string]$Text, [string[]]$Keywords) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($keyword in $Keywords) {
        if (-not [string]::IsNullOrWhiteSpace($keyword) -and $Text.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function New-V4CRoute([string]$Family, [string]$Subfamily, [double]$Confidence, [string[]]$RiskFields, [string]$Priority = 'standard') {
    return [pscustomobject]@{
        family = $Family
        subfamily = $Subfamily
        confidence = [Math]::Round($Confidence,2)
        priority = $Priority
        risk_fields = [string[]]$RiskFields
        policy = if ($Priority -eq 'sports_deep') { 'sports_deep_rules' } else { 'universal_safe_fallback' }
    }
}

function Get-V4CCategoryRoute($Product, $Evidence) {
    $title = [string](Get-V4CProperty $Evidence 'title' (Get-V4CProperty $Product 'name' ''))
    $category = [string](Get-V4CProperty $Evidence 'raw_category' (Get-V4CProperty $Product 'category' ''))
    $text = ($title + ' ' + $category)
    $sportContext = Test-V4CAnyKeyword $text @('運動','运动','Sports','籃球','篮球','排球','足球','棒球','壘球','垒球','羽球','羽毛球','網球','网球','桌球','乒乓','匹克球','壁球','跑步','健身','瑜伽','露營','露营','登山','游泳','自行車','自行车','騎行','骑行')

    # Structural/product-form routes outrank context words.
    if (Test-V4CAnyKeyword $title @('護膝','护膝','護腕','护腕','護肘','护肘','護踝','护踝','護具','护具','頭盔','头盔')) {
        return New-V4CRoute 'sports' 'protective_gear' 0.97 @('size','material','support_level','protection_claims','medical_claims','certification') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $title @('短褲','短裤','長褲','长裤','上衣','外套','背心','T恤','t恤','裙','泳衣','衣服','運動服','运动服','球衣','褲子','裤子','襪子','袜子')) {
        $sub = if ($sportContext) { 'sports_apparel' } else { 'apparel' }
        $priority = if ($sportContext) { 'sports_deep' } else { 'standard' }
        return New-V4CRoute 'apparel' $sub 0.95 @('pockets','zipper','lining','fit','sleeve','hem','print','size','material','color_variant') $priority
    }
    if (Test-V4CAnyKeyword $title @('球鞋','跑鞋','運動鞋','运动鞋','登山鞋','拖鞋','涼鞋','凉鞋','靴子','鞋子')) {
        $sub = if ($sportContext) { 'sports_footwear' } else { 'footwear' }
        $priority = if ($sportContext) { 'sports_deep' } else { 'standard' }
        return New-V4CRoute 'shoes' $sub 0.94 @('size','material','sole','closure','compatibility','waterproof_claims') $priority
    }
    if (Test-V4CAnyKeyword $title @('包包','背包','後背包','后背包','腰包','手提包','旅行袋','球袋','拍套')) {
        $sub = if ($sportContext) { 'sports_bag' } else { 'bags' }
        $priority = if ($sportContext) { 'sports_deep' } else { 'standard' }
        return New-V4CRoute 'bags' $sub 0.94 @('capacity','dimensions','material','pockets','compartments','zipper','strap','load_rating') $priority
    }

    # Explicit sports/outdoor equipment routes. Generic "戶外" is intentionally NOT sufficient.
    if (Test-V4CAnyKeyword $text @('羽球','羽毛球','網球','网球','桌球','乒乓','匹克球','壁球','球拍')) {
        return New-V4CRoute 'sports' 'racket_sports' 0.95 @('racket_type','material','weight','grip','string','size','bundle_count','accessories') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('籃球','篮球','排球','足球','棒球','壘球','垒球','橄欖球','橄榄球','球類','球类')) {
        return New-V4CRoute 'sports' 'ball_sports' 0.96 @('size','material','ball_type','surface_pattern','bundle_count','accessories','certification') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('啞鈴','哑铃','壺鈴','壶铃','彈力帶','弹力带','瑜伽','健身','訓練器','训练器','拉力器','跳繩','跳绳','槓鈴','杠铃')) {
        return New-V4CRoute 'sports' 'fitness_training' 0.94 @('weight','resistance','load_rating','material','dimensions','bundle_count','accessories','usage_claims') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('露營','露营','帳篷','帐篷','睡袋','登山','野營','野营','天幕','營釘','营钉','露營燈','露营灯','野餐墊','野餐垫')) {
        return New-V4CRoute 'sports' 'outdoor_camping' 0.94 @('dimensions','material','waterproof_rating','load_rating','capacity','battery','power','accessories','bundle_count') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('泳鏡','泳镜','泳帽','游泳','浮板','蛙鞋','潛水','潜水')) {
        return New-V4CRoute 'sports' 'swimming' 0.93 @('size','material','waterproof_claims','lens_claims','certification','accessories') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('自行車','自行车','單車','单车','騎行','骑行','碼表','码表','自行車燈','自行车灯')) {
        return New-V4CRoute 'sports' 'cycling' 0.92 @('compatibility','mounting','dimensions','material','battery','power','waterproof_rating') 'sports_deep'
    }

    # Home / garden / solar products frequently coexist in mixed Shopee catalogs.
    if (Test-V4CAnyKeyword $title @('澆花','浇花','滴灌','灌溉','澆水器','浇水器')) {
        return New-V4CRoute 'home_garden' 'irrigation' 0.95 @('power','battery','timer','flow_rate','capacity','dimensions','material','accessories','bundle_count','waterproof_rating')
    }
    if (Test-V4CAnyKeyword $title @('驅鳥','驱鸟','驅獸','驱兽','防獸','防兽','滅蚊燈','灭蚊灯','捕蟲燈','捕虫灯')) {
        return New-V4CRoute 'home_garden' 'garden_protection' 0.93 @('power','battery','sensor_claims','sound_claims','light_claims','range_claims','waterproof_rating','certification','accessories')
    }
    if (Test-V4CAnyKeyword $title @('庭院燈','庭院灯','花園燈','花园灯','草坪燈','草坪灯','地埋燈','地埋灯','路燈','路灯','洗牆燈','洗墙灯','景觀燈','景观灯','風鈴燈','风铃灯','太陽能燈','太阳能灯','壁燈','壁灯')) {
        return New-V4CRoute 'home_garden' 'lighting' 0.95 @('power','battery','brightness','color_temperature','sensor_claims','waterproof_rating','ip_rating','dimensions','material','installation','bundle_count')
    }
    if (Test-V4CAnyKeyword $title @('庭院擺飾','庭院摆饰','花園擺飾','花园摆饰','園藝','园艺')) {
        return New-V4CRoute 'home_garden' 'garden_decor' 0.88 @('dimensions','material','power','battery','waterproof_rating','bundle_count','accessories')
    }

    # Non-sports universal safe fallback routes.
    if (Test-V4CAnyKeyword $text @('充電','充电','充電器','充电器','充電線','充电线','耳機','耳机','藍牙','蓝牙','USB','Type-C','電源','电源','行動電源','移动电源')) {
        return New-V4CRoute 'electronics' 'electronics_accessory' 0.92 @('connector','voltage','power','capacity','compatibility','certification','battery','protocol')
    }
    if (Test-V4CAnyKeyword $text @('收納','收纳','置物','衣架','掛架','挂架','整理盒','收納盒','收纳盒')) {
        return New-V4CRoute 'home_storage' 'storage' 0.91 @('dimensions','material','layers','capacity','load_rating','installation','bundle_count')
    }
    if (Test-V4CAnyKeyword $text @('鍋','锅','杯','餐具','砧板','刀具','廚房','厨房','保鮮','保鲜')) {
        return New-V4CRoute 'kitchen' 'kitchenware' 0.89 @('material','capacity','dimensions','heat_rating','food_contact_claims','bundle_count')
    }
    if (Test-V4CAnyKeyword $text @('桌','椅','櫃','柜','家具','層架','层架','床','沙發','沙发')) {
        return New-V4CRoute 'furniture' 'furniture' 0.89 @('dimensions','material','load_rating','layers','installation','structure')
    }
    if (Test-V4CAnyKeyword $text @('寵物','宠物','貓','猫','狗','牽引','牵引','項圈','项圈','貓砂','猫砂')) {
        return New-V4CRoute 'pet' 'pet_supplies' 0.90 @('pet_type','size','material','capacity','safety_claims','medical_claims')
    }
    if (Test-V4CAnyKeyword $text @('扳手','螺絲','螺丝','鉗','钳','工具','鑽頭','钻头','套筒','五金')) {
        return New-V4CRoute 'tools' 'tools' 0.90 @('dimensions','material','interface','compatibility','load_rating','bundle_contents')
    }
    if (Test-V4CAnyKeyword $text @('玩具','積木','积木','拼圖','拼图','公仔','模型')) {
        return New-V4CRoute 'toys' 'toys' 0.87 @('piece_count','dimensions','material','age_claims','accessories','certification')
    }
    if (Test-V4CAnyKeyword $text @('汽車','汽车','機車','机车','車用','车用','車載','车载','雨刷','方向盤','方向盘')) {
        return New-V4CRoute 'auto' 'auto_accessory' 0.89 @('vehicle_compatibility','mounting','dimensions','material','power','certification')
    }
    if (Test-V4CAnyKeyword $text @('美容','美妝','美妆','護膚','护肤','洗面','面膜','乳液','香水','個人護理','个人护理')) {
        return New-V4CRoute 'beauty' 'beauty_personal_care' 0.88 @('ingredients','capacity','medical_claims','efficacy_claims','certification','usage_claims')
    }
    if (Test-V4CAnyKeyword $text @('項鍊','项链','戒指','耳環','耳环','手鍊','手链','飾品','饰品')) {
        return New-V4CRoute 'jewelry' 'jewelry' 0.88 @('material','dimensions','plating','gem_claims','size','color_variant')
    }

    return New-V4CRoute 'generic' 'unknown' 0.35 @('dimensions','material','features','accessories','bundle_count','brand','certification')
}
