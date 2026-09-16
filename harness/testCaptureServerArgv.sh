#!/usr/bin/env bash
# Every branch of captureServerArgv.sh, against a fake clone and a stubbed mvn.
# Same idiom as testProbes.sh: fixtures in a temp dir, `ok name expected actual`.
#
#   ./testCaptureServerArgv.sh        run everything
#   ./testCaptureServerArgv.sh -v     also print the passing cases
set -uo pipefail
cd "$(dirname "$0")" || exit 1
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; FAILED_NAMES=()
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  \033[32mok\033[0m   %-58s %s\n' "$1" "$2"
      else FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m %-58s expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; return 0; }

# --- a harness dir of our own, so the real target/ is never touched
HD="$TMP/harness"; mkdir -p "$HD"
cp captureServerArgv.sh harness-env.sh jvm-flags.conf "$HD/"
# --- a fake clone: pom, packaged jar, applibs with one guest jar
CL="$TMP/clone"; mkdir -p "$CL/target" "$CL/applibs"
echo '<project/>' > "$CL/pom.xml"; : > "$CL/target/fakeapp-1.0.jar"; : > "$CL/applibs/guest.jar"
# --- a fake local repo with the two swing-bridge jars at version 9.9.9
M2="$TMP/m2"; mkdir -p "$M2/com/vaadin/swing-bridge-patch/9.9.9" "$M2/com/vaadin/swing-bridge-graphics/9.9.9"
: > "$M2/com/vaadin/swing-bridge-patch/9.9.9/swing-bridge-patch-9.9.9.jar"
: > "$M2/com/vaadin/swing-bridge-graphics/9.9.9/swing-bridge-graphics-9.9.9.jar"
# --- a stub mvn that answers help:evaluate the way the real one does, and counts calls
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/mvn" <<STUB
#!/usr/bin/env bash
echo x >> "$TMP/mvn-calls"
for a in "\$@"; do case "\$a" in
  -Dexpression=project.build.finalName) echo fakeapp-1.0 ;;
  -Dexpression=swing-bridge.version)    echo 9.9.9 ;;
  -Dexpression=settings.localRepository) echo "$M2" ;;
esac; done
STUB
chmod +x "$BIN/mvn"
: > "$BIN/java"; chmod +x "$BIN/java"      # entry 0 only has to be an executable
env_() { printf 'SIZING_CLONE_DIR=%s\n%s\n' "$CL" "${1:-}" > "$HD/harness.env"; }
run()  { (cd "$HD" && PATH="$BIN:/usr/bin:/bin" JAVA_HOME= bash ./captureServerArgv.sh "$@") ; }
argv() { mapfile -d '' -t A < "$HD/target/server-argv.cache"; printf '%s\n' "${A[@]}"; }
calls(){ [ -f "$TMP/mvn-calls" ] && wc -l < "$TMP/mvn-calls" || echo 0; }

