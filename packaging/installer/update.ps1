# 회화 연습 업데이트. 보통은 업데이트.bat 을 더블클릭해서 실행합니다.
#   powershell -ExecutionPolicy Bypass -File update.ps1 [-Yes] [-CheckOnly] [-Force] [-Source <로컬 폴더>]
# GitHub 의 최신 릴리스(release.json 의 repo)와 version.txt 를 비교해서, 새 버전이면 업데이트 zip 을 받아
# SHA256 을 확인하고 적용합니다. 바뀐 파일은 backup\<이전 버전>\ 에 보관하고, 실패하면 되돌립니다.
# 정리 정책: 백업은 직전 1개만 남기고, 내려받은 zip 과 임시 폴더는 성공/실패와 상관없이 지우고, pip 캐시는 쓰지 않고,
# 새 잠금 목록(models.lock.json)에 없는 모델 파일과 옛 Ollama 모델은 지웁니다. 업데이트 전후 폴더 크기를 보여 줍니다.
param(
    [switch]$Yes,                                  # 질문에 자동으로 Y
    [switch]$CheckOnly,                            # 새 버전이 있는지만 확인
    [switch]$Force,                                # 같은 버전이어도 다시 적용
    [string]$Source = $(if ($env:HOEHWA_TEST_MODE -eq "1") { $env:HOEHWA_UPDATE_SOURCE })   # (테스트용) GitHub 대신 로컬 폴더: latest.json + 자산 파일. 환경변수는 HOEHWA_TEST_MODE=1 일 때만 읽는다 (-Source 는 직접 적어야 하는 인자라 그대로 동작)
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$env:PIP_NO_CACHE_DIR = "1"                        # pip 은 다운로드 캐시를 남기지 않는다
$env:PIP_DISABLE_PIP_VERSION_CHECK = "1"

$Root     = $PSScriptRoot
$Backend  = Join-Path $Root "backend"
$Vendor   = Join-Path $Root "vendor"
$PyDir    = Join-Path $Root "runtime\python"
$Py       = Join-Path $PyDir "python.exe"
$StateDir = Join-Path $Root "runtime\.state"
$HfDir    = Join-Path $Backend "models\hf"
$LogFile  = Join-Path $Root "update.log"
$BackupDir = Join-Path $Root "backup"
$Work     = Join-Path $BackupDir "_update_work"

# 로그가 계속 커지지 않게: 1 MB 가 넘으면 마지막 2000줄만 남긴다
try {
    if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
        $tail = @(Get-Content -LiteralPath $LogFile -Tail 2000 -Encoding UTF8)
        [System.IO.File]::WriteAllLines($LogFile, $tail, (New-Object System.Text.UTF8Encoding($false)))
    }
} catch {}
$script:LogW = New-Object System.IO.StreamWriter($LogFile, $true, (New-Object System.Text.UTF8Encoding($false)))
$script:LogW.AutoFlush = $true
function Log([string]$m) { $script:LogW.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $m) }
# 테스트용 환경변수(HOEHWA_UPDATE_SOURCE / HOEHWA_OLLAMA_EXE / HOEHWA_UPDATE_FAIL / HOEHWA_PIP_DRYRUN)는 HOEHWA_TEST_MODE=1 을 명시했을 때만 동작한다.
# 배포본을 쓰는 PC 에 우연히 남은 환경변수가 업데이트를 바꾸지 못하게 하기 위해서다.
$TestMode = ($env:HOEHWA_TEST_MODE -eq "1")
function Say([string]$m, [string]$color = "White") { Write-Host $m -ForegroundColor $color; Log $m }
function Info([string]$m) { Say ("    " + $m) "Gray" }
function Warn([string]$m) { Say ("    [주의] " + $m) "Yellow" }
function Write-Utf8([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-Sha256([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function Ask-YN([string]$prompt) {
    if ($Yes) { Say "$prompt -> (자동) Y" "Gray"; return $true }
    while ($true) {
        $a = Read-Host $prompt
        if ($a -match '^[yY]') { return $true }
        if ($a -match '^[nN]') { return $false }
        if ([string]::IsNullOrEmpty($a)) { return $false }   # 빈 입력 / 입력 끝(EOF): 안전한 쪽(N)으로 끝낸다
    }
}
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
function Parse-Ver([string]$s) {
    $m = [regex]::Match(("" + $s).Trim().TrimStart("v", "V"), '^\d+(\.\d+){0,3}')
    if (-not $m.Success) { return [version]"0.0" }
    $v = $m.Value; if ($v -notmatch '\.') { $v += ".0" }
    return [version]$v
}
# 업데이트 파일이 가리킬 수 있는 경로: 앱 폴더 안의 평범한 상대 경로만 (.., 절대 경로, 드라이브 문자 거부).
# 설치 구성 요소/사용자 데이터(runtime, backup, 모델, 데이터, 캐시, 로그, 비밀 키 …)는 업데이트가 건드릴 수 없다.
function Test-UpdatePath([string]$rel, [bool]$ForUpdate = $true) {
    if ([string]::IsNullOrWhiteSpace($rel)) { return $false }
    if ($rel -match '^[\\/]' -or $rel -match '^[A-Za-z]:' -or $rel.Contains(":") -or $rel.Contains("\") -or $rel -match '[\x00-\x1f*?"<>|]') { return $false }
    foreach ($seg in $rel.Split("/")) {
        if ($seg -eq "" -or $seg -eq "." -or $seg -eq ".." -or $seg -match '[. ]$') { return $false }
    }
    if ($ForUpdate -and ($rel -match '(?i)^(runtime|backup)/' -or $rel -match '(?i)^backend/(models|data|cache|logs|tools|\.venv)/' -or
        $rel -match '(?i)^backend/secrets\.json' -or $rel -match '(?i)^(version\.txt|install\.log|update\.log)$')) { return $false }
    return $true
}
# 앱 폴더 안의 실제 경로 (밖으로 나가면 예외)
function Rel-Path([string]$rel) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $Root ($rel -replace "/", "\")))
    if (-not $full.StartsWith($Root.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase)) { throw "앱 폴더 밖을 가리키는 경로입니다: $rel" }
    return $full
}
# 이 폴더의 exe / 파이썬으로 실행 중인 프로세스 (이미지 이름이 아니라 실행 파일 경로로 찾는다)
function Get-AppProcesses {
    $pfx = $Root.TrimEnd("\") + "\"
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($pfx, [StringComparison]::OrdinalIgnoreCase) -and $_.ProcessId -ne $PID })
}
function Get-TreeSize([string]$helper, [string[]]$Skip = @()) {
    $a = @("-X", "utf8", $helper, "dirsize", $Root)
    if ($Skip.Count -gt 0) { $a += @("--skip") + $Skip }
    $code = Invoke-Native $Py $a -Quiet
    if ($code -ne 0) { return -1 }
    return [int64]($script:LastOutput | Select-Object -Last 1)
}
function Format-Size([int64]$b) { if ($b -lt 0) { return "?" }; return ("{0:N2} GB" -f ($b / 1GB)) }

# Ollama (로컬 AI 를 쓰는 설치만 해당). HOEHWA_OLLAMA_EXE 는 테스트용(HOEHWA_TEST_MODE=1 일 때만)으로 다른 실행 파일을 가리킨다.
function Find-OllamaExe {
    if ($TestMode -and $env:HOEHWA_OLLAMA_EXE) { return $env:HOEHWA_OLLAMA_EXE }
    $c = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @((Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"), (Join-Path $env:ProgramFiles "Ollama\ollama.exe"))) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
function Ensure-OllamaServing([string]$exe) {
    if ($TestMode -and $env:HOEHWA_OLLAMA_EXE) { return $true }
    $up = { try { Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 4 | Out-Null; return $true } catch { return $false } }
    if (& $up) { return $true }
    Start-Process -FilePath $exe -ArgumentList "serve" -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Seconds 1; if (& $up) { return $true } }
    return $false
}
function Get-OllamaNames([string]$exe) {
    $code = Invoke-Native $exe @("list") -Quiet
    if ($code -ne 0) { return $null }
    return @($script:LastOutput | Select-Object -Skip 1 | ForEach-Object { ($_.Trim() -split "\s+")[0] } | Where-Object { $_ })
}

# ---------------------------------------------------------------- 릴리스 정보
function Get-LatestRelease([string]$repo, [string]$channel) {
    if ($Source) {
        Info "로컬 업데이트 원본을 사용합니다: $Source"
        return (Get-Content -LiteralPath (Join-Path $Source "latest.json") -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    $hdr = @{ "User-Agent" = "hoehwa-practice-updater"; "Accept" = "application/vnd.github+json" }
    $url = if ($channel -eq "stable") { "https://api.github.com/repos/$repo/releases/latest" } else { "https://api.github.com/repos/$repo/releases?per_page=10" }
    try {
        $r = Invoke-WebRequest -Uri $url -Headers $hdr -UseBasicParsing -TimeoutSec 30
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            $code = [int]$resp.StatusCode
            if ($code -eq 403 -or $code -eq 429) {
                $wait = ""
                try {
                    $reset = [int64]$resp.Headers["X-RateLimit-Reset"]
                    if ($reset -gt 0) {
                        $min = [math]::Ceiling(($reset - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) / 60)
                        if ($min -gt 0) { $wait = " 약 $min 분 뒤에" }
                    }
                } catch {}
                throw "GitHub 요청 한도(로그인 없이 1시간 60번)에 걸렸습니다.$wait 다시 시도해 주세요. 설치된 프로그램은 그대로 쓸 수 있습니다."
            }
            if ($code -eq 404) { throw "GitHub 에서 릴리스를 찾지 못했습니다 ($repo). 아직 공개된 버전이 없을 수 있습니다." }
            throw "GitHub 응답 오류 (HTTP $code)."
        }
        throw ("GitHub 에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요. (" + $_.Exception.Message + ")")
    }
    $j = [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    if ($channel -ne "stable") { $j = @($j | Where-Object { -not $_.draft }) | Select-Object -First 1 }
    return $j
}
function Save-Asset($asset, [string]$dest) {
    $src = "" + $asset.browser_download_url
    if ($Source) {
        if (-not [System.IO.Path]::IsPathRooted($src)) { $src = Join-Path $Source $src }
        Copy-Item -LiteralPath $src -Destination $dest -Force
        return
    }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        Log "> curl $src"
        $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        & $curl.Source -L --fail --retry 3 -o $dest $src      # 진행률이 화면에 보이도록 파이프 없이
        $code = $LASTEXITCODE
        $ErrorActionPreference = $old
        if ($code -ne 0) { throw "다운로드 실패: $($asset.name) (curl $code)" }
    } else { (New-Object Net.WebClient).DownloadFile($src, $dest) }
}

# =================================================================== 본문
$exitCode = 0
$phase = "check"
$backup = $null
$pipTouched = $false
$localEngine = $false
$ollamaExe = $null
$pulledNew = $null        # 이번 실행에서 새로 받은 Ollama 모델 태그 (실패하면 지운다)
$oldOllamaTag = $null     # 성공하면 지울 옛 모델 태그
$sizeBefore = -1
Log "==================== 업데이트 시작 ===================="
if ($TestMode) { Say "[테스트 모드] HOEHWA_TEST_MODE=1: 테스트용 환경변수를 사용합니다. 평소에는 켜지 않습니다." "Yellow" }
elseif ($env:HOEHWA_UPDATE_SOURCE -or $env:HOEHWA_OLLAMA_EXE -or $env:HOEHWA_UPDATE_FAIL -or $env:HOEHWA_PIP_DRYRUN) { Log "HOEHWA_* 테스트용 환경변수가 있지만 HOEHWA_TEST_MODE=1 이 아니라서 무시합니다." }
try {
    Say "=============================================" "Cyan"
    Say "   회화 연습 업데이트" "Cyan"
    Say "=============================================" "Cyan"
    $verFile = Join-Path $Root "version.txt"
    if (-not (Test-Path -LiteralPath $verFile) -or -not (Test-Path -LiteralPath $Py)) {
        throw "설치가 끝나지 않은 폴더입니다. 먼저 설치.bat 으로 설치를 마쳐 주세요."
    }
    $curVerText = (Get-Content -LiteralPath $verFile -Raw).Trim()
    $curVer = Parse-Ver $curVerText
    $relCfg = Get-Content -LiteralPath (Join-Path $Root "release.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $channel = if ($relCfg.channel) { $relCfg.channel } else { "stable" }
    Say "현재 버전: v$curVerText   (배포처: github.com/$($relCfg.repo), $channel)"

    $rel = Get-LatestRelease $relCfg.repo $channel
    if (-not $rel) { throw "릴리스 정보를 읽지 못했습니다." }
    $newVerText = ("" + $rel.tag_name).TrimStart("v", "V")
    $newVer = Parse-Ver $newVerText
    if ($newVer -le $curVer -and -not $Force) {
        Say ""
        Say "최신 버전입니다 (v$curVerText)" "Green"
        $phase = "done"
    } else {
        Say ("새 버전이 있습니다: v{0} -> v{1}" -f $curVerText, $newVerText) "Cyan"
        if ($rel.body) {
            Say "---- 바뀐 점 ----"
            ("" + $rel.body) -split "`r?`n" | Select-Object -First 25 | ForEach-Object { Say ("  " + $_) }
            Say "----------------"
        }
        if ($CheckOnly) { $phase = "done" }
        elseif (-not (Ask-YN "지금 업데이트할까요? (Y/N)")) { Say "취소했습니다."; $phase = "done" }
    }

    if ($phase -eq "check") {
        # ------------------------------------------------ 1. 받기 + 검증 (아직 아무것도 바꾸지 않음)
        Say ""
        Say "[1/4] 업데이트 파일 받기와 검증" "Cyan"
        $zipAsset = @($rel.assets | Where-Object { $_.name -match "(?i)[-_]update[-_]v?$([regex]::Escape($newVerText))\.zip$" }) | Select-Object -First 1
        $sumAsset = @($rel.assets | Where-Object { $_.name -eq "SHA256SUMS.txt" }) | Select-Object -First 1
        if (-not $zipAsset -or -not $sumAsset) { throw "릴리스에 업데이트 파일(…update…zip 또는 SHA256SUMS.txt)이 없습니다." }
        if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force }
        New-Item -ItemType Directory -Force $Work | Out-Null
        $zip = Join-Path $Work "update.zip"
        $sums = Join-Path $Work "SHA256SUMS.txt"
        Info ("받는 중: {0} ({1:N1} MB)" -f $zipAsset.name, ($zipAsset.size / 1MB))
        Save-Asset $sumAsset $sums
        Save-Asset $zipAsset $zip
        $line = Get-Content -LiteralPath $sums -Encoding UTF8 | Where-Object { $_ -match ("\s\*?" + [regex]::Escape($zipAsset.name) + "\s*$") } | Select-Object -First 1
        if (-not $line) { throw "SHA256SUMS.txt 에 $($zipAsset.name) 항목이 없습니다." }
        $want = ($line.Trim() -split "\s+")[0].ToLower()
        if ((Get-Sha256 $zip) -ne $want) { throw "받은 업데이트 파일이 손상되었거나 바뀌었습니다 (SHA256 불일치). 다시 시도해 주세요." }
        Info "SHA256 확인 OK"
        # 압축 파일 안의 이름이 폴더 밖으로 나가려는지 풀기 전에 확인
        $zf = [System.IO.Compression.ZipFile]::OpenRead($zip)
        try {
            foreach ($e in $zf.Entries) {
                if (-not (Test-UpdatePath ($e.FullName.TrimEnd("/")) $false)) { throw "업데이트 파일에 안전하지 않은 경로가 있습니다: $($e.FullName)" }
            }
        } finally { $zf.Dispose() }
        $stage = Join-Path $Work "files"
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
        $manPath = Join-Path $stage "manifest.json"
        if (-not (Test-Path -LiteralPath $manPath)) { throw "업데이트 파일에 manifest.json 이 없습니다." }
        $man = Get-Content -LiteralPath $manPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Parse-Ver $man.version) -ne $newVer) { throw "업데이트 파일의 버전($($man.version))이 릴리스($newVerText)와 다릅니다." }
        foreach ($p in $man.files.PSObject.Properties) {
            if (-not (Test-UpdatePath $p.Name ([bool]$p.Value.in_update))) { throw "manifest.json 에 안전하지 않은 경로가 있습니다: $($p.Name)" }
        }
        $helper = Join-Path $stage "vendor\update_helper.py"
        $code = Invoke-Native $Py @("-X", "utf8", $helper, "verify", $stage, $manPath) -Quiet
        if ($code -ne 0) { throw "업데이트 파일 내용 검증 실패: " + (($script:LastOutput | Select-Object -Last 3) -join " ") }
        Info "파일별 SHA256 확인 OK"
        $instVer = 1
        $ivf = Join-Path $StateDir "installer_version.txt"
        if (Test-Path -LiteralPath $ivf) { $instVer = [int](Get-Content -LiteralPath $ivf -Raw).Trim() }
        if ($instVer -lt [int]$man.min_installer_version) {
            throw ("이 업데이트(v{0})는 새로 설치해야 합니다. https://github.com/{1}/releases/latest 에서 설치 파일을 받아 설치.bat 을 실행해 주세요. (학습 기록은 그대로 남습니다)" -f $newVerText, $relCfg.repo)
        }
        # 설치된 잠금 파일 해시 (새 helper 로 같은 방법으로 계산)
        $code = Invoke-Native $Py @("-X", "utf8", $helper, "lockinfo", $Vendor, $Backend) -Quiet
        if ($code -ne 0) { throw "현재 설치 상태를 읽지 못했습니다." }
        $oldLocks = ($script:LastOutput -join "`n") | ConvertFrom-Json
        $newLocks = $man.locks
        $chg = @{}
        foreach ($k in @("requirements", "bootstrap", "models", "languagetool", "tatoeba_schema", "ollama")) { $chg[$k] = ("" + $oldLocks.$k) -ne ("" + $newLocks.$k) }
        Log ("lock changes: " + (($chg.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " "))
        # 바꾸기 전에 기억해 둘 것: 로컬 AI 를 쓰는지, 지금 쓰는 Ollama 모델 태그
        try {
            $cfgNow = Get-Content -LiteralPath (Join-Path $Backend "config.json") -Raw -Encoding UTF8 | ConvertFrom-Json
            $engFile = Join-Path $StateDir "engine.txt"
            $localEngine = ($cfgNow.llm_provider -eq "ollama") -or (-not $cfgNow.llm_provider -and (Test-Path -LiteralPath $engFile) -and ((Get-Content -LiteralPath $engFile -Raw).Trim() -eq "local"))
            $oldLockFile = Join-Path $Vendor "models.lock.json"
            if (Test-Path -LiteralPath $oldLockFile) { $oldOllamaTag = "" + (Get-Content -LiteralPath $oldLockFile -Raw -Encoding UTF8 | ConvertFrom-Json).ollama.model }
        } catch { Log ("엔진 확인 실패: " + $_.Exception.Message) }
        $sizeBefore = Get-TreeSize $helper @("backup\_update_work")

        # ------------------------------------------------ 2. 실행 중인 프로그램 종료
        Say ""
        Say "[2/4] 실행 중인 프로그램 확인" "Cyan"
        $procs = @(Get-AppProcesses)
        if ($procs.Count -gt 0) {
            foreach ($p in $procs) { Info ("실행 중: {0} (PID {1})" -f $p.Name, $p.ProcessId) }
            if (-not (Ask-YN "회화 연습 프로그램(또는 AI 서버)이 실행 중입니다. 종료하고 업데이트할까요? (Y/N)")) { throw "프로그램을 종료한 뒤 다시 실행해 주세요." }
            foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
            for ($i = 0; $i -lt 20 -and @(Get-AppProcesses).Count -gt 0; $i++) { Start-Sleep -Milliseconds 500 }
            if (@(Get-AppProcesses).Count -gt 0) { throw "프로그램을 종료하지 못했습니다. 직접 닫은 뒤 다시 실행해 주세요." }
            Info "종료했습니다."
        } else { Info "실행 중인 프로그램 없음" }

        # ------------------------------------------------ 3. 백업 + 적용
        $phase = "apply"
        Say ""
        Say "[3/4] 파일 바꾸기 (이전 파일은 backup\$curVerText 에 보관)" "Cyan"
        $backup = Join-Path $BackupDir $curVerText
        if (Test-Path -LiteralPath $backup) { $backup = $backup + "_" + (Get-Date -Format "yyyyMMdd-HHmmss") }
        New-Item -ItemType Directory -Force $backup | Out-Null
        # 지금 설치된 모델 잠금 목록 = "앱이 설치한 파일" 목록. 새 파일로 바뀌기 전에 보관해 두고, 정리 때 이 목록에 있던 것만 지운다.
        $oldLockCopy = Join-Path $backup "_old.models.lock.json"
        if (Test-Path -LiteralPath (Join-Path $Vendor "models.lock.json")) { Copy-Item -LiteralPath (Join-Path $Vendor "models.lock.json") -Destination $oldLockCopy -Force }
        $oldFiles = @{}
        $oldManPath = Join-Path $Root "manifest.json"
        if (Test-Path -LiteralPath $oldManPath) {
            $om = Get-Content -LiteralPath $oldManPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $om.files.PSObject.Properties) { $oldFiles[$p.Name] = $true }
        }
        $newFiles = @{}
        foreach ($p in $man.files.PSObject.Properties) { $newFiles[$p.Name] = $p.Value }
        $state = [ordered]@{ from = $curVerText; to = $newVerText; replaced = @(); added = @(); removed = @(); special = @() }
        function Backup-File([string]$rel) {
            $src = Rel-Path $rel
            $dst = Join-Path $backup ($rel -replace "/", "\")
            New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        # 항상 보관: 사용자 설정이 든 config.json, 버전 정보
        foreach ($rel in @("backend/config.json", "version.txt", "manifest.json", "runtime/.state/installer_version.txt")) {
            if (Test-Path -LiteralPath (Rel-Path $rel)) { Backup-File $rel; $state.special += $rel }
        }
        $toCopy = @()
        foreach ($rel in $newFiles.Keys) {
            $f = $newFiles[$rel]
            if (-not $f.in_update -or $rel -eq "backend/config.json") { continue }
            $dst = Rel-Path $rel
            if (Test-Path -LiteralPath $dst) {
                if ((Get-Item -LiteralPath $dst).Length -eq [int64]$f.size -and (Get-Sha256 $dst) -eq $f.sha256) { continue }
                Backup-File $rel; $state.replaced += $rel
            } else { $state.added += $rel }
            $toCopy += $rel
        }
        foreach ($rel in $oldFiles.Keys) {
            if (-not (Test-UpdatePath $rel $true)) { continue }
            if (-not $newFiles.ContainsKey($rel) -and (Test-Path -LiteralPath (Rel-Path $rel))) { Backup-File $rel; $state.removed += $rel }
        }
        Write-Utf8 (Join-Path $backup "_backup.json") ($state | ConvertTo-Json -Depth 5)
        $script:State = $state
        foreach ($rel in $toCopy) {
            $dst = Rel-Path $rel
            New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
            Copy-Item -LiteralPath (Join-Path $stage ($rel -replace "/", "\")) -Destination $dst -Force
        }
        foreach ($rel in $state.removed) { Remove-Item -LiteralPath (Rel-Path $rel) -Force }
        Info ("바뀐 파일 {0}개, 새 파일 {1}개, 지운 파일 {2}개" -f $state.replaced.Count, $state.added.Count, $state.removed.Count)
        # config.json: 새 기본값 + 사용자가 고른 값(AI 엔진 등)은 그대로
        $newCfg = Join-Path $stage "backend\config.json"
        if (Test-Path -LiteralPath $newCfg) {
            $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "mergecfg", (Join-Path $Backend "config.json"), $newCfg, (Join-Path $Backend "config.json"))
            if ($code -ne 0) { throw "config.json 병합 실패" }
        }

        # ------------------------------------------------ 4. 패키지 / 모델 / 데이터
        Say ""
        Say "[4/4] 필요한 구성 요소 맞추기" "Cyan"
        if ($chg.requirements -or $chg.bootstrap) {
            Info "파이썬 패키지 목록이 바뀌었습니다. 바뀐 패키지만 설치합니다."
            $pipTouched = $true
            $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "pipsync",
                (Join-Path $Vendor "requirements.lock.txt"), (Join-Path $Vendor "bootstrap.lock.txt"), (Join-Path $Vendor "wheels"))
            if ($code -ne 0) { throw "파이썬 패키지 업데이트 실패" }
        } else { Info "파이썬 패키지: 변경 없음" }
        if ($TestMode -and $env:HOEHWA_UPDATE_FAIL -eq "after_packages") { throw "(테스트) 강제 실패: after_packages" }
        if ($chg.models) {
            Info "음성 모델 목록이 바뀌었습니다. 바뀐 모델만 받습니다."
            # install_models.py 가 refs\main 을 새 버전 값으로 바꾼다. 실패해서 되돌릴 때 원래 값으로 복구하려고 먼저 적어 둔다.
            $script:HfRefsFile = Join-Path $backup "_hf_refs.json"
            if ((Test-Path -LiteralPath $HfDir) -and ((Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "refsave", $HfDir, $script:HfRefsFile) -Quiet) -ne 0)) {
                Warn "모델 캐시의 refs\main 값을 기록하지 못했습니다. 실패하면 모델 폴더는 되돌리지 못할 수 있습니다."
                $script:HfRefsFile = $null
            }
            $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "install_models.py"), (Join-Path $Vendor "models.lock.json"), $HfDir)
            if ($code -ne 0) { throw "음성 모델 업데이트 실패" }
        } else { Info "음성 모델: 변경 없음" }
        if ($chg.languagetool) {
            Info "문법 검사기(LanguageTool) 버전이 바뀌었습니다."
            $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "languagetool", (Join-Path $Vendor "models.lock.json"), $Backend)
            if ($code -ne 0) { Warn "LanguageTool 업데이트에 실패했습니다. 문법 교정은 AI 가 합니다." }
        } else { Info "문법 검사기: 변경 없음" }
        if ($chg.tatoeba_schema -and (Test-Path -LiteralPath (Join-Path $Backend "data\tatoeba.sqlite"))) {
            Info "예문 데이터베이스 형식이 바뀌어 다시 만듭니다 (인터넷에서 Tatoeba 자료를 받습니다)."
            $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Backend "tatoeba_build.py"))
            if ($code -ne 0) { Warn "예문 데이터베이스를 다시 만들지 못했습니다. 나중에 프로그램이 다시 시도합니다." }
        } else { Info "예문 데이터베이스: 변경 없음" }
        # 로컬 AI(Ollama): 모델 태그가 바뀌면 새 모델을 받고 설정을 새 태그로 바꾼다. 옛 모델은 성공한 뒤에 지운다.
        $newOllamaTag = $null
        try { $newOllamaTag = "" + (Get-Content -LiteralPath (Join-Path $Vendor "models.lock.json") -Raw -Encoding UTF8 | ConvertFrom-Json).ollama.model } catch {}
        if ($localEngine -and $newOllamaTag -and $oldOllamaTag -and $newOllamaTag -ne $oldOllamaTag) {
            Info "로컬 AI 모델이 $oldOllamaTag 에서 $newOllamaTag 로 바뀌었습니다."
            $ollamaExe = Find-OllamaExe
            if (-not $ollamaExe) { throw "Ollama 를 찾지 못했습니다. Ollama 를 설치/실행한 뒤 다시 업데이트해 주세요." }
            if (-not (Ensure-OllamaServing $ollamaExe)) { throw "Ollama 서버가 켜지지 않습니다. 시작 메뉴에서 Ollama 를 한 번 실행한 뒤 다시 시도해 주세요." }
            $names = Get-OllamaNames $ollamaExe
            if ($null -eq $names) { throw "Ollama 모델 목록을 읽지 못했습니다." }
            if ($names -notcontains $newOllamaTag) {
                Info "$newOllamaTag 모델을 받습니다 (수 GB, 시간이 걸립니다)."
                $ok = $false
                for ($try = 1; $try -le 3 -and -not $ok; $try++) {
                    if ($try -gt 1) { Warn "다시 시도합니다 ($try/3)..."; Start-Sleep -Seconds 5 }
                    $code = Invoke-Native $ollamaExe @("pull", $newOllamaTag)
                    if ($code -eq 0) { $ok = $true }
                }
                if (-not $ok) { throw "$newOllamaTag 모델을 받지 못했습니다." }
                $pulledNew = $newOllamaTag
            } else { Info "$newOllamaTag 모델이 이미 있습니다." }
            $cfgPath = Join-Path $Backend "config.json"
            $cur = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).llm_model
            if (-not $cur -or $cur -eq $oldOllamaTag) {
                $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "setcfg", $cfgPath, "llm_model", $newOllamaTag)
                if ($code -ne 0) { throw "config.json 의 llm_model 을 바꾸지 못했습니다." }
            }
            $script:OldTagToRemove = $oldOllamaTag
        } elseif ($chg.ollama -and $newLocks.ollama) {
            Info "참고: 개발 PC 의 로컬 AI 모델 내용이 바뀌었습니다(같은 태그). 로컬 AI 를 쓰면 'ollama pull' 로 최신 모델을 받을 수 있습니다."
        }
        if ($TestMode -and $env:HOEHWA_UPDATE_FAIL -eq "after_apply") { throw "(테스트) 강제 실패: after_apply" }

        # 마무리: 버전 기록 (여기부터는 되돌리지 않는다)
        Copy-Item -LiteralPath $manPath -Destination (Join-Path $Root "manifest.json") -Force
        Write-Utf8 $verFile ($newVerText + "`r`n")
        New-Item -ItemType Directory -Force $StateDir | Out-Null
        Write-Utf8 (Join-Path $StateDir "installer_version.txt") ("" + $man.installer_version)
        # 업데이트할 수 있었다 = 설치가 끝까지 됐다 = config.json 의 엔진은 이미 적혀 있다 (그 뒤 앱에서 바꿨을 수 있다).
        # 표시 파일이 없던 v1.0.0 설치도 다시 설치할 때 앱에서 고른 엔진을 지키도록 install.ps1 의 표시를 만들어 둔다.
        if (Test-Path -LiteralPath (Join-Path $StateDir "engine.txt")) { Write-Utf8 (Join-Path $StateDir "engine-config.ok") "1" }
        $phase = "done"

        # ------------------------------------------------ 정리: 쓰지 않는 것은 남기지 않는다
        Say ""
        Say "[정리] 쓰지 않는 파일 지우기" "Cyan"
        try {
            if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
            # 백업은 방금 만든 것(직전 버전) 하나만 남긴다
            $old = @(Get-ChildItem -LiteralPath $BackupDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $backup })
            foreach ($d in $old) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            Info ("백업: backup\{0} 만 남깁니다 (옛 백업 {1}개 삭제)" -f (Split-Path $backup -Leaf), $old.Count)
            # 예전 설치 프로그램이 앱 폴더 안에 만들었을 수 있는 pip 캐시
            foreach ($c in @("runtime\pip-cache", "runtime\.pip-cache", "backend\models\pip-cache", "backend\cache\pip", "backend\cache\pip-cache")) {
                $cp = Join-Path $Root $c
                if (Test-Path -LiteralPath $cp) { Remove-Item -LiteralPath $cp -Recurse -Force -ErrorAction SilentlyContinue; Info "pip 캐시 폴더 삭제: $c" }
            }
            # 새 잠금 목록에 없는 모델 파일 (backend\models\hf 안에서만, 먼저 목록을 로그에 남긴다)
            if ($chg.models -and (Test-Path -LiteralPath $HfDir) -and (([System.IO.Path]::GetFullPath($HfDir)).StartsWith($Root.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase))) {
                $lockFile = Join-Path $Vendor "models.lock.json"
                # 옛 잠금 목록(앱이 설치했던 것)에 있던 파일만 지운다. 사용자가 직접 넣은 음성 팩/파일, 목록에 없는 모델은 그대로 둔다.
                $pruneArgs = @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "prunehf", $lockFile, $HfDir)
                if (Test-Path -LiteralPath $oldLockCopy) { $pruneArgs += @("--old-lock", $oldLockCopy) }
                else { Info "이전 잠금 목록이 없어 모델 파일은 지우지 않습니다 (다운로드 임시 캐시만 정리)." }
                $null = Invoke-Native $Py $pruneArgs -Quiet     # 계획만 (update.log 에 기록)
                $code = Invoke-Native $Py ($pruneArgs + @("--apply"))
                if ($code -ne 0) { Warn "쓰지 않는 모델 파일을 정리하지 못했습니다." }
            } else { Info "음성 모델 정리: 필요 없음 (목록 변경 없음)" }
            # 옛 Ollama 모델 (새 모델을 받은 뒤에만)
            if ($script:OldTagToRemove -and $ollamaExe) {
                $names = Get-OllamaNames $ollamaExe
                if ($names -contains $script:OldTagToRemove -and $names -contains $newOllamaTag) {
                    $code = Invoke-Native $ollamaExe @("rm", $script:OldTagToRemove)
                    if ($code -eq 0) { Info "옛 로컬 AI 모델 삭제: $($script:OldTagToRemove)" } else { Warn "옛 로컬 AI 모델($($script:OldTagToRemove))을 지우지 못했습니다. 'ollama rm $($script:OldTagToRemove)' 로 직접 지울 수 있습니다." }
                }
            }
        } catch { Warn ("정리 중 오류(업데이트는 성공): " + $_.Exception.Message) }
        $sizeAfter = Get-TreeSize (Join-Path $Vendor "update_helper.py")
        Say ""
        $diff = if ($sizeBefore -ge 0 -and $sizeAfter -ge 0) { " (변화 {0:+0.0;-0.0;0.0} MB)" -f (($sizeAfter - $sizeBefore) / 1MB) } else { "" }
        Say ("업데이트 전 {0} → 후 {1}{2}" -f (Format-Size $sizeBefore), (Format-Size $sizeAfter), $diff)
        Say ""
        Say "업데이트 완료: v$newVerText" "Green"
        Say "회화연습.exe 를 다시 실행하세요." "Green"
    }
}
catch {
    $exitCode = 1
    $msg = $_.Exception.Message
    Say "" "Red"
    Say "[업데이트 실패] $msg" "Red"
    Log ("스택: " + $_.ScriptStackTrace)
    if ($phase -eq "apply" -and $backup -and $script:State) {
        Say "이전 버전으로 되돌립니다..." "Yellow"
        $rolledBack = $false
        try {
            $st = $script:State
            # 모델 캐시의 refs\main 을 원래 값으로 (이전 버전 앱이 이전 모델 스냅샷을 찾도록). 파일을 되돌리기 전에 한다: 그때는 vendor\update_helper.py 가 아직 refrestore 를 아는 새 버전이다.
            if ($script:HfRefsFile -and (Test-Path -LiteralPath $script:HfRefsFile)) {
                $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "refrestore", $script:HfRefsFile, $HfDir)
                if ($code -ne 0) { Warn "모델 캐시의 refs\main 을 완전히 되돌리지 못했습니다. 설치.bat 을 다시 실행하면 복구됩니다." } else { Info "모델 캐시의 refs\main 을 원래 값으로 되돌렸습니다." }
            }
            foreach ($rel in @($st.replaced) + @($st.removed) + @($st.special)) {
                $src = Join-Path $backup ($rel -replace "/", "\")
                if (Test-Path -LiteralPath $src) {
                    $dst = Rel-Path $rel
                    New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
                    Copy-Item -LiteralPath $src -Destination $dst -Force
                }
            }
            foreach ($rel in $st.added) { Remove-Item -LiteralPath (Rel-Path $rel) -Force -ErrorAction SilentlyContinue }
            if ($pipTouched) {
                Info "파이썬 패키지를 이전 목록으로 되돌립니다..."
                $code = Invoke-Native $Py @("-X", "utf8", (Join-Path $Vendor "update_helper.py"), "pipsync",
                    (Join-Path $Vendor "requirements.lock.txt"), (Join-Path $Vendor "bootstrap.lock.txt"), (Join-Path $Vendor "wheels"))
                if ($code -ne 0) { Warn "패키지를 완전히 되돌리지 못했습니다. 설치.bat 을 다시 실행하면 복구됩니다." }
            }
            # 이번에 새로 받은 로컬 AI 모델은 쓰지 않으므로 지운다 (앱 크기가 늘지 않게)
            if ($pulledNew -and $ollamaExe) { $null = Invoke-Native $ollamaExe @("rm", $pulledNew) -Quiet; Info "새로 받은 로컬 AI 모델($pulledNew)을 지웠습니다." }
            Say ("이전 버전(v{0})으로 되돌렸습니다. 프로그램은 그대로 쓸 수 있습니다." -f $curVerText) "Yellow"
            $rolledBack = $true
        } catch {
            Say ("되돌리기 중 오류: " + $_.Exception.Message + "  -> backup\" + (Split-Path $backup -Leaf) + " 폴더에 이전 파일이 있습니다. 설치.bat 을 다시 실행해 주세요.") "Red"
        }
        # 되돌리기에 성공했으면 이번 시도의 백업은 지금 파일과 같으므로 지운다 (이전 업데이트의 백업은 그대로 둔다)
        if ($rolledBack) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Say "자세한 기록: update.log" "Yellow"
}
finally {
    # 내려받은 zip 과 풀어 둔 임시 폴더는 성공이든 실패든(Ctrl+C 포함) 남기지 않는다
    if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
    if ((Test-Path -LiteralPath $BackupDir) -and -not (Get-ChildItem -LiteralPath $BackupDir -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $BackupDir -Force -ErrorAction SilentlyContinue
    }
}
Log "==================== 업데이트 종료 (코드 $exitCode) ===================="
$script:LogW.Close()
exit $exitCode
