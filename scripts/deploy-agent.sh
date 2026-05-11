#!/usr/bin/env bash
# H-Beam Lab — 只部署 ADK Agent 到 Vertex AI Agent Runtime
#
# 用途:已部署過 Quote Service(或指向其他現成後端),要部署 Lab 內建 Agent。
# 自動從 Cloud Run 撈 Quote Service URL;若 Cloud Run 沒部署則需要 QUOTE_API_URL env。
#
# 用法 1(Cloud Run 已有 h-beam-quote service)— URL 自動抓:
#   export GCP_PROJECT=your-project-id
#   ./scripts/deploy-agent.sh
#
# 用法 2(後端在別處,例如本機 docker):
#   export GCP_PROJECT=your-project-id
#   export QUOTE_API_URL=http://your-backend:8080
#   ./scripts/deploy-agent.sh

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ─────────────────────────────────────────────────────────
# Preflight + 工具檢查(這支需要 uv + agents-cli)
# ─────────────────────────────────────────────────────────
preflight_gcloud

step "[Preflight] 工具 uv / agents-cli"
for cmd in uv agents-cli; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "缺工具:$cmd"
    [[ "$cmd" == "agents-cli" ]] && info "安裝:uv tool install google-agents-cli"
    [[ "$cmd" == "uv" ]] && info "安裝:curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
  fi
done
ok "uv / agents-cli 都在"
info "Agent SA: $AGENT_SA_EMAIL"

# ─────────────────────────────────────────────────────────
# Phase A:啟用 Vertex AI / Observability API
# ─────────────────────────────────────────────────────────
enable_agent_apis() {
  step "[A] 啟用 Vertex AI + Observability API"
  gcloud services enable \
    aiplatform.googleapis.com \
    cloudtrace.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    telemetry.googleapis.com \
    --project="$GCP_PROJECT" --quiet
  ok "5 個 API 已啟用"
}

# ─────────────────────────────────────────────────────────
# Phase B:Service Account + IAM
# ─────────────────────────────────────────────────────────
setup_sa() {
  step "[B] 建立 Agent Service Account 與綁定 IAM 角色"

  if gcloud iam service-accounts describe "$AGENT_SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    info "SA 已存在:$AGENT_SA_EMAIL"
  else
    gcloud iam service-accounts create "$AGENT_SA_NAME" \
      --display-name="H-Beam Agent Runtime SA" \
      --project="$GCP_PROJECT" --quiet
    ok "SA 已建立"

    # IAM 傳播延遲:輪詢 describe 直到一致
    info "等 SA 在 IAM API 一致..."
    for i in $(seq 1 30); do
      if gcloud iam service-accounts describe "$AGENT_SA_EMAIL" \
           --project="$GCP_PROJECT" >/dev/null 2>&1; then
        sleep 2
        break
      fi
      sleep 2
    done
  fi

  local roles=(
    roles/cloudtrace.agent
    roles/logging.logWriter
    roles/monitoring.metricWriter
    roles/serviceusage.serviceUsageConsumer
    roles/aiplatform.user
  )
  for role in "${roles[@]}"; do
    local attempt=0
    until gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
            --member="serviceAccount:${AGENT_SA_EMAIL}" \
            --role="$role" --condition=None --quiet >/dev/null 2>&1; do
      attempt=$((attempt+1))
      if (( attempt >= 10 )); then
        err "綁定 $role 失敗(已試 10 次)"
        exit 1
      fi
      info "  ⟳ 重試 $role(IAM 傳播中,${attempt}/10)..."
      sleep 3
    done
    info "  ✓ $role"
  done
  ok "5 個必要角色已綁定(含 serviceUsageConsumer 防 OTel 403)"
}

# ─────────────────────────────────────────────────────────
# Phase C:抓 / 取得 Quote Service URL
#   - 優先用 QUOTE_API_URL env(若有設)
#   - 否則自動從 Cloud Run 撈 h-beam-quote service URL
# ─────────────────────────────────────────────────────────
resolve_quote_url() {
  step "[C] 取得 Quote Service URL"

  if [[ -n "${QUOTE_API_URL:-}" ]]; then
    info "從 env 讀 QUOTE_API_URL:$QUOTE_API_URL"
  else
    info "查 Cloud Run service $QUOTE_SERVICE @ $GCP_REGION..."
    QUOTE_API_URL=$(gcloud run services describe "$QUOTE_SERVICE" \
      --region "$GCP_REGION" --project "$GCP_PROJECT" \
      --format='value(status.url)' 2>/dev/null || true)
    if [[ -z "$QUOTE_API_URL" ]]; then
      err "找不到 Cloud Run service $QUOTE_SERVICE,也沒有 QUOTE_API_URL env"
      info "解法 1:先跑 ./scripts/deploy-service.sh 部署 Quote Service"
      info "解法 2:設 QUOTE_API_URL 指向別處,例如 http://localhost:8080"
      exit 1
    fi
    ok "自動抓到 Cloud Run URL:$QUOTE_API_URL"
  fi

  # smoke 後端可達
  if curl -sSf -o /dev/null "${QUOTE_API_URL}/api/health"; then
    ok "${QUOTE_API_URL}/api/health → 200"
  else
    warn "${QUOTE_API_URL}/api/health 沒回應(繼續,但 Agent 可能連不到)"
  fi
}

