#!/usr/bin/env bash
# Every branch of every probe in probes.sh, against fixtures.
#
# Written because four defects reached real measurements before anything here
# existed, each one found by a twenty-minute run rather than by a test:
#   - a cgroup counter that cannot see the kill that ends a cell
#   - a probe reading a journal line our own fix had deleted
#   - a verdict computed in a subshell, so it never reached the report
#   - a unit with no journal history reading as clean
# Three of the four were invisible in the output: the cell looked fine.
#
#   ./testProbes.sh          run everything
#   ./testProbes.sh -v       also print the passing cases
#
# Runs under the same shell options as runCeiling.sh, because two of the defects
# WERE the shell options -- pipefail turning a successful grep -q into a failure,
# and grep -c exiting 1 while printing 0.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; FAILED_NAMES=()

ok() { # name expected actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  \033[32mok\033[0m   %-58s %s\n' "$1" "$2"
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$1")
    printf '  \033[31mFAIL\033[0m %-58s expected [%s] got [%s]\n' "$1" "$2" "$3"
  fi
  return 0
}

# journalctl is stubbed: probes.sh calls it unqualified, so this shadows the
# binary. JOURNAL holds what it should print; JOURNAL_RC its exit code.
JOURNAL=""; JOURNAL_RC=0
journalctl() { printf '%s' "$JOURNAL"; return "$JOURNAL_RC"; }

. ./probes.sh

# =====================================================================
echo "scope_kill_verdict — 4 outcomes, and every way the evidence can be odd"
# =====================================================================
kv() { UNIT=test.scope; KILL_GRACE_S=3; scope_kill_verdict; printf '%s/%s' "$KILL_VERDICT" "${KILL_GAP_S:-none}"; }

JOURNAL=""                                              ; ok "empty journal -> unknown"            "unknown/none" "$(kv)"
JOURNAL="-- No entries --"                              ; ok "'No entries' -> unknown, not clean"   "unknown/none" "$(kv)"
JOURNAL="-- Journal begins at Mon 2026-08-31. --"       ; ok "banner only -> unknown"               "unknown/none" "$(kv)"
JOURNAL_RC=1; JOURNAL=""                                ; ok "journalctl fails -> unknown"          "unknown/none" "$(kv)"
JOURNAL_RC=0

JOURNAL="2026-09-09T23:45:11+03:00 h systemd[1]: Started ceil.scope
2026-09-09T23:52:18+03:00 h systemd[1]: ceil.scope: Deactivated successfully."
ok "started + clean exit -> no kill"                    "no/none"      "$(kv)"

JOURNAL="2026-09-09T23:45:11+03:00 h systemd[1]: Started ceil.scope
2026-09-09T23:52:18+03:00 h systemd[1]: ceil.scope: A process of this unit has been killed by the OOM killer.
2026-09-09T23:52:18+03:00 h systemd[1]: ceil.scope: Consumed 15min."
ok "kill, unit ends same second -> server died"         "server/0"     "$(kv)"

JOURNAL="2026-09-09T23:45:11+03:00 h systemd[1]: Started ceil.scope
2026-09-10T00:02:30+03:00 h systemd[1]: ceil.scope: A process of this unit has been killed by the OOM killer.
2026-09-10T00:02:31+03:00 h systemd[1]: ceil.scope: Consumed 7min."
ok "kill, unit ends 1s later -> server died"            "server/1"     "$(kv)"

