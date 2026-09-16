#!/usr/bin/env bash
# The whole matrix, unattended: several heap settings, one fixed budget, every
# user active.
#
# Several settings rather than one, because the heap is the knob that most moves
# the answer and picking it by taste would be picking the result. Too small and
# the guests die or thrash with budget unspent; too large and fewer fit.
#
# A GRID, NOT A SEARCH, and not a fine one. A binary search suits a question
# that is monotonic ("does it run at all"). This one is not: capacity against
# heap rises, peaks and falls, so the analogue would be golden-section rather
# than binary. It is not used, for two reasons.
# It would not be cheaper -- narrowing 2000-3500m to +/-125m costs about five
# evaluations against four for a grid -- and it is unsafe on a measurement this
# noisy: the same cell returns 37, 38, 39, 39 and adjacent heap points differ by
# a similar margin, so a method that discards half the interval on one
# comparison will sometimes discard the half holding the peak and never say so.
#
# Nor is a finer grid worth its time. The existing spacing already brackets the
# peak on both sides at both budgets, and run-to-run variation is the same size
# as the difference between neighbouring settings. Extra points would move the
# chosen setting by less than the noise on the setting already chosen. Pick the
# best of the range that exists and spend the box time on repeats instead.
#
#   ./runCeilingMatrix.sh
#
# Env: BUDGET (4), SB_CAPS, SB_MAX, SETTLE
set -uo pipefail
cd "$(dirname "$0")" || exit 1
HERE=$PWD

BUDGET="${BUDGET:-4}"
SB_CAPS="${SB_CAPS-2500m 3g 3500m}"
SB_MAX="${SB_MAX:-60}"
export SETTLE="${SETTLE:-15000}"
STAMP=$(date -u +%Y%m%d%H%M%S)
SUM="$HERE/reports/$STAMP-ceiling-matrix.txt"
. "$(dirname "$0")/harness-env.sh"

{
  echo "# ceiling matrix  budget=${BUDGET}GiB  every user active"
  echo "# started $(date -u +%FT%TZ)  git=$(git -C .. rev-parse --short HEAD)"
  echo "# heaps: $SB_CAPS"
} | tee "$SUM"

# Nothing from an earlier run may be alive: a leftover server would be measured
# instead of the one under test.
wait_quiet() {
  # A scope whose server was killed at teardown exits non-zero and lingers as
  # a FAILED unit with no cgroup behind it. Counting those as running made every
  # cell after the first wait out this loop in full -- ten minutes of nothing,
  # per cell, for units that were already dead. Clear them, then count only what
  # is actually active.
  systemctl --user reset-failed 2>/dev/null
  for i in $(seq 1 40); do
    n=$(systemctl --user list-units --type=scope --state=active --no-legend \
        2>/dev/null | grep -c 'ceil-')
    [ "$n" = "0" ] && break
    sleep 15
  done
  for i in $(seq 1 40); do
    avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    [ "$avail" -gt 3500 ] && break
    echo "  waiting for the host to recover: ${avail} MB available"
    sleep 15
  done
  # The LOAD box has to be quiet too. It can still be tearing down the previous
  # cell's browsers when the next one starts its ramp, and those compete with
  # the tenants being measured -- a cell would then be judged against a
  # generator doing someone else's work. Only this box was ever checked.
  for i in $(seq 1 40); do
    n=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOXB" \
        'c=0; for d in /proc/[0-9]*; do k=$(cat "$d/comm" 2>/dev/null);
           case "$k" in headless_shell|chrome) c=$((c+1));; esac; done; echo $c' \
        2>/dev/null)
    [ "${n:-0}" = "0" ] && break
    echo "  waiting for the load box: ${n} browsers still up"
    sleep 15
  done
}

run_one() {
  local ch=$1 cap=$2 max=$3
  echo "" | tee -a "$SUM"
  echo "================ $ch  -Xmx$cap  budget ${BUDGET}G ================" | tee -a "$SUM"
  wait_quiet
  ./runCeiling.sh "$ch" "$cap" "$BUDGET" "$max" > "/tmp/ceilmatrix-$ch-$cap.out" 2>&1
  local log
  log=$(ls -t reports/*ceiling-"$ch"-"$cap".log 2>/dev/null | head -1)
  if [ -z "$log" ]; then
    echo "  NO LOG — the run did not start; see /tmp/ceilmatrix-$ch-$cap.out" | tee -a "$SUM"
    tail -5 "/tmp/ceilmatrix-$ch-$cap.out" | sed 's/^/    /' | tee -a "$SUM"
    return
  fi
  # The filter is the summary. A line the cell log records but this does not copy
  # is a line nobody reads: runCeiling.sh has printed "scope alive thru" and the
  # overcount WARNING since the void-cell fix, and neither had ever reached a
  # matrix summary, because neither was listed here. That is how the 3 GiB 2000m
  # cell came to be summarised as a clean 100% fill after the kernel killed it.
  # So: every line that can disqualify a cell belongs in this alternation.
  # 'WARNING *:' matches the harness's own warning and not the driver's
  # "WARNING scenario.tenants ..." note, which has no colon.
  grep -E 'last healthy|stopped at|why|peak in the scope|oom kills|kernel kill|java OOM|tenants reached|scope alive thru|RESULT *:|WARNING *:' \
    "$log" | sed 's/^/  /' | tee -a "$SUM"
  local mon
  mon=$(ls -t reports/*ceiling-"$ch"-"$cap".monitor.csv 2>/dev/null | head -1)
  [ -n "$mon" ] && python3 - "$mon" <<'PY' | tee -a "$SUM"
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    print("  monitor: no rows")
    raise SystemExit
def mx(k):
    vals = [float(r[k]) for r in rows if r.get(k) not in ("", None)]
    return max(vals) if vals else 0
print("  peaks: mem %.0f MB (%.0f%%)  cpu %.0f%%  runq %.0f  tx %.1f Mbps"
      "  sendq_max %.0f kB  threads %.0f  pids %.0f"
      % (mx("cg_mem_mb"), mx("cg_mem_pct"), mx("cpu_pct"), mx("runq"),
         mx("tx_mbps"), mx("sendq_max_kb"), mx("threads"), mx("pids")))
peer = [float(r["peer_load1"]) for r in rows if r.get("peer_load1") not in ("", None)]
print("  load box peak load1: %.2f  (if this approaches its core count, the"
      " generator was the limit, not the server)" % (max(peer) if peer else 0))
PY
}

for cap in $SB_CAPS; do run_one sb "$cap" "$SB_MAX"; done

echo "" | tee -a "$SUM"
echo "# matrix finished $(date -u +%FT%TZ)" | tee -a "$SUM"
echo "SUMMARY: $SUM"
echo "==== MATRIX DONE ===="
