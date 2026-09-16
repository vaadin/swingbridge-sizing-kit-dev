#!/usr/bin/env bash
# Box B side of a two-box run: drive the scenario against Box A, DETACHED.
#
# Why the browsers live on the other box: with them beside the server, the
# server's RSS goes non-monotonic as tenants are added — local Chromium competes
# for the same RAM and the kernel reclaims the server's pages — and the server's
# memory has to be its own to read. Measured, not assumed.
#
# Why detached: a run takes tens of minutes and an ssh session is not a reliable
# container for one. A dropped link ("Bad packet length ... Connection
# corrupted") killed a ramp at start-up. The work is started with setsid on Box B
# and writes to a log there; this side only tails it and reconnects, so a drop
# costs visibility rather than the run.
#
#   ./runScenarioRemote.sh sb <tenants> <cycles>
#
# Env:
#   A_IP             how Box B must address THIS box. From harness-env.sh,
#                    which detects it rather than storing a literal.
#   BOXB             ssh host alias for the load box (harness-env.sh)
#   BOXB_ROOT        the ONLY directory this script may use on Box B.
#                    Defaults to $HOME/dev_load_v2 as resolved ON THE LOAD
#                    BOX -- it is a remote path, so it cannot come from this
#                    box's $HOME. Everything the remote side reads or writes
#                    lives under it: the checkout, the generated script, its
#                    log, and the scratch area below.
#   BOXB_CHECKOUT    repo path on Box B (default $BOXB_ROOT/vaadin-swing-bridge)
#   BOXB_TMPDIR      browser temp dir. Defaults to /dev/shm/sbbench when the
#                    load box has >=8 GB of tmpfs free, else falls back to
#                    $BOXB_ROOT/supplemental/tmp with a warning. Chromium's temp
#                    files are large and invisible to du; the run refuses to
#                    start if the chosen directory cannot hold the ramp.
#   SCENARIO_REMOTE  scenario path in BOX B's checkout, not this one
#                    (kit) when unset and SCENARIO names a file on THIS box, the
#                    file is copied to Box B's scratch area for this run and the
#                    driver reads it from there -- so any path works, and an
#                    edit here is picked up by the next cell
#   FOLLOW_INTERVAL  seconds between log polls (default 20)
#   FOLLOW_IDLE_MAX  stop following after this long with no new output
#                    (default 2700). Catches a hung or vanished remote run.
#                    Measured: a HEALTHY ramp went silent for 1150 s and
#                    940 s in two runs, because the driver emits in bursts
#                    and a first tenant can wait 180 s for its guest. 1800
#                    left only 1.6x margin over that; a plausible 900 would
#                    have voided a good cell.
#   FOLLOW_MAX       absolute seconds to follow before giving up (default 21600)
#   SSH_FAIL_MAX     consecutive ssh TRANSPORT failures before giving up
#                    (default 10)
#
# Nothing here may touch /tmp, ~/.m2 or ~/.cache. The load box is not ours to
# scatter files across, and Maven and Playwright both default outside the
# permitted area, so both are redirected into $BOXB_ROOT/supplemental below.
#
# Addresses are DHCP-volatile and have already changed five times, twice onto a
# different subnet entirely. Verify with `ip -4 addr` here and
# `ssh $BOXB hostname -I` there before every run.
set -uo pipefail

CHANNEL="${1:-sb}"
TENANTS="${2:-1}"
CYCLES="${3:-1}"
. "$(dirname "$0")/harness-env.sh"
A="$A_IP"
# A remote path cannot default from this box's $HOME, so ask the load box.
if [ -z "${BOXB_ROOT:-}" ]; then
  BOXB_ROOT=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOXB" \
              'echo "$HOME/dev_load_v2"' 2>/dev/null)
  [ -n "$BOXB_ROOT" ] || {
    echo "ERROR: cannot reach $BOXB to resolve BOXB_ROOT. Export BOXB_ROOT," >&2
    echo "       or fix the $BOXB entry in ~/.ssh/config." >&2
    exit 1; }
fi
BOXB_CHECKOUT="${BOXB_CHECKOUT:-$BOXB_ROOT/vaadin-swing-bridge}"
SCRATCH="$BOXB_ROOT/supplemental"
# Where the browsers put their temp files. Chromium honours TMPDIR (verified:
# its .org.chromium.* files land there), and it writes a LOT -- measured ~260
# to 540 MB per tenant in files it unlinks and keeps open, which df sees and du
# does not. On a box with more RAM than disk, point this at a tmpfs.
# Chromium writes 260-540 MB per tenant into TMPDIR, as files it unlinks and
# keeps open: df sees them, du does not. A full ramp therefore wants 10-20 GB,
# and running out does not raise an error -- it stops the ramp, which reads as a
# generator ceiling. Three of this project's early "ceilings" (42, 32, 32) were
# exactly that, and it was twice misdiagnosed as memory. So: prefer a tmpfs, say
# so when falling back to disk, and refuse to start if the chosen directory
# cannot hold the ramp being asked for.
if [ -z "${BOXB_TMPDIR:-}" ]; then
  SHM_FREE_MB=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOXB" \
      "df -Pm /dev/shm 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null)
  if [ "${SHM_FREE_MB:-0}" -ge 8192 ]; then
    BOXB_TMPDIR="/dev/shm/sbbench"
  else
    BOXB_TMPDIR="$SCRATCH/tmp"
    echo "WARN: /dev/shm on $BOXB has only ${SHM_FREE_MB:-?} MB free;" >&2
    echo "      falling back to on-disk $BOXB_TMPDIR. Watch df, not du." >&2
  fi
