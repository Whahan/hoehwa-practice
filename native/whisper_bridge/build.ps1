# Builds the WhisperBridge GDExtension (whisper.cpp inside a Godot extension) - docs/v200_phone_design.md section 1.2, path A.
#   powershell -ExecutionPolicy Bypass -File native\whisper_bridge\build.ps1 -Target android-arm64 -Out <build folder> [-AndroidSdk <sdk>] [-Ndk <ndk folder>]
#   powershell -ExecutionPolicy Bypass -File native\whisper_bridge\build.ps1 -Target windows-x64   -Out <build folder>
# Result: godot\bin\libwhisper_bridge.android.arm64.so  or  godot\bin\whisper_bridge.windows.x86_64.dll, a generated (untracked)
#         godot\whisper_bridge.gdextension, and the commits/hashes recorded in native\whisper_bridge\BUILD_INFO.json.
# Sources (not tracked): native\_deps\godot-cpp and native\_deps\whisper.cpp, both checked out at the pinned commits below.
#         -WhisperCommit / -GodotCppCommit only exist to make the check visible: anything but the pinned commit stops the build.
# Exit codes: 0 ok, 1 failure (nothing is built when a check fails).
param(
    [ValidateSet("android-arm64", "windows-x64")][string]$Target = "android-arm64",
    [string]$Out,
    [string]$WhisperCommit,
    [string]$GodotCppCommit,
    [string]$AndroidSdk,
    [string]$Ndk,
    [switch]$NoPatch   # measurement only: build WITHOUT the whisper.cpp patch, result in the Out folder under nopatch, nothing goes to godot/bin
)
$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---- pinned versions (change only together with BUILD_INFO.json / THIRD_PARTY.txt / README.txt)
$PinnedWhisper = "d1be6fde11ac6e0407606b4e42fe72d34add8037"   # whisper.cpp v1.9.5
$PinnedGodotCpp = "e83fd0904c13356ed1d4c3d09f8bb9132bdc6b77"  # godot-cpp godot-4.5-stable
$NdkVersion = "28.1.13356709"
$BridgeVersion = "1"

$Here = $PSScriptRoot
$Native = Split-Path $Here -Parent
$App = Split-Path $Native -Parent
$Deps = Join-Path $Native "_deps"
$GodotDir = Join-Path $App "godot"
$BinDir = Join-Path $GodotDir "bin"
$InfoFile = Join-Path $Here "BUILD_INFO.json"

