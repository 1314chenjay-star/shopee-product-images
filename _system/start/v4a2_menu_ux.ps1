$ErrorActionPreference = 'Stop'

# Compatibility UX layer for the existing beginner menu.
# Only the legacy "press Enter to return" prompt is auto-answered.
# Every other Read-Host call is delegated to the built-in cmdlet unchanged.
function Read-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string]$Prompt,
        [switch]$AsSecureString
    )

    if ([string]$Prompt -eq '按 Enter 回主選單') {
        Start-Sleep -Milliseconds 1100
        return ''
    }

    if ($AsSecureString) {
        if ([string]::IsNullOrWhiteSpace([string]$Prompt)) {
            return Microsoft.PowerShell.Utility\Read-Host -AsSecureString
        }
        return Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt -AsSecureString
    }

    if ([string]::IsNullOrWhiteSpace([string]$Prompt)) {
        return Microsoft.PowerShell.Utility\Read-Host
    }
    return Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt
}

# The old menu file still contains one stale V4-A.1 display label. Replace only that exact
# cosmetic line at render time; all other Write-Host calls are delegated unchanged.
function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position=0, ValueFromPipeline=$true, ValueFromRemainingArguments=$true)]
        [object[]]$Object,
        [object]$Separator = ' ',
        [switch]$NoNewline,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor
    )

    process {
        $items = @($Object)
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ([string]$items[$i] -eq 'Build: V4-A.1｜真實資料＋視覺數量鎖定版') {
                $items[$i] = 'Build: V4-A.3｜Five-Image Planner 五圖整體規劃版'
            }
        }

        $argsMap = @{ Object = $items }
        if ($PSBoundParameters.ContainsKey('Separator')) { $argsMap.Separator = $Separator }
        if ($NoNewline) { $argsMap.NoNewline = $true }
        if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $argsMap.ForegroundColor = $ForegroundColor }
        if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $argsMap.BackgroundColor = $BackgroundColor }
        Microsoft.PowerShell.Utility\Write-Host @argsMap
    }
}

try {
    if ($null -ne $host -and $null -ne $host.UI -and $null -ne $host.UI.RawUI) {
        $host.UI.RawUI.WindowTitle = '蝦皮商品圖片優化工具 V2 | V4-A.3 Five-Image Planner | API-R3-120S'
    }
}
catch {}