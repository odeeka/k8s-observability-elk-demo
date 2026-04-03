# K8s Observability – ELK Stack Demo

A production-like, fully local Kubernetes observability demo using **KIND**, **Fluent Bit**, **Elasticsearch**, and **Kibana**.  
Two Node.js microservices produce structured JSON logs that are automatically collected, enriched with pod metadata, stored in Elasticsearch, and visualised in Kibana.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Project Structure](#project-structure)
4. [Step-by-Step Setup](#step-by-step-setup)
5. [Logging Flow](#logging-flow)
6. [Accessing the Services](#accessing-the-services)
7. [Simulating Errors & Load](#simulating-errors--load)
8. [Querying Logs in Kibana](#querying-logs-in-kibana)
9. [Cleanup](#cleanup)
10. [Troubleshooting](#troubleshooting)
11. [Resource Requirements](#resource-requirements)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────┐
│                        KIND Cluster (single node)                    │
│                                                                      │
│   Namespace: apps                                                    │
│   ┌─────────────────────┐    ┌─────────────────────────────────┐    │
│   │    user-service      │    │        payment-service          │    │
│   │  (2 replicas)        │    │       (2 replicas, 30% fail)    │    │
│   │  GET /users          │    │  GET  /payments                 │    │
│   │  GET /users/:id      │    │  POST /payments (+ latency)     │    │
│   │  GET /error          │    │  GET  /error                    │    │
│   └──────────┬───────────┘    └───────────────┬─────────────────┘    │
│              │ stdout JSON logs               │                      │
│              └──────────────┬─────────────────┘                      │
│                             │ /var/log/containers/*.log              │
│   Namespace: observability  ▼                                        │
│   ┌──────────────────────────────────────┐                          │
│   │         Fluent Bit (DaemonSet)        │                          │
│   │  • Tail container log files           │                          │
│   │  • Parse CRI format                   │                          │
│   │  • Merge JSON log body                │                          │
│   │  • Enrich: pod_name, namespace,       │                          │
│   │            container_name, cluster    │                          │
│   └──────────────────┬───────────────────┘                          │
│                      │ enriched JSON documents                       │
│                      ▼                                               │
│   ┌───────────────────────────────────────┐                         │
│   │   Elasticsearch 8.11 (single node)    │                         │
│   │   Index pattern: logs-YYYY.MM.DD      │                         │
│   └──────────────────┬────────────────────┘                         │
│                      │ REST API                                      │
│                      ▼                                               │
│   ┌───────────────────────────────────────┐                         │
│   │         Kibana 8.11                   │                         │
│   │   NodePort 30561 → localhost:5601     │                         │
│   └───────────────────────────────────────┘                         │
│                                                                      │
│   Host port mappings (KIND extraPortMappings):                       │
│     localhost:5601  →  Kibana          (NodePort 30561)              │
│     localhost:3001  →  user-service    (NodePort 30001)              │
│     localhost:8001  →  payment-service (NodePort 30002)              │
└──────────────────────────────────────────────────────────────────────┘
```

### Component summary

| Component | Role |
|-----------|------|
| **user-service** | Exposes user CRUD endpoints, logs structured JSON to stdout |
| **payment-service** | Processes payments, simulates 30 % failures and up to 800 ms latency |
| **Fluent Bit** | DaemonSet that tails pod logs, parses CRI format, enriches with K8s metadata, ships to ES |
| **Elasticsearch** | Single-node storage; daily indices `logs-YYYY.MM.DD`; security disabled |
| **Kibana** | UI for exploring, querying, and dashboarding the logs |

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Docker | 20.10+ | https://docs.docker.com/get-docker/ |
| KIND | 0.20+ | `go install sigs.k8s.io/kind@latest` or brew |
| kubectl | 1.27+ | https://kubernetes.io/docs/tasks/tools/ |
| curl | any | pre-installed on most systems |

> **Memory:** Elasticsearch requires at least **2 GB** available for the local machine.  
> The full stack (ES + Kibana + Fluent Bit + 2 services × 2 pods) needs roughly **3–4 GB RAM**.

---

## Project Structure

```
k8s-observability-elk-demo/
├── kind/
│   └── kind-config.yaml          # KIND cluster definition (port mappings)
│
├── services/
│   ├── user-service/
│   │   ├── Dockerfile
│   │   ├── package.json
│   │   └── src/index.js          # Express app – /users, /error
│   └── payment-service/
│       ├── Dockerfile
│       ├── package.json
│       └── src/index.js          # Express app – /payments, /error (30% fail)
│
├── k8s/
│   ├── namespace.yaml            # observability + apps namespaces
│   ├── elasticsearch/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── kibana/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   ├── fluent-bit/
│   │   ├── serviceaccount.yaml
│   │   ├── clusterrole.yaml
│   │   ├── clusterrolebinding.yaml
│   │   ├── configmap.yaml        # fluent-bit.conf + parsers.conf
│   │   └── daemonset.yaml
│   ├── user-service/
│   │   ├── deployment.yaml
│   │   └── service.yaml
│   └── payment-service/
│       ├── deployment.yaml
│       └── service.yaml
│
├── scripts/
│   ├── setup.sh                  # Full one-command bootstrap
│   ├── cleanup.sh                # Destroy cluster
│   ├── generate-traffic.sh       # Drive traffic for log generation
│   └── kibana-setup.sh          # Automate data view creation
│
├── dashboards/
│   └── kibana-queries.md         # KQL snippets + dashboard recipes
│
└── README.md
```

---

## Step-by-Step Setup

### 1 · Clone / enter the repository

```bash
cd k8s-observability-elk-demo
```

### 2 · One-command bootstrap (recommended)

```bash
chmod +x scripts/*.sh
./scripts/setup.sh
```

The script (≈ 5–8 min on first run):
1. Checks `kind`, `kubectl`, `docker`
2. Creates the KIND cluster with all port mappings
3. Builds both Docker images
4. Loads images directly into KIND (no registry needed)
5. Deploys Elasticsearch and waits for it to be healthy
6. Creates the `logs-*` index template with field mappings
7. Deploys Kibana, Fluent Bit, and both microservices
8. Waits for all deployments to be `Ready`

### 3 · Manual step-by-step (alternative)

```bash
# 1. Create cluster
kind create cluster --config kind/kind-config.yaml

# 2. Build images
docker build -t user-service:latest    services/user-service/
docker build -t payment-service:latest services/payment-service/

# 3. Load into KIND (skips pulling from a registry)
kind load docker-image user-service:latest    --name observability-demo
kind load docker-image payment-service:latest --name observability-demo

# 4. Deploy in order
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/elasticsearch/
kubectl rollout status deployment/elasticsearch -n observability --timeout=180s
kubectl apply -f k8s/kibana/
kubectl apply -f k8s/fluent-bit/
kubectl apply -f k8s/user-service/
kubectl apply -f k8s/payment-service/

# 5. Verify
kubectl get pods -A
```

### 4 · Verify all pods are Running

```
NAMESPACE       NAME                               READY   STATUS
apps            payment-service-xxx                1/1     Running
apps            payment-service-yyy                1/1     Running
apps            user-service-xxx                   1/1     Running
apps            user-service-yyy                   1/1     Running
observability   elasticsearch-xxx                  1/1     Running
observability   fluent-bit-xxx                     1/1     Running
observability   kibana-xxx                         1/1     Running
```

### 5 · Set up Kibana

```bash
# Generate some traffic first so indices exist
./scripts/generate-traffic.sh 20

# Then create the Kibana data view automatically
./scripts/kibana-setup.sh
```

**Or manually in the Kibana UI:**

1. Open **http://localhost:5601**
2. Navigate to **Stack Management → Data Views → Create data view**
3. Name: `Observability Logs`
4. Index pattern: `logs-*`
5. Timestamp field: `@timestamp`
6. Click **Save data view to Kibana**
7. Go to **Discover** and select your new data view

---

## Logging Flow

```
Node.js service
  process.stdout.write(JSON.stringify({ timestamp, level, service, message, ...fields }) + '\n')
      │
      │  (stdout captured by containerd)
      ▼
/var/log/containers/<pod>_<ns>_<container>-<id>.log   (CRI format on disk)
  Line: "2024-01-15T10:00:00Z stdout F {\"timestamp\":\"...\",\"level\":\"info\",...}"
      │
      │  (Fluent Bit tail INPUT reads the file)
      ▼
Fluent Bit record after CRI parser:
  { time: "2024-01-15T10:00:00Z", stream: "stdout", logtag: "F", log: "{...json...}" }
      │
      │  (kubernetes FILTER)
      │  • Calls Kubernetes API for pod metadata
      │  • Merge_Log: parses the "log" field as JSON and hoists all fields to root
      │  • Keep_Log Off: removes the raw "log" string
      │  • Adds cluster = "observability-demo"
      ▼
Final enriched document stored in Elasticsearch:
  {
    "@timestamp":   "2024-01-15T10:00:00.123Z",   ← set by Fluent Bit
    "timestamp":    "2024-01-15T10:00:00.123Z",   ← from service log
    "level":        "info",
    "service":      "payment-service",
    "message":      "payment_processed",
    "requestId":    "550e8400-…",
    "paymentId":    "pay-3f2a1b",
    "amount":       99.99,
    "durationMs":   342,
    "cluster":      "observability-demo",
    "kubernetes": {
      "pod_name":        "payment-service-7d4f…",
      "namespace_name":  "apps",
      "container_name":  "payment-service",
      "pod_id":          "…",
      "labels": { "app": "payment-service" }
    }
  }
      │
      ▼
Index: logs-2024.01.15
```

### Log fields reference

| Field | Type | Notes |
|-------|------|-------|
| `@timestamp` | date | Set by Fluent Bit from CRI log timestamp |
| `timestamp` | date | Set by the application |
| `level` | keyword | `info`, `warn`, `error` |
| `service` | keyword | `user-service` \| `payment-service` |
| `message` | text | Human-readable event name |
| `requestId` | keyword | Correlation ID (propagated via `X-Request-ID` header) |
| `method` | keyword | HTTP method (`GET`, `POST`, …) |
| `path` | keyword | Request path |
| `statusCode` | integer | HTTP response code |
| `durationMs` | long | Request duration in ms |
| `errorCode` | keyword | Error codes (e.g. `CARD_DECLINED`) |
| `kubernetes.pod_name` | keyword | Added by Fluent Bit |
| `kubernetes.namespace_name` | keyword | Added by Fluent Bit |
| `kubernetes.container_name` | keyword | Added by Fluent Bit |
| `cluster` | keyword | Always `observability-demo` |

---

## Accessing the Services

| Service | URL | Notes |
|---------|-----|-------|
| Kibana | http://localhost:5601 | via NodePort 30561 |
| user-service | http://localhost:3001 | via NodePort 30001 |
| payment-service | http://localhost:8001 | via NodePort 30002 |

### Example API calls

```bash
# user-service
curl http://localhost:3001/users
curl http://localhost:3001/users/1
curl http://localhost:3001/users/999       # 404
curl http://localhost:3001/error           # 500

# payment-service
curl http://localhost:8001/payments
curl -X POST http://localhost:8001/payments \
     -H "Content-Type: application/json" \
     -d '{"userId":1,"amount":49.99,"currency":"USD"}'
curl http://localhost:8001/error           # 500

# Track a request with correlation ID
REQUEST_ID=$(cat /proc/sys/kernel/random/uuid)
curl -H "X-Request-ID: $REQUEST_ID" http://localhost:3001/users
curl -H "X-Request-ID: $REQUEST_ID" http://localhost:8001/payments
# Search in Kibana: requestId: "$REQUEST_ID"
```

---

## Simulating Errors & Load

### Automated traffic generator

```bash
# 50 rounds (default)
./scripts/generate-traffic.sh

# 200 rounds
./scripts/generate-traffic.sh 200

# Continuous (Ctrl-C to stop)
./scripts/generate-traffic.sh --continuous
```

Each round sends:
- `GET /users`, `GET /users/1`, `GET /users/2`, `GET /users/999` (404)
- `GET /payments`, 3× `POST /payments` (30 % will fail with realistic error codes), `GET /payments/:id`
- `GET /error` on both services every few rounds (forced 500)

### Manual error simulation

```bash
# Trigger intentional 500s
curl http://localhost:3001/error
curl http://localhost:8001/error

# Flood payment-service to observe failure rate
for i in $(seq 1 20); do
  curl -s -o /dev/null -X POST http://localhost:8001/payments \
    -H "Content-Type: application/json" \
    -d '{"userId":1,"amount":10,"currency":"USD"}'
done

# Scale replicas to generate more log volume
kubectl scale deployment payment-service -n apps --replicas=4
```

### Increase payment failure rate at runtime

```bash
kubectl set env deployment/payment-service -n apps \
  FAILURE_RATE=0.8 MAX_LATENCY_MS=2000
```

---

## Querying Logs in Kibana

Open **http://localhost:5601 → Discover** and ensure the **Observability Logs** (`logs-*`) data view is selected.

### Essential KQL queries

```kql
# All errors
level: "error"

# All errors + warnings
level: "error" OR level: "warn"

# Payment service errors only
service: "payment-service" AND level: "error"

# Specific error code
errorCode: "CARD_DECLINED"

# Any payment error code
service: "payment-service" AND errorCode: *

# Slow requests (> 500 ms)
durationMs > 500

# Trace a single request across both services
requestId: "paste-your-uuid-here"

# HTTP 5xx responses
statusCode: 500

# HTTP 4xx responses
statusCode >= 400 AND statusCode < 500

# Show only user-service logs from the last 10 min
service: "user-service" AND @timestamp > now-10m
```

### Recommended dashboards

See [`dashboards/kibana-queries.md`](dashboards/kibana-queries.md) for:

- **Error Rate Over Time** – line chart of errors per minute
- **Logs by Service** – pie chart broken down by `service`
- **Recent Failures** – live table of error logs
- **Top Error Codes** – bar chart ranked by `errorCode`
- **Payment Latency Distribution** – histogram of `durationMs`

---

## Cleanup

```bash
# Delete cluster only (images remain in local Docker)
./scripts/cleanup.sh

# Delete cluster AND remove local Docker images
./scripts/cleanup.sh --remove-images
```

---

## Troubleshooting

### Pods stuck in `Pending`

```bash
kubectl describe pod -n observability <pod-name>
```

A `Insufficient memory` event means the node needs more RAM.  
Reduce Elasticsearch heap: edit `k8s/elasticsearch/deployment.yaml` and change `ES_JAVA_OPTS` to `-Xms256m -Xmx256m`.

### Elasticsearch `CrashLoopBackOff` – vm.max_map_count

The privileged init container should set this automatically, but if it fails:

```bash
# On Linux host
sudo sysctl -w vm.max_map_count=262144
# Make it persistent
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
```

### Kibana is taking a long time to start

Kibana waits for Elasticsearch to be fully ready (yellow/green cluster health).  
Check Elasticsearch logs:

```bash
kubectl logs -n observability deployment/elasticsearch -f
```

### No logs in Kibana

**Step 1** – Check Fluent Bit is running and not erroring:

```bash
kubectl get pods -n observability -l app=fluent-bit
kubectl logs -n observability daemonset/fluent-bit
```

**Step 2** – Check that Elasticsearch has received data:

```bash
kubectl -n observability exec deployment/elasticsearch -- \
  curl -s "localhost:9200/_cat/indices/logs-*?v"
```

**Step 3** – Check that the Kibana data view pattern matches the indices:

The indices are named `logs-YYYY.MM.DD`. Make sure your data view pattern is `logs-*`.

**Step 4** – Check Fluent Bit can reach Elasticsearch:

```bash
kubectl -n observability exec daemonset/fluent-bit -- \
  wget -qO- http://elasticsearch.observability.svc.cluster.local:9200/_cluster/health
```

### `ImagePullBackOff` for user-service / payment-service

The images must be loaded into KIND before deploying:

```bash
kind load docker-image user-service:latest    --name observability-demo
kind load docker-image payment-service:latest --name observability-demo
```

### Kibana shows "No results" despite data in Elasticsearch

1. Extend the Kibana time picker to **Last 7 days** or **Today**.
2. Confirm the data view's timestamp field is `@timestamp` (not `timestamp`).
3. Run `./scripts/kibana-setup.sh` to recreate the data view if needed.

### Port conflicts on localhost

If `5601`, `3001`, or `8001` are already in use, edit `kind/kind-config.yaml` and update the matching `hostPort` values and the `nodePort` values in `k8s/kibana/service.yaml`, `k8s/user-service/service.yaml`, and `k8s/payment-service/service.yaml`.

### Watching live pod logs

```bash
# All services
kubectl logs -n apps -l app=user-service    -f --prefix
kubectl logs -n apps -l app=payment-service -f --prefix

# Fluent Bit shipping status
kubectl logs -n observability daemonset/fluent-bit -f | grep -E "error|retry|chunk"
```

---

## Resource Requirements

| Component | CPU request | CPU limit | Memory request | Memory limit |
|-----------|-------------|-----------|----------------|--------------|
| Elasticsearch | 200m | 1000m | 1 Gi | 1.5 Gi |
| Kibana | 200m | 500m | 512 Mi | 1 Gi |
| Fluent Bit | 50m | 200m | 64 Mi | 256 Mi |
| user-service (×2) | 50m | 200m | 64 Mi | 128 Mi |
| payment-service (×2) | 50m | 200m | 64 Mi | 128 Mi |
| **Total** | **~850m** | **~2.7 cores** | **~1.9 Gi** | **~4.4 Gi** |

Tested on: Ubuntu 22.04, 8 GB RAM, 4 CPU cores.