fi
SCN_REMOTE="${SCENARIO_REMOTE:-}"
# Driver properties for the remote side, e.g. the active-ramp settings.
# The quotes must be ESCAPED so they survive into the generated script: inside
# ${var:+word} the quotes are removed by expansion, which wrote
#   export EXTRA=-Dscenario.activeRamp=true -Dscenario.maxTenants=8 ...
# and bash kept only the first token, silently dropping every later property.
EXTRA_R="${EXTRA_REMOTE:-}"
# Both ports are overridable so several servers can be driven independently in
# one budget, each with its own log and its own bounds server. Without that,
# every ramp targets 8088 and reads one shared bounds log, and a tenant can only
# be matched to a server by correlation -- which is how tenants get attributed
# to the wrong one, silently.
PORT="${TARGET_PORT:-8088}"
BOUNDS_PORT="${BOUNDS_PORT:-8099}"
STAMP=$(date -u +%Y%m%d%H%M%S)-p$PORT
RLOG="$SCRATCH/scenario-$CHANNEL-$STAMP.log"
RSCRIPT="$SCRATCH/run-$STAMP.sh"
# Kit: the scenario is a file on THIS box -- harness.env's SCENARIO, at any path --
# and the driver runs on the load box. Ship the file beside the run's log every
# time, so the driver reads what the operator last saved and a path outside the
# checkout works. Without this, runScenario.sh over there falls back to a path
# from the round-2 layout that the kit does not have. SCENARIO_REMOTE still wins.
if [ -z "$SCN_REMOTE" ] && [ -n "${SCENARIO:-}" ]; then
  [ -r "$SCENARIO" ] || { echo "ERROR: SCENARIO is not readable: $SCENARIO" >&2; exit 1; }
  SCN_REMOTE="$SCRATCH/scenario-$STAMP.json"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOXB" "mkdir -p '$SCRATCH'" \
    && scp -q -o BatchMode=yes "$SCENARIO" "$BOXB:$SCN_REMOTE" \
    || { echo "ERROR: could not copy $SCENARIO to $BOXB:$SCN_REMOTE" >&2; exit 1; }
  echo "scenario:   $SCENARIO -> $BOXB:$SCN_REMOTE"
fi

# Will the browser temp directory hold this ramp? ~540 MB per tenant, measured.
WANT_T=$(printf '%s' "${EXTRA_R:-}" | grep -oE 'maxTenants=[0-9]+' | cut -d= -f2 | tail -1)
WANT_T="${WANT_T:-$TENANTS}"
NEED_MB=$(( WANT_T * 540 ))
FREE_MB=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOXB" \
    "mkdir -p '$BOXB_TMPDIR' 2>/dev/null; df -Pm '$BOXB_TMPDIR' 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null)
echo "browser temp: $BOXB:$BOXB_TMPDIR  free ${FREE_MB:-?} MB, ramp to $WANT_T needs ~$NEED_MB MB"
if [ "${FREE_MB:-0}" -lt "$NEED_MB" ]; then
  echo "ERROR: not enough room in $BOXB_TMPDIR for a ramp to $WANT_T tenants." >&2
  echo "       Chromium's temp files are unlinked-but-open: du will show almost" >&2
  echo "       nothing while df drains. Exhausting this stops the ramp with no" >&2
  echo "       error, which reads as a generator ceiling and is not one." >&2
  echo "       Point BOXB_TMPDIR at a tmpfs, or lower maxTenants." >&2
  exit 1
fi

# Fail early and clearly if the load box cannot reach this one: every later
# symptom of that is obscure.
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOXB" \
    "curl -sf -o /dev/null --max-time 8 http://$A:$PORT/" 2>/dev/null; then
  echo "ERROR: $BOXB cannot reach http://$A:$PORT/ — check A_IP and that the" >&2
  echo "       server is up. Both addresses are DHCP-volatile." >&2
  exit 1
fi

