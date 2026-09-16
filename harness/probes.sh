# Everything that turns raw evidence into a verdict, in one sourceable file.
#
# These were inline in runCeiling.sh, where the only way to exercise them was to
# spend twenty minutes running a cell and see what came out. That is how four
# defects reached measurements: a counter that could not see the kill that ended
# a cell, a probe reading a journal line our own fix had deleted, a verdict
# computed in a subshell so it never reached the report, and a unit with no
# journal history reading as clean. Each was found by a run, not by a test.
#
# Sourced by runCeiling.sh and by testProbes.sh, which drives every branch of
# every function below against fixtures. Anything here that grows a new branch
# grows a case there in the same commit.
#
# Contract: no function exits, none writes outside its own stdout, and each one
# is total -- every input, including a missing file or a hostile string, maps to
# a defined answer. Where an answer is uncertain the functions fail towards
# DISQUALIFYING a cell, never towards passing it.

# ---------------------------------------------------------------- java OOMs
# Counts OutOfMemoryError in the server's log AND its rotated predecessor: a
# log that rotates mid-cell would otherwise make the total drop, which once
# produced "java OOM in log : -8".
#
# `grep -ci` prints 0 and STILL EXITS 1 on a file with no match, so a naive
# `|| echo 0` appends a second zero. Command substitution then yields "0 0" and
# the arithmetic breaks. The exit code is discarded deliberately instead.
oom_count() {
  local total=0 f n
  for f in "${BOUNDS:-}" "${BOUNDS:-}.1"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    n=$(grep -ci 'OutOfMemoryError' "$f" 2>/dev/null) || true
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    total=$((total + n))
  done
  printf '%s' "$total"
}

# ------------------------------------------------------- kernel kill verdict
# Sets KILL_VERDICT (unknown|no|survived|server) and KILL_GAP_S.
#
# NOT echo-and-capture: a caller using $(...) runs this in a subshell, and the
# gap never comes back. That shipped once.
#
# The discriminator is how long the unit outlived the kill, NOT the presence of
# "Failed with result 'oom-kill'". systemd wrote that line only because it was
# stopping the unit under OOMPolicy=stop; setting continue removed it, and a
# probe that looked for it then called every kill survivable -- exactly backwards
# for a single JVM, whose death IS the kill. Measured in round 2 over sixteen
# cells, the two populations do not overlap: a single-JVM unit ends 0-1 s after
# its kill, while a server that lost only a child process ran on for 42-73 s.
# Three seconds is a margin, not a tuning.
scope_kill_verdict() {
  KILL_VERDICT=unknown
  KILL_GAP_S=""
  local j k e n
  j=$(journalctl --user -u "$UNIT" --no-pager -o short-iso 2>/dev/null) || true
  # journalctl prints "-- No entries --" for a unit it never saw. That is not
  # empty and it is not a record, so count real timestamped lines. Getting this
  # wrong makes an unknown cell read as clean, the one direction that must never
  # fail.
  n=$(printf '%s\n' "$j" | grep -c '^[0-9][0-9][0-9][0-9]-') || true
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -gt 0 ] || return 0

  k=$(printf '%s\n' "$j" | grep 'killed by the OOM killer' | head -1 | awk '{print $1}')
  if [ -z "$k" ]; then KILL_VERDICT=no; return 0; fi

  e=$(printf '%s\n' "$j" \
      | grep -E 'Consumed|Deactivated successfully|Failed with result' \
      | tail -1 | awk '{print $1}')
  # No end record means the unit was still up when we asked, which only happens
  # when the server outlived the kill.
  if [ -z "$e" ]; then KILL_GAP_S=alive; KILL_VERDICT=survived; return 0; fi

  KILL_GAP_S=$(python3 -c "
from datetime import datetime as D
import sys
try:
    print(int((D.fromisoformat(sys.argv[2]) - D.fromisoformat(sys.argv[1])).total_seconds()))
except Exception:
    print('BAD')" "$k" "$e" 2>/dev/null) || KILL_GAP_S=BAD
  case "${KILL_GAP_S:-BAD}" in
    ''|BAD|-*) KILL_VERDICT=server ;;   # unparseable or end-before-kill: disqualify
    *[!0-9]*)  KILL_VERDICT=server ;;
    *) if [ "$KILL_GAP_S" -le "${KILL_GRACE_S:-3}" ]; then
         KILL_VERDICT=server
       else
         KILL_VERDICT=survived
       fi ;;
  esac
  return 0
}