# =====================================================================
echo "compose -- the happy path"
# =====================================================================
env_ 'GUEST_MANIFEST_FLAGS="--add-exports=java.desktop/x=ALL-UNNAMED --add-opens=java.base/y=ALL-UNNAMED"
SIZING_EXTRA_JVM="-Dvaadin.productionMode=true"
VIEW=sizing
SIZING_MAIN_CLASS=com.acme.inventory.Main
SIZING_ARGS="--offline=all --lang en"'
out=$(run 2>&1); rc=$?
ok "exit 0"                                  "0"  "$rc"
ok "reports composed on stderr"              "yes" "$(case "$out" in *"composed "*"entries"*) echo yes;; esac)"
ok "mvn asked three times, once each"        "3"  "$(calls)"
A=$(argv)
ok "entry 0 is the java binary"              "$BIN/java" "$(printf '%s\n' "$A" | sed -n 1p)"
ok "--patch-module is its own entry"         "--patch-module" "$(printf '%s\n' "$A" | sed -n 2p)"
ok "patch jar rendered from tokens"          "java.desktop=$M2/com/vaadin/swing-bridge-patch/9.9.9/swing-bridge-patch-9.9.9.jar" "$(printf '%s\n' "$A" | sed -n 3p)"
ok "bootclasspath rendered"                  "-Xbootclasspath/a:$M2/com/vaadin/swing-bridge-graphics/9.9.9/swing-bridge-graphics-9.9.9.jar" "$(printf '%s\n' "$A" | sed -n 4p)"
ok "entries 2-23 are the 22 conf flags"      "22" "$(printf '%s\n' "$A" | sed -n '2,23p' | grep -cE '^(--patch-module|java\.desktop=|-Xbootclasspath|--add-)')"
ok "entry 24 is the first guest flag"        "--add-exports=java.desktop/x=ALL-UNNAMED" "$(printf '%s\n' "$A" | sed -n 24p)"
ok "load-bearing add-opens present"          "1"  "$(printf '%s\n' "$A" | grep -cx -- '--add-opens=java.base/java.lang=ALL-UNNAMED')"
ok "guest manifest flags follow the conf"    "2"  "$(printf '%s\n' "$A" | grep -cE '^--add-(exports=java.desktop/x|opens=java.base/y)=ALL-UNNAMED$')"
ok "headless false"                          "1"  "$(printf '%s\n' "$A" | grep -cx -- '-Djava.awt.headless=false')"
ok "port 8088 by default"                    "1"  "$(printf '%s\n' "$A" | grep -cx -- '-Dserver.port=8088')"
ok "applibs.dir is the clone's"              "1"  "$(printf '%s\n' "$A" | grep -cx -- "-Dapplibs.dir=$CL/applibs")"
ok "consoleLogPrefix on"                     "1"  "$(printf '%s\n' "$A" | grep -cx -- '-Dswingbridge.consoleLogPrefix=true')"
ok "includeUserInLogs off, explicitly"       "1"  "$(printf '%s\n' "$A" | grep -cx -- '-Dswingbridge.includeUserInLogs=false')"
ok "extra jvm flag carried"                  "1"  "$(printf '%s\n' "$A" | grep -cx -- '-Dvaadin.productionMode=true')"
ok "kit view: -Dsizing.mainClass carried"    "1"  "$(printf '%s\n' "$A" | grep -cx -- '-Dsizing.mainClass=com.acme.inventory.Main')"
ok "kit view: -Dsizing.args is ONE entry, spaces kept" "1" "$(printf '%s\n' "$A" | grep -cxF -- '-Dsizing.args=--offline=all --lang en')"
ok "  after includeUserInLogs, before the extras" "yes" "$(printf '%s\n' "$A" | grep -n -- '' | grep -E 'includeUserInLogs|sizing\.mainClass|sizing\.args|productionMode' | cut -d: -f1 | tr '\n' ' ' | awk '{print ($2==$1+1 && $3==$2+1 && $4==$3+1) ? "yes" : "no: "$0}')"
ok "no -Xmx anywhere"                        "0"  "$(printf '%s\n' "$A" | grep -c -- '-Xmx')"
ok "no debug agent anywhere"                 "0"  "$(printf '%s\n' "$A" | grep -c -- '-agentlib')"
ok "ends with -jar <jar>"                    "-jar $CL/target/fakeapp-1.0.jar" "$(printf '%s\n' "$A" | tail -2 | tr '\n' ' ' | sed 's/ $//')"
ok "NUL-separated: no newline inside"        "0"  "$(tr -cd '\n' < "$HD/target/server-argv.cache" | wc -c)"

