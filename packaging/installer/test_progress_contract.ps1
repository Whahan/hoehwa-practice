# install.ps1 / check_env.py / uninstall.ps1 계약 시험 (진행 파일, 종료 코드, 이어하기, GPU 규칙, 옛 인자, 제거 안내).
#   powershell -NoProfile -ExecutionPolicy Bypass -File test_progress_contract.ps1 [-Work <폴더>] [-Python <python.exe>] [-Keep]
# 마지막 줄: PROGRESS_CONTRACT OK (종료 0) 또는 PROGRESS_CONTRACT FAIL <개수> (종료 1).
# 실제 설치는 하지 않는다: 가짜 설치 폴더 + HOEHWA_TEST_MODE=1 + HOEHWA_SETUP_SIMULATE=1. 실제 %APPDATA%·바탕화면·레지스트리는 건드리지 않는다.
param([string]$Work = "", [string]$Python = "", [switch]$Keep)
$ErrorActionPreference = "Stop"
$Installer = $PSScriptRoot
$InstallPs1 = Join-Path $Installer "install.ps1"
$UninstallPs1 = Join-Path $Installer "uninstall.ps1"
$CheckEnvPy = Join-Path $Installer "check_env.py"
if (-not $Work) { $Work = Join-Path ([System.IO.Path]::GetTempPath()) ("hoehwa-progress-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8)) }
$Work = [System.IO.Path]::GetFullPath($Work)
New-Item -ItemType Directory -Force $Work | Out-Null
$EmptyIn = Join-Path $Work "empty-stdin.txt"
[System.IO.File]::WriteAllText($EmptyIn, "")
$Utf8 = New-Object System.Text.UTF8Encoding($false)

$script:Results = New-Object System.Collections.Generic.List[object]
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    $script:Results.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
    Write-Host ("[{0}] {1}{2}" -f $(if ($ok) { "O" } else { "X" }), $name, $(if ($detail) { "  -> " + $detail } else { "" })) -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
}

# ------------------------------------------------------------ 도우미
function Find-Python {
    $c = @()
    if ($Python) { $c += $Python }
    if ($env:HOEHWA_TEST_PY) { $c += $env:HOEHWA_TEST_PY }
    $c += (Join-Path $Installer "..\..\backend\.venv\Scripts\python.exe")
    $c += "D:\Ai\언어\app\backend\.venv\Scripts\python.exe"
    foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p)) { return (Resolve-Path -LiteralPath $p).Path } }
    $g = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return $null
}
$Py = Find-Python

function Set-Env([hashtable]$h) {
    $old = @{}
    foreach ($k in $h.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $h[$k]) }
    return $old
}
function Restore-Env([hashtable]$old) { foreach ($k in $old.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) } }

# 가짜 설치 폴더: 1단계가 요구하는 파일만 있는 빈 껍데기 (시뮬레이션은 파이썬·모델 없이 통과한다)
function New-FakeRoot([string]$path, [string]$gpuStt = "") {
    New-Item -ItemType Directory -Force $path | Out-Null
    foreach ($d in @("backend", "vendor", "defaults")) { New-Item -ItemType Directory -Force (Join-Path $path $d) | Out-Null }
    Copy-Item -LiteralPath $InstallPs1 (Join-Path $path "install.ps1")
    Copy-Item -LiteralPath $UninstallPs1 (Join-Path $path "uninstall.ps1")
    Copy-Item -LiteralPath $CheckEnvPy (Join-Path $path "vendor\check_env.py")
    foreach ($f in @("회화연습.exe", "backend\server.py", "backend\curriculum.json", "vendor\requirements.lock.txt", "vendor\bootstrap.lock.txt",
                     "vendor\models.lock.json", "vendor\install_models.py", "vendor\install_tools.py", "vendor\tools.lock.json", "vendor\update_helper.py")) {
        [System.IO.File]::WriteAllText((Join-Path $path $f), "x")
    }
    [System.IO.File]::WriteAllText((Join-Path $path "vendor\vendor.json"), "{}")
    $cfgSrc = Join-Path $Installer "..\..\backend\config.json"
    if (Test-Path -LiteralPath $cfgSrc) { Copy-Item -LiteralPath $cfgSrc (Join-Path $path "backend\config.json") }
    else { [System.IO.File]::WriteAllText((Join-Path $path "backend\config.json"), '{"llm_provider":"opencode","stt":{"model":"small","device":"cuda","compute_type":"int8_float16"}}') }
    [System.IO.File]::WriteAllText((Join-Path $path "defaults\prefs.json"), '{"a":1}')
    [System.IO.File]::WriteAllText((Join-Path $path "defaults\progress.json"), '{}')
    [System.IO.File]::WriteAllText((Join-Path $path "manifest.json"), '{"version":"9.9.9","installer_version":2}')
}

# 진행 파일 없이 스크립트를 돌린다 (입력은 닫힘). 반환: Out(표준 출력+오류), Exit
function Run-Ps([string]$file, [string[]]$extra = @(), [hashtable]$envs = @{}) {
    $out = Join-Path $Work ("rp-" + [guid]::NewGuid().ToString("N").Substring(0, 6) + ".txt")
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $file
    foreach ($e in $extra) { $argLine += " " + $e }
    $old = Set-Env $envs
    try { $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argLine -RedirectStandardInput $EmptyIn -RedirectStandardOutput $out -RedirectStandardError ($out + ".err") -WindowStyle Hidden -PassThru; $null = $p.Handle } finally { Restore-Env $old }
    if (-not $p.WaitForExit(120000)) { & taskkill.exe /PID $p.Id /T /F | Out-Null }
    $p.WaitForExit()
    $t = [System.IO.File]::ReadAllText($out, $Utf8)
    if (Test-Path -LiteralPath ($out + ".err")) { $t += [System.IO.File]::ReadAllText(($out + ".err"), $Utf8) }
    return [pscustomobject]@{ Out = $t; Exit = $p.ExitCode }
}

# 진행 파일을 읽는다 (쓰는 쪽이 교체 중이어도 읽을 수 있게 공유 모드로 연다). 반환: @{ Obj; Raw; Err }
function Read-Progress([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try { $ms = New-Object System.IO.MemoryStream; $fs.CopyTo($ms); $bytes = $ms.ToArray() } finally { $fs.Dispose() }
    } catch { return $null }   # 교체 순간에 못 열면 다음 번에
    $raw = $Utf8.GetString($bytes)
    try { $obj = $raw | ConvertFrom-Json; return @{ Obj = $obj; Raw = $raw; Bytes = $bytes; Err = "" } }
    catch { return @{ Obj = $null; Raw = $raw; Bytes = $bytes; Err = "JSON 깨짐" } }
}

