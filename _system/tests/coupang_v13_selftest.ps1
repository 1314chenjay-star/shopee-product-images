$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$startDir = Join-Path $repoRoot '_system\start'

. (Join-Path $startDir 'coupang_local_collector.ps1')
. (Join-Path $startDir 'coupang_existing_session.ps1')
. (Join-Path $startDir 'coupang_v13_hardening.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "ASSERT FAILED: $Message | expected=[$Expected] actual=[$Actual]"
    }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

Write-Host '=== TinySnow Coupang V1.3 self-test ===' -ForegroundColor Cyan

# 1) Function presence / load smoke.
foreach ($name in @(
    'Get-CoupangBrowserExecutableV1',
    'Get-CoupangInstalledBrowsersV2',
    'Get-CoupangExistingProfilesV2',
    'Resolve-CoupangBrowserExecutableV3',
    'Copy-CoupangBrowserProfileV2',
    'Start-CoupangImportedProfileV2',
    'Invoke-CdpCommandV1',
    'Export-CoupangCaptureBundleV1'
)) {
    Assert-True ([bool](Get-Command $name -ErrorAction SilentlyContinue)) "function loaded: $name"
}

# 2) Deterministic fixture test. This specifically guards against the PowerShell
# single-string [0] bug that previously saved only the first drive/path character.
$oldLocal = $env:LOCALAPPDATA
$oldPf = $env:ProgramFiles
$oldPfx86 = ${env:ProgramFiles(x86)}
$fixture = Join-Path $env:RUNNER_TEMP ('coupang-fixture-' + [guid]::NewGuid().ToString('N'))
if (-not $env:RUNNER_TEMP) { $fixture = Join-Path $env:TEMP ('coupang-fixture-' + [guid]::NewGuid().ToString('N')) }

try {
    $fakeLocal = Join-Path $fixture 'local'
    $fakePf = Join-Path $fixture 'pf'
    $fakePfx86 = Join-Path $fixture 'pfx86'
    New-Item -ItemType Directory -Path $fakeLocal,$fakePf,$fakePfx86 -Force | Out-Null
    $env:LOCALAPPDATA = $fakeLocal
    $env:ProgramFiles = $fakePf
    ${env:ProgramFiles(x86)} = $fakePfx86

    $fakeChrome = Join-Path $fakeLocal 'Google\Chrome\Application\chrome.exe'
    New-Item -ItemType Directory -Path (Split-Path $fakeChrome -Parent) -Force | Out-Null
    Set-Content -LiteralPath $fakeChrome -Value 'fake executable' -Encoding ASCII

    $chromeUserData = Join-Path $fakeLocal 'Google\Chrome\User Data'
    $defaultDir = Join-Path $chromeUserData 'Default'
    $profile1Dir = Join-Path $chromeUserData 'Profile 1'
    New-Item -ItemType Directory -Path $defaultDir,$profile1Dir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $chromeUserData 'Local State') -Value '{"os_crypt":{}}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $defaultDir 'Preferences') -Value '{"profile":{"name":"Coupang Main"}}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $profile1Dir 'Preferences') -Value '{"profile":{"name":"Other Profile"}}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $defaultDir 'Cookies') -Value 'fixture-cookie-db' -Encoding ASCII
    (Get-Item $defaultDir).LastWriteTime = (Get-Date)
    (Get-Item $profile1Dir).LastWriteTime = (Get-Date).AddDays(-1)

    $detected = Get-CoupangBrowserExecutableV1
    Assert-Equal $fakeChrome $detected 'browser executable is a full path, not the first character'
    Assert-True ($detected.Length -gt 10) 'detected browser path has realistic length'
    Assert-True (Test-Path -LiteralPath $detected) 'detected browser executable exists'

    $installed = @(Get-CoupangInstalledBrowsersV2)
    Assert-Equal 1 $installed.Count 'fixture detects exactly one browser'
    Assert-Equal 'Chrome' $installed[0].Browser 'fixture browser type is Chrome'
    Assert-Equal $fakeChrome ([string]$installed[0].Executable) 'installed browser executable remains full path'

    $profiles = @(Get-CoupangExistingProfilesV2)
    Assert-Equal 2 $profiles.Count 'two Chrome profiles discovered'
    Assert-Equal 'Coupang Main' $profiles[0].ProfileName 'profile display name parsed from Preferences'
    Assert-Equal 'Default' $profiles[0].ProfileDirectory 'most recently used profile sorted first'

    $staleMeta = [pscustomobject]@{ browser='Chrome'; executable='C:\definitely-missing\chrome.exe' }
    $repaired = Resolve-CoupangBrowserExecutableV3 $staleMeta
    Assert-Equal $fakeChrome $repaired 'stale executable path auto-repairs to installed browser'

    $copyProfile = [pscustomobject]@{
        Browser = 'Chrome'
        ProcessName = 'tinysnow_nonexistent_browser_process'
        Executable = $fakeChrome
        UserData = $chromeUserData
        ProfileDirectory = 'Default'
        ProfileName = 'Coupang Main'
    }
    $cloneRoot = Copy-CoupangBrowserProfileV2 $copyProfile
    Assert-True (Test-Path -LiteralPath (Join-Path $cloneRoot 'Default\Cookies')) 'profile copy preserves profile data'
    Assert-True (Test-Path -LiteralPath (Join-Path $cloneRoot 'Local State')) 'profile copy preserves Local State'
    $meta = Get-CoupangImportedProfileMetaV2
    Assert-Equal $fakeChrome ([string]$meta.executable) 'saved imported-profile metadata stores full executable path'
    Assert-Equal 'Default' ([string]$meta.profile_directory) 'saved metadata stores selected profile directory'
}
finally {
    $env:LOCALAPPDATA = $oldLocal
    $env:ProgramFiles = $oldPf
    ${env:ProgramFiles(x86)} = $oldPfx86
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}

