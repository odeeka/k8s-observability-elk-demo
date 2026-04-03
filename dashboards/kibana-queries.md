# Kibana Queries & Dashboard Guide

This document contains ready-to-use KQL queries for Kibana Discover and
instructions for building the recommended dashboards.

> **Prerequisite:** Complete the Kibana data view setup described in the
> README or run `./scripts/kibana-setup.sh`.

---

## KQL Quick Reference

Open **Kibana → Discover** and make sure the data view is set to **logs-\***.

### 1. All error-level logs

```kql
level: "error"
```

### 2. All warn or error logs

```kql
level: "error" OR level: "warn"
```

### 3. Logs for a specific service

```kql
service: "payment-service"
```

```kql
service: "user-service"
```

### 4. Logs containing a correlation / request ID

```kql
requestId: "replace-with-actual-id"
```

### 5. All payment failures

```kql
service: "payment-service" AND level: "error"
```

### 6. Specific payment error codes

```kql
errorCode: "PAYMENT_GATEWAY_TIMEOUT"
errorCode: "INSUFFICIENT_FUNDS"
errorCode: "CARD_DECLINED"
errorCode: "FRAUD_DETECTED"
```

### 7. Any payment error (all codes)

```kql
service: "payment-service" AND errorCode: *
```

### 8. Slow payment requests (durationMs > 500 ms)

```kql
service: "payment-service" AND durationMs > 500
```

### 9. HTTP 4xx / 5xx responses

```kql
statusCode >= 400
```

```kql
statusCode: 500
```

```kql
statusCode: 404
```

### 10. Logs from the last 15 minutes (use the time picker)

Set the Kibana time picker to **Last 15 minutes** and combine with any query above.

### 11. Intentional error endpoint hits

```kql
message: "intentional_error_triggered"
```

### 12. Service start-up events

```kql
message: "service_started"
```

### 13. Logs by Kubernetes namespace

```kql
kubernetes.namespace_name: "apps"
```

```kql
kubernetes.namespace_name: "observability"
```

### 14. Logs from a specific pod

```kql
kubernetes.pod_name: "payment-service-*"
```

### 15. Combine service + level + time window

```kql
service: "payment-service" AND level: "error" AND @timestamp >= "now-1h"
```

---

## Dashboard recipes

### Dashboard 1 – Error Rate Over Time

| Widget | Type | Config |
|--------|------|--------|
| Error events / minute | Line chart | X-axis: `@timestamp` (1-min interval), Y-axis: count, Filter: `level: "error"` |
| Error rate % | Metric | Formula: `count(level: "error") / count() * 100` |

**Steps in Kibana:**
1. Open **Kibana → Dashboard → Create dashboard**.
2. Click **Add panel → Aggregation based → Line**.
3. Set index pattern to `logs-*`.
4. Add a filter `level: "error"`.
5. X-axis: Date Histogram on `@timestamp` (Minimum interval: `1m`).
6. Y-axis: Count.
7. Save as "Errors per minute".

---

### Dashboard 2 – Logs by Service

| Widget | Type |
|--------|------|
| Log count per service | Pie or Bar chart |
| Service log table | Data table |

**Steps:**
1. Add panel → Aggregation based → Pie.
2. Bucket: Terms on `service` field, size 10.
3. Save as "Logs by service".

---

### Dashboard 3 – Recent Failures Detail

A searchable table showing the most recent error logs.

**Steps:**
1. Add panel → **Logs** (if available) or **Data table**.
2. Filter: `level: "error"`.
3. Columns: `@timestamp`, `service`, `message`, `errorCode`, `requestId`, `kubernetes.pod_name`.
4. Sort by `@timestamp` descending.
5. Save as "Recent failures".

---

### Dashboard 4 – Top Error Codes

| Widget | Type |
|--------|------|
| Bar chart of errorCode counts | Horizontal bar |

**Steps:**
1. Add panel → Aggregation based → Horizontal bar.
2. Filter: `level: "error"`.
3. X-axis: Count.
4. Y-axis: Terms on `errorCode` field.
5. Save as "Top error codes".

---

### Dashboard 5 – Payment Latency Distribution

| Widget | Type |
|--------|------|
| Histogram of durationMs | Bar chart |
| 95th-percentile latency | Metric |

**Steps:**
1. Add panel → Aggregation based → Vertical bar.
2. Filter: `service: "payment-service"`.
3. X-axis: Histogram on `durationMs` (interval: 50).
4. Y-axis: Count.
5. Save as "Payment latency distribution".

---

## Useful Elasticsearch queries (via kubectl)

Run these directly against Elasticsearch from within the cluster:

```bash
# Count error logs in the last index
kubectl -n observability exec deployment/elasticsearch -- \
  curl -s "localhost:9200/logs-*/_count?q=level:error" | python3 -m json.tool

# Show most recent 5 error log entries
kubectl -n observability exec deployment/elasticsearch -- \
  curl -s -X GET "localhost:9200/logs-*/_search" \
  -H "Content-Type: application/json" \
  -d '{
    "size": 5,
    "sort": [{"@timestamp": "desc"}],
    "query": {"term": {"level": "error"}}
  }' | python3 -m json.tool

# List all active indices
kubectl -n observability exec deployment/elasticsearch -- \
  curl -s "localhost:9200/_cat/indices/logs-*?v"
```
