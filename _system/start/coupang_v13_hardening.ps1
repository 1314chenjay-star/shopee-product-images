$ErrorActionPreference = 'Stop'

# V1.3 overrides browser discovery and CDP input handling from earlier builds.
# Important PowerShell detail: when a pipeline returns exactly one string,
# indexing [0] can otherwise return only the first character of that string.
# Wrapping pipeline results in @() guarantees a real array of paths.

function Get-CoupangBrowserExecutableV1 {
    $candidates = @(
        @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    )

    if ($candidates.Count -eq 0) {
        throw '找不到 Microsoft Edge 或 Google Chrome。請先確認 Windows 已安裝其中一個瀏覽器。'
    }

    $resolved = [string]$candidates[0]
    if (-not $resolved -or -not (Test-Path -LiteralPath $resolved)) {
        throw '瀏覽器路徑偵測失敗。'
    }
    return $resolved
}

function Get-CoupangInstalledBrowsersV2 {
    $items = @()

    $edgeUserData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    $edgeExeCandidates = @(
        @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    )
    if ((Test-Path -LiteralPath $edgeUserData) -and $edgeExeCandidates.Count -gt 0) {
        $items += [pscustomobject]@{
            Browser = 'Edge'
            ProcessName = 'msedge'
            Executable = [string]$edgeExeCandidates[0]
            UserData = $edgeUserData
        }
    }

    $chromeUserData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    $chromeExeCandidates = @(
        @(
            (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
    )
    if ((Test-Path -LiteralPath $chromeUserData) -and $chromeExeCandidates.Count -gt 0) {
        $items += [pscustomobject]@{
            Browser = 'Chrome'
            ProcessName = 'chrome'
            Executable = [string]$chromeExeCandidates[0]
            UserData = $chromeUserData
        }
    }

    return @($items)
}

function Resolve-CoupangBrowserExecutableV3([object]$Meta) {
    if ($Meta -and $Meta.executable) {
        $saved = [string]$Meta.executable
        if ($saved -and (Test-Path -LiteralPath $saved)) { return $saved }
    }

    $preferredBrowser = ''
    if ($Meta -and $Meta.browser) { $preferredBrowser = [string]$Meta.browser }
    $installed = @(Get-CoupangInstalledBrowsersV2)

    if ($preferredBrowser) {
        $match = @($installed | Where-Object { $_.Browser -eq $preferredBrowser })
        if ($match.Count -gt 0) {
            $candidate = [string]$match[0].Executable
            if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
        }
    }

    foreach ($browser in $installed) {
        $candidate = [string]$browser.Executable
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    $fallback = Get-CoupangBrowserExecutableV1
    if ($fallback -and (Test-Path -LiteralPath ([string]$fallback))) {
        return [string]$fallback
    }

    throw '找不到可用的 Microsoft Edge 或 Google Chrome。請確認瀏覽器仍安裝在這台電腦。'
}

function Invoke-CdpCommandV1 {
    param(
        [Parameter(Mandatory=$true)][object]$WebSocketUrl,
        [Parameter(Mandatory=$true)][string]$Method,
        [hashtable]$Params = @{}
    )

    $wsCandidates = @($WebSocketUrl)
    if ($wsCandidates.Count -eq 0) { throw '缺少瀏覽器 WebSocket 控制網址。' }
    $wsText = [string]$wsCandidates[0]
    if (-not $wsText -or $wsText -notmatch '^wss?://') {
        throw '瀏覽器 WebSocket 控制網址格式無效。'
    }

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $token = [Threading.CancellationToken]::None
    $uri = [Uri]$wsText
    $ws.ConnectAsync($uri, $token).GetAwaiter().GetResult()

    try {
        $id = Get-Random -Minimum 1000 -Maximum 999999
        $payload = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 30 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $sendSegment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$bytes)
        $ws.SendAsync($sendSegment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $token).GetAwaiter().GetResult()

        while ($true) {
            $buffer = New-Object byte[] 65536
            $stream = New-Object IO.MemoryStream
            do {
                $receiveSegment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buffer)
                $result = $ws.ReceiveAsync($receiveSegment, $token).GetAwaiter().GetResult()
                if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                    throw '瀏覽器控制連線被關閉。'
                }
                $stream.Write($buffer, 0, $result.Count)
            } while (-not $result.EndOfMessage)

            $text = [Text.Encoding]::UTF8.GetString($stream.ToArray())
            $message = $text | ConvertFrom-Json
            if ($message.id -eq $id) {
                if ($message.error) { throw ("CDP 錯誤：{0}" -f ($message.error | ConvertTo-Json -Compress)) }
                return $message.result
            }
        }
    }
    finally {
        try {
            if ($ws.State -eq [Net.WebSockets.WebSocketState]::Open) {
                $ws.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', $token).GetAwaiter().GetResult()
            }
        }
        catch {}
        $ws.Dispose()
    }
}

