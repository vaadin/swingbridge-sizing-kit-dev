#!/usr/bin/env bash
# Box A -- the sizing cells: one heap after another, each ramped until the set
# breaks, then the report's table for a person to read.
#
# No decision logic here on purpose. The harness's own runConfirmationSet.sh put
# it best: "a script that both measures and decides can quietly publish a wrong
# number". This runs the cells; runReport.sh lays them out; you choose the heap.
#
#   ./runSizing.sh                       heaps at 60 %, 70 %, 80 % of BUDGET, one cell each
#   SIZING_HEAP_START=50% SIZING_HEAP_STOP=70% SIZING_HEAP_STEP=10% ./runSizing.sh
#   SIZING_HEAP_START=2g SIZING_HEAP_STOP=3g SIZING_HEAP_STEP=256m ./runSizing.sh
#   SB_CAPS="2456m 2560m" ./runSizing.sh   an explicit list, overriding the range
#   SIZING_REPEATS=3 ./runSizing.sh        every heap three times, round-robin
#   SIZING_DRY_RUN=1 ./runSizing.sh        print the plan and stop
#
# Env (harness.env): BUDGET (GB, 4), SIZING_HEAP_START/STOP/STEP (60% 80% 10%;
# one unit for all three, % of budget or m/g), SB_CAPS, SIZING_REPEATS (1),
# SIZING_MAX_CELLS (12), SB_MAX (tenant ceiling, 60), SETTLE (ms, 15000).
#
# A cap is a -Xmx: what the Java heap may grow to inside the budget. Percentages
# are of the budget, rounded to 8 MB. One cell is ~27 minutes for an application
# that fits ~40 users -- it scales with the count reached, not the budget.
# Round 2's best heaps sat at 55-61 % of the budget at every budget measured;
# above that the count fell, below it the risk is a Java OOM with budget unspent.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
KIT=$PWD
H="$KIT/harness"
say() { echo "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }
. "$H/harness-env.sh"
. "$H/probes.sh"

BUDGET_GB="${BUDGET:-4}"
MB=$(( BUDGET_GB * 1024 ))
REPEATS="${SIZING_REPEATS:-1}"
MAXT="${SB_MAX:-60}"
MAX_CELLS="${SIZING_MAX_CELLS:-12}"
r8() { echo $(( ( $1 + 4 ) / 8 * 8 )); }

# ---------------------------------------------------------------- the heaps
# Either an explicit list, or a range. A range's three values share one unit:
# percent of the budget, or an absolute heap (m/g) that heap_mb() understands.
if [ -n "${SB_CAPS:-}" ]; then
  CAPS="$SB_CAPS"; RANGE="explicit"
else
  START="${SIZING_HEAP_START:-60%}"; STOP="${SIZING_HEAP_STOP:-80%}"; STEP="${SIZING_HEAP_STEP:-10%}"
  RANGE="$START $STOP $STEP"
  case "$START$STOP$STEP" in
    *%*%*%) unit=pct; s=${START%\%}; e=${STOP%\%}; d=${STEP%\%} ;;
    *%*) die "SIZING_HEAP_START/STOP/STEP must share one unit: all percentages, or all heaps like 2g / 2560m" ;;
    *) unit=abs; s=$(heap_mb "$START"); e=$(heap_mb "$STOP"); d=$(heap_mb "$STEP") ;;
  esac
  for v in "$s" "$e" "$d"; do case "$v" in ''|*[!0-9]*) die "cannot read the heap range '$RANGE'";; esac; done
  [ "$d" -gt 0 ] || die "SIZING_HEAP_STEP must be positive (got $STEP)"
  [ "$s" -le "$e" ] || die "SIZING_HEAP_START ($START) is above SIZING_HEAP_STOP ($STOP)"
  CAPS=""
  v=$s
  while [ "$v" -le "$e" ]; do
    if [ "$unit" = pct ]; then mb=$(r8 $(( MB * v / 100 ))); else mb=$(r8 "$v"); fi
    CAPS="$CAPS${CAPS:+ }${mb}m"
    v=$(( v + d ))
  done
fi
# Every cap must leave the JVM's non-heap memory room inside the budget.
pct_of() { echo $(( ( $1 * 1000 / MB + 5 ) / 10 )); }   # rounded, not truncated: 2456m of 4096 is 60 %, not 59
for cap in $CAPS; do
  mb=$(heap_mb "$cap"); pct=$(pct_of "$mb")
  [ "$mb" -gt 0 ] || die "cannot read heap '$cap'"
  [ "$mb" -lt "$MB" ] || die "-Xmx$cap is ${pct} % of the ${BUDGET_GB} GB budget: the JVM's own non-heap memory makes that wall certain. Stay below 100 %."
  [ "$pct" -lt 90 ] || say "WARN: -Xmx$cap is ${pct} % of the budget; round 2 saw the kernel take the server from 64 % up"
