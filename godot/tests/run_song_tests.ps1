# 노래 공부 시험 전체 러너 (docs/song_study_design.md §8 E1-1).
#   powershell -NoProfile -ExecutionPolicy Bypass -File godot\tests\run_song_tests.ps1
# Godot 시험(인자 없음 + `-- --phone`)과 backend 시험(test_song*.py)을 하나씩 차례로 돌린다 (포트가 겹치지 않게 순차).
# 요약 표: 이름 / passed / failed / SCRIPT ERROR / 판정. 하나라도 실패면 종료 코드 1, 마지막 줄 `SONG_E2E_RESULT PASS|FAIL`.
# 실패 판정: 종료 코드 != 0, failed > 0, 줄 어디든 `SCRIPT ERROR:`, 결과 줄(`N passed, M failed`)이 없음(= 읽지 못함), 시간 초과.
# 안전:
#   - 자식 프로세스의 APPDATA 를 작업 폴더로 돌려 실제 사용자 폴더(%APPDATA%\Godot\app_userdata\...)는 읽지도 쓰지도 않는다.
#   - 시험이 쓰는 포트(18794 18795 18797)가 비어 있는지 시작 전·끝난 뒤에 확인한다. 자기가 시작한 PID(와 하위)만 끈다.
#   - 실제 lrclib.net, 8770/8775/8776 에는 접속하지 않는다 (시험이 가짜 서버만 쓴다).
# 환경 변수: SONG_GODOT (Godot console exe), SONG_PY (python.exe), SONG_ONLY (쉼표로 구분한 이름만 실행: 시험 자체 확인용),
#           SONG_TIMEOUT (한 시험의 제한 시간 초, 기본 900).
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path          # worktree / repo root
$godotDir = Join-Path $root 'godot'
$backendDir = Join-Path $root 'backend'
$godot = if ($env:SONG_GODOT) { $env:SONG_GODOT } else { Join-Path $env:USERPROFILE 'Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe' }
$py = if ($env:SONG_PY) { $env:SONG_PY } else { 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe' }
$timeoutSec = if ($env:SONG_TIMEOUT) { [int]$env:SONG_TIMEOUT } else { 900 }
$only = @(); if ($env:SONG_ONLY) { $only = $env:SONG_ONLY.Split(',') | ForEach-Object { $_.Trim() } }

$godotTests = @('lrc_parser_test', 'song_model_test', 'song_store_test', 'song_sync_guard_test', 'lrclib_client_test', 'song_player_test',
    'song_study_test', 'song_view_test', 'song_add_test', 'song_check_test', 'song_study_screen_test', 'song_tabs_test',
    'song_transfer_test', 'song_flow_test')
$pyTests = @(
    @{ name = 'test_song_align.py'; args = @() },
    @{ name = 'test_song_asr.py'; args = @() },
    @{ name = 'test_song_enrich.py'; args = @() },
    @{ name = 'test_song.py'; args = @('--stub', '18795') }
)
$ports = @(18794, 18795, 18797)

foreach ($p in @($godot, $py)) {
    if (-not (Test-Path $p)) { Write-Host "missing: $p"; Write-Host 'SONG_E2E_RESULT FAIL'; exit 1 }
}

$work = Join-Path $env:TEMP ('song_tests_' + $PID)
New-Item -ItemType Directory -Force -Path $work | Out-Null
$fakeAppData = Join-Path $work 'appdata'
New-Item -ItemType Directory -Force -Path $fakeAppData | Out-Null
$realAppData = $env:APPDATA

function Get-BusyPorts {
    $busy = @()
    foreach ($p in $ports) {
        # a real connect attempt: busy only when something accepts it (TIME_WAIT leftovers do not count)
        $tc = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $tc.BeginConnect('127.0.0.1', $p, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(500) -and $tc.Connected) { $busy += $p }
        }
        catch { }
        finally { $tc.Close() }
    }
    return $busy
}

function Wait-PortsFree([int]$sec) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $sec) {
        if ((Get-BusyPorts).Count -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return ((Get-BusyPorts).Count -eq 0)
}

# Runs one command, output to a log file. Returns @{ code; timeout; log }. Kills only its own process tree on a timeout.
function Invoke-One([string]$exe, [string[]]$argList, [string]$workDir, [string]$tag) {
    $log = Join-Path $work ($tag + '.log')
    $err = Join-Path $work ($tag + '.err')
    $env:APPDATA = $fakeAppData
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $workDir -RedirectStandardOutput $log -RedirectStandardError $err -PassThru -NoNewWindow
        $null = $proc.Handle # keeps the exit code readable after WaitForExit(ms)
        $done = $proc.WaitForExit($timeoutSec * 1000)
        if (-not $done) {
            & taskkill /PID $proc.Id /T /F | Out-Null # our own process only
            return @{ code = -999; timeout = $true; log = $log; err = $err }
        }
        $proc.WaitForExit()
        return @{ code = $proc.ExitCode; timeout = $false; log = $log; err = $err }
    }
    finally {
        $env:APPDATA = $realAppData
    }
}

function Read-Log($r) {
    $t = ''
    if (Test-Path $r.log) { $t += [IO.File]::ReadAllText($r.log, [Text.Encoding]::UTF8) }
    if (Test-Path $r.err) { $t += "`n" + [IO.File]::ReadAllText($r.err, [Text.Encoding]::UTF8) }
    return $t
}

