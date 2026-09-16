#!/usr/bin/env bash
# runReport.sh against six REAL round-2 cells (testdata/round2): the picture mode,
# the published-count mode, several-heaps mode, the per-heap and all-runs tables.
#   ./testRunReport.sh [-v]
set -uo pipefail
cd "$(dirname "$0")" || exit 1
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; FAILED_NAMES=()
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  \033[32mok\033[0m   %-58s %s\n' "$1" "$2"
      else FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m %-58s expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; return 0; }

KIT="$TMP/kit"; H="$KIT/harness"; R="$H/reports"; mkdir -p "$H/scenario" "$R"
cp runReport.sh "$KIT/"; cp harness/probes.sh harness/harness-env.sh "$H/"; cp harness/scenario/renderReport.py "$H/scenario/"
cp testdata/round2/*.log testdata/round2/*.monitor.csv testdata/round2/*.samples.csv "$R/"
chmod +x "$KIT/runReport.sh"
L() { echo "$R/$1"; }
META='budget_gb=4
sb_max=60
settle_ms=15000
server_jar=/somewhere/customer-app-2.3.jar
server_jar_sha256=abcdef0123456789
swing_bridge_version=1.3.0
skeleton_rev=53d7028
kit_rev=deadbee
box_cores=16
box_ram_gb=31
box_virt=none
boxb_cores=14'
report() { (cd "$KIT" && bash ./runReport.sh "$1" 2>&1); }

echo "A: one run per heap -- a picture"
cat > "$R/20260911000000-sizing.txt" <<M
sizing_stamp=20260911000000
heaps=2500m 2560m 2625m
heap_range=explicit
repeats=1
$META
cell 2500m $(L 20260910120305-ceiling-sb-2500m.log) 34 YES
cell 2560m $(L 20260911104905-ceiling-sb-2560m.log) 38 YES
cell 2625m $(L 20260910232410-ceiling-sb-2625m.log) 39 no:server-died
M
out=$(report "$R/20260911000000-sizing.txt"); rc=$?; A="$R/20260911000000-report.md"
ok "exit 0, report written"                       "0 yes" "$rc $([ -s "$A" ] && echo yes)"
ok "picture mode, no published count"             "yes" "$(grep -q '^\*\*A picture, not a published count\.\*\*' "$A" && ! grep -q 'concurrent active users fit' "$A" && echo yes)"
ok "  one line per heap with count and cause"     "yes" "$(grep -q '^- `-Xmx2560m` -> \*\*38\*\* healthy users, publishable; the budget: memory reached 100 %' "$A" && echo yes)"
ok "  the killed heap named as such"              "yes" "$(grep -q '^- `-Xmx2625m` -> \*\*39\*\* healthy users, not publishable: server-died; the budget, hard: the kernel killed' "$A" && echo yes)"
ok "  says how to get a number"                   "yes" "$(grep -q 'SIZING_REPEATS=3 ./runSizing.sh' "$A" && echo yes)"
ok "per heap: three rows, sorted by heap"         "2500m|2560m|2625m" "$(sed -n '/^## Per heap/,/^## Every/p' "$A" | grep -oE '^\| (2500m|2560m|2625m) ' | tr -d '| ' | paste -sd'|')"
ok "  2560m: ~62 % of budget, 1 of 1 publishable" "yes" "$(grep -qE '^\| 2560m \| 6[12] % \| 38 \| 1 of 1 \|' "$A" && echo yes)"
ok "  heap at the ceiling from the samples CSV"   "yes" "$(grep -E '^\| 2560m ' "$A" | grep -q '2560 / 2560 MB (100 %)' && echo yes)"
ok "  2625m: 0 of 1 publishable"                  "yes" "$(grep -E '^\| 2625m ' "$A" | grep -q '| 0 of 1 |' && echo yes)"
ok "every cell: three rows"                       "3" "$(sed -n '/^## Every cell/,/^## /p' "$A" | grep -cE '^\| (2500m|2560m|2625m) \| 1 \|')"
ok "  heap committed column present per cell"     "3" "$(sed -n '/^## Every cell/,/^## /p' "$A" | grep -cE '\| 2[56][0-9]{2} / 2[56][0-9]{2} MB \(100 %\) \|')"   # 2626 / 2625: the JVM rounds to its region size
ok "no all-runs section with a single manifest"   "0" "$(grep -c '^## All runs so far' "$A")"
ok "how-to-read explains heap at the ceiling"     "yes" "$(grep -q 'Heap at the ceiling' "$A" && echo yes)"

echo "B: three runs at one heap -- a published count"
cat > "$R/20260911010000-sizing.txt" <<M
sizing_stamp=20260911010000
heaps=2560m
heap_range=explicit
repeats=3
$META
cell 2560m $(L 20260911080704-ceiling-sb-2560m.log) 39 YES
cell 2560m $(L 20260911083610-ceiling-sb-2560m.log) 41 YES
cell 2560m $(L 20260911091231-ceiling-sb-2560m.log) 39 YES
M
out=$(report "$R/20260911010000-sizing.txt"); rc=$?; B="$R/20260911010000-report.md"
ok "exit 0"                                       "0" "$rc"
ok "headline: median 39 in a 4 GB budget at 2560m" "yes" "$(grep -q '^\*\*39 concurrent active users fit in a 4 GB budget\*\*.*`-Xmx2560m`' "$B" && echo yes)"
ok "  three publishable runs, in run order"       "yes" "$(grep -q 'median of 3 publishable runs at that heap: 39, 41, 39 (min 39, max 41)' "$B" && echo yes)"
ok "  what ran out first: the budget"             "yes" "$(grep -q '^\*\*What ran out first:\*\* the budget: memory reached 100 % of 4096 MB' "$B" && echo yes)"
ok "per heap: one row, median 39"                 "yes" "$(grep -E '^\| 2560m \| 6[12] % \| 39, 41, 39 \| 3 of 3 \| 39 \|' "$B" >/dev/null && echo yes)"
ok "all runs so far: present with two runs"       "yes" "$(grep -q '^Every cell from 2 sizing runs' "$B" && echo yes)"
ok "  2560m across both: 4 runs, median 39"       "yes" "$(sed -n '/^## All runs so far/,/^## How/p' "$B" | grep -E '^\| 2560m ' | grep -q '| 4 of 4 | 39 |' && echo yes)"
ok "  2625m across both: 0 of 1"                  "yes" "$(sed -n '/^## All runs so far/,/^## How/p' "$B" | grep -E '^\| 2625m ' | grep -q '| 0 of 1 |' && echo yes)"
ok "stdout repeats the headline"                  "yes" "$(case "$out" in *"39 concurrent active users"*) echo yes;; esac)"
ok "load box late median / peak both shown"       "yes" "$(sed -n '/^## Every cell/,/^## /p' "$B" | grep -E '^\| 2560m \| 3 ' | grep -qE '\| 3\.6 / 31\.3 \|' && echo yes)"
ok "  and the transient noted, not used"          "yes" "$(sed -n '/^## Every cell/,/^## /p' "$B" | grep -E '^\| 2560m \| 3 ' | grep -q 'launch transient, not sustained' && echo yes)"

echo "C: two heaps each with repeated runs -- the table decides"
cat > "$R/20260911020000-sizing.txt" <<M
sizing_stamp=20260911020000
heaps=2500m 2560m
heap_range=explicit
repeats=2
$META
cell 2500m $(L 20260910120305-ceiling-sb-2500m.log) 34 YES
cell 2500m $(L 20260910120305-ceiling-sb-2500m.log) 34 YES
cell 2560m $(L 20260911080704-ceiling-sb-2560m.log) 39 YES
cell 2560m $(L 20260911091231-ceiling-sb-2560m.log) 39 YES
M
report "$R/20260911020000-sizing.txt" >/dev/null; C="$R/20260911020000-report.md"
ok "several-heaps mode: no single headline"       "yes" "$(grep -q '^\*\*Several heaps have repeated runs; the table ranks them -- choose\.\*\*' "$C" && ! grep -q 'concurrent active users fit' "$C" && echo yes)"
ok "  medians by heap listed"                     "yes" "$(grep -q 'Medians by heap: `-Xmx2500m` 34, `-Xmx2560m` 39' "$C" && echo yes)"
ok "  all runs so far now spans 3 runs"           "yes" "$(grep -q '^Every cell from 3 sizing runs' "$C" && echo yes)"

echo "degenerate"
out=$(report "$R/nope-sizing.txt"); rc=$?
ok "missing manifest -> exit 1, says runSizing"   "1 yes" "$rc $(case "$out" in *"runSizing.sh first"*) echo yes;; esac)"
echo "sizing_stamp=20260911030000
heaps=2500m
heap_range=explicit
repeats=1
$META
cell 2500m - -1 no:no-log" > "$R/20260911030000-sizing.txt"
report "$R/20260911030000-sizing.txt" >/dev/null; rc=$?
ok "a cell with no log renders, exit 0"           "0 yes" "$rc $(grep -q -- '- `-Xmx2500m` -> \*\*-\*\* healthy users, not publishable: no-log' "$R/20260911030000-report.md" && echo yes)"

echo
if [ "$FAIL" -eq 0 ]; then printf '  \033[32m%d passed, 0 failed\033[0m\n' "$PASS"; exit 0
else printf '  \033[31m%d passed, %d FAILED:\033[0m %s\n' "$PASS" "$FAIL" "${FAILED_NAMES[*]}"; exit 1; fi
