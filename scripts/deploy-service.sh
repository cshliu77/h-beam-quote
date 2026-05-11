#!/usr/bin/env bash
# H-Beam Lab — 只部署 Quote Service 到 Cloud Run
#
# 用途:學員想自己開發 Agent → 跑這支起後端;Agent 部署不在此腳本範圍。
#
# 用法(預設 — 用 GHCR pre-built image):
#   export GCP_PROJECT=your-project-id
#   ./scripts/deploy-service.sh
#
# 用法(escape hatch — 自己 build Go 程式碼):
#   BUILD_LOCAL=true ./scripts/deploy-service.sh
#
# 用法(鎖版):
#   H_BEAM_IMAGE=ghcr.io/cshliu77/h-beam-quote:v0.1.0 ./scripts/deploy-service.sh

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ─────────────────────────────────────────────────────────
# Preflight + Quote Service 環境概覽
# ─────────────────────────────────────────────────────────
preflight_gcloud
info "區域:           $GCP_REGION"
info "Quote Service:   $QUOTE_SERVICE"
if [[ "$BUILD_LOCAL" == "true" ]]; then
  info "模式:           BUILD_LOCAL=true(Cloud Build → AR)"
  info "Image:          $AR_IMAGE_URI"
else
  info "模式:           GHCR pre-built(透過 AR remote repo 代理)"
  info "上游 image:      $H_BEAM_IMAGE"
  info "Cloud Run 拉取:  $DEPLOY_IMAGE"
fi

# ─────────────────────────────────────────────────────────
# Phase A:啟用 Cloud Run / Cloud Build / Artifact Registry API
# ─────────────────────────────────────────────────────────
enable_service_apis() {
  step "[A] 啟用必要 API(run / cloudbuild / artifactregistry)"
  gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    --project="$GCP_PROJECT" --quiet
  ok "3 個 API 已啟用"
}

# ─────────────────────────────────────────────────────────
# Phase B:Artifact Registry
#   BUILD_LOCAL=true  → standard repo
#   BUILD_LOCAL=false → remote repo 代理 GHCR
# ─────────────────────────────────────────────────────────
setup_artifact_registry() {
  if [[ "$BUILD_LOCAL" == "true" ]]; then
    step "[B] 確保 Artifact Registry standard repo 存在(${QUOTE_REPO} @ ${GCP_REGION})"
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
    step "[B] 確保 Artifact Registry GHCR proxy repo 存在(${GHCR_PROXY_REPO} @ ${GCP_REGION})"
    info "(Cloud Run 不能直拉 ghcr.io,用 AR remote repo 透明代理)"
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
      ok "GHCR proxy repo 已建立"
    fi
  fi
}

# ─────────────────────────────────────────────────────────
# Phase C:確保 go.sum 存在(僅 BUILD_LOCAL=true)
# ─────────────────────────────────────────────────────────
ensure_go_sum() {
  if [[ "$BUILD_LOCAL" != "true" ]]; then
    step "[C] 跳過 go.sum 檢查(GHCR 模式不需本機編譯)"
    return
  fi
  step "[C] 確保 ${QUOTE_DIR}/go.sum 存在"

  if [[ -f "$QUOTE_DIR/go.sum" ]]; then
    info "go.sum 已存在"
    return
  fi

  if ! command -v go >/dev/null 2>&1; then
    err "缺 go.sum,但本機沒有 go(Cloud Build COPY go.sum* 無檔會 error)"
    info "解法 1:本機裝 go 1.22+ 後再跑(會自動 go mod tidy)"
    info "解法 2:乾脆走 GHCR pre-built(不要設 BUILD_LOCAL=true)"
    exit 1
  fi
  (cd "$QUOTE_DIR" && go mod tidy)
  ok "go.sum 已產出"
}

# ─────────────────────────────────────────────────────────
# Phase D:Cloud Build(僅 BUILD_LOCAL=true)
# ─────────────────────────────────────────────────────────
build_image() {
  if [[ "$BUILD_LOCAL" != "true" ]]; then
    step "[D] 跳過 Cloud Build(用 GHCR pre-built image)"
    return
  fi
  step "[D] Cloud Build 編譯 Quote Service image"
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
# Phase E:Deploy Cloud Run
# ─────────────────────────────────────────────────────────
deploy_cloud_run() {
  step "[E] 部署 Quote Service 到 Cloud Run @ ${GCP_REGION}"
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
# Phase F:Smoke test
# ─────────────────────────────────────────────────────────
smoke_test_service() {
  step "[F] 後端 API 煙霧測試"
  local url
  url=$(gcloud run services describe "$QUOTE_SERVICE" \
    --region "$GCP_REGION" --project "$GCP_PROJECT" \
    --format='value(status.url)')

  if curl -sSf -o /dev/null "${url}/api/health"; then
    ok "/api/health → 200"
  else
    warn "/api/health 沒回應(可能 Cloud Run 還在預熱,30 秒後再試)"
  fi

  if curl -sSf -X POST "${url}/api/quotes" \
       -H "Content-Type: application/json" \
       -d '{"items":[{"product_code":"HW300x300","grade":"SS400","length_m":6,"quantity":20}]}' \
       2>/dev/null | grep -q '"final_total_ntd":321480'; then
    ok "計算 API 回 NT\$ 321,480(預期值)"
  else
    warn "計算 API 沒回預期值"
  fi
}

# ─────────────────────────────────────────────────────────
# 摘要
# ─────────────────────────────────────────────────────────
summary_service() {
  step "[完成] Quote Service 部署摘要"
  local url
  url=$(gcloud run services describe "$QUOTE_SERVICE" --region "$GCP_REGION" \
    --project "$GCP_PROJECT" --format='value(status.url)' 2>/dev/null || echo "(尚未部署)")

  cat <<SUMMARY

  ${C_GREEN}✓ Quote Service URL${C_RESET}: $url
  ${C_GREEN}✓ Region${C_RESET}: $GCP_REGION
  ${C_GREEN}✓ Image${C_RESET}: $DEPLOY_IMAGE

  後續可選:
    1. 自己寫 Agent 接 $url 做開發
    2. 或部署 Lab 內建 Agent:
       export QUOTE_API_URL="$url"
       ./scripts/deploy-agent.sh

SUMMARY
}

main() {
  enable_service_apis
  setup_artifact_registry
  ensure_go_sum
  build_image
  deploy_cloud_run
  smoke_test_service
  summary_service
}

main "$@"