function Get-CoupangStartUrlV4 {
    return 'https://wing.coupang.com/tenants/sfl-portal/delivery/management'
}

function Start-CoupangBrowserV1 {
    $workspace = Get-CoupangWorkspaceV1
    $profile = Join-Path $workspace 'browser_profile'
    New-Item -ItemType Directory -Path $profile -Force | Out-Null

    if (Wait-CoupangCdpV1 -TimeoutSeconds 1) {
        Write-Host 'TinySnow Coupang 專用瀏覽器已經在執行。' -ForegroundColor Green
        return
    }

    $browser = Get-CoupangBrowserExecutableV1
    $args = @(
        '--remote-debugging-port=9333',
        ('--user-data-dir="{0}"' -f $profile),
        '--no-first-run',
        '--new-window',
        (Get-CoupangStartUrlV4)
    )

    Start-Process -FilePath $browser -ArgumentList $args | Out-Null
    if (-not (Wait-CoupangCdpV1 -TimeoutSeconds 20)) {
        throw '瀏覽器已啟動，但 TinySnow 無法連接本機瀏覽器控制埠 9333。請關閉剛開啟的專用瀏覽器後重試。'
    }

    Write-Host ''
    Write-Host '已直接開啟 Coupang 配送管理後台。' -ForegroundColor Green
    Write-Host '第一次使用若被要求登入，請在瀏覽器內自行完成驗證；TinySnow 不讀取、不保存你的帳號密碼。' -ForegroundColor Cyan
}

function Start-CoupangImportedProfileV2 {
    $workspace = Get-CoupangWorkspaceV1
    $cloneRoot = Join-Path $workspace 'browser_profile_existing'
    $meta = Get-CoupangImportedProfileMetaV2
    if (-not $meta) { throw '尚未匯入現有瀏覽器登入狀態。請先選「使用目前 Edge/Chrome 已登入狀態」。' }

    $executable = Resolve-CoupangBrowserExecutableV3 $meta

    $metaPath = Join-Path $cloneRoot 'TinySnow_profile.json'
    if ([string]$meta.executable -ne $executable) {
        $meta.executable = $executable
        $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metaPath -Encoding UTF8
        Write-Host '已自動修復瀏覽器程式位置。' -ForegroundColor Cyan
    }

    if (Wait-CoupangCdpV1 -TimeoutSeconds 1) {
        Write-Host 'TinySnow Coupang 瀏覽器已經在執行。' -ForegroundColor Green
        return
    }

    $args = @(
        '--remote-debugging-port=9333',
        ('--user-data-dir="{0}"' -f $cloneRoot),
        ('--profile-directory="{0}"' -f [string]$meta.profile_directory),
        '--no-first-run',
        '--new-window',
        (Get-CoupangStartUrlV4)
    )
    Start-Process -FilePath $executable -ArgumentList $args | Out-Null

    if (-not (Wait-CoupangCdpV1 -TimeoutSeconds 20)) {
        throw '已啟動瀏覽器，但 TinySnow 無法連接本機控制埠 9333。'
    }

    Write-Host ''
    Write-Host '已使用你原本的登入狀態直接開啟 Coupang 配送管理後台。' -ForegroundColor Green
    Write-Host '如果 Coupang 仍要求登入，代表該登入工作階段已過期或瀏覽器安全機制不允許複製；TinySnow 不會繞過驗證。' -ForegroundColor Yellow
}
