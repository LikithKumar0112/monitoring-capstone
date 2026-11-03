#!/usr/bin/env bash
# Controlled test of the Alertmanager inhibit rule in alertmanager/alertmanager.yml:
#   source severity="critical"  ->  suppresses target severity="warning"  when `instance` is equal
#
# Prerequisite: the stack is up and the REAL HighErrorRate alert (severity=warning,
# instance=flaky-app:8000) is firing from Prometheus (~3 min after startup).
#
# The test injects two alerts straight into Alertmanager with amtool:
#   1. CRITICAL InhibitionTestCritical instance=flaky-app:8000   -> must suppress the real warning
#   2. CONTROL  InhibitionTestControl  instance=other-host:9999  -> warning on another instance, must stay active
# Both expire on their own after TEST_MINUTES (default 10); HighErrorRate then becomes active again.
#
#   ./scripts/inhibition-test.sh          # run the test
#   ./scripts/inhibition-test.sh status   # only show alert states
#   ./scripts/inhibition-test.sh cleanup  # resolve the test alerts now
set -euo pipefail

AM_CONTAINER=${AM_CONTAINER:-alertmanager}
AM_URL=${AM_URL:-http://localhost:9093}
TEST_MINUTES=${TEST_MINUTES:-10}
INSTANCE=flaky-app:8000

amtool() { docker exec "$AM_CONTAINER" amtool --alertmanager.url=http://localhost:9093 "$@" 2>/dev/null; }

# Print every alert Alertmanager holds with its state (active | suppressed) and what inhibits it.
show() {
  echo
  echo "== Alertmanager alerts =="
  curl -s "$AM_URL/api/v2/alerts" | python3 -c '
import sys, json
alerts = json.load(sys.stdin)
print("%-11s %-24s %-9s %-16s %s" % ("STATE", "ALERTNAME", "SEVERITY", "INSTANCE", "INHIBITED BY"))
for a in sorted(alerts, key=lambda a: a["status"]["state"]):
    l, st = a["labels"], a["status"]
    by = ",".join(st["inhibitedBy"])[:12] or "-"
    print("%-11s %-24s %-9s %-16s %s" % (st["state"], l.get("alertname"), l.get("severity"), l.get("instance"), by))
'
}

# count <state> <alertname>
count() {
  curl -s "$AM_URL/api/v2/alerts" | python3 -c '
import sys, json
state, name = sys.argv[1], sys.argv[2]
print(sum(1 for a in json.load(sys.stdin) if a["status"]["state"] == state and a["labels"].get("alertname") == name))
' "$1" "$2"
}

# Re-post the test alerts with an end time of "now" so Alertmanager resolves them.
resolve_test_alerts() {
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  amtool alert add 'alertname="InhibitionTestCritical"' 'severity="critical"' "instance=\"$INSTANCE\"" 'test="inhibition"' --end="$now" || true
  amtool alert add 'alertname="InhibitionTestControl"' 'severity="warning"' 'instance="other-host:9999"' 'test="inhibition"' --end="$now" || true
}

case "${1:-}" in
  status)  show; exit 0 ;;
  cleanup) resolve_test_alerts; sleep 3; show; exit 0 ;;
esac

resolve_test_alerts   # start from a clean state if a previous run is still active
sleep 3

echo "Checking that the real HighErrorRate warning for $INSTANCE is in Alertmanager..."
if [[ $(( $(count active HighErrorRate) + $(count suppressed HighErrorRate) )) -lt 1 ]]; then
  echo "HighErrorRate is not in Alertmanager yet - wait ~3 min after startup and retry." >&2
  exit 1
fi

echo "BEFORE the test:"
show

END=$(date -u -d "+${TEST_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)
echo
echo "Injecting CRITICAL alert for instance=$INSTANCE and CONTROL warning for instance=other-host:9999 (expire $END)"
amtool alert add 'alertname="InhibitionTestCritical"' 'severity="critical"' "instance=\"$INSTANCE\"" 'test="inhibition"' \
  "--annotation=summary=\"Inhibition test: critical alert on $INSTANCE\"" --end="$END"
amtool alert add 'alertname="InhibitionTestControl"' 'severity="warning"' 'instance="other-host:9999"' 'test="inhibition"' \
  '--annotation=summary="Inhibition test: control warning on a different instance"' --end="$END"

sleep 5
echo
echo "AFTER the test:"
show

echo
inhibited=$(count suppressed HighErrorRate)
control=$(count active InhibitionTestControl)
critical=$(count active InhibitionTestCritical)
if [[ "$inhibited" -ge 1 && "$control" -ge 1 && "$critical" -ge 1 ]]; then
  echo "PASS: HighErrorRate (warning, $INSTANCE) is SUPPRESSED by the critical alert on the same instance;"
  echo "      the control warning on other-host:9999 is still ACTIVE."
else
  echo "FAIL: suppressed HighErrorRate=$inhibited, active critical=$critical, active control=$control" >&2
  exit 1
fi
echo "Test alerts expire automatically at $END."
