# Checks that a built APK carries the phone speech-recognition library correctly (docs/v201_design.md section 2.7, 5.7).
# This file is plain ASCII on purpose: the design's constant-mutation test rewrites it as UTF-8 without BOM, and Windows PowerShell 5.1 would misread Korean text then.
#   powershell -ExecutionPolicy Bypass -File packaging\check_phone_native.ps1 -Apk <file.apk> [-BaselineApk <older.apk>] [-AndroidSdk <sdk folder>]
#   powershell -ExecutionPolicy Bypass -File packaging\check_phone_native.ps1 -SelfTest
# Checks (everything is read from the APK; the .so files are copied to a temporary folder that is deleted at the end):
#   (a) abi      lib/arm64-v8a/libwhisper_bridge.android.arm64.so exists; EVERY entry under lib/ is in the folder arm64-v8a (no other ABI folder, no
#                file straight under lib/, no duplicate entry names); EVERY lib/**.so (Godot's own too) has an ELF header that says ELFCLASS64,
#                little endian, ET_DYN and e_machine AArch64 (183) - the folder name alone proves nothing
#   (b) align    every LOAD segment of every lib/*/*.so has p_align >= 2**14 (llvm-objdump from the NDK) - 16 KB pages
#   (c) zipalign zipalign -c -P 16 -v 4 ends with "Verification successful"
#   (d) backup   aapt2 dump xmltree --file AndroidManifest.xml: the android:allowBackup attribute of the <application> element (exactly one, after
#                <manifest>) is false; its own attributes are only the run of "A:" lines right after its "E: application" line (indentation is not
#                used to decide; differently indented lines inside that run = fail); a missing attribute counts as true = fail; a false on
#                <activity> or <manifest> does not count
#   (e) needed   the bridge library needs at least one library and only libc.so libm.so libdl.so liblog.so libandroid.so
#   (f) files    no .dll and no ggml-*.bin anywhere in the APK
#   (g) size     APK <= 100,000,000 bytes and growth over the baseline APK <= $MaxGrowBytes (no default baseline APK found = "unverified" line;
#                a -BaselineApk that is missing, smaller than 1,000,000 bytes, or not a ZIP with AndroidManifest.xml fails)
# Last line: PHONE_NATIVE_OK or PHONE_NATIVE_FAIL <items>; exit code 0 / 1.  -SelfTest ends with SELFTEST_OK (exit 0) or SELFTEST_FAIL (exit 1).
param(
    [string]$Apk,
    [string]$BaselineApk,
    [string]$AndroidSdk,
    [switch]$SelfTest
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$MaxGrowBytes = 15000000
$MaxTotalBytes = 100000000
$BridgeSo = "lib/arm64-v8a/libwhisper_bridge.android.arm64.so"
$AllowedNeeded = @("libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so")
$MinAlignLog2 = 14
$ExpectedMachine = 183          # EM_AARCH64
$CheckElfMachine = $true        # (a): ELF header of every lib/**.so
$CheckAbiFolders = $true        # (a): every entry under lib/ is inside arm64-v8a
$MinBaselineBytes = 1000000
# ZIP entry names, folder names, library names are CASE SENSITIVE on Android. PowerShell hashtables, -eq, -like, -match, -contains,
# Sort-Object -Unique and friends ignore case, so every such comparison below uses an Ordinal comparer or a -c operator.
$NameComparer = [StringComparer]::Ordinal
$BackupApplicationOnly = $true  # (d): read allowBackup from the <application> element only, not the first match anywhere

# run a native tool; returns @(output lines, exit code). Never prints anything itself.
function Native([string]$exe, [string[]]$a) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = & $exe @a 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return ,@($out, $code)
}

function Find-Tools {
    $sdk = $AndroidSdk
    if (-not $sdk) { $sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" } }
    $bt = Join-Path $sdk "build-tools"
    if (-not (Test-Path -LiteralPath $bt)) { throw "Android SDK build-tools folder not found: $bt" }
    $dir = Get-ChildItem -LiteralPath $bt -Directory |
        Where-Object { (Test-Path (Join-Path $_.FullName "zipalign.exe")) -and (Test-Path (Join-Path $_.FullName "aapt2.exe")) } |
        Sort-Object { try { [version]$_.Name } catch { [version]"0.0" } } -Descending | Select-Object -First 1
    if (-not $dir) { throw "no build-tools folder with zipalign.exe and aapt2.exe in: $bt" }
    $ndkRoot = Join-Path $sdk "ndk"
    $objdump = $null
    if (Test-Path -LiteralPath $ndkRoot) {
        foreach ($n in (Get-ChildItem -LiteralPath $ndkRoot -Directory | Sort-Object { try { [version]$_.Name } catch { [version]"0.0" } } -Descending)) {
            $c = Join-Path $n.FullName "toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-objdump.exe"
            if (Test-Path -LiteralPath $c) { $objdump = $c; break }
        }
    }
    if (-not $objdump) { throw "NDK llvm-objdump.exe not found under: $ndkRoot" }
    return @{ Zipalign = (Join-Path $dir.FullName "zipalign.exe"); Aapt2 = (Join-Path $dir.FullName "aapt2.exe"); Objdump = $objdump; BuildTools = $dir.Name }
}

# ------------------------------------------------------------ context: APK entries + .so files copied to a temp folder
function New-Ctx([string]$apk, $tools) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cpn-" + [guid]::NewGuid().ToString("N").Substring(0, 10))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $names = New-Object System.Collections.Generic.List[string]
    $so = New-Object 'System.Collections.Generic.Dictionary[string,string]' $NameComparer
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' $NameComparer
    $dups = @()
    $zip = [IO.Compression.ZipFile]::OpenRead($apk)
    try {
        $i = 0
        foreach ($e in $zip.Entries) {
            $names.Add($e.FullName)
            if (-not $seen.Add($e.FullName)) { $dups += $e.FullName }
            if ($e.FullName -cmatch '^lib/.+\.[sS][oO]$' -and -not $so.ContainsKey($e.FullName)) {
                $i++
                $dst = Join-Path $tmp ("so$i.so")
                $in = $e.Open(); $outS = [IO.File]::Create($dst)
                try { $in.CopyTo($outS) } finally { $outS.Dispose(); $in.Dispose() }
                $so[$e.FullName] = $dst
            }
        }
    } finally { $zip.Dispose() }
    return @{ Apk = $apk; Tools = $tools; Names = $names; So = $so; Dups = $dups; Tmp = $tmp; Length = (Get-Item -LiteralPath $apk).Length }
}
function Remove-Ctx($ctx) { if ($ctx -and $ctx.Tmp -and (Test-Path -LiteralPath $ctx.Tmp)) { Remove-Item -LiteralPath $ctx.Tmp -Recurse -Force -ErrorAction SilentlyContinue } }

