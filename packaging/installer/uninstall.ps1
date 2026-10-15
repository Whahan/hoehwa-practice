# 회화 연습 제거 스크립트. 보통은 제거.bat 을 더블클릭해서 실행합니다.
# 지우는 것: 이 폴더 안의 runtime, backend\models, backend\logs, backend\cache, backend\tools(LanguageTool), backend\secrets.json(API 키), install.log
# 지우지 않는 것: Ollama 와 AI 모델, OpenCode/Node.js, 학습 기록/설정(%APPDATA%\Godot\app_userdata\회화 연습), 프로그램 파일 자체
param([switch]$Yes)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Root = $PSScriptRoot

Write-Host "================ 회화 연습 제거 ================" -ForegroundColor Cyan
Write-Host "다음 폴더/파일을 지웁니다 (설치 폴더: $Root)"
$targets = @("runtime", "backend\models", "backend\logs", "backend\cache", "backend\tools", "backend\secrets.json", "backend\__pycache__", "install.log", "backup", "update.log", "version.txt")
foreach ($t in $targets) {
    $p = Join-Path $Root $t
    if (Test-Path -LiteralPath $p) { Write-Host "  - $t" }
}
Write-Host "지우지 않는 것: Ollama 와 AI 모델, OpenCode/Node.js, 학습 기록과 설정, 프로그램(exe) 자체" -ForegroundColor Gray
if (-not $Yes) {
    $a = Read-Host "정말 제거할까요? (Y/N)"
    if ($a -notmatch '^[yY]') { Write-Host "취소했습니다."; exit 0 }
}

# 이 폴더의 파이썬으로 돌고 있는 서버 / 앱 종료
$rt = (Join-Path $Root "runtime") + "\"
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($rt, [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { Write-Host "  실행 중인 프로세스 종료: $($_.Name) ($($_.ProcessId))"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

foreach ($t in $targets) {
    $p = Join-Path $Root $t
    if (-not (Test-Path -LiteralPath $p)) { continue }
    Write-Host "  삭제 중: $t ..."
    if ((Get-Item -LiteralPath $p) -is [System.IO.DirectoryInfo]) {
        # cmd 의 rd 는 긴 경로도 처리한다 (\\?\ 접두어 사용)
        & cmd.exe /c rd /s /q "\\?\$p" 2>$null
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    } else {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $p) { Write-Host "    [주의] 완전히 지우지 못했습니다. 프로그램을 모두 끈 뒤 다시 실행해 주세요: $t" -ForegroundColor Yellow }
}
Write-Host "제거가 끝났습니다. 폴더 자체는 직접 지우셔도 됩니다." -ForegroundColor Green
Write-Host "(Ollama 는 '설정 > 앱'에서, 학습 기록은 %APPDATA%\Godot\app_userdata\회화 연습 폴더를 지우면 제거됩니다)" -ForegroundColor Gray