# =====================================================================
echo "cache -- unchanged inputs, changed inputs, ARGV_FRESH, ARGV_CHECK"
# =====================================================================
out=$(run 2>&1)
ok "second run reports cached"               "yes" "$(case "$out" in *"cached ("*"unchanged"*) echo yes;; esac)"
ok "second run asked mvn nothing (pom sha)"  "3"  "$(calls)"
ok "ARGV_CHECK on a valid cache -> VALID, 0" "VALID 0" "$(o=$(ARGV_CHECK=1 run 2>/dev/null); echo "${o%% *} $?")"
env_ 'SIZING_PORT=9099'
ok "ARGV_CHECK after an input change -> STALE, 1" "STALE 1" "$(o=$(ARGV_CHECK=1 run 2>/dev/null); echo "${o%% *} $?")"
out=$(run 2>&1)
ok "changed input re-composes"               "yes" "$(case "$out" in *"composed "*) echo yes;; esac)"
ok "and the new port is in the cache"        "1"  "$(argv | grep -cx -- '-Dserver.port=9099')"
before=$(calls); ARGV_FRESH=1 run >/dev/null 2>&1
ok "ARGV_FRESH re-asks mvn"                  "$((before+3))" "$(calls)"
rm -f "$HD/target/server-argv.cache"
ok "ARGV_CHECK with no cache -> ABSENT, 1"   "ABSENT 1" "$(o=$(ARGV_CHECK=1 run 2>/dev/null); echo "${o%% *} $?")"

# =====================================================================
echo "refusals -- each one a run that would otherwise report a wrong number"
# =====================================================================
fails() { out=$(run 2>&1); rc=$?; printf '%s|%s' "$rc" "$(case "$out" in *"$1"*) echo named;; *) echo "$out" | tail -1;; esac)"; }
env_ 'VIEW=josm'; run >/dev/null 2>&1
ok "another view: no -Dsizing.* entries at all"  "0"  "$(argv | grep -c -- '-Dsizing\.')"
env_ 'VIEW=sizing'
ok "kit view without a main class -> 1, names SIZING_MAIN_CLASS" "1|named" "$(fails 'SIZING_MAIN_CLASS is empty')"
printf 'SIZING_CLONE_DIR=\n' > "$HD/harness.env"
ok "no SIZING_CLONE_DIR -> 1, says so"       "1|named" "$(fails 'SIZING_CLONE_DIR is not set')"
env_; mv "$CL/target/fakeapp-1.0.jar" "$CL/target/x"
ok "missing packaged jar -> 1, names mvn package" "1|named" "$(fails 'mvn clean package')"
mv "$CL/target/x" "$CL/target/fakeapp-1.0.jar"; mv "$CL/applibs/guest.jar" "$TMP/g"
ok "empty applibs -> 1, says where the app goes" "1|named" "$(fails 'that is where your Swing application')"
mv "$TMP/g" "$CL/applibs/guest.jar"
env_ 'SIZING_EXTRA_JVM="-Xmx3g"'
ok "-Xmx in extras -> 1, names the sweep"    "1|named" "$(fails "sweep's variable")"
env_ 'GUEST_MANIFEST_FLAGS="-agentlib:jdwp=transport=dt_socket"'
ok "debug agent in flags -> 1"               "1|named" "$(fails 'no debug agent')"
env_; mv "$M2/com/vaadin/swing-bridge-graphics/9.9.9/swing-bridge-graphics-9.9.9.jar" "$TMP/gj"
ARGV_FRESH=1 true
ok "flag naming a missing jar -> 1, names it" "1|named" "$(ARGV_FRESH=1 fails 'names a jar that does not exist')"
mv "$TMP/gj" "$M2/com/vaadin/swing-bridge-graphics/9.9.9/swing-bridge-graphics-9.9.9.jar"
env_ 'SB_VERSION=notaversion'
ok "bad SB_VERSION -> 1"                     "1|named" "$(ARGV_FRESH=1 fails 'expected a version')"
env_ 'M2_REPO=/nonexistent/repo'
ok "M2_REPO not a dir -> 1"                  "1|named" "$(ARGV_FRESH=1 fails 'not a directory')"

echo
if [ "$FAIL" -eq 0 ]; then printf '  \033[32m%d passed, 0 failed\033[0m\n' "$PASS"; exit 0
else printf '  \033[31m%d passed, %d FAILED:\033[0m %s\n' "$PASS" "$FAIL" "${FAILED_NAMES[*]}"; exit 1; fi
