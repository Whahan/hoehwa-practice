# Checks that a built APK carries the phone-only data pack and stays small enough (docs/phone_standalone_design.md A8-1, A8-3).
#   powershell -ExecutionPolicy Bypass -File packaging\check_phone_pack.ps1 <file.apk> [-MaxBytes 100000000] [-RequireFile name.json,...]
# What it looks at (all read from the APK itself; nothing is extracted to disk):
#   1. assets/data/pack/manifest.json exists and is valid JSON with a "files" list.
#   2. Every file of that list is in the APK (assets/data/pack/<path>) with the size and SHA-256 the manifest names.
#   3. The engine's file index (assets/assets.sparsepck, Godot 4.6 APK layout) names manifest.json and every pack file with the
#      same size. Without that index the APK is rejected too: res:// could not find the files.
#   4. The APK is at most -MaxBytes bytes (default 100,000,000).
#   -RequireFile : extra names that must be in the pack (a way to see the check fail; also usable for a file the manifest forgets).
# Exit code 0 = all checks passed, 1 = anything else (a missing/unreadable APK included).
param(
    [Parameter(Position = 0)][string]$Apk,
    [long]$MaxBytes = 100000000,
    [string[]]$RequireFile = @()
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$PackDir = "assets/data/pack/"
$problems = New-Object System.Collections.Generic.List[string]
$zip = $null
$sha = $null

function Problem([string]$m) { $script:problems.Add($m); Write-Host "    X $m" -ForegroundColor Red }
function Good([string]$m) { Write-Host "    O $m" }

# [{path; size}] of a Godot PCK directory (format 2/3: header, directory at dir_offset). $null when it cannot be read.
function Read-PckIndex([byte[]]$b) {
    if ($b.Length -lt 64 -or [System.Text.Encoding]::ASCII.GetString($b, 0, 4) -ne "GDPC") { return $null }
    $ver = [BitConverter]::ToUInt32($b, 4)
    if ($ver -ne 3) { return $null }
    $dirOfs = [int][BitConverter]::ToUInt64($b, 32)
    if ($dirOfs -lt 40 -or $dirOfs -ge $b.Length) { return $null }
    $off = $dirOfs
    $n = [int][BitConverter]::ToUInt32($b, $off); $off += 4
    $list = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $n; $i++) {
        if ($off + 4 -gt $b.Length) { return $null }
        $len = [int][BitConverter]::ToUInt32($b, $off); $off += 4
        if ($len -lt 0 -or $off + $len + 8 + 8 + 16 + 4 -gt $b.Length) { return $null }
        $name = [System.Text.Encoding]::UTF8.GetString($b, $off, $len).TrimEnd([char]0); $off += $len
        $size = [long][BitConverter]::ToUInt64($b, $off + 8); $off += 8 + 8 + 16 + 4
        $list.Add([pscustomobject]@{ path = ($name -replace '^res://', ''); size = $size })
    }
    return ,$list
}

