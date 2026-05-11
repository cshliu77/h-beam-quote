# H-Beam Lab — 看部署現況(PowerShell 版)
#
# 用法:
#   $env:GCP_PROJECT = 'your-project-id'
#   .\scripts\lab-status.ps1

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_lib.ps1"

function Write-Pass { param([string]$msg) Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Miss { param([string]$msg) Write-Host "  ✗ $msg" -ForegroundColor Red }
function Write-Section { param([string]$msg) Write-Host "`n■ $msg" -ForegroundColor Blue }

Write-Host "Project: $GcpProject   Region: $GcpRegion" -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────
# API 啟用狀態
# ─────────────────────────────────────────────────────────
Write-Section "API 啟用狀態"
$enabled = gcloud services list --enabled --project=$GcpProject --format='value(config.name)' 2>$null
$apis = @(
    'run.googleapis.com', 'cloudbuild.googleapis.com', 'artifactregistry.googleapis.com',
    'aiplatform.googleapis.com', 'cloudtrace.googleapis.com', 'logging.googleapis.com',
    'monitoring.googleapis.com', 'telemetry.googleapis.com'
)
foreach ($api in $apis) {
    if ($enabled -match "^$([regex]::Escape($api))$") {
        Write-Pass $api
    } else {
        Write-Miss "$api (尚未啟用)"
    }
}

# ─────────────────────────────────────────────────────────
# Service Account + IAM
# ─────────────────────────────────────────────────────────
Write-Section "Agent Service Account"
$null = gcloud iam service-accounts describe $AgentSaEmail --project=$GcpProject 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass $AgentSaEmail
    $policy = gcloud projects get-iam-policy $GcpProject --format=json 2>$null | ConvertFrom-Json
    $roles = @(
        'roles/cloudtrace.agent', 'roles/logging.logWriter',
        'roles/monitoring.metricWriter', 'roles/serviceusage.serviceUsageConsumer',
        'roles/aiplatform.user'
    )
    foreach ($role in $roles) {
        $bound = $policy.bindings | Where-Object {
            $_.role -eq $role -and $_.members -contains "serviceAccount:$AgentSaEmail"
        }
        if ($bound) { Write-Pass "  bound: $role" } else { Write-Miss "  missing: $role" }
    }
} else {
    Write-Miss "Service Account 不存在"
}

# ─────────────────────────────────────────────────────────
# Image Source(GHCR proxy 或 AR standard)
# ─────────────────────────────────────────────────────────
Write-Section "Image Source"
$null = gcloud artifacts repositories describe $QuoteRepo `
    --location=$GcpRegion --project=$GcpProject 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Pass "AR standard repo: $QuoteRepo @ $GcpRegion (BUILD_LOCAL=true 模式)"
} else {
    $null = gcloud artifacts repositories describe $GhcrProxyRepo `
        --location=$GcpRegion --project=$GcpProject 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "AR GHCR proxy repo: $GhcrProxyRepo @ $GcpRegion (預設 BUILD_LOCAL=false 模式)"
    } else {
        Write-Miss "AR repo 都不存在"
    }
}

# ─────────────────────────────────────────────────────────
# Cloud Run
# ─────────────────────────────────────────────────────────
Write-Section "Cloud Run Quote Service"
$url = gcloud run services describe $QuoteService `
    --region=$GcpRegion --project=$GcpProject `
    --format='value(status.url)' 2>$null
if ($url) {
    Write-Pass $url
    $deployedImage = gcloud run services describe $QuoteService `
        --region=$GcpRegion --project=$GcpProject `
        --format='value(spec.template.spec.containers[0].image)' 2>$null
    if ($deployedImage) { Write-Pass "  image: $deployedImage" }
    try {
        $h = Invoke-RestMethod -Uri "$url/api/health" -TimeoutSec 5
        if ($h.status -eq 'ok') { Write-Pass "  /api/health → 200 OK" }
    } catch {
        Write-Miss "  /api/health 沒回應"
    }
} else {
    Write-Miss "Cloud Run service 不存在"
}

# ─────────────────────────────────────────────────────────
# Agent Runtime
# ─────────────────────────────────────────────────────────
Write-Section "Vertex AI Agent Runtime"
$mdPath = Join-Path $AgentDir 'deployment_metadata.json'
if (Test-Path $mdPath) {
    $md = Get-Content $mdPath | ConvertFrom-Json
    $rid = $md.remote_agent_runtime_id
    if ($rid -and $rid -ne 'None') {
        Write-Pass $rid
        $shortId = $rid -split '/' | Select-Object -Last 1
        Write-Host "  Console: https://console.cloud.google.com/vertex-ai/agents/agent-engines/locations/$GcpRegion/agent-engines/$shortId/playground?project=$GcpProject" -ForegroundColor DarkGray
    } else {
        Write-Miss "deployment_metadata.json 沒有 remote_agent_runtime_id"
    }
} else {
    Write-Miss "agent/deployment_metadata.json 不存在"
}
