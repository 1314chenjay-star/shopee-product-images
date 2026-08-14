Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Get-ProjectRoot { Split-Path $PSScriptRoot -Parent }

function Get-ConfigPath { Join-Path (Get-ProjectRoot) 'config\config.json' }

function Get-DefaultConfig {
    [ordered]@{ api_key=''; base_url='https://tinysnow.one/v1'; model='gpt-image-2'; quality='medium'; size='1024x1024'; output_folder='output'; safe_test_mode=$true; max_reference_images=4; imported_excel=''; selected_product_id='' }
}

function Save-TinySnowConfig($Config) {
    $path = Get-ConfigPath
    $Config | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}

function Get-TinySnowConfig {
    $path = Get-ConfigPath
    if (-not (Test-Path -LiteralPath $path)) { $c=Get-DefaultConfig; Save-TinySnowConfig $c; return [pscustomobject]$c }
    try {
        $loaded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $defaults = Get-DefaultConfig
        foreach ($name in $defaults.Keys) {
            if (-not ($loaded.PSObject.Properties.Name -contains $name)) { Add-Member -InputObject $loaded -NotePropertyName $name -NotePropertyValue $defaults[$name] }
        }
        return $loaded
    } catch { throw "設定檔無法讀取，請刪除 config\config.json 後重試。原因：$($_.Exception.Message)" }
}

function Mask-ApiKey([string]$Key) {
    if ([string]::IsNullOrWhiteSpace($Key)) { return '（尚未設定）' }
    if ($Key.Length -le 8) { return ('*' * $Key.Length) }
    return $Key.Substring(0,4) + ('*' * ($Key.Length-8)) + $Key.Substring($Key.Length-4)
}
function Protect-SecretText([string]$Text,[string]$KnownKey=''){
    if($null-eq$Text){return''};$safe=$Text -replace '(?i)Bearer\s+[A-Za-z0-9._-]+','Bearer ***' -replace '(?i)sk-[A-Za-z0-9._-]{6,}','sk-***'
    if(-not[string]::IsNullOrWhiteSpace($KnownKey)){$safe=$safe.Replace($KnownKey,'***')};return$safe
}

function Get-Endpoint($Config, [string]$Path) { $Config.base_url.TrimEnd('/') + '/' + $Path.TrimStart('/') }

function Write-TinySnowLog([string]$Feature,[string]$Endpoint,[string]$Summary,[bool]$Success,[string]$ErrorText='', [string]$OutputPath='') {
    $root=Get-ProjectRoot; $dir=Join-Path $root 'logs'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $stamp=Get-Date -Format 'yyyy-MM-dd HH:mm:ss'; $day=Get-Date -Format 'yyyy-MM-dd'
    $status=if($Success){'成功'}else{'失敗'}
    $ErrorText=Protect-SecretText $ErrorText;$Summary=Protect-SecretText $Summary
    $entry="[$stamp] 功能=$Feature | 接口=$Endpoint | 參數=$Summary | 結果=$status | 錯誤=$ErrorText | 輸出=$OutputPath"
    Add-Content -LiteralPath (Join-Path $dir "$day.log") -Value $entry -Encoding UTF8
    $featureFile = switch ($Feature) { 'API 測試' {'api-tests.log'} '文生圖' {'text-to-image.log'} '圖生圖' {'image-edits.log'} default {'application.log'} }
    Add-Content -LiteralPath (Join-Path $dir $featureFile) -Value $entry -Encoding UTF8
    if(-not $Success){ Add-Content -LiteralPath (Join-Path $dir 'errors.log') -Value $entry -Encoding UTF8 }
}