mk_gap() { JOURNAL="2026-09-09T23:00:00+03:00 h systemd[1]: Started ceil.scope
2026-09-09T23:10:00+03:00 h systemd[1]: ceil.scope: A process of this unit has been killed by the OOM killer.
$1 h systemd[1]: ceil.scope: Consumed 1min."; }
mk_gap "2026-09-09T23:10:03+03:00"; ok "gap exactly at the 3s threshold -> server"  "server/3"  "$(kv)"
mk_gap "2026-09-09T23:10:04+03:00"; ok "gap 4s, one past threshold -> survived"     "survived/4" "$(kv)"
mk_gap "2026-09-09T23:10:53+03:00"; ok "gap 53s (measured: a server that lived on) -> survived" "survived/53" "$(kv)"
mk_gap "2026-09-09T23:09:58+03:00"; ok "end BEFORE kill (clock skew) -> server"     "server/-2" "$(kv)"
mk_gap "not-a-timestamp";           ok "unparseable end -> server, not a pass"      "server/BAD" "$(kv)"

JOURNAL="2026-09-09T23:00:00+03:00 h systemd[1]: Started ceil.scope
2026-09-09T23:10:00+03:00 h systemd[1]: ceil.scope: A process of this unit has been killed by the OOM killer."
ok "kill, unit still running -> survived/alive"         "survived/alive" "$(kv)"

JOURNAL="2026-09-09T23:00:00+03:00 h systemd[1]: Started ceil.scope
2026-09-09T23:05:00+03:00 h systemd[1]: ceil.scope: A process of this unit has been killed by the OOM killer.
2026-09-09T23:06:00+03:00 h systemd[1]: ceil.scope: A process of this unit has been killed by the OOM killer.
2026-09-09T23:07:00+03:00 h systemd[1]: ceil.scope: Consumed 7min."
ok "several kills -> measured from the FIRST"           "survived/120" "$(kv)"

JOURNAL="2026-09-03T21:30:28+03:00 h systemd[1]: Started ceil.scope
2026-09-03T21:33:54+03:00 h systemd[1]: ceil.scope: A process of this unit has been killed by the OOM killer.
2026-09-03T21:33:55+03:00 h systemd[1]: ceil.scope: Failed with result 'oom-kill'.
2026-09-03T21:33:55+03:00 h systemd[1]: ceil.scope: Consumed 3min."
ok "old OOMPolicy=stop log still reads as server death" "server/1"     "$(kv)"

JOURNAL="2026-09-09T23:00:00+03:00 h systemd[1]: Started ceil.scope
2026-09-09T23:10:00+03:00 h systemd[1]: ceil.scope: A process of this unit has been killed by the OOM killer.
2026-09-09T23:11:40+03:00 h systemd[1]: ceil.scope: Deactivated successfully."
ok "'Deactivated successfully' counts as the end"       "survived/100" "$(kv)"

UNIT=test.scope; KILL_GRACE_S=3; scope_kill_verdict; rc=$?
ok "returns 0 even on the unknown path"                 "0"            "$rc"

# The cases above all pin KILL_GRACE_S, so none of them exercises the DEFAULT --
# mutation testing caught that: widening the default from 3s to 60s left the
# whole suite green. These two run with it unset.
kvd() { UNIT=test.scope; unset KILL_GRACE_S; scope_kill_verdict; printf '%s/%s' "$KILL_VERDICT" "${KILL_GAP_S:-none}"; }
mk_gap "2026-09-09T23:10:03+03:00"; ok "default grace: 3s -> server"     "server/3"  "$(kvd)"
mk_gap "2026-09-09T23:10:04+03:00"; ok "default grace: 4s -> survived"   "survived/4" "$(kvd)"
mk_gap "2026-09-09T23:10:53+03:00"; ok "default grace: 53s -> survived"  "survived/53" "$(kvd)"

# =====================================================================
echo "kernel_kill_count — the grep -c trap"
# =====================================================================
skc() { UNIT=test.scope; kernel_kill_count; }
JOURNAL="nothing here"                                  ; ok "no kills -> exactly one 0"  "0" "$(skc)"
JOURNAL=""                                              ; ok "no journal -> 0"            "0" "$(skc)"
JOURNAL="a killed by the OOM killer"                    ; ok "one kill -> 1"              "1" "$(skc)"
JOURNAL="killed by the OOM killer
killed by the OOM killer
killed by the OOM killer"                               ; ok "three kills -> 3"           "3" "$(skc)"

# =====================================================================
echo "oom_count — missing files, no matches, rotation"
# =====================================================================
printf 'fine\nfine\n'                              > "$TMP/a.log"
printf 'java.lang.OutOfMemoryError: heap\nx\n'     > "$TMP/b.log"
printf 'OutOfMemoryError\noutofmemoryerror\nOOM\n' > "$TMP/c.log"
printf 'OutOfMemoryError\n'                        > "$TMP/c.log.1"
: > "$TMP/empty.log"
BOUNDS=""            ; ok "BOUNDS unset -> 0"                       "0" "$(oom_count)"
BOUNDS="$TMP/nope"   ; ok "BOUNDS missing -> 0"                     "0" "$(oom_count)"
BOUNDS="$TMP/empty.log"; ok "empty file -> 0"                       "0" "$(oom_count)"
BOUNDS="$TMP/a.log"  ; ok "no matches -> 0, not '0 0'"              "0" "$(oom_count)"
BOUNDS="$TMP/b.log"  ; ok "one match -> 1"                          "1" "$(oom_count)"
BOUNDS="$TMP/c.log"  ; ok "case-insensitive, plus .1 -> 2+1=3"      "3" "$(oom_count)"

# =====================================================================
echo "live_thru / monitor_peaks — the CSV after the scope dies"
# =====================================================================
H='t,elapsed_s,tenants,cg_mem_mb,cg_mem_max_mb,cg_mem_pct,cg_oom_kills'
printf '%s\n' "$H" > "$TMP/h.csv"
{ printf '%s\n' "$H"; printf 'x,5,10,1000,2048,48,0\nx,10,19,2000,2048,97,0\n'; } > "$TMP/live.csv"
{ printf '%s\n' "$H"; printf 'x,5,10,1000,2048,48,0\nx,10,18,2040,2048,99,1\nx,15,19,,,,\nx,20,19,,,,\n'; } > "$TMP/died.csv"
{ printf '%s\n' "$H"; printf 'x,5,3,,,,\nx,10,4,,,,\n'; } > "$TMP/allblank.csv"
ok "live throughout -> last tenant count"    "19"              "$(live_thru "$TMP/live.csv")"
ok "blank after the scope dies -> 18"        "18"              "$(live_thru "$TMP/died.csv")"
ok "header only -> 0"                        "0"               "$(live_thru "$TMP/h.csv")"
ok "missing csv -> 0"                        "0"               "$(live_thru "$TMP/nope.csv")"
ok "no argument -> 0"                        "0"               "$(live_thru)"
ok "every row blank -> 0"                    "0"               "$(live_thru "$TMP/allblank.csv")"
ok "peaks, live csv"                         "2000 2048 97.7 0" "$(monitor_peaks "$TMP/live.csv")"
ok "peaks ignore blank rows, keep the kill"  "2040 2048 99.6 1" "$(monitor_peaks "$TMP/died.csv")"
ok "peaks, header only -> zeros"             "0 0 0.0 0"       "$(monitor_peaks "$TMP/h.csv")"
ok "peaks, missing csv -> zeros"             "0 0 0.0 0"       "$(monitor_peaks "$TMP/nope.csv")"
ok "peaks, no argument -> zeros"             "0 0 0.0 0"       "$(monitor_peaks)"

# =====================================================================
echo "void_reason — every exit code, not just the two deadlines"
# =====================================================================
ok "rc 0 -> not void"          ""    "$(void_reason 0)"
ok "rc 124 -> deadline"        "yes" "$([ -n "$(void_reason 124)" ] && echo yes)"
ok "rc 125 -> unreachable"     "yes" "$([ -n "$(void_reason 125)" ] && echo yes)"
ok "rc 1 (driver died) -> VOID"   "yes" "$([ -n "$(void_reason 1)" ] && echo yes)"
ok "rc 137 (SIGKILL) -> VOID"     "yes" "$([ -n "$(void_reason 137)" ] && echo yes)"
ok "no argument -> not void"   ""    "$(void_reason)"
ok "rc 1 names the code"       "yes" "$(case "$(void_reason 1)" in *"exited 1"*) echo yes;; esac)"

# =====================================================================
echo "overcount_warning"
# =====================================================================
ok "19 counted, 18 live -> warns"     "yes" "$([ -n "$(overcount_warning 19 18)" ] && echo yes)"
ok "19 counted, 19 live -> silent"    ""    "$(overcount_warning 19 19)"
ok "18 counted, 19 live -> silent"    ""    "$(overcount_warning 18 19)"
ok "0 and 0 -> silent"                ""    "$(overcount_warning 0 0)"
ok "non-numeric -> silent, no crash"  ""    "$(overcount_warning x 3)"
ok "warning states the safe count"    "yes" "$(case "$(overcount_warning 19 18)" in *"AT MOST 18"*) echo yes;; esac)"

# =====================================================================
echo "print_verdict — the composed report, which is where every defect showed"
# =====================================================================
# A probe can be right while the report is wrong: "oom kills : 0" was true of the
# counter and false of the cell. These assert what the lines say TOGETHER.
say() { printf '%s\n' "$*"; }
verdict() { # -> the whole report as one blob
  BUDGET=4 PEAK_MB=4096 BUDGET_MB=4096 PEAK_PCT=100.0 OOM="${V_OOM:-0}"
  OOM_NOW="${V_NOW:-0}" OOM_BASE="${V_BASE:-0}" RAMP_RC="${V_RC:-0}"
  LIVE_T="${V_LIVE:-10}" UNIT=test.scope KILL_GRACE_S=3
  TCOUNT="$TMP/tcount"; printf '%s' "${V_TENANTS:-10}" > "$TCOUNT"
  print_verdict
}
has()  { case "$2" in *"$1"*) printf yes ;; esac; }
noth() { case "$2" in *"$1"*) printf FOUND ;; esac; }

