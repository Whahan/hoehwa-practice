# 가사 외우기 시험 전체 러너 (docs/lyrics_memorize_design.md §8 M8-1).
#   powershell -NoProfile -ExecutionPolicy Bypass -File godot\tests\run_memo_tests.ps1
# 시험(memo_mask, memo_grade, memo_model, memo_session, song_memo_drill, song_memo_screen, song_lyrics_add, song_lyrics_store, song_search, memo_flow)을
# PC(인자 없음)와 `-- --phone` 각각 하나씩 차례로 돌린다 (포트가 겹치지 않게 순차).
# memo_flow 시험에는 이 러너가 띄운 가짜 LRCLIB(fixtures/song/fake_lrclib.py, 127.0.0.1:18798)를 `--lrclib=` 로 넘긴다.
# 요약 표: 이름 / passed / failed / SCRIPT ERROR / TEST_GUARD / 판정. 하나라도 실패면 종료 코드 1, 마지막 줄 `MEMO_E2E_RESULT PASS|FAIL`.
# 실패 판정: 종료 코드 != 0, failed > 0, 줄 어디든 `SCRIPT ERROR:`, `TEST_GUARD on` 이 정확히 1번이 아님, 결과 줄(`N passed, M failed`)이 없음
#           (= 읽지 못함), 시간 초과, 로그에 금지된 접속 대상(8770/8775/8776, lrclib.net URL)이 보임, 가짜 서버가 get/search 밖의 호출을 받음.
# 안전:
#   - 자식 프로세스의 APPDATA 를 작업 폴더로 돌려 실제 사용자 폴더(%APPDATA%\Godot\app_userdata\...)는 읽지도 쓰지도 않는다.
#     (전후 비교는 실제 폴더의 이름·크기·수정 시각만 본다. 파일 내용은 열지 않는다.)
#   - 시험이 쓰는 포트(18797 시험 자체 가짜 서버, 18798 이 러너의 가짜 LRCLIB)가 시작 전·끝난 뒤 비어 있는지 확인한다.
#     자기가 시작한 PID(와 하위)만 끈다. 0.0.0.0 에는 바인딩하지 않는다(가짜 서버는 127.0.0.1 만).
#   - 실제 lrclib.net, 8770/8775/8776 에는 접속하지 않는다 (시험이 가짜 서버만 쓴다).
# 환경 변수: MEMO_GODOT (Godot console exe), MEMO_PY (python.exe), MEMO_ONLY (쉼표로 구분한 이름만 실행: 시험 자체 확인용),
#           MEMO_TIMEOUT (한 시험의 제한 시간 초, 기본 900), MEMO_WORK (로그·가짜 APPDATA 를 둘 폴더; 기본은 %TEMP%\memo_tests_<PID>).
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path          # worktree / repo root
$godotDir = Join-Path $root 'godot'
$fakeScript = Join-Path $godotDir 'tests\fixtures\song\fake_lrclib.py'
$godot = if ($env:MEMO_GODOT) { $env:MEMO_GODOT } else { Join-Path $env:USERPROFILE 'Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe' }
$py = if ($env:MEMO_PY) { $env:MEMO_PY } else { 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe' }
$timeoutSec = if ($env:MEMO_TIMEOUT) { [int]$env:MEMO_TIMEOUT } else { 900 }
$only = @(); if ($env:MEMO_ONLY) { $only = $env:MEMO_ONLY.Split(',') | ForEach-Object { $_.Trim() } }

$godotTests = @('memo_mask_test', 'memo_grade_test', 'memo_model_test', 'memo_session_test', 'song_memo_drill_test',
    'song_memo_screen_test', 'song_lyrics_add_test', 'song_lyrics_store_test', 'song_search_test', 'memo_flow_test')
$lrPort = 18798                     # the runner's fake LRCLIB (memo_flow_test)
$ports = @(18797, 18781, 18782, $lrPort) # 18797: song_lyrics_add_test starts its own fake server there; 18781 / 18782: song_search_test (fake LRCLIB / fake identify)
$lrBase = "http://127.0.0.1:$lrPort"

foreach ($p in @($godot, $py, $fakeScript)) {
    if (-not (Test-Path $p)) { Write-Host "missing: $p"; Write-Host 'MEMO_E2E_RESULT FAIL'; exit 1 }
}

$work = if ($env:MEMO_WORK) { $env:MEMO_WORK } else { Join-Path $env:TEMP ('memo_tests_' + $PID) }
New-Item -ItemType Directory -Force -Path $work | Out-Null
$fakeAppData = Join-Path $work 'appdata'
New-Item -ItemType Directory -Force -Path $fakeAppData | Out-Null
$realAppData = $env:APPDATA
$realUserDir = Join-Path $realAppData 'Godot\app_userdata\회화 연습'

# Name / size / modified time of the real user folder (never the contents).
function Get-UserSnapshot {
    if (-not (Test-Path -LiteralPath $realUserDir)) { return 'absent' }
    # Godot's own `logs` folder is left out: any other Godot process of the user (not started by this runner) writes there.
    $items = Get-ChildItem -LiteralPath $realUserDir -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $rel = $_.FullName.Substring($realUserDir.Length); $rel -ne '\logs' -and -not $rel.StartsWith('\logs\') } |
        ForEach-Object { '{0}|{1}|{2}' -f $_.FullName.Substring($realUserDir.Length), $(if ($_.PSIsContainer) { 'd' } else { $_.Length }), $_.LastWriteTimeUtc.Ticks }
    return (($items | Sort-Object) -join "`n")
}

function Test-PortBusy([int]$p) {
    # a real connect attempt: busy only when something accepts it (TIME_WAIT leftovers do not count)
    $tc = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tc.BeginConnect('127.0.0.1', $p, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500) -and $tc.Connected) { return $true }
    }
    catch { }
    finally { $tc.Close() }
    return $false
}

