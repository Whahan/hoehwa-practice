# Mutation runner for backend/sync_hub.py (S5).
# Each mutation is applied to a COPY of the backend folder under <Work>\mut\<id>\backend.
# The original sync_hub.py is never written; its MD5 is checked before and after.
# Only the child process this script starts (python test run) is waited for / killed.
param(
    [string]$Work = (Join-Path $env:TEMP 'sync_hub_mut_work'),
    [int]$TestTimeoutSec = 1200
)

$ErrorActionPreference = 'Stop'
$Backend = $PSScriptRoot
$Py      = Join-Path $Backend '.venv\Scripts\python.exe'
$Hub     = Join-Path $Backend 'sync_hub.py'
$TestSrc = Join-Path $Backend 'test_sync_hub.py'
$MutFile = Join-Path $Backend 'sync_hub_mutations.json'

function Emit([string]$s) { Write-Output $s }

if (-not (Test-Path -LiteralPath $Hub)) {
    Emit 'MUT_RUN NOT_RUN: backend\sync_hub.py does not exist yet (S1 pending). Nothing was changed.'
    Emit 'SYNC_HUB_MUT_RESULT NOT_RUN 0/0'
    exit 2
}
if (-not (Test-Path -LiteralPath $Py)) { Emit 'SYNC_HUB_MUT_RESULT FAIL 0/0 venv python missing'; exit 1 }
if (-not (Test-Path -LiteralPath $TestSrc)) { Emit 'SYNC_HUB_MUT_RESULT FAIL 0/0 test_sync_hub.py missing'; exit 1 }

$hubMd5Before = (Get-FileHash -Algorithm MD5 -LiteralPath $Hub).Hash
$spec  = Get-Content -LiteralPath $MutFile -Encoding UTF8 -Raw | ConvertFrom-Json
$muts  = @($spec)
$cases = @([pscustomobject]@{ id = 'BASELINE'; file = 'backend/sync_hub.py'; find = $null; replace = $null; expect_fail = @() }) + $muts

$mutRoot = Join-Path $Work 'mut'
New-Item -ItemType Directory -Force -Path $mutRoot | Out-Null

$rows = @()
$detected = 0
$baselineOk = $false
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

foreach ($c in $cases) {
    $caseDir = Join-Path $mutRoot $c.id
    if (Test-Path -LiteralPath $caseDir) { Remove-Item -Recurse -Force -LiteralPath $caseDir }
    $dst = Join-Path $caseDir 'backend'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null

    # copy only the code/config needed to run the stub; never secrets or pairing data
    Get-ChildItem -LiteralPath $Backend -File | Where-Object {
        ($_.Extension -eq '.py' -or $_.Extension -eq '.json') -and $_.Name -ne 'secrets.json' -and $_.Name -notlike 'lan_devices*'
    } | Copy-Item -Destination $dst

    $target = Join-Path $dst 'sync_hub.py'
    $status = ''
    if ($c.id -ne 'BASELINE') {
        if ([string]$c.file -ne 'backend/sync_hub.py') { $status = 'BAD_SPEC (file must be backend/sync_hub.py)' }
        else {
            $text    = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
            $cnt     = ([regex]::Matches($text, [regex]::Escape([string]$c.find))).Count
            $replAll = [bool]$c.all
            if (($replAll -and $cnt -lt 1) -or (-not $replAll -and $cnt -ne 1)) {
                $status = "NOT_APPLIED (find string matched $cnt times; anchor must be fixed after S1)"
            } else {
                $new = $text.Replace([string]$c.find, [string]$c.replace)
                [System.IO.File]::WriteAllText($target, $new, $utf8NoBom)
            }
        }
    }

    if ($status -eq '') {
        $cmp = Start-Process -FilePath $Py -ArgumentList @('-m', 'py_compile', $target) -NoNewWindow -Wait -PassThru
        if ($cmp.ExitCode -ne 0) { $status = 'BROKEN_MUTATION (copy does not compile)' }
    }

    $code = $null
    $last = ''
    $failIds = @()
    $harness = 0
    if ($status -eq '') {
        $runDir = Join-Path $caseDir 'run'
        $out = Join-Path $caseDir 'test_out.txt'
        $err = Join-Path $caseDir 'test_err.txt'
        $p = Start-Process -FilePath $Py -ArgumentList @((Join-Path $dst 'test_sync_hub.py'), '--work', $runDir) `
             -WorkingDirectory $dst -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $p.Handle   # cache the handle so ExitCode stays readable after exit
        if (-not $p.WaitForExit($TestTimeoutSec * 1000)) {
            try { $p.Kill() } catch { }
            $status = 'TIMEOUT (test process killed)'
        } else {
            $p.WaitForExit()
        }
        $code = $p.ExitCode
        $lines = @()
        if (Test-Path -LiteralPath $out) { $lines = @(Get-Content -LiteralPath $out -Encoding UTF8) }
        $nonEmpty = @($lines | Where-Object { $_ -match '\S' })
        if ($nonEmpty.Count -gt 0) { $last = [string]$nonEmpty[-1] }
        foreach ($l in $lines) {
            if ($l -match '^\[FAIL\] (T-H\d+)\.') { $failIds += $matches[1] }
        }
        $failIds = @($failIds | Sort-Object -Unique)
        $harness = @($lines | Where-Object { $_ -match '^\[FAIL\] HARNESS' }).Count
    }

    if ($c.id -eq 'BASELINE') {
        if ($status -eq '') {
            $baselineOk = ($code -eq 0 -and $last -match '^SYNC_HUB_TEST_RESULT PASS ')
            $status = if ($baselineOk) { 'BASELINE_OK' } else { 'BASELINE_FAIL' }
        }
    } elseif ($status -eq '') {
        # detected = the expected test ids failed AND the stub server came up (basic flow T-H1.1 passed)
        $missing = @($c.expect_fail | Where-Object { $failIds -notcontains $_ })
        $serverUp = @($lines | Where-Object { $_ -match '^\[PASS\] T-H1\.1 ' }).Count -gt 0
        if ($code -ne 0 -and $last -match '^SYNC_HUB_TEST_RESULT FAIL ' -and $missing.Count -eq 0 -and $serverUp) {
            $status = 'DETECTED'
            $detected++
        } else {
            $status = "MISSED (exit=$code harness_fail=$harness missing=" + ($missing -join ',') + ')'
        }
    }
    $rows += ("MUT {0,-9} {1}  exit={2} fails=[{3}] | {4}" -f $c.id, $status, $code, ($failIds -join ','), $last)
}

$hubMd5After = (Get-FileHash -Algorithm MD5 -LiteralPath $Hub).Hash
$hubSame = ($hubMd5Before -eq $hubMd5After)
$mutCount = $muts.Count
$pass = ($baselineOk -and $hubSame -and $mutCount -eq 7 -and $detected -eq $mutCount)

foreach ($r in $rows) { Emit $r }
Emit ("sync_hub.py MD5 before={0} after={1} same={2}" -f $hubMd5Before, $hubMd5After, $hubSame)
$verdict = if ($pass) { 'PASS' } else { 'FAIL' }
Emit ("SYNC_HUB_MUT_RESULT {0} {1}/{2}" -f $verdict, $detected, $mutCount)
if ($pass) { exit 0 } else { exit 1 }