# [align exponents of the LOAD segments, NEEDED names] of an ELF; $null when llvm-objdump cannot read it
function Read-Elf($ctx, [string]$file) {
    $r = Native $ctx.Tools.Objdump @("-p", $file)
    if ($r[1] -ne 0) { return $null }
    $al = @(); $nd = @()
    foreach ($l in $r[0]) {
        if ($l -match '^\s*LOAD\s.*\balign\s+2\*\*(\d+)') { $al += [int]$Matches[1] }
        elseif ($l -match '^\s*NEEDED\s+(\S+)') { $nd += $Matches[1] }
    }
    return @{ Aligns = $al; Needed = $nd }
}

# ------------------------------------------------------------ checks: each returns @{ ok = bool; text = string }
# $null when the file is a 64-bit little-endian shared object for AArch64, else the reason
function Test-ElfHeader([string]$file) {
    $buf = New-Object byte[] 20
    $fs = [IO.File]::OpenRead($file)
    try { $n = $fs.Read($buf, 0, 20) } finally { $fs.Dispose() }
    if ($n -lt 20) { return "file too short for an ELF header" }
    if ($buf[0] -ne 0x7f -or $buf[1] -ne 0x45 -or $buf[2] -ne 0x4c -or $buf[3] -ne 0x46) { return "not an ELF file" }
    if ($buf[4] -ne 2) { return "not ELFCLASS64" }
    if ($buf[5] -ne 1) { return "not little endian" }
    $type = [BitConverter]::ToUInt16($buf, 16); $mach = [BitConverter]::ToUInt16($buf, 18)
    if ($type -ne 3) { return "e_type $type (shared object 3 needed)" }
    if ($mach -ne $ExpectedMachine) { return "e_machine $mach (AArch64 $ExpectedMachine needed)" }
    return $null
}
function Check-Abi($ctx) {
    $problems = @()
    if ($ctx.Dups.Count -gt 0) { $problems += "duplicate APK entry names: " + (($ctx.Dups | Select-Object -First 3) -join ", ") }
    if (-not $ctx.So.ContainsKey($BridgeSo)) { $problems += "$BridgeSo is not in the APK" }
    if ($CheckAbiFolders) {
        $abis = @(); $stray = @()
        foreach ($n in $ctx.Names) {
            if ($n -cnotlike "lib/*" -or $n -ceq "lib/") { continue }
            $parts = $n -split "/"
            if ($parts.Count -lt 3) { $stray += $n; continue }     # a file straight under lib/ has no ABI folder
            $abis += $parts[1]
        }
        $other = @($abis | Where-Object { $_ -cne "arm64-v8a" } | Select-Object -Unique)
        if ($other.Count -gt 0) { $problems += "ABI folder(s) other than arm64-v8a under lib/: [" + ($other -join ",") + "]" }
        if ($stray.Count -gt 0) { $problems += "entries straight under lib/ (no ABI folder): " + (($stray | Select-Object -First 3) -join ", ") }
    }
    if ($CheckElfMachine) {
        foreach ($k in ($ctx.So.Keys | Sort-Object)) {
            $why = Test-ElfHeader $ctx.So[$k]
            if ($why) { $problems += "$k : $why" }
        }
    }
    if ($problems.Count -gt 0) { return @{ ok = $false; text = ($problems -join "; ") } }
    return @{ ok = $true; text = "$BridgeSo present; every lib/ entry is under arm64-v8a; $($ctx.So.Count) .so file(s), all ELF64 little-endian AArch64 shared objects" }
}
function Check-Align($ctx) {
    if ($ctx.So.Count -eq 0) { return @{ ok = $false; text = "no lib/*/*.so in the APK" } }
    $bad = @(); $lines = @()
    foreach ($k in ($ctx.So.Keys | Sort-Object)) {
        $e = Read-Elf $ctx $ctx.So[$k]
        if ($null -eq $e -or $e.Aligns.Count -eq 0) { $bad += "$k(unreadable)"; continue }
        $min = ($e.Aligns | Measure-Object -Minimum).Minimum
        $lines += "$(Split-Path $k -Leaf) $($e.Aligns.Count) LOAD, min align 2**$min"
        if ($min -lt $MinAlignLog2) { $bad += "$(Split-Path $k -Leaf)(2**$min)" }
    }
    if ($bad.Count -gt 0) { return @{ ok = $false; text = "LOAD align smaller than 2**$MinAlignLog2 : " + ($bad -join ", ") } }
    return @{ ok = $true; text = "every .so has LOAD align >= 2**$MinAlignLog2 (" + ($lines -join "; ") + ")" }
}
function Check-ZipAlign($ctx) {
    $r = Native $ctx.Tools.Zipalign @("-c", "-P", "16", "-v", "4", $ctx.Apk)
    $last = ($r[0] | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 1)
    if ($r[1] -eq 0 -and $last -cmatch 'Verification successful') { return @{ ok = $true; text = "zipalign -c -P 16 -v 4: $last" } }
    return @{ ok = $false; text = "zipalign -c -P 16 -v 4 did not pass (exit $($r[1])): $last" }
}
function Test-BackupText([string]$txt) {
    $lines = @($txt -split "`r?`n")
    $mi = @(); for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -cmatch '^\s*E: manifest(\s|$)') { $mi += $i } }
    if ($mi.Count -ne 1) { return @{ ok = $false; text = "expected exactly one manifest element in the aapt2 output, found $($mi.Count)" } }
    if (-not $BackupApplicationOnly) {   # old behaviour, kept only so the self test can prove the new one is needed
        $m0 = [regex]::Match($txt, 'allowBackup\(0x[0-9a-fA-F]+\)=(\S+)')
        if (-not $m0.Success) { return @{ ok = $false; text = "no allowBackup attribute" } }
        return @{ ok = ($m0.Groups[1].Value -ceq "false"); text = "allowBackup=$($m0.Groups[1].Value) (first match anywhere)" }
    }
    # The indentation of the aapt2 output is NOT used to decide anything. Only the order of the lines: an element's own attributes are the
    # run of "A:" lines right after its "E:" line; the first line that is not an "A:" line (E:, N:, T:, ...) ends that run.
    $appIdx = @(); for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -cmatch '^\s*E: application(\s|$)') { $appIdx += $i } }
    if ($appIdx.Count -ne 1) { return @{ ok = $false; text = "expected exactly one application element in the aapt2 output, found $($appIdx.Count)" } }
    if ($appIdx[0] -le $mi[0]) { return @{ ok = $false; text = "the application element is not after the manifest element" } }
    $attrIndent = -1
    $vals = @()
    for ($i = $appIdx[0] + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '\S') { continue }
        if ($lines[$i] -cnotmatch '^\s*A: ') { break }      # BLOCKEND: the application's own attributes end at the first line that is not an A: line
        $ind = ([regex]::Match($lines[$i], '^(\s*)')).Groups[1].Length
        if ($attrIndent -lt 0) { $attrIndent = $ind }
        elseif ($ind -ne $attrIndent) { return @{ ok = $false; text = "the attribute lines of the application element are indented differently (unexpected aapt2 output)" } }
        $m = [regex]::Match($lines[$i], '^\s*A: http://schemas\.android\.com/apk/res/android:allowBackup\(0x[0-9a-fA-F]+\)=(\(type 0x[0-9a-fA-F]+\)0x[0-9a-fA-F]+|\S+)')
        if ($m.Success) { $vals += $m.Groups[1].Value }
    }
    if ($vals.Count -eq 0) { return @{ ok = $false; text = "the application element has no android:allowBackup attribute (a missing attribute means true)" } }
    if ($vals.Count -gt 1) { return @{ ok = $false; text = "the application element has several allowBackup attributes" } }
    $v = $vals[0]
    if ($v -ceq "false" -or $v -cmatch '^\(type 0x12\)0x0$') { return @{ ok = $true; text = "application allowBackup=false" } }
    return @{ ok = $false; text = "application allowBackup=$v (must be false)" }
}
function Check-Backup($ctx) {
    $r = Native $ctx.Tools.Aapt2 @("dump", "xmltree", "--file", "AndroidManifest.xml", $ctx.Apk)
    if ($r[1] -ne 0) { return @{ ok = $false; text = "aapt2 dump xmltree failed (exit $($r[1]))" } }
    return Test-BackupText ($r[0] -join "`n")
}
function Check-Needed($ctx) {
    if (-not $ctx.So.ContainsKey($BridgeSo)) { return @{ ok = $false; text = "$BridgeSo missing, NEEDED not readable" } }
    $e = Read-Elf $ctx $ctx.So[$BridgeSo]
    if ($null -eq $e) { return @{ ok = $false; text = "llvm-objdump could not read the bridge library" } }
    if ($e.Needed.Count -eq 0) { return @{ ok = $false; text = "no NEEDED entry could be read from the bridge library" } }
    $extra = @($e.Needed | Where-Object { $AllowedNeeded -cnotcontains $_ })
    if ($extra.Count -gt 0) { return @{ ok = $false; text = "NEEDED outside the allowed list: " + ($extra -join ", ") + " (all: " + ($e.Needed -join ",") + ")" } }
    return @{ ok = $true; text = "NEEDED = [" + ($e.Needed -join ",") + "] all in the allowed list" }
}
function Check-Files($ctx) {
    $bad = @($ctx.Names | Where-Object { $_ -match '(?i)\.dll$' -or (($_ -split '/')[-1]) -match '(?i)^ggml-.*\.bin$' })
    if ($bad.Count -gt 0) { return @{ ok = $false; text = "files that must not be in the APK: " + (($bad | Select-Object -First 5) -join ", ") } }
    return @{ ok = $true; text = "0 .dll, 0 ggml-*.bin ($($ctx.Names.Count) APK entries)" }
}
function Test-Size([long]$len, $baseLen) {
    if ($len -gt $MaxTotalBytes) { return @{ ok = $false; text = ("APK {0:N0} B is over the limit {1:N0} B" -f $len, $MaxTotalBytes) } }
    if ($null -ne $baseLen -and [long]$baseLen -lt $MinBaselineBytes) { return @{ ok = $false; text = ("baseline APK is only {0:N0} B, not a usable baseline" -f [long]$baseLen) } }
    if ($null -eq $baseLen) { return @{ ok = $true; text = ("total {0:N0} B (limit {1:N0}); growth: UNVERIFIED (no baseline APK found)" -f $len, $MaxTotalBytes) } }
    $grow = $len - [long]$baseLen
    if ($grow -gt $MaxGrowBytes) { return @{ ok = $false; text = ("growth over the baseline APK {0:N0} B is over the limit {1:N0} B (total {2:N0} B)" -f $grow, $MaxGrowBytes, $len) } }
    return @{ ok = $true; text = ("total {0:N0} B (limit {1:N0}); growth over the baseline {2:N0} B (limit {3:N0})" -f $len, $MaxTotalBytes, $grow, $MaxGrowBytes) }
}