# --- a clean cell
JOURNAL="2026-09-09T23:00:00+03:00 h systemd[1]: Started x
2026-09-09T23:10:00+03:00 h systemd[1]: x: Deactivated successfully."
V_OOM=0 V_NOW=0 V_BASE=0 V_RC=0 V_LIVE=10 V_TENANTS=10; R=$(verdict)
ok "clean: says no kernel kill"        "yes" "$(has 'kernel kill       : no' "$R")"
ok "clean: no VOID line"               ""    "$(noth 'RESULT' "$R")"
ok "clean: no overcount warning"       ""    "$(noth 'WARNING' "$R")"
ok "clean: reports scope alive thru"   "yes" "$(has 'scope alive thru  : 10' "$R")"
ok "clean: java OOM zero"              "yes" "$(has 'java OOM in log   : 0' "$R")"

# --- the server died (this is the cell that once read as a clean 100% fill)
JOURNAL="2026-09-09T23:00:00+03:00 h systemd[1]: Started x
2026-09-09T23:10:00+03:00 h systemd[1]: x: A process of this unit has been killed by the OOM killer.
2026-09-09T23:10:00+03:00 h systemd[1]: x: Consumed 10min."
R=$(verdict)
ok "server death: says YES"            "yes" "$(has 'kernel kill       : YES' "$R")"
ok "server death: says not publishable" "yes" "$(has 'not publishable' "$R")"
ok "server death: NOT 'survived'"      ""    "$(noth 'survived' "$R")"
ok "server death: cgroup 0 is labelled" "yes" "$(has 'SURVIVED only' "$R")"