# install.ps1 을 입력이 닫힌 채로 돌리고 0.2초마다 진행 파일을 읽는다
function Run-Install([string]$root, [hashtable]$envs, [string[]]$extra = @(), [int]$timeoutSec = 120) {
    $pf = Join-Path $root "progress.json"
    Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
    $out = Join-Path $root "stdout.txt"; $err = Join-Path $root "stderr.txt"
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProgressFile "{1}"' -f (Join-Path $root "install.ps1"), $pf
    foreach ($e in $extra) { $argLine += " " + $e }
    $old = Set-Env $envs
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argLine -RedirectStandardInput $EmptyIn -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
        $null = $p.Handle   # 핸들을 잡아 두지 않으면 끝난 뒤 ExitCode 가 비어 나온다
    } finally { Restore-Env $old }
    $snaps = New-Object System.Collections.Generic.List[object]
    $timedOut = $false
    while (-not $p.HasExited) {
        $s = Read-Progress $pf
        if ($s) { $snaps.Add($s) }
        if ($sw.Elapsed.TotalSeconds -gt $timeoutSec) { $timedOut = $true; & taskkill.exe /PID $p.Id /T /F | Out-Null; break }
        Start-Sleep -Milliseconds 200
    }
    $p.WaitForExit()
    $s = Read-Progress $pf
    if ($s) { $snaps.Add($s) }
    $text = if (Test-Path -LiteralPath $out) { [System.IO.File]::ReadAllText($out, $Utf8) } else { "" }
    return [pscustomobject]@{ Exit = $(if ($timedOut) { -999 } else { $p.ExitCode }); Snaps = $snaps; Out = $text; Sec = $sw.Elapsed.TotalSeconds; Pf = $pf; Root = $root }
}

# 진행 파일 계약 검사: 문제 목록(빈 배열이면 통과)
function Test-Snapshots($snaps, [string]$expectFinal) {
    $problems = New-Object System.Collections.Generic.List[string]
    if ($snaps.Count -eq 0) { $problems.Add("진행 파일을 한 번도 못 읽음"); return $problems.ToArray() }
    $last = -1
    $i = 0
    foreach ($s in $snaps) {
        $i++
        if ($s.Err) { $problems.Add("#$i $($s.Err)"); continue }
        $o = $s.Obj
        foreach ($k in @("v", "state", "pct", "step", "steps", "title", "detail", "error", "code", "log", "t")) {
            if (-not ($o.PSObject.Properties.Name -contains $k)) { $problems.Add("#$i 키 없음: $k") }
        }
        if ($o.PSObject.Properties.Name -notcontains "pct") { continue }
        if (-not ($o.pct -is [int] -or $o.pct -is [long]) -or $o.pct -lt 0 -or $o.pct -gt 100) { $problems.Add("#$i pct 이상: $($o.pct)") }
        elseif ($o.pct -lt $last) { $problems.Add("#$i pct 감소: $last -> $($o.pct)") }
        else { $last = [int]$o.pct }
        if (@("running", "done", "error") -notcontains $o.state) { $problems.Add("#$i state 이상: $($o.state)") }
        if ($o.steps -ne 11) { $problems.Add("#$i steps != 11") }
        if ($o.state -eq "done" -and $o.pct -ne 100) { $problems.Add("#$i done 인데 pct=$($o.pct)") }
        if ($o.state -eq "running" -and $o.pct -ge 100) { $problems.Add("#$i running 인데 pct=100") }
    }
    $f = $snaps[$snaps.Count - 1]
    if ($f.Obj) {
        if ($f.Obj.state -ne $expectFinal) { $problems.Add("마지막 state=$($f.Obj.state) (기대 $expectFinal)") }
        if ($expectFinal -eq "done" -and $f.Obj.pct -ne 100) { $problems.Add("마지막 pct=$($f.Obj.pct)") }
    }
    return $problems.ToArray()
}

# ------------------------------------------------------------ 0. 정적 검사 (D1, D14, D15)
$src = [System.IO.File]::ReadAllText($InstallPs1, $Utf8)
$bad = [regex]::Matches($src, '(?i)Read-Host|Ask-YN|Select-Engine|winget|npm|nodejs|ollama|auth login')
Check "D1 질문·Node·Ollama·winget·npm 코드 없음" ($bad.Count -eq 0) ("금지어 " + $bad.Count + "건")
Check "D14 auth.json 문자열·로그인 안내 없음" (-not ($src -match '(?i)auth\.json|auth login')) ""
Check "D15 바로가기·Desktop 코드 없음" (-not ($src -match 'CreateShortcut|Desktop')) ""

# ------------------------------------------------------------ 1. 검사기 자체 시험 (일부러 틀린 진행 파일)
function Mk([hashtable]$h) {
    $base = [ordered]@{ v = 1; state = "running"; pct = 10; step = 1; steps = 11; title = "t"; detail = ""; error = ""; code = 0; log = "x"; t = "x" }
    foreach ($k in $h.Keys) { if ($null -eq $h[$k] -and $k -like "_del_*") { $base.Remove(($k -replace "^_del_", "")) } else { $base[$k] = $h[$k] } }
    $j = ($base | ConvertTo-Json -Compress)
    return @{ Obj = ($j | ConvertFrom-Json); Raw = $j; Err = "" }
}
$goodSeq = @((Mk @{ pct = 5 }), (Mk @{ pct = 50 }), (Mk @{ state = "done"; pct = 100 }))
Check "검사기: 정상 순서는 통과" ((Test-Snapshots $goodSeq "done").Count -eq 0) ""
Check "검사기: pct 감소를 잡는다" ((Test-Snapshots @((Mk @{ pct = 50 }), (Mk @{ pct = 40 }), (Mk @{ state = "done"; pct = 100 })) "done").Count -gt 0) ""
Check "검사기: 키 누락을 잡는다" ((Test-Snapshots @((Mk @{ _del_title = $null }), (Mk @{ state = "done"; pct = 100 })) "done").Count -gt 0) ""
Check "검사기: done 인데 pct 99 를 잡는다" ((Test-Snapshots @((Mk @{ state = "done"; pct = 99 })) "done").Count -gt 0) ""
Check "검사기: 깨진 JSON 을 잡는다" ((Test-Snapshots @((Mk @{ pct = 5 }), @{ Obj = $null; Raw = "{"; Err = "JSON 깨짐" }, (Mk @{ state = "done"; pct = 100 })) "done").Count -gt 0) ""
Check "검사기: 기대한 마지막 state 가 아니면 잡는다" ((Test-Snapshots $goodSeq "error").Count -gt 0) ""
Check "검사기: 기록이 비면 잡는다" ((Test-Snapshots @() "done").Count -gt 0) ""

