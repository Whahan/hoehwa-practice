# setup.exe 시험 (시험용 빌드 hoehwa-practice-setup-test.exe 만 쓴다: 다른 AppId, 바로가기와 지우기 경로를 환경변수로 돌림).
#   powershell -NoProfile -ExecutionPolicy Bypass -File test_setup.ps1 [-Work <폴더>] [-SetupExe <시험용 setup.exe>] [-Drive K] [-SkipVisible] [-ShotDir <폴더>] [-Keep]
#   -SetupExe 없이 부르면 가짜 설치 폴더(staging 흉내)를 만들어 빠르게(lzma2/fast) 컴파일해서 시험한다.
#   -SetupExe 가 있으면 그 파일(build_dist.ps1 -TestSetup 이 만든 진짜 내용)을 그대로 시험한다.
# 실제 설치는 하지 않는다: HOEHWA_TEST_MODE=1 + HOEHWA_SETUP_SIMULATE=1 (큰 다운로드 없음). 설치 폴더는 짧은 드라이브 글자(subst)로 95자 이하.
# 건드리는 곳: -Work 아래, 시험 AppId 의 HKCU 제거 항목(끝에 제거), %TEMP%\is-*.tmp (이 시험의 setup 이 만든 것, 우리 파일이 든 것만 지움). 실제 바탕화면·시작 메뉴·LOCALAPPDATA 는 쓰지 않는다.
# 마지막 줄: SETUP_TEST OK (종료 0) 또는 SETUP_TEST FAIL <개수> (종료 1).
param(
    [string]$Work = "",
    [string]$SetupExe = "",
    [string]$Iscc = "",
    [string]$Drive = "K",
    [switch]$SkipVisible,
    [string]$ShotDir = "",
    [switch]$Keep
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Here = $PSScriptRoot
$Utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not $Work) { $Work = Join-Path ([System.IO.Path]::GetTempPath()) ("hoehwa-setup-test-" + [guid]::NewGuid().ToString("N").Substring(0, 8)) }
$Work = [System.IO.Path]::GetFullPath($Work)
New-Item -ItemType Directory -Force $Work | Out-Null
if (-not $ShotDir) { $ShotDir = $Work }
New-Item -ItemType Directory -Force $ShotDir | Out-Null
$TestGuid = "{D56CB0A7-1AA7-41AA-89C9-B78E146F3367}_is1"
$RegKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$TestGuid"

$script:Results = New-Object System.Collections.Generic.List[object]
function Check([string]$name, [bool]$ok, [string]$detail = "") {
    $script:Results.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
    Write-Host ("[{0}] {1}{2}" -f $(if ($ok) { "O" } else { "X" }), $name, $(if ($detail) { "  -> " + $detail } else { "" })) -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
}

# ------------------------------------------------------------ 도우미
function Set-Env([hashtable]$h) {
    $old = @{}
    foreach ($k in $h.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $h[$k]) }
    return $old
}
function Restore-Env([hashtable]$old) { foreach ($k in $old.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) } }

