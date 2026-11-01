<#
  Build tool installer for the developer PC (Inno Setup, used by packaging\setup\hoehwa.iss -> setup.exe).
  Downloads the pinned installer from tools.lock.json, checks size and SHA256, and ONLY THEN installs it for the current user
  (no administrator rights) into  %LOCALAPPDATA%\hoehwa-practice\buildtools\innosetup-<version>\ .

    powershell -NoProfile -ExecutionPolicy Bypass -File packaging\get_build_tools.ps1 [-DryRun] [-Force]
                [-LockFile <tools.lock.json>] [-Dest <folder>] [-TimeoutSec 300]

  -DryRun   prints name / version / URL / SHA256 / destination and does nothing else (no download, no folder created)
  -Force    install again even if ISCC.exe is already there
  Exit code: 0 OK (installed, or already there, or dry run) / 2 bad lock file or arguments / 3 download failed /
             4 size or SHA256 mismatch (nothing is installed) / 5 install failed
  Prints no secrets. The downloaded file is deleted afterwards (success or failure).
#>
param(
    [switch]$DryRun,
    [switch]$Force,
    [string]$LockFile = "",
    [string]$Dest = "",
    [int]$TimeoutSec = 300
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Say($m) { Write-Host $m }
function Die($code, $m) { [Console]::Error.WriteLine("[ERROR] $m"); exit $code }

if (-not $LockFile) { $LockFile = Join-Path $PSScriptRoot "tools.lock.json" }
if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf)) { Die 2 "tools.lock.json not found: $LockFile" }

try {
    $lock = Get-Content -LiteralPath $LockFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $t = $lock.buildtools.innosetup
    $ok = ($lock.schema -eq 1) -and $t -and $t.version -and $t.file -and $t.url -and $t.sha256 -and $t.size
} catch { $ok = $false }
if (-not $ok) { Die 2 "lock file is broken or has no buildtools.innosetup entry: $LockFile" }
$sha = ([string]$t.sha256).ToLowerInvariant()
if ($sha -notmatch '^[0-9a-f]{64}$') { Die 2 "buildtools.innosetup.sha256 is not a 64-digit hex value" }
if (([string]$t.file) -notmatch '^[A-Za-z0-9._-]+$') { Die 2 "buildtools.innosetup.file is not a plain file name" }
if (([string]$t.url) -notmatch '^https://') { Die 2 "only https:// URLs are accepted: $($t.url)" }
if (-not ($t.size -is [int] -or $t.size -is [long]) -or $t.size -le 0) { Die 2 "buildtools.innosetup.size is invalid" }

if (-not $Dest) {
    $Dest = Join-Path $env:LOCALAPPDATA ("hoehwa-practice\buildtools\innosetup-" + $t.version)
}
$iscc = Join-Path $Dest "ISCC.exe"

Say "name    : Inno Setup"
Say "file    : $($t.file)"
Say "version : $($t.version)"
Say "url     : $($t.url)"
Say "sha256  : $sha"
Say "size    : $($t.size)"
Say "dest    : $Dest"

if ($DryRun) { Say "[DryRun] nothing downloaded or installed."; exit 0 }

if ((Test-Path -LiteralPath $iscc -PathType Leaf) -and -not $Force) {
    Say "Already installed: $iscc"
    exit 0
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("hoehwa-buildtools-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
$file = Join-Path $work $t.file
$exitCode = 0
try {
    # 1) download
    Say "Downloading ..."
    try {
        Invoke-WebRequest -Uri $t.url -OutFile $file -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5
    } catch {
        Die 3 ("download failed: " + $_.Exception.GetType().Name)
    }
    # 2) verify BEFORE running anything
    $len = (Get-Item -LiteralPath $file).Length
    $got = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($len -ne [int64]$t.size) { Die 4 "size mismatch (got $len, expected $($t.size)). NOT installed." }
    if ($got -ne $sha) { Die 4 "SHA256 mismatch (got $got, expected $sha). NOT installed." }
    Say "SHA256 OK ($got)"
    try { $sig = Get-AuthenticodeSignature -LiteralPath $file; Say ("signature: " + $sig.Status + " " + $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "" })) } catch {}

    # 3) install for the current user, silently (no administrator rights)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    $log = Join-Path $work "innosetup-install.log"
    $argList = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CURRENTUSER", "/NOICONS", "/DIR=`"$Dest`"", "/LOG=`"$log`"")
    Say "Installing for the current user ..."
    $p = Start-Process -FilePath $file -ArgumentList $argList -PassThru
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { Stop-Process -Id $p.Id -Force } catch {}      # only the process started here, by PID
        Die 5 "installer did not finish in $TimeoutSec s (stopped PID $($p.Id))"
    }
    if ($p.ExitCode -ne 0) { Die 5 "installer exit code $($p.ExitCode)" }
    if (-not (Test-Path -LiteralPath $iscc -PathType Leaf)) { Die 5 "ISCC.exe not found after install: $iscc" }
    Say "Installed: $iscc"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
