$ErrorActionPreference = 'Stop'

function Get-CoupangWorkspaceV1 {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $path = Join-Path $systemRoot 'workspace\coupang'
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-CoupangBrowserExecutableV1 {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -eq 0) {
        throw '找不到 Microsoft Edge 或 Google Chrome。請先確認 Windows 已安裝其中一個瀏覽器。'
    }
    return $candidates[0]
}

function Wait-CoupangCdpV1([int]$Port = 9333, [int]$TimeoutSeconds = 15) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $version = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/version" -f $Port) -UseBasicParsing -TimeoutSec 2
            if ($version.webSocketDebuggerUrl) { return $true }
        }
        catch {}
        Start-Sleep -Milliseconds 350
    } while ((Get-Date) -lt $deadline)
    return $false
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
        'https://wing.coupang.com/'
    )

    Start-Process -FilePath $browser -ArgumentList $args | Out-Null
    if (-not (Wait-CoupangCdpV1 -TimeoutSeconds 20)) {
        throw '瀏覽器已啟動，但 TinySnow 無法連接本機瀏覽器控制埠 9333。請關閉剛開啟的專用瀏覽器後重試。'
    }

    Write-Host ''
    Write-Host '已開啟 TinySnow Coupang 專用瀏覽器。' -ForegroundColor Green
    Write-Host '第一次使用請在瀏覽器內自行登入 WING；TinySnow 不讀取、不保存你的帳號密碼。' -ForegroundColor Cyan
    Write-Host '登入狀態只保存在你電腦的 _system\workspace\coupang\browser_profile。' -ForegroundColor DarkGray
}

