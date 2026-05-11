#!/usr/bin/env bash
# H-Beam Lab — 看部署現況
#
# 用法:
#   export GCP_PROJECT=your-project-id
#   ./scripts/lab-status.sh

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
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'
  C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_BLUE=; C_GREEN=; C_RED=; C_DIM=; C_RESET=
fi

ok()   { printf "  ${C_GREEN}✓${C_RESET} %s\n" "$*"; }
miss() { printf "  ${C_RED}✗${C_RESET} %s\n" "$*"; }
section() { printf "\n${C_BLUE}■ %s${C_RESET}\n" "$*"; }

printf "${C_DIM}Project: %s   Region: %s${C_RESET}\n" "$GCP_PROJECT" "$GCP_REGION"

# ─────────────────────────────────────────────────────────
# API 啟用狀態
# ─────────────────────────────────────────────────────────
section "API 啟用狀態"
enabled=$(gcloud services list --enabled --project="$GCP_PROJECT" \
  --format='value(config.name)' 2>/dev/null || true)
for api in run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com \
           aiplatform.googleapis.com cloudtrace.googleapis.com logging.googleapis.com \
           monitoring.googleapis.com telemetry.googleapis.com; do
  if printf '%s\n' "$enabled" | grep -qx "$api"; then
    ok "$api"
  else
    miss "$api(尚未啟用)"
  fi
done

# ─────────────────────────────────────────────────────────
# Service Account
# ─────────────────────────────────────────────────────────
section "Agent Service Account"
if gcloud iam service-accounts describe "$AGENT_SA_EMAIL" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  ok "$AGENT_SA_EMAIL"
  policy=$(gcloud projects get-iam-policy "$GCP_PROJECT" --format=json 2>/dev/null)
  for role in roles/cloudtrace.agent roles/logging.logWriter roles/monitoring.metricWriter \
              roles/serviceusage.serviceUsageConsumer roles/aiplatform.user; do
    if echo "$policy" | python3 -c "
import json, sys
p = json.load(sys.stdin)
sa = 'serviceAccount:$AGENT_SA_EMAIL'
role = '$role'
for b in p.get('bindings', []):
    if b['role'] == role and sa in b.get('members', []):
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
      ok "  bound: $role"
    else
      miss "  missing: $role"
    fi
  done
else
  miss "Service Account 不存在"
fi

# ─────────────────────────────────────────────────────────
# Image Source(GHCR pre-built 或 Artifact Registry build)
# ─────────────────────────────────────────────────────────
section "Image Source"
if gcloud artifacts repositories describe "$QUOTE_REPO" \
     --location="$GCP_REGION" --project="$GCP_PROJECT" >/dev/null 2>&1; then
  ok "Artifact Registry repo: $QUOTE_REPO @ $GCP_REGION(BUILD_LOCAL=true 模式)"
  count=$(gcloud artifacts docker images list \
    "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT}/${QUOTE_REPO}/${QUOTE_SERVICE}" \
    --format='value(IMAGE)' 2>/dev/null | wc -l | tr -d ' ')
  ok "  images: $count"
else
  ok "AR repo 不存在 → 預設使用 GHCR pre-built image"
  printf "  ${C_DIM}(預設 BUILD_LOCAL=false,Cloud Run 直接拉 ghcr.io/...)${C_RESET}\n"
fi

# ─────────────────────────────────────────────────────────
# Cloud Run Quote Service
# ─────────────────────────────────────────────────────────
section "Cloud Run Quote Service"
if url=$(gcloud run services describe "$QUOTE_SERVICE" --region="$GCP_REGION" \
       --project="$GCP_PROJECT" --format='value(status.url)' 2>/dev/null) && [[ -n "$url" ]]; then
  ok "$url"
  # 顯示實際部署的 image
  deployed_image=$(gcloud run services describe "$QUOTE_SERVICE" --region="$GCP_REGION" \
    --project="$GCP_PROJECT" --format='value(spec.template.spec.containers[0].image)' 2>/dev/null)
  if [[ -n "$deployed_image" ]]; then
    ok "  image: $deployed_image"
  fi
  if curl -sSf -o /dev/null "$url/api/health"; then
    ok "  /api/health → 200 OK"
  else
    miss "  /api/health 沒回應"
  fi
else
  miss "Cloud Run service 不存在"
fi

# ─────────────────────────────────────────────────────────
# Agent Runtime
# ─────────────────────────────────────────────────────────
section "Vertex AI Agent Runtime"
md="$AGENT_DIR/deployment_metadata.json"
if [[ -f "$md" ]]; then
  rid=$(python3 -c "import json; print(json.load(open('$md')).get('remote_agent_runtime_id',''))")
  if [[ -n "$rid" && "$rid" != "None" ]]; then
    ok "$rid"
    short_id="${rid##*/}"
    printf "  ${C_DIM}Console:${C_RESET} https://console.cloud.google.com/vertex-ai/agents/agent-engines/locations/${GCP_REGION}/agent-engines/${short_id}/playground?project=${GCP_PROJECT}\n"
  else
    miss "deployment_metadata.json 沒有 remote_agent_runtime_id"
  fi
else
  miss "agent/deployment_metadata.json 不存在"
fi
