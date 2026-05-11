#!/usr/bin/env bash
# H-Beam Lab — One-shot 部署腳本
#
# 從零開始把 Quote Service(Cloud Run)+ ADK Agent(Vertex AI Agent Runtime)
# 一次部署起來。可重複執行(idempotent)。
#
# 用法(預設 — 用講師預先發布的 GHCR image,Lab 學員走這條):
#   export GCP_PROJECT=your-project-id
#   ./scripts/lab-bootstrap.sh
#
# 用法(escape hatch — 自己 build Go 程式碼):
#   export GCP_PROJECT=your-project-id
#   BUILD_LOCAL=true ./scripts/lab-bootstrap.sh
#
# 用法(鎖版本給 Lab Day):
#   H_BEAM_IMAGE=ghcr.io/cshliu77/h-beam-quote:v0.1.0 ./scripts/lab-bootstrap.sh
#
# 可選環境變數:
#   GCP_REGION      預設 asia-east1
#   QUOTE_SERVICE   預設 h-beam-quote
#   H_BEAM_IMAGE    預設 ghcr.io/cshliu77/h-beam-quote:latest(BUILD_LOCAL=false 時使用)
#   BUILD_LOCAL     預設 false(true 時走 Cloud Build → Artifact Registry)
#   QUOTE_REPO      預設 h-beam-images(僅 BUILD_LOCAL=true 用)
#   AGENT_SA_NAME   預設 h-beam-agent

set -euo pipefail

# ─────────────────────────────────────────────────────────
# 配置(env override 友善)
# ─────────────────────────────────────────────────────────
: "${GCP_PROJECT:?需要設 GCP_PROJECT 環境變數,例:export GCP_PROJECT=your-project}"
GCP_REGION="${GCP_REGION:-asia-east1}"
QUOTE_SERVICE="${QUOTE_SERVICE:-h-beam-quote}"
QUOTE_REPO="${QUOTE_REPO:-h-beam-images}"
AGENT_SA_NAME="${AGENT_SA_NAME:-h-beam-agent}"
AGENT_SA_EMAIL="${AGENT_SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"

# Image 來源:預設 GHCR pre-built,BUILD_LOCAL=true 時改走 Artifact Registry
H_BEAM_IMAGE="${H_BEAM_IMAGE:-ghcr.io/cshliu77/h-beam-quote:latest}"
BUILD_LOCAL="${BUILD_LOCAL:-false}"

# Cloud Run 不能直接拉 GHCR(只認 *-docker.pkg.dev / gcr.io / docker.io)。
# 解法:用 AR remote repository 模式代理 GHCR,Cloud Run 從 AR 拉,AR 透明 proxy 至 GHCR。
GHCR_PROXY_REPO="${GHCR_PROXY_REPO:-h-beam-ghcr-proxy}"
AR_IMAGE_URI="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${QUOTE_REPO}/${QUOTE_SERVICE}:latest"
if [[ "$BUILD_LOCAL" == "true" ]]; then
  DEPLOY_IMAGE="$AR_IMAGE_URI"
