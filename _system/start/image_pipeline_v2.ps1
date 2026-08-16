$ErrorActionPreference = 'Stop'

function Get-V2Workspace {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $path = Join-Path $systemRoot 'workspace'
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-V2ProjectRoot {
    return (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
}

function Get-GeneratedImagesDirectoryV2 {
    $path = Join-Path (Get-V2ProjectRoot) '已生成圖片'
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-ImageInfoV2([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('找不到圖片：' + $Path) }
    Add-Type -AssemblyName System.Drawing
    $stream = [IO.File]::OpenRead($Path)
    $image = $null
    try {
        $image = [Drawing.Image]::FromStream($stream, $true, $true)
        return [pscustomobject]@{
            width = [int]$image.Width
            height = [int]$image.Height
            length = [long](Get-Item -LiteralPath $Path).Length
            hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
    }
    finally {
        if ($null -ne $image) { $image.Dispose() }
        $stream.Dispose()
    }
}

function Convert-ToPngV2([string]$Source, [string]$Target) {
    Add-Type -AssemblyName System.Drawing
    $stream = [IO.File]::OpenRead($Source)
    $image = $null
    try {
        $image = [Drawing.Image]::FromStream($stream, $true, $true)
        $image.Save($Target, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($null -ne $image) { $image.Dispose() }
        $stream.Dispose()
    }
    $info = Get-ImageInfoV2 $Target
    if ($info.length -le 0) { throw '圖片轉存後為 0KB。' }
    return $info
}

function Download-ProductImagesV2($Product) {
    $productId = [string]$Product.product_id
    if ($productId -notmatch '^\d{5,30}$') { throw '商品ID格式錯誤。' }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $rawDir = Join-Path (Get-V2Workspace) ('raw_images\' + $productId)
    New-Item -ItemType Directory -Path $rawDir -Force | Out-Null

    $downloaded = @()
    $failures = @()
    $urls = @($Product.image_urls)

    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = ([string]$urls[$index]).Trim()
        if ($url -notmatch '^https?://') { continue }

        if ($index -eq 0) { $name = '00_main_original.png' }
        else { $name = ('{0:D2}_detail_original.png' -f $index) }
        $target = Join-Path $rawDir $name

        if (Test-Path -LiteralPath $target) {
            try {
                Get-ImageInfoV2 $target | Out-Null
                $downloaded += $target
                continue
            }
            catch {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            }
        }

        $ok = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $temp = $target + '.download'
            try {
                Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing -TimeoutSec 90
                Convert-ToPngV2 $temp $target | Out-Null
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                $downloaded += $target
                $ok = $true
                break
            }
            catch {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                if ($attempt -lt 3) { Start-Sleep -Seconds @(2,5)[$attempt - 1] }
            }
        }

        if (-not $ok) {
            $failures += $url
            Write-TinySnowLogV2 '原圖下載' $url ('product_id=' + $productId) $false '下載或圖片驗證失敗'
        }
    }

    if ($downloaded.Count -eq 0) { throw '所有原始圖片都下載失敗，已停止；不會呼叫生圖 API。' }

    return [pscustomobject]@{
        paths = @($downloaded)
        failed_urls = @($failures)
        folder = $rawDir
    }
}

function Analyze-ProductImagesV2([string]$ProductId, [string[]]$Paths) {
    if ($ProductId -notmatch '^\d{5,30}$') { throw '商品ID格式錯誤。' }
    if ($null -eq $Paths -or $Paths.Count -eq 0) { throw '沒有可分析的原圖。' }

    $seen = @{}
    $items = @()
    $references = @()

    for ($position = 0; $position -lt $Paths.Count; $position++) {
        $imagePath = [string]$Paths[$position]
        $info = Get-ImageInfoV2 $imagePath
        $duplicate = $seen.ContainsKey($info.hash)
        if (-not $duplicate) { $seen[$info.hash] = $true }

        if ($info.height -gt 0) { $ratio = $info.width / [double]$info.height }
        else { $ratio = 0 }
        $squareDelta = [Math]::Abs($ratio - 1.0)

        $items += [pscustomobject]@{
            path = $imagePath
            file = Split-Path $imagePath -Leaf
            position = $position
            width = $info.width
            height = $info.height
            bytes = $info.length
            sha256 = $info.hash
            duplicate = $duplicate
            near_square = ($squareDelta -le 0.15)
        }
        if (-not $duplicate) { $references += $imagePath }
    }

    $analysis = [pscustomobject]@{
        product_id = $ProductId
        analyzed_at = (Get-Date).ToString('o')
        semantic_check = 'not_available_in_local_preflight'
        images = @($items)
        reference_order = @($references)
        failed = $false
    }

    $folder = Split-Path $Paths[0] -Parent
    $analysis | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $folder 'analysis.json') -Encoding UTF8

    $lines = @()
    $lines += ('商品ID：' + $ProductId)
    $lines += ('可用原圖：' + $items.Count + ' 張')
    $lines += ('去重後參考圖：' + $references.Count + ' 張')
    $lines += '本地預檢：能否開啟、尺寸、檔案大小、SHA256重複、接近1:1。'
    $lines += '注意：本地預檢不能可靠判斷圖片內簡體文字、品牌、尺寸或規格語意衝突；最終成品仍需看圖確認。'
    $lines += ''
    foreach ($item in $items) {
        if ($item.duplicate) { $dupText = '重複' } else { $dupText = '正常' }
        $lines += ('{0}｜{1}x{2}｜{3} bytes｜{4}' -f $item.file, $item.width, $item.height, $item.bytes, $dupText)
    }
    $lines | Set-Content -LiteralPath (Join-Path $folder 'analysis_summary.txt') -Encoding UTF8

    return $analysis
}

function Test-SelectedProductImagesV2 {
    $product = Get-SelectedProductV2
    $checkpoint = Get-CheckpointV2 ([string]$product.product_id)
    Set-CheckpointActivityV2 $checkpoint '原圖下載中' '準備下載並檢查原圖'
    $download = Download-ProductImagesV2 $product
    $checkpoint.download_complete = $true
    Set-CheckpointActivityV2 $checkpoint '原圖分析中' ("已下載 {0} 張原圖，開始分析" -f @($download.paths).Count)
    $pathArray = [string[]]@($download.paths)
    $analysis = Analyze-ProductImagesV2 ([string]$product.product_id) $pathArray
    $checkpoint.analysis_complete = $true
    Set-CheckpointActivityV2 $checkpoint '尚未開始' ("原圖檢查完成，共 {0} 張可用" -f @($download.paths).Count)
    return [pscustomobject]@{
        product = $product
        downloaded = @($download.paths)
        failed_urls = @($download.failed_urls)
        analysis = $analysis
        folder = $download.folder
    }
}

function Get-CheckpointPathV2([string]$ProductId) {
    $dir = Join-Path (Get-V2Workspace) ('checkpoints\' + $ProductId)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return (Join-Path $dir 'checkpoint_v2.json')
}

function Get-CheckpointV2([string]$ProductId) {
    $path = Get-CheckpointPathV2 $ProductId
    if (Test-Path -LiteralPath $path) {
        $checkpoint = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $defaults = [ordered]@{ download_complete=$false; analysis_complete=$false; finalization_complete=$false; current_status='尚未開始'; last_log='尚無處理紀錄' }
        foreach ($name in $defaults.Keys) {
            if (-not ($checkpoint.PSObject.Properties.Name -contains $name)) {
                Add-Member -InputObject $checkpoint -NotePropertyName $name -NotePropertyValue $defaults[$name]
            }
        }
        foreach ($slot in @('main','detail1','detail2','detail3','detail4')) {
            $slotState = $checkpoint.states.$slot
            if (-not ($slotState.PSObject.Properties.Name -contains 'layout_retries')) {
                Add-Member -InputObject $slotState -NotePropertyName 'layout_retries' -NotePropertyValue 0
            }
        }
        return $checkpoint
    }

    $states = [ordered]@{}
    foreach ($slot in @('main','detail1','detail2','detail3','detail4')) {
        $states[$slot] = [ordered]@{ status='pending'; retries=0; layout_retries=0; last_error='' }
    }
    $checkpoint = [pscustomobject]@{
        product_id = $ProductId
        states = [pscustomobject]$states
        download_complete = $false
        analysis_complete = $false
        finalization_complete = $false
        current_status = '尚未開始'
        last_log = '尚無處理紀錄'
        updated_at = (Get-Date).ToString('o')
    }
    $checkpoint | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Set-CheckpointActivityV2($Checkpoint, [string]$Status, [string]$Summary) {
    $Checkpoint.current_status = $Status
    $Checkpoint.last_log = $Summary
    Save-CheckpointV2 $Checkpoint
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Summary) -ForegroundColor Cyan
}

function Get-ProgressSummaryV2($Product) {
    $checkpoint = Get-CheckpointV2 ([string]$Product.product_id)
    $doneSlots = @($checkpoint.states.PSObject.Properties | Where-Object { $_.Value.status -eq 'done' }).Count
    $failedSlots = @($checkpoint.states.PSObject.Properties | Where-Object { $_.Value.status -eq 'failed' }).Count
    $steps = 0
    if ([bool]$checkpoint.download_complete) { $steps++ }
    if ([bool]$checkpoint.analysis_complete) { $steps++ }
    if ($checkpoint.states.main.status -eq 'done') { $steps++ }
    if ($checkpoint.states.detail1.status -eq 'done' -and $checkpoint.states.detail2.status -eq 'done') { $steps++ }
    if ($checkpoint.states.detail3.status -eq 'done' -and $checkpoint.states.detail4.status -eq 'done') { $steps++ }
    if ([bool]$checkpoint.finalization_complete) { $steps++ }
    return [pscustomobject]@{ checkpoint=$checkpoint; completed_steps=$steps; generated=$doneSlots; failed=$failedSlots }
}

function Save-CheckpointV2($Checkpoint) {
    $Checkpoint.updated_at = (Get-Date).ToString('o')
    $Checkpoint | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-CheckpointPathV2 ([string]$Checkpoint.product_id)) -Encoding UTF8
}

function Get-PromptV2([string]$Slot, [string]$Name) {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $templatePath = Join-Path $systemRoot 'config\prompt_templates.json'
    $templates = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    switch ($Slot) {
        'main' { $key = 'main_image' }
        'detail1' { $key = 'detail_overview' }
        'detail2' { $key = 'detail_structure' }
        'detail3' { $key = 'detail_scene' }
        'detail4' { $key = 'detail_spec' }
        default { $key = 'detail_general' }
    }
    return ('商品名稱僅供辨識：' + $Name + "。`n" + [string]$templates.$key + "`n共同硬規則：" + [string]$templates.common_rules)
}

function Get-ReferencesForSlotV2($Analysis, [string]$Slot, [int]$Maximum) {
    $order = @($Analysis.reference_order)
    if ($order.Count -eq 0) { throw '沒有可用參考圖。' }
    $maximum = [Math]::Min([Math]::Max(1,$Maximum), $order.Count)
    if ($order.Count -eq 1 -or $maximum -eq 1) { return @([string]$order[0]) }

    $details = @($order | Select-Object -Skip 1)
    $refs = @([string]$order[0])
    switch ($Slot) {
        'detail1' { $offset = 0 }
        'detail2' { $offset = 1 }
        'detail3' { $offset = 2 }
        'detail4' { $offset = 3 }
        default { $offset = 0 }
    }

    if ($Slot -eq 'main') {
        for ($i = 0; $i -lt $details.Count -and $refs.Count -lt $maximum; $i++) {
            $refs += [string]$details[$i]
        }
    }
    else {
        for ($i = 0; $i -lt $details.Count -and $refs.Count -lt $maximum; $i++) {
            $idx = ($offset + $i) % $details.Count
            $candidate = [string]$details[$idx]
            if ($refs -notcontains $candidate) { $refs += $candidate }
        }
    }
    return $refs
}

function Convert-ToFinalJpegV2([string]$Source, [string]$Target) {
    $info = Get-ImageInfoV2 $Source
    if ($info.width -lt 100 -or $info.height -lt 100) { throw '生成圖片尺寸異常。' }
    $ratio = $info.width / [double]$info.height
    if ($ratio -lt 0.9 -or $ratio -gt 1.1) { throw ('生成圖片不是接近1:1：' + $info.width + 'x' + $info.height) }

    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Image]::FromFile($Source)
    try { $image.Save($Target, [Drawing.Imaging.ImageFormat]::Jpeg) }
    finally { $image.Dispose() }
    return (Get-ImageInfoV2 $Target)
}

function Test-MainImageFitnessV2([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object Drawing.Bitmap $Path
    try {
        $values = @()
        for ($x = 0; $x -lt $bitmap.Width; $x += [Math]::Max(1, [int]($bitmap.Width / 16))) {
            for ($y = 0; $y -lt $bitmap.Height; $y += [Math]::Max(1, [int]($bitmap.Height / 16))) {
                $pixel = $bitmap.GetPixel($x, $y)
                $values += (($pixel.R + $pixel.G + $pixel.B) / 3.0)
            }
        }
        $average = ($values | Measure-Object -Average).Average
        $variance = (($values | ForEach-Object { ($_ - $average) * ($_ - $average) }) | Measure-Object -Average).Average
        if ([Math]::Sqrt($variance) -lt 10) { throw '主圖適配檢查未通過：畫面過於單調或接近空白。' }
    }
    finally { $bitmap.Dispose() }
}

function Get-LayoutSimilarityThresholdV2 {
    return 0.90
}

function Get-MaxLayoutRetriesV2 {
    return 2
}

function Get-LayoutDirectionV2([string]$Slot, [int]$LayoutAttempt) {
    $layouts = @{
        main = @('非對稱封面式：大商品主體搭配醒目標題區', '中央商品加周圍短賣點', '斜向動態封面式')
        detail1 = @('上下分區式：商品總覽與核心賣點分層', '中央商品加周圍資訊', '左右分欄式但不可沿用已完成圖片骨架')
        detail2 = @('拆解式：配件或局部細節分散標註', '局部放大式：主體搭配不同位置的細節視窗', '多卡片資訊式：僅列原圖確認的結構或內含物')
        detail3 = @('場景主畫面式：使用動作佔主要畫面', '步驟流程式：依可確認方式呈現操作順序', '上下分區式：情境與操作提示分開')
        detail4 = @('規格資訊式：只使用可靠規格，否則改提醒資訊', '左右分欄式：商品與可靠選購資訊分開', '多卡片補充資訊式：不得猜測數字')
    }
    $choices = @($layouts[$Slot])
    if ($choices.Count -eq 0) { $choices = @('上下分區式', '中央商品加周圍資訊', '左右分欄式') }
    return [string]$choices[$LayoutAttempt % $choices.Count]
}

function Get-LayoutRetryPromptV2([string]$Slot, [int]$LayoutAttempt) {
    $direction = Get-LayoutDirectionV2 $Slot $LayoutAttempt
    if ($LayoutAttempt -eq 0) {
        return ("`n本張指定版型：{0}。必須避開整組已完成圖片的商品位置、標題位置、資訊區、人物、場景與大色塊骨架。" -f $direction)
    }
    return ("`n版型去重重生：本次構圖不得沿用上一張。改用「{0}」，明顯改變商品位置、文字區位置、左右／上下結構、大色塊與畫面骨架；角色任務與事實規則仍須完全遵守。" -f $direction)
}

function Get-LayoutFingerprintV2([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $source = New-Object Drawing.Bitmap $Path
    $small = New-Object Drawing.Bitmap 12,12
    $graphics = [Drawing.Graphics]::FromImage($small)
    try {
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $graphics.DrawImage($source, 0, 0, 12, 12)
        $gray = @()
        $histogram = @(0,0,0,0,0,0,0,0)
        for ($y = 0; $y -lt 12; $y++) {
            for ($x = 0; $x -lt 12; $x++) {
                $pixel = $small.GetPixel($x, $y)
                $value = [double](0.299 * $pixel.R + 0.587 * $pixel.G + 0.114 * $pixel.B)
                $gray += $value
                $bin = [Math]::Min(7, [int]($value / 32))
                $histogram[$bin]++
            }
        }
        $edges = @()
        for ($y = 0; $y -lt 12; $y++) {
            for ($x = 0; $x -lt 12; $x++) {
                $index = $y * 12 + $x
                $right = if ($x -lt 11) { [Math]::Abs($gray[$index] - $gray[$index + 1]) } else { 0 }
                $down = if ($y -lt 11) { [Math]::Abs($gray[$index] - $gray[$index + 12]) } else { 0 }
                $edges += [Math]::Min(255, $right + $down)
            }
        }
        return [pscustomobject]@{ gray=@($gray); edges=@($edges); histogram=@($histogram) }
    }
    finally {
        $graphics.Dispose()
        $small.Dispose()
        $source.Dispose()
    }
}

function Get-LayoutSimilarityV2([string]$FirstPath, [string]$SecondPath) {
    $first = Get-LayoutFingerprintV2 $FirstPath
    $second = Get-LayoutFingerprintV2 $SecondPath
    $grayDifference = 0.0
    $edgeDifference = 0.0
    for ($i = 0; $i -lt $first.gray.Count; $i++) {
        $grayDifference += [Math]::Abs($first.gray[$i] - $second.gray[$i])
        $edgeDifference += [Math]::Abs($first.edges[$i] - $second.edges[$i])
    }
    $graySimilarity = 1.0 - ($grayDifference / ($first.gray.Count * 255.0))
    $edgeSimilarity = 1.0 - ($edgeDifference / ($first.edges.Count * 255.0))
    $histogramDifference = 0.0
    for ($i = 0; $i -lt 8; $i++) { $histogramDifference += [Math]::Abs($first.histogram[$i] - $second.histogram[$i]) }
    $histogramSimilarity = 1.0 - ($histogramDifference / (2.0 * $first.gray.Count))
    return [Math]::Max(0.0, [Math]::Min(1.0, 0.60 * $graySimilarity + 0.25 * $edgeSimilarity + 0.15 * $histogramSimilarity))
}

function Test-LayoutDiversityV2([string]$CandidatePath, [string[]]$ExistingPaths) {
    $highest = 0.0
    $matched = ''
    foreach ($existingPath in @($ExistingPaths)) {
        if (-not (Test-Path -LiteralPath $existingPath -PathType Leaf)) { continue }
        $similarity = Get-LayoutSimilarityV2 $CandidatePath $existingPath
        if ($similarity -gt $highest) { $highest = $similarity; $matched = $existingPath }
    }
    return [pscustomobject]@{
        high_similarity = ($highest -ge (Get-LayoutSimilarityThresholdV2))
        similarity = $highest
        compared_path = $matched
    }
}

function Get-CompactTransportPromptV2([string]$Slot, [string]$Name) {
    $common = '商品名稱僅供辨識；所有數字、尺寸、規格、材質、功能、品牌、型號、配件、贈品與內含物都只能使用參考圖清楚且一致支持的內容。商品外觀、顏色、數量與結構必須忠實；看不清、資料衝突或無法確認就省略，不得猜測。文字使用自然台灣繁體中文，不用中國大陸電商詞。'
    switch ($Slot) {
        'main' { $role = '製作1:1台灣蝦皮封面主圖。商品清楚完整約佔55%到75%，有一個醒目主標題與2到4個可驗證短賣點，背景有層次，手機縮圖可讀。' }
        'detail1' { $role = '製作1:1詳情圖，整理3到5個可確認核心賣點，不與主圖只換背景重複。' }
        'detail2' { $role = '製作1:1拆解或局部放大詳情圖，優先呈現原圖可確認的結構、配件、贈品與內含物；沒有就不得增加。' }
        'detail3' { $role = '製作1:1場景或步驟詳情圖，呈現真實合理的使用動作與操作方式，不做靜態商品海報。' }
        'detail4' { $role = '製作1:1規格或補充資訊圖，優先呈現原圖清楚支持的尺寸與規格；數值、單位或部位不能確認就不畫尺寸圖，改做提醒。' }
        default { $role = '製作1:1補充詳情圖，只呈現可確認內容。' }
    }
    return ('商品名稱僅供辨識：' + $Name + '。' + $role + $common)
}

function Save-ApiReferenceJpegV2([string]$Source, [string]$Target, [int]$MaxEdge) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw ('找不到 API 參考圖：' + $Source) }
    Add-Type -AssemblyName System.Drawing
    $stream=[IO.File]::OpenRead($Source); $sourceImage=$null; $bitmap=$null; $graphics=$null
    try {
        $sourceImage=[Drawing.Image]::FromStream($stream,$true,$true); $largest=[Math]::Max($sourceImage.Width,$sourceImage.Height)
        if ($largest -le 0) { throw 'API 參考圖尺寸異常。' }
        $scale=[Math]::Min(1.0,$MaxEdge/[double]$largest); $width=[Math]::Max(1,[int][Math]::Round($sourceImage.Width*$scale)); $height=[Math]::Max(1,[int][Math]::Round($sourceImage.Height*$scale))
        $bitmap=New-Object Drawing.Bitmap $width,$height; $graphics=[Drawing.Graphics]::FromImage($bitmap); $graphics.Clear([Drawing.Color]::White)
        $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic; $graphics.DrawImage($sourceImage,0,0,$width,$height); $bitmap.Save($Target,[Drawing.Imaging.ImageFormat]::Jpeg)
    } finally { if($null-ne$graphics){$graphics.Dispose()}; if($null-ne$bitmap){$bitmap.Dispose()}; if($null-ne$sourceImage){$sourceImage.Dispose()}; $stream.Dispose() }
    $info=Get-ImageInfoV2 $Target; if($info.length -le 0){throw 'API 參考圖壓縮後為 0KB。'}; return $info
}
function Convert-ToApiReferenceV2([string]$Source,[string]$ProductId) {
    $dir=Join-Path (Get-V2Workspace) ('api_refs\'+$ProductId); New-Item -ItemType Directory -Path $dir -Force|Out-Null; $target=Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($Source)+'.jpg')
    foreach($edge in @(1280,1024,768)){ Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue; $info=Save-ApiReferenceJpegV2 $Source $target $edge; if($info.length -le 1572864){return $target} }; return $target
}
function Get-PreparedApiReferencesV2([string]$ProductId,[string[]]$References) { $prepared=@(); foreach($reference in $References){$prepared+=(Convert-ToApiReferenceV2 ([string]$reference) $ProductId)}; return [string[]]$prepared }
function Test-TransportFailureV2([string]$Message) { if([string]::IsNullOrWhiteSpace($Message)){return $false}; return ($Message -match '发送请求时出错|發送請求時出錯|傳送要求時發生錯誤|HttpRequestException|TaskCanceledException|HTTP 408|HTTP 502|HTTP 503|HTTP 504|HTTP 520|HTTP 522|HTTP 524|timeout|timed out|connection.*(reset|closed|abort)|network|socket|EOF|連線.*(重設|中斷|關閉)|逾時') }
function Test-RetryableV2([string]$Message) { return ((Test-TransportFailureV2 $Message) -or ($Message -match '429|HTTP 5\d\d|暫時|主圖適配檢查未通過|生成圖片與本商品先前成品完全重複')) }

function Write-ProductReportV2($Product, $Checkpoint, [datetime]$Started, [string[]]$Errors) {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $dir = Join-Path $systemRoot 'reports'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $done = @($Checkpoint.states.PSObject.Properties | Where-Object { $_.Value.status -eq 'done' }).Count
    $lines = @()
    $lines += ('商品ID：' + [string]$Product.product_id)
    $lines += ('商品名稱：' + [string]$Product.product_name)
    $lines += ('生成成功數：' + $done)
    foreach ($slot in @('main','detail1','detail2','detail3','detail4')) {
        $lines += ($slot + '：' + [string]$Checkpoint.states.$slot.status)
    }
    $lines += ('總耗時：' + [int]((Get-Date) - $Started).TotalSeconds + ' 秒')
    $lines += ('錯誤：' + ($Errors -join '；'))
    $lines | Set-Content -LiteralPath (Join-Path $dir ([string]$Product.product_id + '_report.txt')) -Encoding UTF8
}

function Start-SingleProductOptimizationV2($Config) {
    if (-not [bool]$Config.safe_test_mode) { throw 'SAFE TEST MODE 必須保持開啟。' }
    $product = Get-SelectedProductV2
    $preflight = Test-SelectedProductImagesV2
    $analysis = $preflight.analysis
    $productId = [string]$product.product_id
    $refCount = @($analysis.reference_order).Count
    if ($refCount -eq 0) { throw '沒有可用原圖，已停止。' }
    $maximum = [Math]::Min(2, [Math]::Min([Math]::Max(1,[int]$Config.max_reference_images), $refCount))

    $finalDir = Get-GeneratedImagesDirectoryV2
    $checkpoint = Get-CheckpointV2 $productId
    $errors = @()
    $generated = 0
    $hashes = @{}
    $acceptedPaths = @()
    $started = Get-Date

    foreach ($slot in @('main','detail1','detail2','detail3','detail4')) {
        $target = Join-Path $finalDir ($productId + '_' + $slot + '.jpg')
        $candidateTarget = $target + '.candidate'
        $state = $checkpoint.states.$slot

        if ($state.status -eq 'done' -and (Test-Path -LiteralPath $target)) {
            try {
                $existing = Get-ImageInfoV2 $target
                $hashes[$existing.hash] = $true
                $acceptedPaths += $target
                continue
            }
            catch { $state.status = 'pending' }
        }

        $labels = @{ main='主圖生成中'; detail1='詳情圖1生成中'; detail2='詳情圖2生成中'; detail3='詳情圖3生成中'; detail4='詳情圖4生成中' }
        $state.status = 'generating'
        Set-CheckpointActivityV2 $checkpoint $labels[$slot] ("正在生成 {0}" -f $slot)
        $basePrompt = Get-PromptV2 $slot ([string]$product.product_name)
        $sourceRefs = [string[]]@(Get-ReferencesForSlotV2 $analysis $slot $maximum)
        $refs = [string[]]@(Get-PreparedApiReferencesV2 $productId $sourceRefs)
        $success = $false

        for ($layoutAttempt = 0; $layoutAttempt -le (Get-MaxLayoutRetriesV2); $layoutAttempt++) {
            $layoutRetryRequired = $false
            $transportDegraded = $false
            $lowQualityRejected = $false

            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $temporary = $null
                $attemptRefs = [string[]]@($refs)
                $attemptQuality = 'medium'
                if ($transportDegraded) {
                    if ($attempt -ge 3) { $attemptRefs = [string[]]@($refs | Select-Object -First 1) }
                    if (-not $lowQualityRejected) { $attemptQuality = 'low' }
                }
                $attemptPrompt = $basePrompt
                if ($transportDegraded) { $attemptPrompt = Get-CompactTransportPromptV2 $slot ([string]$product.product_name) }
                $attemptPrompt += Get-LayoutRetryPromptV2 $slot $layoutAttempt
                if ($slot -eq 'main' -and $attempt -gt 1 -and -not $transportDegraded) {
                    $attemptPrompt += "`n前一次主圖適配檢查未通過。請加大商品主體、加強明確主標題與2到4個可確認的短賣點，避免大片空白，務必做成比詳情圖更鮮明的電商封面。"
                }

                $attemptStarted = Get-Date
                Set-CheckpointActivityV2 $checkpoint $labels[$slot] ("{0} transport 第 {1}/3 次｜layout {2}/{3}｜{4}｜{5} 張壓縮參考圖" -f $slot,$attempt,($layoutAttempt + 1),((Get-MaxLayoutRetriesV2) + 1),$attemptQuality,@($attemptRefs).Count)
                try {
                    Remove-Item -LiteralPath $candidateTarget -Force -ErrorAction SilentlyContinue
                    $temporary = Invoke-ImageEditMultiV2 $Config $attemptRefs $attemptPrompt '1024x1024' $attemptQuality
                    $info = Convert-ToFinalJpegV2 $temporary $candidateTarget
                    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                    $temporary = $null

                    if ($hashes.ContainsKey($info.hash)) { throw '生成圖片與本商品先前成品完全重複。' }
                    if ($slot -eq 'main') { Test-MainImageFitnessV2 $candidateTarget }
                    if ($slot -ne 'main') {
                        $diversity = Test-LayoutDiversityV2 $candidateTarget ([string[]]$acceptedPaths)
                        if ($diversity.high_similarity) {
                            $layoutRetryRequired = $true
                            if ($layoutAttempt -lt (Get-MaxLayoutRetriesV2)) {
                                $state.layout_retries = [int]$state.layout_retries + 1
                            }
                            $state.last_error = ("版型相似度 {0:P1} 高於門檻 {1:P0}，將只重生 {2}" -f $diversity.similarity,(Get-LayoutSimilarityThresholdV2),$slot)
                            Save-CheckpointV2 $checkpoint
                            Remove-Item -LiteralPath $candidateTarget -Force -ErrorAction SilentlyContinue
                            break
                        }
                    }

                    Move-Item -LiteralPath $candidateTarget -Destination $target -Force
                    $hashes[$info.hash] = $true
                    $acceptedPaths += $target
                    $state.status = 'done'
                    $state.last_error = ''
                    $generated++
                    $success = $true
                    Set-CheckpointActivityV2 $checkpoint $labels[$slot] ("{0} 已生成完成" -f $slot)
                    break
                }
                catch {
                    if ($null -ne $temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
                    Remove-Item -LiteralPath $candidateTarget -Force -ErrorAction SilentlyContinue
                    $elapsed = [int]((Get-Date) - $attemptStarted).TotalSeconds
                    $rawError = Protect-SecretTextV2 $_.Exception.Message ([string]$Config.api_key)
                    $isTransport = Test-TransportFailureV2 $rawError
                    $timeoutHint = ''
                    if ($isTransport -and $elapsed -ge 105 -and $elapsed -le 150) { $timeoutHint = '；疑似上游同步約120秒超時' }
                    $state.retries = [int]$state.retries + 1
                    $state.last_error = ($rawError + "（耗時 ${elapsed} 秒${timeoutHint}）")
                    Save-CheckpointV2 $checkpoint
                    if ($isTransport) { $transportDegraded = $true }
                    if ($attemptQuality -eq 'low' -and $rawError -match 'HTTP 400' -and $rawError -match '(quality|low|invalid|unsupported|不支持|不支援)') { $lowQualityRejected = $true }
                    $canRetry = Test-RetryableV2 $rawError
                    if ($lowQualityRejected -and $attempt -lt 3) { $canRetry = $true }
                    if ($attempt -lt 3 -and $canRetry) {
                        if ($isTransport) {
                            $nextMode = if ($attempt -eq 1) { '下一次改用 low 並維持最多2張壓縮參考圖' } else { '下一次降為1張壓縮參考圖' }
                            Set-CheckpointActivityV2 $checkpoint $labels[$slot] ("傳輸失敗，{0}。" -f $nextMode)
                            Start-Sleep -Seconds 3
                        }
                        else { Start-Sleep -Seconds 5 }
                    }
                    else { break }
                }
            }

            if ($success) { break }
            if ($layoutRetryRequired -and $layoutAttempt -lt (Get-MaxLayoutRetriesV2)) {
                Set-CheckpointActivityV2 $checkpoint $labels[$slot] ("{0} 版型過度相似，改用下一種構圖；transport retry 計數保持獨立" -f $slot)
                continue
            }
            if ($layoutRetryRequired) { $state.last_error = '版型重生 2 次後仍高於相似度門檻。' }
            break
        }

        Remove-Item -LiteralPath $candidateTarget -Force -ErrorAction SilentlyContinue
        if (-not $success) {
            $state.status = 'failed'
            $errors += ($slot + '：' + [string]$state.last_error)
            Set-CheckpointActivityV2 $checkpoint '失敗' ("{0} 生成失敗：{1}" -f $slot, $state.last_error)
            break
        }
    }

    Write-ProductReportV2 $product $checkpoint $started ([string[]]$errors)
    $notDone = @($checkpoint.states.PSObject.Properties | Where-Object { $_.Value.status -ne 'done' }).Count
    $allDone = ($notDone -eq 0)
    if ($allDone) {
        Set-CheckpointActivityV2 $checkpoint '成品整理中' '正在確認 5 張成品檔名與輸出位置'
        $checkpoint.finalization_complete = $true
        Set-CheckpointActivityV2 $checkpoint '已完成' '成品整理完成，5 張圖片已直接放入「已生成圖片」'
    }

    return [pscustomobject]@{
        product_id = $productId
        generated_this_run = $generated
        complete = $allDone
        output_folder = $finalDir
        failed_urls = @($preflight.failed_urls)
    }
}