function Get-BusyPorts([int[]]$list) {
    $busy = @()
    foreach ($p in $list) { if (Test-PortBusy $p) { $busy += $p } }
    return $busy
}

function Wait-PortsFree([int[]]$list, [int]$sec) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $sec) {
        if ((Get-BusyPorts $list).Count -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return ((Get-BusyPorts $list).Count -eq 0)
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
            if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) { & taskkill /PID $proc.Id /T /F | Out-Null } # our own process only
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
    # the last "N passed, M failed" of the output ("== x result: 12 passed, 0 failed ==")
    $m = [regex]::Matches($text, '(\d+)\s+passed,\s+(\d+)\s+failed')
    if ($m.Count -gt 0) { $passed = [int]$m[$m.Count - 1].Groups[1].Value; $failed = [int]$m[$m.Count - 1].Groups[2].Value }
    $se = ([regex]::Matches($text, 'SCRIPT ERROR:')).Count
    $guard = ([regex]::Matches($text, 'TEST_GUARD on')).Count
    # forbidden targets: the user's engine ports, the real lrclib.net (a URL; the attribution text names the site without a URL)
    $forbidden = ([regex]::Matches($text, '(127\.0\.0\.1|localhost|0\.0\.0\.0):877[056]\b')).Count + ([regex]::Matches($text, 'https?://[^\s"'']*lrclib\.net')).Count
    $reasons = @()
    if ($r.timeout) { $reasons += 'timeout' }
    elseif ($r.code -ne 0) { $reasons += "exit $($r.code)" }
    if ($null -eq $passed) { $reasons += 'no result line' }
    elseif ($failed -gt 0) { $reasons += "$failed failed" }
    if ($se -gt 0) { $reasons += "$se SCRIPT ERROR" }
    if ($guard -ne 1) { $reasons += "TEST_GUARD on x$guard" }
    if ($forbidden -gt 0) { $reasons += "$forbidden forbidden target in log" }
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

function Ping-Fake {
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri "$lrBase/_ping" -TimeoutSec 2
        return ($resp.StatusCode -eq 200)
    }
    catch { return $false }
}

