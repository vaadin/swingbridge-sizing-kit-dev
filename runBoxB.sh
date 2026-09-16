#!/usr/bin/env bash
# Box B -- the load generator. One-time setup, run ON the load box inside the
# kit checkout there. The ramp itself is always driven from Box A:
# runCeiling.sh -> runScenarioRemote.sh starts the driver here over ssh, so
# after this script you never touch this box again.
#
#   VIEW=<route> ./runBoxB.sh          build the driver, fetch Chromium, write this box's harness.env
#   SIZING_SKIP_BROWSERS=1             skip the Chromium download (already present)
#   SIZING_DRIVER_PREBUILT=1           skip the driver build (target/classes already there)
#
# What Box A's runScenarioRemote.sh expects of this box, unchanged from round 2:
# a root directory it may use and nothing outside it (BOXB_ROOT, default the
# directory this checkout sits in), a scratch area at $BOXB_ROOT/supplemental for
# the Maven repo, temp files and browsers, and the kit checked out under that root
# with the harness in harness/. Nothing here writes to ~/.m2 or ~/.cache.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
KIT=$PWD
H="$KIT/harness"
say() { echo "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. where we are
say "==== 1. where we are ===="
ROOT="${BOXB_ROOT:-$(cd "$KIT/.." && pwd)}"
case "$KIT" in "$ROOT"/*) ;; *) die "this checkout ($KIT) is not under BOXB_ROOT=$ROOT; Box A will look for it there" ;; esac
SCRATCH="$ROOT/supplemental"
mkdir -p "$SCRATCH/.m2" "$SCRATCH/tmp" "$SCRATCH/ms-playwright" || die "cannot create $SCRATCH"
[ -n "${VIEW:-}" ] || die "VIEW is not set. It is the @Route of your view -- the skeleton's default @Route(\"\") cannot be
       addressed, give the view a name such as @Route(\"sizing\") and run: VIEW=sizing ./runBoxB.sh"
say "  kit         : $KIT"
say "  BOXB_ROOT   : $ROOT"
say "  scratch     : $SCRATCH   (Maven repo, temp, browsers -- nothing outside it)"
say "  view        : /$VIEW"
say "  cores / RAM : $(nproc) / $(awk '/MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo)"

# ---------------------------------------------------------------- 2. the driver
say "==== 2. the driver, built from source ===="
export MAVEN_OPTS="${MAVEN_OPTS:-} -Dmaven.repo.local=$SCRATCH/.m2 -Djava.io.tmpdir=$SCRATCH/tmp"
if [ -n "${SIZING_DRIVER_PREBUILT:-}" ] && [ -d "$KIT/driver/target/classes" ]; then
  say "  skipped (SIZING_DRIVER_PREBUILT); using the existing build"
else
  say "  mvn -B -ntp package   in driver/  (repo: $SCRATCH/.m2)"
  ( cd "$KIT/driver" && mvn -B -ntp -q package ) || die "the driver did not build"
fi
CP="$KIT/driver/target/classes:$KIT/driver/target/dependency/*"
# Started with no arguments the driver must fail on ITS OWN check; anything else
# means the classpath is not complete. Captured, not piped: under pipefail
# `java | grep -q` returns java's exit 1 even when grep matches.
PROBE=$(java -Djava.io.tmpdir="$SCRATCH/tmp" -cp "$CP" com.vaadin.swingbridge.load.ScenarioDriver 2>&1 || true)
case "$PROBE" in
  *"scenario.file and -Dscenario.boundsLog are required"*)
    say "  ok: $(ls "$KIT/driver/target/dependency" | wc -l) runtime jars beside the classes; the driver starts" ;;
  *) die "the built driver does not start from $CP:
$(printf '%s\n' "$PROBE" | tail -5)" ;;
esac

# ---------------------------------------------------------------- 3. browsers
say "==== 3. browsers ===="
export PLAYWRIGHT_BROWSERS_PATH="$SCRATCH/ms-playwright"
if [ -n "${SIZING_SKIP_BROWSERS:-}" ]; then
  say "  skipped (SIZING_SKIP_BROWSERS)"
else
  say "  installing Chromium for $(uname -m) into $PLAYWRIGHT_BROWSERS_PATH"
  java -Djava.io.tmpdir="$SCRATCH/tmp" -cp "$CP" com.microsoft.playwright.CLI install chromium \
    || die "Chromium did not install (network? architecture $(uname -m)?)"
fi
say "  PLAYWRIGHT_BROWSERS_PATH=$PLAYWRIGHT_BROWSERS_PATH ($(du -sh "$PLAYWRIGHT_BROWSERS_PATH" 2>/dev/null | cut -f1))"

# ---------------------------------------------------------------- 4. temp headroom
say "==== 4. browser temp headroom ===="
# ~540 MB per tenant of unlinked-but-open Chromium files: df sees them, du does not,
# and running out stops the ramp with no error -- which reads as a ceiling.
SHM=$(df -Pm /dev/shm 2>/dev/null | awk 'NR==2{print $4}')
if [ "${SHM:-0}" -ge 8192 ]; then
  say "  /dev/shm ${SHM} MB free -> room for ~$(( SHM / 540 )) tenants"
else
  DISK=$(df -Pm "$SCRATCH" | awk 'NR==2{print $4}')
  say "  WARN /dev/shm only ${SHM:-?} MB free: runScenarioRemote.sh will fall back to disk"
  say "       at $SCRATCH/tmp (${DISK:-?} MB, ~$(( ${DISK:-0} / 540 )) tenants). Watch df, not du."
fi

# ---------------------------------------------------------------- 5. this box's harness.env
say "==== 5. this box's harness.env ===="
LAUNCH="java -Djava.io.tmpdir=$SCRATCH/tmp -cp $CP"
python3 - "$H/harness.env" "$VIEW" "$LAUNCH" <<'PY'
import re, sys
path, view, launch = sys.argv[1:4]
try:
    s = open(path).read()
except FileNotFoundError:
    s = "# Box B: written by runBoxB.sh; harness-env.sh sources this file.\n"
block = f"""# >>> sizing-kit: load box, derived by runBoxB.sh; your settings below override these >>>
VIEW={view}
DRIVER_LAUNCH="{launch}"
DRIVER_MAIN=com.vaadin.swingbridge.load.ScenarioDriver
# <<< sizing-kit load box <<<

"""
pat = re.compile(r"# >>> sizing-kit: load box.*?# <<< sizing-kit load box <<<\n\n?", re.S)
s = pat.sub(block, s, count=1) if pat.search(s) else block + s
open(path, "w").write(s)
PY
say "  VIEW=$VIEW"
say "  DRIVER_LAUNCH=\"$LAUNCH\""
say "  DRIVER_MAIN=com.vaadin.swingbridge.load.ScenarioDriver"

say "==== ready ===="
say "  Tell Box A where this is, in ITS harness/harness.env:"
say "    BOXB=<ssh alias for this box>"
say "    BOXB_ROOT=$ROOT"
say "    BOXB_CHECKOUT=$KIT"
say "  then on Box A: ./runSizing.sh"
