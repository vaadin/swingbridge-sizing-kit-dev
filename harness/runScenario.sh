#!/usr/bin/env bash
# Runs the user-behaviour scenario against the server through real browsers.
#
#   ./runScenario.sh sb 4          4 cycles
#
# Env: URL, VIEW, BOUNDS_LOG, TENANT, TENANTS, HEADLESS=false, VIDEO,
#      MEM_CMD, MEM_CSV, SCENARIO, GUEST_WAIT_MS, HASH_MAX_DIM,
#      ACTIVE_RAMP, MAX_TENANTS, RAMP_SETTLE_MS, SLOW_FACTOR,
#      TENANT_COUNT_FILE, EXTRA="-Dfoo=bar"
#
# Every -Dscenario.* the driver reads has an env var here on purpose. Three
# readings in this project were lost to a setting that existed on the driver
# but on no script: the value silently fell back to its default and the run
# label kept claiming otherwise. The driver now echoes every property it
# resolved, and whether the value was set or defaulted, so a run can be
# audited from its own output instead of from the script that launched it.
set -uo pipefail
. "$(dirname "$0")/harness-env.sh"

CHANNEL="${1:-sb}"
CYCLES="${2:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCN="$ROOT/swing-bridge-memory-harness/scenario/josm-cycle.json"

case "$CHANNEL" in
sb)
  URL="${URL:-http://localhost:8088/}"; VIEW="${VIEW:-josm}"
  # The bridge tags each tenant's guest stdout, so its server log carries the
  # widget-bounds lines for every session in one file.
  BOUNDS_LOG="${BOUNDS_LOG:-$ROOT/swing-bridge-memory-harness/target/server.log}"
  ;;
*) echo "usage: $0 sb [cycles]" >&2; exit 2 ;;
esac

code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$URL" 2>/dev/null) || code=""
[ "${code:-000}" != "200" ] && {
  echo "ERROR: $URL not reachable (HTTP ${code:-000})" >&2; exit 1; }

echo "# scenario: $CHANNEL  $CYCLES cycles  $(date -u +%FT%TZ)"
echo "# url=$URL view=$VIEW"
echo "# bounds=$BOUNDS_LOG"
echo "# git=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"

if [ -n "${DRIVER_LAUNCH:-}" ]; then
  # Kit: run the driver built from source. DRIVER_MAIN closes the command after
  # the -D properties, which is where java expects the main class.
  read -r -a LAUNCH <<<"$DRIVER_LAUNCH"
else
  LAUNCH=(mvn -q -f "$ROOT/pom.xml" -pl swing-bridge-playground test-compile
    org.codehaus.mojo:exec-maven-plugin:3.1.0:java
    -Dexec.classpathScope=test
    -Dexec.mainClass=com.vaadin.swingbridge.load.ScenarioDriver)
fi
"${LAUNCH[@]}" \
  -Dload.url="$URL" -Dload.view="$VIEW" \
  -Dscenario.file="${SCENARIO:-$SCN}" -Dscenario.boundsLog="$BOUNDS_LOG" \
  -Dscenario.cycles="$CYCLES" \
  ${TENANT:+-Dscenario.tenant="$TENANT"} \
  ${HEADLESS:+-Dscenario.headless="$HEADLESS"} \
  ${TENANTS:+-Dscenario.tenants="$TENANTS"} \
  ${VIDEO:+-Dscenario.video="$VIDEO"} \
  ${MEM_CMD:+-Dscenario.memoryCmd="$MEM_CMD"} \
  ${MEM_CSV:+-Dscenario.memoryCsv="$MEM_CSV"} \
  ${GUEST_WAIT_MS:+-Dscenario.guestWaitMs="$GUEST_WAIT_MS"} \
  ${HASH_MAX_DIM:+-Dscenario.hashMaxDim="$HASH_MAX_DIM"} \
  ${ACTIVE_RAMP:+-Dscenario.activeRamp="$ACTIVE_RAMP"} \
  ${MAX_TENANTS:+-Dscenario.maxTenants="$MAX_TENANTS"} \
  ${RAMP_SETTLE_MS:+-Dscenario.rampSettleMs="$RAMP_SETTLE_MS"} \
  ${SLOW_FACTOR:+-Dscenario.slowFactor="$SLOW_FACTOR"} \
  ${TENANT_COUNT_FILE:+-Dscenario.tenantCountFile="$TENANT_COUNT_FILE"} \
  ${EXTRA:-} ${DRIVER_MAIN:-} 2>&1 | grep -vE 'SLF4J|^\[INFO\]|^\[WARNING\]'