# ------------------------------------------------------------ 2. 시뮬레이션 설치 (D2, D3)
$r1root = Join-Path $Work "fake1"; New-FakeRoot $r1root
$ud = Join-Path $Work "ud"
# 시험 작업 폴더 경로가 95자를 넘을 수 있어(긴 경로 꺼짐 PC) 경로 규칙은 훅으로 끈다. D6 에서만 켠다. 인터넷 점검은 실제로 한다 (D2 와 같은 조건)
$env1 = @{ HOEHWA_TEST_MODE = "1"; HOEHWA_SETUP_SIMULATE = "1"; HOEHWA_TEST_LONGPATHS = "1"; HOEHWA_USERDATA_DIR = $ud }
$r1 = Run-Install $r1root $env1
Check "D2 시뮬레이션 설치: 입력이 닫혀도 종료 0, 120초 이내" ($r1.Exit -eq 0 -and $r1.Sec -lt 120) ("exit=" + $r1.Exit + ", " + [math]::Round($r1.Sec, 1) + "초")
$p1 = Test-Snapshots $r1.Snaps "done"
Check "D3 진행 파일 계약 (키, pct 비감소, 마지막 done/100)" ($p1.Count -eq 0) (($p1 | Select-Object -First 3) -join "; ")
$pcts = @($r1.Snaps | Where-Object { $_.Obj } | ForEach-Object { [int]$_.Obj.pct } | Select-Object -Unique)
Check "D3 진행 파일이 여러 값으로 움직였다 (0.2초 읽기)" ($pcts.Count -ge 8) ("서로 다른 pct " + $pcts.Count + "개")
$raw0 = $r1.Snaps[$r1.Snaps.Count - 1].Bytes
Check "D3 진행 파일은 BOM 없는 UTF-8, .tmp 가 안 남음" (-not ($raw0.Length -ge 3 -and $raw0[0] -eq 0xEF -and $raw0[1] -eq 0xBB -and $raw0[2] -eq 0xBF) -and -not (Test-Path -LiteralPath ($r1.Pf + ".tmp")) -and -not (Test-Path -LiteralPath ($r1.Pf + ".bak"))) ""
$f1 = $r1.Snaps[$r1.Snaps.Count - 1].Obj
Check "D3 done 일 때 log 가 install.log 경로" ($f1.log -eq (Join-Path $r1root "install.log") -and (Test-Path -LiteralPath $f1.log)) ""
Check "완료 기록: version.txt, installer_version.txt=2, gpu.txt" ((Test-Path (Join-Path $r1root "version.txt")) -and ((Get-Content (Join-Path $r1root "runtime\.state\installer_version.txt") -Raw).Trim() -eq "2") -and (Test-Path (Join-Path $r1root "runtime\.state\gpu.txt"))) ""
Check "시험 훅 HOEHWA_USERDATA_DIR: 기본값이 시험 폴더로 복사됨" ((Test-Path (Join-Path $ud "prefs.json")) -and (Test-Path (Join-Path $ud "progress.json"))) ""
Check "시뮬레이션 단계 표시 파일 02,03,04,07,08 이 생김" ((@("02-python", "03-pip", "04-packages", "07-models", "08-prefetch") | ForEach-Object { Test-Path (Join-Path $r1root "runtime\.state\$_.ok") } | Where-Object { -not $_ }).Count -eq 0) ""

function Test-GpuTxtBytes([string]$root, [string]$want) {
    $b = [System.IO.File]::ReadAllBytes((Join-Path $root "runtime\.state\gpu.txt"))
    $noBom = -not (($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) -or ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF))
    $ascii = -not ($b | Where-Object { $_ -gt 127 -or $_ -eq 0 })
    return ($noBom -and $ascii -and ([System.Text.Encoding]::ASCII.GetString($b)) -eq $want)
}
Check "gpu.txt 는 BOM·UTF-16 없는 순수 ASCII 이고 값이 정확히 nvidia/cpu (파이썬 도우미가 UTF-8 로 읽음)" ((Test-GpuTxtBytes $r1root ((Get-Content (Join-Path $r1root "runtime\.state\gpu.txt") -Raw).Trim())) -and ((Get-Content (Join-Path $r1root "runtime\.state\gpu.txt") -Raw).Trim() -match '^(cpu|nvidia)$')) ""

# HOEHWA_TEST_MODE=1 이 없으면 시험 훅은 전부 무시된다: FAIL_STEP=1 을 줘도 "(시험)" 실패가 아니라 실제 1단계(경로 길이)·2단계가 돈다
$rnt = Join-Path $Work "fake_notest"; New-FakeRoot $rnt
$rn = Run-Install $rnt @{ HOEHWA_TEST_MODE = ""; HOEHWA_SETUP_SIMULATE = "1"; HOEHWA_SETUP_FAIL_STEP = "1"; HOEHWA_TEST_LONGPATHS = "1"; HOEHWA_TEST_NET = "skip"; HOEHWA_USERDATA_DIR = (Join-Path $Work "ud_nt") } @("-Gpu cpu") 60
$fn = if ($rn.Snaps.Count) { $rn.Snaps[$rn.Snaps.Count - 1].Obj } else { $null }
Check "시험 훅은 HOEHWA_TEST_MODE=1 없이는 무시된다 (FAIL_STEP=1 인데 '(시험)' 실패가 아님)" ($rn.Exit -ne 0 -and $fn -and $fn.state -eq "error" -and $fn.error -notmatch '시험' -and $fn.step -le 3) ("exit=" + $rn.Exit + " " + $fn.error)
Check "  그때 학습 기록 시험 폴더(HOEHWA_USERDATA_DIR)에 아무것도 안 씀" (-not (Test-Path (Join-Path $Work "ud_nt"))) ""