# --- a process was killed and the unit went on for 53 s: the server survived
JOURNAL="2026-09-09T23:00:00+03:00 h systemd[1]: Started x
2026-09-09T23:10:00+03:00 h systemd[1]: x: A process of this unit has been killed by the OOM killer.
2026-09-09T23:10:53+03:00 h systemd[1]: x: Consumed 10min."
V_OOM=1; R=$(verdict); V_OOM=0
ok "survived: says so, with the gap"   "yes" "$(has 'kernel kill       : survived' "$R")"
ok "survived: names the gap"           "yes" "$(has '(53 s)' "$R")"
ok "survived: counts 1 process"        "yes" "$(has '1 process(es) taken' "$R")"
ok "survived: not disqualifying, but suspicious" "yes yes" "$(has 'Not disqualifying' "$R") $(has 'inspect the cell' "$R")"
ok "survived: no YES verdict"          ""    "$(noth 'kernel kill       : YES' "$R")"

# --- no journal record at all
JOURNAL="-- No entries --"; R=$(verdict)
ok "no record: UNKNOWN"                "yes" "$(has 'UNKNOWN' "$R")"
ok "no record: never reads as no-kill" ""    "$(noth 'kernel kill       : no' "$R")"

# --- the driver died: rc 1
JOURNAL="2026-09-09T23:00:00+03:00 h systemd[1]: Started x
2026-09-09T23:10:00+03:00 h systemd[1]: x: Deactivated successfully."
V_RC=1; R=$(verdict); V_RC=0
ok "rc 1: VOID stated up front"        "yes" "$(has 'RESULT            : VOID' "$R")"
ok "rc 1: names the exit code"         "yes" "$(has 'exited 1' "$R")"
ok "rc 1: tenants marked PARTIAL"      "yes" "$(has 'PARTIAL' "$R")"

