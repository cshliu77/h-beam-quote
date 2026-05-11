# H-Beam Lab — One-shot 部署(Quote Service + Agent 兩個都跑,PowerShell 版)
#
# 等同依序執行:
#   .\scripts\deploy-service.ps1
#   .\scripts\deploy-agent.ps1
#
# 用法:
#   $env:GCP_PROJECT = 'your-project-id'
#   .\scripts\lab-bootstrap.ps1

$ErrorActionPreference = 'Stop'

if (-not $env:GCP_PROJECT) {
    Write-Host "ERROR: 需要設 GCP_PROJECT 環境變數" -ForegroundColor Red
    Write-Host "  例: `$env:GCP_PROJECT = 'your-project-id'" -ForegroundColor DarkGray
    exit 1
}

$region    = if ($env:GCP_REGION)  { $env:GCP_REGION }  else { 'asia-east1' }
$buildLocal = if ($env:BUILD_LOCAL) { $env:BUILD_LOCAL } else { 'false' }

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════"
Write-Host "  H-Beam Lab One-shot Bootstrap (PowerShell)"
Write-Host "  Project: $($env:GCP_PROJECT)   Region: $region"
Write-Host "  Mode:    $buildLocal (BUILD_LOCAL — true=Cloud Build, false=GHCR proxy)"
Write-Host "════════════════════════════════════════════════════════════"

# Step 1:Quote Service
& "$PSScriptRoot\deploy-service.ps1"
if ($LASTEXITCODE -ne 0) { throw "deploy-service.ps1 失敗" }

# Step 2:Agent
& "$PSScriptRoot\deploy-agent.ps1"
if ($LASTEXITCODE -ne 0) { throw "deploy-agent.ps1 失敗" }

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════"
Write-Host "  ✓ One-shot 部署完成" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════════"
Write-Host ""
Write-Host "查狀態:.\scripts\lab-status.ps1"
Write-Host "清資源:.\scripts\lab-teardown.ps1 -Yes"
