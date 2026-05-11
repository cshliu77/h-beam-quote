# Shared helpers + 變數 — 被 deploy-service.ps1 / deploy-agent.ps1 / lab-bootstrap.ps1 dot-source
# 用法: . "$PSScriptRoot\_lib.ps1"

# ─────────────────────────────────────────────────────────
# 必要 env 檢查
# ─────────────────────────────────────────────────────────
if (-not $env:GCP_PROJECT) {
    Write-Host "ERROR: 需要設 GCP_PROJECT 環境變數" -ForegroundColor Red
    Write-Host "  例: `$env:GCP_PROJECT = 'your-project-id'" -ForegroundColor DarkGray
    exit 1
}

# ─────────────────────────────────────────────────────────
# 變數預設值(env override 友善)
# ─────────────────────────────────────────────────────────
$GcpProject     = $env:GCP_PROJECT
$GcpRegion      = if ($env:GCP_REGION)       { $env:GCP_REGION }       else { 'asia-east1' }
$QuoteService   = if ($env:QUOTE_SERVICE)    { $env:QUOTE_SERVICE }    else { 'h-beam-quote' }
$QuoteRepo      = if ($env:QUOTE_REPO)       { $env:QUOTE_REPO }       else { 'h-beam-images' }
$GhcrProxyRepo  = if ($env:GHCR_PROXY_REPO)  { $env:GHCR_PROXY_REPO }  else { 'h-beam-ghcr-proxy' }
$AgentSaName    = if ($env:AGENT_SA_NAME)    { $env:AGENT_SA_NAME }    else { 'h-beam-agent' }
$AgentSaEmail   = "${AgentSaName}@${GcpProject}.iam.gserviceaccount.com"

$HBeamImage     = if ($env:H_BEAM_IMAGE) { $env:H_BEAM_IMAGE } else { 'ghcr.io/cshliu77/h-beam-quote:latest' }
$BuildLocal     = if ($env:BUILD_LOCAL)  { $env:BUILD_LOCAL }  else { 'false' }

$ArImageUri     = "${GcpRegion}-docker.pkg.dev/${GcpProject}/${QuoteRepo}/${QuoteService}:latest"
if ($BuildLocal -eq 'true') {
    $DeployImage = $ArImageUri
} else {
    if (-not $HBeamImage.StartsWith('ghcr.io/')) {
        Write-Host "ERROR: H_BEAM_IMAGE 必須以 ghcr.io/ 開頭(BUILD_LOCAL=false 模式): $HBeamImage" -ForegroundColor Red
        exit 1
    }
    $GhcrPath = $HBeamImage.Substring('ghcr.io/'.Length)
    $DeployImage = "${GcpRegion}-docker.pkg.dev/${GcpProject}/${GhcrProxyRepo}/${GhcrPath}"
}

# 路徑(以 scripts/ 的父層為 repo root)
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$QuoteDir = $RepoRoot
$AgentDir = Join-Path $RepoRoot 'agent'

# ─────────────────────────────────────────────────────────
# 顯示工具(色彩 — PowerShell 內建 Write-Host -ForegroundColor)
# ─────────────────────────────────────────────────────────
function Write-Step { param([string]$msg) Write-Host "`n▶ $msg" -ForegroundColor Blue }
function Write-Ok   { param([string]$msg) Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "⚠ $msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$msg) Write-Host "✗ $msg" -ForegroundColor Red }
function Write-Dim  { param([string]$msg) Write-Host "  $msg" -ForegroundColor DarkGray }

# ─────────────────────────────────────────────────────────
# 工具偵測(PowerShell 跨平台,但 Windows 上 'python' 不一定是 python3)
# ─────────────────────────────────────────────────────────
function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# 找 python:Windows 預設 `python`,Mac/Linux 通常 `python3`
$PythonCmd = $null
foreach ($candidate in @('python3', 'python', 'py')) {
    if (Test-Command $candidate) { $PythonCmd = $candidate; break }
}

# ─────────────────────────────────────────────────────────
# 共用 preflight:gcloud + project 可見
# ─────────────────────────────────────────────────────────
function Invoke-Preflight {
    Write-Step "[Preflight] gcloud + GCP 專案"
    if (-not (Test-Command 'gcloud')) {
        Write-Err "缺工具:gcloud(到 https://cloud.google.com/sdk/docs/install 安裝)"
        exit 1
    }
    $null = gcloud projects describe $GcpProject 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Err "看不到 GCP 專案 $GcpProject — 用 gcloud projects list 確認 Project ID"
        Write-Dim "注意:GCP_PROJECT 是 Project ID(小寫+連字號),不是 Display Name"
        exit 1
    }
    Write-Ok "專案可見:$GcpProject"
    $null = gcloud config set project $GcpProject 2>$null
    $null = gcloud auth application-default set-quota-project $GcpProject 2>$null
    Write-Ok "current project / ADC quota project = $GcpProject"
}