function Summarize([string]$name, $r) {
    $text = Read-Log $r
    $passed = $null; $failed = $null
    # the last "N passed, M failed" of the output ("== x result: 12 passed, 0 failed ==", "N passed, 0 failed", ...)
    $m = [regex]::Matches($text, '(\d+)\s+passed,\s+(\d+)\s+failed')
    if ($m.Count -gt 0) { $passed = [int]$m[$m.Count - 1].Groups[1].Value; $failed = [int]$m[$m.Count - 1].Groups[2].Value }
    $se = ([regex]::Matches($text, 'SCRIPT ERROR:')).Count
    $guard = ([regex]::Matches($text, 'TEST_GUARD on')).Count
    $reasons = @()
    if ($r.timeout) { $reasons += 'timeout' }
    elseif ($r.code -ne 0) { $reasons += "exit $($r.code)" }
    if ($null -eq $passed) { $reasons += 'no result line' }
    elseif ($failed -gt 0) { $reasons += "$failed failed" }
    if ($se -gt 0) { $reasons += "$se SCRIPT ERROR" }
    return [pscustomobject]@{
        Name = $name
        Passed = if ($null -eq $passed) { '?' } else { $passed }
        Failed = if ($null -eq $failed) { '?' } else { $failed }
        ScriptErrors = $se
        Guard = $guard
        Result = if ($reasons.Count -eq 0) { 'PASS' } else { 'FAIL (' + ($reasons -join ', ') + ')' }
        Log = $r.log
    }
}

$rows = @()
$exitCode = 0
$busyStart = Get-BusyPorts
if ($busyStart.Count -gt 0) {
    Write-Host ("ports busy before the start: " + ($busyStart -join ',') + " - waiting up to 60 s (nothing is killed)")
    if (-not (Wait-PortsFree 60)) {
        Write-Host ("still busy: " + ((Get-BusyPorts) -join ',') + " - not starting")
        Write-Host 'SONG_E2E_RESULT FAIL'
        exit 1
    }
}

# Godot tests: no argument, then `-- --phone`
foreach ($t in $godotTests) {
    if ($only.Count -gt 0 -and -not ($only -contains $t)) { continue }
    foreach ($mode in @('pc', 'phone')) {
        $label = if ($mode -eq 'pc') { $t } else { "$t --phone" }
        $a = @('--headless', '--path', $godotDir, "res://tests/$t.tscn")
        if ($mode -eq 'phone') { $a += @('--', '--phone') }
        if (-not (Wait-PortsFree 60)) { $rows += [pscustomobject]@{ Name = $label; Passed = '?'; Failed = '?'; ScriptErrors = 0; Guard = 0; Result = 'FAIL (ports busy)'; Log = '' }; continue }
        Write-Host ("running {0} ..." -f $label)
        $r = Invoke-One $godot $a $godotDir ("g_{0}_{1}" -f $t, $mode)
        $row = Summarize $label $r
        if ($row.Guard -lt 1 -and $t -ne 'lrc_parser_test') { } # TEST_GUARD is reported in the table; the tests check it themselves
        $rows += $row
    }
}

# backend tests
foreach ($pt in $pyTests) {
    if ($only.Count -gt 0 -and -not ($only -contains $pt.name)) { continue }
    if (-not (Wait-PortsFree 60)) { $rows += [pscustomobject]@{ Name = $pt.name; Passed = '?'; Failed = '?'; ScriptErrors = 0; Guard = 0; Result = 'FAIL (ports busy)'; Log = '' }; continue }
    Write-Host ("running {0} ..." -f $pt.name)
    $a = @('-I', $pt.name) + $pt.args
    $r = Invoke-One $py $a $backendDir ("p_" + $pt.name)
    $rows += Summarize $pt.name $r
}

$leftover = Get-BusyPorts
$rows | Format-Table -AutoSize @{ n = 'name'; e = { $_.Name } }, @{ n = 'passed'; e = { $_.Passed } }, @{ n = 'failed'; e = { $_.Failed } },
    @{ n = 'SCRIPT ERROR'; e = { $_.ScriptErrors } }, @{ n = 'result'; e = { $_.Result } } | Out-String -Width 200 | Write-Host

$bad = @($rows | Where-Object { $_.Result -ne 'PASS' })
if ($leftover.Count -gt 0) { Write-Host ("ports still open after the run: " + ($leftover -join ',')) }
else { Write-Host ("no test port is left open (" + ($ports -join ',') + ")") }
if ($bad.Count -gt 0) {
    Write-Host ("failed: " + (($bad | ForEach-Object { $_.Name }) -join '; '))
    foreach ($b in $bad) { if ($b.Log) { Write-Host ("  log: " + $b.Log) } }
    $exitCode = 1
}
if ($leftover.Count -gt 0) { $exitCode = 1 }
if ($rows.Count -eq 0) { $exitCode = 1; Write-Host 'nothing ran' }
Write-Host ("tests: {0}, failed: {1}  (logs in {2})" -f $rows.Count, $bad.Count, $work)
if ($exitCode -eq 0) { Write-Host 'SONG_E2E_RESULT PASS' } else { Write-Host 'SONG_E2E_RESULT FAIL' }
exit $exitCode
