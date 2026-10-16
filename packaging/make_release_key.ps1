# Creates the Android RELEASE signing key (once!) outside the repository and records its public SHA-256 fingerprint.
#   powershell -ExecutionPolicy Bypass -File packaging\make_release_key.ps1
#   test run with a throw-away key:  ... -KeysDir <some scratch folder>   (the repo's android_cert.sha256 is NOT touched then)
#
# Files made in the keys folder (default %LOCALAPPDATA%\hoehwa-practice\keys):
#   release.keystore   PKCS12, alias "hoehwa", RSA 4096, valid ~27 years
#   release.pass       the random password (never printed, never committed; only your Windows user can read it)
# Refuses to run when either file already exists (an existing key is never overwritten).
# Only the certificate fingerprint and the folder path are printed.
param(
    [string]$KeysDir,
    [string]$JavaHome,
    [string]$CertFile      # where the fingerprint is recorded; default: packaging\android_cert.sha256 for the default folder, <KeysDir>\cert.sha256 otherwise
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Pkg = $PSScriptRoot
$App = Split-Path $Pkg -Parent
$DefaultKeys = Join-Path $env:LOCALAPPDATA "hoehwa-practice\keys"
$Alias = "hoehwa"
$Warning = "이 키스토어를 잃어버리거나 비밀번호를 잊으면 같은 앱을 덮어 설치할 수 없습니다. 사용자는 앱을 지우고 다시 설치해야 하고, 그러면 폰에 있던 학습 기록이 사라집니다. keys 폴더 전체를 서로 다른 두 곳(예: USB와 암호 관리자)에 백업하세요. 저장소에 올리지 마세요."

function Fail([string]$msg) { throw $msg }

# run a native tool, return @(output lines, exit code); stderr text is kept in the output (PowerShell 5.1 safe)
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
function New-RandomPassword([int]$len) {
    $alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 1
    $limit = 256 - (256 % $alphabet.Length)    # rejection sampling: no modulo bias
    while ($sb.Length -lt $len) {
        $rng.GetBytes($buf)
        if ($buf[0] -lt $limit) { [void]$sb.Append($alphabet[$buf[0] % $alphabet.Length]) }
    }
    $rng.Dispose()
    return $sb.ToString()
}
function Protect-File([string]$path) {
    # remove inherited rights, leave only the current Windows user
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $r = Native "icacls.exe" @($path, "/inheritance:r", "/grant:r", ($me + ":(F)"))
    if ($r[1] -ne 0) { Write-Host "    경고: 파일 권한을 제한하지 못했어요: $path" -ForegroundColor Yellow }
}

$tmpKs = $null; $tmpPass = $null; $tmpCer = $null
$failed = $false
try {
    if (-not $KeysDir) { $KeysDir = $DefaultKeys }
    $KeysDir = [System.IO.Path]::GetFullPath($KeysDir)
    $isDefault = ($KeysDir.TrimEnd('\') -ieq $DefaultKeys.TrimEnd('\'))
    if (-not $JavaHome) { $JavaHome = Join-Path $env:LOCALAPPDATA "Android\jdk-17" }
    $keytool = Join-Path $JavaHome "bin\keytool.exe"
    if (-not (Test-Path -LiteralPath $keytool)) { Fail "keytool 을 찾지 못했어요: $keytool (JDK 17 경로를 -JavaHome 으로 알려 주세요)" }
    if (-not $CertFile) { $CertFile = if ($isDefault) { Join-Path $Pkg "android_cert.sha256" } else { Join-Path $KeysDir "cert.sha256" } }

    # the keys folder must not be inside this repository (or any other git repository)
    if (Test-Inside $KeysDir $App) { Fail "키 폴더가 저장소 안이에요: $KeysDir . 저장소 밖(예: $DefaultKeys )을 쓰세요." }
    $probe = $KeysDir
    while ($probe -and -not (Test-Path -LiteralPath $probe)) { $probe = Split-Path $probe -Parent }
    if ($probe -and (Get-Command git -ErrorAction SilentlyContinue)) {
        $g = Native git @("-C", $probe, "rev-parse", "--is-inside-work-tree")
        if ($g[1] -eq 0 -and (($g[0] | Select-Object -First 1) -eq "true")) { Fail "키 폴더가 git 저장소 안이에요: $KeysDir . 저장소 밖을 쓰세요." }
    }

    $ks = Join-Path $KeysDir "release.keystore"
    $pf = Join-Path $KeysDir "release.pass"
    if ((Test-Path -LiteralPath $ks) -or (Test-Path -LiteralPath $pf)) {
        Fail "이미 키가 있어요($KeysDir). 기존 키는 덮어쓰지 않아요. 키를 바꾸면 이미 설치한 앱을 덮어 설치할 수 없게 돼요. 정말 새 키가 필요하면 폴더를 직접 백업하고 옮긴 뒤 다시 실행하세요."
    }
    New-Item -ItemType Directory -Force $KeysDir | Out-Null

    # build everything under temporary names; rename both files only when all steps worked
    $stamp = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $tmpKs = Join-Path $KeysDir "release.keystore.new-$stamp"
    $tmpPass = Join-Path $KeysDir "release.pass.new-$stamp"
    $tmpCer = Join-Path $KeysDir "cert.der.new-$stamp"
    $pw = New-RandomPassword 24
    [System.IO.File]::WriteAllText($tmpPass, $pw, (New-Object System.Text.UTF8Encoding($false)))
    $pw = $null
    Protect-File $tmpPass

    Write-Host "== 릴리스 키 만들기 (RSA 4096, 몇 초 걸려요)" -ForegroundColor Cyan
    $r = Native $keytool @("-genkeypair", "-keystore", $tmpKs, "-storetype", "PKCS12", "-alias", $Alias,
        "-keyalg", "RSA", "-keysize", "4096", "-validity", "10000",
        "-dname", "CN=Hoehwa Practice, OU=Android, O=Whahan, C=KR",
        "-storepass:file", $tmpPass)
    if ($r[1] -ne 0 -or -not (Test-Path -LiteralPath $tmpKs)) { Fail ("keytool 이 키를 만들지 못했어요 (종료코드 " + $r[1] + ")") }
    Protect-File $tmpKs

    # fingerprint = SHA-256 of the DER certificate (same value apksigner prints for the signer)
    $r = Native $keytool @("-exportcert", "-keystore", $tmpKs, "-alias", $Alias, "-storepass:file", $tmpPass, "-file", $tmpCer)
    if ($r[1] -ne 0 -or -not (Test-Path -LiteralPath $tmpCer)) { Fail ("인증서를 읽지 못했어요 (종료코드 " + $r[1] + ")") }
    $fp = (Get-FileHash -LiteralPath $tmpCer -Algorithm SHA256).Hash.ToLower()
    Remove-Item -LiteralPath $tmpCer -Force; $tmpCer = $null

    Move-Item -LiteralPath $tmpKs -Destination $ks
    Move-Item -LiteralPath $tmpPass -Destination $pf
    $tmpKs = $null; $tmpPass = $null

    $header = "# 회화 연습 Android 릴리스 서명 인증서의 SHA-256 지문 (공개 정보라서 커밋해도 돼요).`n# 첫 줄이 아닌 값은 모두 주석입니다. publish_release.ps1 -WithApk 와 build_android.ps1 이 APK 서명과 비교합니다.`n"
    [System.IO.File]::WriteAllText($CertFile, ($header + $fp + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    Write-Host ""
    Write-Host "키를 만들었어요." -ForegroundColor Green
    Write-Host "  폴더        : $KeysDir"
    Write-Host "  인증서 SHA-256: $fp"
    Write-Host "  지문 기록   : $CertFile"
    if ($isDefault) { Write-Host "  다음 할 일  : packaging\android_cert.sha256 을 커밋하세요 (키 파일은 절대 커밋하지 마세요)." }
    else { Write-Host "  (시험용 키예요. 저장소의 android_cert.sha256 은 건드리지 않았어요.)" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "경고: $Warning" -ForegroundColor Yellow
}
catch {
    Write-Host ("오류: " + $_.Exception.Message) -ForegroundColor Red
    $failed = $true
}
finally {
    foreach ($t in @($tmpKs, $tmpPass, $tmpCer)) {
        if ($t -and (Test-Path -LiteralPath $t)) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    }
}
if ($failed) { exit 1 }
exit 0
