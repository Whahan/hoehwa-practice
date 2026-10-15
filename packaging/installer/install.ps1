# 회화 연습 설치 스크립트 (재실행 안전). 보통은 설치.bat 을 더블클릭해서 실행합니다.
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-Yes] [-NoShortcut] [-TestPort 8790] [-Engine deepseek|local] [-DryRun]
param(
    [switch]$Yes,          # 모든 질문에 자동으로 Y (무인 설치)
    [switch]$NoShortcut,   # 바탕화면 바로가기 질문 건너뛰기
    [int]$TestPort = 8790, # 마지막 동작 확인용 임시 서버 포트(사용 중이면 다음 빈 포트)
    [ValidateSet("", "deepseek", "local")]
    [string]$Engine = "",  # AI 엔진: deepseek (OpenCode 의 무료 DeepSeek V4.1 Flash, 기본) | local (Ollama + qwen3:8b). 비우면 질문 (-Yes 이면 deepseek)
    [switch]$DryRun        # (검증용) 엔진 선택과 config.json 기록만 확인한다. 파이썬·패키지·모델·Node.js·OpenCode 설치와 로그인은 하지 않는다
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

# ------------------------------------------------------------------ 로그 / 출력 도우미
$script:LogW = New-Object System.IO.StreamWriter($LogFile, $true, (New-Object System.Text.UTF8Encoding($false)))
$script:LogW.AutoFlush = $true
function Log([string]$m) { $script:LogW.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $m) }
function Say([string]$m, [string]$color = "White") { Write-Host $m -ForegroundColor $color; Log $m }
function Info([string]$m) { Say ("    " + $m) "Gray" }
function Warn([string]$m) { Say ("    [주의] " + $m) "Yellow"; $script:Warnings.Add($m) }
function Fail([string]$m) { throw $m }

function Ask-YN([string]$prompt, [bool]$default = $true) {
    if ($Yes) { Say "$prompt -> (자동) Y" "Gray"; return $true }
    while ($true) {
        $a = Read-Host $prompt
        if ($a -match '^[yY]') { return $true }
        if ($a -match '^[nN]') { return $false }
        if ($a -eq "") { return $default }
    }
}

# 외부 프로그램 실행: 출력은 화면과 install.log 에 같이 남긴다. 종료 코드를 돌려준다.
$script:LastOutput = @()
function Invoke-Native([string]$Exe, [string[]]$Arguments, [switch]$Quiet) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        Log ("> " + $Exe + " " + ($Arguments -join " "))
        & $Exe @Arguments 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            $lines.Add($line)
            $script:LogW.WriteLine($line)
            if (-not $Quiet) { Write-Host ("    " + $line) -ForegroundColor DarkGray }
        }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    $script:LastOutput = $lines.ToArray()
    Log ("  (exit $code)")
    return $code
}

