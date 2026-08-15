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

# Render the current V4-B candidate name without rewriting the legacy menu file.
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
            $value = [string]$items[$i]
            if ($value -eq 'Build: V4-A.1｜真實資料＋視覺數量鎖定版' -or $value -eq 'Build: V4-A.3｜Five-Image Planner 五圖整體規劃版') {
                $items[$i] = 'Build: V4-B｜原圖保真台灣化五圖優化版'
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
        $host.UI.RawUI.WindowTitle = '蝦皮商品圖片優化工具 V2 | V4-B 原圖保真台灣化五圖優化版 | API-R3-120S'
    }
}
catch {}