# ─────────────────────────────────────────────────────────
# Phase D:更新 agent/.env
# ─────────────────────────────────────────────────────────
update_agent_env() {
  step "[D] 更新 agent/.env(GCP_PROJECT / QUOTE_API_URL / SERVICE_ACCOUNT)"
  if [[ ! -f "$AGENT_DIR/.env" ]]; then
    cp "$AGENT_DIR/.env.example" "$AGENT_DIR/.env"
    info "從 .env.example 建立 .env"
  fi
  python3 - "$AGENT_DIR/.env" "$GCP_PROJECT" "$QUOTE_API_URL" "$AGENT_SA_EMAIL" <<'PY'
import re, sys
path, project, url, sa = sys.argv[1:5]
with open(path) as f:
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
with open(path, "w") as f:
    f.write(s)
PY
  ok "agent/.env 已更新"
}

# ─────────────────────────────────────────────────────────
# Phase E:Agent 部署到 Agent Runtime
# ─────────────────────────────────────────────────────────
deploy_agent() {
  step "[E] 部署 Agent 到 Vertex AI Agent Runtime @ ${GCP_REGION}"

  cd "$AGENT_DIR"
  agents-cli install >/dev/null
  ok "依賴同步完成"

  # --update-env-vars 是必要的:agents-cli 不會自動讀 .env 注入到 Agent Runtime
  agents-cli deploy \
    --no-confirm-project \
    --update-env-vars "QUOTE_API_URL=${QUOTE_API_URL},OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=NO_CONTENT"

  ok "Agent 部署完成,deployment_metadata.json 已更新"
}

# ─────────────────────────────────────────────────────────
# Phase F:遠端煙霧測試
# ─────────────────────────────────────────────────────────
smoke_test_agent() {
  step "[F] 遠端煙霧測試"

  cd "$AGENT_DIR"
  local rid url
  rid=$(python3 -c "import json; print(json.load(open('deployment_metadata.json'))['remote_agent_runtime_id'])")
  url="https://${GCP_REGION}-aiplatform.googleapis.com/v1/${rid}"
  info "Agent URL: $url"

  if agents-cli run "HW300x300 多重?" --url "$url" --mode adk 2>&1 | grep -E "94|kg/m" >/dev/null; then
    ok "Agent 回應提到 94(HW300x300 unit_weight),tool routing 正常"
  else
    warn "煙霧測試沒看到預期關鍵字 — 詳細跑 agents-cli run 看完整輸出"
  fi
}

# ─────────────────────────────────────────────────────────
# 摘要
# ─────────────────────────────────────────────────────────
summary_agent() {
  step "[完成] Agent 部署摘要"
  cd "$AGENT_DIR"
  local rid
  rid=$(python3 -c "import json; print(json.load(open('deployment_metadata.json'))['remote_agent_runtime_id'])" 2>/dev/null || echo "(尚未部署)")

  cat <<SUMMARY

  ${C_GREEN}✓ Agent Runtime${C_RESET}: $rid
  ${C_GREEN}✓ Service Account${C_RESET}: $AGENT_SA_EMAIL
  ${C_GREEN}✓ 後端 Quote Service${C_RESET}: $QUOTE_API_URL
  ${C_GREEN}✓ Region${C_RESET}: $GCP_REGION (Gemini 走 global endpoint)

  Console Playground:
    https://console.cloud.google.com/vertex-ai/agents/agent-engines/locations/${GCP_REGION}/agent-engines/${rid##*/}/playground?project=${GCP_PROJECT}

  Cloud Trace:
    https://console.cloud.google.com/traces/list?project=${GCP_PROJECT}

  互動測試:
    cd agent
    agents-cli run "HW300x300 多重?" --url "https://${GCP_REGION}-aiplatform.googleapis.com/v1/${rid}" --mode adk

SUMMARY
}

main() {
  enable_agent_apis
  setup_sa
  resolve_quote_url
  update_agent_env
  deploy_agent
  smoke_test_agent
  summary_agent
}

main "$@"
