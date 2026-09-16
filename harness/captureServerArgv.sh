#!/usr/bin/env bash
# The server command line for a sizing run: COMPOSED, not captured.
#
# Same contract as the round-2 script this replaces, so runCeiling.sh's call site
# needs no edit:
#   ./captureServerArgv.sh || exit 1
#   mapfile -d '' -t ARGV < target/server-argv.cache
# Entry 0 is the java binary. runCeiling.sh prepends -Xmx itself, per cell, and
# drops any -Xmx/-Xms/-agentlib it finds -- so none is written here. The cache
# path is fixed and printed only to stderr; the original explains why a caller
# must never depend on this script's stdout.
#
# Why composed: round 2 captured a throwaway `spring-boot:run`'s argv from /proc,
# because the playground's flags lived in its pom and Maven must not sit inside
# the memory budget. Here the server is the customer's skeleton-starter clone,
# packaged with `mvn clean package` and launched as `java <flags> -jar <jar>`.
# In production the pom's <jvmArguments> do not apply, so the flags are the kit's
# own (jvm-flags.conf) and there is nothing to capture.
#
# Inputs, from harness.env:
#   SIZING_CLONE_DIR      the customer's skeleton-starter clone. Required.
#   SIZING_JAR            the packaged jar. Default target/<finalName>.jar, with
#                         finalName resolved from the clone's pom -- not a glob,
#                         which picks a sources/javadoc jar when one is present.
#   SIZING_APPLIBS        the guest jar directory. Default <clone>/applibs.
#   SIZING_PORT           default 8088, the port runCeiling.sh waits on.
#   GUEST_MANIFEST_FLAGS  the guest jar's own Add-Exports/Add-Opens, repeated on
#                         the command line: the JVM honours manifest module flags
#                         for `java -jar` only, and the bridge launches the guest
#                         by main class. Space-separated.
#   SIZING_EXTRA_JVM      anything else, space-separated. Never -Xmx.
#   SIZING_MAIN_CLASS     the guest's main class, passed as -Dsizing.mainClass for the
#                         kit's own view (VIEW=sizing); a view of your own needs neither
#   SIZING_ARGS           its main() arguments, ONE -Dsizing.args entry; the view splits
#                         it on whitespace
#   SB_VERSION, M2_REPO   normally resolved from the clone's pom; set to skip Maven.
#   JAVA_HOME             preferred java; else the first java on PATH.
#
# ARGV_FRESH=1 forces a re-render. ARGV_CHECK=1 reports the cache and exits.
# Every failure below is one that would otherwise surface as a plausible wrong
# answer: a server that never started reads as a ceiling of zero.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
. ./harness-env.sh
HERE=$PWD
CACHE="$HERE/target/server-argv.cache"
RESOLVED="$HERE/target/server-argv.resolved"
FLAGS="$HERE/jvm-flags.conf"
mkdir -p "$HERE/target"

die() { echo "ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------ the clone
CLONE="${SIZING_CLONE_DIR:-}"
[ -n "$CLONE" ] || die "SIZING_CLONE_DIR is not set. Point it at your skeleton-starter clone in harness.env."
[ -d "$CLONE" ]  || die "SIZING_CLONE_DIR is not a directory: $CLONE"
[ -r "$CLONE/pom.xml" ] || die "no readable pom.xml in SIZING_CLONE_DIR=$CLONE"

# ------------------------------------------------------------ three values from the pom
# finalName, swing-bridge.version and settings.localRepository -- resolved by
# Maven itself rather than parsed out of XML, exactly as the skeleton README has
# a developer do by hand. Cached per pom checksum; they change only when it does.
evaluate() {
  mvn -q -f "$CLONE/pom.xml" help:evaluate -Dexpression="$1" -DforceStdout 2>/dev/null
}
POM_SHA=$(sha256sum "$CLONE/pom.xml" | cut -d' ' -f1)
if [ -z "${ARGV_FRESH:-}" ] && [ -r "$RESOLVED" ] && [ "$(sed -n 1p "$RESOLVED")" = "$POM_SHA" ]; then
  FINAL_NAME=$(sed -n 2p "$RESOLVED")
  SB_VERSION="${SB_VERSION:-$(sed -n 3p "$RESOLVED")}"
  M2_REPO="${M2_REPO:-$(sed -n 4p "$RESOLVED")}"
else
  FINAL_NAME=$(evaluate project.build.finalName)
  [ -n "$FINAL_NAME" ] || die "could not resolve project.build.finalName from $CLONE/pom.xml (does 'mvn -q validate' pass there?)"
  SB_VERSION="${SB_VERSION:-$(evaluate swing-bridge.version)}"
  M2_REPO="${M2_REPO:-$(evaluate settings.localRepository)}"
  printf '%s\n' "$POM_SHA" "$FINAL_NAME" "$SB_VERSION" "$M2_REPO" > "$RESOLVED"
fi
case "$SB_VERSION" in [0-9]*) ;; *) die "swing-bridge.version resolved to '$SB_VERSION'; expected a version like 1.3.0" ;; esac
[ -d "$M2_REPO" ] || die "settings.localRepository resolved to '$M2_REPO', which is not a directory"

