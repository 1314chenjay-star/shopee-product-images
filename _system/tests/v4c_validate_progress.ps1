param(
    [Parameter(Mandatory=$false)][string]$InventoryPath="_system/v4c/inventory/source_inventory.jsonl",
    [Parameter(Mandatory=$false)][string]$ProgressPath,
    [Parameter(Mandatory=$false)][string]$DuplicateMapPath,
    [Parameter(Mandatory=$false)][string]$FailedPath,
    [Parameter(Mandatory=$false)][string]$SummaryPath,
    [Parameter(Mandatory=$false)][string]$OutputPath="_system/v4c/runtime/validation.json",
    [Parameter(Mandatory=$false)][ValidateSet("Smoke","Final")][string]$Phase="Smoke",
    [Parameter(Mandatory=$false)][string]$ExpectedStableHead="5d49f061e140813b3d229520e9e530f86b27b640",
    [Parameter(Mandatory=$false)][string]$V4CBaselineHead="28d8eb1f024dd7ff17076b9f2fd69243164c7f6e"
)
Set-StrictMode -Version 2.0
$ErrorActionPreference="Stop"
$Utf8NoBom=New-Object Text.UTF8Encoding($false)
function Read-JL([string]$Path){$a=@();foreach($l in [IO.File]::ReadAllLines($Path,$Utf8NoBom)){if(-not[string]::IsNullOrWhiteSpace($l)){$a+=($l|ConvertFrom-Json)}};return ,$a}
function Write-Text([string]$Path,[string]$Text){$p=Split-Path -Parent $Path;if($p -and -not(Test-Path $p)){New-Item -ItemType Directory -Force -Path $p|Out-Null};[IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)}
foreach($p in @($InventoryPath,$ProgressPath,$DuplicateMapPath,$FailedPath,$SummaryPath)){if(-not(Test-Path $p)){throw "Validation input missing: $p"}}
$inv=@(Read-JL $InventoryPath|Sort-Object {[int]$_.sequence});$progress=@(Read-JL $ProgressPath|Sort-Object {[int]$_.sequence})
if($inv.Count -ne 2394){throw "Inventory count expected 2394, got $($inv.Count)"};if($progress.Count -ne $inv.Count){throw "Progress/inventory reconciliation failed: $($progress.Count)/$($inv.Count)"}
for($i=1;$i -le $inv.Count;$i++){if([int]$inv[$i-1].sequence -ne $i){throw "Inventory sequence gap at $i"};if([int]$progress[$i-1].sequence -ne $i){throw "Progress sequence gap at $i"}}
$seqUnique=@($progress|Group-Object sequence|Where-Object{$_.Count -ne 1});if($seqUnique.Count -gt 0){throw "Duplicate/missing progress sequence records detected"}
$dup=Get-Content -Raw -Encoding UTF8 $DuplicateMapPath|ConvertFrom-Json;$failedRaw=Get-Content -Raw -Encoding UTF8 $FailedPath;$failed=@();if(-not[string]::IsNullOrWhiteSpace($failedRaw)){$parsed=$failedRaw|ConvertFrom-Json;if($parsed -is [System.Array]){$failed=@($parsed)}elseif($null -ne $parsed){$failed=@($parsed)}};$summary=Get-Content -Raw -Encoding UTF8 $SummaryPath|ConvertFrom-Json
$legacyCount=@($progress|Where-Object{$_.status -eq "LEGACY_DONE"}).Count;if($legacyCount -ne 900){throw "Legacy completed preservation failed: expected 900 got $legacyCount"}
$badFlags=@($progress|Where-Object{$_.image_generation_called -ne $false -or $_.tiny_snow_api_called -ne $false -or $_.paid_api_called -ne $false});if($badFlags.Count -gt 0){throw "Forbidden API/generation flag detected"}
$shaBad=@($progress|Where-Object{$_.status -eq "SHA_DUPLICATE" -and $_.semantic_status -eq "PENDING"});if($shaBad.Count -gt 0){throw "SHA duplicate independently queued for semantic analysis"}
$remoteLine=@(& git ls-remote origin "refs/heads/tinysnow-tool-only");if($LASTEXITCODE -ne 0 -or $remoteLine.Count -eq 0){throw "Could not verify stable remote HEAD"};$stableHead=($remoteLine[0] -split "\s+")[0];if($stableHead -ne $ExpectedStableHead){throw "Stable HEAD changed: $stableHead expected $ExpectedStableHead"}
& git diff --quiet $V4CBaselineHead HEAD -- "_system/start/api_v2.ps1";if($LASTEXITCODE -ne 0){throw "_system/start/api_v2.ps1 changed relative to V4-C baseline"}
$terminal=@($progress|Where-Object{$_.status -in @("LEGACY_DONE","DONE","URL_DUPLICATE","SHA_DUPLICATE","FAILED")}).Count;$pendingDownload=@($progress|Where-Object{$_.status -eq "PENDING"}).Count;if($Phase -eq "Final" -and $pendingDownload -ne 0){throw "Final phase still has PENDING downloads: $pendingDownload"}
$result=[ordered]@{phase=$Phase;passed=$true;inventory_count=$inv.Count;progress_count=$progress.Count;sequence_no_gaps=$true;input_output_reconciliation=$true;legacy_done=$legacyCount;terminal_count=$terminal;pending_download=$pendingDownload;url_duplicate_count=@($dup.url_duplicates).Count;sha256_duplicate_count=@($dup.sha256_duplicates).Count;failed_count=$failed.Count;semantic_pending=[int]$summary.semantic_pending;hold=[int]$summary.hold;block=[int]$summary.block;stable_head=$stableHead;stable_head_unchanged=$true;api_v2_unchanged=$true;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false}
Write-Text $OutputPath (($result|ConvertTo-Json -Depth 8)+"`n");Write-Host "VALIDATION_RESULT=$($result|ConvertTo-Json -Compress)"
