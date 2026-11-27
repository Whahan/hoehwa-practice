# 모델 받기 시험 러너 (docs/v201_design.md 5.3 PA3-1).
#   powershell -NoProfile -ExecutionPolicy Bypass -File godot\tests\run_model_tests.ps1
# 가짜 모델 서버(phone_src\tools\fake_model_server.py)를 시험마다 새로(18791~18799 중 비어 있는 포트, 시험 전용 폴더와 새 로그 파일)
# 띄우고 시험이 끝나면 그 PID 의 트리를 끈다. 이전 시험의 늦은 로그 줄이 다음 시험 로그에 섞이지 않게 하는 방법이다.
# Godot 시험 model_store_test(pc 1회)와 stt_model_card_test(pc, phone, phonefont, phonedark)를 차례로 돌린다.
# 실패 판정: 종료 코드 != 0, failed > 0, 줄 어디든 `SCRIPT ERROR:`, 엔진 `ERROR:` 줄(종료 때 나오는 자원 누수 보고 3종만 허용), 결과 줄 없음, `TEST_GUARD on` 이 1줄이 아님,
#            시험 개수가 기대보다 적음(model_store_test 90, stt_model_card_test 모드마다 40), 시간 초과.
# 안전:
#   - 서버 포트는 직접 bind 해 보고 비어 있는 것만 쓴다. 서버·Godot 은 자기가 시작한 PID 의 프로세스 트리만 끈다.
#   - 자식 프로세스의 APPDATA 를 작업 폴더로 돌려 실제 사용자 폴더는 읽지도 쓰지도 않는다.
#   - 접속은 127.0.0.1 의 가짜 서버뿐이다(8770/8775/8776 및 외부 네트워크 없음). 모든 시험에 `--api=http://127.0.0.1:9`(닫힌 포트)를 넘긴다.
# 환경 변수: MODEL_GODOT (Godot console exe), MODEL_PY (python.exe), MODEL_ONLY (쉼표로 구분한 `이름` 또는 `이름 모드`만 실행),
#           MODEL_TIMEOUT (한 시험의 제한 시간 초, 기본 300),
#           MODEL_SRV_LOGDELAY (ms, 변이 확인용: 카드 시험 stt_model_card_test 의 서버에만 로그 줄 지연을 건다. 기본 러너에서는 꺼져 있고
#           model_store_test 의 서버에는 절대 적용되지 않는다).
# 끝: 요약 표, 마지막 줄 `남은 프로세스·열린 포트 없음`(서버 PID 종료와 18791~18799 닫힘을 확인했을 때). 하나라도 실패면 종료 코드 1.
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$godotDir = Join-Path $root 'godot'
$godot = if ($env:MODEL_GODOT) { $env:MODEL_GODOT } else { Join-Path $env:USERPROFILE 'Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe' }
$py = if ($env:MODEL_PY) { $env:MODEL_PY } else { 'D:\Ai\언어\app\backend\.venv\Scripts\python.exe' }
$timeoutSec = if ($env:MODEL_TIMEOUT) { [int]$env:MODEL_TIMEOUT } else { 300 }
$only = @(); if ($env:MODEL_ONLY) { $only = $env:MODEL_ONLY.Split(',') | ForEach-Object { $_.Trim() } }
$server = Join-Path $root 'phone_src\tools\fake_model_server.py'
$ports = 18791..18799

# Allowed `ERROR:` lines: ONLY the three resource-leak reports Godot prints when the process exits, each matched as a
# whole line (only the numbers and the resource type name vary). A line that merely starts like one of them does not pass.
$allowedEngine = '^\s*ERROR: \d+ RID allocations of type ''[^'']+'' were leaked at exit\.\z' +
    '|^\s*ERROR: \d+ resources still in use at exit \(run with --verbose for details\)\.\z' +
    '|^\s*ERROR: (\d+ )?ObjectDB instances leaked at exit \(run with --verbose for details\)\.\z'

function Get-EngineErrorLines([string]$text) {
    return @($text -split "`r?`n" | Where-Object { $_ -match '^\s*(USER )?ERROR:' -and $_ -notmatch $allowedEngine })
}

