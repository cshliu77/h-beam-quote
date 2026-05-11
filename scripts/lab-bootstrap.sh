#!/usr/bin/env bash
# H-Beam Lab — One-shot 部署(Quote Service + Agent 兩個都跑)
#
# 等同依序執行:
#   ./scripts/deploy-service.sh     # 部署 Quote Service 到 Cloud Run
#   ./scripts/deploy-agent.sh        # 部署 ADK Agent 到 Agent Runtime
#
# 若只想部署其中一個,直接跑對應的腳本。
#
# 用法:
#   export GCP_PROJECT=your-project-id
#   ./scripts/lab-bootstrap.sh
#
# 環境變數(全部 optional,各 sub-script 也支援):
#   GCP_REGION      預設 asia-east1
#   H_BEAM_IMAGE    預設 ghcr.io/cshliu77/h-beam-quote:latest
#   BUILD_LOCAL     預設 false(true 時走 Cloud Build → AR)
#   QUOTE_API_URL   若已有別處後端,跳過 Cloud Run 部署(本腳本仍會跑 deploy-service)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 顯示一下 banner(共享變數會在子腳本內透過 _lib.sh 解析,這邊只用最少)
: "${GCP_PROJECT:?需要設 GCP_PROJECT 環境變數,例:export GCP_PROJECT=your-project-id}"
echo
echo "════════════════════════════════════════════════════════════"
echo "  H-Beam Lab One-shot Bootstrap"
echo "  Project: ${GCP_PROJECT}   Region: ${GCP_REGION:-asia-east1}"
echo "  Mode:    ${BUILD_LOCAL:-false} (BUILD_LOCAL — true=Cloud Build, false=GHCR proxy)"
echo "════════════════════════════════════════════════════════════"

# Step 1:Quote Service
"${SCRIPT_DIR}/deploy-service.sh"

# Step 2:Agent
"${SCRIPT_DIR}/deploy-agent.sh"

echo
echo "════════════════════════════════════════════════════════════"
echo "  ✓ One-shot 部署完成"
echo "════════════════════════════════════════════════════════════"
echo
echo "查狀態:./scripts/lab-status.sh"
echo "清資源:./scripts/lab-teardown.sh --yes"