# a usable baseline is an APK: a ZIP that can be opened and has AndroidManifest.xml (exact name)
function Test-Baseline([string]$path) {
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($path)
        $has = $false
        foreach ($e in $zip.Entries) { if ($e.FullName -ceq "AndroidManifest.xml") { $has = $true; break } }
        if (-not $has) { return @{ ok = $false; text = "baseline file is a ZIP but has no AndroidManifest.xml (not an APK): $path" } }
        return @{ ok = $true; text = "baseline is an APK" }
    } catch { return @{ ok = $false; text = "baseline file is not a readable ZIP/APK: $path" } }
    finally { if ($zip) { $zip.Dispose() } }
}

function Find-Baseline([string]$given) {
    if ($given) { if (Test-Path -LiteralPath $given -PathType Leaf) { return (Resolve-Path -LiteralPath $given).Path } else { return $null } }
    $rel = "out\release_2.0.0\hoehwa-practice-android-2.0.0.apk"
    $cands = @((Join-Path $PSScriptRoot $rel))
    try {   # a git worktree has no packaging\out: look in the main checkout too
        $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        $gc = & git -C $PSScriptRoot rev-parse --path-format=absolute --git-common-dir 2>$null
        $ErrorActionPreference = $old
        if ($LASTEXITCODE -eq 0 -and $gc) { $cands += (Join-Path (Split-Path ([string]$gc).Trim() -Parent) ("packaging\" + $rel)) }
    } catch { $ErrorActionPreference = "Stop" }
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path } }
    return $null
}

function Write-Result([string]$tag, [string]$name, $r) {
    Write-Host ("    ({0}) {1} {2}: {3}" -f $tag, $(if ($r.ok) { "OK" } else { "FAIL" }), $name, $r.text)
}

function Invoke-Checks([string]$apk, [string]$baseline) {
    $tools = Find-Tools
    Write-Host "== phone native library check: $apk"
    Write-Host "    build-tools $($tools.BuildTools)"
    $ctx = New-Ctx $apk $tools
    $failed = New-Object System.Collections.Generic.List[string]
    try {
        $baseLen = $null; $baseMissing = $false; $baseBad = $null
        $bp = Find-Baseline $baseline
        if ($bp) {
            $baseLen = (Get-Item -LiteralPath $bp).Length; Write-Host "    baseline APK: $bp ($baseLen B)"
            $bv = Test-Baseline $bp; if (-not $bv.ok) { $baseBad = $bv.text }
        }
        elseif ($baseline) { $baseMissing = $true; Write-Host "    baseline APK not found: $baseline" }
        $list = @(
            @("a", "abi", { Check-Abi $ctx }),
            @("b", "align", { Check-Align $ctx }),
            @("c", "zipalign", { Check-ZipAlign $ctx }),
            @("d", "backup", { Check-Backup $ctx }),
            @("e", "needed", { Check-Needed $ctx }),
            @("f", "files", { Check-Files $ctx }),
            @("g", "size", { if ($baseMissing) { @{ ok = $false; text = "the baseline APK given with -BaselineApk was not found: $baseline" } } elseif ($baseBad) { @{ ok = $false; text = $baseBad } } else { Test-Size $ctx.Length $baseLen } })
        )
        foreach ($c in $list) {
            $r = & $c[2]
            Write-Result $c[0] $c[1] $r
            if (-not $r.ok) { $failed.Add($c[1]) }
        }
    } finally { Remove-Ctx $ctx }
    return $failed
}

# ------------------------------------------------------------ self test: fake inputs that must fail, and one that must pass
function New-FakeElf([int]$alignLog2, [string[]]$needed, [int]$machine = 183) {
    $str = New-Object System.IO.MemoryStream
    $str.WriteByte(0)
    $offs = @()
    foreach ($n in $needed) { $offs += [int]$str.Length; $b = [Text.Encoding]::ASCII.GetBytes($n); $str.Write($b, 0, $b.Length); $str.WriteByte(0) }
    $strBytes = $str.ToArray()
    $strOff = 64 + 2 * 56
    $dynOff = $strOff + $strBytes.Length
    while ($dynOff % 8 -ne 0) { $dynOff++ }
    $dynCount = $needed.Count + 3
    $dynSize = $dynCount * 16
    $total = $dynOff + $dynSize
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([byte[]](0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    $w.Write([uint16]3); $w.Write([uint16]$machine); $w.Write([uint32]1)
    $w.Write([uint64]0); $w.Write([uint64]64); $w.Write([uint64]0)
    $w.Write([uint32]0); $w.Write([uint16]64); $w.Write([uint16]56); $w.Write([uint16]2); $w.Write([uint16]64); $w.Write([uint16]0); $w.Write([uint16]0)
    $w.Write([uint32]1); $w.Write([uint32]7); $w.Write([uint64]0); $w.Write([uint64]0); $w.Write([uint64]0)
    $w.Write([uint64]$total); $w.Write([uint64]$total); $w.Write([uint64]([math]::Pow(2, $alignLog2)))
    $w.Write([uint32]2); $w.Write([uint32]6); $w.Write([uint64]$dynOff); $w.Write([uint64]$dynOff); $w.Write([uint64]$dynOff)
    $w.Write([uint64]$dynSize); $w.Write([uint64]$dynSize); $w.Write([uint64]8)
    $w.Write($strBytes)
    while ($ms.Length -lt $dynOff) { $w.Write([byte]0) }
    foreach ($o in $offs) { $w.Write([uint64]1); $w.Write([uint64]$o) }
    $w.Write([uint64]5); $w.Write([uint64]$strOff)
    $w.Write([uint64]10); $w.Write([uint64]$strBytes.Length)
    $w.Write([uint64]0); $w.Write([uint64]0)
    $w.Flush()
    return $ms.ToArray()
}
$script:CrcTable = $null
function Get-Crc32([byte[]]$data) {
    if (-not $script:CrcTable) {
        $t = New-Object 'long[]' 256
        for ($n = 0; $n -lt 256; $n++) {
            $c = [long]$n
            for ($k = 0; $k -lt 8; $k++) { if ($c -band 1) { $c = (($c -shr 1) -bxor 3988292384) } else { $c = $c -shr 1 } }
            $t[$n] = $c
        }
        $script:CrcTable = $t
    }
    $crc = [long]4294967295
    foreach ($b in $data) { $crc = ($script:CrcTable[($crc -bxor $b) -band 255] -bxor ($crc -shr 8)) }
    return [uint32]($crc -bxor 4294967295)
}
# minimal ZIP writer, every entry stored (method 0), no alignment padding: so a .so is NOT 16 KB aligned until zipalign fixes it
function New-FakeZip([string]$path, [System.Collections.Specialized.OrderedDictionary]$files, [object[]]$extraPairs = @()) {
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $central = @()
    $all = @()
    foreach ($k in $files.Keys) { $all += , @($k, [byte[]]$files[$k]) }
    foreach ($p in $extraPairs) { $all += , @($p[0], [byte[]]$p[1]) }
    foreach ($pair in $all) {
        $name = [string]$pair[0]; $data = [byte[]]$pair[1]
        $nb = [Text.Encoding]::UTF8.GetBytes($name)
        $crc = Get-Crc32 $data
        $off = [uint32]$ms.Length
        $w.Write([uint32]0x04034b50); $w.Write([uint16]20); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]33)
        $w.Write([uint32]$crc); $w.Write([uint32]$data.Length); $w.Write([uint32]$data.Length); $w.Write([uint16]$nb.Length); $w.Write([uint16]0)
        $w.Write($nb); $w.Write($data)
        $central += , @($nb, $crc, [uint32]$data.Length, $off)
    }
    $cdOff = [uint32]$ms.Length
    foreach ($c in $central) {
        $w.Write([uint32]0x02014b50); $w.Write([uint16]20); $w.Write([uint16]20); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]33)
        $w.Write([uint32]$c[1]); $w.Write([uint32]$c[2]); $w.Write([uint32]$c[2]); $w.Write([uint16]$c[0].Length)
        $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint32]0); $w.Write([uint32]$c[3])
        $w.Write($c[0])
    }
    $cdSize = [uint32]($ms.Length - $cdOff)
    $w.Write([uint32]0x06054b50); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]$central.Count); $w.Write([uint16]$central.Count)
    $w.Write($cdSize); $w.Write($cdOff); $w.Write([uint16]0)
    $w.Flush()
    [IO.File]::WriteAllBytes($path, $ms.ToArray())
}
function Invoke-SelfTest {
    $tools = Find-Tools
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("cpn-self-" + [guid]::NewGuid().ToString("N").Substring(0, 10))
    New-Item -ItemType Directory -Force $dir | Out-Null
    $bad = New-Object System.Collections.Generic.List[string]
    # expectFail = item name that must fail; $null = the check must pass
    function Expect([string]$label, [string]$item, $r) {
        if ($item) {
            if (-not $r.ok) { Write-Host "SELFTEST FAIL-as-expected $item ($label)" }
            else { Write-Host "SELFTEST BROKEN $item ($label): a wrong input passed"; $bad.Add("$item/$label") }
        } else {
            if ($r.ok) { Write-Host "SELFTEST PASS ($label)" }
            else { Write-Host "SELFTEST BROKEN ($label): a good input failed: $($r.text)"; $bad.Add("pass/$label") }
        }
    }
    function Zip-Of([string]$name, $files, [bool]$align, [object[]]$extra = @()) {
        $p = Join-Path $dir "$name.zip"
        New-FakeZip $p $files $extra
        if ($align) {
            $q = Join-Path $dir "$name.aligned.zip"
            $r = Native $tools.Zipalign @("-f", "-P", "16", "4", $p, $q)
            if ($r[1] -ne 0 -or -not (Test-Path -LiteralPath $q)) { throw "zipalign could not align the test zip: " + ($r[0] -join " ") }
            return $q
        }
        return $p
    }
    function With-Ctx([string]$zip, [scriptblock]$body) {
        $c = New-Ctx $zip $tools
        try { return (& $body $c) } finally { Remove-Ctx $c }
    }
    try {
        $good = New-FakeElf 14 @("libm.so", "libdl.so", "libc.so")
        $names = @{ so = $BridgeSo }
        # normal input: aligned ELF, allowed NEEDED, zip aligned by zipalign, no .dll/.bin, small size, backup=false
        $files = [ordered]@{ "AndroidManifest.xml" = [byte[]](1, 2, 3); $BridgeSo = $good; "assets/data.txt" = [byte[]](65, 66) }
        $okZip = Zip-Of "ok" $files $true
        With-Ctx $okZip { param($c)
            Expect "abi" $null (Check-Abi $c); Expect "align" $null (Check-Align $c); Expect "zipalign" $null (Check-ZipAlign $c)
            Expect "needed" $null (Check-Needed $c); Expect "files" $null (Check-Files $c)
        }
        $mf = "N: android=http://schemas.android.com/apk/res/android`n  E: manifest (line=2)`n    A: package=`"x`"`n      E: application (line=5)`n"
        Expect "backup false" $null (Test-BackupText ($mf + "        A: http://schemas.android.com/apk/res/android:allowBackup(0x01010280)=false"))
        Expect "size" $null (Test-Size 20000000 10000000)
        # wrong inputs
        $f2 = [ordered]@{ $BridgeSo = (New-FakeElf 12 @("libc.so")) }
        With-Ctx (Zip-Of "align4k" $f2 $true) { param($c) Expect "4 KB LOAD align" "align" (Check-Align $c) }
        With-Ctx (Zip-Of "unaligned" $files $false) { param($c) Expect "zip entry not 16 KB aligned" "zipalign" (Check-ZipAlign $c) }
        Expect "allowBackup=true" "backup" (Test-BackupText ($mf + "        A: http://schemas.android.com/apk/res/android:allowBackup(0x01010280)=true"))
        Expect "allowBackup=false but no manifest element" "backup" (Test-BackupText "A: http://schemas.android.com/apk/res/android:allowBackup(0x01010280)=false")
        Expect "allowBackup missing" "backup" (Test-BackupText ($mf + "        A: http://schemas.android.com/apk/res/android:label(0x01010001)=`"x`""))
        $f3 = [ordered]@{ $BridgeSo = $good; "assets/whisper_bridge.windows.x86_64.dll" = [byte[]](1, 2, 3) }
        With-Ctx (Zip-Of "dll" $f3 $true) { param($c) Expect ".dll inside" "files" (Check-Files $c) }
        $f4 = [ordered]@{ $BridgeSo = $good; "assets/models/ggml-base.en-q5_1.bin" = [byte[]](1, 2, 3) }
        With-Ctx (Zip-Of "bin" $f4 $true) { param($c) Expect "ggml-*.bin inside" "files" (Check-Files $c) }
        $f5 = [ordered]@{ $BridgeSo = (New-FakeElf 14 @("libc.so", "libc++_shared.so")) }
        With-Ctx (Zip-Of "needed" $f5 $true) { param($c) Expect "NEEDED libc++_shared.so" "needed" (Check-Needed $c) }
        $f6 = [ordered]@{ "lib/x86_64/libwhisper_bridge.android.arm64.so" = $good }
        With-Ctx (Zip-Of "abi" $f6 $true) { param($c) Expect "bridge library missing / wrong ABI folder" "abi" (Check-Abi $c) }
        $f7 = [ordered]@{ $BridgeSo = $good; "lib/x86_64/libother.so" = $good }
        With-Ctx (Zip-Of "abi2" $f7 $true) { param($c) Expect "second ABI folder" "abi" (Check-Abi $c) }
        # ELF header / ABI folder holes: the folder name and the LOAD/NEEDED text alone must not be enough
        $x86 = New-FakeElf 14 @("libc.so", "libm.so", "libdl.so") 62
        $e32 = [byte[]]$good.Clone(); $e32[4] = 1
        $beBig = [byte[]]$good.Clone(); $beBig[5] = 2
        $f8 = [ordered]@{ $BridgeSo = $x86 }
        With-Ctx (Zip-Of "x86elf" $f8 $true) { param($c) Expect "bridge ELF says x86-64 (e_machine 62) in arm64-v8a" "abi" (Check-Abi $c) }
        $f9 = [ordered]@{ $BridgeSo = $good; "lib/arm64-v8a/libgodot_android.so" = $x86 }
        With-Ctx (Zip-Of "x86godot" $f9 $true) { param($c) Expect "another .so in arm64-v8a is x86-64" "abi" (Check-Abi $c) }
        $f10 = [ordered]@{ $BridgeSo = $e32 }
        With-Ctx (Zip-Of "elf32" $f10 $true) { param($c) Expect "bridge ELF is ELFCLASS32" "abi" (Check-Abi $c) }
        $f10b = [ordered]@{ $BridgeSo = $beBig }
        With-Ctx (Zip-Of "elfbe" $f10b $true) { param($c) Expect "bridge ELF is big endian" "abi" (Check-Abi $c) }
        $f11 = [ordered]@{ $BridgeSo = [Text.Encoding]::ASCII.GetBytes("this is not an ELF file at all, only text") }
        With-Ctx (Zip-Of "notelf" $f11 $true) { param($c) Expect "bridge .so is not an ELF" "abi" (Check-Abi $c) }
        $f12 = [ordered]@{ $BridgeSo = $good; "lib/x86_64/readme.txt" = [byte[]](65, 66) }
        With-Ctx (Zip-Of "x86file" $f12 $true) { param($c) Expect "other ABI folder with a plain file in it" "abi" (Check-Abi $c) }
        $f13 = [ordered]@{ $BridgeSo = $good; "lib/x86_64/" = [byte[]]@() }
        With-Ctx (Zip-Of "x86dir" $f13 $true) { param($c) Expect "other ABI folder (directory entry only)" "abi" (Check-Abi $c) }
        $f14 = [ordered]@{ $BridgeSo = $good; "lib/readme.txt" = [byte[]](65, 66) }
        With-Ctx (Zip-Of "libstray" $f14 $true) { param($c) Expect "file straight under lib/" "abi" (Check-Abi $c) }
        $f15 = [ordered]@{ $BridgeSo = $good }
        With-Ctx (Zip-Of "dupname" $f15 $true @(, @($BridgeSo, $x86))) { param($c) Expect "duplicate entry name" "abi" (Check-Abi $c) }
        $f16 = [ordered]@{ $BridgeSo = (New-FakeElf 14 @()) }
        With-Ctx (Zip-Of "noneeded" $f16 $true) { param($c) Expect "bridge with no NEEDED at all" "needed" (Check-Needed $c) }
        # case sensitivity: names that differ only by case are different ZIP paths / folders / libraries
        $A = "http://schemas.android.com/apk/res/android"
        $f17 = [ordered]@{ $BridgeSo = $good }     # a hashtable literal cannot hold two keys that differ only by case, so they go in as extra pairs
        With-Ctx (Zip-Of "casepair" $f17 $true @(@("assets/TestCase.txt", [byte[]](65)), @("assets/testcase.txt", [byte[]](66)))) { param($c) Expect "assets/TestCase.txt + assets/testcase.txt are two valid paths" $null (Check-Abi $c); Expect "case pair, files" $null (Check-Files $c) }
        $f18 = [ordered]@{ "LIB/ARM64-V8A/LIBWHISPER_BRIDGE.ANDROID.ARM64.SO" = $good }
        With-Ctx (Zip-Of "upperpath" $f18 $true) { param($c) Expect "bridge path all upper case" "abi" (Check-Abi $c) }
        $f19 = [ordered]@{ "lib/arm64-v8a/LIBWHISPER_BRIDGE.ANDROID.ARM64.SO" = $good }
        With-Ctx (Zip-Of "upperfile" $f19 $true) { param($c) Expect "bridge file name upper case" "abi" (Check-Abi $c) }
        $f20 = [ordered]@{ $BridgeSo = $good; "lib/ARM64-V8A/libother.so" = $good }
        With-Ctx (Zip-Of "upperabi" $f20 $true) { param($c) Expect "ABI folder ARM64-V8A is not arm64-v8a" "abi" (Check-Abi $c) }
        $f21 = [ordered]@{ $BridgeSo = (New-FakeElf 14 @("LIBC.SO", "libm.so")) }
        With-Ctx (Zip-Of "upperneeded" $f21 $true) { param($c) Expect "NEEDED LIBC.SO" "needed" (Check-Needed $c) }
        # allowBackup must come from the application element
        $mAct = "N: android=$A`n  E: manifest (line=2)`n    A: ${A}:package=`"x`"`n      E: application (line=5)`n        A: ${A}:label(0x01010001)=`"x`"`n        E: activity (line=9)`n          A: ${A}:allowBackup(0x01010280)=false"
        Expect "allowBackup=false only on an activity" "backup" (Test-BackupText $mAct)
        $mMan = "N: android=$A`n  E: manifest (line=2)`n    A: ${A}:allowBackup(0x01010280)=false`n      E: application (line=5)`n        A: ${A}:label(0x01010001)=`"x`""
        Expect "allowBackup=false only on the manifest" "backup" (Test-BackupText $mMan)
        $mTrueAct = "N: android=$A`n  E: manifest (line=2)`n      E: application (line=5)`n        A: ${A}:allowBackup(0x01010280)=false`n          E: activity (line=9)`n            A: ${A}:allowBackup(0x01010280)=true"
        Expect "application false, activity true" $null (Test-BackupText $mTrueAct)
        $mTrueApp = "N: android=$A`n  E: manifest (line=2)`n      E: application (line=5)`n        A: ${A}:allowBackup(0x01010280)=true`n          E: activity (line=9)`n            A: ${A}:allowBackup(0x01010280)=false"
        Expect "application true, activity false" "backup" (Test-BackupText $mTrueApp)
        # allowBackup is read from the run of A: lines right after E: application, whatever the indentation says (real aapt2 2-space steps used below)
        $hd = "N: android=$A (line=1)`n  E: manifest (line=1)`n    A: ${A}:compileSdkVersion(0x01010572)=36`n    A: package=`"x`" (Raw: `"x`")`n"
        $nm = "${A}:name(0x01010003)=`".TestActivity`" (Raw: `".TestActivity`")"
        $ab = "${A}:allowBackup(0x01010280)=false"
        $realOk = $hd + "      E: application (line=2)`n        A: ${A}:label(0x01010001)=@0x7f0b0004`n        A: $ab`n        A: ${A}:isGame(0x010103f4)=true`n          E: profileable (line=5)`n            A: ${A}:enabled(0x0101000e)=true`n          E: activity (line=6)`n            A: $nm`n            A: ${A}:exported(0x01010010)=false"
        Expect "real format: application false, then children" $null (Test-BackupText $realOk)
        Expect "real format, type 0x12 false" $null (Test-BackupText ($hd + "      E: application (line=2)`n        A: ${A}:allowBackup(0x01010280)=(type 0x12)0x0`n          E: activity (line=3)`n            A: $nm"))
        $actOnly = $hd + "      E: application (line=2)`n          E: activity (line=3)`n            A: $nm`n            A: $ab"
        Expect "activity-only, real indentation" "backup" (Test-BackupText $actOnly)
        $actOnly8 = $hd + "      E: application (line=2)`n          E: activity (line=3)`n        A: $nm`n        A: $ab"
        Expect "activity-only, activity attribute lines moved to 8 columns" "backup" (Test-BackupText $actOnly8)
        Expect "activity-only, attribute lines at 6 columns" "backup" (Test-BackupText ($hd + "      E: application (line=2)`n          E: activity (line=3)`n      A: $ab"))
        Expect "application has a label, activity false with the same indentation" "backup" (Test-BackupText ($hd + "      E: application (line=2)`n        A: ${A}:label(0x01010001)=@0x7f0b0004`n          E: activity (line=3)`n        A: $ab"))
        Expect "application attribute lines indented differently" "backup" (Test-BackupText ($hd + "      E: application (line=2)`n        A: ${A}:label(0x01010001)=@0x7f0b0004`n          A: $ab"))
        Expect "application attribute lines indented differently (false first)" "backup" (Test-BackupText ($hd + "      E: application (line=2)`n          A: $ab`n        A: ${A}:label(0x01010001)=@0x7f0b0004"))
        Expect "two application elements" "backup" (Test-BackupText ($realOk + "`n      E: application (line=20)`n        A: $ab"))
        Expect "two application elements, first without allowBackup" "backup" (Test-BackupText ($hd + "      E: application (line=2)`n        A: ${A}:label(0x01010001)=@0x7f0b0004`n      E: application (line=20)`n        A: $ab"))
        Expect "application before manifest" "backup" (Test-BackupText ("      E: application (line=2)`n        A: $ab`n" + $hd))
        Expect "two allowBackup attributes in the application" "backup" (Test-BackupText ($hd + "      E: application (line=2)`n        A: $ab`n        A: $ab"))
        Expect "application has no attribute lines at all" "backup" (Test-BackupText ($hd + "      E: application (line=2)"))
        # baseline file must be an APK
        $txtBase = Join-Path $dir "base.txt"; [IO.File]::WriteAllText($txtBase, ("this is not a zip file " * 100))
        Expect "baseline is a text file" "size" (Test-Baseline $txtBase)
        $noMan = Zip-Of "nomanifest" ([ordered]@{ "assets/a.txt" = [byte[]](1) }) $false
        Expect "baseline ZIP without AndroidManifest.xml" "size" (Test-Baseline $noMan)
        Expect "baseline APK-like ZIP" $null (Test-Baseline $okZip)
        Expect "baseline far too small" "size" (Test-Size 20000000 5)
        Expect "growth over limit" "size" (Test-Size 30000000 10000000)
        Expect "total over limit" "size" (Test-Size 100000001 $null)
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($bad.Count -gt 0) { Write-Host ("SELFTEST_FAIL " + ($bad -join " ")); return 1 }
    Write-Host "SELFTEST_OK"
    return 0
}

# ------------------------------------------------------------ main
try {
    if ($SelfTest) { exit (Invoke-SelfTest) }
    if (-not $Apk) { throw "give the APK: check_phone_native.ps1 -Apk <file.apk>" }
    if (-not (Test-Path -LiteralPath $Apk -PathType Leaf)) { throw "APK not found: $Apk" }
    $failed = Invoke-Checks (Resolve-Path -LiteralPath $Apk).Path $BaselineApk
    if ($failed.Count -eq 0) { Write-Host "PHONE_NATIVE_OK"; exit 0 }
    Write-Host ("PHONE_NATIVE_FAIL " + ($failed -join " "))
    exit 1
}
catch {
    Write-Host ("error: " + $_.Exception.Message) -ForegroundColor Red
    if ($SelfTest) { Write-Host "SELFTEST_FAIL error" } else { Write-Host "PHONE_NATIVE_FAIL input" }
    exit 1
}