# How many processes the kernel took. One for a single-JVM server that died;
# more only if the guest had spawned processes of its own.
kernel_kill_count() {
  local j n
  j=$(journalctl --user -u "$UNIT" --no-pager -o cat 2>/dev/null) || true
  n=$(printf '%s\n' "$j" | grep -c 'killed by the OOM killer') || true
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# ------------------------------------------------------- monitor CSV readers
# How far the ramp got while the scope was still ALIVE. Column 3 is the tenant
# count, column 4 cg_mem_mb, which goes blank once the cgroup is gone. A tenant
# counted after the last live reading was never observed being served.
live_thru() {
  local csv="${1:-}"
  [ -n "$csv" ] && [ -f "$csv" ] || { printf '0'; return 0; }
  awk -F, 'NR>1 && $4+0>0 {t=$3+0} END{printf "%d", t+0}' "$csv" 2>/dev/null || printf '0'
}

# Peak memory, the budget, the percentage and the cgroup kill counter, as
# "peak budget pct oom". Read from the monitor rather than from /sys after the
# run: the scope is gone by then, and the old reads there printed 0 MB in every
# cell ever recorded.
monitor_peaks() {
  local csv="${1:-}"
  if [ -z "$csv" ] || [ ! -f "$csv" ]; then printf '0 0 0.0 0'; return 0; fi
  awk -F, 'NR>1{if($4+0>p)p=$4+0; if($5+0>b)b=$5+0; if($7+0>k)k=$7+0}
     END{printf "%.0f %.0f %.1f %d", p+0, b+0, (b?100*p/b:0), k+0}' "$csv" 2>/dev/null \
    || printf '0 0 0.0 0'
}

# ------------------------------------------------------------ ramp exit code
# ANY non-zero exit is VOID. It used to be 124/125 only, so a driver that died
# of its own accord (rc 1) printed a full verdict block with only the ABSENCE of
# "last healthy" to mark it as nothing.
void_reason() {
  case "${1:-0}" in
    0) printf '' ;;
    124) printf 'VOID -- follow gave up on an idle/absolute deadline (rc 124), no ceiling measured' ;;
    125) printf 'VOID -- load box unreachable (rc 125), no ceiling measured' ;;
    *) printf 'VOID -- the ramp exited %s, no ceiling measured. Nothing below is a limit.' "$1" ;;
  esac
}

# The ramp keeps counting for a few seconds after the scope dies. A count past
# the last live reading is an overcount; five round-2 cells had exactly one.
overcount_warning() {
  local tenants="${1:-0}" live="${2:-0}"
  case "$tenants$live" in *[!0-9]*) return 0 ;; esac
  [ "$tenants" -gt "$live" ] || return 0
  printf 'the ramp counted past the last live cgroup reading; treat the served count as AT MOST %s' "$live"
}