ssh "$BOXB" "mkdir -p $SCRATCH && cat > $RSCRIPT" <<EOF
#!/usr/bin/env bash
cd $BOXB_CHECKOUT/${BOXB_HARNESS_SUBDIR:-swing-bridge-memory-harness} || exit 1
echo "# ramp target: http://$A:$PORT/  bounds: http://$A:$BOUNDS_PORT/log"
# Maven and Playwright both default outside the permitted area (~/.m2 and
# ~/.cache/ms-playwright). Redirected, not tidied up afterwards: a default that
# writes where it should not is a defect even when nobody notices.
# java.io.tmpdir too, not just TMPDIR: the JVM takes its temp directory from
# its own default rather than the environment, and Playwright unpacks its
# driver there — measured escaping to /tmp/playwright-java-* with TMPDIR
# already set.
export MAVEN_OPTS="\${MAVEN_OPTS:-} -Dmaven.repo.local=$SCRATCH/.m2 -Djava.io.tmpdir=$SCRATCH/tmp"
export PLAYWRIGHT_BROWSERS_PATH="$SCRATCH/ms-playwright"
export TMPDIR="$BOXB_TMPDIR"
mkdir -p "\$TMPDIR"
export URL="http://$A:$PORT/"
export BOUNDS_LOG="http://$A:$BOUNDS_PORT/log"
export TENANTS="$TENANTS"
export MEM_CMD='curl -sf "http://$A:$BOUNDS_PORT/sample?cycle={cycle}&tenants={tenants}&tenant={tenant}"'
${SCN_REMOTE:+export SCENARIO=\"$SCN_REMOTE\"}
${EXTRA_R:+export EXTRA=\"$EXTRA_R\"}
./runScenario.sh $CHANNEL $CYCLES
echo "REMOTE-EXIT=\$?"
EOF

ssh "$BOXB" "chmod +x $RSCRIPT && setsid nohup $RSCRIPT \
  > $RLOG 2>&1 < /dev/null & echo started"
echo "remote log: $BOXB:$RLOG"
echo "driving:    http://$A:$PORT/  bounds http://$A:$BOUNDS_PORT/log"

# Follow it, reconnecting if the link drops. Nothing is filtered out: an inverse
# filter that hid FAIL lines cost three separate diagnoses in this project.
#
# The loop has to be able to give up. It was `while true` with ssh's stderr sent
# to /dev/null, which made "the box is gone" and "nothing new yet" the same
# observation -- an empty chunk -- so a run that never wrote REMOTE-EXIT left a
# poller ssh'ing into a black hole every 20 s, silently. Two abandoned
# calibration runs did precisely that for 27 hours. Four bounds now end it:
#   REMOTE-EXIT seen  the run finished -- the only success path
#   FOLLOW_IDLE_MAX   no new output for this long: hung, or the box went away
#   FOLLOW_MAX        absolute backstop for a run that prints but never ends
#   SSH_FAIL_MAX      consecutive transport failures (ssh rc 255), which is a
#                     different fact from the log not existing yet (rc 1)
INTERVAL="${FOLLOW_INTERVAL:-20}"
IDLE_MAX="${FOLLOW_IDLE_MAX:-2700}"
ABS_MAX="${FOLLOW_MAX:-21600}"
SSH_FAIL_MAX="${SSH_FAIL_MAX:-10}"

# Every abnormal exit says this, because it is the thing that will otherwise be
# got wrong: the remote side is setsid'd and does NOT stop when we stop looking.
reattach() {
  echo "  NOTE: the remote run is detached and may still be running." >&2
  echo "        re-attach with: ssh $BOXB tail -f $RLOG" >&2
}

started=$SECONDS
last_output=$SECONDS
ssh_fails=0
last=0
while true; do
  # stderr merged, then classified by rc: the remote tail's own stderr is
  # already suppressed, so anything here on rc 255 is ssh's own complaint and
  # must not be mistaken for log content.
  chunk=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOXB" \
    "tail -n +$((last + 1)) $RLOG 2>/dev/null" 2>&1)
  rc=$?

  if [ "$rc" -eq 255 ]; then
    ssh_fails=$((ssh_fails + 1))
    echo "WARN: ssh to $BOXB failed ($ssh_fails/$SSH_FAIL_MAX): ${chunk:-no message}" >&2
    if [ "$ssh_fails" -ge "$SSH_FAIL_MAX" ]; then
      echo "ERROR: $BOXB unreachable for $ssh_fails consecutive attempts." >&2
      reattach
      exit 125
    fi
  else
    ssh_fails=0
    if [ -n "$chunk" ]; then
      printf '%s\n' "$chunk"
      last=$((last + $(printf '%s\n' "$chunk" | wc -l)))
      last_output=$SECONDS
      if printf '%s\n' "$chunk" | grep -q 'REMOTE-EXIT='; then
        RC=$(printf '%s\n' "$chunk" | sed -n 's/.*REMOTE-EXIT=\([0-9]*\).*/\1/p' | tail -1)
        break
      fi
    fi
  fi

  if [ $((SECONDS - last_output)) -ge "$IDLE_MAX" ]; then
    echo "ERROR: no new output in $RLOG for ${IDLE_MAX}s; remote run hung or gone." >&2
    reattach
    exit 124
  fi
  if [ $((SECONDS - started)) -ge "$ABS_MAX" ]; then
    echo "ERROR: follow deadline ${ABS_MAX}s reached with no REMOTE-EXIT." >&2
    reattach
    exit 124
  fi
  sleep "$INTERVAL"
done

# Exit with the remote status. Without this the script always succeeded, and a
# caller could not tell a completed run from a failed one -- the marker line was
# emitted either way, and until the escaping above was fixed it did not even
# carry a number.
[ -n "${RC:-}" ] || { echo "no REMOTE-EXIT code parsed" >&2; exit 1; }
echo "remote exit: $RC"
exit "$RC"
