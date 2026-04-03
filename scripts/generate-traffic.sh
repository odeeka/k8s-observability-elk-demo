#!/usr/bin/env bash
# =============================================================================
#  generate-traffic.sh  –  Send a realistic mix of requests to both services
#
#  Usage:
#    ./scripts/generate-traffic.sh [COUNT] [--continuous]
#
#  Examples:
#    ./scripts/generate-traffic.sh          # 50 request rounds (default)
#    ./scripts/generate-traffic.sh 200      # 200 rounds
#    ./scripts/generate-traffic.sh --continuous   # loop forever (Ctrl-C to stop)
# =============================================================================
set -euo pipefail

USER_SVC="http://localhost:3001"
PAY_SVC="http://localhost:8001"

COUNT=50
CONTINUOUS=false

for arg in "$@"; do
  case "$arg" in
    --continuous) CONTINUOUS=true ;;
    [0-9]*)       COUNT="$arg" ;;
  esac
done

# Portable UUID generation
gen_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

request() {
  local method="$1" url="$2" body="${3:-}"
  local rid; rid="$(gen_uuid)"
  if [[ -n "$body" ]]; then
    curl -s -o /dev/null \
      -X "$method" \
      -H "Content-Type: application/json" \
      -H "X-Request-ID: $rid" \
      -d "$body" \
      "$url"
  else
    curl -s -o /dev/null \
      -X "$method" \
      -H "X-Request-ID: $rid" \
      "$url"
  fi
}

run_round() {
  local i="$1"

  # ── user-service ──────────────────────────────────────────────────────────
  request GET "${USER_SVC}/users"
  request GET "${USER_SVC}/users/1"
  request GET "${USER_SVC}/users/2"
  request GET "${USER_SVC}/users/999"       # 404 – warn log

  # Trigger hard error every 7th round
  if (( i % 7 == 0 )); then
    request GET "${USER_SVC}/error"
  fi

  # ── payment-service ───────────────────────────────────────────────────────
  request GET  "${PAY_SVC}/payments"

  # POST payments with various payloads (30 % will fail inside the service)
  request POST "${PAY_SVC}/payments" '{"userId":1,"amount":99.99,"currency":"USD"}'
  request POST "${PAY_SVC}/payments" '{"userId":2,"amount":49.50,"currency":"EUR"}'
  request POST "${PAY_SVC}/payments" '{"userId":3,"amount":199.00,"currency":"GBP"}'

  request GET  "${PAY_SVC}/payments/pay-0001"
  request GET  "${PAY_SVC}/payments/pay-9999"   # 404 – warn log

  # Trigger hard error every 5th round
  if (( i % 5 == 0 )); then
    request GET "${PAY_SVC}/error"
  fi
}

echo "▶ Sending traffic to:"
echo "    user-service    → ${USER_SVC}"
echo "    payment-service → ${PAY_SVC}"
echo ""

if $CONTINUOUS; then
  echo "Running continuously until Ctrl-C…"
  i=1
  while true; do
    run_round "$i"
    echo -ne "\r  Round ${i} sent…"
    sleep 0.2
    (( i++ ))
  done
else
  echo "Running ${COUNT} rounds…"
  for (( i=1; i<=COUNT; i++ )); do
    run_round "$i"
    echo -ne "\r  Progress: ${i}/${COUNT}"
    sleep 0.1
  done
  echo ""
  echo "✓ Done. Check Kibana at http://localhost:5601"
fi