else
  # 把 ghcr.io/<path>:<tag> 換成 ${REGION}-docker.pkg.dev/${PROJECT}/${PROXY_REPO}/<path>:<tag>
  if [[ "$H_BEAM_IMAGE" != ghcr.io/* ]]; then
    echo "ERROR: H_BEAM_IMAGE 必須以 ghcr.io/ 開頭(BUILD_LOCAL=false 模式):$H_BEAM_IMAGE" >&2
    exit 1
  fi
  GHCR_PATH="${H_BEAM_IMAGE#ghcr.io/}"
  DEPLOY_IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${GHCR_PROXY_REPO}/${GHCR_PATH}"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUOTE_DIR="${REPO_ROOT}"
AGENT_DIR="${REPO_ROOT}/agent"

# ─────────────────────────────────────────────────────────
# 顯示工具(色彩可關 — TERM=dumb)
# ─────────────────────────────────────────────────────────
if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=; C_DIM=; C_RESET=
fi

step() { printf "\n${C_BLUE}▶ %s${C_RESET}\n" "$*"; }
ok()   { printf "${C_GREEN}✓ %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}⚠ %s${C_RESET}\n" "$*"; }
err()  { printf "${C_RED}✗ %s${C_RESET}\n" "$*" >&2; }
info() { printf "${C_DIM}  %s${C_RESET}\n" "$*"; }

# ─────────────────────────────────────────────────────────
# 預檢
# ─────────────────────────────────────────────────────────
preflight() {
  step "[Preflight] 確認工具與 GCP 專案"

  for cmd in gcloud uv agents-cli; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "缺工具:$cmd"
      [[ "$cmd" == "agents-cli" ]] && info "安裝:uv tool install google-agents-cli"
      [[ "$cmd" == "uv" ]] && info "安裝:curl -LsSf https://astral.sh/uv/install.sh | sh"
      exit 1
    fi
  done
  ok "gcloud / uv / agents-cli 都在"

  if ! gcloud projects describe "$GCP_PROJECT" >/dev/null 2>&1; then
    err "看不到 GCP 專案 $GCP_PROJECT — 用 gcloud projects list 確認 ID"
    exit 1
  fi
  ok "專案可見:$GCP_PROJECT"

  gcloud config set project "$GCP_PROJECT" >/dev/null 2>&1
  gcloud auth application-default set-quota-project "$GCP_PROJECT" >/dev/null 2>&1 || true
  ok "current project / ADC quota project = $GCP_PROJECT"

  info "區域:           $GCP_REGION"
  info "Quote Service:   $QUOTE_SERVICE"
  if [[ "$BUILD_LOCAL" == "true" ]]; then
    info "Image 來源:      Cloud Build → $AR_IMAGE_URI"
  else
    info "Image 來源:      $H_BEAM_IMAGE"
    info "Cloud Run 拉取:  $DEPLOY_IMAGE"
    info "                (AR remote repo 透明代理 GHCR)"
  fi
  info "Agent SA:        $AGENT_SA_EMAIL"
}

# ─────────────────────────────────────────────────────────
# Phase A:啟用 GCP API
# ─────────────────────────────────────────────────────────
enable_apis() {
  step "[A] 啟用必要 API(idempotent)"
  gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    aiplatform.googleapis.com \
    cloudtrace.googleapis.com \
    logging.googleapis.com \
    monitoring.googleapis.com \
    telemetry.googleapis.com \
    --project="$GCP_PROJECT" --quiet
  ok "8 個 API 已啟用"
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

    # IAM 傳播延遲:SA 剛建好但 add-iam-policy-binding 可能還看不到。
    # 輪詢 describe 直到一致(典型 ~5-10 秒)。
    info "等 SA 在 IAM API 一致..."
    for i in $(seq 1 30); do
      if gcloud iam service-accounts describe "$AGENT_SA_EMAIL" \
           --project="$GCP_PROJECT" >/dev/null 2>&1; then
        sleep 2  # 額外緩衝,避免 describe 看到但 policy binding API 還沒
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
    # 加 retry — IAM 傳播延遲新 SA 時可能仍說 "does not exist"
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
# Phase C:Artifact Registry
#   BUILD_LOCAL=true  → standard repo(放本機 build 的 image)
#   BUILD_LOCAL=false → remote repo(代理 GHCR,Cloud Run 從這拉)
# ─────────────────────────────────────────────────────────
setup_artifact_registry() {
  if [[ "$BUILD_LOCAL" == "true" ]]; then
    step "[C] 確保 Artifact Registry standard repo 存在(${QUOTE_REPO} @ ${GCP_REGION})"
    if gcloud artifacts repositories describe "$QUOTE_REPO" \
        --location="$GCP_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
      info "repo 已存在"
    else
      gcloud artifacts repositories create "$QUOTE_REPO" \
        --repository-format=docker \
        --location="$GCP_REGION" \
        --project="$GCP_PROJECT" --quiet
      ok "Artifact Registry standard repo 已建立"
    fi
  else
    step "[C] 確保 Artifact Registry GHCR proxy repo 存在(${GHCR_PROXY_REPO} @ ${GCP_REGION})"
    info "(Cloud Run 不能直拉 ghcr.io,用 AR remote repo 代理 GHCR)"
    if gcloud artifacts repositories describe "$GHCR_PROXY_REPO" \
        --location="$GCP_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
      info "GHCR proxy repo 已存在"
    else
      gcloud artifacts repositories create "$GHCR_PROXY_REPO" \
        --repository-format=docker \
        --location="$GCP_REGION" \
        --mode=remote-repository \
        --remote-docker-repo="https://ghcr.io" \
        --remote-repo-config-desc="GHCR remote proxy for h-beam-quote Lab image" \
        --project="$GCP_PROJECT" --quiet
      ok "GHCR proxy repo 已建立(${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${GHCR_PROXY_REPO})"
    fi
  fi
}

# ─────────────────────────────────────────────────────────
# Phase D:確保 go.sum 存在(僅 BUILD_LOCAL=true 用)
# ─────────────────────────────────────────────────────────
ensure_go_sum() {
  if [[ "$BUILD_LOCAL" != "true" ]]; then
    step "[D] 跳過 go.sum 檢查(用 GHCR pre-built image,不需本機編譯)"
    return
  fi
  step "[D] 確保 ${QUOTE_DIR}/go.sum 存在"

  if [[ -f "$QUOTE_DIR/go.sum" ]]; then
    info "go.sum 已存在"
    return
  fi

  if ! command -v go >/dev/null 2>&1; then
    err "缺 go.sum,但本機沒有 go(Cloud Build 的 COPY go.sum* 在無檔時會 error)"
    info "解法 1:本機裝 go 1.22+ 後再跑此腳本(會自動 go mod tidy)"
    info "解法 2:在另一台有 go 的機器跑 'cd h-beam-quote && go mod tidy' 後 commit go.sum"
    info "解法 3:乾脆用 GHCR 預先 build:不要設 BUILD_LOCAL=true(預設值就走這)"
    exit 1
  fi
  (cd "$QUOTE_DIR" && go mod tidy)
  ok "go.sum 已產出"
}

# ─────────────────────────────────────────────────────────
# Phase E:Build + Push Image(僅 BUILD_LOCAL=true 用)
# ─────────────────────────────────────────────────────────
build_image() {
  if [[ "$BUILD_LOCAL" != "true" ]]; then
    step "[E] 跳過 Cloud Build(用 GHCR pre-built image: $H_BEAM_IMAGE)"
    return
  fi
  step "[E] Cloud Build 編譯 Quote Service image"
  info "源碼:$QUOTE_DIR"
  info "目標:$AR_IMAGE_URI"
  (cd "$QUOTE_DIR" && gcloud builds submit \
    --tag "$AR_IMAGE_URI" \
    --project="$GCP_PROJECT" \
    --region="$GCP_REGION" \
    --quiet)
  ok "image 已推到 Artifact Registry"
}

# ─────────────────────────────────────────────────────────
# Phase F:Deploy Cloud Run(用 $DEPLOY_IMAGE — GHCR 或 AR)
# ─────────────────────────────────────────────────────────
deploy_cloud_run() {
  step "[F] 部署 Quote Service 到 Cloud Run @ ${GCP_REGION}"
  info "Image:$DEPLOY_IMAGE"
  gcloud run deploy "$QUOTE_SERVICE" \
    --image "$DEPLOY_IMAGE" \
    --region "$GCP_REGION" \
    --project "$GCP_PROJECT" \
    --allow-unauthenticated \
    --port 8080 \
    --memory 256Mi \
    --cpu 1 \
    --min-instances 0 \
    --max-instances 3 \
    --quiet
  ok "Quote Service deploy 完成"
}

# ─────────────────────────────────────────────────────────
# Phase G:抓 URL,寫進 agent/.env
# ─────────────────────────────────────────────────────────
update_agent_env() {
  step "[G] 抓 Cloud Run URL 並更新 agent/.env"

  local url
  url=$(gcloud run services describe "$QUOTE_SERVICE" \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format='value(status.url)')
  ok "Quote Service URL: $url"

  # Smoke test 後端
  if curl -sSf -o /dev/null "${url}/api/health"; then
    ok "/api/health 正常"
  else
    warn "/api/health 沒回應 — 繼續,可能 Cloud Run 還在預熱"
  fi

  # 寫 agent/.env(若不存在 → 從 .env.example 複製;若存在 → 只更新關鍵欄位)
  if [[ ! -f "$AGENT_DIR/.env" ]]; then
    cp "$AGENT_DIR/.env.example" "$AGENT_DIR/.env"
    info "從 .env.example 建立 .env"
  fi

  # 用 portable sed 替換(macOS / Linux 都通)
  python3 - "$AGENT_DIR/.env" "$GCP_PROJECT" "$url" "$AGENT_SA_EMAIL" <<'PY'
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
  ok "agent/.env 已更新(GCP_PROJECT / QUOTE_API_URL / SERVICE_ACCOUNT)"
}

# ─────────────────────────────────────────────────────────
# Phase H:Agent 部署到 Agent Runtime
# ─────────────────────────────────────────────────────────
deploy_agent() {
  step "[H] 部署 Agent 到 Vertex AI Agent Runtime @ ${GCP_REGION}"

  cd "$AGENT_DIR"
  agents-cli install >/dev/null
  ok "依賴同步完成"

  local quote_url
  quote_url=$(gcloud run services describe "$QUOTE_SERVICE" \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format='value(status.url)')

  # --update-env-vars 是必要的:agents-cli 不會自動讀 .env 注入到 Agent Runtime
  agents-cli deploy \
    --no-confirm-project \
    --update-env-vars "QUOTE_API_URL=${quote_url},OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=NO_CONTENT"

  ok "Agent 部署完成,deployment_metadata.json 已更新"
}

# ─────────────────────────────────────────────────────────
# Phase I:遠端煙霧測試
# ─────────────────────────────────────────────────────────
smoke_test() {
  step "[I] 遠端煙霧測試"

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
summary() {
  step "[完成] 部署摘要"
  cd "$AGENT_DIR"
  local rid url
  rid=$(python3 -c "import json; print(json.load(open('deployment_metadata.json'))['remote_agent_runtime_id'])" 2>/dev/null || echo "(尚未部署)")
  url=$(gcloud run services describe "$QUOTE_SERVICE" --region "$GCP_REGION" --project "$GCP_PROJECT" --format='value(status.url)' 2>/dev/null || echo "(尚未部署)")

  cat <<SUMMARY

  ${C_GREEN}✓ Quote Service${C_RESET}: $url
  ${C_GREEN}✓ Agent Runtime${C_RESET}: $rid
  ${C_GREEN}✓ Service Account${C_RESET}: $AGENT_SA_EMAIL
  ${C_GREEN}✓ Region${C_RESET}: $GCP_REGION (Gemini 走 global endpoint)

  Console Playground:
    https://console.cloud.google.com/vertex-ai/agents/agent-engines/locations/${GCP_REGION}/agent-engines/${rid##*/}/playground?project=${GCP_PROJECT}

  Cloud Trace:
    https://console.cloud.google.com/traces/list?project=${GCP_PROJECT}

  互動測試:
    cd h-beam-quote/agent
    agents-cli run "HW300x300 多重?" --url "https://${GCP_REGION}-aiplatform.googleapis.com/v1/${rid}" --mode adk

  清掉所有資源:
    ./scripts/lab-teardown.sh

SUMMARY
}

# ─────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────
main() {
  preflight
  enable_apis
  setup_sa
  setup_artifact_registry
  ensure_go_sum
  build_image
  deploy_cloud_run
  update_agent_env
  deploy_agent
  smoke_test
  summary
}

main "$@"
