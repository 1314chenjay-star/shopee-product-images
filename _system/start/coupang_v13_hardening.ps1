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