function Fail([string]$msg) { throw $msg }
function Step([string]$m) { Write-Host "== $m" -ForegroundColor Cyan }
function Run([string]$exe, [string[]]$a) {
    & $exe @a
    if ($LASTEXITCODE -ne 0) { Fail "명령이 실패했어요 / command failed ($LASTEXITCODE): $exe $($a -join ' ')" }
}
function Check-Pin([string]$name, [string]$given, [string]$pinned) {
    if ($given) {
        $g = $given.Trim().ToLowerInvariant()
        if ($g.Length -lt 7 -or -not $pinned.StartsWith($g)) {
            Fail "$name 커밋 '$given' 은(는) 고정된 커밋이 아니에요. 고정값: $pinned / '$given' is not the pinned $name commit ($pinned). Nothing was built."
        }
    }
}
function Check-Checkout([string]$name, [string]$dir, [string]$pinned) {
    if (-not (Test-Path -LiteralPath (Join-Path $dir ".git"))) { Fail "$name 소스가 없어요: $dir (git clone 후 $pinned 로 checkout) / $name source missing" }
    $head = @(& git -C $dir rev-parse HEAD 2>$null)[0]
    if ($LASTEXITCODE -ne 0 -or -not $head) { Fail "$name 의 git 상태를 읽지 못했어요 / cannot read git state of $name" }
    if ($head.Trim() -ne $pinned) { Fail "$name 이(가) 고정된 커밋이 아니에요: $head (고정값 $pinned) / $name is not at the pinned commit" }
    $dirty = (& git -C $dir status --porcelain 2>$null)
    if ($dirty) { Fail "$name 작업 폴더가 수정돼 있어요 (재현이 안 돼요) / $name working tree is modified" }
}
# Patch of the pinned whisper.cpp (patches\*.patch): applied for the build only, the checkout is restored afterwards.
$script:Patched = $false
$PatchFile = Join-Path $Here "patches\whisper_abort_in_sched.patch"
function Apply-WhisperPatch {
    $wdir = Join-Path $Deps "whisper.cpp"
    $tmp = Join-Path $Out "whisper_abort.patch"
    New-Item -ItemType Directory -Force $Out | Out-Null
    [System.IO.File]::WriteAllText($tmp, ([System.IO.File]::ReadAllText($PatchFile) -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    & git -C $wdir apply --check $tmp
    if ($LASTEXITCODE -ne 0) { Fail "whisper.cpp 패치를 적용할 수 없어요 / cannot apply patches\whisper_abort_in_sched.patch to the pinned checkout" }
    & git -C $wdir apply $tmp
    if ($LASTEXITCODE -ne 0) { Fail "패치 적용 실패 / patch apply failed" }
    $script:Patched = $true
}
function Restore-Whisper {
    if ($script:Patched) {
        & git -C (Join-Path $Deps "whisper.cpp") checkout -- src/whisper.cpp
        $script:Patched = $false
    }
}
function Sha256([string]$f) { return (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLowerInvariant() }

try {
    Check-Pin "whisper.cpp" $WhisperCommit $PinnedWhisper
    Check-Pin "godot-cpp" $GodotCppCommit $PinnedGodotCpp
    if (-not $Out) { Fail "-Out <빌드 폴더> 가 필요해요 / -Out <build folder> is required" }
    Check-Checkout "whisper.cpp" (Join-Path $Deps "whisper.cpp") $PinnedWhisper
    Check-Checkout "godot-cpp" (Join-Path $Deps "godot-cpp") $PinnedGodotCpp
    if (-not $NoPatch) { Apply-WhisperPatch }

    $cmake = (Get-Command cmake -ErrorAction SilentlyContinue)
    if (-not $cmake) { Fail "cmake 를 찾지 못했어요 / cmake not found" }
    $Build = Join-Path $Out $Target
    $common = @("-S", $Here, "-B", $Build, "-DCMAKE_BUILD_TYPE=Release", "-DWB_WHISPER_COMMIT=$($PinnedWhisper.Substring(0,7))", "-DWB_BRIDGE_VERSION=$BridgeVersion", "-DBUILD_SHARED_LIBS=OFF")
    $outName = $null

    if ($Target -eq "android-arm64") {
        $sdk = $AndroidSdk
        if (-not $sdk) { $sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" } }
        $ndkDir = $Ndk
        if (-not $ndkDir) { $ndkDir = Join-Path $sdk "ndk\$NdkVersion" }
        $props = Join-Path $ndkDir "source.properties"
        if (-not (Test-Path -LiteralPath $props)) { Fail "Android NDK $NdkVersion 를 찾지 못했어요: $ndkDir / Android NDK $NdkVersion not found at $ndkDir" }
        $rev = (Get-Content -LiteralPath $props | Where-Object { $_ -match '^\s*Pkg\.Revision\s*=' } | Select-Object -First 1)
        if (-not $rev -or ($rev -replace '^\s*Pkg\.Revision\s*=\s*', '').Trim() -ne $NdkVersion) { Fail "NDK 버전이 달라요 ($rev), 필요: $NdkVersion / wrong NDK revision" }
        if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) { Fail "ninja 를 찾지 못했어요 / ninja not found" }
        $outName = "libwhisper_bridge.android.arm64.so"
        Step "configure (android arm64, NDK $NdkVersion)"
        Run "cmake" ($common + @("-G", "Ninja", "-DCMAKE_TOOLCHAIN_FILE=$ndkDir\build\cmake\android.toolchain.cmake", "-DANDROID_ABI=arm64-v8a", "-DANDROID_PLATFORM=android-24", "-DANDROID_STL=c++_static"))
    } else {
        # Windows desktop build for tests/calibration only (the PC app does not ship it). Needs VS 2022 C++ tools AND a Windows SDK.
        $vsw = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
        if (-not (Test-Path -LiteralPath $vsw)) { Fail "Visual Studio 2022 (C++ 도구)를 찾지 못했어요 / Visual Studio 2022 C++ tools not found" }
        $vs = @(& $vsw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)[0]
        if (-not $vs) {
            # vswhere hides an installation the installer still marks as incomplete: take any installation that has vcvars64.bat
            $vs = @(& $vsw -all -products * -property installationPath | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ "VC\Auxiliary\Build\vcvars64.bat")) })[0]
        }
        if (-not $vs) { Fail "Visual Studio 2022 의 C++ 도구가 없어요 / VS C++ tools missing" }
        $vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
        $kitRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10"
        $kits = Join-Path $kitRoot "Include"
        $sdkVer = $null
        if (Test-Path -LiteralPath $kits) {
            $sdkVer = (Get-ChildItem -LiteralPath $kits -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName "ucrt\stdio.h") } | Sort-Object Name -Descending | Select-Object -First 1).Name
        }
        $sdkOk = [bool]$sdkVer
        if (-not $sdkOk) { Fail "Windows 10/11 SDK 가 설치돼 있지 않아요 (헤더·라이브러리 없음) / Windows 10/11 SDK is not installed" }
        $outName = "whisper_bridge.windows.x86_64.dll"
        Step "configure + build (windows x64, Ninja inside vcvars64)"
        $cfg = ($common | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $env:Path = (Split-Path $vsw -Parent) + ";" + $env:Path   # vcvars64.bat needs vswhere.exe on PATH to find the Windows SDK
        # vcvars64.bat does not always find a standalone Windows SDK (it reads the registry): add its folders by hand
        $kInc = Join-Path $kits $sdkVer
        $kLib = Join-Path $kitRoot "Lib\$sdkVer"
        $kBin = Join-Path $kitRoot "bin\$sdkVer\x64"
        # one command per line: cmd expands %VAR% when it reads the line, so the set lines must come after the vcvars call
        $cmdLines = @(
            "@echo off",
            "@chcp 65001 >nul",
            "call `"$vcvars`" >nul",
            "set `"INCLUDE=%INCLUDE%;$kInc\ucrt;$kInc\um;$kInc\shared;$kInc\winrt`"",
            "set `"LIB=%LIB%;$kLib\ucrt\x64;$kLib\um\x64`"",
            "set `"PATH=$kBin;%PATH%`"",
            "cmake $cfg -DCMAKE_TRY_COMPILE_CONFIGURATION=Release -G Ninja || exit /b 1",
            "cmake --build `"$Build`" -j 8 || exit /b 1"
        )
        New-Item -ItemType Directory -Force $Out | Out-Null
        $cmdFile = Join-Path $Out "win_build.cmd"
        [System.IO.File]::WriteAllText($cmdFile, (($cmdLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
        cmd /c "`"$cmdFile`""
        if ($LASTEXITCODE -ne 0) { Fail "Windows 빌드가 실패했어요 / windows build failed" }
    }

    if ($Target -eq "android-arm64") {
        Step "build"
        Run "cmake" @("--build", $Build, "-j", "12")
    }

    $built = Join-Path $Build "out\$outName"
    if (-not (Test-Path -LiteralPath $built)) { Fail "빌드 결과가 없어요 / build output missing: $built" }
    if ($NoPatch) {
        $np = Join-Path $Out "nopatch"
        New-Item -ItemType Directory -Force $np | Out-Null
        Copy-Item -LiteralPath $built -Destination (Join-Path $np $outName) -Force
        Write-Host "OK (unpatched, measurement only) $np\$outName" -ForegroundColor Yellow
        Restore-Whisper
        exit 0
    }
    New-Item -ItemType Directory -Force $BinDir | Out-Null
    $dest = Join-Path $BinDir $outName
    Copy-Item -LiteralPath $built -Destination $dest -Force
    $hash = Sha256 $dest
    $size = (Get-Item -LiteralPath $dest).Length

    # generated .gdextension: the template, keeping only the libraries that really exist in godot\bin (untracked file)
    $tmpl = Get-Content -LiteralPath (Join-Path $Here "whisper_bridge.gdextension.in") -Encoding UTF8
    $lines = foreach ($l in $tmpl) {
        if ($l -match 'res://bin/([^"]+)"') { if (Test-Path -LiteralPath (Join-Path $BinDir $Matches[1])) { $l } } else { $l }
    }
    [System.IO.File]::WriteAllText((Join-Path $GodotDir "whisper_bridge.gdextension"), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    # BUILD_INFO.json (merge: keeps the other target's entry)
    $info = [ordered]@{}
    if (Test-Path -LiteralPath $InfoFile) {
        try { $old = Get-Content -LiteralPath $InfoFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($p in $old.PSObject.Properties) { $info[$p.Name] = $p.Value } } catch {}
    }
    $arts = [ordered]@{}
    if ($info.Contains("artifacts") -and $info["artifacts"]) { foreach ($p in $info["artifacts"].PSObject.Properties) { $arts[$p.Name] = $p.Value } }
    $arts[$Target] = [ordered]@{ file = "godot/bin/$outName"; bytes = $size; sha256 = $hash }
    $info["bridge_version"] = $BridgeVersion
    $info["whisper_cpp_commit"] = $PinnedWhisper
    $info["whisper_cpp_tag"] = "v1.9.5"
    $info["godot_cpp_commit"] = $PinnedGodotCpp
    $info["godot_cpp_tag"] = "godot-4.5-stable"
    $info["ndk_version"] = $NdkVersion
    $info["whisper_cpp_patches"] = @([ordered]@{ file = "native/whisper_bridge/patches/whisper_abort_in_sched.patch"; sha256 = (Sha256 $PatchFile); purpose = "abort callback also stops the ggml CPU compute inside the encoder/decoder graphs" })
    $info["artifacts"] = $arts
    [System.IO.File]::WriteAllText($InfoFile, (($info | ConvertTo-Json -Depth 6) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    Write-Host ("OK {0}  {1:N0} bytes  sha256 {2}" -f $dest, $size, $hash) -ForegroundColor Green
    Restore-Whisper
    exit 0
} catch {
    Restore-Whisper
    Write-Host ("FAIL: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