function Get-CoupangTargetsV1([int]$Port = 9333) {
    if (-not (Wait-CoupangCdpV1 -Port $Port -TimeoutSeconds 2)) {
        throw 'TinySnow Coupang 專用瀏覽器尚未啟動。請先選「開啟 WING 專用瀏覽器」。'
    }
    $targets = @(Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/list" -f $Port) -UseBasicParsing -TimeoutSec 5)
    return @($targets | Where-Object {
        $_.type -eq 'page' -and $_.webSocketDebuggerUrl -and (
            $_.url -match '(?i)coupang\.com' -or
            $_.url -match '(?i)coupangcdn\.com'
        )
    })
}

function Invoke-CdpCommandV1 {
    param(
        [Parameter(Mandatory=$true)][string]$WebSocketUrl,
        [Parameter(Mandatory=$true)][string]$Method,
        [hashtable]$Params = @{}
    )

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $token = [Threading.CancellationToken]::None
    $uri = [Uri]$WebSocketUrl
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

function Get-CoupangPageSnapshotV1([object]$Target) {
    $script = @'
(() => {
  const normalize = (s) => (s || '').replace(/\r/g, '').trim();
  const tables = Array.from(document.querySelectorAll('table')).map((table, i) => ({
    index: i,
    text: normalize(table.innerText),
    rows: Array.from(table.querySelectorAll('tr')).map(tr =>
      Array.from(tr.querySelectorAll('th,td')).map(cell => normalize(cell.innerText))
    )
  }));
  const ariaTables = Array.from(document.querySelectorAll('[role="grid"], [role="table"]')).map((el, i) => ({
    index: i,
    role: el.getAttribute('role'),
    text: normalize(el.innerText)
  }));
  const resources = Array.from(new Set(performance.getEntriesByType('resource').map(x => x.name)))
    .filter(x => /coupang/i.test(x));
  return {
    capturedAt: new Date().toISOString(),
    title: document.title,
    url: location.href,
    bodyText: normalize(document.body ? document.body.innerText : ''),
    tables,
    ariaTables,
    resources
  };
})()
'@

    $result = Invoke-CdpCommandV1 -WebSocketUrl $Target.webSocketDebuggerUrl -Method 'Runtime.evaluate' -Params @{
        expression = $script
        returnByValue = $true
        awaitPromise = $true
    }
    if (-not $result.result.value) { throw '無法讀取目前 WING 頁面內容。' }
    return $result.result.value
}

function Save-CoupangSnapshotsV1 {
    $targets = @(Get-CoupangTargetsV1)
    if ($targets.Count -eq 0) {
        throw '目前沒有開啟任何 Coupang 頁面。請先在專用瀏覽器內打開 WING 商品／訂單／數據頁面。'
    }

    $workspace = Get-CoupangWorkspaceV1
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $captureDir = Join-Path $workspace ("captures\{0}" -f $stamp)
    New-Item -ItemType Directory -Path $captureDir -Force | Out-Null

    $index = @()
    $number = 0
    foreach ($target in $targets) {
        $number++
        try {
            $snapshot = Get-CoupangPageSnapshotV1 $target
            $safeTitle = [regex]::Replace(([string]$snapshot.title), '[\\/:*?"<>|\s]+', '_').Trim('_')
            if (-not $safeTitle) { $safeTitle = 'page' }
            if ($safeTitle.Length -gt 50) { $safeTitle = $safeTitle.Substring(0, 50) }
            $base = ('{0:D2}_{1}' -f $number, $safeTitle)
            $jsonPath = Join-Path $captureDir ($base + '.json')
            $txtPath = Join-Path $captureDir ($base + '.txt')

            $snapshot | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
            [string]$snapshot.bodyText | Set-Content -LiteralPath $txtPath -Encoding UTF8

            $index += [pscustomobject]@{
                title = [string]$snapshot.title
                url = [string]$snapshot.url
                json = [IO.Path]::GetFileName($jsonPath)
                text = [IO.Path]::GetFileName($txtPath)
                table_count = @($snapshot.tables).Count
                resource_count = @($snapshot.resources).Count
            }
        }
        catch {
            $index += [pscustomobject]@{
                title = [string]$target.title
                url = [string]$target.url
                error = $_.Exception.Message
            }
        }
    }

    $index | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $captureDir 'index.json') -Encoding UTF8
    @(
        'TinySnow Coupang 本地採集 V1',
        ('採集時間：{0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
        ('頁面數：{0}' -f $targets.Count),
        '',
        '安全說明：本模組不讀取密碼、不導出 Cookie、不修改 Coupang Open API。',
        '目前 V1 用於建立 WING 頁面／表格／內部資源端點地圖，供下一階段自動化商品、訂單與營運報表採集。'
    ) | Set-Content -LiteralPath (Join-Path $captureDir 'README.txt') -Encoding UTF8

    Write-Host ("採集完成：{0}" -f $captureDir) -ForegroundColor Green
    return $captureDir
}

function Export-CoupangCaptureBundleV1 {
    $workspace = Get-CoupangWorkspaceV1
    $captureRoot = Join-Path $workspace 'captures'
    if (-not (Test-Path $captureRoot)) { throw '目前還沒有採集資料。' }
    $items = @(Get-ChildItem -LiteralPath $captureRoot -Directory | Sort-Object LastWriteTime -Descending)
    if ($items.Count -eq 0) { throw '目前還沒有採集資料。' }

    $latest = $items[0]
    $bundleDir = Join-Path $workspace 'bundles'
    New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
    $zip = Join-Path $bundleDir ("Coupang_capture_{0}.zip" -f $latest.Name)
    if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $latest.FullName '*') -DestinationPath $zip -CompressionLevel Optimal
    Write-Host ("已建立採集包：{0}" -f $zip) -ForegroundColor Green
    return $zip
}

function Open-CoupangWorkspaceV1 {
    $workspace = Get-CoupangWorkspaceV1
    Start-Process explorer.exe $workspace
}

function Show-CoupangCollectorMenuV1 {
    while ($true) {
        Clear-Host
        Write-Host '=================================' -ForegroundColor Cyan
        Write-Host 'TinySnow｜Coupang 本地數據採集 V1'
        Write-Host '不修改 Open API｜不保存密碼｜資料只留在本機' -ForegroundColor Green
        Write-Host '=================================' -ForegroundColor Cyan
        Write-Host '1. 開啟 WING 專用瀏覽器（第一次手動登入）'
        Write-Host '2. 採集目前已開啟的 Coupang 頁面'
        Write-Host '3. 打包最新採集資料（ZIP）'
        Write-Host '4. 打開 Coupang 本地資料夾'
        Write-Host '0. 回主選單'
        Write-Host '================================='
        $choice = Read-Host '請輸入編號'

        try {
            switch ($choice) {
                '1' {
                    Start-CoupangBrowserV1
                    Write-Host ''
                    Read-Host '完成後按 Enter' | Out-Null
                }
                '2' {
                    Save-CoupangSnapshotsV1 | Out-Null
                    Write-Host ''
                    Write-Host '提示：把商品管理、訂單管理、銷售／數據分析頁都打開後再採集，資料會更完整。' -ForegroundColor Cyan
                    Read-Host '按 Enter' | Out-Null
                }
                '3' {
                    Export-CoupangCaptureBundleV1 | Out-Null
                    Write-Host ''
                    Read-Host '按 Enter' | Out-Null
                }
                '4' { Open-CoupangWorkspaceV1 }
                '0' { return }
                default {
                    Write-Host '沒有這個選項。' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
            }
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            Write-Host ''
            Read-Host '按 Enter' | Out-Null
        }
    }
}