function Write-Utf8([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-Sha256([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }

function Test-Url([string]$url, [int]$timeout = 10) {
    try { Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec $timeout | Out-Null; return $true } catch {
        # 일부 서버는 HEAD 를 막는다: 응답을 받았다면 연결은 된 것
        if ($_.Exception.Response) { return $true }
        return $false
    }
}

# ------------------------------------------------------------------ 단계 실행기
function Step([int]$n, [string]$title, [string]$key, [scriptblock]$Body, [switch]$Always, [switch]$DryOK) {
    Say ""
    Say ("[{0}/{1}] {2}" -f $n, $TotalSteps, $title) "Cyan"
    if ($DryRun -and -not $DryOK) {
        Say "    [DryRun] 이 단계는 실제로 실행하지 않습니다." "Yellow"
        $script:Timings.Add([pscustomobject]@{ N = $n; Title = $title; Sec = 0; Result = "DryRun 건너뜀" })
        return
    }
    $marker = Join-Path $StateDir ("{0:00}-{1}.ok" -f $n, $key)
    if (-not $Always -and -not $DryRun -and (Test-Path -LiteralPath $marker)) {
        Say "    이미 끝난 단계입니다. 건너뜁니다." "Green"
        $script:Timings.Add([pscustomobject]@{ N = $n; Title = $title; Sec = 0; Result = "건너뜀" })
        return
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Body
    $sw.Stop()
    if (-not $Always -and -not $DryRun) {
        New-Item -ItemType Directory -Force $StateDir | Out-Null
        Write-Utf8 $marker (Get-Date -Format "o")
    }
    Say ("    완료 ({0:N0}초)" -f $sw.Elapsed.TotalSeconds) "Green"
    $script:Timings.Add([pscustomobject]@{ N = $n; Title = $title; Sec = [math]::Round($sw.Elapsed.TotalSeconds); Result = "완료" })
}

# ------------------------------------------------------------------ Ollama 도우미
$OllamaApi = "http://127.0.0.1:11434"
function Find-Ollama {
    $c = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @((Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"),
                     (Join-Path $env:ProgramFiles "Ollama\ollama.exe"))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
function Get-OllamaTags {
    try { return (Invoke-RestMethod "$OllamaApi/api/tags" -TimeoutSec 4).models } catch { return $null }
}
function Ensure-OllamaRunning([string]$exe) {
    if ($null -ne (Get-OllamaTags)) { return $true }
    Info "Ollama 서버를 켭니다..."
    Start-Process -FilePath $exe -ArgumentList "serve" -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 1
        if ($null -ne (Get-OllamaTags)) { return $true }
    }
    return $false
}

# ------------------------------------------------------------------ AI 엔진 선택 / Node.js / OpenCode 도우미
$OpenCodePkg = "opencode-ai"
$OpenCodeVer = "1.19.0"
$OpenCodeModel = "opencode/deepseek-v4.1-flash-free"
$EngineInfo = @{
    deepseek = @{ Provider = "opencode"; Name = "DeepSeek V4.1 Flash 무료 (OpenCode)" }
    local    = @{ Provider = "ollama";   Name = "오프라인 로컬 (Ollama + qwen3:8b)" }
}

function Select-Engine {
    Say ""
    Say "AI 엔진을 골라 주세요" "Cyan"
    Say "  1) DeepSeek V4.1 Flash 무료 (기본, 추천)"
    Say "       인터넷이 필요합니다. 설치: Node.js(없으면) + OpenCode. 각자 본인의 OpenCode 계정으로 로그인합니다." "Gray"
    Say "  2) 오프라인 로컬 (qwen3:8b, 약 5GB, NVIDIA 그래픽카드 권장)"
    Say "       인터넷 없이 동작합니다. 설치: Ollama + 모델 약 5GB." "Gray"
    while ($true) {
        $a = Read-Host "번호를 입력하세요 (1-2, 그냥 Enter 는 1)"
        if ($null -eq $a) { return "deepseek" }   # 입력이 끊긴 경우(자동 실행)
        switch ($a.Trim()) { "" { return "deepseek" } "1" { return "deepseek" } "2" { return "local" } }
    }
}

function Refresh-Path {
    $m = [Environment]::GetEnvironmentVariable("Path", "Machine"); $u = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = (($m, $u) | Where-Object { $_ }) -join ";"
    foreach ($p in @((Join-Path $env:ProgramFiles "nodejs"), (Join-Path $env:APPDATA "npm"))) {
        if ((Test-Path -LiteralPath $p) -and ($env:Path -notlike "*$p*")) { $env:Path += ";$p" }
    }
}
function Get-NodeMajor {
    $n = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $n) { return 0 }
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $v = (& $n.Source --version 2>$null)
    $ErrorActionPreference = $old
    if ("$v" -match '^v(\d+)') { return [int]$Matches[1] }
    return 0
}
function Install-NodeLts {
    $ok = $false
    $msi = $null
    try {
        $idx = Invoke-RestMethod "https://nodejs.org/dist/index.json" -TimeoutSec 30
        $rel = $idx | Where-Object { $_.lts -and [int]($_.version.TrimStart("v").Split(".")[0]) -ge 22 } | Select-Object -First 1
        if (-not $rel) { throw "LTS 버전을 찾지 못했습니다." }
        $ver = $rel.version
        $base = "https://nodejs.org/dist/$ver"
        $msi = Join-Path $env:TEMP "node-$ver-x64.msi"
        Info "Node.js $ver (LTS) MSI 를 받습니다: $base/node-$ver-x64.msi"
        $code = Invoke-Native "curl.exe" @("-L", "--fail", "--retry", "3", "-o", $msi, "$base/node-$ver-x64.msi")
        if ($code -ne 0) { throw "MSI 다운로드 실패" }
        $sums = (Invoke-WebRequest "$base/SHASUMS256.txt" -UseBasicParsing -TimeoutSec 30).Content
        $line = ($sums -split "`n" | Where-Object { $_ -match "node-$([regex]::Escape($ver))-x64\.msi" } | Select-Object -First 1)
        if (-not $line) { throw "SHASUMS256.txt 에서 MSI 해시를 찾지 못했습니다." }
        $want = ($line.Trim() -split "\s+")[0].ToLower()
        if ((Get-Sha256 $msi) -ne $want) { throw "MSI 의 SHA256 이 공식 값과 다릅니다. 보안을 위해 중단합니다." }
        Info "SHA256 확인 OK"
        Info "설치 중... (관리자 권한 확인 창이 뜨면 '예' 를 눌러 주세요)"
        $p = Start-Process msiexec.exe -ArgumentList @("/i", "`"$msi`"", "/qn", "/norestart") -Verb RunAs -Wait -PassThru
        Log "msiexec 종료 코드: $($p.ExitCode)"
        Refresh-Path
        if ((Get-NodeMajor) -ge 22) { $ok = $true }
    } catch { Warn ("공식 MSI 설치 실패: " + $_.Exception.Message) }
    finally { if ($msi) { Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue } }   # 성공해도 실패해도 MSI 는 남기지 않는다
    if (-not $ok -and (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        Info "winget 으로 Node.js LTS 설치를 시도합니다."
        Invoke-Native "winget.exe" @("install", "--id", "OpenJS.NodeJS.LTS", "-e", "--silent", "--accept-package-agreements", "--accept-source-agreements") | Out-Null
        Refresh-Path
        if ((Get-NodeMajor) -ge 22) { $ok = $true }
    }
    return $ok
}
function Get-NpmGlobalVersion([string]$pkg) {
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { return $null }
    Invoke-Native $npm.Source @("ls", "-g", $pkg, "--depth=0", "--json") -Quiet | Out-Null
    try { $j = ($script:LastOutput -join "`n") | ConvertFrom-Json; return $j.dependencies.$pkg.version } catch { return $null }
}
function Find-OpenCode {
    foreach ($n in @("opencode.cmd", "opencode.exe")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    $p = Join-Path $env:APPDATA "npm\opencode.cmd"
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}
function Strip-Ansi([string]$t) { return ($t -replace "\x1b\[[0-9;?]*[A-Za-z]", "") }
# `opencode auth list` 는 로그인한 서비스 이름만 보여 준다 (키는 나오지 않는다)
function Test-OpenCodeLogin([string]$oc) {
    $code = Invoke-Native $oc @("auth", "list") -Quiet
    if ($code -ne 0) { return $false }
    return ((Strip-Ansi ($script:LastOutput -join "`n")) -match "(?im)\bOpenCode(\s+Zen)?\s+(api|oauth|wellknown)\b")
}
function Test-OpenCodeModel([string]$oc) {
    $code = Invoke-Native $oc @("models", "opencode") -Quiet
    if ($code -ne 0) { return $false }
    return (@($script:LastOutput | ForEach-Object { (Strip-Ansi $_).Trim() }) -contains $OpenCodeModel)
}

# ------------------------------------------------------------------ Java 17+ (LanguageTool 문법 검사기용, 선택)
# backend\grammar.py 가 찾는 곳과 같은 규칙: backend\tools\jre*|jdk*, JAVA_HOME, Program Files 의 JDK/JRE 폴더, PATH
function Get-JavaMajor([string]$exe) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $t = (& $exe -version 2>&1 | Out-String) } catch { $t = "" }
    $ErrorActionPreference = $old
    if ($t -match 'version "(\d+)(?:\.(\d+))?') {
        $m = [int]$Matches[1]
        if ($m -eq 1 -and $Matches[2]) { $m = [int]$Matches[2] }   # 1.8 -> 8
        return $m
    }
    return 0
}
function Find-Java17 {
    if ($env:HOEHWA_TEST_NO_JAVA -eq "1") { return $null }   # (테스트용) Java 가 없는 PC 흉내
    $c = New-Object System.Collections.Generic.List[string]
    $tools = Join-Path $Backend "tools"
    if (Test-Path -LiteralPath $tools) {
        Get-ChildItem -LiteralPath $tools -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "jre*" -or $_.Name -like "jdk*" } |
            Sort-Object Name -Descending | ForEach-Object { $c.Add((Join-Path $_.FullName "bin\java.exe")) }
    }
    if ($env:JAVA_HOME) { $c.Add((Join-Path $env:JAVA_HOME "bin\java.exe")) }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        foreach ($v in @("Java", "Eclipse Adoptium", "Microsoft", "Zulu", "Amazon Corretto", "BellSoft", "Semeru")) {
            $vd = Join-Path $root $v
            if (Test-Path -LiteralPath $vd) {
                Get-ChildItem -LiteralPath $vd -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object { $c.Add((Join-Path $_.FullName "bin\java.exe")) }
            }
        }
    }
    $w = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($w) { $c.Add($w.Source) }
    foreach ($e in $c) { if ((Test-Path -LiteralPath $e) -and (Get-JavaMajor $e) -ge 17) { return $e } }
    return $null
}
# 공식 Adoptium API 에서 Temurin 21 JRE x64 zip 의 주소와 SHA256 을 읽는다. zip 은 backend\tools 안에 풀기만 하면 되고
# (MSI 와 달리 관리자 권한 확인 창이 없다) backend\grammar.py 가 backend\tools\jre*|jdk* 를 자동으로 찾는다.
function Get-TemurinJreInfo {
    $api = "https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=x64&image_type=jre&os=windows&vendor=eclipse"
    $meta = Invoke-RestMethod $api -TimeoutSec 30
    $pkg = @($meta | Where-Object { $_.binary.image_type -eq "jre" -and $_.binary.os -eq "windows" -and $_.binary.architecture -eq "x64" -and $_.binary.package.name -like "*.zip" }) |
        Select-Object -First 1 | ForEach-Object { $_.binary.package }
    if (-not $pkg) { throw "Adoptium 에서 Temurin 21 JRE zip 정보를 찾지 못했습니다." }
    if ($pkg.link -notmatch '^https://(github\.com/adoptium/|api\.adoptium\.net/)') { throw "예상과 다른 다운로드 주소입니다: $($pkg.link)" }
    if ($pkg.checksum -notmatch '^[0-9a-fA-F]{64}$') { throw "SHA256 값을 읽지 못했습니다." }
    return $pkg
}
function Install-TemurinJre {
    $pkg = Get-TemurinJreInfo
    $tools = Join-Path $Backend "tools"
    New-Item -ItemType Directory -Force $tools | Out-Null
    $zip = Join-Path $env:TEMP ("temurin-jre-{0}.zip" -f $PID)
    $tmp = Join-Path $tools "_jre_extract"
    try {
        Info ("다운로드: {0} ({1:N0} MB)" -f $pkg.name, ($pkg.size / 1MB))
        $code = Invoke-Native "curl.exe" @("-L", "--fail", "--retry", "3", "-sS", "-o", $zip, $pkg.link) -Quiet
        if ($code -ne 0) { throw "다운로드 실패" }
        if ((Get-Sha256 $zip) -ne $pkg.checksum.ToLower()) { throw "SHA256 이 공식 값과 다릅니다. 보안을 위해 설치하지 않습니다." }
        Info "SHA256 확인 OK"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        $dir = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
        if (-not $dir -or -not (Test-Path -LiteralPath (Join-Path $dir.FullName "bin\java.exe"))) { throw "압축 안에 bin\java.exe 가 없습니다." }
        $dst = Join-Path $tools $dir.Name
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
        Move-Item -LiteralPath $dir.FullName -Destination $dst
        return $true
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Ensure-Java {
    $j = Find-Java17
    if ($j) { Info ("Java 17 이상 확인: " + $j + " (버전 " + (Get-JavaMajor $j) + ")"); return }
    Info "Java 17 이상이 없습니다. 문법 검사기(LanguageTool)는 Java 17 이상이 있어야 켜집니다."
    if ($DryRun) {
        try { $pkg = Get-TemurinJreInfo; Info ("[DryRun] 여기서 설치 여부를 물어볼 예정입니다: Eclipse Temurin 21 JRE x64 ({0}, {1:N0} MB, SHA256 {2}...) 을 backend\tools 안에 풀기만 합니다 (관리자 권한 불필요)." -f $pkg.name, ($pkg.size / 1MB), $pkg.checksum.Substring(0, 12)) }
        catch { Info ("[DryRun] 설치 정보를 읽지 못했습니다 (인터넷 문제일 수 있음): " + $_.Exception.Message) }
        return
    }
    $q = "Eclipse Temurin 21 JRE(약 50 MB, 공식 adoptium.net 에서 SHA256 확인)를 이 프로그램 폴더(backend\tools) 안에 설치할까요? 관리자 권한은 필요 없습니다. 안 하면 AI 가 문법을 고칩니다. (Y/N, 그냥 Enter 는 Y)"
    if (-not (Ask-YN $q $true)) { Info "Java 설치를 건너뜁니다. 문법 교정은 AI 가 합니다. (설치.bat 을 다시 실행하면 다시 물어봅니다)"; return }
    try {
        if ((Install-TemurinJre) -and (Find-Java17)) { Info ("Java 설치 완료: " + (Find-Java17)) }
        else { Warn "Java 를 설치했지만 찾지 못했습니다. 문법 교정은 AI 가 합니다." }
    } catch { Warn ("Java 설치에 실패했습니다: " + $_.Exception.Message + " 문법 교정은 AI 가 합니다. 직접 설치하려면 https://adoptium.net 의 JRE 17 이상을 설치하세요 (프로그램이 자동으로 찾습니다).") }
}

# =================================================================== 본문
$exitCode = 0
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()
Log "==================== 설치 시작 ===================="
Log ("폴더: $Root  / 사용자: $env:USERNAME / PS $($PSVersionTable.PSVersion)")
try {
    Say "=============================================" "Cyan"
    Say "   회화 연습 설치 (영어 / 일본어)" "Cyan"
    Say "=============================================" "Cyan"
    Say "설치 폴더: $Root"
    Say "자세한 기록은 install.log 에 남습니다. 중간에 멈춰도 설치.bat 을 다시 실행하면 이어서 진행합니다."

    # ---------------------------------------------------------------- 1. 사전 점검
    Step 1 "사전 점검 (윈도우, 디스크, 인터넷, 그래픽카드)" "check" -Always -DryOK {
        if (-not [Environment]::Is64BitOperatingSystem) { Fail "64비트 윈도우가 필요합니다." }
        if ([Environment]::OSVersion.Version.Major -lt 10) { Fail "윈도우 10 이상이 필요합니다." }
        Info ("윈도우 " + [Environment]::OSVersion.Version + " (64비트) 확인")

        foreach ($f in @("회화연습.exe", "backend\server.py", "backend\curriculum.json", "backend\config.json",
                         "vendor\vendor.json", "vendor\requirements.lock.txt", "vendor\bootstrap.lock.txt",
                         "vendor\models.lock.json", "vendor\install_models.py", "vendor\check_env.py")) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $f))) {
                Fail "설치 파일이 빠져 있습니다: $f`n    zip 파일을 먼저 '모두 압축 풀기' 한 뒤, 풀린 폴더 안에서 설치.bat 을 실행해 주세요."
            }
        }
        if ($Root -like "\\*") { Fail "네트워크 경로에는 설치할 수 없습니다. 내 컴퓨터의 폴더로 복사해서 실행해 주세요." }
        # 인터넷에서 받은 zip 의 '차단' 표시 제거 (SmartScreen 경고 방지)
        Get-ChildItem -LiteralPath $Root -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike "*\runtime\*" -and $_.FullName -notlike "*\models\*" } |
            Unblock-File -ErrorAction SilentlyContinue

        # 경로 길이: 윈도우 기본 설정은 260자 제한이라 설치 폴더 이름이 길면 파이썬 패키지가 깨진다
        $lp = 0
        try { $lp = [int](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -ErrorAction Stop).LongPathsEnabled } catch {}
        Info ("설치 폴더 경로 길이: {0}자 (긴 경로 지원: {1})" -f $Root.Length, $(if ($lp -eq 1) { "켜짐" } else { "꺼짐" }))
        if ($Root.Length -gt 95 -and $lp -ne 1) {
            Fail ("설치 폴더 경로가 너무 깁니다 ({0}자, 최대 95자).`n    예: C:\회화 연습  처럼 짧은 폴더로 옮긴 뒤 다시 실행해 주세요." -f $Root.Length)
        }

        # 디스크 여유 공간 (설치 드라이브 20 GB)
        $drv = New-Object System.IO.DriveInfo($Root.Substring(0, 1))
        $freeGb = [math]::Round($drv.AvailableFreeSpace / 1GB, 1)
        Info ("설치 드라이브 {0} 여유 공간: {1} GB (필요 20 GB 이상)" -f $drv.Name, $freeGb)
        if ($freeGb -lt 20) {
            if (-not (Test-Path -LiteralPath $Py)) { Fail "디스크 여유 공간이 부족합니다 ($freeGb GB). 20 GB 이상 비워 주세요." }
            Warn "디스크 여유 공간이 20 GB 보다 적습니다 ($freeGb GB). 이미 설치가 진행된 상태라 계속합니다."
        }
        # 인터넷
        $net = @{}
        foreach ($h in @("https://pypi.org", "https://huggingface.co")) {
            $net[$h] = Test-Url $h
            Info ("인터넷 연결 {0}: {1}" -f $h, $(if ($net[$h]) { "OK" } else { "안 됨" }))
        }
        if (-not $net["https://pypi.org"] -and -not (Test-Path (Join-Path $StateDir "04-packages.ok"))) {
            Fail "인터넷에 연결되어 있지 않습니다 (pypi.org). 연결을 확인한 뒤 다시 실행해 주세요."
        }
        # 그래픽카드
        $gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "NVIDIA" })
        if ($gpu.Count -gt 0) { Info ("NVIDIA 그래픽카드: " + ($gpu[0].Name) + " -> 음성 인식을 GPU 로 빠르게 돌립니다") }
        else { Info "NVIDIA 그래픽카드가 없습니다 -> 음성 인식이 CPU 로 동작합니다 (조금 느립니다). 설치는 계속됩니다." }
    }

    # ---------------------------------------------------------------- AI 엔진 선택
    if (-not $DryRun) { New-Item -ItemType Directory -Force $StateDir | Out-Null }
    $engineFile = Join-Path $StateDir "engine.txt"
    if ($Engine -eq "") {
        if (-not $DryRun -and (Test-Path -LiteralPath $engineFile)) {
            $Engine = (Get-Content -LiteralPath $engineFile -Raw).Trim()
            if (-not $EngineInfo.ContainsKey($Engine)) { $Engine = "" }   # 예전 버전이 적어 둔 다른 값은 무시하고 다시 묻는다
            if ($Engine -ne "") { Say ""; Say ("이전에 고른 AI 엔진을 이어서 사용합니다: " + $EngineInfo[$Engine].Name + "  (바꾸려면 설치.bat -Engine deepseek 또는 -Engine local)") "Gray" }
        }
    }
    if ($Engine -eq "") { $Engine = if ($Yes) { "deepseek" } else { Select-Engine } }
    if (-not $DryRun) { Write-Utf8 $engineFile $Engine }
    $EngInfo = $EngineInfo[$Engine]
    Say ("AI 엔진: " + $EngInfo.Name) "Green"
    Log "engine=$Engine provider=$($EngInfo.Provider)"
    if ($Engine -eq "local") {
        $sysFree = [math]::Round((New-Object System.IO.DriveInfo($env:SystemDrive.Substring(0, 1))).AvailableFreeSpace / 1GB, 1)
        Info ("(Ollama 와 AI 모델은 사용자 폴더에 저장됩니다. C: 여유 {0} GB, 약 7 GB 필요)" -f $sysFree)
    }

    # ---------------------------------------------------------------- 2. 파이썬
    Step 2 "파이썬 3.10.11 (포터블) 풀기" "python" {
        $vj = Get-Content -LiteralPath (Join-Path $Vendor "vendor.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $zip = Join-Path $Vendor $vj.python.file
        if (-not (Test-Path -LiteralPath $zip)) { Fail "vendor\$($vj.python.file) 가 없습니다." }
        $h = Get-Sha256 $zip
        if ($h -ne $vj.python.sha256) { Fail "파이썬 압축 파일이 손상되었습니다 (SHA256 불일치)." }
        Info "SHA256 확인 OK"
        if (Test-Path -LiteralPath $PyDir) { Remove-Item -LiteralPath $PyDir -Recurse -Force }
        New-Item -ItemType Directory -Force $Runtime | Out-Null
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $PyDir)
        $pth = Get-ChildItem -LiteralPath $PyDir -Filter "python*._pth" | Select-Object -First 1
        if (-not $pth) { Fail "python._pth 파일을 찾지 못했습니다." }
        $zipName = ($pth.BaseName -replace "\._pth$", "") + ".zip"
        $lines = @($zipName, ".", "Lib\site-packages", "..\..\backend", "", "import site")
        Write-Utf8 $pth.FullName (($lines -join "`r`n") + "`r`n")
        New-Item -ItemType Directory -Force (Join-Path $PyDir "Lib\site-packages") | Out-Null
        $code = Invoke-Native $Py @("-X", "utf8", "-c", "import sys, ssl, ctypes, sqlite3, site; print(sys.version); print(sys.path)") -Quiet
        if ($code -ne 0) { Fail "내장 파이썬이 실행되지 않습니다.`n    (Visual C++ 재배포 가능 패키지가 없거나 백신이 막았을 수 있습니다)`n    $($script:LastOutput -join ' ')" }
        Info ("파이썬 실행 확인: " + $script:LastOutput[0])
    }

    # ---------------------------------------------------------------- 3. pip
    Step 3 "pip 준비 (개발 PC 와 같은 버전)" "pip" {
        $boot = @(Get-Content -LiteralPath (Join-Path $Vendor "bootstrap.lock.txt") -Encoding UTF8 | Where-Object { $_.Trim() -ne "" })
        Info ("고정 버전: " + ($boot -join ", "))
        $getpip = Join-Path $Vendor "get-pip.py"
        $vj = Get-Content -LiteralPath (Join-Path $Vendor "vendor.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Get-Sha256 $getpip) -ne $vj.getpip.sha256) { Fail "vendor\get-pip.py 가 손상되었습니다 (SHA256 불일치)." }
        $env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
        $env:PIP_NO_INPUT = "1"
        $pipArgs = @("-X", "utf8", $getpip) + $boot + @("--no-wheel", "--no-warn-script-location", "--no-cache-dir")
        $code = Invoke-Native $Py $pipArgs
        if ($code -ne 0) { Fail "pip 설치에 실패했습니다. 인터넷 연결을 확인해 주세요." }
        $code = Invoke-Native $Py @("-X", "utf8", "-m", "pip", "--version") -Quiet
        Info ($script:LastOutput -join " ")
    }

    # ---------------------------------------------------------------- 4. 패키지
    Step 4 "파이썬 패키지 설치 (PyTorch, Whisper, Kokoro 등 - 가장 오래 걸립니다)" "packages" {
        $env:PIP_DISABLE_PIP_VERSION_CHECK = "1"
        $env:PIP_NO_INPUT = "1"
        $env:PIP_NO_CACHE_DIR = "1"   # 다운로드 캐시를 남기지 않는다
        $lock = Join-Path $Vendor "requirements.lock.txt"
        $wheels = Join-Path $Vendor "wheels"
        $n = @(Get-Content -LiteralPath $lock -Encoding UTF8 | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") }).Count
        Info "$n 개 패키지를 개발 PC 와 똑같은 버전으로 설치합니다. 10~30분 걸릴 수 있습니다."
        $pipArgs = @("-X", "utf8", "-m", "pip", "install", "--no-deps", "--no-cache-dir", "--no-warn-script-location",
                  "--progress-bar", "off", "--disable-pip-version-check", "-r", $lock)
        if (Test-Path -LiteralPath $wheels) { $pipArgs += @("--find-links", $wheels) }
        if ((Get-Content -LiteralPath $lock -Raw) -match "\+cpu") { $pipArgs += @("--extra-index-url", "https://download.pytorch.org/whl/cpu") }
        $ok = $false
        for ($try = 1; $try -le 3 -and -not $ok; $try++) {
            if ($try -gt 1) { Warn "다시 시도합니다 ($try/3)..."; Start-Sleep -Seconds 5 }
            $code = Invoke-Native $Py $pipArgs
            if ($code -eq 0) { $ok = $true }
        }
        if (-not $ok) { Fail "패키지 설치에 실패했습니다. install.log 를 확인하고, 인터넷 연결 상태에서 설치.bat 을 다시 실행해 주세요." }
        Invoke-Native $Py @("-X", "utf8", "-m", "pip", "check") -Quiet | Out-Null
        Log ("pip check: " + ($script:LastOutput -join " | "))
        $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "check_env.py"), $lock, (Join-Path $Vendor "bootstrap.lock.txt"))
        if ($code -ne 0) { Fail "설치된 패키지가 개발 PC 목록과 다릅니다. 위 목록을 확인하고 다시 실행해 주세요." }
        Info "설치된 패키지 목록이 개발 PC 와 완전히 같습니다."
    }

    # ---------------------------------------------------------------- 5. Ollama
    $script:OllamaExe = $null
    $modelsLock = Get-Content -LiteralPath (Join-Path $Vendor "models.lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Engine -eq "deepseek") {
    # ================= DeepSeek 무료 (OpenCode). Ollama 는 설치하지 않습니다 =================
    Step 5 "Node.js 확인 (22 이상 필요)" "node" -DryOK {
        Refresh-Path
        $major = Get-NodeMajor
        if ($major -ge 22) { Info ("Node.js v$major 사용 가능") }
        else {
            if ($major -gt 0) { Info "설치된 Node.js 가 너무 오래되었습니다 (v$major)." } else { Info "Node.js 가 설치되어 있지 않습니다." }
            if ($DryRun) { Info "[DryRun] 여기서 Node.js 22 이상(공식 LTS MSI, SHA256 확인)을 설치할 예정입니다. 실제로는 설치하지 않습니다."; return }
            if (-not (Ask-YN "OpenCode 를 설치하려면 Node.js 22 이상(공식 LTS)이 필요합니다. 지금 설치할까요? (Y/N)")) {
                Fail "Node.js 없이는 OpenCode 를 설치할 수 없습니다. https://nodejs.org 에서 LTS 를 설치한 뒤 다시 실행하거나, 오프라인 로컬 AI 를 고르세요 (설치.bat -Engine local)."
            }
            if (-not (Install-NodeLts)) { Fail "Node.js 설치에 실패했습니다. https://nodejs.org 에서 직접 설치한 뒤 설치.bat 을 다시 실행해 주세요." }
            Info ("Node.js 설치 완료: v" + (Get-NodeMajor))
        }
        if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { Fail "npm 을 찾지 못했습니다. Node.js 를 다시 설치해 주세요." }
    }
    Step 6 "OpenCode 설치와 로그인 (무료 DeepSeek V4.1 Flash)" "opencode" -Always -DryOK {
        Refresh-Path
        $have = Get-NpmGlobalVersion $OpenCodePkg
        $npmArgs = @("install", "-g", "$OpenCodePkg@$OpenCodeVer", "--allow-scripts=$OpenCodePkg")
        if ($have -eq $OpenCodeVer) { Info "$OpenCodePkg@$have 이(가) 이미 설치되어 있습니다 (고정 버전과 같음)." }
        else {
            if ($have) { Info "다른 버전이 설치되어 있습니다 ($have). 고정 버전 $OpenCodeVer 으로 맞춥니다." }
            if ($DryRun) { Info "[DryRun] 설치 예정: npm $($npmArgs -join ' ')"; return }
            $ok = $false
            for ($try = 1; $try -le 3 -and -not $ok; $try++) {
                if ($try -gt 1) { Warn "다시 시도합니다 ($try/3)..."; Start-Sleep -Seconds 5 }
                $code = Invoke-Native (Get-Command npm.cmd).Source $npmArgs
                if ($code -eq 0) { $ok = $true }
            }
            if (-not $ok) { Fail "$OpenCodePkg 설치에 실패했습니다. install.log 를 확인해 주세요." }
            Refresh-Path
        }
        $oc = Find-OpenCode
        if (-not $oc) { Fail "opencode 명령을 찾지 못했습니다. 새 창에서 설치.bat 을 다시 실행해 보세요." }
        Info "OpenCode: $oc"
        # 로그인: 사람이 직접 한다. 이 스크립트는 계정 정보를 보거나 저장하지 않는다.
        if (Test-OpenCodeLogin $oc) { Info "OpenCode 에 이미 로그인되어 있습니다." }
        elseif ($DryRun) { Info "[DryRun] 로그인 필요: opencode auth login (실제로는 실행하지 않습니다)" }
        elseif ($Yes) { Warn "OpenCode 에 로그인되어 있지 않은 것 같습니다. 무인 설치라 로그인은 건너뜁니다. 나중에 터미널에서 'opencode auth login' 을 실행해 주세요." }
        else {
            Say ""
            Say "무료 DeepSeek 을 쓰려면 OpenCode 에 로그인해야 합니다. 각자 본인의 OpenCode 계정을 씁니다." "Yellow"
            Say "곧 'opencode auth login' 이 열립니다. 목록에서 OpenCode 를 고르고, 안내에 따라 본인 계정으로 로그인해 주세요." "Yellow"
            Say "로그인은 OpenCode 가 직접 처리하며, 이 설치 프로그램은 계정 정보를 보거나 저장하지 않습니다." "Yellow"
            Read-Host "준비되면 Enter 를 누르세요" | Out-Null
            & $oc auth login
            Log "opencode auth login 종료 코드: $LASTEXITCODE"
            if (Test-OpenCodeLogin $oc) { Info "로그인을 확인했습니다." }
            else { Warn "로그인을 확인하지 못했습니다. 나중에 터미널에서 'opencode auth login' 을 실행해 주세요. 그 전에는 AI 대화가 동작하지 않습니다." }
        }
        # 무료 모델이 OpenCode 에 아직 있는지 확인 (무료 제공 여부는 OpenCode 가 정한다)
        if (Test-OpenCodeModel $oc) { Info "무료 모델 확인: $OpenCodeModel" }
        else {
            Warn "OpenCode 모델 목록에서 $OpenCodeModel 을(를) 찾지 못했습니다. 무료 제공이 바뀌었거나 인터넷/로그인 문제일 수 있습니다. 오프라인 로컬 AI 를 설치해 두면 프로그램이 자동으로 그쪽으로 바꿔 답합니다 (설치.bat -Engine local)."
        }
    }
    } else {
    # ================= 로컬 AI (Ollama + qwen3:8b) =================
    Step 5 "Ollama (AI 대화 엔진) 설치 확인" "ollama" {
        $exe = Find-Ollama
        if ($exe) { Info "Ollama 가 이미 설치되어 있습니다: $exe" }
        else {
            Info "Ollama 가 없습니다. 공식 설치 파일을 받아서 조용히 설치합니다."
            $tmp = Join-Path $env:TEMP "OllamaSetup.exe"
            $url = "https://ollama.com/download/OllamaSetup.exe"
            Info "다운로드: $url (1 GB 안팎, 시간이 걸립니다)"
            $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($curl) {
                $code = Invoke-Native $curl.Source @("-L", "--fail", "--retry", "3", "-C", "-", "-o", $tmp, $url)
                if ($code -ne 0) { Fail "Ollama 설치 파일을 받지 못했습니다." }
            } else { (New-Object Net.WebClient).DownloadFile($url, $tmp) }
            $sig = Get-AuthenticodeSignature -LiteralPath $tmp
            Log ("서명 상태: $($sig.Status) / $($sig.SignerCertificate.Subject)")
            if ($sig.Status -ne "Valid") { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; Fail "Ollama 설치 파일의 디지털 서명이 올바르지 않습니다 ($($sig.Status)). 보안을 위해 중단합니다." }
            if ($sig.SignerCertificate.Subject -notmatch "(?i)ollama") { Remove-Item $tmp -Force -ErrorAction SilentlyContinue; Fail "Ollama 설치 파일의 서명자가 예상과 다릅니다: $($sig.SignerCertificate.Subject)" }
            Info "디지털 서명 확인 OK ($($sig.SignerCertificate.Subject))"
            $p = Start-Process -FilePath $tmp -ArgumentList @("/VERYSILENT", "/NORESTART", "/SUPPRESSMSGBOXES", "/LOG=`"$env:TEMP\ollama-install.log`"") -Wait -PassThru
            Log ("OllamaSetup 종료 코드: " + $p.ExitCode)
            Start-Sleep -Seconds 3
            $exe = Find-Ollama
            if (-not $exe) { Fail "Ollama 설치가 끝났지만 ollama.exe 를 찾지 못했습니다. https://ollama.com/download 에서 직접 설치한 뒤 다시 실행해 주세요." }
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            Info "Ollama 설치 완료: $exe"
        }
        if (-not (Ensure-OllamaRunning $exe)) { Fail "Ollama 서버가 켜지지 않습니다. 시작 메뉴에서 Ollama 를 한 번 실행한 뒤 다시 시도해 주세요." }
        Info "Ollama 서버 응답 OK"
    }
    $script:OllamaExe = Find-Ollama

    # ---------------------------------------------------------------- 6. Ollama 모델
    Step 6 ("AI 모델 {0} 받기 (약 5 GB)" -f $modelsLock.ollama.model) "llm" {
        if (-not $script:OllamaExe) { Fail "Ollama 를 찾지 못했습니다." }
        if (-not (Ensure-OllamaRunning $script:OllamaExe)) { Fail "Ollama 서버가 응답하지 않습니다." }
        $tag = $modelsLock.ollama.model
        $have = Get-OllamaTags | Where-Object { $_.name -eq $tag }
        if ($have) { Info "$tag 모델이 이미 있습니다." }
        else {
            $ok = $false
            for ($try = 1; $try -le 3 -and -not $ok; $try++) {
                if ($try -gt 1) { Warn "다시 시도합니다 ($try/3)..."; Start-Sleep -Seconds 5 }
                Log "> ollama pull $tag"
                $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
                & $script:OllamaExe pull $tag     # 진행률이 화면에 바로 보이도록 파이프 없이 실행
                $code = $LASTEXITCODE
                $ErrorActionPreference = $old
                Log "  (exit $code)"
                if ($code -eq 0) { $ok = $true }
            }
            if (-not $ok) { Fail "$tag 모델을 받지 못했습니다. 인터넷 연결을 확인하고 다시 실행해 주세요." }
        }
        $have = Get-OllamaTags | Where-Object { $_.name -eq $tag }
        if (-not $have) { Fail "$tag 모델이 목록에 없습니다." }
        $want = $modelsLock.ollama.digest
        if ($have.digest -eq $want) { Info ("모델 다이제스트가 개발 PC 와 같습니다 (" + $want.Substring(0, 12) + ")") }
        else {
            Warn ("모델 버전 경고: 받은 {0} 모델(다이제스트 {1})이 개발 PC 의 것({2})과 다릅니다. Ollama 쪽에서 모델이 업데이트된 것으로 보입니다. 동작에는 문제가 없을 가능성이 높지만 답변 품질이 조금 다를 수 있습니다." -f $tag, $have.digest.Substring(0, 12), $want.Substring(0, 12))
        }
    }
    }   # end engine branch

    # ---------------------------------------------------------------- 7. 음성 모델
    Step 7 "음성 모델 받기 (Whisper small, Kokoro-82M 등 - 약 2 GB)" "models" {
        New-Item -ItemType Directory -Force $HfDir | Out-Null
        $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "install_models.py"), (Join-Path $Vendor "models.lock.json"), $HfDir)
        if ($code -ne 0) { Fail "음성 모델을 받거나 검증하지 못했습니다 (위 [FAIL] 줄 참고). 다시 실행하면 이어서 받습니다." }
        # 받기에만 쓰는 임시 캐시(xet, .locks)는 지운다. 목록에 없는 모델은 건드리지 않는다고 확인된 것만 지운다.
        $null = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "prunehf", (Join-Path $Vendor "models.lock.json"), $HfDir, "--apply") -Quiet
        Info ((@($script:LastOutput | Where-Object { $_ -like "PRUNE_RESULT*" }) | Select-Object -Last 1))
    }

    # ---------------------------------------------------------------- 8. prefetch
    Step 8 "나머지 데이터 준비 (일본어 사전, 목소리, 음성 인식 장치 확인)" "prefetch" {
        $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Backend "server.py"), "--prefetch")
        $txt = $script:LastOutput -join "`n"
        foreach ($needle in @("[prefetch] Whisper OK", "[prefetch] Kokoro en OK", "[prefetch] Kokoro ja OK", "[prefetch] pyopenjtalk OK")) {
            if (-not $txt.Contains($needle)) { Fail "준비 단계에서 '$needle' 를 확인하지 못했습니다. install.log 를 확인해 주세요." }
        }
        if ($code -ne 0) { Fail "prefetch 가 오류로 끝났습니다 (종료 코드 $code)." }
        $m = [regex]::Match($txt, "Whisper OK on (\S+)")
        if ($m.Success) { Info ("음성 인식 장치: " + $m.Groups[1].Value) }
        # 필수 파일 확인
        $mustExist = @()
        foreach ($e in $modelsLock.hf) {
            $base = if ($e.cache_subdir) { Join-Path $HfDir $e.cache_subdir } else { $HfDir }
            foreach ($f in $e.files) {
                $mustExist += (Join-Path $base ("models--" + ($e.repo_id -replace "/", "--") + "\snapshots\" + $e.revision + "\" + ($f.path -replace "/", "\")))
            }
        }
        $missing = @($mustExist | Where-Object { -not (Test-Path -LiteralPath $_) })
        if ($missing.Count -gt 0) { Fail ("모델 파일이 없습니다: " + $missing[0]) }
        Info ("모델 파일 {0}개 존재 확인" -f $mustExist.Count)
    }

    # ---------------------------------------------------------------- 9. LanguageTool (문법 검사기, 선택)
    # 공식 zip 을 받아 models.lock.json 의 SHA256 으로 검증한다. 실패하거나 Java 17+ 가 없으면 경고만 하고
    # 계속한다 (문법 교정은 AI 가 대신 한다). 매번 확인하지만 이미 설치되어 있으면 바로 넘어간다.
    Step 9 "문법 검사기 LanguageTool 받기 (약 250 MB, Java 17 이상 필요)" "languagetool" -Always -DryOK {
        $lt = $modelsLock.languagetool
        if (-not $lt) { Info "설치 패키지에 LanguageTool 정보가 없어 건너뜁니다 (문법 교정은 AI 가 합니다)."; return }
        if ($DryRun) { Info "[DryRun] LanguageTool 은 받지 않습니다. Java 17 이상 확인만 합니다."; Ensure-Java; return }
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
            $zip = Join-Path $env:TEMP ("LanguageTool-{0}.zip" -f $lt.version)
            if (-not ((Test-Path -LiteralPath $zip) -and (Get-Sha256 $zip) -eq $lt.sha256)) {
                Info ("다운로드: {0} ({1:N0} MB)" -f $lt.url, ($lt.size / 1MB))
                $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
                $ok = $false
                for ($try = 1; $try -le 3 -and -not $ok; $try++) {
                    if ($try -gt 1) { Warn "다시 시도합니다 ($try/3)..."; Start-Sleep -Seconds 5 }
                    try {
                        if ($curl) { $code = Invoke-Native $curl.Source @("-L", "--fail", "--retry", "3", "-sS", "-o", $zip, $lt.url) -Quiet; $ok = ($code -eq 0) }
                        else { (New-Object Net.WebClient).DownloadFile($lt.url, $zip); $ok = $true }
                    } catch { Log ("다운로드 오류: " + $_.Exception.Message) }
                }
                if (-not $ok) { Warn "LanguageTool 을 받지 못했습니다. 문법 교정은 AI 가 합니다 (설치.bat 을 다시 실행하면 다시 시도합니다)."; return }
            }
            $h = Get-Sha256 $zip
            if ($h -ne $lt.sha256 -or (Get-Item -LiteralPath $zip).Length -ne [int64]$lt.size) {
                Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                Warn "받은 LanguageTool 파일이 개발 PC 의 것과 다릅니다 (SHA256 불일치). 보안을 위해 설치하지 않습니다. 문법 교정은 AI 가 합니다."
                return
            }
            Info "SHA256 확인 OK"
            $tmpDir = Join-Path $ltRoot "_extract"
            if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmpDir)
            $dst = Join-Path $ltRoot $lt.dir
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            Move-Item -LiteralPath (Join-Path $tmpDir $lt.dir) -Destination $dst
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $jar)) { Warn "LanguageTool 압축을 풀었지만 languagetool-server.jar 가 없습니다."; return }
            Write-Utf8 $manifest ([pscustomobject]@{ version = $lt.version; dir = $lt.dir; url = $lt.url; sha256 = $lt.sha256; size = $lt.size } | ConvertTo-Json)
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            Info ("LanguageTool {0} 설치 완료" -f $lt.version)
        }
        # Java 17+: 없으면 설치를 물어본다 (서버는 backend\grammar.py 의 규칙으로 같은 곳을 찾는다)
        Ensure-Java
        $code = Invoke-Native $Py @("-X", "utf8", "-c", "import grammar; j = grammar.find_java(); print('JAVA=' + (j or '') + ' ' + (grammar._java.get('version') or ''))") -Quiet
        $jline = ($script:LastOutput | Where-Object { $_ -like "JAVA=*" } | Select-Object -First 1)
        if ($code -eq 0 -and $jline -and $jline -ne "JAVA= ") { Info ("서버가 찾는 Java: " + $jline.Substring(5)) }
        else { Warn "Java 17 이상을 찾지 못했습니다. 문법 검사기는 Java 를 설치하면 자동으로 켜지고, 그 전까지는 AI 가 문법을 고칩니다." }
    }

    # ---------------------------------------------------------------- 10. 설정
    Step 10 "설정 파일 (프로그램 기본 설정, AI 엔진)" "prefs" -Always -DryOK {
        # AI 엔진 종류를 backend\config.json 에 기록 (다른 설정은 그대로 둔다)
        $cfgPath = Join-Path $Backend "config.json"
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -contains "llm_provider") { $cfg.llm_provider = $EngInfo.Provider }
        else { $cfg | Add-Member -NotePropertyName "llm_provider" -NotePropertyValue $EngInfo.Provider }
        if ($Engine -eq "local" -and $modelsLock.ollama -and $modelsLock.ollama.model) {
            # 로컬 엔진은 방금 받은 모델 태그를 쓴다 (업데이트 때 태그가 바뀌면 이 값을 기준으로 옛 모델을 지운다)
            if ($cfg.PSObject.Properties.Name -contains "llm_model") { $cfg.llm_model = $modelsLock.ollama.model }
            else { $cfg | Add-Member -NotePropertyName "llm_model" -NotePropertyValue $modelsLock.ollama.model }
        }
        Write-Utf8 $cfgPath ($cfg | ConvertTo-Json -Depth 8)
        Info ("config.json: llm_provider = " + $EngInfo.Provider)
        if ($DryRun) { Info "[DryRun] 학습 기록/설정 기본값 복사는 건너뜁니다."; return }
        $dataDir = Join-Path $env:APPDATA "Godot\app_userdata\회화 연습"
        New-Item -ItemType Directory -Force $dataDir | Out-Null
        foreach ($name in @("prefs.json", "progress.json")) {
            $src = Join-Path $Root ("defaults\" + $name)
            $dst = Join-Path $dataDir $name
            if (-not (Test-Path -LiteralPath $src)) { continue }
            if (Test-Path -LiteralPath $dst) { Info "$name : 이미 있어서 그대로 둡니다." }
            else { Copy-Item -LiteralPath $src -Destination $dst; Info "$name : 기본값을 복사했습니다." }
        }
    }

    # ---------------------------------------------------------------- 11. 동작 확인
    Step 11 "동작 확인 (임시 서버를 켜서 음성 인식 / 목소리 / AI 확인)" "verify" -Always {
        if ($Engine -eq "local" -and -not (Ensure-OllamaRunning $script:OllamaExe)) { Fail "Ollama 서버가 응답하지 않습니다." }
        Refresh-Path   # DeepSeek(OpenCode): 방금 설치한 node / npm 전역 경로가 서버에 전달되도록
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
                Start-Sleep -Seconds 2
                if ($proc.HasExited) { break }
                try {
                    $h = Invoke-RestMethod "http://127.0.0.1:$port/health" -TimeoutSec 5
                    $last = $h
                    # 로컬 엔진은 AI 도 준비되어야 합격. DeepSeek 은 로그인/무료 제공 여부가 이 설치 밖의 일이라 경고만 한다
                    if ($h.ok -and $h.stt -and $h.tts.en -and $h.tts.ja -and ($h.llm -or $Engine -eq "deepseek")) { $good = $true; break }
                } catch {}
                if (([int]$sw.Elapsed.TotalSeconds) % 10 -lt 2) { Info ("서버 준비 중... {0}초" -f [int]$sw.Elapsed.TotalSeconds) }
            }
        } finally {
            if ($proc -and -not $proc.HasExited) {
                Invoke-Native "taskkill.exe" @("/PID", "$($proc.Id)", "/T", "/F") -Quiet | Out-Null
            }
        }
        if ($last) { Log ("마지막 /health: " + ($last | ConvertTo-Json -Compress)) }
        if (-not $good) {
            $lg = Join-Path $Backend "logs\server-install.log"
            if (Test-Path $lg) { Log "---- server-install.log (끝부분) ----"; Get-Content $lg -Tail 25 -Encoding UTF8 | ForEach-Object { Log $_ } }
            $why = if ($last -and -not $last.llm) { "AI 엔진(Ollama)이 준비되지 않았습니다." } elseif ($last) { "음성 인식 또는 목소리가 준비되지 않았습니다." } else { "서버가 켜지지 않았습니다." }
            Fail "동작 확인에 실패했습니다: $why`n    backend\logs\server-install.log 와 install.log 를 확인해 주세요."
        }
        if ($last.llm) { Info ("/health 정상: 음성 인식 OK, 목소리(영어/일본어) OK, AI 엔진({0}) OK, 채점 {1}" -f $last.llm_model, $last.score) }
        else { Warn "음성 인식과 목소리는 정상이지만 DeepSeek(OpenCode)에는 아직 연결되지 않았습니다. 터미널에서 'opencode auth login' 으로 로그인했는지 확인해 주세요. 그 전에는 인터넷이 없을 때처럼 AI 대화가 동작하지 않습니다." }
        Info ("문법 검사기(LanguageTool): " + $(if ($last.grammar) { "사용" } else { "꺼짐 (AI 가 문법을 고칩니다)" }))
    }

    # ---------------------------------------------------------------- 바로가기
    if (-not $NoShortcut -and -not $DryRun) {
        Say ""
        if (Ask-YN "바탕화면에 바로가기를 만들까요? (Y/N)") {
            $desktop = [Environment]::GetFolderPath("Desktop")
            $lnkPath = Join-Path $desktop "회화 연습.lnk"
            $ws = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($lnkPath)
            $lnk.TargetPath = Join-Path $Root "회화연습.exe"
            $lnk.WorkingDirectory = $Root
            $lnk.Description = "영어/일본어 회화 연습"
            $lnk.Save()
            Say "    바로가기를 만들었습니다: $lnkPath" "Green"
        }
    }
}
catch {
    $exitCode = 1
    Say "" "Red"
    Say "[설치 실패] $($_.Exception.Message)" "Red"
    Log ("스택: " + $_.ScriptStackTrace)
    Say "해결 방법: 위 메시지를 확인하고 (인터넷 연결 등) 설치.bat 을 다시 실행해 주세요. 끝난 단계는 건너뜁니다." "Yellow"
    Say "문제가 계속되면 install.log 파일을 보내 주세요." "Yellow"
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
if ($exitCode -eq 0 -and $DryRun) {
    Say ""
    Say "[DryRun] 확인 끝: AI 엔진 = $($EngInfo.Name), config.json 에 llm_provider 를 기록했습니다. 아무것도 설치하지 않았습니다." "Green"
}
elseif ($exitCode -eq 0) {
    # 설치된 버전 기록 (업데이트.bat 이 GitHub 최신 릴리스와 비교한다)
    try {
        $mf = Join-Path $Root "manifest.json"
        if (Test-Path -LiteralPath $mf) {
            $man = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Utf8 (Join-Path $Root "version.txt") ($man.version + "`r`n")
            New-Item -ItemType Directory -Force $StateDir | Out-Null
            Write-Utf8 (Join-Path $StateDir "installer_version.txt") ("" + $man.installer_version)
            Say ("설치된 버전: v" + $man.version)
        }
    } catch { Log ("version.txt 기록 실패: " + $_.Exception.Message) }
    Say ""
    Say "설치가 끝났습니다! 회화연습.exe 를 더블클릭해서 시작하세요. (사용법.txt 참고)" "Green"
    Say "새 버전이 나오면 이 폴더의 업데이트.bat 을 더블클릭하면 됩니다." "Green"
    if ($Engine -eq "deepseek") { Say "인터넷이 안 될 때도 쓰려면 설치.bat -Engine local 로 오프라인 로컬 AI 를 추가로 설치할 수 있습니다." "Gray" }
}
Log "==================== 설치 종료 (코드 $exitCode) ===================="
$script:LogW.Close()
exit $exitCode
