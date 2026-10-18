# S4 runner for the learning-record sync engine tests (docs/sync_design.md 7.4 and 10.7).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File run_sync_tests.ps1 [-Work <scratch folder>] [-Mutations]
#
# Plain run (default):
#   1. snapshot of the real user-data folder (prefs.json / progress.json md5, file list; studylog.json and logs excluded)
#      and of backend\data\sync (must not be created or changed)
#   2. free ports from 18791..18799 (never 8770 / 8775 / 8776 / 8862..8869)
#   3. stub hub (backend\lan_stub_server.py, --sync-dir in the work folder, phone-link listener on a free port)
#      + a counting proxy in front of it (generated into the work folder)
#   4. Godot: tests\sync_engine_test.tscn, then tests\sync_roundtrip_test.tscn. APPDATA and HOEHWA_SYNC_TEST_ROOT point to a
#      test folder inside the work folder, so the real user folder is never written
#   5. only the PIDs this runner started are stopped; the ports are checked free again
#   6. snapshots compared again (E-RT10). Last line: "SYNC_E2E_RESULT PASS" or "SYNC_E2E_RESULT FAIL"
#
# -Mutations: runs the engine mutations of sync_engine_mutations.json on a COPY of the godot folder (the original is only read;
#   its md5 is checked before and after). Last line: "SYNC_MUT_RESULT PASS n/n" or "SYNC_MUT_RESULT FAIL k/n".
#
# Windows PowerShell 5.1 compatible. ASCII only. Exit code 0 only for PASS.

param(
    [string]$Work = '',
    [string]$Godot = (Join-Path $env:USERPROFILE 'Desktop\Godot_v4.6.3-stable_win64.exe\Godot_v4.6.3-stable_win64_console.exe'),
    [string]$Python = '',
    [switch]$Mutations,
    [switch]$SelfTest,
    [int]$RunTimeoutSec = 900
)

$ErrorActionPreference = 'Stop'
$script:PortCandidates = @(18791, 18792, 18793, 18794, 18795, 18796, 18797, 18798, 18799)
$script:Started = @()          # PIDs this runner started (only these are stopped)
$script:Lines = @()            # report lines
$script:Overall = $true

function Say([string]$s) {
    $script:Lines += $s
    Write-Output $s
}

function Get-Md5([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return 'ABSENT' }
    return (Get-FileHash -Algorithm MD5 -LiteralPath $p).Hash
}

