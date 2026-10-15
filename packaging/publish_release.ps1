# Publishes a GitHub release: builds the full installer + update zip, writes SHA256SUMS.txt, tags and uploads.
#   powershell -ExecutionPolicy Bypass -File packaging\publish_release.ps1 -Version 1.0.0 -Notes "바뀐 점 ..."
# Needs: git (this folder is a clone of the repo in packaging\release.json, clean working tree) and the GitHub CLI
# (`gh auth login` done). Nothing is uploaded before every check passes.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Notes = "",
    [string]$NotesFile,
    [switch]$Draft,
    [switch]$Prerelease,
    [switch]$SkipBuild,     # reuse an existing packaging\out\release_<Version>\ folder
    [switch]$SkipExport,    # passed to build_dist.ps1
    [string]$GodotExe
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

function Native([string]$exe, [string[]]$a, [switch]$AllowFail) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = & $exe @a 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0 -and -not $AllowFail) { throw ("$exe $($a -join ' ') failed ($code):`n" + ($out -join "`n")) }
    return ,@($out, $code)
}

Write-Host "== checks ($Repo $Tag)" -ForegroundColor Cyan
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git not found" }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) not found: winget install GitHub.cli" }
Native gh @("auth", "status") | Out-Null
$top = (Native git @("-C", $App, "rev-parse", "--show-toplevel"))[0] | Select-Object -First 1
Write-Host "    git root: $top"
$dirty = (Native git @("-C", $App, "status", "--porcelain"))[0]
if ($dirty) { throw ("working tree not clean - commit first:`n" + ($dirty -join "`n")) }
$remote = ((Native git @("-C", $App, "remote", "get-url", "origin"))[0] | Select-Object -First 1)
if ($remote -notmatch [regex]::Escape($Repo)) { throw "git remote origin ($remote) is not $Repo" }
if (((Native git @("-C", $App, "tag", "--list", $Tag))[0] | Where-Object { $_ })) { throw "tag $Tag already exists" }
$r = Native gh @("release", "view", $Tag, "--repo", $Repo) -AllowFail
if ($r[1] -eq 0) { throw "release $Tag already exists on GitHub" }

# secrets / personal data must never be in the repository
$tracked = (Native git @("-C", $App, "ls-files"))[0]
$forbidden = $tracked | Where-Object { $_ -match '(^|/)(secrets\.json[^/]*|auth\.json|\.env|progress\.json|prefs\.json)$' -or
    $_ -match '(^|/)(runtime|\.venv|models|data|cache|logs|dist|backup|backups)/' -or $_ -match '^packaging/out/' -or
    $_ -match '\.sqlite$' -or $_ -match '^godot/\.godot/' }
if ($forbidden) { throw ("files that must not be published are tracked:`n" + ($forbidden -join "`n")) }
$keyHits = Native git @("-C", $App, "grep", "-I", "-n", "-E", "(sk-(ant-|proj-)?[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})") -AllowFail
if ($keyHits[1] -eq 0 -and $keyHits[0]) { throw ("something that looks like an API key is tracked:`n" + ($keyHits[0] -join "`n")) }
$cfg = Get-Content -LiteralPath (Join-Path $App "backend\config.json") -Raw -Encoding UTF8
if ($cfg -match '(?i)"(api_key|apikey|token|secret)"\s*:') { throw "backend\config.json contains a key-like field" }
Write-Host "    OK: clean tree, no secrets tracked"

# build
$RelDir = Join-Path $Pkg "out\release_$Version"
if (-not $SkipBuild) {
    Write-Host "== build" -ForegroundColor Cyan
    $args2 = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $Pkg "build_dist.ps1"), "-Release", $Version, "-Notes", $Notes)
    if ($SkipExport) { $args2 += "-SkipExport" }
    if ($GodotExe) { $args2 += @("-GodotExe", $GodotExe) }
    & powershell.exe @args2
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

# tag + release
Write-Host "== tag $Tag and GitHub release" -ForegroundColor Cyan
Native git @("-C", $App, "tag", "-a", $Tag, "-m", "회화 연습 $Tag") | Out-Null
Native git @("-C", $App, "push", "origin", $Tag) | Out-Null
if (-not $Notes) { $Notes = "회화 연습 $Tag" }
$notesTmp = Join-Path $env:TEMP "hoehwa_release_notes.md"
$body = $Notes + "`n`n## 설치 / 업데이트`n- 처음 설치: ``$prefix-setup-$Version.zip`` 을 받아 압축을 풀고 ``설치.bat`` 실행`n- 이미 설치한 경우: 프로그램 폴더의 ``업데이트.bat`` 실행 (이 릴리스의 update zip 을 자동으로 받습니다)`n"
[System.IO.File]::WriteAllText($notesTmp, $body, (New-Object System.Text.UTF8Encoding($false)))
$ghArgs = @("release", "create", $Tag) + $assets + @("--repo", $Repo, "--title", "회화 연습 $Tag", "--notes-file", $notesTmp, "--verify-tag")
if ($Draft) { $ghArgs += "--draft" }
if ($Prerelease) { $ghArgs += "--prerelease" }
$out = Native gh $ghArgs
Remove-Item -LiteralPath $notesTmp -Force -ErrorAction SilentlyContinue
Write-Host ($out[0] -join "`n")
Write-Host "DONE: https://github.com/$Repo/releases/tag/$Tag" -ForegroundColor Green
