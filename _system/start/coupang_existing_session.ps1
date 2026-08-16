$ErrorActionPreference = 'Stop'

function Get-CoupangInstalledBrowsersV2 {
    $items = @()

    $edgeUserData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'
    $edgeExeCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ((Test-Path $edgeUserData) -and $edgeExeCandidates.Count -gt 0) {
        $items += [pscustomobject]@{
            Browser = 'Edge'
            ProcessName = 'msedge'
            Executable = $edgeExeCandidates[0]
            UserData = $edgeUserData
        }
    }

    $chromeUserData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'
    $chromeExeCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }
    if ((Test-Path $chromeUserData) -and $chromeExeCandidates.Count -gt 0) {
        $items += [pscustomobject]@{
            Browser = 'Chrome'
            ProcessName = 'chrome'
            Executable = $chromeExeCandidates[0]
            UserData = $chromeUserData
        }
    }

    return @($items)
}

function Get-CoupangProfileDisplayNameV2([string]$ProfilePath, [string]$Fallback) {
    $prefs = Join-Path $ProfilePath 'Preferences'
    if (Test-Path $prefs) {
        try {
            $json = Get-Content -LiteralPath $prefs -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.profile -and $json.profile.name) { return [string]$json.profile.name }
        }
        catch {}
    }
    return $Fallback
}

function Get-CoupangExistingProfilesV2 {
    $rows = @()
    foreach ($browser in @(Get-CoupangInstalledBrowsersV2)) {
        $dirs = @(Get-ChildItem -LiteralPath $browser.UserData -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -eq 'Default' -or $_.Name -match '^Profile \d+$'
        } | Sort-Object LastWriteTime -Descending)

        foreach ($dir in $dirs) {
            $rows += [pscustomobject]@{
                Browser = $browser.Browser
                ProcessName = $browser.ProcessName
                Executable = $browser.Executable
                UserData = $browser.UserData
                ProfileDirectory = $dir.Name
                ProfileName = Get-CoupangProfileDisplayNameV2 $dir.FullName $dir.Name
                LastWriteTime = $dir.LastWriteTime
            }
        }
    }
    return @($rows | Sort-Object LastWriteTime -Descending)
}

function Stop-CoupangSourceBrowserV2([string]$ProcessName) {
    $running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) { return }

    Write-Host ''
    Write-Host '為了完整複製你目前已登入的瀏覽器狀態，請先把原本的瀏覽器視窗全部關閉。' -ForegroundColor Yellow
    Read-Host '關閉後按 Enter 繼續' | Out-Null
    Start-Sleep -Seconds 1

    $running = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host ''
        Write-Host '瀏覽器仍有背景程序在執行（常見於 Edge Startup Boost）。' -ForegroundColor Yellow
        $confirm = Read-Host '輸入 1 讓 TinySnow 關閉這些背景程序；其他鍵取消'
        if ($confirm -ne '1') { throw '已取消。請完全關閉瀏覽器後再試一次。' }
        $running | Stop-Process -Force
        Start-Sleep -Seconds 1
    }
}