# 임시 폴더에 새로 생긴 Inno 임시 폴더(is-*.tmp)의 진행 파일을 읽는다 (쓰는 쪽이 교체 중이어도 읽도록 공유 모드로)
$TempDir = [System.IO.Path]::GetTempPath()
$BaseTmp = @{}
foreach ($d in @(Get-ChildItem -LiteralPath $TempDir -Directory -Filter "is-*.tmp" -ErrorAction SilentlyContinue)) { $BaseTmp[$d.FullName] = $true }
function Read-AnyProgress {
    # 가장 최근에 쓰인 진행 파일 (이전 실행이 남긴 임시 폴더의 옛 파일은 건너뛴다)
    $best = $null; $bestT = [datetime]::MinValue
    foreach ($d in @(Get-ChildItem -LiteralPath $TempDir -Directory -Filter "is-*.tmp" -ErrorAction SilentlyContinue)) {
        if ($BaseTmp.ContainsKey($d.FullName)) { continue }
        $f = Join-Path $d.FullName "hoehwa-setup-progress.json"
        $fi = Get-Item -LiteralPath $f -ErrorAction SilentlyContinue
        if ($fi -and $fi.LastWriteTimeUtc -gt $bestT) { $best = $f; $bestT = $fi.LastWriteTimeUtc }
    }
    if (-not $best) { return $null }
    try {
        $fs = [System.IO.File]::Open($best, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try { $sr = New-Object System.IO.StreamReader($fs, $Utf8); $t = $sr.ReadToEnd() } finally { $fs.Dispose() }
        return ($t | ConvertFrom-Json)
    } catch { return $null }
}

# 이 시험의 setup 이 만든 Inno 임시 폴더인가: 우리 파일(진행 파일, 정리 스크립트와 그 결과)이 들어 있는 것만. 다른 프로그램의 임시 폴더는 절대 지우지 않는다.
function Is-OurTmp([string]$dir) {
    foreach ($n in @("hoehwa-setup-progress.json", "hoehwa-stop-report.txt", "stop_app.ps1")) { if (Test-Path -LiteralPath (Join-Path $dir $n)) { return $true } }
    return $false
}
# 이전 실행이 남긴 Inno 임시 폴더(실패 때 setup 이 ExitProcess 로 끝나면 남는다)를 지운다. 돌고 있는 시험 setup 이 없을 때만, 이 시험이 만든 것만.
function Clean-Tmp {
    $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "hoehwa-practice-setup-test*" })
    if ($running.Count) { return }
    foreach ($d in @(Get-ChildItem -LiteralPath $TempDir -Directory -Filter "is-*.tmp" -ErrorAction SilentlyContinue)) {
        if (-not $BaseTmp.ContainsKey($d.FullName) -and (Is-OurTmp $d.FullName)) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
# setup 실행: 반환 Exit, Sec, Samples(진행 파일을 0.15초마다 읽은 기록), Log
function Run-Setup([string[]]$Args2, [hashtable]$Envs = @{}, [int]$TimeoutSec = 240, [switch]$NoWait) {
    $argLine = ($Args2 | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join " "
    Clean-Tmp
    $old = Set-Env $Envs
    try { $p = Start-Process -FilePath $SetupExe -ArgumentList $argLine -PassThru; $null = $p.Handle } finally { Restore-Env $old }
    if ($NoWait) { return [pscustomobject]@{ Proc = $p } }
    return (Wait-Setup $p $TimeoutSec)
}
function Wait-Setup($p, [int]$TimeoutSec = 240) {
    $samples = New-Object System.Collections.Generic.List[object]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited) {
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { & taskkill.exe /PID $p.Id /T /F | Out-Null; break }
        $o = Read-AnyProgress
        if ($o) { $samples.Add([pscustomobject]@{ T = $sw.Elapsed.TotalSeconds; Pct = [int]$o.pct; State = [string]$o.state; Step = [int]$o.step; Code = [int]$o.code; Error = [string]$o.error; Log = [string]$o.log; Warn = [string]$o.warn; Title = [string]$o.title }) }
        Start-Sleep -Milliseconds 150
    }
    $p.WaitForExit()
    # 끝난 뒤 한 번 더: 마지막 쓰기(error/done)는 프로세스가 끝나기 직전이라 위 반복이 놓칠 수 있다 (실패로 끝나면 임시 폴더가 남아 읽을 수 있다)
    $o = Read-AnyProgress
    if ($o) { $samples.Add([pscustomobject]@{ T = $sw.Elapsed.TotalSeconds; Pct = [int]$o.pct; State = [string]$o.state; Step = [int]$o.step; Code = [int]$o.code; Error = [string]$o.error; Log = [string]$o.log; Warn = [string]$o.warn; Title = [string]$o.title }) }
    return [pscustomobject]@{ Exit = $p.ExitCode; Sec = $sw.Elapsed.TotalSeconds; Samples = $samples.ToArray() }
}
function Read-Log([string]$path) { if (Test-Path -LiteralPath $path) { return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) } return "" }
function Env-Std([string]$tag) {
    return @{ HOEHWA_TEST_MODE = "1"; HOEHWA_SETUP_SIMULATE = "1"; HOEHWA_USERDATA_DIR = (Join-Path $Work "ud"); HOEHWA_TEST_NET = "skip";
              HOEHWA_TEST_SHORTCUT_DIR = (Join-Path $Work "sc"); HOEHWA_TEST_LOCALAPPDATA = (Join-Path $Work "fl") }
}
function Fake-Proc([string]$dir) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $exe = Join-Path $dir "fake.exe"
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot "System32\ping.exe") $exe -Force
    return (Start-Process -FilePath $exe -ArgumentList @("-t", "127.0.0.1") -WindowStyle Hidden -PassThru)
}
function Alive([int]$id) { return [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
function Real-Path([string]$p) { return (Join-Path $RealSub ($p.Substring(3))) }   # 드라이브 글자 경로 -> 실제 폴더 (지울 때는 실제 경로로)
function Shortcut-Snapshot {
    $d = [Environment]::GetFolderPath("Desktop"); $m = [Environment]::GetFolderPath("Programs")
    $a = @(Get-ChildItem -LiteralPath $d -Filter "회화*" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + "|" + $_.LastWriteTimeUtc.Ticks })
    $b = @(Get-ChildItem -LiteralPath $m -Filter "회화*" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + "|" + $_.LastWriteTimeUtc.Ticks })
    return (($a + $b) -join ";")
}