V_RC=124; R=$(verdict); V_RC=0
ok "rc 124: VOID, deadline wording"    "yes" "$(has 'deadline' "$R")"
V_RC=125; R=$(verdict); V_RC=0
ok "rc 125: VOID, unreachable wording" "yes" "$(has 'unreachable' "$R")"

# --- counted past the last live reading
V_LIVE=9 V_TENANTS=10; R=$(verdict); V_LIVE=10 V_TENANTS=10
ok "overcount: warns"                  "yes" "$(has 'WARNING' "$R")"
ok "overcount: states the safe count"  "yes" "$(has 'AT MOST 9' "$R")"

# --- java OOM deltas
V_NOW=5 V_BASE=0; R=$(verdict)
ok "oom delta: plain count"            "yes" "$(has 'java OOM in log   : 5' "$R")"
V_NOW=12 V_BASE=8; R=$(verdict)
ok "oom delta: subtracts the baseline" "yes" "$(has 'java OOM in log   : 4' "$R")"
ok "oom delta: says what was held"     "yes" "$(has 'log held 8' "$R")"
V_NOW=2 V_BASE=8; R=$(verdict)
ok "oom rotated: never negative"       ""    "$(noth 'log   : -' "$R")"
ok "oom rotated: says ROTATED"         "yes" "$(has 'ROTATED' "$R")"
V_NOW=0 V_BASE=0

# =====================================================================
echo "cell_verdict / pick_winner — the publishability bar applied mechanically"
# =====================================================================
# The unattended run picks the published heap with these. A bug here produces a
# defensible-looking wrong number, which is the failure this project keeps
# making, so every disqualifying condition gets a case.
mkcell() { # file users kill joom live reached [void]
  { echo "==== WHAT RAN OUT ===="
    [ "${7:-0}" = 1 ] && echo "  RESULT            : VOID -- the ramp exited 1, no ceiling measured."
    [ "$2" != "-" ] && echo "  last healthy : $2 active tenants"
    echo "  kernel kill       : $3"
    echo "  java OOM in log   : $4"
    echo "  tenants reached   : $6"
    echo "  scope alive thru  : $5 tenants"
  } > "$TMP/$1"
}
mkcell clean.log   17 "no (systemd journal)"                  0 19 19
mkcell surv.log    10 "survived -- 1 process(es) taken, the unit outlived the kill (53 s)" 0 10 10
mkcell died.log    19 "YES -- the SERVER died (unit ended 0s)" 0 19 19
mkcell joom.log    26 "no (systemd journal)"                  2 27 27
mkcell unk.log     12 "UNKNOWN -- no journal record"          0 12 12
mkcell over.log    19 "no (systemd journal)"                  0 18 19
mkcell void.log    10 "no (systemd journal)"                  0 10 10 1
mkcell noverd.log  -  "no (systemd journal)"                  0 10 10
mkcell big.log     18 "no (systemd journal)"                  0 19 19

