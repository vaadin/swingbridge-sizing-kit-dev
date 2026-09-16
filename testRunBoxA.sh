#!/usr/bin/env bash
# runBoxA.sh with every external stubbed -- ssh, rsync, git, java and its tools,
# systemd-run, and the harness scripts it orchestrates -- so what is pinned is the
# orchestration itself: what the first run asks, writes, fetches and removes; what
# later runs derive, write, ship where and run on Box B; and what every run refuses.
#   ./testRunBoxA.sh [-v]
set -uo pipefail
cd "$(dirname "$0")" || exit 1
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; FAILED_NAMES=()
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  \033[32mok\033[0m   %-58s %s\n' "$1" "$2"
      else FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m %-58s expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; return 0; }

KIT="$TMP/sizing-kit"; H="$KIT/harness"; mkdir -p "$H/target" "$H/reports" "$H/scenario" "$KIT/driver" "$KIT/testdata" "$KIT/view"
cp runBoxA.sh "$KIT/"; cp harness/harness-env.sh harness/jvm-flags.conf harness/checkFlagsDrift.py "$H/"
cp view/SizingView.java "$KIT/view/"; cp harness/manifestFlags.py "$H/"; : > "$H/scenario/test-cycle.json"
# --- jars are real zips: manifestFlags.py reads them for real (only java is stubbed)
mkjar() { python3 - "$@" <<'PY'
import sys, zipfile
path, manifest = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
with zipfile.ZipFile(path, "w") as zf:
    zf.writestr("Hello.class", b"\xca\xfe\xba\xbe")
    if manifest is not None:
        zf.writestr("META-INF/MANIFEST.MF", manifest)
PY
}
GUEST_MF=$'Manifest-Version: 1.0\nAdd-Exports: java.desktop/com.sun.imageio.spi jdk.deploy/com.sun.deploy.config\nAdd-Opens: java.base/java.lang\n'
GUEST_FLAGS='--add-exports=java.desktop/com.sun.imageio.spi=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED'
# --- a fake clone with the REAL skeleton pom (so the drift guard runs for real) and one guest jar
CL="$TMP/clone"; mkdir -p "$CL/applibs" "$CL/target"; mkjar "$CL/applibs/guest.jar" "$GUEST_MF"
cp /home/eftun/dev/git/skeleton-starter-vaadin-swing-bridge/pom.xml "$CL/pom.xml" 2>/dev/null || echo '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion></project>' > "$CL/pom.xml"
# --- stubs
BIN="$TMP/bin"; mkdir -p "$BIN"; CALLS="$TMP/calls"; : > "$CALLS"
cat > "$H/checkEnv.sh" <<'S'
#!/usr/bin/env bash
echo "checkEnv $*" >> "$STUB_CALLS"; exit "${STUB_CHECKENV_RC:-0}"
S
cat > "$H/captureServerArgv.sh" <<'S'
#!/usr/bin/env bash
cd "$(dirname "$0")"; echo "captureServerArgv" >> "$STUB_CALLS"
. ./harness-env.sh   # as the real one does: harness.env decides, not the environment
echo "gmf=${GUEST_MANIFEST_FLAGS-unset}" >> "$STUB_CALLS"
printf '%s\0' /usr/bin/java -Dx=1 -jar /clone/target/app-1.0.jar > target/server-argv.cache
printf '%s\n' pomsha app-1.0 1.3.0 /m2 > target/server-argv.resolved
echo "# server argv: composed 4 entries" >&2
S
cat > "$BIN/mvn" <<'S'
#!/usr/bin/env bash
echo "mvn $* in $PWD" >> "$STUB_CALLS"; : > target/app-1.0.jar
S
cat > "$BIN/systemd-run" <<'S'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$STUB_CALLS"
[ -n "${STUB_CAP_UNENFORCED:-}" ] && { echo max; exit 0; }
for a in "$@"; do case "$a" in MemoryMax=*G) n=${a#MemoryMax=}; n=${n%G}; echo $((n*1073741824)); exit 0;; esac; done
S
cat > "$BIN/ssh" <<'S'
#!/usr/bin/env bash
cmd="${@: -1}"
# Most specific first: the runBoxB and tar commands both contain the root path.
case "$cmd" in
  *'./runBoxB.sh'*)     echo "ssh-run $cmd" >> "$STUB_CALLS"; echo "stub runBoxB ran"; exit "${STUB_RUNBOXB_RC:-0}" ;;
  *'tar -C'*)           cat > /dev/null; echo "ssh-tar $cmd" >> "$STUB_CALLS" ;;
  *'command -v rsync'*) exit "${STUB_B_RSYNC_RC:-0}" ;;
  nproc)                echo 14 ;;
  true)                 echo "ssh-true ${@: -2:1}" >> "$STUB_CALLS"; exit "${STUB_SSH_TRUE_RC:-0}" ;;
  *'echo "$HOME/dev_load_v2"'*) echo /home/b/dev_load_v2 ;;
  *)                    echo "ssh-other $*" >> "$STUB_CALLS" ;;
