# Builds the signed Android APK (phone client of the PC app) with Godot's prebuilt export template (no Gradle).
#   powershell -ExecutionPolicy Bypass -File packaging\build_android.ps1 -Version 1.1.0 [-GodotExe <path>] [-OutDir <folder>] [-KeysDir <folder>] [-Debug] [-Emulator]
#   verify an existing APK only:   ... -Version 1.1.0 -VerifyApk <file.apk>
# Release build : needs release.keystore + release.pass in the keys folder (made once by make_release_key.ps1,
#                 default %LOCALAPPDATA%\hoehwa-practice\keys, never inside the repository). The password only travels to the
#                 Godot child process in environment variables; it is never printed and never written to export_presets.cfg.
# -Debug        : signed with Godot's debug key, file name ...-debug.apk, for test installs only (never upload it).
# -Emulator     : debug build that also contains the x86_64 libraries (...-debug-emulator.apk); export_presets.cfg is
#                 changed for the duration of the export and restored afterwards.
# -AllowNewKey  : do not stop when the APK's certificate differs from packaging\android_cert.sha256 (only for the very first release).
# Exit codes: 0 ok, 1 failure, 3 signing certificate differs from the pinned fingerprint.
param(
    [string]$Version,
    [string]$GodotExe = "C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe",
    [string]$OutDir,
    [string]$KeysDir,
    [string]$JavaHome,
    [string]$AndroidSdk,
    [string]$VerifyApk,
    [switch]$Debug,
    [switch]$Emulator,
    [switch]$AllowNewKey
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Pkg = $PSScriptRoot
$App = Split-Path $Pkg -Parent
$GodotPrj = Join-Path $App "godot"
$PresetFile = Join-Path $GodotPrj "export_presets.cfg"
$ProjectFile = Join-Path $GodotPrj "project.godot"
$DefaultKeys = Join-Path $env:LOCALAPPDATA "hoehwa-practice\keys"
$PackageName = "io.github.whahan.hoehwa"
$KeyAlias = "hoehwa"
$AllowedPermissions = @("android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE", "android.permission.RECORD_AUDIO")
$script:ExitCode = 1

function Fail([string]$msg) { throw $msg }
function Step([string]$m) { Write-Host "== $m" -ForegroundColor Cyan }

# run a native tool; returns @(output lines, exit code). Never prints anything itself.
function Native([string]$exe, [string[]]$a) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = & $exe @a 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return ,@($out, $code)
}
function Test-Inside([string]$child, [string]$parent) {
    $c = [System.IO.Path]::GetFullPath($child).TrimEnd('\') + '\'
    $p = [System.IO.Path]::GetFullPath($parent).TrimEnd('\') + '\'
    return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
}
function Read-Pin([string]$file) {
    # first line that is not empty / a comment; only a 64-digit lowercase hex value counts as a fingerprint
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    foreach ($l in Get-Content -LiteralPath $file -Encoding UTF8) {
        $t = $l.Trim()
        if (-not $t -or $t.StartsWith("#")) { continue }
        if ($t -match '^[0-9a-f]{64}$') { return $t }
        return $null
    }
    return $null
}

# ---------------------------------------------------------------- tools
function Find-Tools {
    $sdk = $AndroidSdk
    if (-not $sdk) { $sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" } }
    $bt = Join-Path $sdk "build-tools"
    if (-not (Test-Path -LiteralPath $bt)) { Fail "Android SDK build-tools 폴더가 없어요: $bt" }
    $dir = Get-ChildItem -LiteralPath $bt -Directory | Where-Object { Test-Path (Join-Path $_.FullName "apksigner.bat") } |
        Sort-Object { try { [version]$_.Name } catch { [version]"0.0" } } -Descending | Select-Object -First 1
    if (-not $dir) { Fail "build-tools 안에 apksigner 가 없어요: $bt" }
    $t = @{ Apksigner = (Join-Path $dir.FullName "apksigner.bat"); Aapt2 = (Join-Path $dir.FullName "aapt2.exe"); BuildTools = $dir.Name }
    if (-not (Test-Path -LiteralPath $t.Aapt2)) { Fail "aapt2 를 찾지 못했어요: $($t.Aapt2)" }
    return $t
}

# Checks signature, package/version/SDK/ABI/permissions of a finished APK. Throws on any problem.
# $pinFile = file with the expected certificate SHA-256 ($null = do not compare), $abis = the only native ABIs allowed.
function Test-Apk([string]$apk, $tools, [string]$expectVersion, [string]$pinFile, [string[]]$abis, [bool]$isDebugBuild) {
    if (-not (Test-Path -LiteralPath $apk)) { Fail "APK 가 없어요: $apk" }
    $oldJh = $env:JAVA_HOME
    $env:JAVA_HOME = $JavaHome
    try { $r = Native $tools.Apksigner @("verify", "--print-certs", "--verbose", $apk) } finally { $env:JAVA_HOME = $oldJh }
    $txt = ($r[0] -join "`n")
    if ($r[1] -ne 0 -or $txt -notmatch '(?m)^Verifies') { Fail ("서명 검증에 실패했어요(apksigner 종료코드 " + $r[1] + "):`n" + (($r[0] | Select-Object -First 6) -join "`n")) }
    if ($txt -notmatch '(?m)^Number of signers:\s*1\s*$') { Fail "서명자가 정확히 1명이 아니에요." }
    if ($txt -notmatch 'certificate SHA-256 digest:\s*([0-9a-fA-F]{64})') { Fail "APK 의 인증서 지문을 읽지 못했어요." }
    $fp = $Matches[1].ToLower()
    Write-Host "    서명 OK, 인증서 SHA-256: $fp"
    if ($pinFile) {
        $pin = Read-Pin $pinFile
        if (-not $pin) {
            if ($AllowNewKey) { Write-Host "    경고: $pinFile 에 지문이 아직 없어요(-AllowNewKey 로 계속). make_release_key.ps1 로 만든 지문을 기록·커밋해야 해요." -ForegroundColor Yellow }
            else { Fail "기대하는 인증서 지문이 아직 없어요($pinFile). 먼저 packaging\make_release_key.ps1 로 릴리스 키를 만들고 android_cert.sha256 을 커밋하세요." }
        }
        elseif ($pin -ne $fp) {
            if ($AllowNewKey) { Write-Host "    경고: 서명 인증서가 기록된 지문과 달라요(-AllowNewKey). 이 APK 는 기존 설치 위에 덮어 설치되지 않아요." -ForegroundColor Yellow }
            else {
                $script:ExitCode = 3
                Fail "APK 서명 인증서가 기록된 릴리스 지문(android_cert.sha256)과 달라요. 키를 잃어버리고 새로 만든 게 아니라면 올바른 키 폴더인지 확인하세요. 정말 새 키로 내보내려면 -AllowNewKey 를 쓰세요(기존 사용자는 앱을 지우고 다시 설치해야 해요)."
            }
        }
        else { Write-Host "    인증서가 android_cert.sha256 과 같아요." }
    }

    $r = Native $tools.Aapt2 @("dump", "badging", $apk)
    if ($r[1] -ne 0) { Fail ("aapt2 dump badging 실패(종료코드 " + $r[1] + ")") }
    $b = ($r[0] -join "`n")
    if ($b -notmatch "package: name='([^']*)' versionCode='([^']*)' versionName='([^']*)'") { Fail "APK 의 패키지 정보를 읽지 못했어요." }
    $pk = $Matches[1]; $vc = $Matches[2]; $vn = $Matches[3]
    $parts = $expectVersion -split '\.'
    $wantCode = ([int]$parts[0] * 10000 + [int]$parts[1] * 100 + [int]$parts[2]).ToString()
    if ($pk -ne $PackageName) { Fail "패키지 이름이 달라요: $pk (기대: $PackageName)" }
    if ($vc -ne $wantCode) { Fail "versionCode 가 달라요: $vc (기대: $wantCode)" }
    if ($vn -ne $expectVersion) { Fail "versionName 이 달라요: $vn (기대: $expectVersion)" }
    $sdkMin = if ($b -match "(?m)^(?:min)?[sS]dkVersion:'(\d+)'") { $Matches[1] } else { "?" }
    $sdkTarget = if ($b -match "(?m)^targetSdkVersion:'(\d+)'") { $Matches[1] } else { "?" }
    $native = if ($b -match "(?m)^native-code:\s*(.*)$") { @([regex]::Matches($Matches[1], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) } else { @() }
    if (-not $isDebugBuild -and $b -match "(?m)^application-debuggable") { Fail "릴리스 APK 가 debuggable 이에요." }
    if ((($native | Sort-Object) -join ",") -ne (($abis | Sort-Object) -join ",")) { Fail ("네이티브 ABI 가 달라요: [" + ($native -join ",") + "] (기대: [" + ($abis -join ",") + "])") }
    Write-Host "    패키지 $pk  versionCode=$vc  versionName=$vn  minSdk=$sdkMin  targetSdk=$sdkTarget  ABI=$($native -join ',')"

    $r = Native $tools.Aapt2 @("dump", "permissions", $apk)
    if ($r[1] -ne 0) { Fail ("aapt2 dump permissions 실패(종료코드 " + $r[1] + ")") }
    $perms = @($r[0] | ForEach-Object { if ($_ -match "^uses-permission[^:]*:\s*name='([^']+)'") { $Matches[1] } } | Sort-Object -Unique)
    $extra = @($perms | Where-Object { $AllowedPermissions -notcontains $_ })
    $missing = @($AllowedPermissions | Where-Object { $perms -notcontains $_ })
    Write-Host "    권한: $($perms -join ', ')"
    if ($extra.Count -gt 0) { Fail ("허용 목록 밖의 권한이 있어요: " + ($extra -join ", ")) }
    if ($missing.Count -gt 0) { Fail ("필요한 권한이 빠졌어요: " + ($missing -join ", ")) }
    $mb = (Get-Item -LiteralPath $apk).Length / 1MB
    if ($mb -lt 15 -or $mb -gt 60) { Write-Host ("    경고: APK 크기 {0:N1} MB 가 예상 범위(15~60 MB) 밖이에요." -f $mb) -ForegroundColor Yellow }
    if ($sdkMin -ne "24") { Write-Host "    알림: 최소 SDK 가 24 가 아니에요($sdkMin)." -ForegroundColor Yellow }
}

function Write-Final([string]$apk) {
    $h = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLower()
    Write-Host ("APK: {0}  {1:N1} MB  sha256={2}" -f $apk, ((Get-Item -LiteralPath $apk).Length / 1MB), $h)
}

# ---------------------------------------------------------------- main
$tmpApk = $null; $buildPrefix = $null; $presetBackup = $null; $envSet = $false
try {
    if (-not $Version) { Fail "-Version 1.2.3 을 알려 주세요." }
    $Version = $Version.TrimStart("v", "V")
    if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "버전은 1.2.3 같은 모양이어야 해요: $Version" }
    if (-not $JavaHome) { $JavaHome = Join-Path $env:LOCALAPPDATA "Android\jdk-17" }
    if (-not (Test-Path -LiteralPath (Join-Path $JavaHome "bin\java.exe"))) { Fail "JDK 17 을 찾지 못했어요: $JavaHome (-JavaHome 으로 알려 주세요)" }
    $tools = Find-Tools
    Write-Host "    build-tools $($tools.BuildTools), JDK $JavaHome"

    if (-not $KeysDir) { $KeysDir = $DefaultKeys }
    $KeysDir = [System.IO.Path]::GetFullPath($KeysDir)
    $usingDefaultKeys = ($KeysDir.TrimEnd('\') -ieq $DefaultKeys.TrimEnd('\'))
    $RepoPin = Join-Path $Pkg "android_cert.sha256"
    $PinFile = if ($usingDefaultKeys) { $RepoPin } else { Join-Path $KeysDir "cert.sha256" }

    # ---- verify-only mode
    if ($VerifyApk) {
        Step "APK 검증만 ($VerifyApk)"
        $pinForVerify = if ($Debug) { $null } else { $RepoPin }
        if (-not $usingDefaultKeys) { $pinForVerify = $PinFile }
        Test-Apk $VerifyApk $tools $Version $pinForVerify @("arm64-v8a") ([bool]$Debug)
        $script:ExitCode = 0
        Write-Final (Resolve-Path -LiteralPath $VerifyApk).Path
    } else {

    # ---- input checks (before the slow export)
    Step "입력 검사"
    if (-not (Test-Path -LiteralPath $GodotExe)) { Fail "Godot 콘솔 exe 를 찾지 못했어요: $GodotExe (-GodotExe 로 알려 주세요)" }
    if (-not (Test-Path -LiteralPath $ProjectFile)) { Fail "godot\project.godot 가 없어요." }
    $proj = Get-Content -LiteralPath $ProjectFile -Raw -Encoding UTF8
    if ($proj -notmatch '(?m)^config/version="([^"]*)"') { Fail "godot\project.godot 에 application/config/version 이 없어요." }
    if ($Matches[1] -ne $Version) { Fail "-Version $Version 이(가) godot\project.godot 의 config/version ($($Matches[1])) 과 달라요. 먼저 두 곳을 맞추세요." }
    $presetText = Get-Content -LiteralPath $PresetFile -Raw -Encoding UTF8
    $androidIdx = $null
    foreach ($m in [regex]::Matches($presetText, '(?m)^\[preset\.(\d+)\]\s*\r?\n(?:(?!\[).*\r?\n)*?name="Android"')) { $androidIdx = $m.Groups[1].Value }
    if ($null -eq $androidIdx) { Fail "export_presets.cfg 에 'Android' preset 이 없어요." }
    $opt = [regex]::Match($presetText, "(?ms)^\[preset\.$androidIdx\.options\]\s*\r?\n(.*?)(?=^\[|\z)")
    if (-not $opt.Success) { Fail "export_presets.cfg 에 Android 옵션 구역이 없어요." }
    $optText = $opt.Groups[1].Value
    $parts = $Version -split '\.'
    $wantCode = [int]$parts[0] * 10000 + [int]$parts[1] * 100 + [int]$parts[2]
    if ($optText -notmatch '(?m)^version/code=(\d+)\s*$') { Fail "Android preset 에 version/code 가 없어요." }
    if ([int]$Matches[1] -ne $wantCode) { Fail "Android preset 의 version/code ($($Matches[1])) 가 버전 $Version 의 계산값 $wantCode 와 달라요." }
    if ($optText -match '(?m)^version/name="([^"]+)"' -and $Matches[1] -ne $Version) { Fail "Android preset 의 version/name ($($Matches[1])) 이 -Version 과 달라요." }
    if ($presetText -match '(?m)^keystore/(release|debug)_password="[^"]+"') { Fail "export_presets.cfg 의 키스토어 비밀번호 칸이 비어 있지 않아요. 지우세요(비밀번호는 환경변수로만 전달해요)." }
    if ($optText -match '(?m)^architectures/arm64-v8a=false') { Fail "Android preset 에서 arm64-v8a 가 꺼져 있어요." }

    $isDebugBuild = [bool]($Debug -or $Emulator)
    $abis = @("arm64-v8a")
    if ($Emulator) { $abis = @("arm64-v8a", "x86_64") }
    if (-not $OutDir) { $OutDir = Join-Path $Pkg "out\android" }
    $OutDir = [System.IO.Path]::GetFullPath($OutDir)
    $finalName = "hoehwa-practice-android-$Version" + $(if ($isDebugBuild) { "-debug" } else { "" }) + $(if ($Emulator) { "-emulator" } else { "" }) + ".apk"
    $finalApk = Join-Path $OutDir $finalName

    $exportMode = "--export-debug"
    if (-not $isDebugBuild) {
        $exportMode = "--export-release"
        if (Test-Inside $KeysDir $App) { Fail "키 폴더가 저장소 안이에요: $KeysDir . 저장소 밖에 두세요." }
        if (-not (Test-Path -LiteralPath $KeysDir)) { Fail "키 폴더가 없어요: $KeysDir . 먼저 packaging\make_release_key.ps1 로 릴리스 키를 만드세요." }
        $ks = Join-Path $KeysDir "release.keystore"
        $pf = Join-Path $KeysDir "release.pass"
        if (-not (Test-Path -LiteralPath $ks)) { Fail "release.keystore 가 없어요: $ks" }
        if (-not (Test-Path -LiteralPath $pf)) { Fail "release.pass 가 없어요: $pf" }
        $keytool = Join-Path $JavaHome "bin\keytool.exe"
        $r = Native $keytool @("-list", "-keystore", $ks, "-alias", $KeyAlias, "-storepass:file", $pf)
        if ($r[1] -ne 0) { Fail "키스토어를 열지 못했어요. release.pass 의 비밀번호가 틀렸거나 키스토어/별칭($KeyAlias)이 올바르지 않아요." }
        if (-not $usingDefaultKeys) { Write-Host "    알림: 기본 위치가 아닌 키 폴더예요. 릴리스 지문(android_cert.sha256) 대신 이 폴더의 cert.sha256 과 비교해요." -ForegroundColor Yellow }
    }
    # Godot needs the editor settings (SDK / JDK paths) that the editor wrote once
    $es = Join-Path $env:APPDATA "Godot\editor_settings-4.6.tres"
    if (-not (Test-Path -LiteralPath $es) -or ((Get-Content -LiteralPath $es -Raw -Encoding UTF8) -notmatch 'export/android/android_sdk_path')) {
        Fail "Godot 편집기 설정에 Android SDK 경로가 없어요($es). 편집기 > 편집기 설정 > 내보내기 > Android 에서 SDK·JDK 경로를 한 번 지정하세요."
    }
    Write-Host "    OK"

    New-Item -ItemType Directory -Force $OutDir | Out-Null

    # ---- first import of a fresh checkout (the class cache must exist for the export)
    if (-not (Test-Path -LiteralPath (Join-Path $GodotPrj ".godot\imported"))) {
        Step "프로젝트 가져오기(처음 한 번)"
        foreach ($i in 1, 2) {
            $ilog = Join-Path $OutDir "godot_import_$i.log"
            $ip = Start-Process -FilePath $GodotExe -ArgumentList @("--headless", "--path", "`"$GodotPrj`"", "--import") -RedirectStandardOutput $ilog -RedirectStandardError ($ilog + ".err") -PassThru -WindowStyle Hidden
            $null = $ip.Handle
            if (-not $ip.WaitForExit(600000)) { & taskkill.exe /PID $ip.Id /T /F | Out-Null; Fail "Godot 가져오기가 시간 초과로 중단됐어요." }
        }
    }

    # ---- export
    Step "Godot export ($exportMode Android)"
    $buildPrefix = ".building-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $tmpApk = Join-Path $OutDir ($buildPrefix + ".apk")
    $log = Join-Path $OutDir "godot_export_android.log"
    if ($Emulator) {
        $presetBackup = [System.IO.File]::ReadAllBytes($PresetFile)
        $mod = $presetText -replace '(?m)^architectures/x86_64=false', 'architectures/x86_64=true'
        [System.IO.File]::WriteAllText($PresetFile, $mod, (New-Object System.Text.UTF8Encoding($false)))
    }
    if (-not $isDebugBuild) {
        $env:GODOT_ANDROID_KEYSTORE_RELEASE_PATH = $ks
        $env:GODOT_ANDROID_KEYSTORE_RELEASE_USER = $KeyAlias
        $env:GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD = [System.IO.File]::ReadAllText($pf).Trim()
        $envSet = $true
    }
    $p = Start-Process -FilePath $GodotExe -ArgumentList @("--headless", "--path", "`"$GodotPrj`"", $exportMode, "`"Android`"", "`"$tmpApk`"") `
            -RedirectStandardOutput $log -RedirectStandardError ($log + ".err") -PassThru -WindowStyle Hidden
    $null = $p.Handle
    if (-not $p.WaitForExit(900000)) { & taskkill.exe /PID $p.Id /T /F | Out-Null; Fail "Godot export 가 15분 안에 끝나지 않아 중단했어요." }
    if ($envSet) {
        Remove-Item Env:\GODOT_ANDROID_KEYSTORE_RELEASE_PATH, Env:\GODOT_ANDROID_KEYSTORE_RELEASE_USER, Env:\GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD -ErrorAction SilentlyContinue
        $envSet = $false
    }
    if ($null -ne $presetBackup) { [System.IO.File]::WriteAllBytes($PresetFile, $presetBackup); $presetBackup = $null }
    $exitText = if ($null -ne $p.ExitCode) { "$($p.ExitCode)" } else { "?" }
    if (-not (Test-Path -LiteralPath $tmpApk) -or (Get-Item -LiteralPath $tmpApk).Length -lt 5MB) {
        Get-Content -LiteralPath ($log + ".err") -Tail 15 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
        Get-Content -LiteralPath $log -Tail 15 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
        Fail "Godot export 가 APK 를 만들지 못했어요(종료코드 $exitText). 로그: $log"
    }
    if ($exitText -ne "0" -and $exitText -ne "?") { Fail "Godot export 가 오류로 끝났어요(종료코드 $exitText). 로그: $log" }
    Write-Host ("    exported {0:N1} MB" -f ((Get-Item -LiteralPath $tmpApk).Length / 1MB))

    # ---- verify, then move into place (a failed check leaves nothing behind)
    Step "APK 검증"
    $pinForBuild = if ($isDebugBuild) { $null } else { $PinFile }
    Test-Apk $tmpApk $tools $Version $pinForBuild $abis $isDebugBuild
    Move-Item -LiteralPath $tmpApk -Destination $finalApk -Force
    $tmpApk = $null
    $script:ExitCode = 0
    Write-Final $finalApk
    }
}
catch {
    Write-Host ("오류: " + $_.Exception.Message) -ForegroundColor Red
}
finally {
    if ($envSet) { Remove-Item Env:\GODOT_ANDROID_KEYSTORE_RELEASE_PATH, Env:\GODOT_ANDROID_KEYSTORE_RELEASE_USER, Env:\GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD -ErrorAction SilentlyContinue }
    if ($null -ne $presetBackup) { try { [System.IO.File]::WriteAllBytes($PresetFile, $presetBackup) } catch { Write-Host "경고: export_presets.cfg 를 되돌리지 못했어요. git checkout 으로 복구하세요." -ForegroundColor Red } }
    # whatever is left of this run's temporary files (Godot also leaves a .idsig next to the signed APK)
    if ($buildPrefix) { Get-ChildItem -LiteralPath $OutDir -Force -Filter "$buildPrefix*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
}
exit $script:ExitCode