ok "clean cell is eligible"             "17 YES"                    "$(cell_verdict "$TMP/clean.log")"
ok "a survived kill stays eligible"     "10 YES"                    "$(cell_verdict "$TMP/surv.log")"
ok "server death disqualifies"          "19 no:server-died"         "$(cell_verdict "$TMP/died.log")"
ok "java OOM disqualifies, names count" "26 no:java-oom-2"          "$(cell_verdict "$TMP/joom.log")"
ok "UNKNOWN kill disqualifies"          "12 no:kill-unknown"        "$(cell_verdict "$TMP/unk.log")"
ok "overcount disqualifies"             "19 no:counted-past-live-scope" "$(cell_verdict "$TMP/over.log")"
ok "VOID disqualifies before anything"  "10 no:void"                "$(cell_verdict "$TMP/void.log")"
ok "no verdict line -> -1"              "-1 no:no-verdict"          "$(cell_verdict "$TMP/noverd.log")"
ok "missing log -> -1"                  "-1 no:missing-log"         "$(cell_verdict "$TMP/gone.log")"
ok "no argument -> -1"                  "-1 no:missing-log"         "$(cell_verdict)"

ok "winner: highest eligible count"     "1125m 17" "$(printf '1125m %s\n1250m %s\n' "$TMP/clean.log" "$TMP/died.log" | pick_winner)"
ok "winner: ignores the bigger but void" "1125m 17" "$(printf '1125m %s\n1200m %s\n' "$TMP/clean.log" "$TMP/void.log" | pick_winner)"
ok "winner: none eligible -> empty"     ""         "$(printf '1250m %s\n1875m %s\n' "$TMP/died.log" "$TMP/joom.log" | pick_winner)"
ok "winner: tie goes to the larger heap" "1200m 17" "$(printf '1125m %s\n1200m %s\n' "$TMP/clean.log" "$TMP/clean.log" | pick_winner)"
ok "winner: 18 beats 17"                "1200m 18" "$(printf '1125m %s\n1200m %s\n' "$TMP/clean.log" "$TMP/big.log" | pick_winner)"
ok "winner: empty input -> empty"       ""         "$(printf '' | pick_winner)"
ok "winner: a survived-kill cell can win" "96m 10" "$(printf '96m %s\n' "$TMP/surv.log" | pick_winner)"
# Mixed units: the original compared "${h%m}" numerically, so "3g" vs "2500m"
# was a non-numeric test and the tie went to whichever line came first.
ok "winner: tie, 3g beats 2500m"          "3g 17"    "$(printf '2500m %s\n3g %s\n' "$TMP/clean.log" "$TMP/clean.log" | pick_winner)"
ok "winner: tie, 3g beats 2500m, other order" "3g 17" "$(printf '3g %s\n2500m %s\n' "$TMP/clean.log" "$TMP/clean.log" | pick_winner)"
ok "winner: tie, 2500m beats 2g"          "2500m 17" "$(printf '2g %s\n2500m %s\n' "$TMP/clean.log" "$TMP/clean.log" | pick_winner)"
ok "winner: 18 at 2g still beats 17 at 3g" "2g 18"   "$(printf '3g %s\n2g %s\n' "$TMP/clean.log" "$TMP/big.log" | pick_winner)"

# =====================================================================
echo "heap_mb -- every suffix the JVM accepts, and garbage"
# =====================================================================
ok "2500m -> 2500"        "2500" "$(heap_mb 2500m)"
ok "3g -> 3072"           "3072" "$(heap_mb 3g)"
ok "3G -> 3072"           "3072" "$(heap_mb 3G)"
ok "1500M -> 1500"        "1500" "$(heap_mb 1500M)"
ok "2048k -> 2"           "2"    "$(heap_mb 2048k)"
ok "bare 1048576 = bytes -> 1" "1" "$(heap_mb 1048576)"
ok "garbage -> 0, no crash" "0"  "$(heap_mb 2.5g)"
ok "empty -> 0"           "0"    "$(heap_mb "")"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '  \033[32m%d passed, 0 failed\033[0m\n' "$PASS"; exit 0
else
  printf '  \033[31m%d passed, %d FAILED:\033[0m %s\n' "$PASS" "$FAIL" "${FAILED_NAMES[*]}"; exit 1
fi
