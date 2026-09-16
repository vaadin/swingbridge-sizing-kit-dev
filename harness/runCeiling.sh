#!/usr/bin/env bash
# How many ACTIVE users fit in a fixed physical budget, and what ran out first.
#
#   ./runCeiling.sh sb 3g    [budgetGB] [maxTenants]
#
# The budget is enforced, not assumed: the product's whole process tree runs in a
# systemd user scope with MemoryMax=<budget> and MemorySwapMax=0. Swap is off
# deliberately — a tree that swaps stays "alive" while serving nobody, and we
# want the budget to be the wall rather than a suggestion.
#
# What is NOT charged to the budget, and why:
#   maven      943 MB of build tool measured beside an 869 MB server. The real
#              server command is captured and launched directly instead.
#   harness    the sampler service and the monitor are instrumentation; they run
#              outside the scope so the product gets the whole budget.
#   browsers   they live on the load box, which is also why the server's RSS
#              stays monotonic as tenants are added.
#
# Sampling here does NOT force a collection (--no-gc). Everywhere else a forced
# full GC buys a clean live-set reading; in a ceiling run it would hand the
# product free reclamation at every step and inflate the answer. The cgroup's own
# memory.current is the honest number.
#
# Env:
#   JOSM_JAR   path to the patched JOSM guest jar, which is NOT in the tree
#              (GPLv2 guest, commercial repo). Defaults to
#              $HOME/dev/josm/josm-web-patched.jar -- per-user, so it resolves
#              on any box that follows that layout. The run ABORTS if it is not
#              readable, because a missing guest otherwise yields a complete
#              verdict full of zeros rather than an error.
#   A_IP, SETTLE, EXTRA_RAMP  -- see the ramp.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
HERE=$PWD
ROOT=$(cd .. && pwd)

CH="${1:-}"
HEAP="${2:-}"
BUDGET="${3:-4}"
MAXT="${4:-60}"
# Extra driver properties for the ramp, e.g. -Dscenario.fineFrom=22. Passed
# through so a cell's stepping is a setting rather than an edit to this script.
EXTRA_RAMP="${EXTRA_RAMP:-}"
# Everything machine-specific comes from harness-env.sh -- run ./checkEnv.sh
# to see what resolved.
. "$(dirname "$0")/probes.sh"      # oom_count, scope_kill_verdict, live_thru, ...
                                  # every branch of it pinned by ./testProbes.sh
. "$(dirname "$0")/harness-env.sh"   # JOSM_JAR, A_IP, BOXB
[ -z "$CH" ] || [ -z "$HEAP" ] && { echo "usage: $0 sb <heap> [budgetGB] [maxTenants]" >&2; exit 2; }
# The channel argument survives from a harness that once drove two; only sb exists.
[ "$CH" = sb ] || { echo "the only channel is sb" >&2; exit 2; }

STAMP=$(date -u +%Y%m%d%H%M%S)
UNIT="ceil-$CH-$STAMP.scope"
TAG="$STAMP-ceiling-$CH-$HEAP"
MON="$HERE/reports/$TAG.monitor.csv"
SAMP="$HERE/reports/$TAG.samples.csv"
LOG="$HERE/reports/$TAG.log"
TCOUNT="/tmp/ceiling-tenants-$STAMP"
echo 0 > "$TCOUNT"

say() { echo "$@" | tee -a "$LOG"; }

cleanup() {
  say "--- tearing down ---"
  kill "$(cat /tmp/ceilmon.pid 2>/dev/null)" 2>/dev/null
  kill "$(cat /tmp/harnessServer.pid 2>/dev/null)" 2>/dev/null
  systemctl --user stop "$UNIT" 2>/dev/null
  for p in $(jps -l | awk -v m="${SERVER_JPS_MATCH:-mycompany.swingbridge.Application}" '$0 ~ m {print $1}'); do
    kill "$p" 2>/dev/null
  done
}
trap cleanup EXIT

say "# ceiling run  channel=$CH  heap=$HEAP  budget=${BUDGET}G  maxTenants=$MAXT"
say "# scope=$UNIT  A=$A_IP  git=$(git -C "$ROOT" rev-parse --short HEAD)"

# ---------------------------------------------------------------- teardown
kill "$(cat /tmp/harnessServer.pid 2>/dev/null)" 2>/dev/null
for p in $(jps -l | awk -v m="${SERVER_JPS_MATCH:-mycompany.swingbridge.Application|plexus.classworlds}" '$0 ~ m {print $1}'); do
  kill "$p" 2>/dev/null
done
sleep 8

