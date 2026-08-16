$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b007_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b008_semantic_review.json')
$priorBag = Get-V4CSemanticReviewProduct $prior '54265715317'
$currentBag = Get-V4CSemanticReviewProduct $current '54265715317'

Write-Host ('B008 carry probe prior constraints=' + @($priorBag.variant_constraints).Count + ' current constraints=' + @($currentBag.variant_constraints).Count)
$i = 0
foreach ($required in @($priorBag.variant_constraints)) {
    $req = [string]$required
    $found = $false
    $candidateInfo = @()
    foreach ($candidate in @($currentBag.variant_constraints)) {
        $cand = [string]$candidate
        if ($cand -eq $req) { $found = $true }
        if ($cand.Length -eq $req.Length) {
            $candidateInfo += ('len=' + $cand.Length + ' eq=' + ($cand -eq $req) + ' ceq=' + ($cand -ceq $req) + ' value=[' + $cand + ']')
        }
    }
    Write-Host ('REQ[' + $i + '] len=' + $req.Length + ' found=' + $found + ' value=[' + $req + ']')
    foreach ($info in $candidateInfo) { Write-Host ('  CAND ' + $info) }
    $i++
}

Write-Host 'V4-C0 B008 chain probe: DONE'