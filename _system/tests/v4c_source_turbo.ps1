param(
    [Parameter(Mandatory=$false)][string]$ShardPath,
    [Parameter(Mandatory=$false)][string]$ProgressOut,
    [Parameter(Mandatory=$false)][string]$SummaryOut,
    [Parameter(Mandatory=$false)][int]$MaxConcurrency = 6,
    [Parameter(Mandatory=$false)][int]$MaxAttempts = 3,
    [Parameter(Mandatory=$false)][int]$RetryDelaySeconds = 2,
    [Parameter(Mandatory=$false)][switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-JsonLines([string]$Path) {
    $items=@()
    if (-not (Test-Path $Path)) { return ,$items }
    foreach($line in [System.IO.File]::ReadAllLines($Path,$Utf8NoBom)) {
        if([string]::IsNullOrWhiteSpace($line)){continue}
        $items += ($line | ConvertFrom-Json)
    }
    return ,$items
}
function Ensure-Parent([string]$Path) {
    $p=Split-Path -Parent $Path
    if($p -and -not(Test-Path $p)){New-Item -ItemType Directory -Force -Path $p|Out-Null}
}
function Write-JsonLine([string]$Path,$Obj) {
    Ensure-Parent $Path
    $line=($Obj|ConvertTo-Json -Compress -Depth 12)+"`n"
    [System.IO.File]::AppendAllText($Path,$line,$Utf8NoBom)
}
function New-Result($Src,[string]$Status,[int]$Attempts,[string]$Sha,[long]$Bytes,[string]$ErrorText,[bool]$RetryObserved) {
    [pscustomobject][ordered]@{
        sequence=[int]$Src.sequence
        source_id=[string]$Src.source_id
        product_id=[string]$Src.product_id
        image_index=$Src.image_index
        image_type=[string]$Src.image_type
        url=[string]$Src.url
        status=$Status
        attempts=$Attempts
        retry_observed=$RetryObserved
        sha256=$Sha
        byte_count=$Bytes
        error=$ErrorText
        semantic_status= $(if($Status -eq "DONE"){"PENDING"}else{"BLOCK"})
        image_generation_called=$false
        tiny_snow_api_called=$false
        paid_api_called=$false
    }
}

function Invoke-MockOne($Src,[int]$MaxAttemptsLocal) {
    $url=[string]$Src.url
    $attempt=0; $retry=$false
    while($attempt -lt $MaxAttemptsLocal) {
        $attempt++
        if($url -eq "mock://always-fail") {
            if($attempt -lt $MaxAttemptsLocal){$retry=$true;continue}
            return New-Result $Src "FAILED" $attempt "" 0 "mock failure" $retry
        }
        if($url -eq "mock://retry-once" -and $attempt -eq 1){$retry=$true;continue}
        $payload = if($url -like "mock://sha-*") {[Text.Encoding]::UTF8.GetBytes("same-bytes")} else {[Text.Encoding]::UTF8.GetBytes($url)}
        $sha=[BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($payload)).Replace("-","").ToLowerInvariant()
        return New-Result $Src "DONE" $attempt $sha $payload.Length "" $retry
    }
}

function Invoke-SelfTest {
    $srcs=@(
        [pscustomobject]@{sequence=1;source_id="T1";product_id="P1";image_index=0;image_type="main";url="mock://retry-once"},
        [pscustomobject]@{sequence=2;source_id="T2";product_id="P2";image_index=0;image_type="main";url="mock://always-fail"},
        [pscustomobject]@{sequence=3;source_id="T3";product_id="P3";image_index=0;image_type="main";url="mock://sha-a"},
        [pscustomobject]@{sequence=4;source_id="T4";product_id="P4";image_index=0;image_type="main";url="mock://sha-b"}
    )
    $r=@($srcs|ForEach-Object{Invoke-MockOne $_ 3})
    $retry=@($r|Where-Object{$_.sequence -eq 1})[0]
    $fail=@($r|Where-Object{$_.sequence -eq 2})[0]
    $shaA=@($r|Where-Object{$_.sequence -eq 3})[0]
    $shaB=@($r|Where-Object{$_.sequence -eq 4})[0]
    $passed=($retry.status -eq "DONE" -and $retry.attempts -eq 2 -and $retry.retry_observed -and $fail.status -eq "FAILED" -and $fail.attempts -eq 3 -and $shaA.sha256 -eq $shaB.sha256)
    $summary=[ordered]@{
        passed=$passed
        retry_normal=($retry.status -eq "DONE" -and $retry.attempts -eq 2)
        failed_state_normal=($fail.status -eq "FAILED" -and $fail.attempts -eq 3)
        sha_fixture_equal=($shaA.sha256 -eq $shaB.sha256)
        image_generation_called=$false
        tiny_snow_api_called=$false
        paid_api_called=$false
    }
    Write-Host "SELFTEST_RESULT=$($summary|ConvertTo-Json -Compress)"
    if(-not $passed){throw "v4c_source_turbo self-test failed"}
}

if($SelfTest){Invoke-SelfTest;exit 0}
if([string]::IsNullOrWhiteSpace($ShardPath)){throw "ShardPath is required"}
if([string]::IsNullOrWhiteSpace($ProgressOut)){throw "ProgressOut is required"}
if([string]::IsNullOrWhiteSpace($SummaryOut)){throw "SummaryOut is required"}
if($MaxConcurrency -lt 1 -or $MaxConcurrency -gt 12){throw "MaxConcurrency must be 1..12"}
if($MaxAttempts -lt 1 -or $MaxAttempts -gt 6){throw "MaxAttempts must be 1..6"}

$sources=@(Read-JsonLines $ShardPath)
if(Test-Path $ProgressOut){
    $existing=@(Read-JsonLines $ProgressOut)
} else {
    Ensure-Parent $ProgressOut
    [IO.File]::WriteAllText($ProgressOut,"",$Utf8NoBom)
    $existing=@()
}
$doneMap=@{}
foreach($p in $existing){if([string]$p.status -eq "DONE" -or [string]$p.status -eq "SHA_DUPLICATE"){$doneMap[[int]$p.sequence]=$true}}
$pending=@($sources|Where-Object{-not $doneMap.ContainsKey([int]$_.sequence)})

$workDir=Join-Path ([IO.Path]::GetTempPath()) ("v4c-turbo-"+[Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $workDir|Out-Null
$jobs=@{}
$queue=New-Object System.Collections.Queue
foreach($s in $pending){$queue.Enqueue($s)}

try {
    while($queue.Count -gt 0 -or $jobs.Count -gt 0) {
        while($queue.Count -gt 0 -and $jobs.Count -lt $MaxConcurrency) {
            $src=$queue.Dequeue()
            $seq=[int]$src.sequence
            $dest=Join-Path $workDir ("source-"+$seq+".bin")
            $job=Start-Job -ArgumentList @($src,$dest,$MaxAttempts,$RetryDelaySeconds) -ScriptBlock {
                param($Src,$Dest,$MaxAttemptsLocal,$RetryDelay)
                $ErrorActionPreference="Stop"
                $attempt=0;$retry=$false;$lastError=""
                while($attempt -lt $MaxAttemptsLocal) {
                    $attempt++
                    try {
                        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
                        $wc=New-Object Net.WebClient
                        $wc.Headers.Add("User-Agent","TinySnow-V4C1-SourceEvidence/1.0")
                        try {$wc.DownloadFile([string]$Src.url,$Dest)} finally {$wc.Dispose()}
                        if(-not(Test-Path $Dest)){throw "download produced no file"}
                        $fi=Get-Item $Dest
                        if($fi.Length -le 0){throw "downloaded zero bytes"}
                        $sha=(Get-FileHash -Algorithm SHA256 -LiteralPath $Dest).Hash.ToLowerInvariant()
                        return [pscustomobject]@{sequence=[int]$Src.sequence;status="DONE";attempts=$attempt;retry_observed=$retry;sha256=$sha;byte_count=[long]$fi.Length;error=""}
                    } catch {
                        $lastError=$_.Exception.Message
                        if(Test-Path $Dest){Remove-Item -Force $Dest -ErrorAction SilentlyContinue}
                        if($attempt -lt $MaxAttemptsLocal){$retry=$true;Start-Sleep -Seconds $RetryDelay}
                    }
                }
                return [pscustomobject]@{sequence=[int]$Src.sequence;status="FAILED";attempts=$attempt;retry_observed=$retry;sha256="";byte_count=0;error=$lastError}
            }
            $jobs[$job.Id]=[pscustomobject]@{job=$job;src=$src;dest=$dest}
        }

        $finished=@($jobs.Values|Where-Object{$_.job.State -in @("Completed","Failed","Stopped")})
        if($finished.Count -eq 0){Start-Sleep -Milliseconds 250;continue}
        foreach($entry in $finished) {
            $job=$entry.job;$src=$entry.src
            $raw=@(Receive-Job -Job $job -ErrorAction SilentlyContinue)
            $r=$null
            if($raw.Count -gt 0){$r=$raw[-1]}
            if($null -eq $r -or $job.State -ne "Completed"){
                $msg=if($job.ChildJobs.Count -gt 0 -and $job.ChildJobs[0].JobStateInfo.Reason){$job.ChildJobs[0].JobStateInfo.Reason.Message}else{"worker job failed"}
                $r=[pscustomobject]@{status="FAILED";attempts=$MaxAttempts;retry_observed=$true;sha256="";byte_count=0;error=$msg}
            }
            $record=New-Result $src ([string]$r.status) ([int]$r.attempts) ([string]$r.sha256) ([long]$r.byte_count) ([string]$r.error) ([bool]$r.retry_observed)
            Write-JsonLine $ProgressOut $record
            if(Test-Path $entry.dest){Remove-Item -Force $entry.dest -ErrorAction SilentlyContinue}
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $jobs.Remove($job.Id)
        }
    }
} finally {
    foreach($entry in @($jobs.Values)){Stop-Job $entry.job -ErrorAction SilentlyContinue;Remove-Job $entry.job -Force -ErrorAction SilentlyContinue}
    if(Test-Path $workDir){Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue}
}

$rawAll=@(Read-JsonLines $ProgressOut)
$latest=@{}
foreach($item in $rawAll){$latest[[int]$item.sequence]=$item}
$all=New-Object System.Collections.Generic.List[object]
foreach($src in $sources){
    $seq=[int]$src.sequence
    if(-not $latest.ContainsKey($seq)){throw "Missing output for shard sequence $seq"}
    $all.Add($latest[$seq])
}
$finalText=(($all|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 12}) -join "`n")+"`n"
[IO.File]::WriteAllText($ProgressOut,$finalText,$Utf8NoBom)
$summary=[ordered]@{
    input_count=$sources.Count
    skipped_done_on_resume=($sources.Count-$pending.Count)
    attempted_count=$pending.Count
    done_count=@($all|Where-Object{$_.status -eq "DONE"}).Count
    failed_count=@($all|Where-Object{$_.status -eq "FAILED"}).Count
    retry_observed_count=@($all|Where-Object{$_.retry_observed}).Count
    output_count=$all.Count
    input_output_reconciled=($all.Count -eq $sources.Count)
    image_generation_called=$false
    tiny_snow_api_called=$false
    paid_api_called=$false
}
Ensure-Parent $SummaryOut
[IO.File]::WriteAllText($SummaryOut,(($summary|ConvertTo-Json -Depth 8)+"`n"),$Utf8NoBom)
Write-Host "SHARD_SUMMARY=$($summary|ConvertTo-Json -Compress)"
if(-not $summary.input_output_reconciled){throw "Shard input/output reconciliation failed"}
