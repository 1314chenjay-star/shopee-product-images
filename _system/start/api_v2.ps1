$ErrorActionPreference = 'Stop'

function Get-V2SystemRoot {
    return (Split-Path $PSScriptRoot -Parent)
}

function Get-V2ConfigPath {
    return (Join-Path (Get-V2SystemRoot) 'config\config.json')
}

function Get-DefaultTinySnowConfigV2 {
    return [ordered]@{
        api_key = ''
        base_url = 'https://tinysnow.one/v1'
        model = 'gpt-image-2'
        quality = 'medium'
        size = '1024x1024'
        safe_test_mode = $true
        max_reference_images = 4
        imported_excel = ''
        selected_product_id = ''
    }
}

function Save-TinySnowConfigV2($Config) {
    $path = Get-V2ConfigPath
    $dir = Split-Path $path -Parent
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-TinySnowConfigV2 {
    $path = Get-V2ConfigPath
    if (-not (Test-Path -LiteralPath $path)) {
        $config = [pscustomobject](Get-DefaultTinySnowConfigV2)
        Save-TinySnowConfigV2 $config
        return $config
    }

    try {
        $loaded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $defaults = Get-DefaultTinySnowConfigV2
        foreach ($name in $defaults.Keys) {
            if (-not ($loaded.PSObject.Properties.Name -contains $name)) {
                Add-Member -InputObject $loaded -NotePropertyName $name -NotePropertyValue $defaults[$name]
            }
        }
        return $loaded
    }
    catch {
        throw ('設定檔無法讀取：' + $_.Exception.Message)
    }
}

function Mask-ApiKeyV2([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return '（尚未設定）' }
    if ($Key.Length -le 8) { return ('*' * $Key.Length) }
    return ($Key.Substring(0,4) + ('*' * ($Key.Length - 8)) + $Key.Substring($Key.Length - 4))
}

function Protect-SecretTextV2([string]$Text, [string]$KnownKey = '') {
    if ($null -eq $Text) { return '' }
    $safe = [string]$Text
    $safe = $safe -replace '(?i)Bearer\s+[A-Za-z0-9._-]+', 'Bearer ***'
    $safe = $safe -replace '(?i)sk-[A-Za-z0-9._-]{6,}', 'sk-***'
    if (-not [string]::IsNullOrWhiteSpace($KnownKey)) {
        $safe = $safe.Replace($KnownKey, '***')
    }
    return $safe
}

function Get-TinySnowEndpointV2($Config, [string]$RelativePath) {
    return ($Config.base_url.TrimEnd('/') + '/' + $RelativePath.TrimStart('/'))
}

function Write-TinySnowLogV2(
    [string]$Feature,
    [string]$Endpoint,
    [string]$Summary,
    [bool]$Success,
    [string]$ErrorText = '',
    [string]$OutputPath = ''
) {
    $dir = Join-Path (Get-V2SystemRoot) 'logs'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $day = Get-Date -Format 'yyyy-MM-dd'
    $status = if ($Success) { '成功' } else { '失敗' }
    $entry = "[$stamp] 功能=$Feature | 接口=$Endpoint | 參數=$(Protect-SecretTextV2 $Summary) | 結果=$status | 錯誤=$(Protect-SecretTextV2 $ErrorText) | 輸出=$OutputPath"
    Add-Content -LiteralPath (Join-Path $dir ($day + '.log')) -Value $entry -Encoding UTF8
    if (-not $Success) {
        Add-Content -LiteralPath (Join-Path $dir 'errors.log') -Value $entry -Encoding UTF8
    }
}

function Assert-TinySnowConfigV2($Config) {
    if ([string]::IsNullOrWhiteSpace([string]$Config.api_key)) {
        throw '尚未設定 API Key，請先選主選單 1。'
    }
    $uri = $null
    if (-not [Uri]::TryCreate([string]$Config.base_url, [UriKind]::Absolute, [ref]$uri)) {
        throw 'Base URL 格式錯誤。'
    }
    if ($uri.Scheme -notin @('http','https')) {
        throw 'Base URL 必須以 http:// 或 https:// 開頭。'
    }
}

function Get-TinySnowHeadersV2($Config) {
    return @{ Authorization = ('Bearer ' + [string]$Config.api_key) }
}

function Get-ExceptionChainTextV2($Exception) {
    if ($null -eq $Exception) { return '未知錯誤' }
    $parts = @()
    $current = $Exception
    $depth = 0
    while ($null -ne $current -and $depth -lt 8) {
        $typeName = $current.GetType().FullName
        $message = [string]$current.Message
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $parts += ($typeName + ': ' + $message)
        }
        $current = $current.InnerException
        $depth++
    }
    if ($parts.Count -eq 0) { return [string]$Exception }
    return ($parts -join ' -> ')
}

function Get-HttpErrorTextV2($Exception) {
    if ($null -eq $Exception) { return '未知錯誤' }
    $text = Get-ExceptionChainTextV2 $Exception
    try {
        $prop = $Exception.PSObject.Properties['Response']
        if ($null -ne $prop -and $null -ne $prop.Value) {
            $response = $prop.Value
            $stream = $response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object IO.StreamReader($stream)
                try {
                    $body = $reader.ReadToEnd()
                    if (-not [string]::IsNullOrWhiteSpace($body)) { $text = $body }
                }
                finally { $reader.Dispose() }
            }
        }
    }
    catch {}
    return $text
}

