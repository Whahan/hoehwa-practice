# 회화 연습 setup.exe / 제거 프로그램이 부르는 정리 스크립트.
#   powershell -NoProfile -ExecutionPolicy Bypass -File stop_app.ps1 -Root <설치 폴더> [-ReportFile <파일>] [-ListOnly]
# 실행 파일 경로가 <설치 폴더>\ 아래인 프로세스만, PID 로 끈다. 이름으로 끄지 않는다 (이름만 같은 다른 폴더의 프로세스는 그대로 둔다).
# 이 스크립트를 부른 쪽(부모 프로세스들)과 제거 프로그램(unins*.exe)은 끄지 않는다.
# 종료 코드: 0 (끌 것이 없었거나 모두 껐음, -ListOnly 포함) / 1 (끄지 못한 프로세스가 남음)
# -ReportFile : 결과 줄을 그 파일에 쓴다 (STOP <pid> <이름> / SURVIVOR <pid> <이름> / STOP_RESULT <끈 개수> <남은 개수>). setup 이 로그에 옮겨 적는다.
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$ReportFile = "",
    [switch]$ListOnly
)
$ErrorActionPreference = "Continue"
$lines = New-Object System.Collections.Generic.List[string]
function Rep([string]$m) { $lines.Add($m); Write-Host $m }
function Save-Report {
    if (-not $ReportFile) { return }
    try { [System.IO.File]::WriteAllText($ReportFile, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false))) } catch {}
}

try { $full = [System.IO.Path]::GetFullPath($Root) } catch { Rep "STOP_RESULT 0 0"; Save-Report; exit 0 }
$prefix = $full.TrimEnd("\") + "\"
if (-not (Test-Path -LiteralPath $full)) { Rep "STOP_RESULT 0 0"; Save-Report; exit 0 }

# 나(와 내 부모들)는 끄지 않는다
$self = New-Object System.Collections.Generic.HashSet[int]
$all = @{}
foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $all[[int]$p.ProcessId] = $p }
$cur = [int]$PID
for ($i = 0; $i -lt 32 -and $cur -gt 0; $i++) {
    if (-not $self.Add($cur)) { break }
    if ($all.ContainsKey($cur)) { $cur = [int]$all[$cur].ParentProcessId } else { break }
}

function Get-Targets {
    $res = @()
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if (-not $p.ExecutablePath) { continue }
        if (-not $p.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($self.Contains([int]$p.ProcessId)) { continue }
        if ($p.Name -like "unins*.exe") { continue }
        $res += $p
    }
    return $res
}

$targets = @(Get-Targets)
if ($ListOnly) {
    foreach ($t in $targets) { Rep ("FOUND {0} {1}" -f $t.ProcessId, $t.Name) }
    Rep ("STOP_RESULT 0 {0}" -f $targets.Count)
    Save-Report
    exit 0
}
$stopped = 0
foreach ($t in $targets) {
    try {
        Stop-Process -Id ([int]$t.ProcessId) -Force -ErrorAction Stop
        Rep ("STOP {0} {1}" -f $t.ProcessId, $t.Name)
        $stopped++
    } catch {
        Rep ("TRY_FAIL {0} {1}" -f $t.ProcessId, $t.Name)
    }
}
# 끝날 때까지 잠깐 기다린다 (파일 잠금이 풀리도록). 최대 10초.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$left = @(Get-Targets)
while ($left.Count -gt 0 -and $sw.Elapsed.TotalSeconds -lt 10) {
    Start-Sleep -Milliseconds 300
    $left = @(Get-Targets)
}
foreach ($t in $left) { Rep ("SURVIVOR {0} {1}" -f $t.ProcessId, $t.Name) }
Rep ("STOP_RESULT {0} {1}" -f $stopped, $left.Count)
Save-Report
if ($left.Count -gt 0) { exit 1 }
exit 0
