# Release check: the repository must not track lyrics, music or per-song records (docs/song_study_design.md L1/L11).
#   powershell -ExecutionPolicy Bypass -File packaging\check_no_media.ps1 [-RepoRoot <folder of a git work tree>]
# Looks at the files git tracks (git ls-files) and fails when any of these is tracked outside the allowed folder
# godot/tests/fixtures/song/ (synthetic test files written for this project):
#   audio files (mp3 m4a ogg wav flac opus), *.lrc, song.json, memo.json, anything under a songs/ or song_jobs/ folder.
# Exit code 0 = nothing found, 1 = something found (the repo-relative paths are listed) or git could not be read.
param([string]$RepoRoot = "")
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Host "X git not found"; exit 1 }

$out = & git -c core.quotepath=off -C $RepoRoot ls-files
if ($LASTEXITCODE -ne 0) { Write-Host "X git ls-files failed (exit $LASTEXITCODE)"; exit 1 }
$tracked = @($out | Where-Object { $_ })
if ($tracked.Count -eq 0) { Write-Host "X git ls-files returned no files (wrong folder?)"; exit 1 }

$allowed = '^godot/tests/fixtures/song/'
$bad = '\.(mp3|m4a|ogg|wav|flac|opus|lrc)$|(^|/)(song|memo)\.json$|(^|/)(songs|song_jobs)/'
$hits = @($tracked | Where-Object { $_ -notmatch $allowed -and $_ -match $bad })
if ($hits.Count -gt 0) {
    Write-Host "X media / lyrics / song records are tracked outside godot/tests/fixtures/song/ :"
    $hits | ForEach-Object { Write-Host "    $_" }
    Write-Host "NO_MEDIA_RESULT FAIL ($($hits.Count) files)"
    exit 1
}
Write-Host "NO_MEDIA_RESULT OK ($($tracked.Count) tracked files scanned)"
exit 0
