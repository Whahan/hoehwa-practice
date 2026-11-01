# Idempotent setup for the speaking-practice backend. Safe to re-run.
#   powershell -ExecutionPolicy Bypass -File setup.ps1
# Creates .venv, installs packages, downloads models into .\models\hf and records the working STT device in config.json.
# (The AI is the free DeepSeek through OpenCode: connect it inside the app with the AI connect button. No local model is installed.)
param(
    [string]$Python = "C:\Users\rtyu6\AppData\Local\Programs\Python\Python310\python.exe"
)
$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
Set-Location $Root
$Venv = Join-Path $Root ".venv"
$VPy = Join-Path $Venv "Scripts\python.exe"
$Cfg = Join-Path $Root "config.json"

# Nothing may be downloaded into the user profile
$env:HF_HOME = Join-Path $Root "models\hf"
$env:HF_HUB_CACHE = $env:HF_HOME
$env:HF_HUB_DISABLE_SYMLINKS_WARNING = "1"
$env:PYTHONUTF8 = "1"
$env:PIP_CACHE_DIR = Join-Path $Root "models\pip-cache"
New-Item -ItemType Directory -Force $env:HF_HOME, (Join-Path $Root "logs") | Out-Null

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Run-Native($exe, $argList) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & $exe @argList
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0) { throw "failed: $exe $($argList -join ' ') (exit $code)" }
}
function Test-Py($code) {
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & $VPy -c $code *> $null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $old
    return $ok
}
function Read-Cfg {
    if (Test-Path $Cfg) { return (Get-Content $Cfg -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return $null
}
function Write-Cfg($obj) {
    $json = $obj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Cfg, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# --- 1. venv -----------------------------------------------------------------------------------
Step "Python venv"
if (-not (Test-Path $VPy)) {
    if (-not (Test-Path $Python)) { throw "Python not found at $Python (use -Python <path>)" }
    Run-Native $Python @("-m", "venv", $Venv)
}
Run-Native $VPy @("-m", "pip", "install", "--upgrade", "pip", "--quiet")

# --- 2. packages ---------------------------------------------------------------------------------
Step "PyTorch (CPU build; Kokoro-82M is fast on CPU and VRAM is left to the LLM)"
if (-not (Test-Py "import torch")) {
    Run-Native $VPy @("-m", "pip", "install", "torch", "--index-url", "https://download.pytorch.org/whl/cpu")
} else { Write-Host "torch already installed" }

Step "Python packages (requirements.txt)"
Run-Native $VPy @("-m", "pip", "install", "-r", (Join-Path $Root "requirements.txt"))

Step "spaCy English model (used by Kokoro's English G2P)"
if (-not (Test-Py "import en_core_web_sm")) {
    Run-Native $VPy @("-m", "pip", "install", "https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl")
} else { Write-Host "en_core_web_sm already installed" }

# --- 3. config.json ----------------------------------------------------------------------------
Step "config.json"
if (-not (Test-Path $Cfg)) {
    $default = [ordered]@{
        port = 8770
        llm_provider = "opencode"
        stt = [ordered]@{ model = "small"; device = "cuda"; compute_type = "int8_float16" }
        tts = [ordered]@{ voice_en = "af_heart"; voice_ja = "jf_alpha"; device = "cpu" }
    }
    Write-Cfg $default
    Write-Host "created config.json"
} else { Write-Host "config.json exists" }

# --- 4. speech models (Whisper small, Kokoro-82M + voices) and STT device check ---------------------
Step "Whisper / Kokoro / pyopenjtalk (downloads into models\hf, picks CUDA or CPU)"
Run-Native $VPy @((Join-Path $Root "server.py"), "--prefetch")

# pip's download cache is not needed afterwards
if (Test-Path $env:PIP_CACHE_DIR) { Remove-Item -Recurse -Force $env:PIP_CACHE_DIR -ErrorAction SilentlyContinue }

Step "Done"
$c = Read-Cfg
Write-Host ("STT device: {0}/{1}   port: {2}" -f $c.stt.device, $c.stt.compute_type, $c.port) -ForegroundColor Green
Write-Host "Start the server with run_backend.bat"
