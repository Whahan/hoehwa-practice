# Publishes a GitHub release: builds the full installer + update zip, writes SHA256SUMS.txt and uploads them.
#   powershell -ExecutionPolicy Bypass -File packaging\publish_release.ps1 -Version 1.0.0 -Notes "바뀐 점 ..."
#   add -DryRun to run every check and the build but stop before anything is pushed or uploaded,
#   add -ScanOnly to run just the secret/personal-data scan of the tracked files.
# Needs: git (this folder is a clone of the repo in packaging\release.json, clean working tree, HEAD already pushed)
# and the GitHub CLI (`gh auth login` done). Nothing is uploaded before every check passes. The git tag is created by
# `gh release create --target <commit>` itself, so a failed release leaves no tag behind (and is cleaned up again).
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Notes = "",
    [string]$NotesFile,
    [switch]$Draft,
    [switch]$Prerelease,
    [switch]$SkipBuild,     # reuse an existing packaging\out\release_<Version>\ folder
    [switch]$SkipExport,    # passed to build_dist.ps1
    [string]$GodotExe,
    [switch]$DryRun,        # checks + build + asset verification, then stop (no tag, no push, no GitHub call)
    [switch]$ScanOnly       # only the secret / personal data scan
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Pkg = $PSScriptRoot
$App = Split-Path $Pkg -Parent
$Version = $Version.TrimStart("v", "V")
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must look like 1.2.3" }
$Tag = "v$Version"
if ($NotesFile) { $Notes = Get-Content -LiteralPath $NotesFile -Raw -Encoding UTF8 }
$rel = Get-Content -LiteralPath (Join-Path $Pkg "release.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$Repo = $rel.repo
if (-not $Repo -or $Repo -match "PLACEHOLDER|<|>") { throw "packaging\release.json has no real repo yet" }
$offline = $DryRun -or $ScanOnly    # no gh / remote / tag checks, nothing is written anywhere but packaging\out

function Native([string]$exe, [string[]]$a, [switch]$AllowFail) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = & $exe @a 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0 -and -not $AllowFail) { throw ("$exe $($a -join ' ') failed ($code):`n" + ($out -join "`n")) }
    return ,@($out, $code)
}

