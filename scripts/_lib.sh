# Shared helpers + 變數 — 由 deploy-service.sh / deploy-agent.sh / lab-bootstrap.sh source
# 用法:source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ─────────────────────────────────────────────────────────
# 共享變數預設值(env override 友善)
# ─────────────────────────────────────────────────────────
: "${GCP_PROJECT:?需要設 GCP_PROJECT 環境變數,例:export GCP_PROJECT=your-project-id}"
GCP_REGION="${GCP_REGION:-asia-east1}"
QUOTE_SERVICE="${QUOTE_SERVICE:-h-beam-quote}"
QUOTE_REPO="${QUOTE_REPO:-h-beam-images}"           # BUILD_LOCAL=true 用的 standard repo
GHCR_PROXY_REPO="${GHCR_PROXY_REPO:-h-beam-ghcr-proxy}" # BUILD_LOCAL=false 用的 remote proxy repo
AGENT_SA_NAME="${AGENT_SA_NAME:-h-beam-agent}"
AGENT_SA_EMAIL="${AGENT_SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"

# Image 來源
H_BEAM_IMAGE="${H_BEAM_IMAGE:-ghcr.io/cshliu77/h-beam-quote:latest}"
BUILD_LOCAL="${BUILD_LOCAL:-false}"

# 計算 DEPLOY_IMAGE(Cloud Run 實際拉的 URL)
AR_IMAGE_URI="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${QUOTE_REPO}/${QUOTE_SERVICE}:latest"
if [[ "$BUILD_LOCAL" == "true" ]]; then
  DEPLOY_IMAGE="$AR_IMAGE_URI"
else
  if [[ "$H_BEAM_IMAGE" != ghcr.io/* ]]; then
    echo "ERROR: H_BEAM_IMAGE 必須以 ghcr.io/ 開頭(BUILD_LOCAL=false 模式):$H_BEAM_IMAGE" >&2
    exit 1
  fi
  GHCR_PATH="${H_BEAM_IMAGE#ghcr.io/}"
  DEPLOY_IMAGE="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${GHCR_PROXY_REPO}/${GHCR_PATH}"
fi

# 路徑(以 scripts/ 的父層為 repo root)
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
# 共用 preflight:gcloud 存在 + project 可見 + 鎖 ADC quota project
# 各 deploy 腳本另外加自己的 CLI 檢查(uv / agents-cli 等)
# ─────────────────────────────────────────────────────────
preflight_gcloud() {
  step "[Preflight] gcloud + GCP 專案"
  if ! command -v gcloud >/dev/null 2>&1; then
    err "缺工具:gcloud(到 https://cloud.google.com/sdk/docs/install 安裝)"
    exit 1
  fi
  if ! gcloud projects describe "$GCP_PROJECT" >/dev/null 2>&1; then
    err "看不到 GCP 專案 $GCP_PROJECT — 用 gcloud projects list 確認 Project ID"
    info "注意:GCP_PROJECT 是 Project ID(小寫+連字號),不是 Display Name"
    exit 1
  fi
  ok "專案可見:$GCP_PROJECT"
  gcloud config set project "$GCP_PROJECT" >/dev/null 2>&1
  gcloud auth application-default set-quota-project "$GCP_PROJECT" >/dev/null 2>&1 || true
  ok "current project / ADC quota project = $GCP_PROJECT"
}