# ------------------------------------------------------------ the verdict
# The composed report, as a function, because this is where the damage was done:
# every reporting defect so far was a cell that LOOKED like a measurement. A
# driver that died printed peak/oom/kernel-kill/tenants with only a missing
# "last healthy" to mark it as nothing; a kernel-killed cell printed
# "oom kills : 0"; the scope-alive-thru line existed but no summary carried it.
# None of that is visible from reading a probe in isolation -- it is a property
# of what the lines say TOGETHER, so the composition is tested as a unit in
# testProbes.sh against every combination of outcome.
#
# Reads: BUDGET PEAK_MB BUDGET_MB PEAK_PCT OOM OOM_NOW OOM_BASE RAMP_RC LIVE_T
#        TCOUNT UNIT, and say().
print_verdict() {
  say "==== WHAT RAN OUT ===="
  # 124 = follow deadline (idle or absolute), 125 = load box unreachable. Neither
  # is a measurement: the ramp stopped being watched, so nothing below is a limit.
  # The diagnostics still print -- they are useful for working out what happened --
  # but the cell must not be read, or parsed, as a capacity result.
  # ANY non-zero ramp exit is VOID. It used to be 124/125 only -- the follow
  # deadlines -- and everything else fell through to print a full verdict block.
  # A driver that died of its own accord (rc 1: maven/exec failure on the load
  # box) therefore produced peak, oom kills, kernel kill, tenants reached and
  # scope alive thru, with only the ABSENCE of "last healthy" to distinguish it
  # from a measurement. Two cells of the first confirmation attempt looked like
  # results that way. The runner cannot know why a driver failed; it can know
  # that a driver which did not exit 0 measured nothing.
  VOID_TXT=$(void_reason "${RAMP_RC:-0}")
  [ -n "$VOID_TXT" ] && say "  RESULT            : $VOID_TXT"

  say "  budget            : ${BUDGET} GiB, swap disabled"
  say "  peak in the scope : ${PEAK_MB:-0} MB of ${BUDGET_MB:-0} MB (${PEAK_PCT:-0}%)"
  say "  oom kills         : ${OOM:-0}  (cgroup counter -- kills the cell SURVIVED only)"
  scope_kill_verdict
  KILLED="$KILL_VERDICT"
  case "$KILLED" in
    server)
      say "  kernel kill       : YES -- the SERVER died (unit failed with oom-kill)"
      say "                      Not a tenant degrading: the kernel took the server."
      say "                      Counts stay valid up to 'scope alive thru', but the"
      say "                      cell is not publishable: the server did not survive." ;;
    survived)
      say "  kernel kill       : survived -- $(kernel_kill_count) process(es) taken, the unit outlived the kill ($([ "$KILL_GAP_S" = alive ] && echo 'still up when asked' || echo "${KILL_GAP_S} s"))"
      say "                      Not disqualifying: the server did not die. For a single-JVM"
      say "                      server this should not happen; inspect the cell before trusting it." ;;
    no)      say "  kernel kill       : no (systemd journal)" ;;
    *)       say "  kernel kill       : UNKNOWN -- no journal record for $UNIT" ;;
  esac
  if [ "${OOM_NOW:-0}" -lt "${OOM_BASE:-0}" ]; then
    # The count went DOWN, which a delta cannot represent: the product rotated its
    # own log mid-cell, so the baseline describes a file that no longer exists.
    # Left unhandled this printed "java OOM in log : -8" -- a negative count of
    # errors, which is the same species of nonsense as the constant 8 the delta
    # was introduced to kill.
    say "  java OOM in log   : ${OOM_NOW:-0}  (log ROTATED mid-cell; baseline of ${OOM_BASE} discarded, so this counts only what the new log holds)"
  elif [ "${OOM_BASE:-0}" -gt 0 ]; then
    say "  java OOM in log   : $(( ${OOM_NOW:-0} - ${OOM_BASE:-0} ))  (log held ${OOM_BASE} before this cell)"
  else
    say "  java OOM in log   : $(( ${OOM_NOW:-0} - ${OOM_BASE:-0} ))"
  fi
  if [ "${RAMP_RC:-0}" != 0 ]; then
    say "  tenants reached   : $(cat "$TCOUNT")  (PARTIAL -- not the limit)"
  else
    say "  tenants reached   : $(cat "$TCOUNT")"
  fi
  say "  scope alive thru  : ${LIVE_T:-0} tenants"
  OC_TXT=$(overcount_warning "$(cat "$TCOUNT" 2>/dev/null || echo 0)" "${LIVE_T:-0}")
  [ -n "$OC_TXT" ] && say "  WARNING           : $OC_TXT"
}

