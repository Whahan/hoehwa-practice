# Builds the one-click install package:  app\packaging\out\회화연습_설치패키지_<yyyyMMdd>.zip
#   powershell -ExecutionPolicy Bypass -File build_dist.ps1 [-IncludeModels] [-IncludeProgress] [-SkipExport] [-Release 1.2.3 [-NotesFile notes.md]]
# Re-runnable: everything (exe, backend source, pip lock, model lock) is regenerated from the live state of this PC.
param(
    [switch]$IncludeModels,    # also pack backend\models\hf (about 2 GB more, fully offline model install)
    [switch]$IncludeProgress,  # also pack progress.json (learning history) for the user's own second PC
    [switch]$SkipExport,       # reuse app\dist\회화연습.exe instead of re-exporting from Godot
    [string]$GodotExe = "C:\Users\rtyu6\Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe",
    [string]$OutDir,
    [string]$Release,          # x.y.z : also build the update zip + out\release_<x.y.z>\ (GitHub assets, SHA256SUMS.txt)
    [string]$Notes = "",       # release notes (only written into the local latest.json used for testing)
    [string]$NotesFile,        # same, read from a UTF-8 file (publish_release.ps1 uses this: no quoting problems, no empty argument)
    [string]$TestRequirementsLock  # (tests only) ship this file as vendor\requirements.lock.txt instead of the real lock
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Pkg     = $PSScriptRoot
$App     = Split-Path $Pkg -Parent
$Backend = Join-Path $App "backend"
$GodotPrj = Join-Path $App "godot"
$VenvPy  = Join-Path $Backend ".venv\Scripts\python.exe"
if (-not $OutDir) { $OutDir = Join-Path $Pkg "out" }
$RootName = "회화연습"
$Stage   = Join-Path $OutDir "staging"
$Dest    = Join-Path $Stage $RootName
$Locks   = Join-Path $Pkg "locks"
$Date    = Get-Date -Format "yyyyMMdd"
$RelCfg  = Get-Content -LiteralPath (Join-Path $Pkg "release.json") -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Release) {
    $Release = $Release.TrimStart("v", "V")
    if ($Release -notmatch '^\d+\.\d+\.\d+$') { throw "-Release must look like 1.2.3" }
    $Version = $Release
    $Tag = $Release
} else {
    $Version = "0.0.0"   # local/dev build: any published release counts as newer
    $Tag = $Date
}
$ZipName = if ($IncludeModels) { "회화연습_설치패키지_${Tag}_모델포함.zip" } else { "회화연습_설치패키지_${Tag}.zip" }
$ZipPath = Join-Path $OutDir $ZipName
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
if ($NotesFile) { $Notes = (Get-Content -LiteralPath $NotesFile -Raw -Encoding UTF8) }
$DefaultCfg = Join-Path $Pkg "defaults\config.default.json"

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Run-Native([string]$exe, [string[]]$a) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & $exe @a 2>&1 | ForEach-Object { Write-Host "    $_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return $code
}
function Copy-WithBom([string]$src, [string]$dst) {
    $text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($dst, $text, $utf8Bom)
}

