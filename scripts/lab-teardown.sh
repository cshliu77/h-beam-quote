#!/usr/bin/env bash
# H-Beam Lab — 清掉所有部署資源
#
# 反向清除:Agent Engine → Cloud Run → Artifact Registry images → SA
# 不關 GCP API(可能其他專案在用)
# 不刪 staging bucket(我們本來就沒建,inline 模式不需要)
#
# 用法:
#   export GCP_PROJECT=your-project-id
#   ./scripts/lab-teardown.sh
#   ./scripts/lab-teardown.sh --yes      # 跳過確認

set -euo pipefail

: "${GCP_PROJECT:?需要設 GCP_PROJECT}"
GCP_REGION="${GCP_REGION:-asia-east1}"
QUOTE_SERVICE="${QUOTE_SERVICE:-h-beam-quote}"
QUOTE_REPO="${QUOTE_REPO:-h-beam-images}"
AGENT_SA_NAME="${AGENT_SA_NAME:-h-beam-agent}"
AGENT_SA_EMAIL="${AGENT_SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_DIR="${REPO_ROOT}/agent"

if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=; C_DIM=; C_RESET=
fi
step() { printf "\n${C_BLUE}▶ %s${C_RESET}\n" "$*"; }
ok()   { printf "${C_GREEN}✓ %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}⚠ %s${C_RESET}\n" "$*"; }
info() { printf "${C_DIM}  %s${C_RESET}\n" "$*"; }

YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=true

# ─────────────────────────────────────────────────────────
# 確認
# ─────────────────────────────────────────────────────────
confirm() {
  cat <<EOF
${C_YELLOW}即將從專案 ${GCP_PROJECT} (${GCP_REGION}) 刪除以下資源:${C_RESET}

  • Agent Engine 實例(deployment_metadata.json 內列出的)
  • Cloud Run service:    ${QUOTE_SERVICE}
  • Artifact Registry:    ${QUOTE_REPO} 內的所有 images
  • Service Account:      ${AGENT_SA_EMAIL}

${C_DIM}保留:GCP API 啟用狀態(避免影響其他專案)${C_RESET}

EOF
  if ! $YES; then
    read -rp "確認刪除?(打 yes 確認):" answer
    [[ "$answer" == "yes" ]] || { warn "取消"; exit 0; }
  fi
}

# ─────────────────────────────────────────────────────────
# 1. 刪 Agent Engine
# ─────────────────────────────────────────────────────────
delete_agent_engine() {
  step "[1] 刪除 Agent Engine 實例"

  local md="$AGENT_DIR/deployment_metadata.json"
  if [[ ! -f "$md" ]]; then
    info "找不到 deployment_metadata.json,跳過"
    return
  fi

  local rid
  rid=$(python3 -c "import json; print(json.load(open('$md')).get('remote_agent_runtime_id',''))")
  if [[ -z "$rid" ]]; then
    info "deployment_metadata.json 沒有 remote_agent_runtime_id,跳過"
    return
  fi
  info "Agent: $rid"

  if gcloud auth print-access-token >/dev/null 2>&1; then
    local token
    token=$(gcloud auth print-access-token)
    local short_id="${rid##*/}"
    local api="https://${GCP_REGION}-aiplatform.googleapis.com/v1/${rid}?force=true"
    if curl -sSf -X DELETE -H "Authorization: Bearer $token" "$api" >/dev/null; then
      ok "Agent Engine 已刪除"
    else
      warn "刪除可能失敗(資源可能已不存在)"
    fi
  fi

  # 重置 deployment_metadata.json
  python3 - "$md" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
d["remote_agent_runtime_id"] = "None"
d["deployment_timestamp"] = "None"
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PY
  ok "deployment_metadata.json 已重置"
}

# ─────────────────────────────────────────────────────────
# 2. 刪 Cloud Run
# ─────────────────────────────────────────────────────────
delete_cloud_run() {
  step "[2] 刪除 Cloud Run service"

  if gcloud run services describe "$QUOTE_SERVICE" \
       --region "$GCP_REGION" --project "$GCP_PROJECT" >/dev/null 2>&1; then
    gcloud run services delete "$QUOTE_SERVICE" \
      --region "$GCP_REGION" --project "$GCP_PROJECT" --quiet
    ok "Cloud Run service ${QUOTE_SERVICE} 已刪除"
  else
    info "Cloud Run service 不存在,跳過"
  fi
}

# ─────────────────────────────────────────────────────────
# 3. 刪 Artifact Registry repo(連 images 一起)
# 注意:預設 GHCR 模式不會建這個 repo,delete 會跳過
# ─────────────────────────────────────────────────────────
delete_artifact_registry() {
  step "[3] 刪除 Artifact Registry repo(連 images)"

  if gcloud artifacts repositories describe "$QUOTE_REPO" \
       --location="$GCP_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
    gcloud artifacts repositories delete "$QUOTE_REPO" \
      --location="$GCP_REGION" --project="$GCP_PROJECT" --quiet
    ok "Artifact Registry repo ${QUOTE_REPO} 已刪除"
  else
    info "AR repo 不存在(預設 GHCR 模式不需建,跳過)"
  fi
}

# ─────────────────────────────────────────────────────────
# 4. 刪 SA + 解綁 IAM 角色
# ─────────────────────────────────────────────────────────
delete_sa() {
  step "[4] 刪除 Service Account 與 IAM 綁定"

  if ! gcloud iam service-accounts describe "$AGENT_SA_EMAIL" \
       --project="$GCP_PROJECT" >/dev/null 2>&1; then
    info "SA 不存在,跳過"
    return
  fi

  local roles=(
    roles/cloudtrace.agent
    roles/logging.logWriter
    roles/monitoring.metricWriter
    roles/serviceusage.serviceUsageConsumer
    roles/aiplatform.user
  )
  for role in "${roles[@]}"; do
    gcloud projects remove-iam-policy-binding "$GCP_PROJECT" \
      --member="serviceAccount:${AGENT_SA_EMAIL}" \
      --role="$role" --condition=None --quiet >/dev/null 2>&1 || true
    info "  ✓ unbind $role"
  done

  gcloud iam service-accounts delete "$AGENT_SA_EMAIL" \
    --project="$GCP_PROJECT" --quiet
  ok "SA ${AGENT_SA_EMAIL} 已刪除"
}

# ─────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────
main() {
  confirm
  delete_agent_engine
  delete_cloud_run
  delete_artifact_registry
  delete_sa

  printf "\n${C_GREEN}✓ Lab 環境已清空${C_RESET}\n"
  printf "${C_DIM}  (GCP API 保留啟用狀態;若要關閉自行 gcloud services disable)${C_RESET}\n"
}

main "$@"