function Test-TinySnowApiV2($Config) {
    Assert-TinySnowConfigV2 $Config
    $endpoint = Get-TinySnowEndpointV2 $Config 'models'
    try {
        Invoke-RestMethod -Uri $endpoint -Method Get -Headers (Get-TinySnowHeadersV2 $Config) -TimeoutSec 30 | Out-Null
        Write-TinySnowLogV2 'API 測試' $endpoint ('model=' + [string]$Config.model) $true
        return [pscustomobject]@{ Success=$true; Message='TinySnow API 連線成功。' }
    }
    catch {
        $errorText = Protect-SecretTextV2 (Get-HttpErrorTextV2 $_.Exception) ([string]$Config.api_key)
        Write-TinySnowLogV2 'API 測試' $endpoint ('model=' + [string]$Config.model) $false $errorText
        return [pscustomobject]@{ Success=$false; Message=('TinySnow API 測試失敗：' + $errorText) }
    }
}

function Save-B64ImageV2($Response, [string]$Prefix) {
    $data = @($Response.data)
    if ($data.Count -lt 1) { throw 'API 回傳沒有 data。' }
    $b64 = [string]$data[0].b64_json
    if ([string]::IsNullOrWhiteSpace($b64)) { throw 'API 回傳沒有 b64_json。' }
    $bytes = [Convert]::FromBase64String($b64)
    $dir = Join-Path (Get-V2SystemRoot) 'output'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir ($Prefix + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '.png')
    [IO.File]::WriteAllBytes($path, $bytes)
    if ((Get-Item -LiteralPath $path).Length -le 0) { throw 'API 圖片輸出為 0KB。' }
    return $path
}

function Invoke-ImageEditMultiV2($Config, [string[]]$ImagePaths, [string]$Prompt, [string]$Size, [string]$Quality) {
    Assert-TinySnowConfigV2 $Config
    if ([string]::IsNullOrWhiteSpace($Prompt)) { throw '提示詞不可空白。' }
    if ($null -eq $ImagePaths -or $ImagePaths.Count -lt 1) { throw '至少需要一張參考圖片。' }

    $maxRefs = [Math]::Max(1, [int]$Config.max_reference_images)
    if ($ImagePaths.Count -gt $maxRefs) { throw ('參考圖片超過上限 ' + $maxRefs + ' 張。') }
    $totalBytes = [long]0
    foreach ($imagePath in $ImagePaths) {
        if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { throw ('找不到參考圖片：' + $imagePath) }
        $totalBytes += [long](Get-Item -LiteralPath $imagePath).Length
    }

    Add-Type -AssemblyName System.Net.Http
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    try { [Net.ServicePointManager]::Expect100Continue = $false } catch {}

    $endpoint = Get-TinySnowEndpointV2 $Config 'images/edits'
    $client = $null
    $form = $null
    $streams = @()

    try {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(10)
        $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue -ArgumentList 'Bearer', ([string]$Config.api_key)
        $client.DefaultRequestHeaders.ExpectContinue = $false
        $form = New-Object System.Net.Http.MultipartFormDataContent

        $fields = @{
            model = [string]$Config.model
            prompt = $Prompt
            size = $Size
            quality = $Quality
            n = '1'
            response_format = 'b64_json'
        }
        foreach ($name in $fields.Keys) {
            $content = New-Object System.Net.Http.StringContent -ArgumentList ([string]$fields[$name]), ([Text.Encoding]::UTF8)
            $form.Add($content, $name)
        }

        foreach ($imagePath in $ImagePaths) {
            $resolved = (Resolve-Path -LiteralPath $imagePath).Path
            $stream = [IO.File]::OpenRead($resolved)
            $streams += $stream
            $fileContent = New-Object System.Net.Http.StreamContent -ArgumentList $stream
            $extension = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
            $mime = switch ($extension) {
                '.jpg' { 'image/jpeg' }
                '.jpeg' { 'image/jpeg' }
                '.webp' { 'image/webp' }
                default { 'image/png' }
            }
            $fileContent.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue -ArgumentList $mime
            $form.Add($fileContent, 'image[]', (Split-Path $resolved -Leaf))
        }

        $summary = ('images=' + $ImagePaths.Count + '; input_bytes=' + $totalBytes + '; size=' + $Size + '; quality=' + $Quality)
        $response = $client.PostAsync($endpoint, $form).GetAwaiter().GetResult()
        $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ('HTTP ' + [int]$response.StatusCode + ': ' + $raw)
        }
        $json = $raw | ConvertFrom-Json
        $path = Save-B64ImageV2 $json 'edit'
        Write-TinySnowLogV2 '圖生圖' $endpoint $summary $true '' $path
        return $path
    }
    catch {
        $message = Protect-SecretTextV2 (Get-HttpErrorTextV2 $_.Exception) ([string]$Config.api_key)
        $summary = ('images=' + $ImagePaths.Count + '; input_bytes=' + $totalBytes + '; size=' + $Size + '; quality=' + $Quality)
        Write-TinySnowLogV2 '圖生圖' $endpoint $summary $false $message
        throw ('圖生圖失敗：' + $message)
    }
    finally {
        if ($null -ne $form) { $form.Dispose() }
        foreach ($stream in $streams) {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        if ($null -ne $client) { $client.Dispose() }
    }
}