try {
    if (-not $Apk) { throw "APK 파일을 알려 주세요: check_phone_pack.ps1 <file.apk>" }
    if (-not (Test-Path -LiteralPath $Apk -PathType Leaf)) { throw "APK 가 없어요: $Apk" }
    Write-Host "== 폰 단독 데이터 팩 검사: $Apk"

    # ---- 4. size
    $len = (Get-Item -LiteralPath $Apk).Length
    if ($len -le $MaxBytes) { Good ("APK 크기 {0:N0} 바이트 (한도 {1:N0})" -f $len, $MaxBytes) }
    else { Problem ("APK 가 너무 커요: {0:N0} 바이트 > 한도 {1:N0}" -f $len, $MaxBytes) }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Apk).Path)
    $entries = @{}
    foreach ($e in $zip.Entries) { $entries[$e.FullName] = $e }

    # ---- 1. manifest
    $mEntry = $entries[$PackDir + "manifest.json"]
    if ($null -eq $mEntry) { throw "APK 안에 $($PackDir)manifest.json 이 없어요(내보내기 포함 필터에 data/pack 이 빠졌는지 확인하세요)." }
    $sr = New-Object System.IO.StreamReader($mEntry.Open(), (New-Object System.Text.UTF8Encoding($false)))
    try { $mText = $sr.ReadToEnd() } finally { $sr.Dispose() }
    try { $manifest = $mText | ConvertFrom-Json } catch { throw "manifest.json 이 올바른 JSON 이 아니에요: $($_.Exception.Message)" }
    $files = @($manifest.files)
    if ($files.Count -eq 0) { throw "manifest.json 에 files 목록이 없어요." }
    Good ("manifest.json 이 있고 파일 {0}개가 적혀 있어요" -f $files.Count)

    # ---- 2. every manifest file: present, size, sha256
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $before = $problems.Count
    $required = @{}
    foreach ($f in $files) {
        $p = [string]$f.path
        if (-not $p -or $p.Contains("..") -or $p.StartsWith("/")) { Problem "manifest 의 파일 경로가 이상해요: '$p'"; continue }
        $required[$p] = $true
        $en = $entries[$PackDir + $p]
        if ($null -eq $en) { Problem "APK 에 없어요: $PackDir$p"; continue }
        if ([long]$f.bytes -ne $en.Length) { Problem ("크기가 manifest 와 달라요: {0} ({1} != {2})" -f $p, $en.Length, $f.bytes); continue }
        $st = $en.Open()
        try { $hash = ([BitConverter]::ToString($sha.ComputeHash($st)) -replace '-', '').ToLower() } finally { $st.Dispose() }
        if ($hash -ne ([string]$f.sha256).ToLower()) { Problem "sha256 이 manifest 와 달라요: $p"; continue }
    }
    foreach ($r in $RequireFile) {
        if (-not $r) { continue }
        $required[$r] = $true
        if ($null -eq $entries[$PackDir + $r]) { Problem "필수로 요구한 파일이 APK 에 없어요: $PackDir$r" }
    }
    if ($problems.Count -eq $before) { Good ("manifest 의 파일 {0}개가 모두 있고 크기·sha256 이 맞아요" -f $files.Count) }

    # ---- 3. the engine's index names them too
    $idxEntry = $entries["assets/assets.sparsepck"]
    if ($null -eq $idxEntry) { Problem "엔진 파일 색인(assets/assets.sparsepck)이 APK 에 없어요. 앱이 res:// 로 팩 파일을 못 찾을 수 있어요." }
    else {
        $ms = New-Object System.IO.MemoryStream
        $st = $idxEntry.Open()
        try { $st.CopyTo($ms) } finally { $st.Dispose() }
        $index = Read-PckIndex $ms.ToArray()
        if ($null -eq $index) { Problem "엔진 파일 색인을 읽지 못했어요(assets.sparsepck 형식이 달라졌을 수 있어요)." }
        else {
            $bySize = @{}
            foreach ($it in $index) { $bySize[$it.path] = $it.size }
            $miss = New-Object System.Collections.Generic.List[string]
            $names = @("manifest.json") + @($required.Keys)
            foreach ($n in $names) {
                $key = "data/pack/$n"
                if (-not $bySize.ContainsKey($key)) { $miss.Add($n); continue }
                $zn = $entries[$PackDir + $n]
                if ($null -ne $zn -and $bySize[$key] -ne $zn.Length) { $miss.Add("$n (크기 다름)") }
            }
            if ($miss.Count -gt 0) { Problem ("엔진 파일 색인에 없거나 크기가 달라요: " + ($miss -join ", ")) }
            else { Good ("엔진 파일 색인({0}개 항목)에 팩 파일이 모두 있어요" -f $index.Count) }
        }
    }
}
catch {
    Problem $_.Exception.Message
}
finally {
    if ($null -ne $sha) { $sha.Dispose() }
    if ($null -ne $zip) { $zip.Dispose() }
}
if ($problems.Count -gt 0) {
    Write-Host ("폰 단독 데이터 팩 검사 실패: 문제 {0}개" -f $problems.Count) -ForegroundColor Red
    exit 1
}
Write-Host "폰 단독 데이터 팩 검사 통과"
exit 0
