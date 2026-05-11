# H-Beam Lab — 清掉所有部署資源(PowerShell 版)
#
# 用法:
#   $env:GCP_PROJECT = 'your-project-id'
#   .\scripts\lab-teardown.ps1            # 互動式確認
#   .\scripts\lab-teardown.ps1 -Yes       # 跳過確認

param(
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_lib.ps1"

# ─────────────────────────────────────────────────────────
# 確認
# ─────────────────────────────────────────────────────────
function Confirm-Delete {
    Write-Host @"

即將從專案 $GcpProject ($GcpRegion) 刪除以下資源:

  • Agent Engine 實例(deployment_metadata.json 內列出的)
  • Cloud Run service:     $QuoteService
  • Artifact Registry:     $QuoteRepo + $GhcrProxyRepo
  • Service Account:       $AgentSaEmail

(保留:GCP API 啟用狀態 — 避免影響其他專案)

"@ -ForegroundColor Yellow

    if (-not $Yes) {
        $ans = Read-Host "確認刪除?(打 yes 確認)"
        if ($ans -ne 'yes') {
            Write-Host "取消" -ForegroundColor Yellow
            exit 0
        }
    }
}

# ─────────────────────────────────────────────────────────
# 1. 刪 Agent Engine
# ─────────────────────────────────────────────────────────
function Remove-AgentEngine {
    Write-Step "[1] 刪除 Agent Engine 實例"
    $mdPath = Join-Path $AgentDir 'deployment_metadata.json'
    if (-not (Test-Path $mdPath)) {
        Write-Dim "找不到 deployment_metadata.json,跳過"
        return
    }
    $md = Get-Content $mdPath | ConvertFrom-Json
    $rid = $md.remote_agent_runtime_id
    if (-not $rid -or $rid -eq 'None') {
        Write-Dim "deployment_metadata.json 沒有 remote_agent_runtime_id,跳過"
        return
    }
    Write-Dim "Agent: $rid"
    try {
        $token = gcloud auth print-access-token 2>$null
        $api = "https://$GcpRegion-aiplatform.googleapis.com/v1/$rid?force=true"
        $resp = Invoke-RestMethod -Uri $api -Method DELETE `
            -Headers @{ Authorization = "Bearer $token" } -ErrorAction Stop
        Write-Ok "Agent Engine 已刪除"
    } catch {
        Write-Warn "刪除可能失敗(資源可能已不存在):$_"
    }

    # 重置 metadata
    $md.remote_agent_runtime_id = 'None'
    $md.deployment_timestamp = 'None'
    $md | ConvertTo-Json | Set-Content $mdPath
    Write-Ok "deployment_metadata.json 已重置"
}

# ─────────────────────────────────────────────────────────
# 2. Cloud Run
# ─────────────────────────────────────────────────────────
function Remove-CloudRun {
    Write-Step "[2] 刪除 Cloud Run service"
    $null = gcloud run services describe $QuoteService `
        --region=$GcpRegion --project=$GcpProject 2>$null
    if ($LASTEXITCODE -eq 0) {
        gcloud run services delete $QuoteService `
            --region=$GcpRegion --project=$GcpProject --quiet
        Write-Ok "Cloud Run service $QuoteService 已刪除"
    } else {
        Write-Dim "Cloud Run service 不存在,跳過"
    }
}

# ─────────────────────────────────────────────────────────
# 3. Artifact Registry repos
# ─────────────────────────────────────────────────────────
function Remove-ArtifactRegistry {
    Write-Step "[3] 刪除 Artifact Registry repos"
    foreach ($repo in @($QuoteRepo, $GhcrProxyRepo)) {
        $null = gcloud artifacts repositories describe $repo `
            --location=$GcpRegion --project=$GcpProject 2>$null
        if ($LASTEXITCODE -eq 0) {
            gcloud artifacts repositories delete $repo `
                --location=$GcpRegion --project=$GcpProject --quiet
            Write-Ok "  AR repo $repo 已刪除"
        } else {
            Write-Dim "  $repo 不存在(跳過)"
        }
    }
}

# ─────────────────────────────────────────────────────────
# 4. SA + IAM
# ─────────────────────────────────────────────────────────
function Remove-Sa {
    Write-Step "[4] 刪除 Service Account 與 IAM 綁定"
    $null = gcloud iam service-accounts describe $AgentSaEmail --project=$GcpProject 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Dim "SA 不存在,跳過"
        return
    }
    $roles = @(
        'roles/cloudtrace.agent', 'roles/logging.logWriter',
        'roles/monitoring.metricWriter', 'roles/serviceusage.serviceUsageConsumer',
        'roles/aiplatform.user'
    )
    foreach ($role in $roles) {
        $null = gcloud projects remove-iam-policy-binding $GcpProject `
            --member="serviceAccount:$AgentSaEmail" `
            --role=$role --condition=None --quiet 2>$null
        Write-Dim "  ✓ unbind $role"
    }
    gcloud iam service-accounts delete $AgentSaEmail --project=$GcpProject --quiet
    Write-Ok "SA $AgentSaEmail 已刪除"
}

# ─────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────
Confirm-Delete
Remove-AgentEngine
Remove-CloudRun
Remove-ArtifactRegistry
Remove-Sa

Write-Host ""
Write-Host "✓ Lab 環境已清空" -ForegroundColor Green
Write-Host "  (GCP API 保留啟用狀態;若要關閉自行 gcloud services disable)" -ForegroundColor DarkGray