done
NPOINTS=$(set -- $CAPS; echo $#)
CELLS=$(( NPOINTS * REPEATS ))
[ "$CELLS" -le "$MAX_CELLS" ] \
  || die "$NPOINTS heap(s) x $REPEATS run(s) = $CELLS cells, above SIZING_MAX_CELLS=$MAX_CELLS. A typo here books a day of box time; raise the limit if you mean it."
# Round-robin, not grouped: a slow drift in host load through the afternoon then
# lands on every heap rather than on one.
LIST=""
for _ in $(seq "$REPEATS"); do for cap in $CAPS; do LIST="$LIST${LIST:+ }$cap"; done; done

# ---------------------------------------------------------------- the plan
PCTS=$(for cap in $CAPS; do printf '%s(%d%%) ' "$cap" "$(pct_of "$(heap_mb "$cap")")"; done)
EST_MIN=$(( CELLS * 27 ))
say "==== plan ===="
say "  budget  : ${BUDGET_GB} GB"
say "  heaps   : $PCTS ($RANGE)"
say "  runs    : $REPEATS per heap -> $CELLS cell(s), round-robin"
say "  ceiling : $MAXT tenants per cell, ${SETTLE:-15000} ms settle"
say "  time    : about $(awk -v m=$EST_MIN 'BEGIN{printf "%.1f", m/60}') h for an application that fits ~40 users; scales with the count reached"
if [ -n "${SIZING_DRY_RUN:-}" ]; then say "  dry run : stopping here"; exit 0; fi

# ---------------------------------------------------------------- preflight
[ -s "$H/target/server-argv.cache" ] || die "no composed server command yet: run ./runBoxA.sh first"
[ -n "${GUEST_JVM_EXTRA+x}" ] \
  || die "GUEST_JVM_EXTRA is not set (runBoxA.sh writes it): runCeiling.sh would inject the round-2 JOSM guest"
"$H/checkEnv.sh" || die "preflight failed. Each failure above produces a wrong answer, not an error."

STAMP=$(date -u +%Y%m%d%H%M%S)
mkdir -p "$H/reports"
MANIFEST="$H/reports/$STAMP-sizing.txt"
mapfile -d '' -t SARGV < "$H/target/server-argv.cache"
SERVER_JAR="${SARGV[${#SARGV[@]}-1]}"
{
  echo "sizing_stamp=$STAMP"
  echo "budget_gb=$BUDGET_GB"
  echo "heaps=$CAPS"
  echo "heap_range=$RANGE"
  echo "repeats=$REPEATS"
  echo "sb_max=$MAXT"
  echo "settle_ms=${SETTLE:-15000}"
  echo "server_jar=$SERVER_JAR"
  echo "server_jar_sha256=$(sha256sum "$SERVER_JAR" 2>/dev/null | cut -c1-16 || echo unknown)"
  echo "main_class=${SIZING_MAIN_CLASS:-}"
  echo "view=${VIEW:-}"
  echo "swing_bridge_version=$(sed -n 3p "$H/target/server-argv.resolved" 2>/dev/null)"
  echo "skeleton_rev=$(git -C "${SERVER_CWD:-.}" rev-parse --short HEAD 2>/dev/null)"
  echo "kit_rev=$(git -C "$KIT" rev-parse --short HEAD 2>/dev/null)"
  echo "box_cores=$(nproc)"
  echo "box_ram_gb=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)"
  echo "box_virt=$(systemd-detect-virt 2>/dev/null || echo unknown)"
  echo "boxb_cores=${BOXB_CORES:-}"
} > "$MANIFEST"

# ---------------------------------------------------------------- the cells
say "==== $CELLS cell(s): $LIST ===="
BUDGET="$BUDGET_GB" SB_CAPS="$LIST" SB_MAX="$MAXT" SETTLE="${SETTLE:-15000}" \
  "$H/runCeilingMatrix.sh" || say "WARN: runCeilingMatrix.sh exited non-zero; reading whatever cells it wrote"

# Every cell log from THIS run, per heap, in run order. Cell logs begin with a UTC
# stamp; anything older than this script's start belongs to an earlier run and is
# not read -- a missing cell reads as missing, never as last week's number.
say "==== results ===="
for cap in $CAPS; do
  n=0
  for f in $(ls "$H"/reports/*-ceiling-sb-"$cap".log 2>/dev/null | sort); do
    [[ "$(basename "$f")" < "$STAMP" ]] && continue
    n=$(( n + 1 ))
    v=$(cell_verdict "$f")
    echo "cell $cap $f $v" >> "$MANIFEST"
    say "  -Xmx$cap  run $n: $v  ($(basename "$f"))"
  done
  [ "$n" -eq "$REPEATS" ] || say "  -Xmx$cap: expected $REPEATS cell(s), found $n"
  [ "$n" -gt 0 ] || echo "cell $cap - -1 no:no-log" >> "$MANIFEST"
done
say "==== done ===="
say "  manifest : $MANIFEST"
say "  next     : ./runReport.sh"