# ------------------------------------------------------- start in the scope
# Capture the real server command: spring-boot:run forks it, and maven itself
# must not be inside the budget. Captured fresh each run so it cannot go stale.
# Cached across runs, revalidated each time -- a full Maven startup was being
# paid for every cell, which is ten minutes across a six-run trial session and
# buys nothing: the command only changes when the build does.
mv "$HERE/target/server.log" "$HERE/target/server.log.pre-$STAMP" 2>/dev/null
"$HERE/captureServerArgv.sh" \
  || { say "ERROR: could not obtain the server command"; exit 1; }
ARGV_CACHE="$HERE/target/server-argv.cache"
mapfile -d '' -t ARGV < "$ARGV_CACHE"
[ "${#ARGV[@]}" -gt 3 ] || { say "ERROR: captured argv looks wrong (${#ARGV[@]} entries)"; exit 1; }
say "# server command: ${#ARGV[@]} argv entries from $(basename "$ARGV_CACHE")"

# Relaunch that exact command inside the budget, with the heap we are testing.
# -Xmx must be explicit: the JVM is container-aware and would otherwise cap
# itself at a quarter of the scope and OOM with most of the budget unused.
JAVA="${ARGV[0]}"
REST=()
DROPPED=()
for a in "${ARGV[@]:1}"; do
  case "$a" in
  # A dev profile attaches a debug agent, and no deployment answering "how many
  # users fit on this box" runs one on a wildcard address. Stripped here rather
  # than in the pom, so the kit owns its run configuration and nobody loses
  # debugging on spring-boot:run.
  -agentlib:jdwp*|-Xdebug|-Xrunjdwp*)
    DROPPED+=("$a") ;;
  # Our -Xmx is prepended, so any captured one would come after it and win.
  # Nothing sets it today; if the pom ever does, it would silently override
  # the heap under test and void the sweep without a symptom.
  -Xmx*|-Xms*)
    DROPPED+=("$a") ;;
  *)
    REST+=("$a") ;;
  esac