function Assert-Config($Config) {
    if([string]::IsNullOrWhiteSpace($Config.api_key)){ throw '尚未設定 API Key，請先選主選單 1。' }
    $uri=$null; if(-not [Uri]::TryCreate($Config.base_url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https')){ throw 'Base URL 格式錯誤，必須以 https:// 或 http:// 開頭。' }
}

function Get-HttpErrorDetail($Exception) {
    $status='無'; $body=$Exception.Message
    if($Exception.Response){
        try { $status=[int]$Exception.Response.StatusCode } catch {}
        try { $reader=New-Object IO.StreamReader($Exception.Response.GetResponseStream()); $read=$reader.ReadToEnd(); if($read){$body=$read} } catch {}
    }
    [pscustomobject]@{ Status=$status; Body=$body }
}

function Get-FriendlyHint($Status,[string]$Body) {
    if($Status -in @(401,403)){ return '請檢查 API Key、帳務狀態，以及模型權限是否已開通。' }
    if($Status -eq 404){ return '請檢查 Base URL；預設值應為 https://tinysnow.one/v1。' }
    if($Status -eq 400){ return '請檢查模型、size、quality 與 response_format；文生圖必須是 b64_json。' }
    if($Status -eq 429){ return '請檢查額度或帳務，或稍後再試。' }
    return '請檢查網路連線、Base URL、API Key、帳務及模型權限。'
}

function Get-Headers($Config) { @{ Authorization="Bearer $($Config.api_key)" } }

function Test-TinySnowApi($Config) {
    Assert-Config $Config; $endpoint=Get-Endpoint $Config 'models'; $summary="model=$($Config.model); key=$(Mask-ApiKey $Config.api_key)"
    try {
        Invoke-RestMethod -Uri $endpoint -Method Get -Headers (Get-Headers $Config) -TimeoutSec 30 | Out-Null
        Write-TinySnowLog 'API 測試' $endpoint $summary $true
        return [pscustomobject]@{Success=$true; Message='TinySnow API 連線成功，金鑰可用。'}
    } catch {
        $d=Get-HttpErrorDetail $_.Exception; $hint=Get-FriendlyHint $d.Status $d.Body
        Write-TinySnowLog 'API 測試' $endpoint $summary $false "$($d.Body)；$hint"
        return [pscustomobject]@{Success=$false; Message="連線失敗`nHTTP 狀態碼：$($d.Status)`n回傳內容：$($d.Body)`n常見原因提示：$hint"}
    }
}

function Save-B64Image($Response,[string]$Prefix,$Config) {
    if(-not $Response -or -not $Response.data -or $Response.data.Count -lt 1 -or [string]::IsNullOrWhiteSpace($Response.data[0].b64_json)){ throw '回傳格式異常：找不到 data[0].b64_json。' }
    try { $bytes=[Convert]::FromBase64String($Response.data[0].b64_json) } catch { throw "b64_json 不是有效的 Base64：$($_.Exception.Message)" }
    $folder=[string]$Config.output_folder; if(-not [IO.Path]::IsPathRooted($folder)){$folder=Join-Path (Get-ProjectRoot) $folder}
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $path=Join-Path $folder ("{0}_{1}.png" -f $Prefix,(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    try {
        Add-Type -AssemblyName System.Drawing
        $stream=New-Object IO.MemoryStream(,$bytes); $image=[Drawing.Image]::FromStream($stream,$true,$true)
        $image.Save($path,[Drawing.Imaging.ImageFormat]::Png); $image.Dispose(); $stream.Dispose()
        if((Get-Item -LiteralPath $path).Length -eq 0){throw '圖片檔案大小為 0。'}
        return $path
    } catch { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; throw "圖片解碼或轉存 PNG 失敗：$($_.Exception.Message)" }
}

function Invoke-TextToImage($Config,[string]$Prompt,[string]$Size,[string]$Quality) {
    Assert-Config $Config; if([string]::IsNullOrWhiteSpace($Prompt)){throw '提示詞不可空白。'}
    $endpoint=Get-Endpoint $Config 'images/generations'; $summary="model=$($Config.model); size=$Size; quality=$Quality; response_format=b64_json; prompt_length=$($Prompt.Length); key=$(Mask-ApiKey $Config.api_key)"
    try {
        $body=@{model=$Config.model;prompt=$Prompt;size=$Size;quality=$Quality;response_format='b64_json'}|ConvertTo-Json
        $response=Invoke-RestMethod -Uri $endpoint -Method Post -Headers (Get-Headers $Config) -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 600
        $path=Save-B64Image $response 'text' $Config; Write-TinySnowLog '文生圖' $endpoint $summary $true '' $path; return $path
    } catch { $d=Get-HttpErrorDetail $_.Exception; $hint=Get-FriendlyHint $d.Status $d.Body; Write-TinySnowLog '文生圖' $endpoint $summary $false "$($d.Body)；$hint"; throw "文生圖失敗。HTTP：$($d.Status)`n$($d.Body)`n提示：$hint" }
}

function Invoke-ImageEdit($Config,[string]$ImagePath,[string]$Prompt,[string]$Size,[string]$Quality) {
    Invoke-ImageEditMulti $Config @($ImagePath) $Prompt $Size $Quality
}

function Invoke-ImageEditMulti($Config,[string[]]$ImagePaths,[string]$Prompt,[string]$Size,[string]$Quality) {
    Assert-Config $Config; if([string]::IsNullOrWhiteSpace($Prompt)){throw '提示詞不可空白。'}
    if(-not $ImagePaths -or $ImagePaths.Count -lt 1){throw '至少需要一張參考圖片。'}
    $maximum=[Math]::Max(1,[int]$Config.max_reference_images); if($ImagePaths.Count -gt $maximum){throw "參考圖片超過設定上限 $maximum 張。"}
    foreach($sourcePath in $ImagePaths){if(-not(Test-Path -LiteralPath $sourcePath -PathType Leaf)){throw "找不到輸入圖片：$sourcePath"}}
    $endpoint=Get-Endpoint $Config 'images/edits'; $summary="model=$($Config.model); size=$Size; quality=$Quality; images=$($ImagePaths.Count); prompt_length=$($Prompt.Length); key=$(Mask-ApiKey $Config.api_key)"
    $client=$null;$form=$null;$streams=New-Object Collections.Generic.List[IDisposable]
    try {
        Add-Type -AssemblyName System.Net.Http; $client=New-Object Net.Http.HttpClient; $client.Timeout=[TimeSpan]::FromMinutes(10); $client.DefaultRequestHeaders.Authorization=New-Object Net.Http.Headers.AuthenticationHeaderValue('Bearer',$Config.api_key)
        $form=New-Object Net.Http.MultipartFormDataContent
        foreach($pair in @(@('model',[string]$Config.model),@('prompt',$Prompt),@('quality',$Quality),@('size',$Size))){$form.Add((New-Object Net.Http.StringContent($pair[1],[Text.Encoding]::UTF8)),$pair[0])}
        foreach($sourcePath in $ImagePaths){
            $fileStream=[IO.File]::OpenRead((Resolve-Path -LiteralPath $sourcePath));$streams.Add($fileStream)
            $file=New-Object Net.Http.StreamContent($fileStream);$file.Headers.ContentType=New-Object Net.Http.Headers.MediaTypeHeaderValue('application/octet-stream');$form.Add($file,'image[]',(Split-Path $sourcePath -Leaf))
        }
        $http=$client.PostAsync($endpoint,$form).GetAwaiter().GetResult(); $raw=$http.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if(-not $http.IsSuccessStatusCode){ throw "HTTP $([int]$http.StatusCode)：$raw" }
        $response=$raw|ConvertFrom-Json; $path=Save-B64Image $response 'edit' $Config; Write-TinySnowLog '圖生圖' $endpoint $summary $true '' $path; return $path
    } catch { $message=$_.Exception.Message; Write-TinySnowLog '圖生圖' $endpoint $summary $false $message; throw "圖生圖失敗：$message`n提示：請檢查圖片格式、API Key、Base URL、帳務與模型權限。" }
    finally { if($form){$form.Dispose()};foreach($item in $streams){$item.Dispose()};if($client){$client.Dispose()} }
}

Export-ModuleMember -Function Get-TinySnowConfig,Save-TinySnowConfig,Get-DefaultConfig,Get-Endpoint,Write-TinySnowLog,Mask-ApiKey,Protect-SecretText,Test-TinySnowApi,Invoke-TextToImage,Invoke-ImageEdit,Invoke-ImageEditMulti,Get-ProjectRoot
