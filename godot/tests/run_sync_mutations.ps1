# S6b mutation runner for the sync merge tests (docs/sync_design.md 10.5).
# Copies the godot project to a scratch copy, applies each mutation from sync_mutations.json to the
# copy's scripts/sync/*.gd, runs tests/sync_merge_test.tscn on the copy and checks that the suite fails.
# The original project is only read (md5 checked before and after). Windows PowerShell 5.1 compatible, ASCII only.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File run_sync_mutations.ps1 [-CountOnly]
# Last line: "SYNC_MUT_RESULT PASS n/n" (all mutations detected) or "SYNC_MUT_RESULT FAIL k/n" (k detected of n).
# Exit code: 0 for PASS, 1 otherwise.

param(
    [string]$GodotSrc = '',
    [string]$Scratch = 'C:\Users\rtyu6\AppData\Local\Temp\claude\D--Ai---\9cb41c31-c114-4117-abfc-6c62dfb3d0b7\scratchpad\w_S6b',
    [string]$Godot = (Join-Path $env:USERPROFILE 'Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe'),
    [int]$TimeoutSec = 300,
    [string]$MutationsPath = '',
    [switch]$CountOnly
)

$ErrorActionPreference = 'Stop'
$script:Fatal = ''
$script:Results = @()
$script:Baseline = 'NOT_RUN'
$final = 'SYNC_MUT_RESULT FAIL 0/0'

function Read-Utf8([string]$p) {
    return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
}

