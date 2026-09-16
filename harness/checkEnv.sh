#!/usr/bin/env bash
# Preflight: show what the harness resolved, and whether it exists.
#
# Run this before a sweep, and first of all on a new box. Every failure this
# reports is one that otherwise surfaces as a plausible wrong answer rather
# than an error: a missing guest jar yields a cell of zeros, an unreachable
# load box yields a ceiling of zero, a stale A_IP yields a server that looks
# healthy while nothing drives it.
#
#   ./checkEnv.sh
set -uo pipefail
cd "$(dirname "$0")" || exit 1
. ./harness-env.sh

FAIL=0
WARN=0

ok()   { printf '  \033[32mOK\033[0m    %-22s %s\n' "$1" "$2"; }
bad()  { printf '  \033[31mFAIL\033[0m  %-22s %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %-22s %s\n' "$1" "$2"; WARN=$((WARN + 1)); }

echo "harness: $HARNESS_HOME"
echo "repo:    $REPO_ROOT  ($(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'not a git tree'))"
echo

echo "-- this box --"
if [ -n "$A_IP" ]; then ok "A_IP" "$A_IP  (detected; export A_IP to override)"
else bad "A_IP" "could not detect an address; export A_IP=<addr>"; fi

case "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" in
  cgroup2fs) ok "cgroup" "v2" ;;
  *)         bad "cgroup" "not cgroup v2; the budget cannot be enforced" ;;
esac

if [ -f /sys/fs/cgroup/user.slice/user-"$(id -u)".slice/user@"$(id -u)".service/memory.max ]; then
  ok "memory delegated" "user slice can set MemoryMax"
else
  bad "memory delegated" "memory controller not delegated to the user slice; MemoryMax will be ignored"
fi

[ "$(systemd-detect-virt 2>/dev/null)" = none ] \
  && ok "bare metal" "systemd-detect-virt=none" \
  || warn "bare metal" "systemd-detect-virt=$(systemd-detect-virt 2>/dev/null || echo '?') -- fine, but say so in the write-up"

printf '  %-6s %-22s %s\n' "INFO" "cpu" "$(nproc) logical / $(lscpu 2>/dev/null | sed -n 's/^Core(s) per socket: *//p' | head -1) cores per socket"
printf '  %-6s %-22s %s\n' "INFO" "ram" "$(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
echo

echo "-- swing bridge --"
# Kit: with GUEST_JVM_EXTRA set (even empty) the guest comes via the argv cache
# and the JOSM jar check does not apply.
if [ -z "${GUEST_JVM_EXTRA+x}" ]; then
  if [ -r "$JOSM_JAR" ]; then
    ok "JOSM_JAR" "$JOSM_JAR ($(sha256sum "$JOSM_JAR" | cut -c1-16), $(stat -c%s "$JOSM_JAR") bytes)"
  elif [ -e "$JOSM_JAR" ]; then
    bad "JOSM_JAR" "exists but is not readable: $JOSM_JAR"
  else
    bad "JOSM_JAR" "not found: $JOSM_JAR   (export JOSM_JAR=<path>)"
  fi
fi
# Kit: the scenario is the customer's and has no default -- the first run of
# runBoxA.sh writes SCENARIO; the JOSM example's lives under examples/josm/.
S="${SCENARIO:-}"
if [ -z "$S" ]; then bad "scenario" "SCENARIO is not set (the first run of ./runBoxA.sh writes it; SCENARIO.md)"
elif [ -r "$S" ]; then ok "scenario" "$S"
else bad "scenario" "not found: $S"; fi
# A data file the scenario needs, only when SCENARIO_DATA names one.
D="${SCENARIO_DATA:-}"
if [ -n "$D" ]; then
  [ -r "$D" ] && ok "scenario data" "$D" || bad "scenario data" "not found: $D"
fi
echo

echo "-- load box --"
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOXB" true 2>/dev/null; then
  RH=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOXB" 'echo $HOME' 2>/dev/null)
  ok "BOXB" "$BOXB reachable (remote HOME=$RH, $(ssh -o BatchMode=yes "$BOXB" nproc 2>/dev/null) cores)"
  if ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOXB" \
       "curl -sf -o /dev/null --max-time 8 http://$A_IP:8088/ || curl -sf -o /dev/null --max-time 8 http://$A_IP:8080/" 2>/dev/null; then
    ok "boxb -> this box" "reached a server on $A_IP"
  else
    warn "boxb -> this box" "no server answering on $A_IP:8088 or :8080 (expected if none is running)"
  fi
else
  bad "BOXB" "$BOXB unreachable over ssh  (export BOXB=<alias>; keep the address in ~/.ssh/config)"
fi

echo "-- browser temp headroom on the load box --"
# The single most expensive resource a ramp consumes, and the one that fails
# silently: Chromium writes ~540 MB per tenant into TMPDIR as unlinked-but-open
# files, so du shows nothing while df drains, and running out stops the ramp
# without an error.
if ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOXB" true 2>/dev/null; then
  SHM_FREE=$(ssh -o BatchMode=yes "$BOXB" "df -Pm /dev/shm 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null)
  DISK_FREE=$(ssh -o BatchMode=yes "$BOXB" "df -Pm \$HOME 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null)
  if [ "${SHM_FREE:-0}" -ge 8192 ]; then
    ok "browser temp" "/dev/shm/sbbench, ${SHM_FREE} MB free -> room for ~$(( SHM_FREE / 540 )) tenants"
  else
    warn "browser temp" "/dev/shm only ${SHM_FREE:-?} MB free; would fall back to disk (${DISK_FREE:-?} MB, ~$(( ${DISK_FREE:-0} / 540 )) tenants)"
  fi
else
  warn "browser temp" "load box unreachable; cannot check"
fi
echo

if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL check(s) FAILED, $WARN warning(s). Do not start a sweep: each of these"
  echo "produces a wrong answer rather than an error."
  exit 1
fi
echo "all checks passed${WARN:+, $WARN warning(s)}."
