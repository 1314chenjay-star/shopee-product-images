$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'memory_runtime.py'
if (-not (Test-Path $script)) { throw "TinySnow memory runtime not found: $script" }
& python $script @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