# --------------------------------------------------- reading a cell back
# The publishability bar as code. Unattended selection needs it applied
# mechanically, and a bug here would quietly publish the wrong heap -- the failure would be a
# defensible-looking number, which is the kind this project keeps producing.
#
# Reads the cell's own log rather than re-deriving from the journal: the log
# records what was true when the run happened, and journal retention is finite.
#
# Prints "<users> YES" or "<users> no:<reason>"; users is -1 when the cell never
# reached a verdict at all.
cell_verdict() {
  local log="${1:-}" users kill joom void live reached
  [ -n "$log" ] && [ -f "$log" ] || { printf '%s' "-1 no:missing-log"; return 0; }
  users=$(grep -m1 -oP 'last healthy : \K[0-9]+'      "$log" 2>/dev/null)
  kill=$( grep -m1 -oP 'kernel kill       : \K[A-Za-z]+' "$log" 2>/dev/null)
  joom=$( grep -m1 -oP 'java OOM in log   : \K-?[0-9]+'  "$log" 2>/dev/null)
  live=$( grep -m1 -oP 'scope alive thru  : \K[0-9]+'    "$log" 2>/dev/null)
  reached=$(grep -m1 -oP 'tenants reached   : \K[0-9]+'  "$log" 2>/dev/null)
  void=$(grep -c 'RESULT            : VOID' "$log" 2>/dev/null) || true
  case "$void" in ''|*[!0-9]*) void=0 ;; esac

  [ "$void" -gt 0 ]      && { printf '%s' "${users:--1} no:void"; return 0; }
  [ -n "$users" ]        || { printf '%s' "-1 no:no-verdict"; return 0; }
  [ "$kill" = "YES" ]    && { printf '%s' "$users no:server-died"; return 0; }
  [ "$kill" = "UNKNOWN" ] && { printf '%s' "$users no:kill-unknown"; return 0; }
  [ -z "$kill" ]         && { printf '%s' "$users no:no-kill-line"; return 0; }
  case "${joom:-1}" in ''|*[!0-9]*) printf '%s' "$users no:joom-unreadable"; return 0 ;; esac
  [ "$joom" -gt 0 ]      && { printf '%s' "$users no:java-oom-$joom"; return 0; }
  # An overcount means the tail of the ramp was never observed against a live
  # scope; the count is only trustworthy up to 'scope alive thru'.
  if [ -n "$live" ] && [ -n "$users" ] && [ "$users" -gt "$live" ]; then
    printf '%s' "$users no:counted-past-live-scope"; return 0
  fi
  printf '%s' "$users YES"
}

# A -Xmx value in MB, so heaps written with different suffixes compare as
# numbers: 3g > 2500m. Bare digits are bytes, as the JVM reads them. Anything
# unparseable is 0 -- a tie then falls to whichever came first, never a crash.
heap_mb() {
  local v="${1:-}" n
  case "$v" in ''|*[!0-9kKmMgG]*) printf '0'; return 0 ;; esac
  n="${v%[kKmMgG]}"
  case "$n" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  case "$v" in
    *[gG]) printf '%d' $(( n * 1024 )) ;;
    *[mM]) printf '%d' "$n" ;;
    *[kK]) printf '%d' $(( n / 1024 )) ;;
    *)     printf '%d' $(( n / 1048576 )) ;;
  esac
}

# Highest eligible count wins; ties go to the LARGER heap, matching the
# published convention of handing a tie to the more generous setting.
# Input lines: "<heap> <log>". Prints "<heap> <users>", or "" if none qualify.
#
# Compared through heap_mb: the original stripped a trailing "m" and compared
# what was left, so "3g" against "2500m" was a non-numeric test and the tie
# went to whichever line came first. Round 2's own caps mixed units.
pick_winner() {
  local best_h="" best_u=-1 h log v u ok
  while read -r h log; do
    [ -n "$h" ] || continue
    v=$(cell_verdict "$log"); u=${v%% *}; ok=${v#* }
    [ "$ok" = "YES" ] || continue
    if [ "$u" -gt "$best_u" ]; then best_h=$h; best_u=$u
    elif [ "$u" -eq "$best_u" ] && [ "$(heap_mb "$h")" -gt "$(heap_mb "$best_h")" ]; then best_h=$h
    fi
  done
  [ -n "$best_h" ] && printf '%s %s' "$best_h" "$best_u"
}