# ------------------------------------------------------------ 3. 실패 흉내와 이어하기 (D4, D5)
$r2root = Join-Path $Work "fake2"; New-FakeRoot $r2root
$envBase = @{ HOEHWA_TEST_MODE = "1"; HOEHWA_SETUP_SIMULATE = "1"; HOEHWA_TEST_NET = "skip"; HOEHWA_TEST_LONGPATHS = "1"; HOEHWA_USERDATA_DIR = (Join-Path $Work "ud2") }
$envFail = $envBase.Clone(); $envFail["HOEHWA_SETUP_FAIL_STEP"] = "4"
$r2 = Run-Install $r2root $envFail
$f2 = if ($r2.Snaps.Count) { $r2.Snaps[$r2.Snaps.Count - 1].Obj } else { $null }
Check "D4 FAIL_STEP=4: 종료 코드 40" ($r2.Exit -eq 40) ("exit=" + $r2.Exit)
Check "D4 진행 파일 state=error, code=40" ($f2 -and $f2.state -eq "error" -and $f2.code -eq 40) ""
Check "D4 error 는 비어 있지 않은 한국어 한 줄(120자 이하)" ($f2 -and $f2.error -match '[가-힣]' -and $f2.error.Length -le 120 -and $f2.error -notmatch "`n") ($f2.error)
Check "D4 log 필드가 install.log 위치" ($f2 -and $f2.log -eq (Join-Path $r2root "install.log") -and (Test-Path -LiteralPath $f2.log)) ""
Check "D4 진행 파일 계약 (error 로 끝남, pct 비감소)" ((Test-Snapshots $r2.Snaps "error").Count -eq 0) ((Test-Snapshots $r2.Snaps "error") -join "; ")
Check "D4 실패 후 version.txt 가 없음" (-not (Test-Path (Join-Path $r2root "version.txt"))) ""
$r3 = Run-Install $r2root $envBase
Check "D5 이어하기: 훅 없이 다시 실행하면 종료 0" ($r3.Exit -eq 0) ("exit=" + $r3.Exit)
Check "D5 2~3단계는 '이미 끝난 단계', 4단계는 다시 함" (($r3.Out -match '\[2/11\][^\[]*이미 끝난 단계') -and ($r3.Out -match '\[3/11\][^\[]*이미 끝난 단계') -and -not ($r3.Out -match '\[4/11\][^\[]*이미 끝난 단계')) ""
Check "D5 이어하기 진행 파일 계약 (done/100)" ((Test-Snapshots $r3.Snaps "done").Count -eq 0) ((Test-Snapshots $r3.Snaps "done") -join "; ")
# 5·6단계(OpenCode, JRE) 실패는 설치를 막지 않는다: 경고만 남기고 7단계 이후도 하고, 종료 0, state=done
foreach ($case in @(@(5, "AI 프로그램을 받지 못했어요", "05"), @(6, "문법 검사 도구를 받지 못했어요", "06"))) {
    $sroot = Join-Path $Work ("fake_soft" + $case[0]); New-FakeRoot $sroot
    $envSoft = $envBase.Clone(); $envSoft["HOEHWA_SETUP_FAIL_STEP"] = [string]$case[0]
    $rs = Run-Install $sroot $envSoft
    $fs = if ($rs.Snaps.Count) { $rs.Snaps[$rs.Snaps.Count - 1].Obj } else { $null }
    $slog = Get-Content -LiteralPath (Join-Path $sroot "install.log") -Raw -Encoding UTF8
    Check ("{0}단계 실패 흉내: 설치는 계속되어 종료 0, state=done, pct=100" -f $case[0]) ($rs.Exit -eq 0 -and $fs -and $fs.state -eq "done" -and $fs.pct -eq 100 -and $fs.code -eq 0) ("exit=" + $rs.Exit)
    Check ("{0}단계 실패 흉내: 진행 파일 warn 에 한국어 경고 '{1}'" -f $case[0], $case[1]) ($fs -and $fs.warn -match [regex]::Escape($case[1])) ($fs.warn)
    Check ("{0}단계 실패 흉내: 7·8단계도 실행됨(표시 파일 07,08 있음), version.txt 기록" -f $case[0]) ((Test-Path (Join-Path $sroot "runtime\.state\07-models.ok")) -and (Test-Path (Join-Path $sroot "runtime\.state\08-prefetch.ok")) -and (Test-Path (Join-Path $sroot "version.txt"))) ""
    Check ("{0}단계 실패 흉내: install.log 에 원인 줄([경고 원인])과 경고 문구" -f $case[0]) ($slog -match '\[경고 원인\]' -and $slog -match [regex]::Escape($case[1])) ""
    Check ("{0}단계 실패 흉내: 진행 파일 계약(done)" -f $case[0]) ((Test-Snapshots $rs.Snaps "done").Count -eq 0) ((Test-Snapshots $rs.Snaps "done") -join "; ")
    Check ("{0}단계 실패 흉내: 단계 표시 파일 {1}-*.ok 는 안 만들어 다음 실행에서 다시 시도" -f $case[0], $case[2]) (@(Get-ChildItem (Join-Path $sroot "runtime\.state") -Filter ($case[2] + "-*.ok") -ErrorAction SilentlyContinue).Count -eq 0) ""
}
# 필수 단계(7 음성 모델) 실패는 여전히 막는다 (종료 50)
$r7f = Join-Path $Work "fake_hard7"; New-FakeRoot $r7f
$envH7 = $envBase.Clone(); $envH7["HOEHWA_SETUP_FAIL_STEP"] = "7"
$rh7 = Run-Install $r7f $envH7
$fh7 = if ($rh7.Snaps.Count) { $rh7.Snaps[$rh7.Snaps.Count - 1].Obj } else { $null }
Check "필수 7단계 실패 흉내: 종료 50, state=error" ($rh7.Exit -eq 50 -and $fh7 -and $fh7.state -eq "error" -and $fh7.code -eq 50) ("exit=" + $rh7.Exit)
# 인터넷 점검 실패 흉내 (R10): 어느 주소인지 한국어로, 종료 20
$r2b = Join-Path $Work "fake_net"; New-FakeRoot $r2b
$envNet = $envBase.Clone(); $envNet["HOEHWA_TEST_NET_FAIL"] = "github.com"
$rnet = Run-Install $r2b $envNet
$fnet = if ($rnet.Snaps.Count) { $rnet.Snaps[$rnet.Snaps.Count - 1].Obj } else { $null }
Check "인터넷 점검 실패 흉내: 종료 20, 어느 주소인지 error 에 적힘" ($rnet.Exit -eq 20 -and $fnet -and $fnet.code -eq 20 -and $fnet.error -match 'github\.com' -and $fnet.error -match '[가-힣]') ($fnet.error)
# 디스크 부족 흉내
$r2c = Join-Path $Work "fake_disk"; New-FakeRoot $r2c
$envDisk = $envBase.Clone(); $envDisk["HOEHWA_TEST_FREE_GB"] = "1"
$rdisk = Run-Install $r2c $envDisk
$fdisk = if ($rdisk.Snaps.Count) { $rdisk.Snaps[$rdisk.Snaps.Count - 1].Obj } else { $null }
Check "디스크 부족 흉내: 종료 10, error 에 '공간'" ($rdisk.Exit -eq 10 -and $fdisk -and $fdisk.error -match '공간') ($fdisk.error)
# 필수 파일 누락
$r2d = Join-Path $Work "fake_missing"; New-FakeRoot $r2d; Remove-Item (Join-Path $r2d "vendor\tools.lock.json") -Force
$rmiss = Run-Install $r2d $envBase
$fmiss = if ($rmiss.Snaps.Count) { $rmiss.Snaps[$rmiss.Snaps.Count - 1].Obj } else { $null }
Check "필수 파일(vendor\tools.lock.json) 누락: 종료 10, error 에 파일 이름" ($rmiss.Exit -eq 10 -and $fmiss -and $fmiss.error -match 'tools\.lock\.json') ($fmiss.error)

$badG = Join-Path $Work "badgpu"; New-Item -ItemType Directory -Force (Join-Path $badG "runtime\.state") | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $badG "runtime\.state\gpu.txt"), [byte[]](0xFF, 0xFE, 0x63, 0x00, 0x70, 0x00, 0x75, 0x00))
$u16 = Test-GpuTxtBytes $badG "cpu"
[System.IO.File]::WriteAllBytes((Join-Path $badG "runtime\.state\gpu.txt"), [byte[]](0xEF, 0xBB, 0xBF, 0x63, 0x70, 0x75))
$bom8 = Test-GpuTxtBytes $badG "cpu"
Check "검사기: gpu.txt 가 UTF-16 이거나 BOM 이 있으면 잡는다" (-not $u16 -and -not $bom8) ""