$fakeProc = $null
$fakeBadCalls = -1
function Start-Fake {
    # the port was checked free by the caller; bind 127.0.0.1 only (fake_lrclib.py refuses any other host)
    $log = Join-Path $work 'fake_lrclib.log'
    $err = Join-Path $work 'fake_lrclib.err'
    $script:fakeProc = Start-Process -FilePath $py -ArgumentList @('-I', $fakeScript, '--port', "$lrPort") -WorkingDirectory $work -RedirectStandardOutput $log -RedirectStandardError $err -PassThru -NoNewWindow
    $null = $script:fakeProc.Handle
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 20) {
        if ($script:fakeProc.HasExited) { return $false }
        if (Ping-Fake) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Stop-Fake {
    if ($null -eq $script:fakeProc) { return }
    $script:fakeBadCalls = -1
    try {
        $log = Invoke-RestMethod -UseBasicParsing -Uri "$lrBase/_log" -TimeoutSec 2
        $script:fakeBadCalls = @($log.bad_calls).Count
    }
    catch { }
    try { Invoke-WebRequest -UseBasicParsing -Uri "$lrBase/_quit" -Method Post -TimeoutSec 2 | Out-Null } catch { }
    Start-Sleep -Milliseconds 400
    $script:fakeProc.Refresh()
    if (-not $script:fakeProc.HasExited) { & cmd /c "taskkill /PID $($script:fakeProc.Id) /T /F >nul 2>&1" } # our own process only
    $script:fakeProc = $null
}

$rows = @()
$exitCode = 0
$userBefore = Get-UserSnapshot
$busyStart = Get-BusyPorts $ports
if ($busyStart.Count -gt 0) {
    Write-Host ("ports busy before the start: " + ($busyStart -join ',') + " - waiting up to 60 s (nothing is killed)")
    if (-not (Wait-PortsFree $ports 60)) {
        Write-Host ("still busy: " + ((Get-BusyPorts $ports) -join ',') + " - not starting")
        Write-Host 'MEMO_E2E_RESULT FAIL'
        exit 1
    }
}

try {
    foreach ($t in $godotTests) {
        if ($only.Count -gt 0 -and -not ($only -contains $t)) { continue }
        $needFake = ($t -eq 'memo_flow_test')
        foreach ($mode in @('pc', 'phone')) {
            $label = if ($mode -eq 'pc') { $t } else { "$t --phone" }
            $a = @('--headless', '--path', $godotDir, "res://tests/$t.tscn")
            $userArgs = @()
            if ($mode -eq 'phone') { $userArgs += '--phone' }
            if ($needFake) {
                $userArgs += "--lrclib=$lrBase"
                $userArgs += "--python=$py"
            }
            if ($userArgs.Count -gt 0) { $a += '--'; $a += $userArgs }
            # song_lyrics_add_test starts its own fake server on 18797: that port (and ours) must be free
            if (-not (Wait-PortsFree $ports 60)) { $rows += [pscustomobject]@{ Name = $label; Passed = '?'; Failed = '?'; ScriptErrors = 0; Guard = 0; Result = 'FAIL (ports busy)'; Log = '' }; continue }
            if ($needFake) {
                if (-not (Start-Fake)) {
                    Stop-Fake
                    $rows += [pscustomobject]@{ Name = $label; Passed = '?'; Failed = '?'; ScriptErrors = 0; Guard = 0; Result = 'FAIL (fake LRCLIB did not start)'; Log = (Join-Path $work 'fake_lrclib.err') }
                    continue
                }
            }
            Write-Host ("running {0} ..." -f $label)
            $r = Invoke-One $godot $a $godotDir ("g_{0}_{1}" -f $t, $mode)
            $row = Summarize $label $r
            if ($needFake) {
                Stop-Fake
                if ($fakeBadCalls -gt 0) { $row.Result = 'FAIL (fake LRCLIB saw ' + $fakeBadCalls + ' call(s) other than get/search)' }
                elseif ($fakeBadCalls -lt 0) { $row.Result = 'FAIL (fake LRCLIB log not readable)' }
            }
            $rows += $row
            if ($row.Result -ne 'PASS') { Write-Host ("  -> {0}: {1}   (log {2})" -f $label, $row.Result, $row.Log) }
        }
    }
}
finally {
    Stop-Fake
    $env:APPDATA = $realAppData
}

$leftover = Get-BusyPorts $ports
$userAfter = Get-UserSnapshot
$userSame = ($userBefore -eq $userAfter)
$rows | Format-Table -AutoSize @{ n = 'name'; e = { $_.Name } }, @{ n = 'passed'; e = { $_.Passed } }, @{ n = 'failed'; e = { $_.Failed } },
    @{ n = 'SCRIPT ERROR'; e = { $_.ScriptErrors } }, @{ n = 'GUARD'; e = { $_.Guard } }, @{ n = 'result'; e = { $_.Result } } | Out-String -Width 220 | Write-Host

$bad = @($rows | Where-Object { $_.Result -ne 'PASS' })
if ($leftover.Count -gt 0) { Write-Host ("ports still open after the run: " + ($leftover -join ',')) }
else { Write-Host ("no test port is left open (" + ($ports -join ',') + ")") }
if ($userSame) { Write-Host 'the real user folder (name / size / time list) is unchanged' }
else { Write-Host 'the real user folder CHANGED during the run'; $exitCode = 1 }
if ($bad.Count -gt 0) {
    Write-Host ("failed: " + (($bad | ForEach-Object { $_.Name }) -join '; '))
    foreach ($b in $bad) { if ($b.Log) { Write-Host ("  log: " + $b.Log) } }
    $exitCode = 1
}
if ($leftover.Count -gt 0) { $exitCode = 1 }
if ($rows.Count -eq 0) { $exitCode = 1; Write-Host 'nothing ran' }
Write-Host ("tests: {0}, failed: {1}  (logs in {2})" -f $rows.Count, $bad.Count, $work)
if ($exitCode -eq 0) { Write-Host 'MEMO_E2E_RESULT PASS' } else { Write-Host 'MEMO_E2E_RESULT FAIL' }
exit $exitCode