# ---------------------------------------------------------------- checks
Write-Host "== checks ($Repo $Tag)$(if ($DryRun) { ' [DRY RUN]' })" -ForegroundColor Cyan
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git not found" }
if (-not $offline) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found: winget install GitHub.cli" }
    Native gh @("auth", "status") | Out-Null
}
$top = (Native git @("-C", $App, "rev-parse", "--show-toplevel"))[0] | Select-Object -First 1
Write-Host "    git root: $top"
$dirty = (Native git @("-C", $App, "status", "--porcelain"))[0]
if ($dirty) {
    if ($offline) { Write-Host "    [dry run] working tree is not clean (ignored here; a real release needs a clean tree):`n      $($dirty -join "`n      ")" -ForegroundColor Yellow }
    else { throw ("working tree not clean - commit first:`n" + ($dirty -join "`n")) }
}
if (-not $offline) {
    $remote = ((Native git @("-C", $App, "remote", "get-url", "origin"))[0] | Select-Object -First 1)
    if ($remote -notmatch [regex]::Escape($Repo)) { throw "git remote origin ($remote) is not $Repo" }
    Native git @("-C", $App, "fetch", "origin", "--prune", "--quiet", "--tags") | Out-Null    # fresh remote state (stale origin/* refs must not fake "pushed")
    if (((Native git @("-C", $App, "tag", "--list", $Tag))[0] | Where-Object { $_ })) { throw "tag $Tag already exists" }
    if (((Native git @("-C", $App, "ls-remote", "--tags", "origin", "refs/tags/$Tag"))[0] | Where-Object { $_ })) { throw "tag $Tag already exists on the remote" }
    $r = Native gh @("release", "view", $Tag, "--repo", $Repo) -AllowFail
    if ($r[1] -eq 0) { throw "release $Tag already exists on GitHub" }
    $sha = ((Native git @("-C", $App, "rev-parse", "HEAD"))[0] | Select-Object -First 1)
    if (-not ((Native git @("-C", $App, "branch", "-r", "--contains", $sha))[0] | Where-Object { $_ })) {
        throw "HEAD ($sha) is not on the remote yet - git push first (the release tag is created on that commit)"
    }
}

# secrets / personal data must never be in the repository.
# Folder rules are anchored to the real locations (a folder merely NAMED data, e.g. godot/data/, is fine).
$tracked = (Native git @("-C", $App, "ls-files"))[0]
$badName = '(^|/)(secrets\.json[^/]*|auth\.json|\.env(\.[^/]*)?|progress\.json|prefs\.json|shots_progress\.json)$'
$badDir  = '^(runtime|dist|backups?)/|^backend/(models|data|cache|logs|tools)/|(^|/)\.venv/|^packaging/(out|locks)/|^godot/\.godot/|(^|/)__pycache__/'
$badExt  = '\.(sqlite[0-9]*|sqlite-(journal|wal)|pem|key|log|pyc)$'
$forbidden = $tracked | Where-Object { $_ -match $badName -or $_ -match $badDir -or $_ -match $badExt }
if ($forbidden) { throw ("files that must not be published are tracked:`n" + ($forbidden -join "`n")) }
$keyRegex = '((^|[^A-Za-z0-9_])sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
$keyHits = Native git @("-C", $App, "grep", "-I", "-n", "-E", $keyRegex) -AllowFail
if ($keyHits[1] -eq 0 -and $keyHits[0]) {
    # show where, never the matched text itself
    throw ("something that looks like an API key / token is tracked in:`n" + (($keyHits[0] | ForEach-Object { ($_ -split ":", 3)[0..1] -join ":" }) -join "`n"))
}
foreach ($c in @("backend\config.json", "packaging\defaults\config.default.json")) {
    $cp = Join-Path $App $c
    if (-not (Test-Path -LiteralPath $cp)) { if ($c -like "*default*") { throw "$c is missing" } else { continue } }
    if ((Get-Content -LiteralPath $cp -Raw -Encoding UTF8) -match '(?i)"(api_key|apikey|token|secret)"\s*:') { throw "$c contains a key-like field" }
}
Write-Host "    OK: no secrets tracked ($(@($tracked).Count) tracked files scanned)"
if ($ScanOnly) { Write-Host "SCAN OK" -ForegroundColor Green; exit 0 }

# ---------------------------------------------------------------- build
$RelDir = Join-Path $Pkg "out\release_$Version"
if (-not $SkipBuild) {
    Write-Host "== build" -ForegroundColor Cyan
    $args2 = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $Pkg "build_dist.ps1"), "-Release", $Version)
    # Windows PowerShell 5.1 drops an empty string argument, so the notes travel in a file (and only when there are any)
    $buildNotes = $null
    if ($Notes.Trim()) {
        $buildNotes = Join-Path $env:TEMP ("hoehwa_build_notes_{0}.md" -f $PID)
        [System.IO.File]::WriteAllText($buildNotes, $Notes, (New-Object System.Text.UTF8Encoding($false)))
        $args2 += @("-NotesFile", $buildNotes)
    }
    if ($SkipExport) { $args2 += "-SkipExport" }
    if ($GodotExe) { $args2 += @("-GodotExe", $GodotExe) }
    try { & powershell.exe @args2 } finally { if ($buildNotes) { Remove-Item -LiteralPath $buildNotes -Force -ErrorAction SilentlyContinue } }
    if ($LASTEXITCODE -ne 0) { throw "build_dist.ps1 failed" }
}
$prefix = if ($rel.asset_prefix) { $rel.asset_prefix } else { "app" }
$assets = @("$prefix-setup-$Version.zip", "$prefix-update-$Version.zip", "SHA256SUMS.txt") | ForEach-Object { Join-Path $RelDir $_ }
foreach ($a in $assets) { if (-not (Test-Path -LiteralPath $a)) { throw "missing asset $a" } }
# re-check the checksums we are about to publish
foreach ($line in Get-Content -LiteralPath (Join-Path $RelDir "SHA256SUMS.txt")) {
    if (-not $line.Trim()) { continue }
    $h, $n = $line.Trim() -split "\s+", 2
    if ((Get-FileHash -LiteralPath (Join-Path $RelDir $n) -Algorithm SHA256).Hash.ToLower() -ne $h) { throw "checksum mismatch: $n" }
}
Write-Host "    OK: assets and checksums verified ($RelDir)"
if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN OK - stopped before git/gh. A real run would now create release $Tag on $Repo with:" -ForegroundColor Green
    $assets | ForEach-Object { Write-Host "    $(Split-Path $_ -Leaf)" }
    exit 0
}

# ---------------------------------------------------------------- release (gh creates the tag at HEAD itself)
Write-Host "== GitHub release $Tag" -ForegroundColor Cyan
if (-not $Notes.Trim()) { $Notes = "회화 연습 $Tag" }
$notesTmp = Join-Path $env:TEMP ("hoehwa_release_notes_{0}.md" -f $PID)
$body = $Notes + "`n`n## 설치 / 업데이트`n- 처음 설치: ``$prefix-setup-$Version.zip`` 을 받아 압축을 풀고 ``설치.bat`` 실행`n- 이미 설치한 경우: 프로그램 폴더의 ``업데이트.bat`` 실행 (이 릴리스의 update zip 을 자동으로 받습니다)`n"
[System.IO.File]::WriteAllText($notesTmp, $body, (New-Object System.Text.UTF8Encoding($false)))
$ghArgs = @("release", "create", $Tag) + $assets + @("--repo", $Repo, "--target", $sha, "--title", "회화 연습 $Tag", "--notes-file", $notesTmp)
if ($Draft) { $ghArgs += "--draft" }
if ($Prerelease) { $ghArgs += "--prerelease" }
try {
    $out = Native gh $ghArgs
    Write-Host ($out[0] -join "`n")
} catch {
    # nothing may be left behind that blocks a retry: remove the half-made release and its tag (both were checked absent above)
    Write-Host "release failed - cleaning up so the same command can simply be run again" -ForegroundColor Yellow
    Native gh @("release", "delete", $Tag, "--repo", $Repo, "--yes", "--cleanup-tag") -AllowFail | Out-Null
    Native git @("-C", $App, "push", "origin", "--delete", "refs/tags/$Tag") -AllowFail | Out-Null
    Native git @("-C", $App, "tag", "-d", $Tag) -AllowFail | Out-Null
    throw
} finally {
    Remove-Item -LiteralPath $notesTmp -Force -ErrorAction SilentlyContinue
}
Native git @("-C", $App, "fetch", "origin", "--quiet", "--tags") -AllowFail | Out-Null    # local copy of the tag gh created
Write-Host "DONE: https://github.com/$Repo/releases/tag/$Tag" -ForegroundColor Green
