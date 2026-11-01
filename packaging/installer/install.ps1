# 회화 연습 설치 스크립트 (재실행 안전, 질문 없음). 보통은 setup.exe 가 불러 줍니다 (zip 설치는 설치.bat).
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-ProgressFile <경로>] [-Gpu auto|nvidia|cpu] [-DryRun] [-TestPort 8790]
#   옛 인자 -Yes / -Engine / -NoShortcut 은 받기만 하고 무시합니다 (로그에 "무시됨").
# 진행 상황은 -ProgressFile 의 JSON 한 개로 알린다 (스키마 v1: state/pct/step/steps/title/detail/error/code/log/t).
# 종료 코드: 0 성공 / 10 점검 실패(윈도우·경로·디스크) / 20 인터넷 / 30 받은 파일 해시 불일치 / 40 파이썬 패키지 / 50 모델 / 60 동작 확인 / 1 그 밖
param(
    [string]$ProgressFile = "",   # setup.exe 가 읽는 진행 파일 (없으면 안 쓴다)
    [ValidateSet("auto", "nvidia", "cpu")]
    [string]$Gpu = "auto",        # auto = NVIDIA 그래픽카드가 보이면 nvidia. cpu 이면 cuBLAS/cuDNN/nvrtc(약 2GB)를 설치하지 않는다
    [switch]$DryRun,              # 아무것도 설치하지 않고 단계 계획만 출력한다
    [int]$TestPort = 8790,        # 마지막 동작 확인용 임시 서버 포트(사용 중이면 다음 빈 포트)
    [switch]$Yes,                 # (옛 인자, 무시됨)
    [string]$Engine = "",         # (옛 인자, 무시됨)
    [switch]$NoShortcut           # (옛 인자, 무시됨)
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Root     = $PSScriptRoot
$Backend  = Join-Path $Root "backend"
$Vendor   = Join-Path $Root "vendor"
$Runtime  = Join-Path $Root "runtime"
$PyDir    = Join-Path $Runtime "python"
$Py       = Join-Path $PyDir "python.exe"
$PyW      = Join-Path $PyDir "pythonw.exe"
$HfDir    = Join-Path $Backend "models\hf"
$StateDir = Join-Path $Runtime ".state"
$LogFile  = Join-Path $Root "install.log"
$TotalSteps = 11
$script:Timings = New-Object System.Collections.Generic.List[object]
$script:Warnings = New-Object System.Collections.Generic.List[string]
if ($ProgressFile) { $ProgressFile = [System.IO.Path]::GetFullPath($ProgressFile) }

# 시험 장치: HOEHWA_TEST_MODE=1 일 때만 읽는다 (배포본은 무시)
$TestMode = ($env:HOEHWA_TEST_MODE -eq "1")
function Get-Hook([string]$name) { if ($TestMode) { return [Environment]::GetEnvironmentVariable($name) } return $null }
$Simulate = ($TestMode -and $env:HOEHWA_SETUP_SIMULATE -eq "1")
$FailStep = 0
if ($TestMode -and $env:HOEHWA_SETUP_FAIL_STEP -match '^\d+$') { $FailStep = [int]$env:HOEHWA_SETUP_FAIL_STEP }

# ------------------------------------------------------------------ 단계 표 (가중치 합 100)
$StepDefs = @(
    @{ N = 1;  Key = "check";        Weight = 3;  Code = 10; Title = "설치 환경 점검 중";       Name = "사전 점검 (윈도우, 경로, 디스크, 인터넷, 그래픽카드)" },
    @{ N = 2;  Key = "python";       Weight = 2;  Code = 1;  Title = "파이썬 준비 중";          Name = "파이썬 3.10.11 (포터블) 풀기" },
    @{ N = 3;  Key = "pip";          Weight = 2;  Code = 20; Title = "pip 준비 중";             Name = "pip 준비 (개발 PC 와 같은 버전)" },
    @{ N = 4;  Key = "packages";     Weight = 35; Code = 40; Title = "파이썬 패키지 설치 중";  Name = "파이썬 패키지 설치 (PyTorch, Whisper, Kokoro 등 - 가장 오래 걸립니다)" },
    @{ N = 5;  Key = "opencode";     Weight = 6;  Code = 1;  Soft = $true; WarnMsg = "AI 프로그램을 받지 못했어요. 앱에서 [AI 연결하기]를 누르면 다시 받아요."; Title = "OpenCode 받는 중";        Name = "OpenCode 받기 (무료 AI 엔진)" },
    @{ N = 6;  Key = "jre";          Weight = 3;  Code = 1;  Soft = $true; WarnMsg = "문법 검사 도구를 받지 못했어요. 문법 교정은 AI가 대신해요."; Title = "자바 받는 중";            Name = "자바(JRE) 받기 (문법 검사기용)" },
    @{ N = 7;  Key = "models";       Weight = 28; Code = 50; Title = "음성 모델 받는 중";       Name = "음성 모델 받기 (Whisper small, Kokoro-82M 등 - 약 2 GB)" },
    @{ N = 8;  Key = "prefetch";     Weight = 5;  Code = 50; Title = "데이터 준비 중";          Name = "나머지 데이터 준비 (일본어 사전, 목소리, 음성 인식 장치 확인)" },
    @{ N = 9;  Key = "languagetool"; Weight = 8;  Code = 1;  Title = "문법 검사기 설치 중";     Name = "문법 검사기 LanguageTool 받기" },
    @{ N = 10; Key = "prefs";        Weight = 1;  Code = 1;  Title = "설정 저장 중";            Name = "설정 파일 (프로그램 기본 설정, 학습 기록 기본값)" },
    @{ N = 11; Key = "verify";       Weight = 7;  Code = 60; Title = "동작 확인 중";            Name = "동작 확인 (임시 서버를 켜서 음성 인식 / 목소리 확인)" }
)
$acc = 0
foreach ($sd in $StepDefs) { $sd.Start = $acc; $acc += $sd.Weight }

# ------------------------------------------------------------------ 로그 / 출력 도우미
try {
    $script:LogW = New-Object System.IO.StreamWriter($LogFile, $true, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    $LogFile = Join-Path ([System.IO.Path]::GetTempPath()) "hoehwa-install.log"
    $script:LogW = New-Object System.IO.StreamWriter($LogFile, $true, (New-Object System.Text.UTF8Encoding($false)))
}
$script:LogW.AutoFlush = $true
function Log([string]$m) { $script:LogW.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $m) }
function Say([string]$m, [string]$color = "White") { Write-Host $m -ForegroundColor $color; Log $m }
function Info([string]$m) { Say ("    " + $m) "Gray" }
function Warn([string]$m) { Say ("    [주의] " + $m) "Yellow"; $script:Warnings.Add($m) }
# 실패: 한국어 메시지와 종료 코드. 코드를 안 주면 (기본 1) 지금 단계의 기본 코드가 쓰인다.
$script:FailCode = 0
function Fail([string]$m, [int]$code = 0) { $script:FailCode = $code; throw $m }

function Write-Utf8([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-Sha256([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

# 임시 파일에 쓰고 이름을 바꿔 교체한다 (읽는 쪽이 반쯤 쓴 파일을 보지 않게). 읽는 쪽이 잡고 있으면 몇 번 다시 시도하고, 끝내 안 되면 false.
function Write-FileAtomic([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $tmp = $path + ".tmp"
    for ($i = 0; $i -lt 6; $i++) {
        try {
            [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $path) {
                # Replace 는 한 번에 바꿔 치우는 연산이다 (백업 이름을 꼭 줘야 한다: PowerShell 은 $null 문자열 인자를 빈 문자열로 바꾼다)
                $bak = $path + ".bak"
                [System.IO.File]::Replace($tmp, $path, $bak)
                Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
            } else { [System.IO.File]::Move($tmp, $path) }
            return $true
        } catch { Start-Sleep -Milliseconds 40 }
    }
    return $false
}

# ------------------------------------------------------------------ 진행 파일 (setup.exe 가 읽는다. 스키마 3.3.2)
$script:Pct = 0
$script:CurStep = 1
$script:StepTitle = "시작하는 중"
$script:Detail = ""
$script:ProgWarn = ""   # 설치를 막지 않는 경고(5·6단계 실패 등): 진행 파일의 warn 에 끝까지 남는다
$script:LastWriteTick = -100000
$script:ProgressSw = [System.Diagnostics.Stopwatch]::StartNew()
# 키·토큰처럼 보이는 문자열은 가리고, 한국어 한 줄(120자 이하)로 만든다
function Format-ErrorLine([string]$m) {
    $line = ""
    foreach ($l in ($m -split "`r?`n")) { if ($l.Trim() -ne "") { $line = $l.Trim(); break } }
    $line = $line -replace '\s+', ' '
    $line = $line -replace '(?i)\b(sk|key|token|ghp|hf)[-_][A-Za-z0-9_\-]{8,}', '***'
    if ($line -notmatch '[가-힣]') { $line = "예기치 않은 오류가 생겼어요: " + $line }
    if ($line.Length -gt 120) { $line = $line.Substring(0, 119) + "…" }
    return $line
}
# -Force 가 없으면 0.4초 안에 또 쓰지 않는다 (값은 바로 반영, 파일 쓰기만 건너뜀). pct 는 줄어들지 않고, running 중에는 99 를 넘지 않는다.
function Set-Progress {
    param($Detail = $null, $Frac = $null, [string]$State = "running", [string]$Err = "", [int]$Code = 0, [switch]$Force)
    if ($null -ne $Detail) { $script:Detail = [string]$Detail }
    if ($null -ne $Frac) {
        $s = $StepDefs[$script:CurStep - 1]
        $f = [math]::Max(0.0, [math]::Min(0.99, [double]$Frac))
        $p = [int][math]::Floor($s.Start + $s.Weight * $f)
        if ($p -gt $script:Pct) { $script:Pct = $p }
    }
    if ($State -eq "running" -and $script:Pct -gt 99) { $script:Pct = 99 }
    if ($State -eq "done") { $script:Pct = 100 }
    if (-not $ProgressFile) { return }
    $now = [int]$script:ProgressSw.ElapsedMilliseconds
    if (-not $Force -and $State -eq "running" -and ($now - $script:LastWriteTick) -lt 400) { return }
    $script:LastWriteTick = $now
    try {
        $o = [ordered]@{
            v = 1; state = $State; pct = [int]$script:Pct; step = [int]$script:CurStep; steps = $TotalSteps
            title = $script:StepTitle; detail = $script:Detail; error = $Err; code = $Code; log = $LogFile; warn = $script:ProgWarn
            t = (Get-Date -Format "yyyy-MM-dd'T'HH:mm:sszzz")
        }
        [void](Write-FileAtomic $ProgressFile ($o | ConvertTo-Json -Compress))
    } catch { }   # 진행 표시가 안 써져도 설치는 계속한다
}

# ------------------------------------------------------------------ 외부 프로그램 실행
# 인자 하나를 CommandLineToArgvW 규칙으로 감싼다
function Quote-Arg([string]$a) {
    if ($a -eq "") { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $s = $a -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}
# 출력은 화면과 install.log 에 같이 남긴다. 종료 코드를 돌려준다. 입력은 닫아 둔다 (물어보는 프로그램이 멈추지 않게).
# 1초 안에 진행 파일을 다시 쓰고(-Tick 도 그때 부른다), 줄이 나올 때마다 -OnLine 을 부른다. -TimeoutSec 가 지나면 자기가 시작한 PID 만 끈다.
$script:LastOutput = @()
function Invoke-Native([string]$Exe, [string[]]$Arguments, [switch]$Quiet, [int]$TimeoutSec = 0, [scriptblock]$OnLine = $null, [scriptblock]$Tick = $null) {
    $argText = (@($Arguments | ForEach-Object { Quote-Arg ([string]$_) }) -join " ")
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $argText
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    Log ("> " + $Exe + " " + $argText)
    $lines = New-Object System.Collections.Generic.List[string]
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    # 입력용 글자 객체는 콘솔 입력 인코딩을 따라 맨 앞에 BOM 을 보낸다: 잠깐 BOM 없는 인코딩으로 바꿔 두고 시작한다
    $oldInEnc = $null
    try { $oldInEnc = [Console]::InputEncoding; [Console]::InputEncoding = [System.Text.Encoding]::ASCII } catch {}
    try { [void]$proc.Start() } catch { if ($oldInEnc) { try { [Console]::InputEncoding = $oldInEnc } catch {} }; Log ("  (시작 실패: " + $_.Exception.Message + ")"); $script:LastOutput = @(); return 1 }
    if ($oldInEnc) { try { [Console]::InputEncoding = $oldInEnc } catch {} }
    $procId = $proc.Id
    try { $proc.StandardInput.BaseStream.Close() } catch {}   # 글자 쓰는 객체째로 닫으면 맨 앞에 BOM 한 글자가 들어간다
    $tOut = $proc.StandardOutput.ReadLineAsync()
    $tErr = $proc.StandardError.ReadLineAsync()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    while ($null -ne $tOut -or $null -ne $tErr) {
        $tasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
        if ($null -ne $tOut) { $tasks.Add($tOut) }
        if ($null -ne $tErr) { $tasks.Add($tErr) }
        [void][System.Threading.Tasks.Task]::WaitAny($tasks.ToArray(), 1000)
        foreach ($which in 1, 2) {
            $t = if ($which -eq 1) { $tOut } else { $tErr }
            if ($null -eq $t -or -not $t.IsCompleted) { continue }
            $line = $null
            if (-not $t.IsFaulted -and -not $t.IsCanceled) { $line = $t.Result }
            if ($null -eq $line) { if ($which -eq 1) { $tOut = $null } else { $tErr = $null }; continue }
            $lines.Add($line)
            $script:LogW.WriteLine($line)
            if (-not $Quiet) { Write-Host ("    " + $line) -ForegroundColor DarkGray }
            if ($OnLine) { try { & $OnLine $line } catch {} }
            if ($which -eq 1) { $tOut = $proc.StandardOutput.ReadLineAsync() } else { $tErr = $proc.StandardError.ReadLineAsync() }
        }
        if ($Tick) { try { & $Tick } catch {} }
        Set-Progress
        if ($TimeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            $timedOut = $true
            Log ("  (시간 초과 {0}초: PID {1} 종료)" -f $TimeoutSec, $procId)
            try { & taskkill.exe /PID $procId /T /F 2>&1 | Out-Null } catch {}
            break
        }
    }
    [void]$proc.WaitForExit(15000)
    $code = if ($timedOut) { 1 } elseif ($proc.HasExited) { $proc.ExitCode } else { 1 }
    try { $proc.Dispose() } catch {}
    $script:LastOutput = $lines.ToArray()
    Log ("  (exit $code)")
    return $code
}

# 주소 여러 개에 동시에 HEAD 를 보낸다. 응답이 왔으면(404·405 포함) 연결은 된 것. 0.5초마다 진행 파일을 갱신한다.
function Test-UrlsReachable([string[]]$urls, [int]$timeoutSec = 10) {
    $res = @{}
    $pending = @{}
    foreach ($u in $urls) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($u)
            $req.Method = "HEAD"; $req.UserAgent = "hoehwa-setup"; $req.Timeout = $timeoutSec * 1000
            $pending[$u] = @{ Req = $req; Task = $req.GetResponseAsync() }
        } catch { $res[$u] = $false }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($pending.Count -gt 0 -and $sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $tasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
        foreach ($k in @($pending.Keys)) { $tasks.Add($pending[$k].Task) }
        [void][System.Threading.Tasks.Task]::WaitAny($tasks.ToArray(), 500)
        Set-Progress
        foreach ($u in @($pending.Keys)) {
            $t = $pending[$u].Task
            if (-not $t.IsCompleted) { continue }
            if ($t.IsFaulted) { $ex = $t.Exception.InnerException; $res[$u] = (($ex -is [System.Net.WebException]) -and ($null -ne $ex.Response)) }
            elseif ($t.IsCanceled) { $res[$u] = $false }
            else { $res[$u] = $true; try { $t.Result.Close() } catch {} }
            $pending.Remove($u)
        }
    }
    foreach ($u in @($pending.Keys)) { $res[$u] = $false; try { $pending[$u].Req.Abort() } catch {} }
    return $res
}

# ------------------------------------------------------------------ 작은 도우미 (시험이 코드에서 직접 꺼내 쓴다)
# 그래픽카드 종류가 cpu 이면 NVIDIA 라이브러리 3개 줄(cuBLAS, cuDNN, nvrtc)을 뺀 잠금 파일을 만들어 그 경로를 돌려준다. nvidia 이면 원본 그대로.
function Get-EffectiveLock([string]$lock, [string]$gpuKind, [string]$outDir) {
    if ($gpuKind -ne "cpu") { return $lock }
    $drop = '^(nvidia[-_]cublas[-_]cu12|nvidia[-_]cudnn[-_]cu12|nvidia[-_]cuda[-_]nvrtc[-_]cu12)\s*(==|@)'
    $keep = @(Get-Content -LiteralPath $lock -Encoding UTF8 | Where-Object { $_ -notmatch $drop })
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $dst = Join-Path $outDir "requirements.cpu.lock.txt"
    Write-Utf8 $dst (($keep -join "`r`n") + "`r`n")
    return $dst
}
# 임시 서버 /health 가 설치 합격인가: ok, 음성 인식, 영어/일본어 목소리, 채점. AI(llm)는 요구하지 않는다 (로그인 전이 정상).
function Test-HealthGood($h) {
    if ($null -eq $h) { return $false }
    return [bool]($h.ok -and $h.stt -and $h.tts -and $h.tts.en -and $h.tts.ja -and $h.score)
}
function Get-HealthWhy($h) {
    if ($null -eq $h) { return "서버가 켜지지 않았어요." }
    if (-not $h.stt) { return "음성 인식이 준비되지 않았어요." }
    if (-not ($h.tts -and $h.tts.en -and $h.tts.ja)) { return "목소리(영어/일본어)가 준비되지 않았어요." }
    return "채점 기능이 준비되지 않았어요."
}
function Get-JavaMajor([string]$exe) {
    $code = Invoke-Native $exe @("-version") -Quiet -TimeoutSec 60
    $t = ($script:LastOutput -join "`n")
    if ($t -match 'version "(\d+)(?:\.(\d+))?') {
        $m = [int]$Matches[1]
        if ($m -eq 1 -and $Matches[2]) { $m = [int]$Matches[2] }   # 1.8 -> 8
        return $m
    }
    return 0
}
# backend\grammar.py 가 찾는 곳과 같은 규칙: backend\tools\jre*|jdk*\bin\java.exe (6단계가 여기에 푼다)
function Find-ToolsJava {
    $tools = Join-Path $Backend "tools"
    if (-not (Test-Path -LiteralPath $tools)) { return $null }
    foreach ($d in (Get-ChildItem -LiteralPath $tools -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "jre*" -or $_.Name -like "jdk*" } | Sort-Object Name -Descending)) {
        $e = Join-Path $d.FullName "bin\java.exe"
        if (Test-Path -LiteralPath $e) { return $e }
    }
    return $null
}
# install_tools.py 를 부른다 (표준 출력: TOOL <이름> OK|SKIP|FAIL ..., TOOL_RESULT OK|FAIL). 실패하면 한국어 이유와 종료 코드로 끝낸다.
function Invoke-InstallTools([string]$only, [string]$niceName) {
    $tools = Join-Path $Vendor "install_tools.py"
    $lockf = Join-Path $Vendor "tools.lock.json"
    $script:ToolFailReason = ""
    $code = Invoke-Native $Py @("-X", "utf8", $tools, $lockf, $Root, "--only", $only) -OnLine {
        $l = [string]$args[0]
        if ($l -match '^TOOL \S+ FAIL \S+ (.+)$') { $script:ToolFailReason = $Matches[1] }
        elseif ($l -match '^TOOL \S+ (OK|SKIP)') { Set-Progress -Detail ($script:ToolNice + " 확인 완료") -Frac 0.9 }
    }
    if ($code -ne 0) {
        $why = if ($script:ToolFailReason) { $script:ToolFailReason } else { "$niceName 를 받지 못했어요." }
        $c = if ($code -eq 20 -or $code -eq 30) { $code } else { 1 }
        Fail ($niceName + ": " + $why) $c
    }
    if (-not (@($script:LastOutput | Where-Object { $_ -match '^TOOL_RESULT OK' }).Count)) { Fail "$niceName 설치 결과를 확인하지 못했어요." 1 }
}

# ------------------------------------------------------------------ 단계 실행기
# 설치를 막지 않는 실패: 자세한 이유(해시·zip 등)는 install.log 에만, 사용자에게는 짧은 한국어 경고를 진행 파일(warn, detail)에 남기고 계속한다
function Soft-Fail([string]$userMsg, [string]$reason) {
    Log ("[경고 원인] " + $reason)
    Warn $userMsg
    $script:ProgWarn = (($script:ProgWarn + " " + $userMsg).Trim())
    if ($script:ProgWarn.Length -gt 300) { $script:ProgWarn = $script:ProgWarn.Substring(0, 299) + "…" }
    Set-Progress -Detail $userMsg -Force
}
function Invoke-SimStep([int]$n) {
    for ($i = 1; $i -le 4; $i++) {
        Start-Sleep -Milliseconds 250
        Set-Progress -Detail ("(시뮬레이션) {0}/4" -f $i) -Frac ($i / 4.0)
    }
}
function Step([int]$n, [scriptblock]$Body, [switch]$Always, [switch]$RealInSimulation) {
    $def = $StepDefs[$n - 1]
    $script:CurStep = $n
    $script:StepTitle = $def.Title
    Say ""
    Say ("[{0}/{1}] {2}" -f $n, $TotalSteps, $def.Name) "Cyan"
    $endPct = [math]::Min(99, $def.Start + $def.Weight)
    if ($FailStep -eq $n -and -not $def.Soft) {
        Set-Progress -Detail "(시험) 실패를 흉내냅니다" -Frac 0 -Force
        Log "(시험 훅) HOEHWA_SETUP_FAIL_STEP=$n"
        Fail ("(시험) {0}단계 실패를 흉내 냈어요." -f $n) $def.Code
    }
    $marker = Join-Path $StateDir ("{0:00}-{1}.ok" -f $n, $def.Key)
    if (-not $Always -and (Test-Path -LiteralPath $marker)) {
        Say "    이미 끝난 단계입니다. 건너뜁니다." "Green"
        Set-Progress -Detail "이미 끝난 단계" -Frac 0.99 -Force
        if ($script:Pct -lt $endPct) { $script:Pct = $endPct }
        $script:Timings.Add([pscustomobject]@{ N = $n; Title = $def.Name; Sec = 0; Result = "건너뜀" })
        return
    }
    Set-Progress -Detail $def.Title -Frac 0 -Force
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $softFailed = $false
    try {
        if ($FailStep -eq $n) { Log "(시험 훅) HOEHWA_SETUP_FAIL_STEP=$n (이 단계는 실패해도 설치를 막지 않음)"; Fail "(시험) 해시 불일치를 흉내 냈어요." 30 }
        if ($Simulate -and -not $RealInSimulation) { Say "    (시뮬레이션) 실제 작업 대신 1초 기다립니다." "Yellow"; Invoke-SimStep $n } else { & $Body }
    } catch {
        if (-not $def.Soft) { throw }
        $script:FailCode = 0
        Soft-Fail $def.WarnMsg $_.Exception.Message
        $softFailed = $true
    }
    $sw.Stop()
    if (-not $Always) {
        New-Item -ItemType Directory -Force $StateDir | Out-Null
        Write-Utf8 $marker (Get-Date -Format "o")
    }
    if ($script:Pct -lt $endPct) { $script:Pct = $endPct }
    Set-Progress -Force
    Say ("    완료 ({0:N0}초)" -f $sw.Elapsed.TotalSeconds) "Green"
    $script:Timings.Add([pscustomobject]@{ N = $n; Title = $def.Name; Sec = [math]::Round($sw.Elapsed.TotalSeconds); Result = $(if ($softFailed) { "경고(건너뜀)" } else { "완료" }) })
}

# =================================================================== -DryRun: 계획만 출력
Log "==================== 설치 시작 ===================="
Log ("폴더: $Root  / 사용자: $env:USERNAME / PS $($PSVersionTable.PSVersion)")
foreach ($legacy in @(@("Yes", "-Yes"), @("Engine", "-Engine"), @("NoShortcut", "-NoShortcut"))) {
    if ($PSBoundParameters.ContainsKey($legacy[0])) { Say ("옛 인자 {0}: 무시됨 (이제 질문이 없습니다)" -f $legacy[1]) "Gray" }
}
if ($DryRun) {
    Say "=============================================" "Cyan"
    Say "   회화 연습 설치 - 계획 보기 (아무것도 설치하지 않습니다)" "Cyan"
    Say "=============================================" "Cyan"
    $plan = @(
        "점검: 윈도우 64비트, 경로 길이(95자), 디스크 여유(NVIDIA 14GB / 그 외 10GB, 임시 폴더 3GB), 인터넷(pypi, github, huggingface), 그래픽카드 감지 -> runtime\.state\gpu.txt",
        "파이썬 3.10.11 포터블을 vendor 의 zip 에서 풀기 (SHA256 확인)",
        "pip 를 고정 버전으로 준비",
        "파이썬 패키지를 잠금 파일과 똑같이 설치 (NVIDIA 그래픽카드가 없으면 cuBLAS, cuDNN, nvrtc 약 2GB 제외)",
        "OpenCode 받기: install_tools.py --only opencode (GitHub 릴리스 zip, SHA256 확인, AVX2 없는 PC 는 baseline 판) -> backend\tools\opencode",
        "JRE 받기: install_tools.py --only jre (Temurin 21 JRE zip, SHA256 확인) -> backend\tools",
        "음성 모델 받기 (Whisper small, Kokoro-82M 등, 파일마다 크기와 SHA256 확인)",
        "나머지 데이터 준비 (일본어 사전, 목소리, 음성 인식 장치 확인)",
        "문법 검사기 LanguageTool 받기 (SHA256 확인, Java 는 6단계가 준비)",
        "설정: backend\config.json 의 llm_provider=opencode, NVIDIA 없으면 stt 를 cpu/int8 로, 학습 기록 기본값 복사(있으면 그대로)",
        "동작 확인: 임시 서버 /health 에서 음성 인식, 영어/일본어 목소리, 채점이 OK 면 합격 (AI 연결은 요구하지 않음)"
    )
    for ($i = 0; $i -lt $plan.Count; $i++) {
        Say ("[DryRun] {0}/{1} {2}" -f ($i + 1), $TotalSteps, $plan[$i]) "Yellow"
    }
    Say "계획 출력 끝. 아무것도 설치하지 않았습니다." "Green"
    Log "==================== 설치 종료 (코드 0, 계획만) ===================="
    $script:LogW.Close()
    exit 0
}

# =================================================================== 본문
$exitCode = 0
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
$script:GpuKind = ""
try {
    Set-Progress -Detail "설치를 시작합니다" -Force
    Say "=============================================" "Cyan"
    Say "   회화 연습 설치 (영어 / 일본어)" "Cyan"
    Say "=============================================" "Cyan"
    Say "설치 폴더: $Root"
    Say "자세한 기록은 install.log 에 남습니다. 중간에 멈춰도 다시 실행하면 이어서 진행합니다."
    if ($Simulate) { Say "[시험] HOEHWA_SETUP_SIMULATE=1: 2~9, 11단계는 실제 작업 대신 시뮬레이션합니다." "Yellow" }
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    # 옛 방식(엔진 선택)이 남긴 표시 파일은 지운다. 옛 단계 표시(05-node.ok 등)는 새 키와 달라 그냥 무시된다.
    foreach ($old in @("engine.txt", "engine-config.ok", "engine-pending.ok")) {
        $op = Join-Path $StateDir $old
        if (Test-Path -LiteralPath $op) { Remove-Item -LiteralPath $op -Force -ErrorAction SilentlyContinue; Log "옛 상태 파일 삭제: $old" }
    }

    # ---------------------------------------------------------------- 1. 사전 점검
    Step 1 -Always -RealInSimulation {
        if (-not [Environment]::Is64BitOperatingSystem) { Fail "64비트 윈도우가 필요해요." 10 }
        if ([Environment]::OSVersion.Version.Major -lt 10) { Fail "윈도우 10 이상이 필요해요." 10 }
        Info ("윈도우 " + [Environment]::OSVersion.Version + " (64비트) 확인")

        foreach ($f in @("회화연습.exe", "manifest.json", "backend\server.py", "backend\curriculum.json", "backend\config.json",
                         "vendor\vendor.json", "vendor\requirements.lock.txt", "vendor\bootstrap.lock.txt",
                         "vendor\models.lock.json", "vendor\install_models.py", "vendor\install_tools.py", "vendor\tools.lock.json",
                         "vendor\check_env.py", "vendor\update_helper.py")) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $f))) {
                Fail "설치 파일이 빠져 있어요: $f (setup.exe 를 다시 받아 실행해 주세요)" 10
            }
        }
        if ($Root -like "\\*") { Fail "네트워크 경로에는 설치할 수 없어요. 내 컴퓨터의 폴더를 쓰세요." 10 }
        Set-Progress -Detail "파일 확인 완료" -Frac 0.2
        # 인터넷에서 받은 zip 의 '차단' 표시 제거 (zip 으로 풀었을 때 SmartScreen 경고 방지)
        Get-ChildItem -LiteralPath $Root -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike "*\runtime\*" -and $_.FullName -notlike "*\models\*" } |
            Unblock-File -ErrorAction SilentlyContinue

        # 경로 길이: 윈도우 기본 설정은 260자 제한이라 설치 폴더 이름이 길면 파이썬 패키지가 깨진다
        $lp = 0
        try { $lp = [int](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -ErrorAction Stop).LongPathsEnabled } catch {}
        $hk = Get-Hook "HOEHWA_TEST_LONGPATHS"
        if ($hk -match '^[01]$') { $lp = [int]$hk; Log "(시험 훅) HOEHWA_TEST_LONGPATHS=$hk" }
        Info ("설치 폴더 경로 길이: {0}자 (긴 경로 지원: {1})" -f $Root.Length, $(if ($lp -eq 1) { "켜짐" } else { "꺼짐" }))
        if ($Root.Length -gt 95 -and $lp -ne 1) {
            Fail ("설치 폴더 경로가 너무 길어요 ({0}자, 최대 95자). C:\회화연습 처럼 짧은 폴더를 쓰세요." -f $Root.Length) 10
        }

        # 그래픽카드 (디스크 요구량이 달라지므로 먼저)
        $kind = $Gpu
        if ($Gpu -eq "auto") {
            $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "NVIDIA" })
            if ($gpus.Count -gt 0) { $kind = "nvidia"; Info ("NVIDIA 그래픽카드: " + $gpus[0].Name + " -> 음성 인식을 GPU 로 빠르게 돌립니다") }
            else { $kind = "cpu"; Info "NVIDIA 그래픽카드가 없습니다 -> 음성 인식이 CPU 로 동작합니다 (조금 느립니다). NVIDIA 전용 라이브러리(약 2GB)는 설치하지 않습니다." }
        } else { Info ("그래픽카드 종류를 직접 지정: -Gpu $Gpu") }
        $gpuFile = Join-Path $StateDir "gpu.txt"
        $prevKind = if (Test-Path -LiteralPath $gpuFile) { ("" + (Get-Content -LiteralPath $gpuFile -Raw -ErrorAction SilentlyContinue)).Trim() } else { "" }
        if ($prevKind -and $prevKind -ne $kind) {
            Info "그래픽카드 종류가 바뀌었습니다 ($prevKind -> $kind). 패키지 단계를 다시 합니다."
            foreach ($mk in @("04-packages.ok", "08-prefetch.ok")) { Remove-Item -LiteralPath (Join-Path $StateDir $mk) -Force -ErrorAction SilentlyContinue }
        }
        Write-Utf8 $gpuFile $kind
        $script:GpuKind = $kind
        Set-Progress -Detail "그래픽카드 확인 완료" -Frac 0.4

        # 디스크 여유 공간: 설치 드라이브 14GB(NVIDIA)/10GB(그 밖) + 임시 폴더 드라이브 3GB
        $needGb = if ($kind -eq "nvidia") { 14 } else { 10 }
        $drv = New-Object System.IO.DriveInfo($Root.Substring(0, 1))
        $freeGb = [math]::Round($drv.AvailableFreeSpace / 1GB, 1)
        $tmpDrv = New-Object System.IO.DriveInfo(([System.IO.Path]::GetTempPath()).Substring(0, 1))
        $tmpFreeGb = [math]::Round($tmpDrv.AvailableFreeSpace / 1GB, 1)
        $hk = Get-Hook "HOEHWA_TEST_FREE_GB"
        if ($hk -match '^[0-9.]+$') { $freeGb = [double]$hk; $tmpFreeGb = [double]$hk; Log "(시험 훅) HOEHWA_TEST_FREE_GB=$hk" }
        Info ("설치 드라이브 {0} 여유 공간: {1} GB (필요 {2} GB 이상), 임시 폴더 드라이브 {3}: {4} GB (필요 3 GB 이상)" -f $drv.Name, $freeGb, $needGb, $tmpDrv.Name, $tmpFreeGb)
        $resuming = (Test-Path -LiteralPath $Py)
        if ($freeGb -lt $needGb) {
            if (-not $resuming) { Fail ("디스크 여유 공간이 부족해요 ({0} GB). {1} GB 이상 비워 주세요." -f $freeGb, $needGb) 10 }
            Warn "디스크 여유 공간이 $needGb GB 보다 적습니다 ($freeGb GB). 이미 설치가 진행된 상태라 계속합니다."
        }
        if ($tmpFreeGb -lt 3) { Fail ("임시 폴더 드라이브의 여유 공간이 부족해요 ({0} GB). 3 GB 이상 비워 주세요." -f $tmpFreeGb) 10 }
        Set-Progress -Detail "디스크 확인 완료" -Frac 0.55

        # 인터넷: 아직 받을 것이 남은 곳만 필수
        $hosts = New-Object System.Collections.Generic.List[string]
        $toolsDone = (Test-Path -LiteralPath (Join-Path $Backend "tools\opencode\opencode.exe")) -and (Find-ToolsJava)
        if (-not (Test-Path -LiteralPath (Join-Path $StateDir "04-packages.ok"))) { $hosts.Add("pypi.org") }
        if (-not $toolsDone) { $hosts.Add("github.com") }
        if (-not (Test-Path -LiteralPath (Join-Path $StateDir "07-models.ok"))) { $hosts.Add("huggingface.co") }
        $net = @{}
        if ((Get-Hook "HOEHWA_TEST_NET") -eq "skip") { Log "(시험 훅) HOEHWA_TEST_NET=skip: 인터넷 점검을 건너뜁니다."; foreach ($h in $hosts) { $net[$h] = $true } }
        else {
            $r = Test-UrlsReachable @($hosts | ForEach-Object { "https://" + $_ }) 10
            foreach ($h in $hosts) { $net[$h] = [bool]$r["https://" + $h] }
        }
        $nf = Get-Hook "HOEHWA_TEST_NET_FAIL"
        if ($nf) { foreach ($h in @($nf -split ",")) { if ($net.ContainsKey($h.Trim())) { $net[$h.Trim()] = $false; Log "(시험 훅) HOEHWA_TEST_NET_FAIL: $h" } } }
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($h in $hosts) {
            Info ("인터넷 연결 {0}: {1}" -f $h, $(if ($net[$h]) { "OK" } else { "안 됨" }))
            if (-not $net[$h]) { $bad.Add($h) }
        }
        if ($bad.Count -gt 0) { Fail ("인터넷에 연결할 수 없어요: " + ($bad -join ", ") + ". 연결을 확인한 뒤 다시 실행해 주세요.") 20 }
    }

    # ---------------------------------------------------------------- 2. 파이썬
    Step 2 {
        $vj = Get-Content -LiteralPath (Join-Path $Vendor "vendor.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $zip = Join-Path $Vendor $vj.python.file
        if (-not (Test-Path -LiteralPath $zip)) { Fail "vendor\$($vj.python.file) 가 없어요." 10 }
        $h = Get-Sha256 $zip
        if ($h -ne $vj.python.sha256) { Fail "파이썬 압축 파일이 손상되었어요 (SHA256 불일치)." 30 }
        Info "SHA256 확인 OK"
        if (Test-Path -LiteralPath $PyDir) { Remove-Item -LiteralPath $PyDir -Recurse -Force }
        New-Item -ItemType Directory -Force $Runtime | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $PyDir)
        $pth = Get-ChildItem -LiteralPath $PyDir -Filter "python*._pth" | Select-Object -First 1
        if (-not $pth) { Fail "python._pth 파일을 찾지 못했어요." 1 }
        $zipName = ($pth.BaseName -replace "\._pth$", "") + ".zip"
        $lines = @($zipName, ".", "Lib\site-packages", "..\..\backend", "", "import site")
        Write-Utf8 $pth.FullName (($lines -join "`r`n") + "`r`n")
        New-Item -ItemType Directory -Force (Join-Path $PyDir "Lib\site-packages") | Out-Null
        $code = Invoke-Native $Py @("-X", "utf8", "-c", "import sys, ssl, ctypes, sqlite3, site; print(sys.version); print(sys.path)") -Quiet
        if ($code -ne 0) { Fail "내장 파이썬이 실행되지 않아요 (Visual C++ 재배포 패키지가 없거나 백신이 막았을 수 있어요)." 1 }
        Info ("파이썬 실행 확인: " + $script:LastOutput[0])
    }

    # ---------------------------------------------------------------- 3. pip
    Step 3 {
        $boot = @(Get-Content -LiteralPath (Join-Path $Vendor "bootstrap.lock.txt") -Encoding UTF8 | Where-Object { $_.Trim() -ne "" })
        Info ("고정 버전: " + ($boot -join ", "))
        $getpip = Join-Path $Vendor "get-pip.py"
        $vj = Get-Content -LiteralPath (Join-Path $Vendor "vendor.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Get-Sha256 $getpip) -ne $vj.getpip.sha256) { Fail "vendor\get-pip.py 가 손상되었어요 (SHA256 불일치)." 30 }
        $env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
        $env:PIP_NO_INPUT = "1"
        if ($TestMode -and $env:HOEHWA_PIP_DRYRUN -eq "1") { Info "(시험) pip 를 실행하지 않습니다."; return }
        $pipArgs = @("-X", "utf8", $getpip) + $boot + @("--no-wheel", "--no-warn-script-location", "--no-cache-dir")
        $code = Invoke-Native $Py $pipArgs
        if ($code -ne 0) { Fail "pip 를 설치하지 못했어요. 인터넷 연결을 확인해 주세요." 20 }
        $null = Invoke-Native $Py @("-X", "utf8", "-m", "pip", "--version") -Quiet
        Info ($script:LastOutput -join " ")
    }

    # ---------------------------------------------------------------- 4. 패키지
    Step 4 {
        $env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
        $env:PIP_NO_INPUT = "1"
        $env:PIP_NO_CACHE_DIR = "1"   # 다운로드 캐시를 남기지 않는다
        $lock = Get-EffectiveLock (Join-Path $Vendor "requirements.lock.txt") $script:GpuKind $StateDir
        if ($script:GpuKind -eq "cpu") { Info "NVIDIA 그래픽카드가 없어 cuBLAS, cuDNN, nvrtc 는 설치하지 않습니다." }
        $wheels = Join-Path $Vendor "wheels"
        $n = @(Get-Content -LiteralPath $lock -Encoding UTF8 | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") }).Count
        $script:PkgTotal = [math]::Max(1, $n)
        $script:PkgSeen = 0
        Info "$n 개 패키지를 개발 PC 와 똑같은 버전으로 설치합니다. 10~30분 걸릴 수 있습니다."
        $pipArgs = @("-X", "utf8", "-m", "pip", "install", "--no-deps", "--no-cache-dir", "--no-warn-script-location",
                  "--progress-bar", "off", "--disable-pip-version-check", "-r", $lock)
        if (Test-Path -LiteralPath $wheels) { $pipArgs += @("--find-links", $wheels) }
        if ((Get-Content -LiteralPath $lock -Raw) -match "\+cpu") { $pipArgs += @("--extra-index-url", "https://download.pytorch.org/whl/cpu") }
        $dry = ($TestMode -and $env:HOEHWA_PIP_DRYRUN -eq "1")
        if ($dry) { Info "(시험) pip 를 실행하지 않습니다." }
        else {
            $ok = $false
            for ($try = 1; $try -le 3 -and -not $ok; $try++) {
                if ($try -gt 1) { Warn "다시 시도합니다 ($try/3)..."; Start-Sleep -Seconds 5 }
                $script:PkgSeen = 0
                $code = Invoke-Native $Py $pipArgs -OnLine {
                    $l = [string]$args[0]
                    if ($l -match '^Collecting ') {
                        $script:PkgSeen++
                        Set-Progress -Detail ("패키지 받는 중 ({0}/{1})" -f [math]::Min($script:PkgSeen, $script:PkgTotal), $script:PkgTotal) -Frac (0.9 * [math]::Min($script:PkgSeen, $script:PkgTotal) / $script:PkgTotal)
                    }
                    elseif ($l -match '^Installing collected packages') { Set-Progress -Detail "패키지 설치하는 중" -Frac 0.92 }
                    elseif ($l -match '^Successfully installed') { Set-Progress -Detail "패키지 설치 끝, 확인하는 중" -Frac 0.97 }
                }
                if ($code -eq 0) { $ok = $true }
            }
            if (-not $ok) { Fail "파이썬 패키지를 설치하지 못했어요. 인터넷 연결 상태에서 다시 실행해 주세요." 40 }
            $null = Invoke-Native $Py @("-X", "utf8", "-m", "pip", "check") -Quiet
            Log ("pip check: " + ($script:LastOutput -join " | "))
        }
        Set-Progress -Detail "설치된 패키지 목록 확인 중" -Frac 0.98
        $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "check_env.py"), (Join-Path $Vendor "requirements.lock.txt"), (Join-Path $Vendor "bootstrap.lock.txt"), "--gpu", $script:GpuKind)
        if ($code -ne 0) { Fail "설치된 패키지가 개발 PC 목록과 달라요 (install.log 참고)." 40 }
        Info "설치된 패키지 목록이 개발 PC 와 완전히 같습니다."
    }

    # ---------------------------------------------------------------- 5. OpenCode (매번 확인: 같은 버전이면 install_tools 가 바로 SKIP)
    Step 5 -Always {
        $script:ToolNice = "OpenCode"
        Invoke-InstallTools "opencode" "OpenCode"
        $oc = Join-Path $Backend "tools\opencode\opencode.exe"
        if (-not (Test-Path -LiteralPath $oc)) { Fail "OpenCode 실행 파일(opencode.exe)을 찾지 못했어요." 1 }
        # 첫 실행은 백신 검사로 느리다: 미리 한 번 실행해 둔다 (실패해도 설치는 계속)
        $code = Invoke-Native $oc @("--version") -Quiet -TimeoutSec 90
        if ($code -eq 0) { Info ("OpenCode " + (($script:LastOutput | Select-Object -First 1) -as [string])) }
        else { Warn "OpenCode 를 한 번 실행해 보지 못했습니다. 앱에서 [AI 연결하기]를 누를 때 다시 확인합니다." }
    }

    # ---------------------------------------------------------------- 6. JRE
    Step 6 -Always {
        $script:ToolNice = "자바(JRE)"
        Invoke-InstallTools "jre" "자바(JRE)"
        $j = Find-ToolsJava
        if (-not $j) { Fail "자바 실행 파일(java.exe)을 찾지 못했어요." 1 }
        $maj = Get-JavaMajor $j
        if ($maj -ge 17) { Info ("자바 $maj 확인: $j") } else { Warn "자바를 풀었지만 실행해 보지 못했습니다. 문법 검사기가 꺼질 수 있어요." }
    }

    # ---------------------------------------------------------------- 7. 음성 모델
    Step 7 {
        New-Item -ItemType Directory -Force $HfDir | Out-Null
        $mlock = Get-Content -LiteralPath (Join-Path $Vendor "models.lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:RepoTotal = [math]::Max(1, @($mlock.hf).Count)
        $script:RepoDone = 0
        $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "install_models.py"), (Join-Path $Vendor "models.lock.json"), $HfDir) -OnLine {
            $l = [string]$args[0]
            if ($l -match '^\s*\[(OK|FAIL)\]') { $script:RepoDone++; Set-Progress -Detail ("음성 모델 {0}/{1} 확인" -f [math]::Min($script:RepoDone, $script:RepoTotal), $script:RepoTotal) -Frac ([math]::Min($script:RepoDone, $script:RepoTotal) / $script:RepoTotal) }
            elseif ($l -match '^\s*\.\.\. ([\d.]+) MB / ([\d.]+) MB') {
                $fr = if ([double]$Matches[2] -gt 0) { [double]$Matches[1] / [double]$Matches[2] } else { 0 }
                Set-Progress -Detail ("음성 모델 받는 중 ({0}/{1}) {2:N0} MB" -f ($script:RepoDone + 1), $script:RepoTotal, [double]$Matches[1]) -Frac (($script:RepoDone + [math]::Min(1.0, $fr)) / $script:RepoTotal)
            }
        }
        if ($code -ne 0) {
            $mm = (($script:LastOutput -join "`n") -match "sha256 mismatch")
            Fail "음성 모델을 받거나 검증하지 못했어요 (install.log 의 [FAIL] 줄 참고). 다시 실행하면 이어서 받아요." $(if ($mm) { 30 } else { 50 })
        }
        # 받기에만 쓰는 임시 캐시(xet, .locks)는 지운다. 목록에 없는 모델은 건드리지 않는다고 확인된 것만 지운다.
        $null = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "prunehf", (Join-Path $Vendor "models.lock.json"), $HfDir, "--apply") -Quiet
        Info ((@($script:LastOutput | Where-Object { $_ -like "PRUNE_RESULT*" }) | Select-Object -Last 1))
    }

    # ---------------------------------------------------------------- 8. prefetch
    Step 8 {
        $mlock = Get-Content -LiteralPath (Join-Path $Vendor "models.lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:PfSeen = 0
        $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Backend "server.py"), "--prefetch") -OnLine {
            if ([string]$args[0] -match '^\[prefetch\] .* OK') { $script:PfSeen++; Set-Progress -Detail ("데이터 준비 {0}/4" -f [math]::Min($script:PfSeen, 4)) -Frac ([math]::Min($script:PfSeen, 4) / 4.0) }
        }
        $txt = $script:LastOutput -join "`n"
        foreach ($needle in @("[prefetch] Whisper OK", "[prefetch] Kokoro en OK", "[prefetch] Kokoro ja OK", "[prefetch] pyopenjtalk OK")) {
            if (-not $txt.Contains($needle)) { Fail "준비 단계에서 '$needle' 를 확인하지 못했어요 (install.log 참고)." 50 }
        }
        if ($code -ne 0) { Fail "데이터 준비가 오류로 끝났어요 (종료 코드 $code)." 50 }
        $m = [regex]::Match($txt, "Whisper OK on (\S+)")
        if ($m.Success) { Info ("음성 인식 장치: " + $m.Groups[1].Value) }
        $mustExist = @()
        foreach ($e in $mlock.hf) {
            $base = if ($e.cache_subdir) { Join-Path $HfDir $e.cache_subdir } else { $HfDir }
            foreach ($f in $e.files) {
                $mustExist += (Join-Path $base ("models--" + ($e.repo_id -replace "/", "--") + "\snapshots\" + $e.revision + "\" + ($f.path -replace "/", "\")))
            }
        }
        $missing = @($mustExist | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($missing.Count -gt 0) { Fail ("모델 파일이 없어요: " + $missing[0]) 50 }
        Info ("모델 파일 {0}개 존재 확인" -f $mustExist.Count)
    }

    # ---------------------------------------------------------------- 9. LanguageTool (실패해도 경고만: 문법 교정은 AI 가 대신한다)
    Step 9 -Always {
        $mlock = Get-Content -LiteralPath (Join-Path $Vendor "models.lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $lt = $mlock.languagetool
        if (-not $lt) { Info "설치 패키지에 LanguageTool 정보가 없어 건너뜁니다 (문법 교정은 AI 가 합니다)."; return }
        $ltRoot = Join-Path $Backend "tools\languagetool"
        $jar = Join-Path $ltRoot ($lt.dir + "\languagetool-server.jar")
        $manifest = Join-Path $ltRoot "lt.json"
        $have = $null
        if ((Test-Path -LiteralPath $jar) -and (Test-Path -LiteralPath $manifest)) {
            try { $have = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        }
        if ($have -and $have.sha256 -eq $lt.sha256) { Info ("LanguageTool {0} 이(가) 이미 설치되어 있습니다." -f $lt.version) }
        else {
            New-Item -ItemType Directory -Force $ltRoot | Out-Null
            $zip = Join-Path $env:TEMP ("LanguageTool-{0}-{1}.zip" -f $lt.version, $PID)   # 프로세스마다 다른 이름
            $tmpDir = Join-Path $ltRoot "_extract"
            $script:LtZip = $zip; $script:LtSize = [double]$lt.size
            try {   # 아래 어디서 실패하든 finally 에서 받은 zip 과 _extract 폴더를 지운다
                Info ("다운로드: {0} ({1:N0} MB)" -f $lt.url, ($lt.size / 1MB))
                $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
                $ok = $false
                for ($try = 1; $try -le 3 -and -not $ok; $try++) {
                    if ($try -gt 1) { Warn "다시 시도합니다 ($try/3)..."; Start-Sleep -Seconds 5 }
                    try {
                        if ($curl) {
                            $code = Invoke-Native $curl.Source @("-L", "--fail", "--retry", "3", "-sS", "-o", $zip, $lt.url) -Quiet -Tick {
                                if (Test-Path -LiteralPath $script:LtZip) {
                                    $got = (Get-Item -LiteralPath $script:LtZip).Length
                                    Set-Progress -Detail ("문법 검사기 받는 중 {0:N0} / {1:N0} MB" -f ($got / 1MB), ($script:LtSize / 1MB)) -Frac ($got / $script:LtSize)
                                }
                            }
                            $ok = ($code -eq 0)
                        }
                        else { (New-Object Net.WebClient).DownloadFile($lt.url, $zip); $ok = $true }
                    } catch { Log ("다운로드 오류: " + $_.Exception.Message) }
                }
                if (-not $ok) { Warn "LanguageTool 을 받지 못했습니다. 문법 교정은 AI 가 합니다 (다시 실행하면 다시 시도합니다)."; return }
                $h = Get-Sha256 $zip
                if ($h -ne $lt.sha256 -or (Get-Item -LiteralPath $zip).Length -ne [int64]$lt.size) {
                    Warn "받은 LanguageTool 파일이 개발 PC 의 것과 다릅니다 (SHA256 불일치). 보안을 위해 설치하지 않습니다. 문법 교정은 AI 가 합니다."
                    return
                }
                Info "SHA256 확인 OK"
                Set-Progress -Detail "문법 검사기 압축 푸는 중" -Frac 0.9
                if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
                [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmpDir)
                $dst = Join-Path $ltRoot $lt.dir
                if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
                Move-Item -LiteralPath (Join-Path $tmpDir $lt.dir) -Destination $dst
                if (-not (Test-Path -LiteralPath $jar)) { Warn "LanguageTool 압축을 풀었지만 languagetool-server.jar 가 없습니다."; return }
                Write-Utf8 $manifest ([pscustomobject]@{ version = $lt.version; dir = $lt.dir; url = $lt.url; sha256 = $lt.sha256; size = $lt.size } | ConvertTo-Json)
                Info ("LanguageTool {0} 설치 완료" -f $lt.version)
            } finally {
                if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
        # 서버가 같은 규칙으로 자바를 찾는지 확인 (자바는 6단계가 backend\tools 에 풀어 두었다)
        $code = Invoke-Native $Py @("-X", "utf8", "-c", "import grammar; j = grammar.find_java(); print('JAVA=' + (j or '') + ' ' + (grammar._java.get('version') or ''))") -Quiet
        $jline = ($script:LastOutput | Where-Object { $_ -like "JAVA=*" } | Select-Object -First 1)
        if ($code -eq 0 -and $jline -and $jline -ne "JAVA= ") { Info ("서버가 찾는 Java: " + $jline.Substring(5)) }
        else { Warn "서버가 Java 17 이상을 찾지 못했습니다. 문법 검사기가 꺼지고, 그동안은 AI 가 문법을 고칩니다." }
    }

    # ---------------------------------------------------------------- 10. 설정
    Step 10 -Always -RealInSimulation {
        # backend\config.json: llm_provider 는 opencode (앱에서 openai_api 를 고른 설치는 그대로), NVIDIA 가 없으면 음성 인식을 cpu/int8 로
        $cfgPath = Join-Path $Backend "config.json"
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $changed = $false
        $cur = if ($cfg.PSObject.Properties.Name -contains "llm_provider") { "" + $cfg.llm_provider } else { "" }
        if (@("opencode", "openai_api") -notcontains $cur) {
            if ($cfg.PSObject.Properties.Name -contains "llm_provider") { $cfg.llm_provider = "opencode" } else { $cfg | Add-Member -NotePropertyName "llm_provider" -NotePropertyValue "opencode" }
            $changed = $true; Info "config.json: llm_provider = opencode"
        } else { Info ("config.json: llm_provider = " + $cur + " (그대로)") }
        if ($script:GpuKind -eq "cpu") {
            if (-not ($cfg.PSObject.Properties.Name -contains "stt") -or $null -eq $cfg.stt) { $cfg | Add-Member -NotePropertyName "stt" -NotePropertyValue ([pscustomobject]@{}) -Force }
            foreach ($kv in @(@("device", "cpu"), @("compute_type", "int8"))) {
                if ($cfg.stt.PSObject.Properties.Name -contains $kv[0]) { if ($cfg.stt.($kv[0]) -ne $kv[1]) { $cfg.stt.($kv[0]) = $kv[1]; $changed = $true } }
                else { $cfg.stt | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1]; $changed = $true }
            }
            Info "config.json: stt.device = cpu, stt.compute_type = int8 (NVIDIA 그래픽카드 없음)"
        }
        if ($changed) { Write-Utf8 $cfgPath ($cfg | ConvertTo-Json -Depth 8) }
        # 학습 기록/설정 기본값: 이미 있으면 그대로 둔다
        $dataDir = Join-Path $env:APPDATA "Godot\app_userdata\회화 연습"
        $hk = Get-Hook "HOEHWA_USERDATA_DIR"
        if ($hk) { $dataDir = $hk; Log "(시험 훅) HOEHWA_USERDATA_DIR=$hk" }
        New-Item -ItemType Directory -Force $dataDir | Out-Null
        foreach ($name in @("prefs.json", "progress.json")) {
            $src = Join-Path $Root ("defaults\" + $name)
            $dst = Join-Path $dataDir $name
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if (Test-Path -LiteralPath $dst) { Info "$name : 이미 있어서 그대로 둡니다." }
            else { Copy-Item -LiteralPath $src -Destination $dst; Info "$name : 기본값을 복사했습니다." }
        }
    }

    # ---------------------------------------------------------------- 11. 동작 확인 (AI 연결은 요구하지 않는다: 로그인 전이 정상)
    Step 11 -Always {
        $port = $TestPort
        for ($p = $TestPort; $p -lt $TestPort + 50; $p++) {
            try { $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p); $l.Start(); $l.Stop(); $port = $p; break } catch {}
        }
        Info "임시 서버 포트: $port"
        $srv = Join-Path $Backend "server.py"
        $proc = Start-Process -FilePath $PyW -ArgumentList @("`"$srv`"", "--port", "$port", "--tag", "install") `
                    -WorkingDirectory $Backend -WindowStyle Hidden -PassThru
        $good = $false; $last = $null
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 300) {
                Start-Sleep -Seconds 1
                Set-Progress -Detail ("서버 준비 확인 중 ({0}초)" -f [int]$sw.Elapsed.TotalSeconds) -Frac ([math]::Min(0.9, $sw.Elapsed.TotalSeconds / 120.0))
                if ($proc.HasExited) { break }
                if (([int]$sw.Elapsed.TotalSeconds) % 2 -ne 0) { continue }
                try {
                    $h = Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 5
                    $last = $h
                    if (Test-HealthGood $h) { $good = $true; break }
                } catch {}
                if (([int]$sw.Elapsed.TotalSeconds) % 10 -lt 2) { Info ("서버 준비 중... {0}초" -f [int]$sw.Elapsed.TotalSeconds) }
            }
        } finally {
            if ($proc -and -not $proc.HasExited) { $null = Invoke-Native "taskkill.exe" @("/PID", "$($proc.Id)", "/T", "/F") -Quiet }
        }
        if ($last) { Log ("마지막 /health: " + ($last | ConvertTo-Json -Compress)) }
        if (-not $good) {
            $lg = Join-Path $Backend "logs\server-install.log"
            if (Test-Path $lg) { Log "---- server-install.log (끝부분) ----"; Get-Content $lg -Tail 25 -Encoding UTF8 | ForEach-Object { Log $_ } }
            Fail ("동작 확인에 실패했어요: " + (Get-HealthWhy $last)) 60
        }
        Info ("/health 정상: 음성 인식 OK, 목소리(영어/일본어) OK, 채점 {0}" -f $last.score)
        if (-not $last.llm) { Info "AI 는 아직 연결되지 않았어요 (정상입니다). 앱에서 [AI 연결하기]를 한 번 하면 됩니다." }
        Info ("문법 검사기(LanguageTool): " + $(if ($last.grammar) { "사용" } else { "꺼짐 (AI 가 문법을 고칩니다)" }))
    }

    # ---------------------------------------------------------------- 끝: 설치된 버전 기록 (state=done 은 이게 끝난 뒤에만)
    $mf = Join-Path $Root "manifest.json"
    $man = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $man.version) { Fail "manifest.json 에 버전이 없어요." 1 }
    $iv = if ($null -ne $man.installer_version) { "" + $man.installer_version } else { "2" }
    Write-Utf8 (Join-Path $StateDir "installer_version.txt") $iv
    Write-Utf8 (Join-Path $Root "version.txt") ($man.version + "`r`n")
    Say ("설치된 버전: v" + $man.version)
    $script:CurStep = $TotalSteps
    $script:StepTitle = "설치 완료"
    Set-Progress -Detail "설치가 끝났어요" -State done -Force
}
catch {
    $stepCode = $StepDefs[[math]::Max(0, [math]::Min($TotalSteps, $script:CurStep) - 1)].Code
    $exitCode = if ($script:FailCode -gt 0) { $script:FailCode } else { $stepCode }
    $errLine = Format-ErrorLine $_.Exception.Message
    Say "" "Red"
    Say "[설치 실패] $($_.Exception.Message)" "Red"
    Log ("스택: " + $_.ScriptStackTrace)
    Say "해결 방법: 위 메시지를 확인하고 (인터넷 연결 등) 다시 실행해 주세요. 끝난 단계는 건너뜁니다." "Yellow"
    Say "문제가 계속되면 install.log 파일을 보내 주세요: $LogFile" "Yellow"
    Set-Progress -Detail $errLine -State error -Err $errLine -Code $exitCode -Force
}

$totalSw.Stop()
Say ""
Say "---------------- 단계별 소요 시간 ----------------" "Cyan"
foreach ($t in $script:Timings) { Say ("  {0,2}. {1}  [{2}] {3} 초" -f $t.N, $t.Title, $t.Result, $t.Sec) }
Say ("  합계: {0:N0} 초" -f $totalSw.Elapsed.TotalSeconds)
if ($script:Warnings.Count -gt 0) {
    Say ""
    Say "주의 사항:" "Yellow"
    foreach ($w in $script:Warnings) { Say "  - $w" "Yellow" }
}
if ($exitCode -eq 0) {
    Say ""
    Say "설치가 끝났습니다! 회화연습.exe 를 실행해서 시작하세요. AI 대화·AI 레슨은 앱에서 [AI 연결하기]를 한 번 하면 됩니다. (사용법.txt 참고)" "Green"
    Say "새 버전이 나오면 업데이트.bat (또는 시작 메뉴의 회화 연습 업데이트)을 실행하세요." "Green"
}
Log "==================== 설치 종료 (코드 $exitCode) ===================="
$script:LogW.Close()
exit $exitCode