# ------------------------------------------------------------ 4. 경로 95자 (D6)
$pad = "a" * [math]::Max(1, 100 - $Work.Length - 1 - "fake_long".Length)
$r4root = Join-Path $Work ("fake_long" + $pad)
Check "D6 시험 폴더 경로가 95자 초과" ($r4root.Length -gt 95) ([string]$r4root.Length + "자")
New-FakeRoot $r4root
$envLong = $envBase.Clone(); $envLong["HOEHWA_TEST_LONGPATHS"] = "0"
$r4 = Run-Install $r4root $envLong
$f4 = if ($r4.Snaps.Count) { $r4.Snaps[$r4.Snaps.Count - 1].Obj } else { $null }
Check "D6 경로 95자 초과(긴 경로 꺼짐): 종료 10, error 에 '경로'" ($r4.Exit -eq 10 -and $f4 -and $f4.state -eq "error" -and $f4.code -eq 10 -and $f4.error -match '경로') ($f4.error)
$envLong1 = $envBase.Clone(); $envLong1["HOEHWA_TEST_LONGPATHS"] = "1"
$r4b = Run-Install $r4root $envLong1
Check "D6 대조: 긴 경로 지원이 켜져 있으면 같은 폴더도 통과(종료 0)" ($r4b.Exit -eq 0) ("exit=" + $r4b.Exit)

# ------------------------------------------------------------ 5. GPU 규칙, 설정 (D7)
function Get-Cfg($root) { return (Get-Content -LiteralPath (Join-Path $root "backend\config.json") -Raw -Encoding UTF8 | ConvertFrom-Json) }
$r5root = Join-Path $Work "fake_cpu"; New-FakeRoot $r5root
[System.IO.File]::WriteAllText((Join-Path $r5root "backend\config.json"), '{"port":8770,"llm_provider":"legacy","stt":{"model":"small","device":"cuda","compute_type":"int8_float16"},"tts":{"device":"auto"}}')
$r5 = Run-Install $r5root $envBase @("-Gpu cpu")
$c5 = Get-Cfg $r5root
Check "D7 -Gpu cpu: gpu.txt=cpu, stt.device=cpu, compute_type=int8" ($r5.Exit -eq 0 -and (Get-Content (Join-Path $r5root "runtime\.state\gpu.txt") -Raw).Trim() -eq "cpu" -and $c5.stt.device -eq "cpu" -and $c5.stt.compute_type -eq "int8") ("exit=" + $r5.Exit)
Check "D7 -Gpu cpu 일 때 gpu.txt 바이트가 정확히 'cpu' (BOM·UTF-16 없음)" (Test-GpuTxtBytes $r5root "cpu") ""
Check "D7 설정의 다른 값은 그대로 (stt.model, tts)" ($c5.stt.model -eq "small" -and $c5.tts.device -eq "auto" -and $c5.port -eq 8770) ""
Check "설정: 알 수 없는 llm_provider 는 opencode 로 고침" ($c5.llm_provider -eq "opencode") ($c5.llm_provider)
$r6root = Join-Path $Work "fake_nv"; New-FakeRoot $r6root
[System.IO.File]::WriteAllText((Join-Path $r6root "backend\config.json"), '{"llm_provider":"openai_api","stt":{"model":"small","device":"cuda","compute_type":"int8_float16"}}')
$r6 = Run-Install $r6root $envBase @("-Gpu nvidia")
$c6 = Get-Cfg $r6root
Check "D7 -Gpu nvidia: gpu.txt=nvidia, stt.device 안 바뀜(cuda), compute_type 그대로" ($r6.Exit -eq 0 -and (Get-Content (Join-Path $r6root "runtime\.state\gpu.txt") -Raw).Trim() -eq "nvidia" -and $c6.stt.device -eq "cuda" -and $c6.stt.compute_type -eq "int8_float16") ("exit=" + $r6.Exit)
Check "D7 -Gpu nvidia 일 때 gpu.txt 바이트가 정확히 'nvidia'" (Test-GpuTxtBytes $r6root "nvidia") ""
Check "설정: 앱에서 고른 openai_api 는 그대로 둠" ($c6.llm_provider -eq "openai_api") ""
# 그래픽카드 종류가 바뀌면 패키지 단계를 다시 한다
$r6b = Run-Install $r6root $envBase @("-Gpu cpu")
Check "그래픽카드 종류가 바뀌면(nvidia->cpu) 4단계를 다시 함" ($r6b.Exit -eq 0 -and -not ($r6b.Out -match '\[4/11\][^\[]*이미 끝난 단계')) ""
$r6c = Run-Install $r6root $envBase @("-Gpu cpu")
Check "그래픽카드 종류가 같으면 4단계는 건너뜀" ($r6c.Exit -eq 0 -and ($r6c.Out -match '\[4/11\][^\[]*이미 끝난 단계')) ""
$r6bad = Run-Install $r6root $envBase @("-Gpu amd") 30
Check "잘못된 -Gpu 값은 거절 (종료 0 아님)" ($r6bad.Exit -ne 0) ("exit=" + $r6bad.Exit)

# ------------------------------------------------------------ 6. 옛 인자, DryRun (D9, D10), 옛 상태 파일 (D12)
$r7root = Join-Path $Work "fake_dry"; New-FakeRoot $r7root
$dry = Run-Ps (Join-Path $r7root "install.ps1") @("-Yes", "-Engine", "local", "-NoShortcut", "-DryRun") @{ HOEHWA_TEST_MODE = ""; HOEHWA_SETUP_SIMULATE = "" }
$dryOut = $dry.Out; $dryExit = $dry.Exit
$dryLog = Get-Content -LiteralPath (Join-Path $r7root "install.log") -Raw -Encoding UTF8
Check "D9 옛 인자 -Yes -Engine local -NoShortcut -DryRun: 종료 0, 로그에 '무시됨' 3줄" ($dryExit -eq 0 -and ([regex]::Matches($dryLog, '무시됨')).Count -ge 3) ("exit=" + $dryExit)
Check "D10 -DryRun 은 [DryRun] 11줄, OpenCode·JRE 줄 포함" (([regex]::Matches($dryOut, '\[DryRun\]')).Count -eq 11 -and $dryOut -match 'OpenCode' -and $dryOut -match 'JRE') ""
Check "D10 -DryRun 은 아무것도 만들지 않음 (runtime, version.txt, gpu.txt 없음)" (-not (Test-Path (Join-Path $r7root "runtime")) -and -not (Test-Path (Join-Path $r7root "version.txt"))) ""
$r8root = Join-Path $Work "fake_oldstate"; New-FakeRoot $r8root
New-Item -ItemType Directory -Force (Join-Path $r8root "runtime\.state") | Out-Null
foreach ($n in @("engine.txt", "engine-config.ok", "engine-pending.ok", "05-node.ok", "06-llm.ok")) { [System.IO.File]::WriteAllText((Join-Path $r8root "runtime\.state\$n"), "local") }
$r8 = Run-Install $r8root $envBase
$st = Join-Path $r8root "runtime\.state"
Check "D12 옛 상태 파일(engine.txt, engine-config.ok, engine-pending.ok)을 지우고 정상 진행" ($r8.Exit -eq 0 -and -not (Test-Path "$st\engine.txt") -and -not (Test-Path "$st\engine-config.ok") -and -not (Test-Path "$st\engine-pending.ok")) ("exit=" + $r8.Exit)
Check "D12 옛 단계 표시(05-node.ok 등)는 무시됨(지우지도 않고 새 단계에 영향 없음)" ((Test-Path "$st\05-node.ok") -and -not (Test-Path "$st\05-opencode.ok")) ""