# 3) Real Windows browser detection + CDP launch test on the GitHub Windows runner.
$realBrowser = Get-CoupangBrowserExecutableV1
Assert-True (Test-Path -LiteralPath $realBrowser) 'real Edge/Chrome detected on Windows runner'
Assert-True ($realBrowser -match '\.exe$') 'real browser path ends in .exe'
Assert-True ($realBrowser.Length -gt 10) 'real browser path is not truncated'

$port = 9333
$cdpProfile = Join-Path $env:TEMP ('tinysnow-cdp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cdpProfile -Force | Out-Null
$browserProcess = $null
try {
    $args = @(
        "--remote-debugging-port=$port",
        ('--user-data-dir="{0}"' -f $cdpProfile),
        '--headless=new',
        '--disable-gpu',
        '--no-first-run',
        '--no-default-browser-check',
        'about:blank'
    )
    $browserProcess = Start-Process -FilePath $realBrowser -ArgumentList $args -PassThru
    Assert-True (Wait-CoupangCdpV1 -Port $port -TimeoutSeconds 25) 'real browser exposes local CDP port'

    $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -UseBasicParsing -TimeoutSec 5)
    $page = @($targets | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl }) | Select-Object -First 1
    Assert-True ($null -ne $page) 'CDP returns a page target'

    $eval = Invoke-CdpCommandV1 -WebSocketUrl $page.webSocketDebuggerUrl -Method 'Runtime.evaluate' -Params @{
        expression = '40 + 2'
        returnByValue = $true
    }
    Assert-Equal 42 $eval.result.value 'CDP Runtime.evaluate round-trip works'
}
finally {
    if ($browserProcess) {
        try { & taskkill.exe /PID $browserProcess.Id /T /F | Out-Null } catch {}
    }
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $cdpProfile) { Remove-Item -LiteralPath $cdpProfile -Recurse -Force -ErrorAction SilentlyContinue }
}

# 4) Capture bundle ZIP test.
$workspace = Get-CoupangWorkspaceV1
$captureRoot = Join-Path $workspace 'captures'
$testCapture = Join-Path $captureRoot ('9999_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testCapture -Force | Out-Null
Set-Content -LiteralPath (Join-Path $testCapture 'index.json') -Value '{"ok":true}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $testCapture 'README.txt') -Value 'selftest' -Encoding UTF8
(Get-Item $testCapture).LastWriteTime = (Get-Date).AddMinutes(5)
$zip = Export-CoupangCaptureBundleV1
Assert-True (Test-Path -LiteralPath $zip) 'capture bundle ZIP is created'
Assert-True ((Get-Item $zip).Length -gt 0) 'capture bundle ZIP is non-empty'

Write-Host '=== ALL COUPANG V1.3 SELF-TESTS PASSED ===' -ForegroundColor Green
