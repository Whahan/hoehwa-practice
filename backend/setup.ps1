# Idempotent setup for the speaking-practice backend. Safe to re-run.
#   powershell -ExecutionPolicy Bypass -File setup.ps1
# Creates .venv, installs packages, downloads models into .\models\hf, pulls the Ollama LLM and
# records the working STT device / LLM tag in config.json.
param(
    [string]$Python = "C:\Users\rtyu6\AppData\Local\Programs\Python\Python310\python.exe",
    [string[]]$LlmTags = @("qwen3:8b", "qwen2.5:7b")
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
        llm_model = $LlmTags[0]
        ollama_url = "http://127.0.0.1:11434"
        keep_alive = "30m"
        num_ctx = 6144
        stt = [ordered]@{ model = "small"; device = "cuda"; compute_type = "int8_float16" }
        tts = [ordered]@{ voice_en = "af_heart"; voice_ja = "jf_alpha"; device = "cpu" }
    }
    Write-Cfg $default
    Write-Host "created config.json"
} else { Write-Host "config.json exists" }

# --- 4. Ollama LLM -------------------------------------------------------------------------------
Step "Ollama model"
$ollama = (Get-Command ollama -ErrorAction SilentlyContinue).Source
if (-not $ollama) { $ollama = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe" }
if (-not (Test-Path $ollama)) { throw "Ollama not found. Install it first: winget install Ollama.Ollama" }
# make sure the Ollama service answers
$up = $false
try { Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 3 | Out-Null; $up = $true } catch {}
if (-not $up) {
    Write-Host "starting ollama serve ..."
    Start-Process -FilePath $ollama -ArgumentList "serve" -WindowStyle Hidden
    for ($i = 0; $i -lt 30 -and -not $up; $i++) {
        Start-Sleep -Seconds 1
        try { Invoke-RestMethod "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 | Out-Null; $up = $true } catch {}
    }
}
if (-not $up) { throw "Ollama server is not reachable on 127.0.0.1:11434" }
$have = (Invoke-RestMethod "http://127.0.0.1:11434/api/tags").models | ForEach-Object { $_.name }
$chosen = $null
foreach ($tag in $LlmTags) {
    if ($have -contains $tag) { $chosen = $tag; Write-Host "$tag already pulled"; break }
    Write-Host "ollama pull $tag"
    & $ollama pull $tag
    if ($LASTEXITCODE -eq 0) { $chosen = $tag; break }
    Write-Host "pull of $tag failed, trying next" -ForegroundColor Yellow
}
if (-not $chosen) { throw "no LLM tag could be pulled" }
$c = Read-Cfg
$c.llm_model = $chosen
Write-Cfg $c
Write-Host "LLM tag: $chosen"

# --- 5. speech models (Whisper small, Kokoro-82M + voices) and STT device check ---------------------
Step "Whisper / Kokoro / pyopenjtalk (downloads into models\hf, picks CUDA or CPU)"
Run-Native $VPy @((Join-Path $Root "server.py"), "--prefetch")

# pip's download cache is not needed afterwards
if (Test-Path $env:PIP_CACHE_DIR) { Remove-Item -Recurse -Force $env:PIP_CACHE_DIR -ErrorAction SilentlyContinue }

Step "Done"
$c = Read-Cfg
Write-Host ("STT device: {0}/{1}   LLM: {2}   port: {3}" -f $c.stt.device, $c.stt.compute_type, $c.llm_model, $c.port) -ForegroundColor Green
Write-Host "Start the server with run_backend.bat"