# ------------------------------------------------------------ 7. 제거 스크립트 (D13)
$u1 = Join-Path $Work "fake_uns_setup"; New-FakeRoot $u1
foreach ($p in @("runtime\python", "backend\tools\opencode", "backend\models")) { New-Item -ItemType Directory -Force (Join-Path $u1 $p) | Out-Null; [System.IO.File]::WriteAllText((Join-Path $u1 "$p\f.txt"), "x") }
[System.IO.File]::WriteAllText((Join-Path $u1 "unins000.exe"), "x"); [System.IO.File]::WriteAllText((Join-Path $u1 "install.log"), "x"); [System.IO.File]::WriteAllText((Join-Path $u1 "version.txt"), "1")
$ur1 = Run-Ps (Join-Path $u1 "uninstall.ps1") @("-Yes"); $uo1 = $ur1.Out; $ux1 = $ur1.Exit
$still = @("runtime\python\f.txt", "backend\tools\opencode\f.txt", "backend\models\f.txt", "install.log", "version.txt", "회화연습.exe", "unins000.exe") | ForEach-Object { Test-Path (Join-Path $u1 $_) }
Check "D13 unins000.exe 가 있으면: 종료 0, '설정 > 앱' 안내만, 아무것도 안 지움" ($ux1 -eq 0 -and $uo1 -match '설정 > 앱' -and ($still | Where-Object { -not $_ }).Count -eq 0) ("exit=" + $ux1)
$u2 = Join-Path $Work "fake_uns_zip"; New-FakeRoot $u2
foreach ($p in @("runtime\python", "backend\tools\opencode", "backend\models")) { New-Item -ItemType Directory -Force (Join-Path $u2 $p) | Out-Null; [System.IO.File]::WriteAllText((Join-Path $u2 "$p\f.txt"), "x") }
[System.IO.File]::WriteAllText((Join-Path $u2 "install.log"), "x"); [System.IO.File]::WriteAllText((Join-Path $u2 "version.txt"), "1")
$ur2 = Run-Ps (Join-Path $u2 "uninstall.ps1") @("-Yes"); $uo2 = $ur2.Out; $ux2 = $ur2.Exit
$gone = @("runtime", "backend\tools", "backend\models", "install.log", "version.txt") | ForEach-Object { -not (Test-Path (Join-Path $u2 $_)) }
$kept = @("회화연습.exe", "backend\server.py", "uninstall.ps1") | ForEach-Object { Test-Path (Join-Path $u2 $_) }
Check "D13 unins000.exe 없으면 지금처럼 지움 (runtime, tools, models, log), 프로그램 파일은 남김" ($ux2 -eq 0 -and ($gone | Where-Object { -not $_ }).Count -eq 0 -and ($kept | Where-Object { -not $_ }).Count -eq 0) ("exit=" + $ux2)
Check "D13 제거 출력에 Ollama 문구 없음" (-not ($uo2 -match '(?i)ollama') -and -not ($uo1 -match '(?i)ollama')) ""

# ------------------------------------------------------------ 8. check_env.py (D8)
if ($Py) {
    $ev = Join-Path $Work "envx"
    New-Item -ItemType Directory -Force (Join-Path $ev "vendor"), (Join-Path $ev "runtime\.state") | Out-Null
    Copy-Item -LiteralPath $CheckEnvPy (Join-Path $ev "vendor\check_env.py") -Force
    $lock = Join-Path $ev "lock.txt"
    [System.IO.File]::WriteAllText($lock, "# lock`nfoo==1.0`nbar==2.0`nnvidia-cublas-cu12==12.9.2.10`nnvidia-cudnn-cu12==9.27.0.42`nnvidia-cuda-nvrtc-cu12==12.9.86`n")
    $fz = @{
        none   = "foo==1.0`nbar==2.0`n"
        withnv = "foo==1.0`nbar==2.0`nnvidia-cublas-cu12==12.9.2.10`nnvidia-cudnn-cu12==9.27.0.42`nnvidia-cuda-nvrtc-cu12==12.9.86`n"
        onenv  = "foo==1.0`nbar==2.0`nnvidia-cublas-cu12==12.9.2.10`n"
        badver = "foo==1.1`nbar==2.0`n"
    }
    function Run-Env([string]$gpuTxt, [string]$freezeKey, [string[]]$extra = @(), [bool]$testMode = $true) {
        if ($gpuTxt) { [System.IO.File]::WriteAllText((Join-Path $ev "runtime\.state\gpu.txt"), $gpuTxt) } else { Remove-Item (Join-Path $ev "runtime\.state\gpu.txt") -Force -ErrorAction SilentlyContinue }
        $ff = Join-Path $ev "freeze.txt"; [System.IO.File]::WriteAllText($ff, $fz[$freezeKey])
        $old = Set-Env @{ HOEHWA_TEST_MODE = $(if ($testMode) { "1" } else { "" }); HOEHWA_FREEZE_FILE = $ff }
        try { $o = & $Py -I -X utf8 (Join-Path $ev "vendor\check_env.py") $lock @extra 2>&1 | Out-String; $c = $LASTEXITCODE } finally { Restore-Env $old }
        return [pscustomobject]@{ Out = $o; Code = $c }
    }
    $e1 = Run-Env "cpu" "none"
    Check "D8 gpu.txt=cpu + nvidia 없는 freeze -> ENV_RESULT OK, 종료 0" ($e1.Code -eq 0 -and $e1.Out -match 'ENV_RESULT OK') ($e1.Out.Trim())
    $e2 = Run-Env "cpu" "withnv"
    Check "D8 gpu.txt=cpu + nvidia 있는 freeze -> EXTRA nvidia-... + MISMATCH, 종료 1" ($e2.Code -eq 1 -and $e2.Out -match 'EXTRA\s+nvidia-' -and $e2.Out -match 'MISMATCH') ($e2.Out.Trim() -replace "`r?`n", " | ")
    $e3 = Run-Env "nvidia" "none"
    Check "D8 gpu.txt=nvidia + nvidia 빠진 freeze -> MISSING + MISMATCH" ($e3.Code -eq 1 -and $e3.Out -match 'MISSING\s+nvidia-' -and $e3.Out -match 'MISMATCH') ($e3.Out.Trim() -replace "`r?`n", " | ")
    $e4 = Run-Env "nvidia" "withnv"
    Check "D8 gpu.txt=nvidia + nvidia 있는 freeze -> OK" ($e4.Code -eq 0 -and $e4.Out -match 'ENV_RESULT OK') ""
    $e5 = Run-Env "nvidia" "none" @("--gpu", "cpu")
    Check "D8 --gpu cpu 인자가 gpu.txt 보다 우선" ($e5.Code -eq 0 -and $e5.Out -match 'ENV_RESULT OK') ""
    $e6 = Run-Env "" "none"
    Check "D8 gpu.txt 가 없으면 nvidia 로 엄격하게 비교 (MISSING)" ($e6.Code -eq 1 -and $e6.Out -match 'MISSING\s+nvidia-') ""
    $e7 = Run-Env "cpu" "onenv"
    Check "D8 cpu 인데 nvidia 하나만 있어도 EXTRA" ($e7.Code -eq 1 -and $e7.Out -match 'EXTRA\s+nvidia-cublas-cu12') ""
    $e8 = Run-Env "cpu" "badver"
    Check "D8 버전이 다르면 DIFFERENT + MISMATCH" ($e8.Code -eq 1 -and $e8.Out -match 'DIFFERENT foo' ) ""
    $e9 = Run-Env "cpu" "none" @() $false
    Check "D8 HOEHWA_TEST_MODE 없으면 HOEHWA_FREEZE_FILE 은 무시된다 (실제 pip freeze 와 비교해 불일치)" ($e9.Code -eq 1 -and $e9.Out -match 'MISSING\s+foo') ($e9.Out.Trim() -replace "`r?`n", " | " | ForEach-Object { $_.Substring(0, [math]::Min(120, $_.Length)) })
} else {
    Check "D8 check_env.py 시험 (파이썬을 못 찾음)" $false "-Python 으로 python.exe 를 알려 주세요"
}

