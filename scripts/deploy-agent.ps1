# H-Beam Lab — 只部署 ADK Agent 到 Vertex AI Agent Runtime(PowerShell 版)
#
# 用法 1(Cloud Run 已有 h-beam-quote)— URL 自動抓:
#   $env:GCP_PROJECT = 'your-project-id'
#   .\scripts\deploy-agent.ps1
#
# 用法 2(後端在別處):
#   $env:GCP_PROJECT = 'your-project-id'
#   $env:QUOTE_API_URL = 'http://localhost:8080'
#   .\scripts\deploy-agent.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_lib.ps1"

# ─────────────────────────────────────────────────────────
# Preflight + 工具檢查
# ─────────────────────────────────────────────────────────
Invoke-Preflight

Write-Step "[Preflight] 工具 uv / agents-cli / python"
foreach ($cmd in @('uv', 'agents-cli')) {
    if (-not (Test-Command $cmd)) {
        Write-Err "缺工具:$cmd"
        if ($cmd -eq 'agents-cli') {
            Write-Dim "安裝:uv tool install google-agents-cli"
        }
        if ($cmd -eq 'uv') {
            Write-Dim "Windows 安裝:powershell -c `"irm https://astral.sh/uv/install.ps1 | iex`""
        }
        exit 1
    }
}
if (-not $PythonCmd) {
    Write-Err "缺工具:python(到 https://www.python.org 安裝 3.11+)"
    exit 1
}
Write-Ok "uv / agents-cli / $PythonCmd 都在"
Write-Dim "Agent SA: $AgentSaEmail"

# ─────────────────────────────────────────────────────────
# Phase A:啟用 API
# ─────────────────────────────────────────────────────────
function Enable-AgentApis {
    Write-Step "[A] 啟用 Vertex AI + Observability API"
    gcloud services enable `
        aiplatform.googleapis.com `
        cloudtrace.googleapis.com `
        logging.googleapis.com `
        monitoring.googleapis.com `
        telemetry.googleapis.com `
        --project=$GcpProject --quiet
    if ($LASTEXITCODE -ne 0) { throw "API enable 失敗" }
    Write-Ok "5 個 API 已啟用"
}

# ─────────────────────────────────────────────────────────
# Phase B:Service Account + IAM
# ─────────────────────────────────────────────────────────
function Setup-Sa {
    Write-Step "[B] 建立 Agent Service Account 與綁定 IAM 角色"

    $null = gcloud iam service-accounts describe $AgentSaEmail --project=$GcpProject 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Dim "SA 已存在:$AgentSaEmail"
    } else {
        gcloud iam service-accounts create $AgentSaName `
            --display-name="H-Beam Agent Runtime SA" `
            --project=$GcpProject --quiet
        if ($LASTEXITCODE -ne 0) { throw "SA 建立失敗" }
        Write-Ok "SA 已建立"

        Write-Dim "等 SA 在 IAM API 一致..."
        for ($i = 1; $i -le 30; $i++) {
            $null = gcloud iam service-accounts describe $AgentSaEmail --project=$GcpProject 2>$null
            if ($LASTEXITCODE -eq 0) {
                Start-Sleep -Seconds 2
                break
            }
            Start-Sleep -Seconds 2
        }
    }

    $roles = @(
        'roles/cloudtrace.agent',
        'roles/logging.logWriter',
        'roles/monitoring.metricWriter',
        'roles/serviceusage.serviceUsageConsumer',
        'roles/aiplatform.user'
    )
    foreach ($role in $roles) {
        $attempt = 0
        do {
            $null = gcloud projects add-iam-policy-binding $GcpProject `
                --member="serviceAccount:$AgentSaEmail" `
                --role=$role --condition=None --quiet 2>$null
            if ($LASTEXITCODE -eq 0) { break }
            $attempt++
            if ($attempt -ge 10) {
                Write-Err "綁定 $role 失敗(已試 10 次)"
                exit 1
            }
            Write-Dim "  ⟳ 重試 $role(IAM 傳播中,$attempt/10)..."
            Start-Sleep -Seconds 3
        } while ($true)
        Write-Dim "  ✓ $role"
    }
    Write-Ok "5 個必要角色已綁定(含 serviceUsageConsumer 防 OTel 403)"
}

# ─────────────────────────────────────────────────────────
# Phase C:取得 Quote Service URL
# ─────────────────────────────────────────────────────────
function Resolve-QuoteUrl {
    Write-Step "[C] 取得 Quote Service URL"
    $script:QuoteApiUrl = $env:QUOTE_API_URL
    if ($script:QuoteApiUrl) {
        Write-Dim "從 env 讀 QUOTE_API_URL:$($script:QuoteApiUrl)"
    } else {
        Write-Dim "查 Cloud Run service $QuoteService @ $GcpRegion..."
        $script:QuoteApiUrl = gcloud run services describe $QuoteService `
            --region $GcpRegion --project $GcpProject `
            --format='value(status.url)' 2>$null
        if (-not $script:QuoteApiUrl) {
            Write-Err "找不到 Cloud Run service $QuoteService,也沒有 QUOTE_API_URL env"
            Write-Dim "解法 1:先跑 .\scripts\deploy-service.ps1"
            Write-Dim "解法 2:設 `$env:QUOTE_API_URL 指向別處,例如 http://localhost:8080"
            exit 1
        }
        Write-Ok "自動抓到 Cloud Run URL:$($script:QuoteApiUrl)"
    }

    try {
        $health = Invoke-RestMethod -Uri "$($script:QuoteApiUrl)/api/health" -TimeoutSec 10
        if ($health.status -eq 'ok') {
            Write-Ok "$($script:QuoteApiUrl)/api/health → 200"
        }
    } catch {
        Write-Warn "$($script:QuoteApiUrl)/api/health 沒回應(繼續,但 Agent 可能連不到)"
    }
}

