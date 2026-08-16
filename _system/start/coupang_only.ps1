$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'TinySnow Coupang 數據採集工具 V1'

. (Join-Path $PSScriptRoot 'coupang_local_collector.ps1')

Show-CoupangCollectorMenuV1
