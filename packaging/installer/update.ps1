# 회화 연습 업데이트. 보통은 업데이트.bat 을 더블클릭해서 실행합니다.
#   powershell -ExecutionPolicy Bypass -File update.ps1 [-Yes] [-CheckOnly] [-Force] [-Source <로컬 폴더>]
# GitHub 의 최신 릴리스(release.json 의 repo)와 version.txt 를 비교해서, 새 버전이면 업데이트 zip 을 받아
# SHA256 을 확인하고 적용합니다. 바뀐 파일은 backup\<이전 버전>\ 에 보관하고, 실패하면 되돌립니다.
param(
    [switch]$Yes,                                  # 질문에 자동으로 Y
    [switch]$CheckOnly,                            # 새 버전이 있는지만 확인
    [switch]$Force,                                # 같은 버전이어도 다시 적용
    [string]$Source = $env:HOEHWA_UPDATE_SOURCE    # (테스트용) GitHub 대신 로컬 폴더: latest.json + 자산 파일
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Root     = $PSScriptRoot
$Backend  = Join-Path $Root "backend"
$Vendor   = Join-Path $Root "vendor"
$PyDir    = Join-Path $Root "runtime\python"
$Py       = Join-Path $PyDir "python.exe"
$StateDir = Join-Path $Root "runtime\.state"
$HfDir    = Join-Path $Backend "models\hf"
$LogFile  = Join-Path $Root "update.log"
$Work     = Join-Path $Root "backup\_update_work"

$script:LogW = New-Object System.IO.StreamWriter($LogFile, $true, (New-Object System.Text.UTF8Encoding($false)))
$script:LogW.AutoFlush = $true
function Log([string]$m) { $script:LogW.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $m) }
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
function Rel-Path([string]$rel) { return Join-Path $Root ($rel -replace "/", "\") }
# 이 폴더의 exe / 파이썬으로 실행 중인 프로세스 (이미지 이름이 아니라 실행 파일 경로로 찾는다)
function Get-AppProcesses {
    $pfx = $Root.TrimEnd("\") + "\"
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($pfx, [StringComparison]::OrdinalIgnoreCase) -and $_.ProcessId -ne $PID })
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
Log "==================== 업데이트 시작 ===================="
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
        $stage = Join-Path $Work "files"
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
        $manPath = Join-Path $stage "manifest.json"
        if (-not (Test-Path -LiteralPath $manPath)) { throw "업데이트 파일에 manifest.json 이 없습니다." }
        $man = Get-Content -LiteralPath $manPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ((Parse-Ver $man.version) -ne $newVer) { throw "업데이트 파일의 버전($($man.version))이 릴리스($newVerText)와 다릅니다." }
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
        $backup = Join-Path $Root ("backup\" + $curVerText)
        if (Test-Path -LiteralPath $backup) { $backup = $backup + "_" + (Get-Date -Format "yyyyMMdd-HHmmss") }
        New-Item -ItemType Directory -Force $backup | Out-Null
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
        if ($env:HOEHWA_UPDATE_FAIL -eq "after_packages") { throw "(테스트) 강제 실패: after_packages" }
        if ($chg.models) {
            Info "음성 모델 목록이 바뀌었습니다. 바뀐 모델만 받습니다."
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
        if ($chg.ollama -and $newLocks.ollama) {
            Info "참고: 개발 PC 의 로컬 AI 모델 버전이 바뀌었습니다. 로컬 AI 를 쓰면 'ollama pull' 로 최신 모델을 받을 수 있습니다."
        }
        if ($env:HOEHWA_UPDATE_FAIL -eq "after_apply") { throw "(테스트) 강제 실패: after_apply" }

        # 마무리: 버전 기록
        Copy-Item -LiteralPath $manPath -Destination (Join-Path $Root "manifest.json") -Force
        Write-Utf8 $verFile ($newVerText + "`r`n")
        New-Item -ItemType Directory -Force $StateDir | Out-Null
        Write-Utf8 (Join-Path $StateDir "installer_version.txt") ("" + $man.installer_version)
        $phase = "done"
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
        # 오래된 백업은 최근 3개만 남긴다
        Get-ChildItem -LiteralPath (Join-Path $Root "backup") -Directory | Where-Object { $_.Name -ne "_update_work" } |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
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
        try {
            $st = $script:State
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
            Say ("이전 버전(v{0})으로 되돌렸습니다. 프로그램은 그대로 쓸 수 있습니다." -f $curVerText) "Yellow"
        } catch {
            Say ("되돌리기 중 오류: " + $_.Exception.Message + "  -> backup\" + (Split-Path $backup -Leaf) + " 폴더에 이전 파일이 있습니다. 설치.bat 을 다시 실행해 주세요.") "Red"
        }
    }
    Say "자세한 기록: update.log" "Yellow"
}
if (Test-Path -LiteralPath $Work) { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue }
Log "==================== 업데이트 종료 (코드 $exitCode) ===================="
$script:LogW.Close()
exit $exitCode