function Write-Utf8([string]$p, [string]$t) {
    [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Md5([string]$p) {
    return (Get-FileHash -Algorithm MD5 -LiteralPath $p).Hash
}

function Count-Occ([string]$hay, [string]$needle) {
    if ($needle.Length -eq 0) { return 0 }
    $n = 0
    $i = 0
    while ($true) {
        $j = $hay.IndexOf($needle, $i, [System.StringComparison]::Ordinal)
        if ($j -lt 0) { break }
        $n++
        $i = $j + $needle.Length
    }
    return $n
}

# Snapshot of the real Godot user-data folder (read only). Our scratch copy uses its own folder name.
function Get-UserDataSnapshot {
    $root = Join-Path $env:APPDATA 'Godot\app_userdata'
    if (-not (Test-Path -LiteralPath $root)) { return 'no app_userdata dir' }
    $items = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Where-Object { $_.FullName -notlike '*w_S6b_scratch*' } | Sort-Object FullName)
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $items) {
        [void]$sb.AppendLine(('{0}|{1}|{2}' -f $f.FullName, $f.Length, $f.LastWriteTimeUtc.Ticks))
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $h = [BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', ''
    return ($h + ' files=' + $items.Count)
}

function Invoke-GodotRun([string]$proj, [string]$logDir, [string]$tag) {
    $outF = Join-Path $logDir ($tag + '.stdout.txt')
    $errF = Join-Path $logDir ($tag + '.stderr.txt')
    $glF = Join-Path $logDir ($tag + '.godot.log')
    foreach ($f in @($outF, $errF, $glF)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
    }
    # ProcessStartInfo instead of Start-Process: Start-Process gave an empty ExitCode on PS 5.1 here
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Godot
    $psi.Arguments = '--headless --path "' + $proj + '" --log-file "' + $glF + '" res://tests/sync_merge_test.tscn'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $tOut = $p.StandardOutput.ReadToEndAsync()
    $tErr = $p.StandardError.ReadToEndAsync()
    $res = @{ TimedOut = $false; ExitCode = -999; Text = ''; Pid = $p.Id }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        # only the process this runner started (by PID)
        $res.TimedOut = $true
        try { $p.Kill() } catch { }
        [void]$p.WaitForExit(10000)
    } else {
        [void]$p.WaitForExit()
        $res.ExitCode = [int]$p.ExitCode
    }
    [System.IO.File]::WriteAllText($outF, $tOut.Result, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($errF, $tErr.Result, (New-Object System.Text.UTF8Encoding($false)))
    $t = ''
    if (Test-Path -LiteralPath $outF) { $t += (Read-Utf8 $outF) }
    if (Test-Path -LiteralPath $errF) { $t += "`n" + (Read-Utf8 $errF) }
    $res.Text = $t
    return $res
}

function Parse-Run($res) {
    $t = [string]$res.Text
    $fails = @{}
    foreach ($ln in ($t -split "`r?`n")) {
        # test lines look like "  FAIL  U15b <name> ..."; the id is the first token (U01, U15b, M-04, ...)
        if ($ln -match '^\s*FAIL\s+(\S+)') { $fails[$matches[1]] = $true }
    }
    $sumPass = $null
    $sumFail = $null
    if ($t -match '== sync merge: (\d+) passed, (\d+) failed ==') {
        $sumPass = [int]$matches[1]
        $sumFail = [int]$matches[2]
    }
    $broken = [bool]($t -match 'Parse Error|Compile Error|Failed to load script|Failed to compile')
    return @{ Fails = @($fails.Keys | Sort-Object); SumPass = $sumPass; SumFail = $sumFail; Broken = $broken }
}

try {
    if ($GodotSrc -eq '') { $GodotSrc = Split-Path -Parent $PSScriptRoot }
    $GodotSrc = (Resolve-Path -LiteralPath $GodotSrc).Path
    $jsonPath = Join-Path $PSScriptRoot 'sync_mutations.json'
    if ($MutationsPath -ne '') { $jsonPath = $MutationsPath }

    if (-not (Test-Path -LiteralPath (Join-Path $GodotSrc 'project.godot'))) { throw 'project.godot not found under GodotSrc' }
    if (-not (Test-Path -LiteralPath $jsonPath)) { throw 'sync_mutations.json not found next to the runner' }
    if ($Scratch -notmatch 'w_S6b') { throw 'Scratch must be a w_S6b folder' }
    if ($Scratch.StartsWith($GodotSrc, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Scratch must be outside the project' }
    if (-not (Test-Path -LiteralPath $Godot)) { throw ('Godot not found: ' + $Godot) }

    # PS 5.1: ConvertFrom-Json emits a top-level array as one object, so assign first and wrap afterwards
    $parsed = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $muts = @($parsed)
    if ($muts.Count -eq 0) { throw 'no mutations in sync_mutations.json' }
    foreach ($mm in $muts) { if (([string]$mm.id) -eq '' -or ([string]$mm.find) -eq '') { throw 'mutation without id or find' } }

    $proj = Join-Path $Scratch 'proj'
    $pristine = Join-Path $Scratch 'pristine'
    $logDir = Join-Path $Scratch 'logs'
    New-Item -ItemType Directory -Force -Path $Scratch, $pristine, $logDir | Out-Null

    # originals: md5 before
    $watch = @('scripts\sync\sync_merge.gd', 'scripts\sync\sync_doc.gd', 'tests\sync_merge_test.gd', 'project.godot')
    $origBefore = @{}
    foreach ($w in $watch) { $origBefore[$w] = Get-Md5 (Join-Path $GodotSrc $w) }
    $udBefore = Get-UserDataSnapshot

    # scratch copy of the whole godot folder (includes .godot cache)
    if (Test-Path -LiteralPath $proj) { Remove-Item -LiteralPath $proj -Recurse -Force }
    & robocopy.exe $GodotSrc $proj /E /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw ('robocopy failed: ' + $LASTEXITCODE) }

    # separate user-data folder for the copy, so the real app folder is never touched
    $pg = Join-Path $proj 'project.godot'
    $pgText = Read-Utf8 $pg
    $anchor = 'config/quit_on_go_back=false'
    if ((Count-Occ $pgText $anchor) -ne 1) { throw 'anchor for user dir not unique in project.godot' }
    $add = "`r`n" + 'config/use_custom_user_dir=true' + "`r`n" + 'config/custom_user_dir_name="w_S6b_scratch"'
    Write-Utf8 $pg ($pgText.Replace($anchor, $anchor + $add))

    # pristine copies of the two mutable files (taken from the copy, which equals the original here)
    foreach ($rel in @('sync_merge.gd', 'sync_doc.gd')) {
        Copy-Item -LiteralPath (Join-Path $proj ('scripts\sync\' + $rel)) -Destination (Join-Path $pristine $rel) -Force
        if ((Get-Md5 (Join-Path $pristine $rel)) -ne $origBefore[('scripts\sync\' + $rel)]) { throw ('pristine copy differs from original: ' + $rel) }
    }

    if (-not $CountOnly) {
        $b = Invoke-GodotRun $proj $logDir 'baseline'
        $pb = Parse-Run $b
        $cleanOk = (-not $b.TimedOut) -and ($b.ExitCode -eq 0) -and (-not $pb.Broken) -and ($pb.SumPass -ne $null) -and ($pb.SumFail -eq 0) -and ($pb.SumPass -gt 0)
        $script:Baseline = $(if ($cleanOk) { 'CLEAN' } else { 'FAILED' })
        Write-Output ('BASELINE: ' + $script:Baseline + ' exit=' + $b.ExitCode + ' timeout=' + $b.TimedOut + ' passed=' + $pb.SumPass + ' failed=' + $pb.SumFail + ' broken=' + $pb.Broken)
        if (-not $cleanOk) { throw 'baseline (no mutation) is not clean; mutations not run' }
    }

    foreach ($m in $muts) {
        $id = [string]$m.id
        $rel = [string]$m.file
        $expect = @($m.expect_fail | ForEach-Object { [string]$_ })
        $row = [ordered]@{ id = $id; applied = $false; occurrences = 0; status = ''; fails = @(); expected = $expect; missing = @(); extra = @(); exitCode = $null; note = '' }

        if (($rel -ne 'sync_merge.gd') -and ($rel -ne 'sync_doc.gd')) {
            $row.status = 'BAD_FILE'
            $script:Results += New-Object PSObject -Property $row
            Write-Output ('{0,-5} BAD_FILE file=[{1}]' -f $id, $rel)
            continue
        }
        $target = Join-Path $proj ('scripts\sync\' + $rel)
        Copy-Item -LiteralPath (Join-Path $pristine $rel) -Destination $target -Force
        $orig = Read-Utf8 $target
        $find = [string]$m.find
        $repl = [string]$m.replace
        $all = [bool]$m.all
        $cnt = Count-Occ $orig $find
        $row.occurrences = $cnt

        if ($cnt -eq 0) {
            $row.status = 'NOT_APPLIED'
        } elseif (($cnt -gt 1) -and (-not $all)) {
            $row.status = 'AMBIGUOUS'
        } else {
            $new = $orig.Replace($find, $repl)
            Write-Utf8 $target $new
            $row.applied = ((Get-Md5 $target) -ne (Get-Md5 (Join-Path $pristine $rel)))
            if (-not $row.applied) {
                $row.status = 'NOT_APPLIED'
            } elseif ($CountOnly) {
                $row.status = 'COUNT_OK'
            } else {
                $r = Invoke-GodotRun $proj $logDir $id
                $pr = Parse-Run $r
                $row.exitCode = $r.ExitCode
                $row.fails = $pr.Fails
                $row.missing = @($expect | Where-Object { $pr.Fails -notcontains $_ })
                $row.extra = @($pr.Fails | Where-Object { $expect -notcontains $_ })
                if ($r.TimedOut) {
                    $row.status = 'TIMEOUT'
                } elseif ($pr.Broken) {
                    $row.status = 'BROKEN'
                    $row.note = 'parse/compile error in mutated script (not a detection)'
                } elseif ($pr.SumPass -eq $null) {
                    $row.status = 'NO_SUMMARY'
                } elseif (($pr.Fails.Count -gt 0) -or ($pr.SumFail -gt 0)) {
                    $row.status = 'DETECTED'
                } else {
                    $row.status = 'MISSED'
                }
                if (($row.status -eq 'DETECTED') -and ($row.missing.Count -gt 0)) { $row.note = 'detected, but listed test(s) did not fail' }
                # restore the copy's file for the next mutation
                Copy-Item -LiteralPath (Join-Path $pristine $rel) -Destination $target -Force
            }
        }
        if ($row.applied -and $row.status -ne 'DETECTED' -and -not $CountOnly) {
            Copy-Item -LiteralPath (Join-Path $pristine $rel) -Destination $target -Force
        }
        $script:Results += New-Object PSObject -Property $row
        Write-Output ('{0,-5} {1,-12} occ={2} exitCode={3} fails=[{4}] expected=[{5}] missing=[{6}] extra=[{7}] {8}' -f $id, $row.status, $cnt, $row.exitCode, ($row.fails -join ','), ($expect -join ','), (@($row.missing) -join ','), (@($row.extra) -join ','), $row.note)
    }

    # originals: md5 after must equal before
    $same = $true
    foreach ($w in $watch) {
        if ((Get-Md5 (Join-Path $GodotSrc $w)) -ne $origBefore[$w]) { $same = $false; Write-Output ('ORIGINAL CHANGED: ' + $w) }
    }
    $udAfter = Get-UserDataSnapshot
    Write-Output ('ORIGINAL_MD5_SAME=' + $same + ' USERDATA_SAME=' + ($udBefore -eq $udAfter))
    if (-not $same) { $script:Fatal = 'original project file changed' }
}
catch {
    $script:Fatal = [string]$_.Exception.Message
    Write-Output ('FATAL: ' + $script:Fatal)
}
finally {
    if (-not $CountOnly -and $script:Results.Count -eq 0 -and $script:Fatal -eq '') { $script:Fatal = 'no results' }
    $n = $script:Results.Count
    $det = @($script:Results | Where-Object { $_.status -eq 'DETECTED' }).Count
    $expOk = @($script:Results | Where-Object { $_.status -eq 'DETECTED' -and $_.missing.Count -eq 0 }).Count
    Write-Output ('SUMMARY: detected=' + $det + '/' + $n + ' expected_listed_all_failed=' + $expOk + '/' + $n + ' baseline=' + $script:Baseline)
    if ($CountOnly) {
        $ok = (@($script:Results | Where-Object { $_.status -eq 'COUNT_OK' }).Count -eq $n) -and ($n -gt 0)
        $final = 'SYNC_MUT_RESULT ' + $(if ($ok) { 'PASS' } else { 'FAIL' }) + ' ' + $(if ($ok) { "$n/$n" } else { "0/$n" })
    } elseif (($script:Fatal -eq '') -and ($script:Baseline -eq 'CLEAN') -and ($n -gt 0) -and ($det -eq $n)) {
        $final = 'SYNC_MUT_RESULT PASS ' + $n + '/' + $n
    } else {
        $final = 'SYNC_MUT_RESULT FAIL ' + $det + '/' + $n
    }
    if (-not $CountOnly -and $script:Fatal -ne '') { Write-Output ('FATAL_REASON: ' + $script:Fatal) }
    Write-Output $final
}

if ($final -like '*PASS*') { exit 0 } else { exit 1 }