# The gate checks itself first: made-up lines that only start like the allowed ones must be caught, the real ones must pass.
$gateFake = @(
    "ERROR: 1 resources still in use at exit; review test error",
    "ERROR: 1 resources still in use at exit (run with --verbose for details). extra",
    "ERROR: 4 RID allocations of type 'X' were leaked at exit. and something else",
    "ERROR: 4 RID allocations of type 'X' were leaked at exit",
    "ERROR: ObjectDB instances leaked at exit (run with --verbose for details). plus",
    "ERROR: Condition `"status != STATUS_BODY`" is true.",
    "USER ERROR: something"
)
$gateReal = @(
    "ERROR: 4 RID allocations of type 'PN13RendererDummy14TextureStorage12DummyTextureE' were leaked at exit.",
    "ERROR: 1 resources still in use at exit (run with --verbose for details).",
    "ERROR: 12 ObjectDB instances leaked at exit (run with --verbose for details).",
    "ERROR: ObjectDB instances leaked at exit (run with --verbose for details)."
)
$gateBad = @()
foreach ($l in $gateFake) { if ((Get-EngineErrorLines $l).Count -ne 1) { $gateBad += "not caught: $l" } }
foreach ($l in $gateReal) { if ((Get-EngineErrorLines $l).Count -ne 0) { $gateBad += "wrongly caught: $l" } }
if ($gateBad.Count -gt 0) {
    Write-Host 'engine error gate selfcheck FAILED:'
    $gateBad | ForEach-Object { Write-Host ("  " + $_) }
    Write-Host 'MODEL_TESTS_RESULT FAIL'
    exit 1
}
Write-Host ("selfcheck FAIL-as-expected engine gate ({0} made-up lines caught, {1} real leak lines allowed)" -f $gateFake.Count, $gateReal.Count)

$plan = @(
    @{ name = 'model_store_test'; mode = 'pc'; min = 90 },
    @{ name = 'stt_model_card_test'; mode = 'pc'; min = 40 },
    @{ name = 'stt_model_card_test'; mode = 'phone'; min = 40 },
    @{ name = 'stt_model_card_test'; mode = 'phonefont'; min = 40 },
    @{ name = 'stt_model_card_test'; mode = 'phonedark'; min = 40 }
)

foreach ($p in @($godot, $py, $server)) {
    if (-not (Test-Path $p)) { Write-Host "missing: $p"; Write-Host 'MODEL_TESTS_RESULT FAIL'; exit 1 }
}

function Test-PortOpen([int]$port) {
    # a real connect attempt: open only when something accepts it
    $tc = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tc.BeginConnect('127.0.0.1', $port, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(500) -and $tc.Connected)
    }
    catch { return $false }
    finally { $tc.Close() }
}

function Find-FreePort {
    foreach ($p in $ports) {
        if (Test-PortOpen $p) { continue }
        $l = $null
        try {
            $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), $p)
            $l.Start()
            $l.Stop()
            return $p
        }
        catch { continue }
        finally { if ($null -ne $l) { try { $l.Stop() } catch { } } }
    }
    return 0
}

$work = Join-Path $env:TEMP ('model_tests_' + $PID)
$fakeAppData = Join-Path $work 'appdata'
New-Item -ItemType Directory -Force -Path $work, $fakeAppData | Out-Null
$realAppData = $env:APPDATA

$logDelay = 0; if ($env:MODEL_SRV_LOGDELAY) { $logDelay = [int]$env:MODEL_SRV_LOGDELAY }
$script:srvProc = $null
$script:srvPids = @()

# One fake server per test: its own folder (payloads + requests.jsonl), its own log files. Returns the port.
function Start-FakeServer([string]$dir, [string]$tag, [int]$delayMs) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $p = Find-FreePort
    if ($p -eq 0) { throw 'no free port in 18791..18799' }
    $extra = @(); if ($delayMs -gt 0) { $extra = @('--logdelay', [string]$delayMs) }
    $script:srvProc = Start-Process -FilePath $py -ArgumentList (@('-I', '-X', 'utf8', $server, '--port', $p, '--root', $dir, '--ttl', '1500') + $extra) -RedirectStandardOutput (Join-Path $work ("server_{0}.log" -f $tag)) -RedirectStandardError (Join-Path $work ("server_{0}.err" -f $tag)) -PassThru -NoNewWindow
    $script:srvPids += $script:srvProc.Id
    Write-Host ("fake model server pid {0} on 127.0.0.1:{1}{2}" -f $script:srvProc.Id, $p, $(if ($delayMs -gt 0) { " (log delay $delayMs ms)" } else { '' }))
    $up = $false
    for ($i = 0; $i -lt 50; $i++) {
        if (Test-PortOpen $p) { $up = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $up) { throw 'the fake server did not start' }
    return $p
}

# Stops our own server (its PID tree) and waits until it is gone, so no late log line can reach the next test.
function Stop-FakeServer {
    if ($null -ne $script:srvProc) {
        & taskkill /PID $script:srvProc.Id /T /F 2>$null | Out-Null
        for ($i = 0; $i -lt 25; $i++) {
            if ($null -eq (Get-Process -Id $script:srvProc.Id -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Milliseconds 200
        }
        $script:srvProc = $null
    }
}

$rows = @()
$exitCode = 0
try {
    foreach ($t in $plan) {
        $label = "{0} {1}" -f $t.name, $t.mode
        if ($only.Count -gt 0 -and -not ($only -contains $t.name) -and -not ($only -contains $label)) { continue }
        $srv = Join-Path $work ("srv_{0}_{1}" -f $t.name, $t.mode)
        $srvDelay = 0; if ($t.name -eq 'stt_model_card_test') { $srvDelay = $logDelay }
        $port = Start-FakeServer $srv ("{0}_{1}" -f $t.name, $t.mode) $srvDelay
        $a = @('--headless', '--path', $godotDir)
        if ($t.mode -like 'phone*') { $a += @('--resolution', '412x915') }
        $a += "res://tests/$($t.name).tscn"
        $u = @("--port=$port", "--srv-root=$srv", '--api=http://127.0.0.1:9') # C-4: the closed API address, never a real engine
        if ($t.mode -like 'phone*') { $u += '--phone' }
        if ($t.mode -like '*font') { $u += '--font-scale=1.5' }
        if ($t.mode -like '*dark') { $u += '--dark' }
        $a += '--'
        $a += $u
        $log = Join-Path $work ("{0}_{1}.log" -f $t.name, $t.mode)
        Write-Host ("running {0} ..." -f $label)
        $env:APPDATA = $fakeAppData
        try {
            $proc = Start-Process -FilePath $godot -ArgumentList $a -WorkingDirectory $godotDir -RedirectStandardOutput $log -RedirectStandardError ($log + '.err') -PassThru -NoNewWindow
            $null = $proc.Handle
            $done = $proc.WaitForExit($timeoutSec * 1000)
            if (-not $done) { & taskkill /PID $proc.Id /T /F | Out-Null; $code = -999 } else { $proc.WaitForExit(); $code = $proc.ExitCode }
        }
        finally { $env:APPDATA = $realAppData; Stop-FakeServer }
        $text = ''
        if (Test-Path $log) { $text += [IO.File]::ReadAllText($log, [Text.Encoding]::UTF8) }
        if (Test-Path ($log + '.err')) { $text += "`n" + [IO.File]::ReadAllText(($log + '.err'), [Text.Encoding]::UTF8) }
        $m = [regex]::Matches($text, '(\d+)\s+passed,\s+(\d+)\s+failed')
        $np = $null; $nf = $null
        if ($m.Count -gt 0) { $np = [int]$m[$m.Count - 1].Groups[1].Value; $nf = [int]$m[$m.Count - 1].Groups[2].Value }
        $se = ([regex]::Matches($text, 'SCRIPT ERROR:')).Count
        $tg = ([regex]::Matches($text, 'TEST_GUARD on')).Count
        # engine errors (`ERROR:` lines) count as failures, except the known leak report Godot prints when it exits
        $eng = (Get-EngineErrorLines $text).Count
        $why = @()
        if ($code -eq -999) { $why += 'timeout' } elseif ($code -ne 0) { $why += "exit $code" }
        if ($null -eq $np) { $why += 'no result line' } else {
            if ($nf -gt 0) { $why += "$nf failed" }
            if ($np -lt [int]$t.min) { $why += "only $np tests (need $($t.min))" }
        }
        if ($se -gt 0) { $why += "$se SCRIPT ERROR" }
        if ($eng -gt 0) { $why += "$eng engine ERROR" }
        if ($tg -ne 1) { $why += "TEST_GUARD x$tg" }
        $res = if ($why.Count -eq 0) { 'PASS' } else { 'FAIL (' + ($why -join ', ') + ')' }
        if ($why.Count -gt 0) { $exitCode = 1 }
        $row = [pscustomobject]@{ Name = $t.name; Mode = $t.mode; Passed = $np; Failed = $nf; SE = $se; Guard = $tg; Result = $res; Log = $log }
        $rows += $row
        Write-Host ("{0} {1}: {2} passed, {3} failed | SCRIPT_ERROR={4} ENGINE_ERROR={5} TEST_GUARD={6} | {7}" -f $t.name, $t.mode, $np, $nf, $se, $eng, $tg, $res)
    }
    if ($rows.Count -eq 0) { $exitCode = 1; Write-Host 'nothing ran' }
}
catch {
    Write-Host ("runner error: " + $_.Exception.Message)
    $exitCode = 1
}
finally {
    $env:APPDATA = $realAppData
    Stop-FakeServer # our own server only
}

# the leftover check: every server PID we started is gone and nothing listens in 18791..18799
$alive = $false
foreach ($sp in $script:srvPids) { if ($null -ne (Get-Process -Id $sp -ErrorAction SilentlyContinue)) { $alive = $true } }
$open = @($ports | Where-Object { Test-PortOpen $_ })
Write-Host ("tests: {0}, failed: {1}  (logs in {2})" -f $rows.Count, @($rows | Where-Object { $_.Result -ne 'PASS' }).Count, $work)
if ($exitCode -eq 0) { Write-Host 'MODEL_TESTS_RESULT PASS' } else { Write-Host 'MODEL_TESTS_RESULT FAIL' }
if ($alive -or $open.Count -gt 0) {
    Write-Host ("남은 프로세스 또는 열린 포트 있음: pid alive={0} ports={1}" -f $alive, ($open -join ','))
    exit 1
}
Write-Host '남은 프로세스·열린 포트 없음'
exit $exitCode