# ------------------------------------------------------------ 9. install.ps1 의 작은 함수들을 코드에서 꺼내 시험 (D11 포함)
$tok = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($InstallPs1, [ref]$tok, [ref]$perr)
Check "install.ps1 구문 오류 없음" ($perr.Count -eq 0) ""
$fnAsts = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
function Get-FnText([string]$name) {
    $f = $fnAsts | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if (-not $f) { throw "함수 없음: $name" }
    return $f.Extent.Text
}
# 의존 stub
function Log([string]$m) { }
$script:HB = 0
function Set-Progress { param($Detail = $null, $Frac = $null, [string]$State = "running", [string]$Err = "", [int]$Code = 0, [switch]$Force) $script:HB++ }
$script:LogW = [System.IO.StreamWriter]::Null
function Write-Utf8([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, $Utf8) }
foreach ($n in @("Quote-Arg", "Invoke-Native", "Fail", "Invoke-InstallTools", "Format-ErrorLine", "Get-EffectiveLock", "Test-HealthGood", "Get-HealthWhy", "Write-FileAtomic")) { Invoke-Expression (Get-FnText $n) }

Check "Quote-Arg: 공백·따옴표·끝 역슬래시" ((Quote-Arg "a b") -eq '"a b"' -and (Quote-Arg 'x"y') -eq '"x\"y"' -and (Quote-Arg 'C:\a b\') -eq '"C:\a b\\"' -and (Quote-Arg "") -eq '""' -and (Quote-Arg "plain") -eq "plain") ""
$c = Invoke-Native "cmd.exe" @("/c", "exit 3") -Quiet
Check "Invoke-Native: 종료 코드를 그대로 돌려준다 (3)" ($c -eq 3) ("code=" + $c)
if ($Py) {
    $c = Invoke-Native $Py @("-X", "utf8", "-c", "import sys;print('한글 출력');print('에러 줄',file=sys.stderr)") -Quiet
    Check "Invoke-Native: 한글 stdout/stderr 를 둘 다 받는다" ($c -eq 0 -and ($script:LastOutput -contains "한글 출력") -and ($script:LastOutput -contains "에러 줄")) (($script:LastOutput -join " | "))
    $c = Invoke-Native $Py @("-X", "utf8", "-c", "import sys;print(repr(sys.stdin.read()))") -Quiet -TimeoutSec 20
    Check "Invoke-Native: 입력은 닫혀 있다 (읽으면 바로 빈 문자열, 멈추지 않음)" ($c -eq 0 -and ($script:LastOutput -contains "''")) (($script:LastOutput -join " | "))
    $script:HB = 0; $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $c = Invoke-Native $Py @("-X", "utf8", "-c", "import time;time.sleep(3.6)") -Quiet
    Check "Invoke-Native: 출력이 없어도 1초마다 진행 파일 갱신(3.6초 동안 3번 이상)" ($c -eq 0 -and $script:HB -ge 3) ("갱신 " + $script:HB + "번, " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "초")
    $script:Seen = New-Object System.Collections.Generic.List[string]
    $c = Invoke-Native $Py @("-X", "utf8", "-c", "print('a');print('b');print('c')") -Quiet -OnLine { $script:Seen.Add([string]$args[0]) }
    Check "Invoke-Native: -OnLine 이 줄마다 불림" ($script:Seen.Count -eq 3 -and $script:Seen[2] -eq "c") ""
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $c = Invoke-Native $Py @("-X", "utf8", "-c", "import os,time;print(os.getpid(),flush=True);time.sleep(60)") -Quiet -TimeoutSec 2
    $childPid = [int]($script:LastOutput | Select-Object -First 1)
    $alive = [bool](Get-Process -Id $childPid -ErrorAction SilentlyContinue)
    Check "Invoke-Native: -TimeoutSec 가 지나면 자기가 시작한 PID 만 끄고 1 을 돌려준다" ($c -eq 1 -and $sw.Elapsed.TotalSeconds -lt 10 -and -not $alive) ("code=$c, " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "초, 살아 있음=$alive")
    if ($alive) { & taskkill.exe /PID $childPid /T /F | Out-Null }
}
if ($Py) {
    # 가짜 install_tools.py 로 Invoke-InstallTools 의 실제 코드를 시험한다
    $script:Vendor = Join-Path $Work "vend_fake"; New-Item -ItemType Directory -Force $script:Vendor | Out-Null
    $script:Root = Join-Path $Work "root_fake"; New-Item -ItemType Directory -Force $script:Root | Out-Null
    $script:Py = $Py; $script:ToolNice = "OpenCode"
    [System.IO.File]::WriteAllText((Join-Path $script:Vendor "tools.lock.json"), "{}")
    function Run-FakeTools([string]$body) {
        [System.IO.File]::WriteAllText((Join-Path $script:Vendor "install_tools.py"), $body, $Utf8)
        $script:FailCode = 0; $msg = ""
        try { Invoke-InstallTools "opencode" "OpenCode" } catch { $msg = $_.Exception.Message }
        return [pscustomobject]@{ Msg = $msg; Code = $script:FailCode }
    }
    $t1 = Run-FakeTools "import sys`nprint('TOOL opencode FAIL hash 해시가 달라요')`nprint('TOOL_RESULT FAIL')`nsys.exit(30)`n"
    Check "Invoke-InstallTools: 해시 실패(종료 30)는 한국어 이유와 함께 예외, 코드 30" ($t1.Code -eq 30 -and $t1.Msg -match '해시가 달라요') ($t1.Msg + " / " + $t1.Code)
    $t2 = Run-FakeTools "import sys`nprint('TOOL opencode FAIL net 인터넷이 안 돼요')`nsys.exit(20)`n"
    Check "Invoke-InstallTools: 인터넷 실패(종료 20)는 코드 20" ($t2.Code -eq 20 -and $t2.Msg -match '인터넷이 안 돼요') ($t2.Msg + " / " + $t2.Code)
    $t3 = Run-FakeTools "print('TOOL opencode OK 1.19.0 x')`nprint('TOOL_RESULT OK')`n"
    Check "Invoke-InstallTools: TOOL_RESULT OK 면 예외 없음" ($t3.Msg -eq "" -and $t3.Code -eq 0) ($t3.Msg)
    $t4 = Run-FakeTools "print('TOOL opencode OK 1.19.0 x')`n"
    Check "Invoke-InstallTools: 종료 0 이어도 TOOL_RESULT OK 가 없으면 실패로 본다" ($t4.Msg -ne "") ""
    $t5 = Run-FakeTools "import sys`nsys.exit(7)`n"
    Check "Invoke-InstallTools: 이유 줄 없이 종료 7 이면 기본 한국어 문구, 코드 1" ($t5.Code -eq 1 -and $t5.Msg -match '[가-힣]') ($t5.Msg + " / " + $t5.Code)
}
$c = Invoke-Native "C:\nonexistent\nothing.exe" @() -Quiet
Check "Invoke-Native: 없는 실행 파일은 예외 없이 1" ($c -eq 1) ""

$e = Format-ErrorLine "English only failure`nsecond line"
Check "Format-ErrorLine: 영어 메시지는 한국어 머리말, 첫 줄만" ($e -match '^예기치 않은 오류' -and $e -match 'English only failure' -and $e -notmatch 'second') $e
$e = Format-ErrorLine (("가" * 300) + "`n다음 줄")
Check "Format-ErrorLine: 120자 이하로 자르고 한 줄" ($e.Length -le 120 -and $e -notmatch "`n") ([string]$e.Length)
$e = Format-ErrorLine "키 sk-ABCDEFGH12345678 가 보였어요"
Check "Format-ErrorLine: 키처럼 보이는 문자열은 가림" ($e -notmatch 'ABCDEFGH' -and $e -match '\*\*\*') $e

$lk = Join-Path $Work "lock_unit.txt"
[System.IO.File]::WriteAllText($lk, "# c`nfoo==1`nnvidia-cublas-cu12==12.9`nnvidia_cudnn_cu12==9`nnvidia-cuda-nvrtc-cu12==12`nnvidia-nccl-cu12==2`nbar==2`n")
$cpuLock = Get-EffectiveLock $lk "cpu" (Join-Path $Work "lockout")
$cpuTxt = Get-Content -LiteralPath $cpuLock -Raw
Check "Get-EffectiveLock cpu: cuBLAS/cuDNN/nvrtc 3줄만 빠지고 나머지(foo, bar, nccl)는 남음" ($cpuTxt -notmatch 'cublas|cudnn|nvrtc' -and $cpuTxt -match 'foo==1' -and $cpuTxt -match 'bar==2' -and $cpuTxt -match 'nvidia-nccl') ""
Check "Get-EffectiveLock nvidia: 원본 경로를 그대로 돌려줌" ((Get-EffectiveLock $lk "nvidia" (Join-Path $Work "lockout2")) -eq $lk) ""
$realLock = @("D:\Ai\언어\app\packaging\locks\requirements.lock.txt", (Join-Path $Installer "..\locks\requirements.lock.txt")) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($realLock) {
    $rl = Get-EffectiveLock $realLock "cpu" (Join-Path $Work "lockout3")
    $d = @(Get-Content $realLock).Count - @(Get-Content $rl).Count
    Check "Get-EffectiveLock: 실제 잠금에서 정확히 3줄이 빠짐" ($d -eq 3) ("빠진 줄 $d")
}

Check "D11 Test-HealthGood: llm=false 여도 합격" (Test-HealthGood ('{"ok":true,"stt":true,"tts":{"en":true,"ja":true},"llm":false,"score":true}' | ConvertFrom-Json)) ""
Check "D11 Test-HealthGood: llm 키가 없어도 합격" (Test-HealthGood ('{"ok":true,"stt":true,"tts":{"en":true,"ja":true},"score":true}' | ConvertFrom-Json)) ""
foreach ($bad in @(
    @('stt=false', '{"ok":true,"stt":false,"tts":{"en":true,"ja":true},"llm":true,"score":true}'),
    @('tts.ja=false', '{"ok":true,"stt":true,"tts":{"en":true,"ja":false},"llm":true,"score":true}'),
    @('tts.en=false', '{"ok":true,"stt":true,"tts":{"en":false,"ja":true},"llm":true,"score":true}'),
    @('score=false', '{"ok":true,"stt":true,"tts":{"en":true,"ja":true},"llm":true,"score":false}'),
    @('ok=false', '{"ok":false,"stt":true,"tts":{"en":true,"ja":true},"llm":true,"score":true}'),
    @('tts 없음', '{"ok":true,"stt":true,"llm":true,"score":true}'))) {
    Check ("D11 Test-HealthGood: " + $bad[0] + " 이면 불합격 (llm=true 여도)") (-not (Test-HealthGood ($bad[1] | ConvertFrom-Json))) ""
}
Check "D11 Test-HealthGood: null 이면 불합격, Get-HealthWhy 가 한국어" (-not (Test-HealthGood $null) -and (Get-HealthWhy $null) -match '[가-힣]') ""

$wf = Join-Path $Work "atomic.json"
$ok1 = Write-FileAtomic $wf '{"a":1}'; $ok2 = Write-FileAtomic $wf '{"a":2}'
Check "Write-FileAtomic: 새로 쓰기와 덮어쓰기, .tmp/.bak 안 남음" ($ok1 -and $ok2 -and ((Get-Content $wf -Raw).Trim() -eq '{"a":2}') -and -not (Test-Path ($wf + ".tmp")) -and -not (Test-Path ($wf + ".bak"))) ""
$fsHold = [System.IO.File]::Open($wf, "Open", "Read", "ReadWrite, Delete")
try { $ok3 = Write-FileAtomic $wf '{"a":3}' } finally { $fsHold.Dispose() }
Check "Write-FileAtomic: 읽는 쪽이 (삭제 공유로) 열고 있어도 교체됨" ($ok3 -and ((Get-Content $wf -Raw).Trim() -eq '{"a":3}')) ""

# ------------------------------------------------------------ 끝
if (-not $Keep) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
$fails = @($script:Results | Where-Object { -not $_.Ok })
Write-Host ""
Write-Host ("항목 {0}개 중 실패 {1}개" -f $script:Results.Count, $fails.Count)
if ($fails.Count -eq 0) { Write-Host "PROGRESS_CONTRACT OK"; exit 0 }
foreach ($f in $fails) { Write-Host ("  X " + $f.Name) -ForegroundColor Red }
Write-Host ("PROGRESS_CONTRACT FAIL " + $fails.Count)
exit 1
