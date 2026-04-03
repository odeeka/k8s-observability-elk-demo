#!/usr/bin/env bash
# =============================================================================
#  setup.sh  –  Bootstrap the complete observability demo environment
#
#  What this script does:
#    1. Checks prerequisites (kind, kubectl, docker)
#    2. Creates a KIND cluster
#    3. Builds Docker images for both microservices
#    4. Loads the images into KIND (no registry needed)
#    5. Deploys all Kubernetes resources in dependency order
#    6. Waits for readiness and prints access information
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="observability-demo"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${BLUE}▶${NC} $*"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
check_prerequisites() {
  step "Checking prerequisites…"
  local missing=()
  for tool in kind kubectl docker; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing tools: ${missing[*]}"
    error "Install them and re-run this script."
    exit 1
  fi

  if ! docker info &>/dev/null; then
    error "Docker daemon is not running. Please start Docker and retry."
    exit 1
  fi
  info "All prerequisites satisfied."
}

# ── KIND cluster ──────────────────────────────────────────────────────────────
create_cluster() {
  step "Creating KIND cluster '${CLUSTER_NAME}'…"

  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    warn "Cluster '${CLUSTER_NAME}' already exists – skipping creation."
  else
    kind create cluster --config "${PROJECT_DIR}/kind/kind-config.yaml"
    info "Cluster created."
  fi

  kubectl config use-context "kind-${CLUSTER_NAME}"
  kubectl cluster-info --context "kind-${CLUSTER_NAME}"
}

# ── Docker images ─────────────────────────────────────────────────────────────
build_and_load_images() {
  step "Building Docker images…"

  docker build -t user-service:latest    "${PROJECT_DIR}/services/user-service/"
  info "Built user-service:latest"

  docker build -t payment-service:latest "${PROJECT_DIR}/services/payment-service/"
  info "Built payment-service:latest"

  step "Loading images into KIND (no registry required)…"
  kind load docker-image user-service:latest    --name "${CLUSTER_NAME}"
  kind load docker-image payment-service:latest --name "${CLUSTER_NAME}"
  info "Images loaded."
}

# ── Kubernetes resources ───────────────────────────────────────────────────────
deploy_resources() {
  step "Creating namespaces…"
  kubectl apply -f "${PROJECT_DIR}/k8s/namespace.yaml"

  # ── Elasticsearch ──
  step "Deploying Elasticsearch…"
  kubectl apply -f "${PROJECT_DIR}/k8s/elasticsearch/"

  info "Waiting for Elasticsearch (up to 3 min – JVM start-up is slow)…"
  kubectl rollout status deployment/elasticsearch \
    -n observability --timeout=180s
  info "Elasticsearch is ready."

  # ── Create index template (correct field mappings) ──
  step "Configuring Elasticsearch index template for logs-*…"
  kubectl -n observability exec deployment/elasticsearch -- \
    curl -s -o /dev/null -w "%{http_code}" \
         -X PUT "http://localhost:9200/_index_template/logs-template" \
         -H "Content-Type: application/json" \
         -d '{
               "index_patterns": ["logs-*"],
               "template": {
                 "settings": {
                   "number_of_shards": 1,
                   "number_of_replicas": 0,
                   "refresh_interval": "5s"
                 },
                 "mappings": {
                   "properties": {
                     "@timestamp":  { "type": "date" },
                     "timestamp":   { "type": "date" },
                     "level":       { "type": "keyword" },
                     "service":     { "type": "keyword" },
                     "message":     { "type": "text", "fields": { "keyword": { "type": "keyword" } } },
                     "requestId":   { "type": "keyword" },
                     "errorCode":   { "type": "keyword" },
                     "statusCode":  { "type": "integer" },
                     "durationMs":  { "type": "long" },
                     "latencyMs":   { "type": "long" },
                     "amount":      { "type": "float" },
                     "userId":      { "type": "integer" }
                   }
                 }
               }
             }' | grep -q "200" && info "Index template created." || warn "Index template may already exist – continuing."

  # ── Kibana ──
  step "Deploying Kibana…"
  kubectl apply -f "${PROJECT_DIR}/k8s/kibana/"

  # ── Fluent Bit ──
  step "Deploying Fluent Bit DaemonSet…"
  kubectl apply -f "${PROJECT_DIR}/k8s/fluent-bit/"

  # ── Microservices ──
  step "Deploying microservices…"
  kubectl apply -f "${PROJECT_DIR}/k8s/user-service/"
  kubectl apply -f "${PROJECT_DIR}/k8s/payment-service/"

  # ── Wait for everything ──
  step "Waiting for remaining deployments…"
  kubectl rollout status deployment/kibana          -n observability --timeout=240s
  kubectl rollout status deployment/user-service    -n apps          --timeout=90s
  kubectl rollout status deployment/payment-service -n apps          --timeout=90s

  info "All deployments are ready."
}

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║     Setup complete!                      ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo "  Service          │ URL"
  echo "  ─────────────────┼─────────────────────────────"
  echo "  Kibana           │ http://localhost:5601"
  echo "  user-service     │ http://localhost:3001"
  echo "  payment-service  │ http://localhost:8001"
  echo ""
  echo "  Quick-start:"
  echo "    # Generate traffic"
  echo "    ./scripts/generate-traffic.sh"
  echo ""
  echo "    # Create Kibana data view (run once after first logs arrive)"
  echo "    ./scripts/kibana-setup.sh"
  echo ""
  echo "  Useful commands:"
  echo "    kubectl get pods -A"
  echo "    kubectl logs -n observability -l app=fluent-bit -f"
  echo "    kubectl logs -n apps -l app=payment-service -f"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  cd "${PROJECT_DIR}"
  check_prerequisites
  create_cluster
  build_and_load_images
  deploy_resources
  print_summary
}

main "$@"