esac
S
cat > "$BIN/rsync" <<'S'
#!/usr/bin/env bash
echo "rsync $*" >> "$STUB_CALLS"
S
cat > "$BIN/java" <<'S'
#!/usr/bin/env bash
case "${1:-}" in
  -version) echo "openjdk version \"${STUB_JAVA_VERSION:-21.0.12}\" 2026-07-21" >&2
            echo "OpenJDK Runtime Environment (build stub)" >&2 ;;
  --list-modules)    printf '%s\n' java.base@21 java.desktop@21 ;;
  --describe-module) case "$2" in
                       java.base)    printf '%s\n' 'exports java.lang' 'contains sun.security.action' ;;
                       java.desktop) printf '%s\n' 'contains com.sun.imageio.spi' 'contains com.sun.imageio.plugins.jpeg' ;;
                       *) echo "Error: module $2 not found" >&2; exit 1 ;;
                     esac ;;
  *)        echo "java $*" >> "$STUB_CALLS" ;;
esac
S
for t in jps jcmd journalctl; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$t"; done
cat > "$BIN/jar" <<'S'
#!/usr/bin/env bash
# jar tf <jar>: a fixed listing, or STUB_JAR_LIST (newline-separated)
echo "jar $*" >> "$STUB_CALLS"
[ "${1:-}" = tf ] || exit 2
if [ -n "${STUB_JAR_LIST+x}" ]; then printf '%s\n' "$STUB_JAR_LIST"; else printf '%s\n' META-INF/MANIFEST.MF com/acme/inventory/Main.class; fi
S
cat > "$BIN/git" <<'S'
#!/usr/bin/env bash
# clone makes a fake skeleton: pom, the sample jar in applibs/, the sample view
echo "git $*" >> "$STUB_CALLS"
case "${1:-}" in
  clone) d="${@: -1}"; [ -n "${STUB_GIT_CLONE_RC:-}" ] && exit "$STUB_GIT_CLONE_RC"
         mkdir -p "$d/applibs" "$d/src/main/java/com/example/swingbridge/ui"
         echo '<project/>' > "$d/pom.xml"; python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1],"w").writestr("META-INF/MANIFEST.MF","Manifest-Version: 1.0\n")' "$d/applibs/simple-swing-apps-0.0.1-SNAPSHOT.jar"
         echo 'class WarehouseView {}' > "$d/src/main/java/com/example/swingbridge/ui/WarehouseView.java" ;;
  -C)    case "${3:-}" in rev-parse) echo 53d7028 ;; checkout) exit "${STUB_GIT_CHECKOUT_RC:-0}" ;; esac ;;
