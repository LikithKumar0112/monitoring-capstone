#!/usr/bin/env bash
# e2e — smoke test. PASS/FAIL per check; SKIP if that profile isn't running.
# Exits non-zero if any check FAILs. Run after the stack has warmed up (~1-2 min).
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP+1)); }

# is a container (by compose service name) running?
running() { [ "$(docker inspect -f '{{.State.Running}}' "e2e-$1" 2>/dev/null)" = "true" ]; }

echo "== 1. Expected containers running =="
for svc in prometheus node-exporter cadvisor grafana alertmanager flaky-app \
           jaeger hotrod elasticsearch logstash kibana filebeat log-generator \
           minio prometheus-us prometheus-eu prometheus-fed \
           thanos-sidecar-us thanos-sidecar-eu thanos-store thanos-compact thanos-query; do
  if docker inspect "e2e-$svc" >/dev/null 2>&1; then
    running "$svc" && pass "container e2e-$svc running" || fail "container e2e-$svc NOT running"
  else
    skip "e2e-$svc not in this profile set"
  fi
done

echo "== 2. Prometheus targets all up =="
if running prometheus; then
  down=$(curl -sf localhost:9090/api/v1/targets \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);print(sum(1 for t in d["data"]["activeTargets"] if t["health"]!="up"))' 2>/dev/null)
  if [ "${down:-1}" = "0" ]; then pass "all Prometheus targets up"; else fail "$down target(s) not up"; fi
else skip "prometheus not running"; fi

echo "== 3. Prometheus has recording + alerting rule groups =="
if running prometheus; then
  types=$(curl -sf localhost:9090/api/v1/rules \
    | python3 -c 'import sys,json;d=json.load(sys.stdin);ts=set(r["type"] for g in d["data"]["groups"] for r in g["rules"]);print(",".join(sorted(ts)))' 2>/dev/null)
  if echo "$types" | grep -q recording && echo "$types" | grep -q alerting; then
    pass "recording + alerting rules loaded ($types)"
  else fail "missing rule types (got: ${types:-none})"; fi
else skip "prometheus not running"; fi

echo "== 4. Alertmanager status responds =="
if running alertmanager; then
  st=$(curl -sf localhost:9093/api/v2/status | python3 -c 'import sys,json;print(json.load(sys.stdin)["cluster"]["status"])' 2>/dev/null)
  [ -n "${st:-}" ] && pass "Alertmanager status: $st" || fail "Alertmanager /api/v2/status no response"
else skip "alertmanager not running"; fi

echo "== 5. Elasticsearch cluster health green/yellow =="
if running elasticsearch; then
  h=$(curl -sf localhost:9200/_cluster/health | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])' 2>/dev/null)
  case "${h:-}" in green|yellow) pass "ES cluster health: $h";; *) fail "ES cluster health: ${h:-unreachable}";; esac
else skip "elasticsearch not running"; fi

echo "== 6. app-logs-* index exists with docs > 0 =="
if running elasticsearch; then
  c=$(curl -sf 'localhost:9200/app-logs-*/_count' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("count",0))' 2>/dev/null)
  if [ "${c:-0}" -gt 0 ] 2>/dev/null; then pass "app-logs-* doc count: $c"; else fail "app-logs-* missing or empty (count=${c:-0})"; fi
else skip "elasticsearch not running"; fi

echo "== 7. Grafana health ok =="
if running grafana; then
  db=$(curl -sf localhost:3000/api/health | python3 -c 'import sys,json;print(json.load(sys.stdin)["database"])' 2>/dev/null)
  [ "${db:-}" = "ok" ] && pass "Grafana /api/health database: ok" || fail "Grafana health not ok (${db:-unreachable})"
else skip "grafana not running"; fi

echo "== 8. Thanos Query lists both sidecars + store, all healthy =="
if running thanos-query; then
  ok=$(curl -sf localhost:10902/api/v1/stores | python3 -c '
import sys,json
d=json.load(sys.stdin)["data"]
n=sum(len(v) for v in d.values())
print("ok" if n>=3 else "only %d"%n)' 2>/dev/null)
  [ "${ok:-}" = "ok" ] && pass "Thanos Query stores: 3 endpoints (2 sidecars + store)" || fail "Thanos Query stores: ${ok:-unreachable}"
else skip "thanos-query not running"; fi

echo "== 9. Jaeger has >=1 trace for frontend =="
if running jaeger; then
  n=$(curl -sf "localhost:16686/api/traces?service=frontend&limit=1" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data") or []))' 2>/dev/null)
  if [ "${n:-0}" -gt 0 ] 2>/dev/null; then pass "Jaeger frontend traces: $n"; else fail "no frontend traces (generate load via HotROD first)"; fi
else skip "jaeger not running"; fi

echo
echo "== SUMMARY: $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" -eq 0 ]