# ------------------------------------------------------------ the jar and the guest
JAR="${SIZING_JAR:-$CLONE/target/$FINAL_NAME.jar}"
[ -r "$JAR" ] || die "packaged jar not found: $JAR
       Run 'mvn clean package' in $CLONE (runBoxA.sh does this), or set SIZING_JAR."
APPLIBS="${SIZING_APPLIBS:-$CLONE/applibs}"
[ -d "$APPLIBS" ] || die "guest jar directory not found: $APPLIBS (SIZING_APPLIBS)"
[ "$(find "$APPLIBS" -maxdepth 1 -name '*.jar' | wc -l)" -gt 0 ] \
  || die "no *.jar in $APPLIBS -- that is where your Swing application's jar(s) go"

JAVA="${JAVA_HOME:+$JAVA_HOME/bin/java}"
JAVA="${JAVA:-$(command -v java || true)}"
[ -n "$JAVA" ] && [ -x "$JAVA" ] || die "no java binary (set JAVA_HOME or put java on PATH)"

for tok in ${GUEST_MANIFEST_FLAGS:-} ${SIZING_EXTRA_JVM:-}; do
  case "$tok" in
    -Xmx*|-Xms*) die "'$tok' is the sweep's variable: runCeiling.sh sets -Xmx per cell. Remove it from GUEST_MANIFEST_FLAGS / SIZING_EXTRA_JVM." ;;
    -agentlib:*|-Xdebug|-Xrunjdwp*) die "'$tok': no debug agent in a measured run." ;;
  esac
done
# The kit's view starts whatever -Dsizing.mainClass names; without it every tenant
# fails at once and the cell reads as a capacity of zero.
if [ "${VIEW:-}" = sizing ] && [ -z "${SIZING_MAIN_CLASS:-}" ]; then
  die "VIEW=sizing is the kit's own view, which starts the class named by -Dsizing.mainClass -- and SIZING_MAIN_CLASS is empty.
       Set it in harness.env (the first run of ./runBoxA.sh asks for it), or set VIEW to your own view's route."
fi

# ------------------------------------------------------------ compose
[ -r "$FLAGS" ] || die "missing $FLAGS"
ARGV=("$JAVA")
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  line=${line//@LOCAL_REPO@/$M2_REPO}
  line=${line//@SB_VERSION@/$SB_VERSION}
  ARGV+=("$line")
done < "$FLAGS"
# Every jar the flags name must exist -- the same check the original applied to
# its cached command, because a fingerprint of the inputs cannot see a missing
# artifact and the JVM would fail at start-up inside the scope.
for tok in "${ARGV[@]}"; do
  case "$tok" in
    *.jar|*.jar=*|*=*.jar)
      for p in $(printf '%s' "$tok" | tr '=:' '\n\n' | grep -E '\.jar$'); do
        [ -e "$p" ] || die "flag names a jar that does not exist: $p
       (swing-bridge $SB_VERSION in $M2_REPO -- has the clone been built once, so Maven fetched it?)"
      done ;;
  esac
done
for tok in ${GUEST_MANIFEST_FLAGS:-}; do ARGV+=("$tok"); done
ARGV+=("-Djava.awt.headless=false"
       "-Dserver.port=${SIZING_PORT:-8088}"
       "-Dapplibs.dir=$APPLIBS"
       "-Dswingbridge.consoleLogPrefix=true"
       "-Dswingbridge.includeUserInLogs=false")
# For the kit's view: the main class, and the arguments as one entry (the view
# splits on whitespace; the loop below would split them into separate flags).
[ -n "${SIZING_MAIN_CLASS:-}" ] && ARGV+=("-Dsizing.mainClass=$SIZING_MAIN_CLASS")
[ -n "${SIZING_ARGS:-}" ]       && ARGV+=("-Dsizing.args=$SIZING_ARGS")
for tok in ${SIZING_EXTRA_JVM:-}; do ARGV+=("$tok"); done
ARGV+=("-jar" "$JAR")

# ------------------------------------------------------------ write, or report
TMP="$CACHE.tmp.$$"
printf '%s\0' "${ARGV[@]}" > "$TMP"
if [ -n "${ARGV_CHECK:-}" ]; then
  if [ -s "$CACHE" ] && cmp -s "$TMP" "$CACHE"; then rm -f "$TMP"; echo "VALID   $CACHE (${#ARGV[@]} entries)"; exit 0; fi
  rm -f "$TMP"
  [ -s "$CACHE" ] && { echo "STALE   would re-render (${#ARGV[@]} entries)"; exit 1; }
  echo "ABSENT  no cache yet"; exit 1
fi
if [ -z "${ARGV_FRESH:-}" ] && [ -s "$CACHE" ] && cmp -s "$TMP" "$CACHE"; then
  rm -f "$TMP"
  echo "# server argv: cached (${#ARGV[@]} entries, unchanged) -> $CACHE" >&2
  exit 0
fi
mv -f "$TMP" "$CACHE"
echo "# server argv: composed ${#ARGV[@]} entries -> $CACHE" >&2
echo "#   $JAVA ... -jar $JAR" >&2
echo "#   applibs $APPLIBS, swing-bridge $SB_VERSION from $M2_REPO" >&2