esac
S
chmod +x "$H"/*.sh "$KIT/runBoxA.sh" "$BIN"/*
env_() { printf 'SIZING_CLONE_DIR=%s\nBOXB=boxb\nSCENARIO=%s\n%s\n' "$CL" "$H/scenario/test-cycle.json" "${1:-}" > "$H/harness.env"; }
run()  { (cd "$KIT" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" STUB_CALLS="$CALLS" "$@" bash ./runBoxA.sh 2>&1); }
runa() { (cd "$KIT" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" STUB_CALLS="$CALLS" bash ./runBoxA.sh "$@" 2>&1); }   # script arguments
reset() { : > "$CALLS"; rm -f "$CL/target/"*.jar; }
blk()  { sed -n '/^# >>> sizing-kit: derived/,/^# <<< sizing-kit derived/p' "$H/harness.env"; }
E="$H/harness.env"
UI="src/main/java/com/example/swingbridge/ui"

# =====================================================================
echo "the first run: setup, with the default clone location"
# =====================================================================
rm -f "$E"; reset
SUT="$KIT/system-under-test/skeleton-starter-vaadin-swing-bridge"
out=$(printf '%s\n' "" "com.acme.inventory.Main" "--offline=all --lang en" "" "4" | run); rc=$?
ok "exit 0"                                        "0" "$rc"
ok "toolchain: java 21, a JDK, and the rest present" "yes" "$(case "$out" in *"java 21 (a JDK)"*"-- present"*) echo yes;; esac)"
ok "five questions asked, answers echoed"          "5" "$(printf '%s\n' "$out" | grep -cE '\((SIZING_CLONE_DIR|SIZING_MAIN_CLASS|SIZING_ARGS|BOXB|BUDGET)\)')"
ok "harness.env: the default clone dir, absolute, under system-under-test/" "SIZING_CLONE_DIR=\"$SUT\"" "$(grep '^SIZING_CLONE_DIR=' "$E")"
ok "harness.env: main class"                       'SIZING_MAIN_CLASS="com.acme.inventory.Main"' "$(grep '^SIZING_MAIN_CLASS=' "$E")"
ok "harness.env: args, spaces kept"                'SIZING_ARGS="--offline=all --lang en"' "$(grep '^SIZING_ARGS=' "$E")"
ok "harness.env: the kit's view"                   "VIEW=sizing" "$(grep '^VIEW=' "$E")"
ok "harness.env: BOXB default, BUDGET"             "BOXB=boxb BUDGET=4" "$(echo $(grep -E '^(BOXB|BUDGET)=' "$E"))"
ok "harness.env: the scenario path, to be written" 'SCENARIO="$HARNESS_HOME/scenario/app-cycle.json"' "$(grep '^SCENARIO=' "$E")"
ok "harness.env: the kit's own lines"              "SKELETON_PINNED_REV=53d7028 GUEST_JVM_EXTRA= BOXB_HARNESS_SUBDIR=harness" "$(echo $(grep -E '^(SKELETON_PINNED_REV|GUEST_JVM_EXTRA|BOXB_HARNESS_SUBDIR)=' "$E"))"
ok "harness.env sources; SCENARIO expands"         "$H/scenario/app-cycle.json" "$(cd "$H" && HARNESS_HOME=$H bash -c '. ./harness.env && echo "$SCENARIO"')"
ok "load box probed over ssh, by the answered alias" "yes" "$(grep -q '^ssh-true boxb$' "$CALLS" && echo yes)"
ok "  and reported answering"                      "yes" "$(case "$out" in *"boxb answers over ssh"*) echo yes;; esac)"
ok "cap proof at the answered budget"              "yes" "$(grep -q 'systemd-run.*MemoryMax=4G' "$CALLS" && echo yes)"
ok "git clone of the skeleton URL into the dir"    "yes" "$(grep -q "^git clone -q https://github.com/vaadin/skeleton-starter-vaadin-swing-bridge.git $SUT$" "$CALLS" && echo yes)"
ok "checked out the pinned revision"               "yes" "$(grep -q "^git -C $SUT checkout -q 53d7028$" "$CALLS" && echo yes)"
ok "skeleton's sample jar removed from applibs"    "0" "$(ls "$SUT/applibs" | wc -l)"
ok "  and said so, by name"                        "yes" "$(case "$out" in *"removed the skeleton's sample simple-swing-apps-0.0.1-SNAPSHOT.jar"*) echo yes;; esac)"
ok "skeleton's WarehouseView removed"              "no" "$([ -e "$SUT/$UI/WarehouseView.java" ] && echo yes || echo no)"
ok "the kit's view installed, byte for byte"       "yes" "$(cmp -s view/SizingView.java "$SUT/$UI/SizingView.java" && echo yes)"
ok "stops with: jar into applibs, scenario path, run again" "yes" "$(case "$out" in *"$SUT/applibs/"*"$H/scenario/app-cycle.json"*"run ./runBoxA.sh again"*) echo yes;; esac)"
ok "nothing built, composed, shipped or run on B"  "0" "$(grep -cE '^(mvn|rsync|ssh-run|ssh-tar|captureServerArgv|checkEnv)' "$CALLS")"

echo "the second run continues where the first stopped"
mkjar "$SUT/applibs/acme.jar" $'Manifest-Version: 1.0\nCreated-By: nobody\n'; : > "$H/scenario/app-cycle.json"; mkdir -p "$SUT/target"
reset; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "exit 0"                                        "0" "$rc"
ok "no questions this time"                        "0" "$(printf '%s\n' "$out" | grep -c '(SIZING_MAIN_CLASS)')"
ok "main class found in the jar, said so"          "yes" "$(case "$out" in *"main class : com.acme.inventory.Main  (in acme.jar)"*) echo yes;; esac)"
ok "  listed with jar tf"                          "yes" "$(grep -q "^jar tf $SUT/applibs/acme.jar$" "$CALLS" && echo yes)"
ok "the scenario from harness.env"                 "yes" "$(case "$out" in *"scenario   : $H/scenario/app-cycle.json"*) echo yes;; esac)"
ok "a manifest without module flags: said, block empty-but-set" "yes GUEST_MANIFEST_FLAGS=\"\"" "$(case "$out" in *"no Add-Exports / Add-Opens in the jar manifest(s)"*) echo yes;; esac) $(blk | grep '^GUEST_MANIFEST_FLAGS=')"
ok "block written above the first run's file"     "SERVER_CWD=$SUT" "$(blk | grep '^SERVER_CWD=')"
ok "  first run's lines still there, below it"     "yes" "$(grep -q '^SIZING_MAIN_CLASS="com.acme.inventory.Main"$' "$E" && echo yes)"
ok "rsync excludes the clone kept inside the kit"  "yes" "$(grep '^rsync' "$CALLS" | grep -q -- '--exclude=/system-under-test/ ' && echo yes)"
ok "runBoxB.sh run on B with VIEW=sizing"          "yes" "$(grep -q "VIEW='sizing' BOXB_ROOT='/home/b/dev_load_v2' ./runBoxB.sh$" "$CALLS" && echo yes)"
ok "ready names the next step"                     "yes" "$(case "$out" in *"next       : ./runSizing.sh"*) echo yes;; esac)"
printf 'SIZING_MAIN_CLASS=com.acme.Other\n' >> "$E"
reset; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "a main class in no jar -> exit 1, names it and the count" "1 yes" "$rc $(case "$out" in *"main class com.acme.Other (com/acme/Other.class) is in none of the 1 jar(s)"*) echo yes;; esac)"
ok "  before anything else"                        "0" "$(grep -cE '^(mvn|captureServerArgv|rsync|ssh-run)' "$CALLS")"
sed -i '$d' "$E"
rm -f "$H/scenario/app-cycle.json"; reset; out=$(run); rc=$?
ok "no scenario yet -> exit 1, names the path and the example" "1 yes" "$rc $(case "$out" in *"no scenario at $H/scenario/app-cycle.json"*"SCENARIO.md"*"examples/josm/josm-cycle.json"*) echo yes;; esac)"
ok "  before the build"                            "0" "$(grep -c '^mvn' "$CALLS")"
: > "$H/scenario/app-cycle.json"

# =====================================================================
echo "first-run variants"
# =====================================================================
rm -f "$E"; reset
out=$(run SIZING_CLONE_DIR="$TMP/own" SIZING_MAIN_CLASS=com.x.Y SIZING_ARGS= BOXB=lb BUDGET=2 </dev/null); rc=$?
ok "all five from the environment, no stdin: exit 0" "0" "$rc"
ok "  each taken without asking"                   "5 0" "$(printf '%s\n' "$out" | grep -c '(from the environment)') $(printf '%s\n' "$out" | grep -c '\[boxb\]')"
ok "  written as given"                            "SIZING_CLONE_DIR=\"$TMP/own\" SIZING_ARGS=\"\" BOXB=lb BUDGET=2" "$(echo $(grep -E '^(SIZING_CLONE_DIR|SIZING_ARGS|BOXB|BUDGET)=' "$E"))"
ok "  cloned there"                                "yes" "$(grep -q "^git clone -q .* $TMP/own$" "$CALLS" && echo yes)"
ok "  SCENARIO / GUEST_MANIFEST_FLAGS from the environment become active lines" "yes" "$(rm -f "$E"; run SIZING_CLONE_DIR="$TMP/own2" SIZING_MAIN_CLASS=a.B SIZING_ARGS= BOXB=lb BUDGET=2 SCENARIO=/s/my.json GUEST_MANIFEST_FLAGS='--add-opens=x/y=ALL-UNNAMED' </dev/null >/dev/null; grep -q '^SCENARIO="/s/my.json"$' "$E" && grep -q '^GUEST_MANIFEST_FLAGS="--add-opens=x/y=ALL-UNNAMED"$' "$E" && echo yes)"

MINE="$TMP/mine"; mkdir -p "$MINE/applibs" "$MINE/$UI"; echo '<project/>' > "$MINE/pom.xml"; mkjar "$MINE/applibs/mine.jar"; echo 'mine' > "$MINE/$UI/WarehouseView.java"
rm -f "$E"; reset
out=$(printf '%s\n' "$MINE" "com.acme.Main" "" "" "" | run); rc=$?
ok "an existing project: exit 0, used as it is"    "0 yes" "$rc $(case "$out" in *"a Maven project is already there"*"nothing there is removed"*) echo yes;; esac)"
ok "  no clone"                                    "0" "$(grep -c '^git clone' "$CALLS")"
ok "  its jar and its view kept"                   "yes" "$([ -e "$MINE/applibs/mine.jar" ] && [ "$(cat "$MINE/$UI/WarehouseView.java")" = mine ] && echo yes)"
ok "  the kit's view installed beside them"        "yes" "$(cmp -s view/SizingView.java "$MINE/$UI/SizingView.java" && echo yes)"
echo 'my own' > "$MINE/$UI/SizingView.java"; rm -f "$E"
out=$(printf '%s\n' "$MINE" "com.acme.Main" "" "" "" | run)
ok "a SizingView of one's own is left alone, said so" "my own yes" "$(cat "$MINE/$UI/SizingView.java") $(case "$out" in *"SizingView.java of your own"*"left as it is"*) echo yes;; esac)"
NE="$TMP/notempty"; mkdir -p "$NE"; : > "$NE/somefile"; rm -f "$E"
out=$(printf '%s\n' "$NE" "$TMP/fresh" "com.acme.Main" "" "" "" | run); rc=$?
ok "a non-empty non-project dir is refused, re-asked" "0 yes" "$rc $(case "$out" in *"holds no pom.xml"*) echo yes;; esac)"
ok "  the second answer taken"                     "SIZING_CLONE_DIR=\"$TMP/fresh\"" "$(grep '^SIZING_CLONE_DIR=' "$E")"

rm -f "$E"; out=$(printf '%s\n' "" "not a class!" "com.acme.Main" "" "" "" | run); rc=$?
ok "a bad main class is re-asked"                  "0 yes" "$rc $(case "$out" in *"is not a Java class name"*) echo yes;; esac)"
ok "  the good one written"                        'SIZING_MAIN_CLASS="com.acme.Main"' "$(grep '^SIZING_MAIN_CLASS=' "$E")"
rm -f "$E"; out=$(printf '%s\n' "" "com.acme.Main" "-Dfoo=bar --x" "" "" | run); rc=$?
ok "JVM-looking args: a note, accepted"            "0 yes" "$rc $(case "$out" in *"JVM flags such as -D... belong in SIZING_EXTRA_JVM"*) echo yes;; esac)"
ok "  written anyway"                              'SIZING_ARGS="-Dfoo=bar --x"' "$(grep '^SIZING_ARGS=' "$E")"
rm -f "$E"; out=$(printf '%s\n' "" "com.acme.Main" "" "" "99999" "3" | run); rc=$?
ok "a budget above the box's RAM is re-asked"      "0 yes" "$rc $(case "$out" in *"must leave room"*) echo yes;; esac)"
ok "  the second one written"                      "BUDGET=3" "$(grep '^BUDGET=' "$E")"
rm -f "$E"; out=$(printf '%s\n' "" "com.acme.Main" "" "" "four" "2" | run); rc=$?
ok "a non-numeric budget is re-asked"              "0 yes" "$rc $(case "$out" in *"a whole number of GB"*) echo yes;; esac)"
rm -f "$E"; out=$(printf '%s\n' "" "com.acme.Main" | run); rc=$?
ok "input ends early -> exit 1, says which question" "1 yes" "$rc $(case "$out" in *"no answer to 'Arguments"*) echo yes;; esac)"
ok "  no harness.env written"                      "no" "$([ -e "$E" ] && echo yes || echo no)"
rm -f "$E"; reset; out=$(printf '%s\n' "" "com.acme.Main" "" "" "" | run STUB_SSH_TRUE_RC=255); rc=$?
ok "load box not answering: exit 0, a note pointing at SETUP.md" "0 yes" "$rc $(case "$out" in *"does not answer over ssh yet"*"SETUP.md"*) echo yes;; esac)"
rm -f "$E"; reset; out=$(printf '%s\n' "" "com.acme.Main" "" "" "" | run STUB_CAP_UNENFORCED=1); rc=$?
ok "budget not enforceable -> exit 1 at setup, names the drop-in" "1 yes" "$rc $(case "$out" in *"MemoryMax is NOT enforced"*"SETUP.md"*) echo yes;; esac)"
ok "  before harness.env is written or anything cloned" "no 0" "$([ -e "$E" ] && echo yes || echo no) $(grep -c '^git clone' "$CALLS")"
rm -f "$E"; reset; out=$(printf '%s\n' "$TMP/nc" "com.acme.Main" "" "" "" | run STUB_GIT_CLONE_RC=128); rc=$?
ok "clone fails -> exit 1, says what to do"        "1 yes" "$rc $(case "$out" in *"could not clone skeleton-starter"*) echo yes;; esac)"
env_ 'VIEW=sizing'; out=$(runa --init); rc=$?
ok "--init with a harness.env -> exit 1, refuses to overwrite" "1 yes" "$rc $(case "$out" in *"harness.env exists"*) echo yes;; esac)"
ok "  file untouched"                              "yes" "$(grep -q '^VIEW=sizing$' "$E" && echo yes)"
rm -f "$E"; out=$(printf '%s\n' "" "com.acme.Main" "" "" "" | runa --init); rc=$?
ok "--init without one asks"                       "0 yes" "$rc $(case "$out" in *"(SIZING_MAIN_CLASS)"*) echo yes;; esac)"
env_ 'VIEW=sizing'; out=$(runa --frobnicate); rc=$?
ok "an unknown argument -> exit 1, usage"          "1 yes" "$rc $(case "$out" in *"Usage: ./runBoxA.sh [--init]"*) echo yes;; esac)"

# =====================================================================
echo "the toolchain: checked, named, never installed"
# =====================================================================
TB="$TMP/toolbox"; mkdir -p "$TB"
for f in /usr/bin/* /bin/*; do b=$(basename "$f"); [ -e "$TB/$b" ] || ln -s "$f" "$TB/$b"; done 2>/dev/null
BIN2="$TMP/bin2"; cp -a "$BIN" "$BIN2"; rm -f "$BIN2/rsync" "$TB/rsync" "$BIN2/jcmd" "$TB/jcmd"
rm -f "$E"; reset
out=$(cd "$KIT" && env -i PATH="$BIN2:$TB" HOME="$TMP" STUB_CALLS="$CALLS" bash ./runBoxA.sh 2>&1 </dev/null); rc=$?
ok "two tools missing -> exit 1"                   "1" "$rc"
ok "  each named with its package"                 "yes" "$(case "$out" in *"MISSING  jcmd -- package openjdk-21-jdk; a JDK, not a JRE"*"MISSING  rsync -- package rsync"*) echo yes;; esac)"
ok "  installs nothing, says so"                   "yes" "$(case "$out" in *"The kit installs nothing itself"*) echo yes;; esac)"
ok "  before any question"                         "0 no" "$(printf '%s\n' "$out" | grep -c '(SIZING_CLONE_DIR)') $([ -e "$E" ] && echo yes || echo no)"
rm -f "$E"; out=$(run STUB_JAVA_VERSION=17.0.2 </dev/null); rc=$?
ok "java 17 -> exit 1, names 21 and the package"   "1 yes" "$rc $(case "$out" in *"java 21 or later -- package openjdk-21-jdk; found: openjdk version \"17.0.2\""*) echo yes;; esac)"
env_ 'VIEW=sizing'; out=$(run STUB_JAVA_VERSION=17.0.2); rc=$?
ok "  on a later run too"                          "1" "$rc"

# =====================================================================
echo "later runs: the happy path, with the build"
# =====================================================================
reset; env_ 'VIEW=sizing'; out=$(run); rc=$?
ok "exit 0"                                        "0" "$rc"
ok "mvn clean package -DskipTests, in the clone"   "yes" "$(grep -q "mvn -B -ntp -q clean package -DskipTests in $CL" "$CALLS" && echo yes)"
ok "drift guard ran against the clone's pom"       "yes" "$(case "$out" in *"flags drift"*) echo yes;; esac)"
ok "captureServerArgv.sh called"                   "1" "$(grep -c '^captureServerArgv$' "$CALLS")"
ok "block: jar name for jps"                       "SERVER_JPS_MATCH=app-1.0" "$(blk | grep '^SERVER_JPS_MATCH=')"
ok "block: clone as working directory"             "SERVER_CWD=$CL" "$(blk | grep '^SERVER_CWD=')"
ok "block: GUEST_JVM_EXTRA set-but-empty"          "GUEST_JVM_EXTRA=" "$(blk | grep '^GUEST_JVM_EXTRA=')"
ok "block: load box cores from ssh nproc"          "BOXB_CORES=14" "$(blk | grep '^BOXB_CORES=')"
ok "block: root asked of Box B"                    "BOXB_ROOT=/home/b/dev_load_v2" "$(blk | grep '^BOXB_ROOT=')"
ok "block: checkout = root / this dir's name"      "BOXB_CHECKOUT=/home/b/dev_load_v2/sizing-kit" "$(blk | grep '^BOXB_CHECKOUT=')"
ok "checkEnv.sh ran, no arguments"                 "yes" "$(grep -q '^checkEnv $' "$CALLS" && echo yes)"
ok "cap proof: a 4G scope asked for"               "yes" "$(grep -q 'systemd-run.*MemoryMax=4G' "$CALLS" && echo yes)"
ok "  and judged real"                             "yes" "$(case "$out" in *"the wall is real"*) echo yes;; esac)"
ok "no main class set: no jar listing, no check"   "0" "$(grep -c '^jar tf' "$CALLS")"
ok "manifest flags derived from the guest jar, said" "yes" "$(case "$out" in *"manifest   : 2 flag(s) derived from the jar manifest(s): $GUEST_FLAGS"*) echo yes;; esac)"
ok "  the entry this JDK lacks named as skipped"    "yes" "$(case "$out" in *"skipped    : skipped guest.jar: jdk.deploy/com.sun.deploy.config -- no module jdk.deploy in this JDK"*) echo yes;; esac)"
ok "  reached captureServerArgv.sh in the environment" "yes" "$(grep -qxF "gmf=$GUEST_FLAGS" "$CALLS" && echo yes)"
ok "  written into the block"                       "GUEST_MANIFEST_FLAGS=\"$GUEST_FLAGS\"" "$(blk | grep '^GUEST_MANIFEST_FLAGS=')"
ok "scenario: not validated without a sample, said so" "yes" "$(case "$out" in *"not validated"*) echo yes;; esac)"
ok "ship: rsync with --delete to Box B's checkout" "yes" "$(grep -q "^rsync -az --delete .* $KIT/ boxb:/home/b/dev_load_v2/sizing-kit/$" "$CALLS" && echo yes)"
ok "  protecting Box B's harness.env"              "yes" "$(grep '^rsync' "$CALLS" | grep -q -- '--exclude=/harness/harness.env' && echo yes)"
ok "  and its builds and reports"                  "3" "$(grep '^rsync' "$CALLS" | grep -oE -- '--exclude=/(driver/target/|harness/target/|harness/reports/\*)' | wc -l)"
ok "  not the fixtures or .git"                    "2" "$(grep '^rsync' "$CALLS" | grep -oE -- '--exclude=/(\.git/|testdata/)' | wc -l)"
ok "  a clone outside the kit: no extra exclude"   "0" "$(grep '^rsync' "$CALLS" | grep -c -- '--exclude=/system-under-test/')"
ok "runBoxB.sh run on Box B, in the checkout, with VIEW" "yes" "$(grep -q "^ssh-run cd '/home/b/dev_load_v2/sizing-kit' && VIEW='sizing' BOXB_ROOT='/home/b/dev_load_v2' ./runBoxB.sh$" "$CALLS" && echo yes)"
ok "  its output streamed back"                    "yes" "$(case "$out" in *"stub runBoxB ran"*) echo yes;; esac)"
ok "ready names the load box and the next step"    "yes" "$(case "$out" in *"load box   : boxb:/home/b/dev_load_v2/sizing-kit"*"./runSizing.sh"*) echo yes;; esac)"

echo "later runs: variants"
reset; env_ 'VIEW=sizing'; run SIZING_SKIP_BUILD=1 >/dev/null
ok "SIZING_SKIP_BUILD: no mvn"                     "0" "$(grep -c '^mvn' "$CALLS")"
reset; env_ 'VIEW=sizing'; : > "$CL/target/app-1.0.jar"; run SIZING_SKIP_BUILD=1 SIZING_SKIP_SHIP=1 >/dev/null
ok "SIZING_SKIP_SHIP: nothing shipped, nothing run on B" "0" "$(grep -cE '^(rsync|ssh-run|ssh-tar)' "$CALLS")"
reset; env_ 'VIEW=sizing'; run SIZING_SKIP_BUILD=1 SIZING_SKIP_BROWSERS=1 >/dev/null
ok "SIZING_SKIP_BROWSERS forwarded to runBoxB"     "yes" "$(grep -q "SIZING_SKIP_BROWSERS=1 ./runBoxB.sh" "$CALLS" && echo yes)"
reset; env_ 'VIEW=sizing
BOXB_ROOT=/custom/root
BOXB_CHECKOUT=/custom/root/kit'; run SIZING_SKIP_BUILD=1 >/dev/null
ok "user's BOXB_ROOT/BOXB_CHECKOUT honoured (below the block)" "yes" "$(grep -q "^rsync .* boxb:/custom/root/kit/$" "$CALLS" && echo yes)"
reset; env_ 'VIEW=sizing'; out=$(run STUB_B_RSYNC_RC=1 SIZING_SKIP_BUILD=1); rc=$?
ok "no rsync on Box B: tar over ssh, exit 0"       "0 yes" "$rc $(grep -q '^ssh-tar' "$CALLS" && echo yes)"
ok "  said so"                                     "yes" "$(case "$out" in *"tar over ssh"*) echo yes;; esac)"
reset; env_ 'VIEW=sizing'; run SIZING_SKIP_BUILD=1 >/dev/null; run SIZING_SKIP_BUILD=1 >/dev/null
ok "block written once across two runs"            "1" "$(grep -c 'sizing-kit: derived' "$E")"
reset; env_ 'VIEW=sizing
GUEST_MANIFEST_FLAGS="--add-exports=java.desktop/com.sun.imageio.spi=ALL-UNNAMED --add-opens=x/y=ALL-UNNAMED"'; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "GUEST_MANIFEST_FLAGS of your own (below the block): kept, exit 0" "0 yes" "$rc $(case "$out" in *"manifest   : GUEST_MANIFEST_FLAGS is yours (below the block): --add-exports=java.desktop/com.sun.imageio.spi=ALL-UNNAMED --add-opens=x/y=ALL-UNNAMED"*) echo yes;; esac)"
ok "  a WARN names what the manifest declares and it lacks" "yes" "$(case "$out" in *"WARN       : it lacks what the manifest(s) declare: --add-opens=java.base/java.lang=ALL-UNNAMED"*) echo yes;; esac)"
ok "  yours is what captureServerArgv.sh saw"      "yes" "$(grep -qxF 'gmf=--add-exports=java.desktop/com.sun.imageio.spi=ALL-UNNAMED --add-opens=x/y=ALL-UNNAMED' "$CALLS" && echo yes)"
ok "  the block still records the derived list"    "GUEST_MANIFEST_FLAGS=\"$GUEST_FLAGS\"" "$(blk | grep '^GUEST_MANIFEST_FLAGS=')"
reset; env_ 'VIEW=sizing'; run SIZING_SKIP_BUILD=1 >/dev/null; reset; out=$(run SIZING_SKIP_BUILD=1 GUEST_MANIFEST_FLAGS=--from-the-shell); rc=$?
ok "a previous run's block line is re-derived, not taken as yours" "0 yes yes" "$rc $(case "$out" in *"2 flag(s) derived"*) echo yes;; esac) $(grep -qxF "gmf=$GUEST_FLAGS" "$CALLS" && echo yes)"
ok "  and the shell's value is not the channel (harness.env decides)" "1" "$(grep -c 'sizing-kit: derived' "$E")"
mkjar "$CL/applibs/guest.jar" $'Manifest-Version: 1.0\nAdd-Opens: java.base/java.lang\n'; reset; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "a changed manifest re-derives into the same block line" "0 GUEST_MANIFEST_FLAGS=\"--add-opens=java.base/java.lang=ALL-UNNAMED\" 1" "$rc $(blk | grep '^GUEST_MANIFEST_FLAGS=') $(grep -c '^GUEST_MANIFEST_FLAGS=' "$E")"
mkjar "$CL/applibs/guest.jar" "$GUEST_MF"
reset; env_ 'VIEW=sizing
SIZING_MAIN_CLASS=com.acme.inventory.Main'; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "main class set: checked in applibs, found"     "0 yes" "$rc $(case "$out" in *"main class : com.acme.inventory.Main  (in guest.jar)"*) echo yes;; esac)"
reset; env_ 'VIEW=sizing
SIZING_MAIN_CLASS="com.acme.Outer\$Inner"'; out=$(run SIZING_SKIP_BUILD=1 STUB_JAR_LIST=$'x/y.class\ncom/acme/Outer$Inner.class'); rc=$?
ok "an inner main class matches exactly"           "0" "$rc"

echo "later runs: refusals"
reset; env_; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "no VIEW -> exit 1, explains the named route"   "1 yes" "$rc $(case "$out" in *"VIEW is not set"*"@Route"*) echo yes;; esac)"
ok "  before any build or ship"                    "0" "$(grep -cE '^(mvn|rsync|ssh-run)' "$CALLS")"
reset; env_ 'VIEW=sizing'; out=$(run STUB_CHECKENV_RC=1 SIZING_SKIP_BUILD=1); rc=$?
ok "preflight fails -> exit 1, nothing shipped"    "1 0" "$rc $(grep -cE '^(rsync|ssh-run)' "$CALLS")"
reset; env_ 'VIEW=sizing'; out=$(run STUB_CAP_UNENFORCED=1 SIZING_SKIP_BUILD=1); rc=$?
ok "budget not enforced -> exit 1, nothing shipped" "1 0 yes" "$rc $(grep -cE '^(rsync|ssh-run)' "$CALLS") $(case "$out" in *"NOT enforced"*) echo yes;; esac)"
reset; env_ 'VIEW=sizing'; out=$(run STUB_RUNBOXB_RC=3 SIZING_SKIP_BUILD=1); rc=$?
ok "runBoxB fails on B -> exit 1, says so"         "1 yes" "$rc $(case "$out" in *"runBoxB.sh did not complete"*) echo yes;; esac)"
reset; env_ 'VIEW=sizing'; rm -f "$CL/applibs/guest.jar"; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "empty applibs -> exit 1, before the build, says to put them there" "1 0 yes" "$rc $(grep -c '^mvn' "$CALLS") $(case "$out" in *"Put them there and run again"*) echo yes;; esac)"
echo "not a zip" > "$CL/applibs/guest.jar"; reset; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "a jar that is not a zip -> exit 1, names it, before the build" "1 0 yes" "$rc $(grep -c '^mvn' "$CALLS") $(case "$out" in *"guest.jar: not a readable jar"*) echo yes;; esac)"
mkjar "$CL/applibs/guest.jar" "$GUEST_MF"
reset; printf 'SIZING_CLONE_DIR=%s\nBOXB=boxb\nVIEW=sizing\n' "$CL" > "$E"; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "no SCENARIO line -> exit 1, says the first run writes it" "1 yes 0" "$rc $(case "$out" in *"SCENARIO is not set in harness/harness.env"*"first run writes the line"*) echo yes;; esac) $(grep -c '^mvn' "$CALLS")"
reset; printf 'SIZING_CLONE_DIR=%s\nBOXB=boxb\nVIEW=sizing\n' "$TMP/gone" > "$E"; out=$(run SIZING_SKIP_BUILD=1); rc=$?
ok "clone dir gone -> exit 1, says how to redo the first run" "1 yes" "$rc $(case "$out" in *"no readable pom.xml at SIZING_CLONE_DIR=$TMP/gone"*"move harness/harness.env away"*) echo yes;; esac)"

echo
if [ "$FAIL" -eq 0 ]; then printf '  \033[32m%d passed, 0 failed\033[0m\n' "$PASS"; exit 0
else printf '  \033[31m%d passed, %d FAILED:\033[0m %s\n' "$PASS" "$FAIL" "${FAILED_NAMES[*]}"; exit 1; fi
