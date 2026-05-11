# H-Beam Lab — 只部署 Quote Service 到 Cloud Run(PowerShell 版)
#
# 用法(預設 — 用 GHCR pre-built image):
#   $env:GCP_PROJECT = 'your-project-id'
#   .\scripts\deploy-service.ps1
#
# 用法(自己 build Go 程式碼):
#   $env:BUILD_LOCAL = 'true'; .\scripts\deploy-service.ps1
#
# 用法(鎖版):
#   $env:H_BEAM_IMAGE = 'ghcr.io/cshliu77/h-beam-quote:v0.1.0'; .\scripts\deploy-service.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"

# ─────────────────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────────────────
Invoke-Preflight
Write-Dim "區域:           $GcpRegion"
Write-Dim "Quote Service:   $QuoteService"
if ($BuildLocal -eq 'true') {
    Write-Dim "模式:           BUILD_LOCAL=true(Cloud Build → AR)"
    Write-Dim "Image:          $ArImageUri"
} else {
    Write-Dim "模式:           GHCR pre-built(透過 AR remote repo 代理)"
    Write-Dim "上游 image:      $HBeamImage"
    Write-Dim "Cloud Run 拉取:  $DeployImage"
}

# ─────────────────────────────────────────────────────────
# Phase A:啟用 API
# ─────────────────────────────────────────────────────────
function Enable-ServiceApis {
    Write-Step "[A] 啟用必要 API(run / cloudbuild / artifactregistry)"
    gcloud services enable `
        run.googleapis.com `
        cloudbuild.googleapis.com `
        artifactregistry.googleapis.com `
        --project=$GcpProject --quiet
    if ($LASTEXITCODE -ne 0) { throw "API enable 失敗" }
    Write-Ok "3 個 API 已啟用"
}