function Read-Utf8([string]$p) {
    return [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Shared([string]$p) {
    # a process may still hold its redirected output open: read with shared access
    $fs = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
        return $sr.ReadToEnd()
    } finally {
        $fs.Close()
    }
}

function Write-Utf8([string]$p, [string]$t) {
    [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
}

function Count-Occ([string]$hay, [string]$needle) {
    if ($needle.Length -eq 0) { return 0 }
    $n = 0
    $i = 0
    while ($true) {
        $j = $hay.IndexOf($needle, $i, [System.StringComparison]::Ordinal)
        if ($j -lt 0) { break }
        $n++
        $i = $j + $needle.Length
    }
    return $n
}

# ---- real user data folder (read only). The app folder name (the project name) is built from code points: ASCII-only script
function Get-RealUserDir([string]$appdata) {
    $name = [string]::new([char[]]@(0xD68C, 0xD654, 0x20, 0xC5F0, 0xC2B5))
    return (Join-Path $appdata ('Godot\app_userdata\' + $name))
}

# Only the app's own files are compared (test_* files, logs, shader_cache and other folders written by other tests are ignored).
# Strict (FAIL on any change): prefs.json, progress.json, remote.json, curriculum.json, sync_state.json and the sync_backup folder.
# studylog.json: its presence must not change (FAIL); a change of its content is only a WARNING, because the app may write it.
$script:StrictFiles = @('prefs.json', 'progress.json', 'remote.json', 'curriculum.json', 'sync_state.json')

function Get-UserSnapshot([string]$dir) {
    $snap = @{ Present = $false; Files = @{}; Soft = @{}; Backup = 'ABSENT' }
    if (-not (Test-Path -LiteralPath $dir)) { return $snap }
    $snap.Present = $true
    $root = (Resolve-Path -LiteralPath $dir).Path.TrimEnd('\')
    foreach ($k in $script:StrictFiles) {
        $snap.Files[$k] = Get-Md5 (Join-Path $root $k)
    }
    $sp = Join-Path $root 'studylog.json'
    if (Test-Path -LiteralPath $sp) {
        $snap.Files['studylog.json'] = 'PRESENT'
        $snap.Soft['studylog.json'] = Get-Md5 $sp
    } else {
        $snap.Files['studylog.json'] = 'ABSENT'
    }
    $bk = Join-Path $root 'sync_backup'
    if (Test-Path -LiteralPath $bk) {
        $broot = (Resolve-Path -LiteralPath $bk).Path.TrimEnd('\')
        $rows = @()
        foreach ($f in @(Get-ChildItem -LiteralPath $broot -Recurse -Force)) {
            $rows += ($f.FullName.Substring($broot.Length) + '|' + [string]$f.Length)
        }
        $snap.Backup = 'PRESENT:' + (($rows | Sort-Object) -join ';')
    }
    return $snap
}

# -> @{ Ok = bool; Fails = @(strings); Warns = @(strings) }
function Compare-UserSnapshot($a, $b) {
    $fails = @()
    $warns = @()
    foreach ($k in $script:StrictFiles) {
        if ($a.Files[$k] -ne $b.Files[$k]) {
            $fails += ($k + ' changed (' + [string]$a.Files[$k] + ' -> ' + [string]$b.Files[$k] + ')')
        }
    }
    if ($a.Files['studylog.json'] -ne $b.Files['studylog.json']) {
        $fails += ('studylog.json presence changed (' + [string]$a.Files['studylog.json'] + ' -> ' + [string]$b.Files['studylog.json'] + ')')
    } elseif ($a.Files['studylog.json'] -eq 'PRESENT' -and $a.Soft['studylog.json'] -ne $b.Soft['studylog.json']) {
        $warns += 'studylog.json content changed (not a failure: the app may write it)'
    }
    if ($a.Backup -ne $b.Backup) {
        $fails += 'sync_backup folder changed (presence or file list)'
    }
    return @{ Ok = ($fails.Count -eq 0); Fails = $fails; Warns = $warns }
}

function Get-TreeSnapshot([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return 'ABSENT' }
    $root = (Resolve-Path -LiteralPath $dir).Path.TrimEnd('\')
    $rows = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        $rows += ($f.FullName.Substring($root.Length) + '|' + [string]$f.Length)
    }
    return ('PRESENT:' + (($rows | Sort-Object) -join ';'))
}

# ---- ports
function Test-PortFree([int]$port) {
    $busy = @(netstat -ano | Where-Object { $_ -match ('[:\.]' + $port + '\s+\S+\s+LISTENING') })
    if ($busy.Count -gt 0) { return $false }
    try {
        $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $port
        $l.Start()
        $l.Stop()
        return $true
    } catch {
        return $false
    }
}

function Get-FreePorts([int]$n, [int[]]$avoid) {
    $got = @()
    foreach ($p in $script:PortCandidates) {
        if ($got.Count -ge $n) { break }
        if ($avoid -contains $p) { continue }
        if (Test-PortFree $p) { $got += $p }
    }
    if ($got.Count -lt $n) { throw ('not enough free ports in 18791..18799 (found ' + $got.Count + ')') }
    return $got
}

function Wait-PortFree([int]$port, [int]$sec) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $sec) {
        if (Test-PortFree $port) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Stop-Ours([int]$pid0) {
    if ($pid0 -le 0) { return }
    try { Stop-Process -Id $pid0 -Force -ErrorAction Stop } catch { }
    $script:Started = @($script:Started | Where-Object { $_ -ne $pid0 })
}

function Wait-FileText([string]$path, [string]$needle, [int]$sec, $proc) {
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt $sec) {
        if (Test-Path -LiteralPath $path) {
            if ((Read-Shared $path).Contains($needle)) { return $true }
        }
        if ($proc.HasExited) { return $false }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# ---- the counting proxy (written into the work folder; stdlib only)
$ProxyCode = @'
import json, socket, sys, threading, http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

LISTEN = int(sys.argv[1])
TARGET = int(sys.argv[2])
LOG = sys.argv[3]
MODE = {"down": False, "pull404": False, "pull_body": "none"}
COUNT = {"sync_requests": 0, "sync_replies_ok": 0, "sync_replies_err": 0, "dropped": 0}
LOCK = threading.Lock()


def log(line):
    with LOCK:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def _send(self, status, body, ctype="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _ctl(self, path):
        qs = parse_qs(urlsplit(path).query)
        with LOCK:
            if "down" in qs:
                MODE["down"] = qs["down"][0] == "1"
            if "pull404" in qs:
                MODE["pull404"] = qs["pull404"][0] == "1"
            if "pull_body" in qs:
                MODE["pull_body"] = qs["pull_body"][0]
            snap = dict(COUNT)
            snap["down"] = MODE["down"]
            snap["pull404"] = MODE["pull404"]
            snap["pull_body"] = MODE["pull_body"]
        self._send(200, json.dumps(snap).encode("utf-8"))

    def _fwd(self, method):
        path = self.path
        if path.startswith("/__ctl"):
            return self._ctl(path)
        short = path.split("?")[0]
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        is_sync = short.startswith("/sync/")
        if is_sync:
            with LOCK:
                COUNT["sync_requests"] += 1
        if MODE["down"]:
            with LOCK:
                COUNT["dropped"] += 1
            log("%s %s DROPPED" % (method, short))
            self.close_connection = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except Exception:
                pass
            return
        if is_sync and short == "/sync/pull" and MODE["pull404"]:
            log("%s %s 404 (injected)" % (method, short))
            return self._send(404, b'{"error":"not found"}')
        if is_sync and short == "/sync/pull" and MODE["pull_body"] != "none":
            payload = b'{"replicas":7}' if MODE["pull_body"] == "bad" else b"not json at all"
            log("%s %s 200 (injected body)" % (method, short))
            return self._send(200, payload)
        c = http.client.HTTPConnection("127.0.0.1", TARGET, timeout=120)
        hdr = {}
        for k, v in self.headers.items():
            if k.lower() in ("connection", "keep-alive", "proxy-connection", "transfer-encoding"):
                continue
            hdr[k] = v
        c.request(method, path, body=body, headers=hdr)
        r = c.getresponse()
        data = r.read()
        c.close()
        if is_sync:
            with LOCK:
                if r.status < 400:
                    COUNT["sync_replies_ok"] += 1
                else:
                    COUNT["sync_replies_err"] += 1
        log("%s %s %d" % (method, short, r.status))
        self.send_response(r.status)
        self.send_header("Content-Type", r.getheader("Content-Type", "application/json"))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._fwd("GET")

    def do_POST(self):
        self._fwd("POST")


ThreadingHTTPServer.daemon_threads = True
srv = ThreadingHTTPServer(("127.0.0.1", LISTEN), H)
print("PROXY_READY", LISTEN, flush=True)
srv.serve_forever()
'@

function Start-Hub([int]$port, [int]$lanPort, [string]$hubDir, [string]$runDir, [string]$stub) {
    New-Item -ItemType Directory -Force -Path $hubDir | Out-Null
    $out = Join-Path $runDir 'stub.out.txt'
    $err = Join-Path $runDir 'stub.err.txt'
    $devf = Join-Path $runDir 'devices.json'
    $argStr = '"' + $stub + '" --port ' + $port + ' --sync-dir "' + $hubDir + '" --devices-file "' + $devf + '" --lan-port ' + $lanPort + ' --lan-enabled --tag s4'
    $p = Start-Process -FilePath $Python -ArgumentList $argStr -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    $script:Started += $p.Id
    if (-not (Wait-FileText $out 'STUB_READY' 60 $p)) {
        Stop-Ours $p.Id
        throw ('stub hub did not start on port ' + $port)
    }
    return $p.Id
}

function Start-Proxy([int]$listen, [int]$target, [string]$logFile, [string]$proxyPy, [string]$runDir) {
    $out = Join-Path $runDir 'proxy.out.txt'
    $err = Join-Path $runDir 'proxy.err.txt'
    $argStr = '-I "' + $proxyPy + '" ' + $listen + ' ' + $target + ' "' + $logFile + '"'
    $p = Start-Process -FilePath $Python -ArgumentList $argStr -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    $script:Started += $p.Id
    if (-not (Wait-FileText $out 'PROXY_READY' 30 $p)) {
        Stop-Ours $p.Id
        throw ('proxy did not start on port ' + $listen)
    }
    return $p.Id
}

# ---- one Godot run (ProcessStartInfo: captured output, own environment, killed by PID only)
function Invoke-Godot([string]$godotSrc, [string]$scene, [string]$userArgs, [string]$appdataDir, [string]$runDir, [string]$tag) {
    $outF = Join-Path $runDir ($tag + '.stdout.txt')
    $errF = Join-Path $runDir ($tag + '.stderr.txt')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Godot
    $a = '--headless --path "' + $godotSrc + '" ' + $scene
    if ($userArgs -ne '') { $a = $a + ' -- ' + $userArgs }
    $psi.Arguments = $a
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['APPDATA'] = $appdataDir
    $psi.EnvironmentVariables['HOEHWA_SYNC_TEST_ROOT'] = $appdataDir
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $tOut = $p.StandardOutput.ReadToEndAsync()
    $tErr = $p.StandardError.ReadToEndAsync()
    $res = @{ TimedOut = $false; ExitCode = -999; Text = '' }
    if (-not $p.WaitForExit($RunTimeoutSec * 1000)) {
        $res.TimedOut = $true
        try { $p.Kill() } catch { }
        [void]$p.WaitForExit(15000)
    } else {
        [void]$p.WaitForExit()
        $res.ExitCode = [int]$p.ExitCode
    }
    [System.IO.File]::WriteAllText($outF, $tOut.Result, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($errF, $tErr.Result, (New-Object System.Text.UTF8Encoding($false)))
    $res.Text = (Read-Utf8 $outF) + "`n" + (Read-Utf8 $errF)
    return $res
}

function Parse-Suite($run, [string]$resultName) {
    $t = [string]$run.Text
    $checks = @()
    foreach ($ln in ($t -split "`r?`n")) {
        if ($ln -match '^\s*(PASS|FAIL|SKIP)\s+\[([^\]]+)\]\s*(.*)$') {
            $checks += ,@($matches[1], $matches[2], $matches[3])
        }
    }
    $sum = $null
    $pat = '== ' + $resultName + ' result: (\d+) passed, (\d+) failed =='
    if ($t -match $pat) { $sum = @([int]$matches[1], [int]$matches[2]) }
    $broken = [bool]($t -match 'Parse Error|Compile Error|Failed to load script|Failed to compile|SCRIPT ERROR')
    $guard = [bool]($t -match 'GUARD:|missing arguments')
    return @{ Checks = $checks; Sum = $sum; Broken = $broken; Guard = $guard; ExitCode = $run.ExitCode; TimedOut = $run.TimedOut }
}

function Get-Ids($parsed, [string]$kind) {
    $h = @{}
    foreach ($c in $parsed.Checks) {
        if ($c[0] -eq $kind) { $h[$c[1]] = $true }
    }
    return $h
}

# ---- one roundtrip run, with its own stub, proxy and folders
function Invoke-Suite([string]$godotSrc, [string]$suite, [string]$runDir, [string]$appdataDir) {
    New-Item -ItemType Directory -Force -Path $runDir, $appdataDir | Out-Null
    $proxyPy = Join-Path $runDir 'proxy_s4.py'
    if (-not (Test-Path -LiteralPath $proxyPy)) { Write-Utf8 $proxyPy $ProxyCode }
    $hubDir = Join-Path $runDir 'hub'
    if (Test-Path -LiteralPath $hubDir) { Remove-Item -LiteralPath $hubDir -Recurse -Force }
    $ports = Get-FreePorts 3 @()
    $hubPort = $ports[0]
    $proxyPort = $ports[1]
    $lanPort = $ports[2]
    $stubPid = 0
    $proxyPid = 0
    $run = $null
    try {
        $stubPid = Start-Hub $hubPort $lanPort $hubDir $runDir $stubScript
        $logF = Join-Path $runDir 'proxy_req.log'
        if (Test-Path -LiteralPath $logF) { Remove-Item -LiteralPath $logF -Force }
        $proxyPid = Start-Proxy $proxyPort $hubPort $logF $proxyPy $runDir
        $base = 'http://127.0.0.1:' + $proxyPort
        $userArgs = ''
        $scene = 'res://tests/sync_engine_test.tscn'
        if ($suite -eq 'roundtrip') {
            $scene = 'res://tests/sync_roundtrip_test.tscn'
            $userArgs = '--proxy=' + $base + ' --ctl=' + $base + ' --stub=http://127.0.0.1:' + $hubPort + ' --lan=http://127.0.0.1:' + $lanPort + ' --hub-dir="' + $hubDir + '"'
        }
        $run = Invoke-Godot $godotSrc $scene $userArgs $appdataDir $runDir $suite
        $resName = 'sync_engine'
        if ($suite -eq 'roundtrip') { $resName = 'sync_roundtrip' }
        $parsed = Parse-Suite $run $resName
        $parsed['Suite'] = $suite
        $parsed['Hub'] = [string]$hubPort
        $parsed['Lan'] = [string]$lanPort
        $parsed['Proxy'] = [string]$proxyPort
        $parsed['HubPid'] = $stubPid
        $parsed['ProxyPid'] = $proxyPid
        return $parsed
    } finally {
        Stop-Ours $proxyPid
        Stop-Ours $stubPid
        foreach ($pp in @($hubPort, $proxyPort, $lanPort)) {
            if (-not (Wait-PortFree $pp 15)) { Say ('WARNING: port ' + $pp + ' still busy after stop') }
        }
    }
}

# ---------------------------------------------------------------- self test of the comparison (no Godot, no real folder)
# -SelfTest: fake snapshots (wrong input must FAIL) and a scratch folder run through the real Get-UserSnapshot.

function New-FakeBase {
    return @{ Present = $true; Files = @{ 'prefs.json' = 'AAA'; 'progress.json' = 'BBB'; 'remote.json' = 'ABSENT'; 'curriculum.json' = 'CCC'; 'sync_state.json' = 'ABSENT'; 'studylog.json' = 'PRESENT' }; Soft = @{ 'studylog.json' = 'S1' }; Backup = 'ABSENT' }
}

function Invoke-SelfTest {
    $script:stPass = 0
    $script:stFail = 0
    $root = if ($Work -ne '') { Join-Path $Work 'selftest' } else { Join-Path $env:TEMP 'hoehwa_sync_selftest' }
    Say ('self test of the real-user-folder comparison; scratch folder: ' + $root)

    # fake snapshots: each case changes one thing of a base snapshot
    $b = New-FakeBase
    $r = Compare-UserSnapshot $b (New-FakeBase)
    Say ('  ' + $(if ($r.Ok) { 'PASS' } else { 'FAIL' }) + '  [SELF-1] identical snapshots -> unchanged'); if ($r.Ok) { $script:stPass++ } else { $script:stFail++ }

    $cases = @(
        @{ id = 'SELF-2'; label = 'prefs.json md5 differs -> FAIL'; mod = { param($s) $s.Files['prefs.json'] = 'XXX' }; ok = $false },
        @{ id = 'SELF-3'; label = 'progress.json removed -> FAIL'; mod = { param($s) $s.Files['progress.json'] = 'ABSENT' }; ok = $false },
        @{ id = 'SELF-4'; label = 'remote.json appears -> FAIL'; mod = { param($s) $s.Files['remote.json'] = 'HHH' }; ok = $false },
        @{ id = 'SELF-5'; label = 'sync_state.json appears -> FAIL'; mod = { param($s) $s.Files['sync_state.json'] = 'SSS' }; ok = $false },
        @{ id = 'SELF-6'; label = 'curriculum.json md5 differs -> FAIL'; mod = { param($s) $s.Files['curriculum.json'] = 'DDD' }; ok = $false },
        @{ id = 'SELF-7'; label = 'sync_backup folder appears -> FAIL'; mod = { param($s) $s.Backup = 'PRESENT:first|0' }; ok = $false },
        @{ id = 'SELF-8'; label = 'studylog.json content differs -> warning only, OK'; mod = { param($s) $s.Soft['studylog.json'] = 'S2' }; ok = $true },
        @{ id = 'SELF-9'; label = 'studylog.json removed -> FAIL'; mod = { param($s) $s.Files['studylog.json'] = 'ABSENT' }; ok = $false }
    )
    foreach ($c in $cases) {
        $after = New-FakeBase
        & $c.mod $after
        $res = Compare-UserSnapshot $b $after
        $good = ($res.Ok -eq $c.ok)
        if ($c.id -eq 'SELF-8') {
            $good = $good -and (@($res.Warns).Count -eq 1)
        } else {
            $good = $good -and (@($res.Fails).Count -ge 1)
        }
        Say ('  ' + $(if ($good) { 'PASS' } else { 'FAIL' }) + '  [' + $c.id + '] ' + $c.label + ' (ok=' + [string]$res.Ok + ', fails=' + $res.Fails.Count + ', warns=' + $res.Warns.Count + ')')
        if ($good) { $script:stPass++ } else { $script:stFail++ }
    }

    # scratch folder through the real function: test_* files, logs, shader_cache and other folders must be ignored
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    Write-Utf8 (Join-Path $root 'prefs.json') '{"a":1}'
    Write-Utf8 (Join-Path $root 'progress.json') '{"b":2}'
    Write-Utf8 (Join-Path $root 'studylog.json') '{"c":3}'
    $s1 = Get-UserSnapshot $root
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'test_guard'), (Join-Path $root 'logs'), (Join-Path $root 'shader_cache') | Out-Null
    Write-Utf8 (Join-Path $root 'test_touch_studylog.json') '{}'
    Write-Utf8 (Join-Path $root 'test_guard\prefs.json') '{}'
    Write-Utf8 (Join-Path $root 'logs\godot.log') 'x'
    Write-Utf8 (Join-Path $root 'shader_cache\s.bin') 'y'
    $s2 = Get-UserSnapshot $root
    $r10 = Compare-UserSnapshot $s1 $s2
    Say ('  ' + $(if ($r10.Ok) { 'PASS' } else { 'FAIL' }) + '  [SELF-10] test_* files, test_guard, logs and shader_cache are ignored'); if ($r10.Ok) { $script:stPass++ } else { $script:stFail++ }
    Write-Utf8 (Join-Path $root 'prefs.json') '{"a":999}'
    $s3 = Get-UserSnapshot $root
    $r11 = Compare-UserSnapshot $s1 $s3
    $g11 = (-not $r11.Ok) -and ($r11.Fails | Where-Object { $_ -like 'prefs.json*' }).Count -eq 1
    Say ('  ' + $(if ($g11) { 'PASS' } else { 'FAIL' }) + '  [SELF-11] scratch prefs.json rewritten -> FAIL (real function, real files)'); if ($g11) { $script:stPass++ } else { $script:stFail++ }
    Write-Utf8 (Join-Path $root 'studylog.json') '{"c":4}'
    $s4 = Get-UserSnapshot $root
    $r12 = Compare-UserSnapshot $s3 $s4
    $g12 = $r12.Ok -and $r12.Warns.Count -eq 1
    Say ('  ' + $(if ($g12) { 'PASS' } else { 'FAIL' }) + '  [SELF-12] scratch studylog.json rewritten -> warning only'); if ($g12) { $script:stPass++ } else { $script:stFail++ }
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'sync_backup') | Out-Null
    $s5 = Get-UserSnapshot $root
    $r13 = Compare-UserSnapshot $s4 $s5
    $g13 = (-not $r13.Ok) -and ($r13.Fails | Where-Object { $_ -like 'sync_backup*' }).Count -eq 1
    Say ('  ' + $(if ($g13) { 'PASS' } else { 'FAIL' }) + '  [SELF-13] scratch sync_backup folder appears -> FAIL'); if ($g13) { $script:stPass++ } else { $script:stFail++ }
    Remove-Item -LiteralPath $root -Recurse -Force

    $ok = ($script:stFail -eq 0)
    Write-Output ('SYNC_SELFTEST_RESULT ' + $(if ($ok) { 'PASS ' } else { 'FAIL ' }) + [string]$script:stPass + '/' + [string]($script:stPass + $script:stFail))
    $script:SelfTestCode = $(if ($ok) { 0 } else { 1 })
}

if ($SelfTest) {
    Invoke-SelfTest
    exit $script:SelfTestCode
}

# ---------------------------------------------------------------- main

$appdataReal = $env:APPDATA
$exitCode = 1
$finalLine = 'SYNC_E2E_RESULT FAIL'
try {
    $testsDir = $PSScriptRoot
    $godotSrc = Split-Path -Parent $testsDir
    $appRoot = Split-Path -Parent $godotSrc
    $backendDir = Join-Path $appRoot 'backend'
    $script:stubScript = Join-Path $backendDir 'lan_stub_server.py'
    if ($Python -eq '') { $Python = Join-Path $backendDir '.venv\Scripts\python.exe' }
    if (-not (Test-Path -LiteralPath $Godot)) { throw 'Godot not found' }
    if (-not (Test-Path -LiteralPath $Python)) { throw 'backend venv python not found' }
    if (-not (Test-Path -LiteralPath $script:stubScript)) { throw 'lan_stub_server.py not found' }
    if (-not (Test-Path -LiteralPath (Join-Path $godotSrc 'project.godot'))) { throw 'project.godot not found' }
    if ($Work -eq '') { $Work = Join-Path $env:TEMP ('hoehwa_sync_s4_' + (Get-Date -Format 'yyyyMMddHHmmss')) }
    $Work = [System.IO.Path]::GetFullPath($Work)
    if ($Work.StartsWith($godotSrc, [System.StringComparison]::OrdinalIgnoreCase) -or $Work.StartsWith($appRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'the work folder must be outside the project'
    }
    New-Item -ItemType Directory -Force -Path $Work | Out-Null

    # the real folders before the run
    $realDir = Get-RealUserDir $appdataReal
    $userBefore = Get-UserSnapshot $realDir
    $dataSync = Join-Path $backendDir 'data\sync'
    $syncBefore = Get-TreeSnapshot $dataSync
    $godotMd5Before = Get-Md5 (Join-Path $godotSrc 'project.godot')

    $required = @{
        'sync_engine' = @('E-U1', 'E-U2', 'E-U3', 'E-U4', 'E-J1', 'E-J2', 'E-J3', 'E-R1', 'E-R2', 'E-C1', 'E-C2', 'E-H1', 'E-H2', 'E-B1', 'E-B2', 'E-S1', 'E-S2', 'E-S3', 'E-S4', 'E-S5', 'E-S6', 'E-F1');
        'sync_roundtrip' = @('E-RT1', 'E-RT2', 'E-RT3', 'E-RT4', 'E-RT5', 'E-RT6', 'E-RT7', 'E-RT8', 'E-RT9', 'E-RT11', 'E-RT12', 'E-C1')
    }

    if (-not $Mutations) {
        $run = Join-Path $Work 'run'
        $appd = Join-Path $run 'appdata'
        $results = @{}
        foreach ($suite in @('engine', 'roundtrip')) {
            $sdir = Join-Path $run $suite
            $r = Invoke-Suite $godotSrc $suite $sdir $appd
            $results[$suite] = $r
            $rname = 'sync_engine'
            if ($suite -eq 'roundtrip') { $rname = 'sync_roundtrip' }
            Say ('[' + $suite + '] exit=' + $r.ExitCode + ' timeout=' + $r.TimedOut + ' hub=' + $r.Hub + ' proxy=' + $r.Proxy + ' lan=' + $r.Lan + ' summary=' + $(if ($r.Sum) { $r.Sum[0].ToString() + ' passed, ' + $r.Sum[1].ToString() + ' failed' } else { 'NONE' }) + ' broken=' + $r.Broken)
            foreach ($c in $r.Checks) {
                if ($c[0] -eq 'FAIL' -or $c[0] -eq 'SKIP') { Say ('  ' + $c[0] + ' [' + $c[1] + '] ' + $c[2]) }
            }
            $rk = $rname
            if ($r.Sum -eq $null -or $r.Sum[1] -ne 0 -or $r.Broken -or $r.Guard -or $r.TimedOut -or $r.ExitCode -ne 0 -or $r.Sum[0] -le 0) {
                $script:Overall = $false
                Say ('  NOT CLEAN: ' + $suite)
            }
            $ids = Get-Ids $r 'PASS'
            $fails = Get-Ids $r 'FAIL'
            $skips = Get-Ids $r 'SKIP'
            foreach ($need in $required[$rk]) {
                if (-not $ids.ContainsKey($need) -or $fails.ContainsKey($need) -or $skips.ContainsKey($need)) {
                    $script:Overall = $false
                    Say ('  REQUIRED CHECK NOT PASSED: [' + $need + '] in ' + $suite)
                }
            }
            $allReq = @($required[$rk])
            Say ('  required in ' + $suite + ': ' + ($allReq -join ' '))
        }
        # the skipped items of the engine suite are reported as unverified (none expected now)
        $skipIds = @()
        foreach ($k in $results.Keys) {
            foreach ($c in $results[$k].Checks) { if ($c[0] -eq 'SKIP') { $skipIds += $c[1] } }
        }
        if ($skipIds.Count -gt 0) { Say ('UNVERIFIED: ' + ($skipIds -join ' ')) }

        # E-RT10 / E-S: real folders unchanged
        $userAfter = Get-UserSnapshot $realDir
        $syncAfter = Get-TreeSnapshot $dataSync
        $cmpUser = Compare-UserSnapshot $userBefore $userAfter
        $userSame = $cmpUser.Ok
        $syncSame = ($syncBefore -eq $syncAfter)
        Say ('[E-RT10] real user app files unchanged (prefs, progress, remote, curriculum, sync_state, sync_backup, studylog presence): ' + $userSame)
        foreach ($f in $cmpUser.Fails) { Say ('  FAIL: ' + $f) }
        foreach ($w in $cmpUser.Warns) { Say ('  WARNING (not a failure): ' + $w) }
        # isolation proof: the Godot runs of this runner used the scratch APPDATA (their user folder is there)
        $isoDir = Join-Path $Work 'run\appdata\Godot\app_userdata'
        $isoOk = (Test-Path -LiteralPath $isoDir)
        Say ('[E-RT10] runs used the scratch user folder: ' + $isoOk)
        if (-not $isoOk) { $script:Overall = $false }
        Say ('[E-RT10] backend\data\sync unchanged: ' + $syncSame + ' (' + $(if ($syncBefore -eq 'ABSENT') { 'absent before' } else { 'present before' }) + ')')
        if (-not $userSame -or -not $syncSame) { $script:Overall = $false }
        $godotMd5After = Get-Md5 (Join-Path $godotSrc 'project.godot')
        if ($godotMd5Before -ne $godotMd5After) { $script:Overall = $false; Say 'project.godot changed during the run' }
        if ($script:Overall) {
            Say 'ALL CHECKS PASSED'
        }
        $finalLine = $(if ($script:Overall) { 'SYNC_E2E_RESULT PASS' } else { 'SYNC_E2E_RESULT FAIL' })
        $exitCode = $(if ($script:Overall) { 0 } else { 1 })
    } else {
        # ----- mutation sweep on a copy
        $mutJson = Get-Content -LiteralPath (Join-Path $testsDir 'sync_engine_mutations.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $muts = @($mutJson.mutations)
        if ($muts.Count -eq 0) { throw 'no mutations' }
        $proj = Join-Path $Work 'mut_proj'
        if (Test-Path -LiteralPath $proj) { Remove-Item -LiteralPath $proj -Recurse -Force }
        & robocopy.exe $godotSrc $proj /E /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw ('robocopy failed: ' + $LASTEXITCODE) }
        $target = Join-Path $proj 'scripts\sync\sync_engine.gd'
        $pristine = Read-Utf8 $target
        if ((Get-Md5 $target) -ne (Get-Md5 (Join-Path $godotSrc 'scripts\sync\sync_engine.gd'))) { throw 'copy differs from original' }
        $appd = Join-Path $Work 'mut_appdata'
        $origMd5 = Get-Md5 (Join-Path $godotSrc 'scripts\sync\sync_engine.gd')

        # baseline: the copy must be clean without any mutation
        $base1 = Invoke-Suite $proj 'engine' (Join-Path $Work 'mut_base_engine') $appd
        $base2 = Invoke-Suite $proj 'roundtrip' (Join-Path $Work 'mut_base_rt') $appd
        $baseClean = $true
        foreach ($b in @($base1, $base2)) {
            if ($b.Sum -eq $null -or $b.Sum[1] -ne 0 -or $b.Broken -or $b.TimedOut -or $b.ExitCode -ne 0) { $baseClean = $false }
        }
        Say ('BASELINE: ' + $(if ($baseClean) { 'CLEAN' } else { 'NOT CLEAN' }) + ' engine=' + $(if ($base1.Sum) { $base1.Sum[0].ToString() + '/' + $base1.Sum[1].ToString() } else { 'none' }) + ' roundtrip=' + $(if ($base2.Sum) { $base2.Sum[0].ToString() + '/' + $base2.Sum[1].ToString() } else { 'none' }))
        if (-not $baseClean) { throw 'baseline (no mutation) is not clean; mutations not run' }

        $detected = 0
        $n = 0
        foreach ($m in $muts) {
            $n++
            $id = [string]$m.id
            $find = [string]$m.find
            $repl = [string]$m.replace
            $nl = $(if ($pristine.Contains("`r`n")) { "`r`n" } else { "`n" })
            $find = $find.Replace("`n", $nl)
            $repl = $repl.Replace("`n", $nl)
            $suite = [string]$m.suite
            $expect = @($m.expect_fail | ForEach-Object { [string]$_ })
            $occ = Count-Occ $pristine $find
            if ($occ -ne 1) {
                Say ($id + ' BAD_FIND occurrences=' + $occ)
                continue
            }
            Write-Utf8 $target ($pristine.Replace($find, $repl))
            try {
                $r = Invoke-Suite $proj $suite (Join-Path $Work ('mut_' + $id)) $appd
            } finally {
                Write-Utf8 $target $pristine
            }
            $fails = Get-Ids $r 'FAIL'
            $missing = @()
            foreach ($e in $expect) { if (-not $fails.ContainsKey($e)) { $missing += $e } }
            $allFails = @($fails.Keys | Sort-Object)
            if ($missing.Count -eq 0 -and -not $r.Broken) {
                $detected++
                Say ($id + ' DETECTED by ' + ($expect -join ',') + ' (suite ' + $suite + '; all FAIL: ' + ($allFails -join ' ') + ')')
            } else {
                $why = ''
                if ($r.Broken) { $why = ' suite did not run cleanly (script error)' }
                Say ($id + ' MISSED expected ' + ($missing -join ',') + ' (suite ' + $suite + '; FAIL: ' + ($allFails -join ' ') + ')' + $why)
            }
        }
        $origAfter = Get-Md5 (Join-Path $godotSrc 'scripts\sync\sync_engine.gd')
        Say ('original sync_engine.gd md5 unchanged: ' + ($origMd5 -eq $origAfter))
        if ($origMd5 -ne $origAfter) { throw 'original sync_engine.gd changed' }
        $userAfter = Get-UserSnapshot $realDir
        Say ('real user folder unchanged: ' + (Compare-UserSnapshot $userBefore $userAfter).Ok)
        $finalMut = 'SYNC_MUT_RESULT ' + $(if ($detected -eq $n) { 'PASS ' } else { 'FAIL ' }) + [string]$detected + '/' + [string]$n
        $finalLine = $finalMut
        $exitCode = $(if ($detected -eq $n) { 0 } else { 1 })
    }
} catch {
    Say ('RUNNER ERROR at line ' + [string]$_.InvocationInfo.ScriptLineNumber + ': ' + $_.Exception.Message)
    $finalLine = $(if ($Mutations) { 'SYNC_MUT_RESULT FAIL 0/0' } else { 'SYNC_E2E_RESULT FAIL' })
    $exitCode = 1
} finally {
    foreach ($pid0 in @($script:Started)) { Stop-Ours $pid0 }
}
Write-Output $finalLine
exit $exitCode
