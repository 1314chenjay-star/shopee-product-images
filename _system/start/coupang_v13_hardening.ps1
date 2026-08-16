$ErrorActionPreference = 'Stop'

# V1.3 overrides two browser-discovery functions from earlier builds.
# Important PowerShell detail: when a pipeline returns exactly one string,
# indexing [0] can otherwise return only the first character of that string.
# Wrapping the pipeline result in @() guarantees a real array of paths.

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