# ─────────────────────────────────────────────────────────
# Phase B:Artifact Registry
# ─────────────────────────────────────────────────────────
function Setup-ArtifactRegistry {
    if ($BuildLocal -eq 'true') {
        Write-Step "[B] 確保 Artifact Registry standard repo 存在($QuoteRepo @ $GcpRegion)"
        $null = gcloud artifacts repositories describe $QuoteRepo `
            --location=$GcpRegion --project=$GcpProject 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Dim "repo 已存在"
        } else {
            gcloud artifacts repositories create $QuoteRepo `
                --repository-format=docker `
                --location=$GcpRegion `
                --project=$GcpProject --quiet
            Write-Ok "AR standard repo 已建立"
        }
    } else {
        Write-Step "[B] 確保 Artifact Registry GHCR proxy repo 存在($GhcrProxyRepo @ $GcpRegion)"
        Write-Dim "(Cloud Run 不能直拉 ghcr.io,用 AR remote repo 透明代理)"
        $null = gcloud artifacts repositories describe $GhcrProxyRepo `
            --location=$GcpRegion --project=$GcpProject 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Dim "GHCR proxy repo 已存在"
        } else {
            gcloud artifacts repositories create $GhcrProxyRepo `
                --repository-format=docker `
                --location=$GcpRegion `
                --mode=remote-repository `
                --remote-docker-repo="https://ghcr.io" `
                --remote-repo-config-desc="GHCR remote proxy for h-beam-quote Lab image" `
                --project=$GcpProject --quiet
            Write-Ok "GHCR proxy repo 已建立"
        }
    }
}

# ─────────────────────────────────────────────────────────
# Phase C:確保 go.sum(僅 BUILD_LOCAL=true)
# ─────────────────────────────────────────────────────────
function Ensure-GoSum {
    if ($BuildLocal -ne 'true') {
        Write-Step "[C] 跳過 go.sum 檢查(GHCR 模式不需本機編譯)"
        return
    }
    Write-Step "[C] 確保 $QuoteDir\go.sum 存在"
    if (Test-Path "$QuoteDir\go.sum") {
        Write-Dim "go.sum 已存在"
        return
    }
    if (-not (Test-Command 'go')) {
        Write-Err "缺 go.sum,但本機沒有 go"
        Write-Dim "解法 1:裝 go 1.22+ 後重跑"
        Write-Dim "解法 2:乾脆走 GHCR pre-built(`$env:BUILD_LOCAL = 'false'`)"
        exit 1
    }
    Push-Location $QuoteDir
    try { go mod tidy } finally { Pop-Location }
    Write-Ok "go.sum 已產出"
}

# ─────────────────────────────────────────────────────────
# Phase D:Cloud Build(僅 BUILD_LOCAL=true)
# ─────────────────────────────────────────────────────────
function Build-Image {
    if ($BuildLocal -ne 'true') {
        Write-Step "[D] 跳過 Cloud Build(用 GHCR pre-built image)"
        return
    }
    Write-Step "[D] Cloud Build 編譯 Quote Service image"
    Write-Dim "源碼:$QuoteDir"
    Write-Dim "目標:$ArImageUri"
    Push-Location $QuoteDir
    try {
        gcloud builds submit `
            --tag $ArImageUri `
            --project=$GcpProject `
            --region=$GcpRegion `
            --quiet
        if ($LASTEXITCODE -ne 0) { throw "Cloud Build 失敗" }
    } finally { Pop-Location }
    Write-Ok "image 已推到 Artifact Registry"
}

# ─────────────────────────────────────────────────────────
# Phase E:Deploy Cloud Run
# ─────────────────────────────────────────────────────────
function Deploy-CloudRun {
    Write-Step "[E] 部署 Quote Service 到 Cloud Run @ $GcpRegion"
    Write-Dim "Image:$DeployImage"
    gcloud run deploy $QuoteService `
        --image $DeployImage `
        --region $GcpRegion `
        --project $GcpProject `
        --allow-unauthenticated `
        --port 8080 `
        --memory 256Mi `
        --cpu 1 `
        --min-instances 0 `
        --max-instances 3 `
        --quiet
    if ($LASTEXITCODE -ne 0) { throw "Cloud Run deploy 失敗" }
    Write-Ok "Quote Service deploy 完成"
}

# ─────────────────────────────────────────────────────────
# Phase F:Smoke test
# ─────────────────────────────────────────────────────────
function Test-ServiceSmoke {
    Write-Step "[F] 後端 API 煙霧測試"
    $url = gcloud run services describe $QuoteService `
        --region $GcpRegion --project $GcpProject `
        --format='value(status.url)'
    try {
        $health = Invoke-RestMethod -Uri "$url/api/health" -TimeoutSec 10
        if ($health.status -eq 'ok') {
            Write-Ok "/api/health → 200"
        } else {
            Write-Warn "/api/health 回應異常:$($health | ConvertTo-Json -Compress)"
        }
    } catch {
        Write-Warn "/api/health 沒回應(可能 Cloud Run 還在預熱,30 秒後再試)"
    }
    try {
        $body = '{"items":[{"product_code":"HW300x300","grade":"SS400","length_m":6,"quantity":20}]}'
        $resp = Invoke-RestMethod -Uri "$url/api/quotes" -Method POST `
            -ContentType 'application/json' -Body $body -TimeoutSec 10
        if ($resp.final_total_ntd -eq 321480) {
            Write-Ok "計算 API 回 NT`$ 321,480(預期值)"
        } else {
            Write-Warn "計算 API 回:$($resp.final_total_ntd)(預期 321480)"
        }
    } catch {
        Write-Warn "計算 API 失敗:$_"
    }
}

# ─────────────────────────────────────────────────────────
# 摘要
# ─────────────────────────────────────────────────────────
function Show-ServiceSummary {
    Write-Step "[完成] Quote Service 部署摘要"
    $url = gcloud run services describe $QuoteService `
        --region $GcpRegion --project $GcpProject `
        --format='value(status.url)' 2>$null
    if (-not $url) { $url = '(尚未部署)' }
    Write-Host ""
    Write-Host "  Quote Service URL : $url" -ForegroundColor Green
    Write-Host "  Region            : $GcpRegion" -ForegroundColor Green
    Write-Host "  Image             : $DeployImage" -ForegroundColor Green
    Write-Host ""
    Write-Host "  後續可選:" -ForegroundColor DarkGray
    Write-Host "    1. 自己寫 Agent 接 $url 做開發" -ForegroundColor DarkGray
    Write-Host "    2. 或部署 Lab 內建 Agent:" -ForegroundColor DarkGray
    Write-Host "       `$env:QUOTE_API_URL = '$url'" -ForegroundColor DarkGray
    Write-Host "       .\scripts\deploy-agent.ps1" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────
Enable-ServiceApis
Setup-ArtifactRegistry
Ensure-GoSum
Build-Image
Deploy-CloudRun
Test-ServiceSmoke
Show-ServiceSummary