# ─────────────────────────────────────────────────────────
# Phase D:更新 agent/.env
# ─────────────────────────────────────────────────────────
function Update-AgentEnv {
    Write-Step "[D] 更新 agent/.env(GCP_PROJECT / QUOTE_API_URL / SERVICE_ACCOUNT)"
    $envFile = Join-Path $AgentDir '.env'
    if (-not (Test-Path $envFile)) {
        Copy-Item (Join-Path $AgentDir '.env.example') $envFile
        Write-Dim "從 .env.example 建立 .env"
    }

    # 用 python script 改值(避免 PowerShell 處理 multi-line regex 的麻煩)
    $pyScript = @'
import re, sys
path, project, url, sa = sys.argv[1:5]
with open(path, encoding='utf-8') as f:
    s = f.read()
def setvar(s, key, value):
    pattern = rf"^{re.escape(key)}=.*$"
    new = f"{key}={value}"
    if re.search(pattern, s, flags=re.M):
        return re.sub(pattern, new, s, flags=re.M)
    return s.rstrip() + f"\n{new}\n"
s = setvar(s, "GCP_PROJECT", project)
s = setvar(s, "GOOGLE_CLOUD_PROJECT", project)
s = setvar(s, "QUOTE_API_URL", url)
s = setvar(s, "SERVICE_ACCOUNT", sa)
with open(path, "w", encoding='utf-8') as f:
    f.write(s)
'@
    $tmpPy = New-TemporaryFile
    $tmpPy = "$($tmpPy.FullName).py"
    Set-Content -Path $tmpPy -Value $pyScript -Encoding UTF8
    & $PythonCmd $tmpPy $envFile $GcpProject $script:QuoteApiUrl $AgentSaEmail
    Remove-Item $tmpPy
    Write-Ok "agent/.env 已更新"
}

# ─────────────────────────────────────────────────────────
# Phase E:Agent 部署
# ─────────────────────────────────────────────────────────
function Deploy-Agent {
    Write-Step "[E] 部署 Agent 到 Vertex AI Agent Runtime @ $GcpRegion"
    Push-Location $AgentDir
    try {
        $null = agents-cli install
        Write-Ok "依賴同步完成"
        agents-cli deploy `
            --no-confirm-project `
            --update-env-vars "QUOTE_API_URL=$($script:QuoteApiUrl),OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=NO_CONTENT"
        if ($LASTEXITCODE -ne 0) { throw "agents-cli deploy 失敗" }
    } finally { Pop-Location }
    Write-Ok "Agent 部署完成,deployment_metadata.json 已更新"
}

# ─────────────────────────────────────────────────────────
# Phase F:遠端煙霧
# ─────────────────────────────────────────────────────────
function Test-AgentSmoke {
    Write-Step "[F] 遠端煙霧測試"
    Push-Location $AgentDir
    try {
        $md = Get-Content (Join-Path $AgentDir 'deployment_metadata.json') | ConvertFrom-Json
        $rid = $md.remote_agent_runtime_id
        $url = "https://${GcpRegion}-aiplatform.googleapis.com/v1/${rid}"
        Write-Dim "Agent URL: $url"
        $output = agents-cli run "HW300x300 多重?" --url $url --mode adk 2>&1 | Out-String
        if ($output -match '94|kg/m') {
            Write-Ok "Agent 回應提到 94(HW300x300 unit_weight),tool routing 正常"
        } else {
            Write-Warn "煙霧測試沒看到預期關鍵字 — 詳細跑 agents-cli run 看完整輸出"
        }
    } finally { Pop-Location }
}

# ─────────────────────────────────────────────────────────
# 摘要
# ─────────────────────────────────────────────────────────
function Show-AgentSummary {
    Write-Step "[完成] Agent 部署摘要"
    $md = Get-Content (Join-Path $AgentDir 'deployment_metadata.json') | ConvertFrom-Json
    $rid = $md.remote_agent_runtime_id
    $shortId = $rid -split '/' | Select-Object -Last 1
    Write-Host ""
    Write-Host "  Agent Runtime      : $rid" -ForegroundColor Green
    Write-Host "  Service Account    : $AgentSaEmail" -ForegroundColor Green
    Write-Host "  後端 Quote Service : $($script:QuoteApiUrl)" -ForegroundColor Green
    Write-Host "  Region             : $GcpRegion (Gemini 走 global endpoint)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Console Playground:" -ForegroundColor DarkGray
    Write-Host "    https://console.cloud.google.com/vertex-ai/agents/agent-engines/locations/$GcpRegion/agent-engines/$shortId/playground?project=$GcpProject" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  互動測試:" -ForegroundColor DarkGray
    Write-Host "    cd agent" -ForegroundColor DarkGray
    Write-Host "    agents-cli run `"HW300x300 多重?`" --url `"https://${GcpRegion}-aiplatform.googleapis.com/v1/${rid}`" --mode adk" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────
Enable-AgentApis
Setup-Sa
Resolve-QuoteUrl
Update-AgentEnv
Deploy-Agent
Test-AgentSmoke
Show-AgentSummary