done
if [ ${#DROPPED[@]} -gt 0 ]; then
  say "# dropped from the captured command: ${DROPPED[*]}"
else
  say "# dropped from the captured command: (nothing)"
fi
# The guest jar lives OUTSIDE the tree -- JOSM is GPLv2 and this repo is
# commercial -- so its path is environment-specific and must be passed in.
# Round 2's sweeps got it from an ad-hoc export in one shell session that is
# recorded nowhere; when that session ended, the next run launched no guest at
# all and still produced a full verdict, of zeros. JosmApp's compiled default
# is /home/eftun/..., which on this box is a DIFFERENT user's home at mode 750,
# so it cannot even be stat'd. Prepended beside -Xmx rather than appended: the
# captured argv ends with the main class, and anything after that is a program
# argument, not a JVM option.
JVM_EXTRA=()
if [ -n "${GUEST_JVM_EXTRA+x}" ]; then
  # Kit: guest injection lives in the argv cache; a set-but-empty
  # GUEST_JVM_EXTRA means "inject nothing here" and skips the JOSM block.
  [ -n "$GUEST_JVM_EXTRA" ] && read -r -a JVM_EXTRA <<<"$GUEST_JVM_EXTRA"
elif [ "$CH" = sb ]; then
  if [ ! -r "$JOSM_JAR" ]; then
    say "ERROR: guest jar not readable: $JOSM_JAR"
    say "       set JOSM_JAR=<path>. Refusing to run: without it the guest"
    say "       never starts and the cell records zeros instead of failing."
    exit 1
  fi
  JVM_EXTRA+=("-Djosm.jar=$JOSM_JAR")
  say "# guest jar: $JOSM_JAR ($(sha256sum "$JOSM_JAR" | cut -c1-16))"
fi
say "# starting the server in the scope with -Xmx$HEAP"
# From the module directory: the captured command carries RELATIVE paths
# (--patch-module ../swing-bridge-patch/target/...), so the working directory
# is part of the command, not incidental to it.
( cd "${SERVER_CWD:-$ROOT/swing-bridge-playground}" && \
  systemd-run --user --scope --unit="$UNIT" --quiet \
    -p MemoryMax="${BUDGET}G" -p MemorySwapMax=0 -p OOMPolicy=continue \
    "$JAVA" "-Xmx$HEAP" ${JVM_EXTRA[@]+"${JVM_EXTRA[@]}"} "${REST[@]}" \
      > "$HERE/target/server.log" 2>&1 & )
PORT=8088
BOUNDS="$HERE/target/server.log"

for i in $(seq 1 90); do
  sleep 5
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/")" = "200" ] && break
done
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/")
say "# server on :$PORT -> $CODE"
[ "$CODE" != "200" ] && { say "ERROR: server did not come up in the scope"; exit 1; }

# ------------------------------------------------- instrumentation, outside
SPID=$(jps -l | awk -v m="${SERVER_JPS_MATCH:-mycompany.swingbridge.Application}" '$0 ~ m {print $1; exit}')
SARGS="--channel sb --proc-pid $SPID --heap-pid $SPID --no-gc"
nohup "$HERE/scenario/harnessServer.py" --bind 0.0.0.0 --port 8099 \
  --log "$BOUNDS" --sample-args "$SARGS" --csv "$SAMP" \
  --tenants-file "$TCOUNT" \
  > /tmp/harnessServer.log 2>&1 &
echo $! > /tmp/harnessServer.pid
sleep 3

nohup "$HERE/scenario/ceilingMonitor.py" --scope "$UNIT" \
  --iface "$(ip route | awk '/default/{print $5; exit}')" --port "$PORT" \
  --peer-ssh "$BOXB" --csv "$MON" \
  --interval "${MON_INTERVAL:-5}" --peer-every "${MON_PEER_EVERY:-1}" \
  --tenants-file "$TCOUNT" > "$HERE/reports/$TAG.monitor.log" 2>&1 &
echo $! > /tmp/ceilmon.pid
sleep 2
say "# monitor -> $MON"
say "# samples -> $SAMP"

# -------------------------------------------------------- drive from Box B
# Baseline the log's OOM count now that BOUNDS is known, so the verdict can
# report what THIS cell produced rather than what the file has accumulated.
OOM_BASE=$(oom_count)
say "# ramping active users from the load box"
A_IP="$A_IP" \
EXTRA_REMOTE="-Dscenario.activeRamp=true -Dscenario.maxTenants=$MAXT -Dscenario.rampSettleMs=${SETTLE:-25000} ${EXTRA_RAMP:-}" \
  "$HERE/runScenarioRemote.sh" "$CH" 1 1 2>&1 | tee -a "$LOG"
# PIPESTATUS, not $?, which would be tee's. This code was discarded entirely
# before, so a ramp that never finished still produced a full verdict below and
# the matrix recorded its partial tenant count as a ceiling -- the same shape as
# the heap sweep that recorded an infrastructure failure as a heap result.
RAMP_RC=${PIPESTATUS[0]}

# ------------------------------------------------------------------ verdict
sleep 3
# Peak and kernel OOM kills come from the MONITOR CSV, not from /sys/fs/cgroup.
# The scope is gone by the time the verdict runs, so the old reads here found
# nothing and printed "peak 0 MB / oom kills 0" in every cell ever recorded --
# while the monitor, sampling the same counters during the run, had the real
# numbers all along. Columns: 4 cg_mem_mb, 5 cg_mem_max_mb, 7 cg_oom_kills.
# How far the ramp got while the scope was still ALIVE. The scope dying at the
# wall is not a fault -- it IS the ceiling -- but the ramp keeps counting for a
# few seconds afterwards, and a tenant counted after the last live cgroup
# reading was never observed being served by anything. Five round-2 cells
# reported exactly one tenant more than the scope was alive for, among them a
# headline figure.
LIVE_T=$(live_thru "$MON")

read -r PEAK_MB BUDGET_MB PEAK_PCT OOM <<<"$(monitor_peaks "$MON")"
say ""
print_verdict
say "  monitor CSV       : $MON"
tail -4 "$MON" 2>/dev/null | sed 's/^/  /' | tee -a "$LOG"

# Kit: keep the server's own event lines for this cell -- launch failures, errors,
# OOMs -- so the report can tell a guest that hit the bridge's 5 s first-window
# limit ("did not display any window within the launch timeout") from one that
# never published. The full log is mostly bounds lines and runs to hundreds of MB
# at forty tenants; only the events are kept, beside the cell's other evidence.
if [ -r "$HERE/target/server.log" ]; then
  EVENTS="$HERE/reports/$TAG.server-events.log"
  grep -vF "${BOUNDS_MARKER:-WIDGET-BOUNDS}" "$HERE/target/server.log" 2>/dev/null \
    | grep -E 'ERROR|WARN|Exception|failed to launch|launch timeout|OutOfMemoryError' > "$EVENTS" 2>/dev/null || true
  say "  server events     : $(wc -l < "$EVENTS") line(s) -> reports/$TAG.server-events.log"
fi