if (-not (Test-Path $VenvPy)) { throw "dev venv python not found: $VenvPy" }
New-Item -ItemType Directory -Force $OutDir | Out-Null
if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Force $Dest | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
# From here on, a failure (throw, Ctrl+C) must not leave out\staging / staging_update behind: the finally block removes them.
try {

    # ---------------------------------------------------------------- 1. Godot export
    Step "1/6 Godot export"
    $exeOut = Join-Path $Dest "$RootName.exe"
    if ($SkipExport) {
        Copy-Item -LiteralPath (Join-Path $App "dist\$RootName.exe") -Destination $exeOut
        Write-Host "    (skipped export: copied dist\$RootName.exe)"
    } else {
        if (-not (Test-Path -LiteralPath $GodotExe)) { throw "Godot console exe not found: $GodotExe (use -GodotExe)" }
        $expDir = Join-Path $OutDir "godot_export"
        if (Test-Path $expDir) { Remove-Item $expDir -Recurse -Force }
        New-Item -ItemType Directory -Force $expDir | Out-Null
        $tmpExe = Join-Path $expDir "app.exe"
        $log = Join-Path $OutDir "godot_export.log"
        $p = Start-Process -FilePath $GodotExe -ArgumentList @("--headless", "--path", "`"$GodotPrj`"", "--export-release", "`"Windows Desktop`"", "`"$tmpExe`"") `
                -RedirectStandardOutput $log -RedirectStandardError ($log + ".err") -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(900000)) { $p.Kill(); throw "Godot export timed out" }
        Get-Content $log -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
        if (-not (Test-Path $tmpExe) -or (Get-Item $tmpExe).Length -lt 20MB) {
            Get-Content ($log + ".err") -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
            throw "Godot export failed (exit $($p.ExitCode)); see $log"
        }
        Move-Item -LiteralPath $tmpExe -Destination $exeOut
        Write-Host ("    exported {0:N1} MB" -f ((Get-Item -LiteralPath $exeOut).Length / 1MB))
        # keep the dev copy (README: dist\회화연습.exe) the same build as the package; it is locked while the app runs
        try {
            New-Item -ItemType Directory -Force (Join-Path $App "dist") | Out-Null
            Copy-Item -LiteralPath $exeOut -Destination (Join-Path $App "dist\$RootName.exe") -Force -ErrorAction Stop
        } catch { Write-Host "    (warning: dist\$RootName.exe not updated - is the app running? $($_.Exception.Message))" }
    }

    # ---------------------------------------------------------------- 2. backend source
    Step "2/6 backend source"
    $bdst = Join-Path $Dest "backend"
    $rc = Run-Native "robocopy.exe" @($Backend, $bdst, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP",
        "/XD", ".venv", "models", "cache", "logs", "data", "__pycache__", "test_out", ".pytest_cache",
        "tools",   # LanguageTool (~400 MB): the installer downloads the official zip (models.lock.json "languagetool")
        "/XF", "setup.ps1", "run_backend.bat", "stop_backend.bat", "*.pyc", "*.log",
        "secrets.json", "secrets.json.tmp",   # API keys never leave this PC
        "lan_devices*.json", "lan_devices*.json.*",   # phone link: paired-phone token hashes never leave this PC
        "test_*.py", "build_curriculum.py", "requirements.txt", ".gitignore")   # dev files (kept in git, not shipped)
    if ($rc -ge 8) { throw "robocopy failed ($rc)" }
    # the package ships a neutral config, never this PC's backend\config.json (robocopy copied it; it is replaced right here)
    if (-not (Test-Path -LiteralPath $DefaultCfg)) { throw "defaults\config.default.json not found" }
    Copy-Item -LiteralPath $DefaultCfg -Destination (Join-Path $bdst "config.json") -Force
    # safety net: no API key file and no key-looking value in config.json may reach the package
    if (Get-ChildItem -LiteralPath $bdst -Recurse -File -Filter "secrets.json*" -ErrorAction SilentlyContinue) { throw "secrets.json was copied into the package" }
    $cfgTxt = Get-Content -LiteralPath (Join-Path $bdst "config.json") -Raw -Encoding UTF8
    if ($cfgTxt -match '(?i)"(api_key|apikey|token|secret)"\s*:' -or $cfgTxt -match '(sk-[A-Za-z0-9_\-]{16,}|AIza[0-9A-Za-z_\-]{20,})') { throw "config.json looks like it contains an API key" }
    if ((Get-FileHash -LiteralPath (Join-Path $bdst "config.json") -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $DefaultCfg -Algorithm SHA256).Hash) { throw "backend\config.json in the package is not the default config" }
    $devFiles = Get-ChildItem -LiteralPath $bdst -Recurse -File | Where-Object { $_.Name -match '^test_.*\.py$|^build_curriculum\.py$|^\.gitignore$|^requirements\.txt$' }
    if ($devFiles) { throw ("dev files in the package: " + ($devFiles.Name -join ", ")) }
    Copy-Item (Join-Path $Pkg "defaults\run_backend.bat") $bdst -Force
    Copy-Item (Join-Path $Pkg "defaults\stop_backend.bat") $bdst -Force
    Get-ChildItem $bdst -File | ForEach-Object { Write-Host ("    {0}  ({1:N0} B)" -f $_.Name, $_.Length) }

    # ---------------------------------------------------------------- 3. locks
    Step "3/6 requirements.lock.txt / models.lock.json from the live venv and model cache"
    $code = Run-Native $VenvPy @("-X", "utf8", (Join-Path $Pkg "make_locks.py"), "--backend", $Backend, "--out", $Locks)
    if ($code -ne 0) { throw "make_locks.py failed" }
    $vdst = Join-Path $Dest "vendor"
    New-Item -ItemType Directory -Force $vdst | Out-Null
    foreach ($f in @("requirements.lock.txt", "bootstrap.lock.txt", "models.lock.json")) {
        Copy-Item (Join-Path $Locks $f) $vdst
    }
    $wh = Join-Path $Locks "wheels"
    if (Test-Path $wh) { Copy-Item $wh (Join-Path $vdst "wheels") -Recurse }
    if ($TestRequirementsLock) {
        Copy-Item -LiteralPath $TestRequirementsLock (Join-Path $vdst "requirements.lock.txt") -Force
        Write-Host "    [TEST] requirements.lock.txt replaced by $TestRequirementsLock" -ForegroundColor Yellow
    }

    # ---------------------------------------------------------------- 4. vendor + installer
    Step "4/6 vendor files and installer scripts"
    $vj = Get-Content (Join-Path $Pkg "vendor\vendor.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in @("python", "getpip")) {
        $f = Join-Path $Pkg ("vendor\" + $vj.$k.file)
        $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
        if ($h -ne $vj.$k.sha256) { throw "vendor hash mismatch: $f" }
        Copy-Item -LiteralPath $f $vdst
    }
    Copy-Item (Join-Path $Pkg "vendor\vendor.json") $vdst
    foreach ($f in @("install_models.py", "check_env.py", "update_helper.py")) { Copy-Item (Join-Path $Pkg "installer\$f") $vdst }
    foreach ($f in @("install.ps1", "uninstall.ps1", "update.ps1")) { Copy-WithBom (Join-Path $Pkg "installer\$f") (Join-Path $Dest $f) }
    Copy-WithBom (Join-Path $Pkg "installer\사용법.txt") (Join-Path $Dest "사용법.txt")
    foreach ($f in @("설치.bat", "제거.bat", "업데이트.bat")) { Copy-Item -LiteralPath (Join-Path $Pkg "installer\$f") (Join-Path $Dest $f) }
    Copy-Item -LiteralPath (Join-Path $Pkg "release.json") (Join-Path $Dest "release.json")

    # ---------------------------------------------------------------- 5. defaults
    Step "5/6 defaults (prefs.json)"
    $ddst = Join-Path $Dest "defaults"
    New-Item -ItemType Directory -Force $ddst | Out-Null
    $userData = Join-Path $env:APPDATA "Godot\app_userdata\회화 연습"
    $prefs = Join-Path $userData "prefs.json"
    if (-not (Test-Path -LiteralPath $prefs)) { throw "prefs.json not found: $prefs" }
    $code = Run-Native $VenvPy @("-X", "utf8", (Join-Path $Pkg "sanitize_prefs.py"), $prefs, (Join-Path $ddst "prefs.json"))
    if ($code -ne 0) { throw "sanitize_prefs failed" }
    if ($IncludeProgress) {
        Copy-Item -LiteralPath (Join-Path $userData "progress.json") (Join-Path $ddst "progress.json")
        Write-Host "    progress.json included (personal learning history!)" -ForegroundColor Yellow
    }
    if ($IncludeModels) {
        $mdst = Join-Path $bdst "models\hf"
        New-Item -ItemType Directory -Force $mdst | Out-Null
        Write-Host "    copying models\hf (about 2 GB) ..."
        $rc = Run-Native "robocopy.exe" @((Join-Path $Backend "models\hf"), $mdst, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP",
            "/XD", "xet", ".locks", "/XF", ".agent_harnesses.json")
        if ($rc -ge 8) { throw "robocopy models failed ($rc)" }
    }
    $info = "built " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " on " + $env:COMPUTERNAME + "`r`nIncludeModels=$IncludeModels IncludeProgress=$IncludeProgress`r`n"
    $info += "requirements.lock.txt sha256 " + (Get-FileHash (Join-Path $vdst "requirements.lock.txt") -Algorithm SHA256).Hash + "`r`n"
    $info += "models.lock.json sha256 " + (Get-FileHash (Join-Path $vdst "models.lock.json") -Algorithm SHA256).Hash + "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $vdst "BUILD_INFO.txt"), $info, (New-Object System.Text.UTF8Encoding($false)))

    # ---------------------------------------------------------------- 6. manifest + zip(s)
    Step "6/6 manifest and zip (version $Version)"
    # files that only the full installer needs (never shipped in an update zip)
    $notInUpdate = @("vendor/python-3.10.11-embed-amd64.zip", "vendor/get-pip.py", "defaults/progress.json", "backend/models")
    $code = Run-Native $VenvPy (@("-X", "utf8", (Join-Path $Pkg "installer\update_helper.py"), "manifest", $Dest, $Version,
        "$($RelCfg.min_installer_version)", "$($RelCfg.installer_version)", (Join-Path $Dest "manifest.json"), "--exclude-from-update") + $notInUpdate)
    if ($code -ne 0) { throw "manifest failed" }
    # last safety net: nothing secret / personal in the package
    $bad = Get-ChildItem -LiteralPath $Dest -Recurse -File | Where-Object { $_.Name -match '^(secrets\.json.*|auth\.json|\.env|lan_devices.*\.json.*)$' -or ($_.Name -eq "progress.json" -and -not $IncludeProgress) }
    if ($bad) { throw ("secret/personal file in package: " + ($bad.FullName -join ", ")) }
    $code = Run-Native $VenvPy @("-X", "utf8", (Join-Path $Pkg "make_zip.py"), $Stage, $RootName, $ZipPath)
    if ($code -ne 0) { throw "zip failed" }
    $z = Get-Item -LiteralPath $ZipPath
    Write-Host ("    full installer: {0} ({1:N1} MB)" -f $z.Name, ($z.Length / 1MB))
    $zcArgs = @("-X", "utf8", (Join-Path $Pkg "check_zip.py"), $ZipPath, $DefaultCfg)
    if ($IncludeModels) { $zcArgs += "--allow-models" }
    if ($IncludeProgress) { $zcArgs += "--allow-progress" }
    if ((Run-Native $VenvPy $zcArgs) -ne 0) { throw "setup zip check failed" }

    if ($Release) {
        # update package: only app files (manifest in_update), at the zip root, plus manifest.json
        $UStage = Join-Path $OutDir "staging_update"
        if (Test-Path -LiteralPath $UStage) { Remove-Item -LiteralPath $UStage -Recurse -Force }
        New-Item -ItemType Directory -Force $UStage | Out-Null
        $man = Get-Content -LiteralPath (Join-Path $Dest "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $man.files.PSObject.Properties) {
            if (-not $p.Value.in_update) { continue }
            $rel = $p.Name -replace "/", "\"
            $dst = Join-Path $UStage $rel
            New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
            Copy-Item -LiteralPath (Join-Path $Dest $rel) -Destination $dst
        }
        Copy-Item -LiteralPath (Join-Path $Dest "manifest.json") (Join-Path $UStage "manifest.json")
        $UZip = Join-Path $OutDir "회화연습_update_$Version.zip"
        $code = Run-Native $VenvPy @("-X", "utf8", (Join-Path $Pkg "make_zip.py"), $UStage, ".", $UZip)
        if ($code -ne 0) { throw "update zip failed" }
        Remove-Item -LiteralPath $UStage -Recurse -Force
        if ((Run-Native $VenvPy @("-X", "utf8", (Join-Path $Pkg "check_zip.py"), $UZip, $DefaultCfg)) -ne 0) { throw "update zip check failed" }
        # GitHub release assets: ASCII names (GitHub rewrites non-ASCII asset names), SHA256SUMS.txt, and a
        # latest.json in the GitHub API shape so update.ps1 -Source <folder> can test the exact same flow locally.
        $RelDir = Join-Path $OutDir "release_$Version"
        if (Test-Path -LiteralPath $RelDir) { Remove-Item -LiteralPath $RelDir -Recurse -Force }
        New-Item -ItemType Directory -Force $RelDir | Out-Null
        $prefix = if ($RelCfg.asset_prefix) { $RelCfg.asset_prefix } else { "app" }
        $assets = [ordered]@{ ("$prefix-setup-$Version.zip") = $ZipPath; ("$prefix-update-$Version.zip") = $UZip }
        $sumLines = @(); $assetList = @()
        foreach ($name in $assets.Keys) {
            $dst = Join-Path $RelDir $name
            Copy-Item -LiteralPath $assets[$name] -Destination $dst
            $h = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLower()
            $sumLines += "$h  $name"
            $assetList += [ordered]@{ name = $name; size = (Get-Item -LiteralPath $dst).Length; browser_download_url = $name }
        }
        [System.IO.File]::WriteAllText((Join-Path $RelDir "SHA256SUMS.txt"), (($sumLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $assetList += [ordered]@{ name = "SHA256SUMS.txt"; size = (Get-Item -LiteralPath (Join-Path $RelDir "SHA256SUMS.txt")).Length; browser_download_url = "SHA256SUMS.txt" }
        $latest = [ordered]@{ tag_name = "v$Version"; name = "v$Version"; body = $Notes; draft = $false; prerelease = $false; assets = $assetList }
        [System.IO.File]::WriteAllText((Join-Path $RelDir "latest.json"), ($latest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host ("    update package: {0} ({1:N1} MB)" -f (Split-Path $UZip -Leaf), ((Get-Item -LiteralPath $UZip).Length / 1MB))
        Write-Host "    release assets: $RelDir"
        Get-Content -LiteralPath (Join-Path $RelDir "SHA256SUMS.txt") | ForEach-Object { Write-Host "      $_" }
    }
} finally {
    foreach ($leftover in @($Stage, (Join-Path $OutDir "staging_update"))) {
        if (Test-Path -LiteralPath $leftover) {
            try { Remove-Item -LiteralPath $leftover -Recurse -Force -ErrorAction Stop }
            catch { Write-Warning ("could not remove the temporary folder " + $leftover + " (" + $_.Exception.Message + ") - delete it by hand") }
        }
    }
}
Write-Host ""
Write-Host ("DONE: {0}  ({1:N1} MB)  [{2:N0}s]" -f $z.FullName, ($z.Length / 1MB), $sw.Elapsed.TotalSeconds) -ForegroundColor Green