# ------------------------------------------------------------ 준비: 짧은 드라이브, 시험용 setup
$RealSub = Join-Path $Work "sub"
New-Item -ItemType Directory -Force $RealSub | Out-Null
$madeSubst = $false
$cur = (& subst.exe) | Where-Object { $_ -match ("^" + $Drive + ":\\") }
if (-not $cur) {
    if (Test-Path ($Drive + ":\")) { throw "드라이브 $Drive 는 이미 쓰이고 있어요. -Drive 로 다른 글자를 주세요." }
    & subst.exe ($Drive + ":") $RealSub | Out-Null; $madeSubst = $true
} elseif ($cur -notmatch [regex]::Escape($RealSub)) { throw "드라이브 $Drive 가 다른 폴더를 가리켜요: $cur" }
$D = $Drive + ":"

$BuiltHere = $false
if (-not $SetupExe) {
    if (-not $Iscc) {
        $lock = Get-Content -LiteralPath (Join-Path $Here "..\tools.lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $Iscc = Join-Path $env:LOCALAPPDATA ("hoehwa-practice\buildtools\innosetup-" + $lock.buildtools.innosetup.version + "\ISCC.exe")
    }
    $stage = Join-Path $Work "fakestage\회화연습"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    foreach ($d in @("backend", "vendor", "defaults")) { New-Item -ItemType Directory -Force (Join-Path $stage $d) | Out-Null }
    $inst = Join-Path $Here "..\installer"
    foreach ($f in @("install.ps1", "uninstall.ps1", "update.ps1", "업데이트.bat")) { Copy-Item -LiteralPath (Join-Path $inst $f) $stage }
    Copy-Item -LiteralPath (Join-Path $Here "stop_app.ps1") $stage
    Copy-Item -LiteralPath (Join-Path $inst "check_env.py") (Join-Path $stage "vendor\check_env.py")
    foreach ($f in @("backend\server.py", "backend\curriculum.json", "vendor\requirements.lock.txt", "vendor\bootstrap.lock.txt", "vendor\models.lock.json", "vendor\install_models.py", "vendor\install_tools.py", "vendor\tools.lock.json", "vendor\update_helper.py")) {
        [System.IO.File]::WriteAllText((Join-Path $stage $f), "x")
    }
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot "System32\ping.exe") (Join-Path $stage "회화연습.exe")
    [System.IO.File]::WriteAllText((Join-Path $stage "vendor\vendor.json"), "{}")
    Copy-Item -LiteralPath (Join-Path $Here "..\defaults\config.default.json") (Join-Path $stage "backend\config.json")
    [System.IO.File]::WriteAllText((Join-Path $stage "defaults\prefs.json"), '{"a":1}')
    [System.IO.File]::WriteAllText((Join-Path $stage "manifest.json"), '{"version":"9.9.9","installer_version":2}')
    $outDir = Join-Path $Work "out"
    New-Item -ItemType Directory -Force $outDir | Out-Null
    $cargs = @("/Q", "/DStageDir=$stage", "/DAppVersion=9.9.9", "/DOutDir=$outDir", "/DTestBuild=1", "/DLzma=lzma2/fast", (Join-Path $Here "hoehwa.iss"))
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $co = & $Iscc @cargs 2>&1 | ForEach-Object { "$_" }
    $cc = $LASTEXITCODE; $ErrorActionPreference = $old
    Check "컴파일(시험용 빌드): ISCC 종료 0" ($cc -eq 0) (($co | Select-Object -Last 2) -join " / ")
    $SetupExe = Join-Path $outDir "hoehwa-practice-setup-test.exe"
    $BuiltHere = $true
}
if (-not (Test-Path -LiteralPath $SetupExe)) { throw "setup 시험 파일이 없어요: $SetupExe" }
$SetupExe = (Resolve-Path -LiteralPath $SetupExe).Path
Write-Host "시험 대상: $SetupExe"
if ($SetupExe -notmatch 'setup-test\.exe$') { throw "시험용 빌드(…-setup-test.exe)만 시험합니다. 배포용 setup.exe 는 실행하지 않아요." }

$snap0 = Shortcut-Snapshot
if (-not $SkipVisible) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic; using System.Drawing;
public class WinInfo { public long Handle; public bool Visible; public int W, H; public string Title; }
public static class HoehwaWin {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  struct RECT { public int L, T, R, B; }
  public static List<WinInfo> Top(uint[] pids) {
    var res = new List<WinInfo>();
    EnumWindows((h, l) => { uint pid; GetWindowThreadProcessId(h, out pid);
      if (Array.IndexOf(pids, pid) >= 0) { var sb = new StringBuilder(256); GetWindowText(h, sb, 256); RECT r; GetWindowRect(h, out r);
        res.Add(new WinInfo { Handle = h.ToInt64(), Visible = IsWindowVisible(h), W = r.R - r.L, H = r.B - r.T, Title = sb.ToString() }); }
      return true; }, IntPtr.Zero);
    return res;
  }
  public static List<string> Children(long handle) {
    var res = new List<string>();
    EnumChildWindows(new IntPtr(handle), (h, l) => { var sb = new StringBuilder(128); GetClassName(h, sb, 128);
      if (IsWindowVisible(h)) res.Add(sb.ToString() + ":" + (IsWindowEnabled(h) ? "on" : "off")); return true; }, IntPtr.Zero);
    return res;
  }
  // Captures ONLY that window's own pixels (PrintWindow), never the rest of the desktop.
  public static bool Shot(long handle, string path) {
    IntPtr h = new IntPtr(handle); RECT r; if (!GetWindowRect(h, out r)) return false;
    int w = r.R - r.L, hh = r.B - r.T; if (w < 100 || hh < 100 || w > 2500 || hh > 2500) return false;
    using (var bmp = new Bitmap(w, hh)) { using (var g = Graphics.FromImage(bmp)) { IntPtr dc = g.GetHdc(); bool ok = PrintWindow(h, dc, 2); g.ReleaseHdc(dc); if (!ok) return false; }
      bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png); }
    return true;
  }
}
"@
}
$killList = New-Object System.Collections.Generic.List[int]
$installed = New-Object System.Collections.Generic.List[string]
try {

# ------------------------------------------------------------ P. 기본 폴더 규칙 (설치하지 않고 로그만)
function Path-Rule([string]$base, [string]$fallback = "") {
    $log = Join-Path $Work ("pr-" + [guid]::NewGuid().ToString("N").Substring(0, 6) + ".log")
    $e = @{}; if ($fallback) { $e["HOEHWA_TEST_FALLBACK_DIR"] = $fallback }
    $null = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/PATHRULE=$base", "/LOG=$log") $e 60
    $t = Read-Log $log
    if ($t -match 'PATHRULE base=(.*) choice=(.*) len=(\d+)') { return [pscustomobject]@{ Base = $Matches[1]; Choice = $Matches[2]; Len = [int]$Matches[3] } }
    return $null
}
$shortBase = "C:\Users\bob\AppData\Local"
$r1 = Path-Rule $shortBase
Check "P1 짧은 기본 폴더: <LOCALAPPDATA>\Programs\회화연습" ($r1 -and $r1.Choice -eq ($shortBase + "\Programs\회화연습")) ($(if ($r1) { $r1.Choice } else { "로그 없음" }))
# 후보 길이가 정확히 80자면 그대로, 81자면 짧은 폴더
$suffix = "\Programs\회화연습"
$base80 = "C:\Users\" + ("a" * (80 - $suffix.Length - 9))
$r2 = Path-Rule $base80
Check "P2 후보 80자: 그대로" ($r2 -and $r2.Len -eq 80 -and $r2.Choice -eq ($base80 + $suffix)) ($(if ($r2) { "len=$($r2.Len) $($r2.Choice)" } else { "로그 없음" }))
$r3 = Path-Rule ($base80 + "a") "C:\fallback-probe"
Check "P3 후보 81자: 짧은 폴더(시험 대체값)" ($r3 -and $r3.Len -eq 81 -and $r3.Choice -eq "C:\fallback-probe") ($(if ($r3) { "len=$($r3.Len) $($r3.Choice)" } else { "로그 없음" }))
$r4 = Path-Rule ("C:\Users\" + ("김" * 80))
Check "P4 긴 한글 사용자 이름: 기본값은 C:\회화연습" ($r4 -and $r4.Choice -eq "C:\회화연습") ($(if ($r4) { $r4.Choice } else { "로그 없음" }))

# ------------------------------------------------------------ S. 조용한 시뮬레이션 설치 (F6, F7)
$X = "$D\t1"
$log1 = Join-Path $Work "inno1.log"
$res1 = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$X", "/LOG=$log1") (Env-Std "s1")
$installed.Add($X)
Check "S1 종료 코드 0" ($res1.Exit -eq 0) ("exit=$($res1.Exit) $([int]$res1.Sec)초")
$need = @("회화연습.exe", "unins000.exe", "manifest.json", "install.ps1", "stop_app.ps1", "version.txt", "runtime\.state\installer_version.txt", "backend\config.json")
$missing = @($need | Where-Object { -not (Test-Path -LiteralPath (Join-Path $X $_)) })
Check "S2 설치 파일 존재 (회화연습.exe, unins000.exe, version.txt, installer_version.txt …)" ($missing.Count -eq 0) ($(if ($missing.Count) { "없음: " + ($missing -join ", ") } else { "모두 있음" }))
$iv = if (Test-Path -LiteralPath "$X\runtime\.state\installer_version.txt") { (Get-Content -LiteralPath "$X\runtime\.state\installer_version.txt" -Raw).Trim() } else { "" }
Check "S3 installer_version.txt == 2" ($iv -eq "2") "값=$iv"
Check "S4 학습 기록 기본값이 시험용 USERDATA 폴더에만 복사됨" ((Test-Path -LiteralPath (Join-Path $Work "ud\prefs.json"))) ""
$sm = @($res1.Samples)
$mono = $true; for ($i = 1; $i -lt $sm.Count; $i++) { if ($sm[$i].Pct -lt $sm[$i - 1].Pct) { $mono = $false } }
# 마지막 쓰기(done/100)는 setup 이 끝나면서 임시 폴더를 지우기 직전이라 표본이 놓칠 수 있다: 90 이상까지 보였으면 되고, done/100 은 S6(Inno 로그)이 확인한다
$hasHigh = ($sm | Where-Object { $_.Pct -ge 90 }).Count -gt 0
Check "S5 진행 파일: 낮은 값에서 90 이상까지 증가, 줄어들지 않음 (표본 $($sm.Count)개)" ($sm.Count -ge 8 -and $mono -and $hasHigh -and $sm[0].Pct -lt 50) ("처음=$(if ($sm.Count) { $sm[0].Pct } else { '-' }) 끝=$(if ($sm.Count) { $sm[$sm.Count - 1].Pct } else { '-' })")
$t1 = Read-Log $log1
Check "S6 Inno 로그: install.ps1 이 done/100 으로 끝남" ($t1 -match 'install\.ps1 끝: 시작=1 종료코드=0 상태=done 단계=11 진행=100') ""
Check "S7 막대는 파일 풀기에서 줄어들지 않고 이어짐 (파일 풀기 뒤 위치 로그 있음)" ($t1 -match '진행 막대\(파일 푼 뒤\)') ""
Check "S8 바로가기: 시험 경로에만 생김 (바탕화면 1 + 시작 메뉴 3)" ((Test-Path -LiteralPath (Join-Path $Work "sc\Desktop\회화 연습.lnk")) -and (@(Get-ChildItem -LiteralPath (Join-Path $Work "sc\Programs\회화 연습") -Filter *.lnk).Count -eq 3)) ""
Check "S9 제거 항목 등록 (시험 AppId, HKCU)" (Test-Path $RegKey) ""
Check "S10 실제 바탕화면·시작 메뉴의 '회화*' 항목이 그대로 (설치 전후 같음)" ((Shortcut-Snapshot) -eq $snap0) ""
Check "S11 질문 0: 조용한 모드가 사용자 입력 없이 끝남 (질문 창이 없으면 위 종료 0)" ($res1.Exit -eq 0) ""

# ------------------------------------------------------------ F. 실패(FAIL_STEP=4)와 이어하기 (F9)
$Y = "$D\t2"
$logF = Join-Path $Work "innoF.log"
$eF = Env-Std "f"; $eF["HOEHWA_SETUP_FAIL_STEP"] = "4"
$resF = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$Y", "/LOG=$logF") $eF
$installed.Add($Y)
$tF = Read-Log $logF
Check "F1 종료 코드가 0 이 아님 (40)" ($resF.Exit -eq 40) "exit=$($resF.Exit)"
Check "F2 로그에 한국어 사유와 install.log 경로" ($tF -match '설치 실패: .*[가-힣]' -and $tF -match '기록 파일: .*install\.log') ""
$lastS = if ($resF.Samples.Count) { $resF.Samples[$resF.Samples.Count - 1] } else { $null }
Check "F3 진행 파일 마지막: state=error, code=40, 한국어 error" ($lastS -and $lastS.State -eq "error" -and $lastS.Code -eq 40 -and $lastS.Error -match '[가-힣]') ($(if ($lastS) { "state=$($lastS.State) code=$($lastS.Code)" } else { "표본 없음" }))
Check "F4 실패해도 파일이 남아 있음 (롤백 없음)" ((Test-Path -LiteralPath "$Y\install.ps1") -and (Test-Path -LiteralPath "$Y\unins000.exe") -and (Test-Path -LiteralPath "$Y\회화연습.exe")) ""
Check "F5 실패해도 제거 항목은 남음 (제거 가능)" (Test-Path $RegKey) ""
# 설정 파일 보존: 사용자가 바꾼 config.json 은 다시 실행해도 덮어쓰지 않는다
$cfgPath = "$Y\backend\config.json"
$cfgTxt = [System.IO.File]::ReadAllText($cfgPath, $Utf8)
[System.IO.File]::WriteAllText($cfgPath, $cfgTxt.TrimEnd().TrimEnd("}").TrimEnd() + ',"zz_user_marker":123}', $Utf8)
$logR = Join-Path $Work "innoR.log"
$resR = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$Y", "/LOG=$logR") (Env-Std "r")
Check "F6 다시 실행(훅 없이): 이어서 성공 (종료 0, 상태 done)" ($resR.Exit -eq 0 -and (Read-Log $logR) -match '상태=done') "exit=$($resR.Exit)"
$ilog = Read-Log "$Y\install.log"
Check "F7 이어하기: 끝난 단계를 건너뜀 (install.log 의 '이미 끝난 단계')" (([regex]::Matches($ilog, "이미 끝난 단계")).Count -ge 1) "횟수=$(([regex]::Matches($ilog, '이미 끝난 단계')).Count)"
Check "F8 다시 설치해도 사용자 backend\config.json 을 덮어쓰지 않음" ((Read-Log $cfgPath) -match 'zz_user_marker') ""

# ------------------------------------------------------------ W. 설치를 막지 않는 경고 (5단계 실패 -> 끝에 경고)
$Z = "$D\t3"
$logW = Join-Path $Work "innoW.log"
$eW = Env-Std "w"; $eW["HOEHWA_SETUP_FAIL_STEP"] = "5"
$resW = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$Z", "/LOG=$logW") $eW
$installed.Add($Z)
$tW = Read-Log $logW
Check "W1 경고만 있으면 종료 0, 로그에 경고 문구와 done" ($resW.Exit -eq 0 -and $tW -match 'install\.ps1 경고: .*[가-힣]' -and $tW -match '상태=done') "exit=$($resW.Exit)"
Check "W2 경고가 있어도 끝 알림이 있음 (조용한 모드에서는 '기본값 OK'로 로그에 남음)" ($tW -match '설치는 끝났어요') ""

# ------------------------------------------------------------ K. 실행 중 프로세스 정리 (F11) + 제거
$pIn = Fake-Proc $X
$pOut = Fake-Proc (Join-Path $Work "other")
$killList.Add($pIn.Id); $killList.Add($pOut.Id)
Start-Sleep -Milliseconds 500
$logK = Join-Path $Work "innoK.log"
$resK = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$X", "/LOG=$logK") (Env-Std "k")
$tK = Read-Log $logK
Check "K1 재설치: 설치 폴더 아래 프로세스만 PID 로 끔 (안쪽 죽음, 같은 이름의 다른 폴더 프로세스 살아 있음)" ($resK.Exit -eq 0 -and -not (Alive $pIn.Id) -and (Alive $pOut.Id)) "exit=$($resK.Exit) 안=$(Alive $pIn.Id) 밖=$(Alive $pOut.Id)"
Check "K2 로그에 끈 PID 기록 (stop_app: STOP <pid>)" ($tK -match ("stop_app: STOP " + $pIn.Id + " ")) ""
# 제거: 설치 폴더 아래 프로세스 다시 띄우고, opencode 작업 폴더와 그 옆 다른 파일, 학습 기록 자리를 준비
$pIn2 = Fake-Proc $X; $killList.Add($pIn2.Id)
$oc = Join-Path $Work "fl\hoehwa-practice\opencode"
New-Item -ItemType Directory -Force $oc | Out-Null
[System.IO.File]::WriteAllText((Join-Path $oc "work.txt"), "w")
[System.IO.File]::WriteAllText((Join-Path $Work "fl\hoehwa-practice\keep.txt"), "k")
[System.IO.File]::WriteAllText((Join-Path $Work "ud\progress.json"), '{"sentinel":1}')
[System.IO.File]::WriteAllText("$X\runtime\.state\leftover.txt", "x")
New-Item -ItemType Directory -Force "$X\backend\models\hf" | Out-Null
[System.IO.File]::WriteAllText("$X\backend\models\hf\big.bin", "x")
[System.IO.File]::WriteAllText("$X\install.log.extra", "x")
$logU = Join-Path $Work "unins1.log"
$old = Set-Env (Env-Std "u")
try { $u = Start-Process -FilePath "$X\unins000.exe" -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/LOG=$logU") -PassThru; $null = $u.Handle } finally { Restore-Env $old }
if (-not $u.WaitForExit(120000)) { & taskkill.exe /PID $u.Id /T /F | Out-Null }
Start-Sleep -Seconds 2
$tU = Read-Log $logU
$leftX = if (Test-Path -LiteralPath (Real-Path $X)) { @(Get-ChildItem -LiteralPath (Real-Path $X) -Recurse -Force -Name | Select-Object -First 5) } else { @() }
Check "U1 제거 종료 코드 0" ($u.ExitCode -eq 0) "exit=$($u.ExitCode)"
# 아는 것(설치한 파일, runtime, backend\models, install.log …)은 모두 지워지고, 제거 프로그램이 모르는 파일(이 시험이 둔 fake.exe, install.log.extra)만 남는다. 모르는 파일이 없으면 폴더째 사라진다 (U9b).
$allowedLeft = @("fake.exe", "install.log.extra")
$unexpected = @(); if (Test-Path -LiteralPath (Real-Path $X)) { $unexpected = @(Get-ChildItem -LiteralPath (Real-Path $X) -Recurse -Force -Name | Where-Object { $allowedLeft -notcontains $_ }) }
Check "U2 아는 파일은 모두 지워짐 (runtime, backend\models, unins000, 회화연습.exe …). 모르는 파일(시험이 둔 2개)만 남음" ($unexpected.Count -eq 0) ($(if ($unexpected.Count) { "예상 밖으로 남음: " + (($unexpected | Select-Object -First 5) -join ", ") } else { "남은 것: " + (($leftX) -join ", ") }))
Check "U3 제거가 실행 중이던 앱 프로세스를 PID 로 끔" (-not (Alive $pIn2.Id) -and (Alive $pOut.Id)) ""
Check "U4 학습 기록 폴더(시험용 USERDATA)는 그대로 남음 (prefs.json, progress.json)" ((Test-Path -LiteralPath (Join-Path $Work "ud\prefs.json")) -and (Test-Path -LiteralPath (Join-Path $Work "ud\progress.json"))) ""
Check "U5 opencode 작업 폴더는 지워지고, 같은 부모의 다른 파일은 남음" (-not (Test-Path -LiteralPath $oc) -and (Test-Path -LiteralPath (Join-Path $Work "fl\hoehwa-practice\keep.txt"))) ""
Check "U6 바로가기가 지워짐" (-not (Test-Path -LiteralPath (Join-Path $Work "sc\Desktop\회화 연습.lnk")) -and -not (Test-Path -LiteralPath (Join-Path $Work "sc\Programs\회화 연습"))) ""
Check "U7 제거 항목(HKCU, 시험 AppId)이 사라짐" (-not (Test-Path $RegKey)) ""
Check "U8 실제 바탕화면·시작 메뉴의 '회화*' 항목이 그대로" ((Shortcut-Snapshot) -eq $snap0) ""
# 시험 환경변수가 없을 때: 시험 빌드는 실제 LOCALAPPDATA 의 opencode 폴더를 지우지 않는다 (아래에서 확인)
$realOc = Join-Path $env:LOCALAPPDATA "hoehwa-practice\opencode"
$realOcBefore = Test-Path -LiteralPath $realOc
$X4 = "$D\t4"
$null = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$X4", "/LOG=$(Join-Path $Work 'inno4.log')") (Env-Std "x4")
$e4 = Env-Std "x4"; $e4["HOEHWA_TEST_LOCALAPPDATA"] = ""
$old = Set-Env $e4
try { $u4 = Start-Process -FilePath "$X4\unins000.exe" -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES") -PassThru; $null = $u4.Handle } finally { Restore-Env $old }
$u4.WaitForExit(120000) | Out-Null
# unins000.exe 는 실제 제거를 다른 프로세스(임시 사본)에 넘기고 먼저 끝난다: 폴더가 사라질 때까지 기다린다 (최대 40초)
$swu = [System.Diagnostics.Stopwatch]::StartNew()
while ($swu.Elapsed.TotalSeconds -lt 40 -and (Test-Path -LiteralPath (Real-Path $X4))) { Start-Sleep -Milliseconds 500 }
Check "U9b 모르는 파일이 없는 설치는 제거하면 폴더째 사라짐" (-not (Test-Path -LiteralPath (Real-Path $X4))) ""
Check "U9 시험 환경변수 없이 제거해도 실제 LOCALAPPDATA 의 opencode 폴더는 건드리지 않음 (있었다면 그대로)" ((Test-Path -LiteralPath $realOc) -eq $realOcBefore) "전=$realOcBefore 후=$(Test-Path -LiteralPath $realOc)"

# ------------------------------------------------------------ L. 경로 길이 (F12)
$longDir = Join-Path $Work "long-folder-name-for-the-path-length-rule-test-0123456789"
if ($longDir.Length -lt 96) { $longDir = $longDir + ("x" * (96 - $longDir.Length)) }
$logL = Join-Path $Work "innoL.log"
$resL = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$longDir", "/LOG=$logL") (Env-Std "l")
$tL = Read-Log $logL
$lastL = if ($resL.Samples.Count) { $resL.Samples[$resL.Samples.Count - 1] } else { $null }
Check "L1 /DIR 가 96자 이상: 종료 10, 한국어 안내(경로)" ($resL.Exit -eq 10 -and $tL -match '경로' -and $longDir.Length -ge 96) "exit=$($resL.Exit) 길이=$($longDir.Length)"
Check "L2 진행 파일 error 에 '경로' 포함, code=10" ($lastL -and $lastL.Code -eq 10 -and $lastL.Error -match '경로') ($(if ($lastL) { $lastL.Error } else { "표본 없음" }))
if (Test-Path -LiteralPath "$longDir\unins000.exe") {
    $ul = Start-Process -FilePath "$longDir\unins000.exe" -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES") -PassThru -Wait
}

# ------------------------------------------------------------ M. 두 개 동시 실행 방지 (F13)
$M1 = "$D\t5"; $M2 = "$D\t6"
$logM1 = Join-Path $Work "innoM1.log"; $logM2 = Join-Path $Work "innoM2.log"
$first = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$M1", "/LOG=$logM1") (Env-Std "m1") -NoWait
$installed.Add($M1)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 30 -and -not (Read-AnyProgress)) { Start-Sleep -Milliseconds 200 }
$second = Run-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/DIR=$M2", "/LOG=$logM2") (Env-Std "m2") 60
$firstRes = Wait-Setup $first.Proc 240
Check "M1 두 번째 setup 은 바로 끝나고 (15초 이내) 아무것도 설치하지 않음" ($second.Sec -lt 15 -and -not (Test-Path -LiteralPath (Real-Path $M2))) "exit=$($second.Exit) $([int]$second.Sec)초"
Check "M2 첫 번째 setup 은 영향 없이 성공 (종료 0)" ($firstRes.Exit -eq 0 -and (Test-Path -LiteralPath "$M1\version.txt")) "exit=$($firstRes.Exit)"

# ------------------------------------------------------------ V. 화면 있는 무입력 모드 (F8) + 화면 캡처 (그 창만)
if (-not $SkipVisible) {
    $V = "$D\t7"
    $logV = Join-Path $Work "innoV.log"
    $pv = (Run-Setup @("/DIR=$V", "/LOG=$logV") (Env-Std "v") -NoWait).Proc
    $installed.Add($V)
    $shots = @{}; $maxWin = 0; $dialogSeen = $false; $mainSeen = $false; $btnInfo = ""
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $pv.HasExited -and $sw.Elapsed.TotalSeconds -lt 240) {
        $pids = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "hoehwa-practice-setup-test*" } | ForEach-Object { [uint32]$_.ProcessId })
        $wins = if ($pids.Count) { @([HoehwaWin]::Top($pids)) } else { @() }
        $vis = @($wins | Where-Object { $_.Visible -and $_.W -ge 300 -and $_.H -ge 200 })
        if ($vis.Count -gt 0) { $mainSeen = $true }
        if ($vis.Count -gt 1) { $dialogSeen = $true }
        $o = Read-AnyProgress
        if ($vis.Count -ge 1 -and $o) {
            $w0 = $vis[0]
            if (-not $shots.ContainsKey("start")) { if ([HoehwaWin]::Shot($w0.Handle, (Join-Path $ShotDir "shot_start.png"))) { $shots["start"] = $o.pct } }
            elseif (-not $shots.ContainsKey("mid") -and $o.pct -ge 35) { if ([HoehwaWin]::Shot($w0.Handle, (Join-Path $ShotDir "shot_mid.png"))) { $shots["mid"] = $o.pct } }
            elseif (-not $shots.ContainsKey("late") -and $o.pct -ge 85) { if ([HoehwaWin]::Shot($w0.Handle, (Join-Path $ShotDir "shot_late.png"))) { $shots["late"] = $o.pct } }
            if (-not $btnInfo) { $btnInfo = ([HoehwaWin]::Children($w0.Handle) -join ",") }
        }
        Start-Sleep -Milliseconds 200
    }
    if (-not $pv.HasExited) { & taskkill.exe /PID $pv.Id /T /F | Out-Null }
    $pv.WaitForExit()
    Check "V1 화면 모드: 창이 하나만 뜨고 (질문·오류 대화상자 없음) 입력 없이 종료 0" ($mainSeen -and -not $dialogSeen -and $pv.ExitCode -eq 0) "창=$mainSeen 대화상자=$dialogSeen exit=$($pv.ExitCode)"
    Check "V2 화면 캡처 3장 (시작·중간·끝 무렵, 그 창만): shot_start/mid/late.png" ($shots.ContainsKey("start") -and $shots.ContainsKey("mid") -and $shots.ContainsKey("late")) (($shots.Keys | ForEach-Object { "$_=$($shots[$_])%" }) -join " ")
    Write-Host "    창 안의 컨트롤(클래스:보임/켜짐): $btnInfo"
    Check "V3 화면 모드 설치가 파일을 풀고 끝남 (version.txt)" (Test-Path -LiteralPath "$V\version.txt") ""
}

} finally {
    # ------------------------------------------------------------ 정리 (시험 AppId 제거 항목, 남은 프로세스, 임시 폴더)
    foreach ($id in $killList) { if (Alive $id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }
    foreach ($dir in $installed) {
        $u = Join-Path (Real-Path $dir) "unins000.exe"
        if (Test-Path -LiteralPath $u) {
            try { $p = Start-Process -FilePath ($dir + "\unins000.exe") -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES") -PassThru -Wait } catch {}
        }
    }
    if (Test-Path $RegKey) { Remove-Item -LiteralPath $RegKey -Recurse -Force -ErrorAction SilentlyContinue }
    $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath -like "*hoehwa-practice-setup-test*" })
    if (-not $running.Count) {
        foreach ($d in @(Get-ChildItem -LiteralPath $TempDir -Directory -Filter "is-*.tmp" -ErrorAction SilentlyContinue)) {
            if (-not $BaseTmp.ContainsKey($d.FullName) -and (Is-OurTmp $d.FullName)) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    if ($madeSubst) { & subst.exe ($Drive + ":") /D | Out-Null }
}
$left = @(Get-ChildItem -LiteralPath $TempDir -Directory -Filter "is-*.tmp" -ErrorAction SilentlyContinue | Where-Object { -not $BaseTmp.ContainsKey($_.FullName) -and (Is-OurTmp $_.FullName) })
Check "Z1 끝난 뒤 시험 AppId 제거 항목·남은 임시 폴더 없음" (-not (Test-Path $RegKey) -and $left.Count -eq 0) "임시 폴더 $($left.Count)개"

$bad = @($script:Results | Where-Object { -not $_.Ok })
Write-Host ""
if ($bad.Count -eq 0) { Write-Host "SETUP_TEST OK ($($script:Results.Count) checks)" -ForegroundColor Green; exit 0 }
Write-Host "SETUP_TEST FAIL $($bad.Count)" -ForegroundColor Red
exit 1