function Copy-CoupangBrowserProfileV2([object]$Profile) {
    $workspace = Get-CoupangWorkspaceV1
    $cloneRoot = Join-Path $workspace 'browser_profile_existing'

    Stop-CoupangSourceBrowserV2 $Profile.ProcessName

    if (Test-Path $cloneRoot) {
        Remove-Item -LiteralPath $cloneRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $cloneRoot -Force | Out-Null

    $sourceLocalState = Join-Path $Profile.UserData 'Local State'
    if (Test-Path $sourceLocalState) {
        Copy-Item -LiteralPath $sourceLocalState -Destination (Join-Path $cloneRoot 'Local State') -Force
    }

    $sourceProfile = Join-Path $Profile.UserData $Profile.ProfileDirectory
    $destProfile = Join-Path $cloneRoot $Profile.ProfileDirectory
    New-Item -ItemType Directory -Path $destProfile -Force | Out-Null

    $arguments = @(
        ('"{0}"' -f $sourceProfile),
        ('"{0}"' -f $destProfile),
        '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP',
        '/XD', 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'GrShaderCache', 'ShaderCache', 'Crashpad'
    )
    $process = Start-Process -FilePath 'robocopy.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -gt 7) {
        throw ("複製瀏覽器 Profile 失敗，robocopy 代碼：{0}" -f $process.ExitCode)
    }

    $meta = [pscustomobject]@{
        browser = $Profile.Browser
        executable = $Profile.Executable
        profile_directory = $Profile.ProfileDirectory
        profile_name = $Profile.ProfileName
        imported_at = (Get-Date).ToString('o')
    }
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $cloneRoot 'TinySnow_profile.json') -Encoding UTF8

    Write-Host ''
    Write-Host ("已複製：{0}｜{1}" -f $Profile.Browser, $Profile.ProfileName) -ForegroundColor Green
    Write-Host '登入資料只複製到 TinySnow 本機資料夾，不會上傳到 GitHub 或傳給 ChatGPT。' -ForegroundColor DarkGray
    return $cloneRoot
}

function Get-CoupangImportedProfileMetaV2 {
    $cloneRoot = Join-Path (Get-CoupangWorkspaceV1) 'browser_profile_existing'
    $metaPath = Join-Path $cloneRoot 'TinySnow_profile.json'
    if (-not (Test-Path $metaPath)) { return $null }
    try {
        return Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch { return $null }
}

function Start-CoupangImportedProfileV2 {
    $workspace = Get-CoupangWorkspaceV1
    $cloneRoot = Join-Path $workspace 'browser_profile_existing'
    $meta = Get-CoupangImportedProfileMetaV2
    if (-not $meta) { throw '尚未匯入現有瀏覽器登入狀態。請先選「使用目前 Edge/Chrome 已登入狀態」。' }
    if (-not (Test-Path ([string]$meta.executable))) { throw '原瀏覽器程式已不存在，請重新匯入。' }

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
        'https://wing.coupang.com/'
    )
    Start-Process -FilePath ([string]$meta.executable) -ArgumentList $args | Out-Null

    if (-not (Wait-CoupangCdpV1 -TimeoutSeconds 20)) {
        throw '已啟動瀏覽器，但 TinySnow 無法連接本機控制埠 9333。'
    }

    Write-Host ''
    Write-Host '已使用你原本的登入狀態開啟 Coupang WING。' -ForegroundColor Green
    Write-Host '如果 Coupang 仍要求登入，代表該登入工作階段已過期或瀏覽器安全機制不允許複製；TinySnow 不會繞過驗證。' -ForegroundColor Yellow
}

function Import-AndStart-CoupangExistingSessionV2 {
    $profiles = @(Get-CoupangExistingProfilesV2)
    if ($profiles.Count -eq 0) { throw '找不到可用的 Edge/Chrome 使用者 Profile。' }

    Clear-Host
    Write-Host '=================================' -ForegroundColor Cyan
    Write-Host '選擇你平常已登入 Coupang 的瀏覽器 Profile'
    Write-Host '=================================' -ForegroundColor Cyan
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        Write-Host ("{0}. {1}｜{2}｜最後使用 {3}" -f ($i + 1), $profiles[$i].Browser, $profiles[$i].ProfileName, $profiles[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    }
    Write-Host '0. 取消'
    $choice = Read-Host '請輸入編號'
    if ($choice -eq '0') { return }
    if ($choice -notmatch '^\d+$') { throw '請輸入左側數字編號。' }
    $number = [int]$choice
    if ($number -lt 1 -or $number -gt $profiles.Count) { throw '編號超出範圍。' }

    Copy-CoupangBrowserProfileV2 $profiles[$number - 1] | Out-Null
    Start-CoupangImportedProfileV2
}
