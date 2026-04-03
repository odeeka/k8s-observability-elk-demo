#!/usr/bin/env bash
# =============================================================================
#  kibana-setup.sh  –  Automate initial Kibana configuration via REST API
#
#  Creates:
#    - Data view  "logs-*"  (time field: @timestamp)
#
#  Run this script AFTER logs have started flowing into Elasticsearch
#  (i.e. after running generate-traffic.sh for at least ~30 seconds).
# =============================================================================
set -euo pipefail

KIBANA="http://localhost:5601"
ES="http://localhost:9200"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Wait for Kibana API ───────────────────────────────────────────────────────
wait_for_kibana() {
  info "Waiting for Kibana to be available at ${KIBANA}…"
  local retries=30
  for (( i=1; i<=retries; i++ )); do
    status=$(curl -s -o /dev/null -w "%{http_code}" "${KIBANA}/api/status" 2>/dev/null || true)
    if [[ "$status" == "200" ]]; then
      info "Kibana is up."
      return 0
    fi
    echo -ne "  Attempt ${i}/${retries}… (HTTP ${status})\r"
    sleep 5
  done
  error "Kibana did not become available in time."
  exit 1
}

# ── Check Elasticsearch indices ───────────────────────────────────────────────
check_indices() {
  info "Checking for logs-* indices in Elasticsearch…"
  status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:9200/logs-*" 2>/dev/null || true)
  if [[ "$status" != "200" ]]; then
    warn "No logs-* indices found yet. Run ./scripts/generate-traffic.sh first."
    warn "Continuing anyway – the data view can be created before data arrives."
  else
    info "Found logs-* indices."
  fi
}

# ── Create data view ──────────────────────────────────────────────────────────
create_data_view() {
  info "Creating Kibana data view 'logs-*'…"

  response=$(curl -s -w "\n%{http_code}" \
    -X POST "${KIBANA}/api/data_views/data_view" \
    -H "Content-Type: application/json" \
    -H "kbn-xsrf: true" \
    -d '{
          "data_view": {
            "title":      "logs-*",
            "name":       "Observability Logs",
            "timeFieldName": "@timestamp"
          }
        }')

  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | head -n -1)

  if [[ "$http_code" == "200" ]]; then
    info "Data view created successfully."
    VIEW_ID=$(echo "$body" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    info "Data view ID: ${VIEW_ID}"
    info "Open Kibana Discover: ${KIBANA}/app/discover"
  elif [[ "$http_code" == "409" ]]; then
    warn "Data view 'logs-*' already exists."
  else
    error "Failed to create data view (HTTP ${http_code}):"
    echo "$body"
    exit 1
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
wait_for_kibana
check_indices
create_data_view

echo ""
echo "════════════════════════════════════════════"
echo "  Kibana setup complete!"
echo "  Open: ${KIBANA}/app/discover"
echo "════════════════════════════════════════════"
