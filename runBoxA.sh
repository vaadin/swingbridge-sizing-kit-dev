#!/usr/bin/env bash
# Box A -- the server under test. On its first run it sets this box up; on every
# later run it prepares the customer's skeleton-starter clone for sizing runs,
# proves this box can enforce a memory budget, and ships the kit to Box B.
#
#   ./runBoxA.sh                    first run (no harness/harness.env yet): check the toolchain,
#                                   ask five questions -- where the starter project goes, your
#                                   main class and its arguments, the load box's ssh name, the
#                                   budget -- write harness/harness.env, fetch skeleton-starter
#                                   at the pinned revision with the kit's view in it, and stop:
#                                   your jar and your scenario come next
#   ./runBoxA.sh                    every later run: preflight (your main class in your jar,
#                                   the jar manifests' Add-Exports/Add-Opens derived as flags,
#                                   the scenario present), build the clone, compose the launch,
#                                   prove the budget, then ship the kit to Box B and set it up there
#   ./runBoxA.sh --init             the questions again (only while harness/harness.env is absent)
#   SIZING_SKIP_BUILD=1 ./runBoxA.sh    reuse an already packaged jar
#   SIZING_SKIP_SHIP=1  ./runBoxA.sh    leave Box B as it is
#
# The five answers can be given as environment variables instead -- SIZING_CLONE_DIR,
# SIZING_MAIN_CLASS, SIZING_ARGS, BOXB, BUDGET -- or piped in, one line each.
#
# Orchestration only, from the second run on: every check and every command is
# one of the harness's own scripts, run in the order a sizing run needs them.
# The first run is the exception: it checks, asks and fetches, and installs
# nothing -- a missing tool is named with its package and the run stops.
#
# Box A is the only box a person touches. The kit reaches Box B by rsync over the
# ssh alias the harness needs anyway, and runBoxB.sh runs there over that ssh --
# the same pattern runScenarioRemote.sh already uses for the ramp. Box B needs no
# git and no credentials, and the two boxes cannot run different revisions.
#
# Reads harness/harness.env. Writes the values it derives back into that file as a
# managed block at the top, so the harness scripts see the same settings whether
# started from here or by hand; anything you set below the block overrides it.
#
# Every failure here is one that would otherwise surface as a plausible wrong
# number: a server that never started reads as a ceiling of zero, an unenforced
# budget as a ceiling that never comes, a wrong main class as a tenant that
# never starts.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
KIT=$PWD
H="$KIT/harness"
say() { echo "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }

SKELETON_URL="${SKELETON_URL:-https://github.com/vaadin/skeleton-starter-vaadin-swing-bridge.git}"
SKELETON_PINNED_REV="${SKELETON_PINNED_REV:-53d7028}"

MODE=run
case "${1:-}" in
  --init) MODE=init
          [ -r "$H/harness.env" ] && die "harness/harness.env exists. Edit it -- it is plain text -- or move it away and run ./runBoxA.sh --init again." ;;
  '')     [ -r "$H/harness.env" ] || MODE=init ;;
  *)      die "unknown argument '$1'. Usage: ./runBoxA.sh [--init]" ;;
esac

# The proof that the wall is real: start a scope at the budget and read memory.max
# back. Every count this rig produces rests on it, so it runs on the first run,
# as soon as the budget is known, and again before every later run.
prove_cap() {
  local gb=$1 want got
  want=$(( gb * 1024 * 1024 * 1024 ))
  got=$(systemd-run --user --scope --quiet -p MemoryMax="${gb}G" -p MemorySwapMax=0 \
          bash -c 'cat /sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max' 2>/dev/null)
  [ "$got" = "$want" ] \
    || die "MemoryMax is NOT enforced: a ${gb}G scope reports memory.max='${got:-?}', expected $want.
       Every count this rig produced would be fiction. Needs cgroup v2 with the memory
       controller delegated to the user slice -- SETUP.md, 'Box A', has the drop-in."
  say "  a ${gb}G scope reports memory.max=$got -- the wall is real"
}

# ---------------------------------------------------------------- 0. the toolchain
# Checked, never installed: the kit names the package and stops. Each tool here is
# one a harness script calls; missing, it would fail twenty minutes into a cell.
say "==== 0. the toolchain ===="
MISSING=()
need() { command -v "$1" >/dev/null 2>&1 || MISSING+=("$1 -- package $2${3:+; $3}"); }
need java        openjdk-21-jdk
need jps         openjdk-21-jdk "a JDK, not a JRE: process discovery uses jps"
need jcmd        openjdk-21-jdk "a JDK, not a JRE: the memory sampler uses jcmd"
need jar         openjdk-21-jdk "checks that your main class is in your jar"
need mvn         maven
need python3     python3
need git         git            "fetches the starter project"
need rsync       rsync          "ships the kit to Box B"
need curl        curl
need ssh         openssh-client
need systemd-run systemd        "the budget is a systemd scope"
need journalctl  systemd        "the kill verdict is read from the user journal"
need ip          iproute2
need ss          iproute2
JAVA_MAJOR=""
if command -v java >/dev/null 2>&1; then
  JV=$(java -version 2>&1)
  if [[ $JV =~ version\ \"([0-9]+) ]]; then JAVA_MAJOR=${BASH_REMATCH[1]}; fi
  case "$JAVA_MAJOR" in
    '') MISSING+=("java -- could not read its version from: ${JV%%$'\n'*}") ;;
    *)  [ "$JAVA_MAJOR" -ge 21 ] || MISSING+=("java 21 or later -- package openjdk-21-jdk; found: ${JV%%$'\n'*}") ;;
  esac
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  for m in "${MISSING[@]}"; do say "  MISSING  $m"; done
  die "install what is named above and run ./runBoxA.sh again. The kit installs nothing itself."
fi
say "  java $JAVA_MAJOR (a JDK), maven, python3, git, rsync, curl, ssh, systemd-run, journalctl, ip, ss -- present"

# ================================================================ the first run
if [ "$MODE" = init ]; then
  say "==== first run: setting this box up ===="
  say "  There is no harness/harness.env yet, so this run asks five questions, writes that file,"
  say "  fetches the starter project your application will run in, and stops. Nothing is measured."
  say "  Enter accepts the default in [brackets]; an answer already set as the environment variable"
  say "  named in parentheses is taken without asking."
  say ""

  # ask VAR "question" default [validator]: the validator prints a reason and returns
  # 1 to ask again, or prints a note and returns 0 to accept. Answers are echoed when
  # they come from a pipe, so a transcript shows what was answered.
  ask() {
    local var=$1 q=$2 def=$3 check=${4:-} ans msg rc
    if [ -n "${!var+x}" ]; then say "  $q: ${!var}  (from the environment)"; return 0; fi
    while :; do
      printf '  %s%s: ' "$q" "${def:+ [$def]}"
      IFS= read -r ans || die "no answer to '$q' -- the input ended. Run ./runBoxA.sh in a terminal, pipe the answers one per line, or set the variable."
      [ -t 0 ] || say "$ans"
      ans=${ans:-$def}
      if [ -n "$check" ]; then
        msg=$("$check" "$ans"); rc=$?
        [ -n "$msg" ] && say "     $msg"
        [ "$rc" -eq 0 ] || continue
      fi
      printf -v "$var" '%s' "$ans"; return 0
    done
  }
  check_clone_dir() {
    [ -n "$1" ] || { echo "a path is needed"; return 1; }
    if [ -e "$1" ]; then
      [ -d "$1" ] || { echo "$1 exists and is not a directory"; return 1; }
      if [ ! -r "$1/pom.xml" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; then
        echo "$1 exists, is not empty and holds no pom.xml: name a new or empty directory, or a skeleton-starter clone"; return 1
      fi
      [ -r "$1/pom.xml" ] && echo "a Maven project is already there; it will be used as it is"
    fi
    return 0
  }
  check_main_class() {
    [[ $1 =~ ^[A-Za-z_\$][A-Za-z0-9_\$]*(\.[A-Za-z_\$][A-Za-z0-9_\$]*)*$ ]] \
      || { echo "'$1' is not a Java class name (like com.acme.inventory.Main)"; return 1; }
    case "$1" in *.*) ;; *) echo "no package in '$1' -- fine if your main class really is in the default package" ;; esac
    return 0
  }
  check_args() {
    case " $1" in *" -X"*|*" -D"*)
      echo "note: these go to your application's main(String[]); JVM flags such as -D... belong in SIZING_EXTRA_JVM in harness.env" ;;
    esac
    return 0
  }
  check_alias() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || { echo "'$1' is not an ssh host alias (a name from ~/.ssh/config, no spaces)"; return 1; }; }
  check_budget() {
    [[ $1 =~ ^[1-9][0-9]*$ ]] || { echo "a whole number of GB, like 4"; return 1; }
    local ram; ram=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
    [ "$1" -lt "$ram" ] || { echo "this box has $ram GiB; the budget must leave room for the operating system and the kit"; return 1; }
    return 0
  }

  ask SIZING_CLONE_DIR  "Where to put the starter project, skeleton-starter-vaadin-swing-bridge (SIZING_CLONE_DIR)" "$KIT/system-under-test/skeleton-starter-vaadin-swing-bridge" check_clone_dir
  ask SIZING_MAIN_CLASS "The main class of your Swing application, e.g. com.acme.inventory.Main (SIZING_MAIN_CLASS)" "" check_main_class
  ask SIZING_ARGS       "Arguments for its main(), space-separated, if any (SIZING_ARGS)" "" check_args
  ask BOXB              "The ssh name of the load box, Box B -- an entry in ~/.ssh/config, see SETUP.md (BOXB)" "boxb" check_alias
  ask BUDGET            "The RAM budget to size for, in GB (BUDGET)" "4" check_budget
  SIZING_CLONE_DIR=$(realpath -m "$SIZING_CLONE_DIR")
  say ""

  say "==== the load box ===="
  if ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOXB" true 2>/dev/null; then
    say "  $BOXB answers over ssh without a password"
  else
    say "  NOTE: $BOXB does not answer over ssh yet. Fine for now; the next run needs it."
    say "        SETUP.md, 'ssh from A to B': a key without a passphrase, a Host $BOXB entry, keepalive."
  fi

  say "==== the budget is enforceable ===="
  prove_cap "$BUDGET"

  say "==== harness/harness.env ===="
  esc() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\$/\\\$}; s=${s//\`/\\\`}; printf '%s' "$s"; }
  SCN_LINE='SCENARIO="$HARNESS_HOME/scenario/app-cycle.json"'
  [ -n "${SCENARIO:-}" ] && SCN_LINE="SCENARIO=\"$(esc "$SCENARIO")\""
  GMF_LINE='#GUEST_MANIFEST_FLAGS=""'
  [ -n "${GUEST_MANIFEST_FLAGS:-}" ] && GMF_LINE="GUEST_MANIFEST_FLAGS=\"$(esc "$GUEST_MANIFEST_FLAGS")\""
  XJ_LINE='#SIZING_EXTRA_JVM=""'
  [ -n "${SIZING_EXTRA_JVM:-}" ] && XJ_LINE="SIZING_EXTRA_JVM=\"$(esc "$SIZING_EXTRA_JVM")\""
  cat > "$H/harness.env" <<ENV
# Box A -- written by ./runBoxA.sh on its first run, $(date -u +'%Y-%m-%d %H:%M UTC').
# Plain text, sourced by every kit script: harness/harness-env.sh reads it before its own
# defaults, so whatever is here wins. Edit freely. runBoxA.sh keeps a block between >>> and
# <<< markers at the top with what it derives; your lines below that block override it.
# Every setting the kit knows is described in harness.env.example beside this file.

# ---------------------------------------------------------------- your application
# The skeleton-starter clone your application runs in. Your jar(s) go in its applibs/.
SIZING_CLONE_DIR="$(esc "$SIZING_CLONE_DIR")"
# What the kit's view starts -- /sizing, src/main/java/com/example/swingbridge/ui/SizingView.java
# in the clone: your main class, and the arguments for its main(), space-separated.
SIZING_MAIN_CLASS="$(esc "$SIZING_MAIN_CLASS")"
SIZING_ARGS="$(esc "$SIZING_ARGS")"
VIEW=sizing
# Your jar's manifest Add-Exports / Add-Opens are read and repeated on the server's command
# line by every run: the JVM honours them for 'java -jar' only, and the bridge starts your
# application by main class. Set this only to REPLACE that derived list.
$GMF_LINE
# Anything else for the server JVM: -Dmyapp.config=/path, an --add-exports your application
# needs beyond its manifest. Never -Xmx: the kit sets it per cell.
$XJ_LINE

# ---------------------------------------------------------------- the scenario
# What one user does, step by step, and what must change on screen after each step. Write it
# at this path; SCENARIO.md describes the format and examples/josm/josm-cycle.json is a
# complete one. The next run refuses until the file exists.
$SCN_LINE

# ---------------------------------------------------------------- the boxes
# The load box's ssh alias (an entry in ~/.ssh/config -- SETUP.md), and the RAM budget in GB.
BOXB=$BOXB
BUDGET=$BUDGET

# ---------------------------------------------------------------- the kit's own -- leave as is
SKELETON_PINNED_REV=$SKELETON_PINNED_REV
GUEST_JVM_EXTRA=
BOXB_HARNESS_SUBDIR=harness
ENV
  say "  written: $H/harness.env"

  say "==== the starter project ===="
  if [ -r "$SIZING_CLONE_DIR/pom.xml" ]; then
    say "  using the project already at $SIZING_CLONE_DIR -- nothing there is removed"
  else
    say "  git clone $SKELETON_URL"
    say "        -> $SIZING_CLONE_DIR"
    mkdir -p "$(dirname "$SIZING_CLONE_DIR")"
    git clone -q "$SKELETON_URL" "$SIZING_CLONE_DIR" \
      || die "could not clone skeleton-starter (no network? a proxy?). Clone it yourself, then run ./runBoxA.sh --init after moving harness/harness.env away, and name that directory."
    git -C "$SIZING_CLONE_DIR" checkout -q "$SKELETON_PINNED_REV" \
      || die "revision $SKELETON_PINNED_REV is not in the clone at $SIZING_CLONE_DIR"
    say "  at revision $SKELETON_PINNED_REV, the one this kit was exercised against"
    # The skeleton ships a sample application in applibs/ and a view for it. Both go:
    # every jar in applibs/ is on your application's classpath, and a page whose jar
    # is gone would only mislead.
    for j in "$SIZING_CLONE_DIR"/applibs/*.jar; do
      [ -e "$j" ] || continue
      rm -f "$j"; say "  removed the skeleton's sample $(basename "$j") from applibs/ -- your jar(s) go there"
    done
    W="$SIZING_CLONE_DIR/src/main/java/com/example/swingbridge/ui/WarehouseView.java"
    if [ -e "$W" ]; then rm -f "$W"; say "  removed the skeleton's sample WarehouseView.java (its jar is gone)"; fi
  fi
  VDIR="$SIZING_CLONE_DIR/src/main/java/com/example/swingbridge/ui"; VDST="$VDIR/SizingView.java"
  if [ -e "$VDST" ] && ! cmp -s "$KIT/view/SizingView.java" "$VDST"; then
    say "  a SizingView.java of your own is at $VDST -- left as it is (the kit's is view/SizingView.java)"
  else
    mkdir -p "$VDIR" && cp "$KIT/view/SizingView.java" "$VDST" || die "could not install the view at $VDST"
    say "  installed the kit's view: $VDST"
    say "    @Route(\"sizing\"); starts SIZING_MAIN_CLASS with SIZING_ARGS, both from harness.env"
  fi

  SCN_SHOW="${SCENARIO:-$H/scenario/app-cycle.json}"
  say "==== set up. Before the next run ===="
  say "  1. Put your Swing application's jar file(s) -- and nothing else -- into"
  say "       $SIZING_CLONE_DIR/applibs/"
  say "  2. Write the scenario -- what one user does, and what must change on screen -- at"
  say "       $SCN_SHOW"
  say "     SCENARIO.md explains the format; $KIT/examples/josm/josm-cycle.json is a complete example."
  say "  then run ./runBoxA.sh again. Your answers are in $H/harness.env, plain text."
  exit 0
fi

# ================================================================ every later run
. "$H/harness-env.sh"

# ---------------------------------------------------------------- 1. the clone
say "==== 1. the clone ===="
CLONE="${SIZING_CLONE_DIR:-}"
[ -n "$CLONE" ] || die "SIZING_CLONE_DIR is not set in harness/harness.env"
[ -n "${VIEW:-}" ] || [ -n "${SIZING_SKIP_SHIP:-}" ] \
  || die "VIEW is not set in harness/harness.env. It is the @Route of your view -- the skeleton's default
       @Route(\"\") cannot be addressed; the kit's view is @Route(\"sizing\"), so VIEW=sizing."
[ -d "$CLONE" ] && [ -r "$CLONE/pom.xml" ] \
  || die "no readable pom.xml at SIZING_CLONE_DIR=$CLONE. The first run fetches the project there; to redo
       that, move harness/harness.env away and run ./runBoxA.sh again."
REV=$(git -C "$CLONE" rev-parse --short HEAD 2>/dev/null || echo "not a git checkout")
say "  clone      : $CLONE"
say "  revision   : $REV"
if [ -n "${SKELETON_PINNED_REV:-}" ] && [ "$REV" != "$SKELETON_PINNED_REV" ]; then
  say "  WARN       : the kit was validated against skeleton-starter $SKELETON_PINNED_REV; this clone is $REV."
  say "               Fine, but say so in the run's notes."
fi
APPLIBS="${SIZING_APPLIBS:-$CLONE/applibs}"
n=$(find "$APPLIBS" -maxdepth 1 -name '*.jar' 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || die "no *.jar in $APPLIBS -- that is where your Swing application's jar(s) go. Put them there and run again."
say "  applibs    : $n jar(s) in $APPLIBS"
# The main class must be in one of those jars: a wrong one reads as a tenant that
# never starts, which is a capacity of zero. Listed with the JDK's own jar tool;
# captured, not piped: `cmd | grep -q` under pipefail reports cmd's status, not grep's.
if [ -n "${SIZING_MAIN_CLASS:-}" ]; then
  CLS="${SIZING_MAIN_CLASS//.//}.class"; FOUND=""
  for j in "$APPLIBS"/*.jar; do
    L=$(jar tf "$j" 2>/dev/null) || continue
    if grep -qxF -- "$CLS" <<< "$L"; then FOUND=$(basename "$j"); break; fi
  done
  [ -n "$FOUND" ] || die "main class $SIZING_MAIN_CLASS ($CLS) is in none of the $n jar(s) in $APPLIBS.
       Fix SIZING_MAIN_CLASS in harness/harness.env, or add the jar that holds it."
  say "  main class : $SIZING_MAIN_CLASS  (in $FOUND)"
fi
# The jars' manifest Add-Exports / Add-Opens, as flags. The JDK launcher applies
# them for `java -jar` and ignores them for a classpath launch -- how the bridge
# starts a guest -- so they are repeated on the command line: derived here on every
# run and written into the managed block NOW, because captureServerArgv.sh reads
# harness.env itself in step 3 and an assignment there beats any exported value.
# A GUEST_MANIFEST_FLAGS line of your own below the block replaces the derived list.
# Entries this JDK cannot honour are dropped and named, as the launcher itself
# drops them. Anything your application needs beyond its manifest belongs in
# SIZING_EXTRA_JVM.
JAVA_FOR_FLAGS="${JAVA_HOME:+$JAVA_HOME/bin/java}"; JAVA_FOR_FLAGS="${JAVA_FOR_FLAGS:-java}"
SKIPPED="$H/target/manifest-skipped.txt"; mkdir -p "$H/target"
DERIVED_GMF=$(python3 "$H/manifestFlags.py" --java "$JAVA_FOR_FLAGS" "$APPLIBS"/*.jar 2>"$SKIPPED") \
  || die "$(cat "$SKIPPED")"
NDERIVED=$(set -- $DERIVED_GMF; echo $#)
# Into the block (created with just this line if there is none yet; step 4 rewrites
# it whole), and: is there a line of yours below it?
GMF_USER=$(python3 - "$H/harness.env" "$DERIVED_GMF" <<'PY'
import re, sys
path, gmf = sys.argv[1:3]
orig = open(path).read()
line = f'GUEST_MANIFEST_FLAGS="{gmf}"\n'
m = re.search(r"(# >>> sizing-kit: derived.*?)(# <<< sizing-kit derived <<<\n)", orig, re.S)
# Everything that is not the block, judged on the file as it was: a line of yours?
rest = (orig[:m.start()] + orig[m.end():]) if m else orig
if m:
    body = re.sub(r"^GUEST_MANIFEST_FLAGS=.*\n", "", m.group(1), flags=re.M)
    new = orig[:m.start()] + body + line + m.group(2) + orig[m.end():]
else:
    new = "# >>> sizing-kit: derived by runBoxA.sh; your settings below override these >>>\n" + line + "# <<< sizing-kit derived <<<\n\n" + orig
open(path, "w").write(new)
print("x" if re.search(r"^\s*(export\s+)?GUEST_MANIFEST_FLAGS=", rest, re.M) else "")
PY
) || die "could not write GUEST_MANIFEST_FLAGS into harness/harness.env"
if [ -n "$GMF_USER" ]; then
  say "  manifest   : GUEST_MANIFEST_FLAGS is yours (below the block): ${GUEST_MANIFEST_FLAGS:-(empty)}"
  LACKS=""
  for f in $DERIVED_GMF; do case " ${GUEST_MANIFEST_FLAGS:-} " in *" $f "*) ;; *) LACKS="$LACKS $f" ;; esac; done
  [ -z "$LACKS" ] || say "  WARN       : it lacks what the manifest(s) declare:$LACKS"
elif [ "$NDERIVED" -gt 0 ]; then
  say "  manifest   : $NDERIVED flag(s) derived from the jar manifest(s): $DERIVED_GMF"
else
  say "  manifest   : no Add-Exports / Add-Opens in the jar manifest(s); nothing to repeat"
fi
[ -s "$SKIPPED" ] && sed 's/^/  skipped    : /' "$SKIPPED"
SCN="${SCENARIO:-}"
[ -n "$SCN" ] || die "SCENARIO is not set in harness/harness.env. It names your scenario file -- what one user
       does, step by step, and what must change on screen (SCENARIO.md). The first run writes the line."
[ -r "$SCN" ] || die "no scenario at $SCN. It is the list of what one user does and what must change on
       screen after each step; SCENARIO.md explains the format and $KIT/examples/josm/josm-cycle.json
       is a complete one. Save yours at that path and run again."
say "  scenario   : $SCN"
python3 "$H/checkFlagsDrift.py" "$CLONE/pom.xml" "$H/jvm-flags.conf" || true   # a warning, never a stop

# ---------------------------------------------------------------- 2. build
say "==== 2. build ===="
if [ -n "${SIZING_SKIP_BUILD:-}" ]; then
  say "  skipped (SIZING_SKIP_BUILD is set); the packaged jar must already exist"
else
  say "  mvn -B -ntp clean package -DskipTests   in $CLONE"
  say "  (the frontend build is slow the first time; nothing here touches the budget)"
  ( cd "$CLONE" && mvn -B -ntp -q clean package -DskipTests ) \
    || die "the clone did not package. Fix the build there first; the kit measures what you ship."
fi

# ---------------------------------------------------------------- 3. the launch command
say "==== 3. the launch command ===="
ARGV_FRESH=1 "$H/captureServerArgv.sh" || die "could not compose the server command (see above)"
FINAL_NAME=$(sed -n 2p "$H/target/server-argv.resolved")
[ -n "$FINAL_NAME" ] || die "captureServerArgv.sh left no resolved finalName"

# ---------------------------------------------------------------- 4. derived settings
say "==== 4. derived settings -> harness/harness.env ===="
# The load box's core count: peer_load1 in the monitor CSV is only readable
# against it, and nothing recorded it in round 2. Empty when the box is not
# reachable yet; checkEnv.sh reports that properly in the next step.
BOXB_CORES=$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${BOXB:-boxb}" nproc 2>/dev/null || true)
# Where the kit lives on Box B: the root is asked of Box B itself when not set
# (runScenarioRemote.sh resolves it the same way), and the checkout defaults to
# this directory's name under it -- what runBoxA.sh ships to in step 8.
BOXB_ROOT="${BOXB_ROOT:-$(ssh -o BatchMode=yes -o ConnectTimeout=8 "${BOXB:-boxb}" 'echo "$HOME/dev_load_v2"' 2>/dev/null || true)}"
BOXB_CHECKOUT="${BOXB_CHECKOUT:-${BOXB_ROOT:+$BOXB_ROOT/$(basename "$KIT")}}"
python3 - "$H/harness.env" "$FINAL_NAME" "$CLONE" "$BOXB_CORES" "$BOXB_ROOT" "$BOXB_CHECKOUT" "$DERIVED_GMF" <<'PY'
import re, sys
path, final, clone, cores, root, checkout, gmf = sys.argv[1:8]
s = open(path).read()
block = f"""# >>> sizing-kit: derived by runBoxA.sh; your settings below override these >>>
SERVER_JPS_MATCH={final}
SERVER_CWD={clone}
GUEST_MANIFEST_FLAGS="{gmf}"
GUEST_JVM_EXTRA=
BOXB_HARNESS_SUBDIR=harness
BOXB_CORES={cores}
BOXB_ROOT={root}
BOXB_CHECKOUT={checkout}
# <<< sizing-kit derived <<<

"""
pat = re.compile(r"# >>> sizing-kit: derived.*?# <<< sizing-kit derived <<<\n\n?", re.S)
s = pat.sub(block, s, count=1) if pat.search(s) else block + s
open(path, "w").write(s)
PY
say "  SERVER_JPS_MATCH=$FINAL_NAME   (how runCeiling.sh finds the server: jps -l prints the jar path)"
say "  SERVER_CWD=$CLONE"
say "  GUEST_MANIFEST_FLAGS=\"$DERIVED_GMF\"   (from the jar manifest(s); your own line below the block replaces it)"
say "  GUEST_JVM_EXTRA=  BOXB_HARNESS_SUBDIR=harness"
say "  BOXB_CORES=${BOXB_CORES:-(load box not reachable yet)}"
say "  BOXB_ROOT=${BOXB_ROOT:-(load box not reachable yet)}   BOXB_CHECKOUT=${BOXB_CHECKOUT:-?}"
. "$H/harness-env.sh"   # pick the block up for the steps below

# ---------------------------------------------------------------- 5. preflight
say "==== 5. preflight: checkEnv.sh ===="
"$H/checkEnv.sh" || die "preflight failed. Nothing below would produce a right answer."

# ---------------------------------------------------------------- 6. the wall is real
say "==== 6. the budget is enforceable ===="
prove_cap "${BUDGET:-4}"

# ---------------------------------------------------------------- 7. the scenario
say "==== 7. the scenario ===="
if [ -n "${SIZING_BOUNDS_SAMPLE:-}" ]; then
  if [ ! -d "$KIT/driver/target/classes" ]; then
    say "  building the driver here once, for --validate"
    ( cd "$KIT/driver" && mvn -B -ntp -q package -DskipTests ) || die "the driver did not build"
  fi
  OUT=$(java -cp "$KIT/driver/target/classes:$KIT/driver/target/dependency/*" \
          -Dscenario.file="$SCN" -Dscenario.boundsLog="$SIZING_BOUNDS_SAMPLE" \
          com.vaadin.swingbridge.load.ScenarioDriver --validate 2>&1); RC=$?
  printf '%s\n' "$OUT" | grep -vE '^prop '
  [ "$RC" -eq 0 ] || die "the scenario does not resolve against what your guest publishes. Fix it before the first cell."
else
  say "  not validated. To check $SCN"
  say "  against your application without browsers, run it once so it prints a WIDGET-BOUNDS line,"
  say "  save that output, and set SIZING_BOUNDS_SAMPLE=<that file>. Otherwise the first"
  say "  single-tenant cell is the check -- and a bad scenario shows up there as a 180 s timeout."
fi

# ---------------------------------------------------------------- 8. the load box
say "==== 8. the load box: ship the kit, set it up ===="
if [ -n "${SIZING_SKIP_SHIP:-}" ]; then
  say "  skipped (SIZING_SKIP_SHIP); Box B keeps what it has"
else
  [ -n "${BOXB_CHECKOUT:-}" ] || die "BOXB_CHECKOUT is unknown (Box B not reachable in step 4?)"
  # Box B's own harness.env (runBoxB.sh writes it), its reports and its builds
  # stay; --delete removes only what the kit itself no longer has. A clone kept
  # inside the kit directory (the first run's default, system-under-test/) stays here too.
  RS_EXCL=(--exclude=/.git/ --exclude=/testdata/ --exclude=/harness/harness.env
           --exclude=/harness/reports/* --exclude=/harness/target/ --exclude=/driver/target/)
  TAR_EXCL=(--exclude=./.git --exclude=./testdata --exclude=./harness/harness.env
            --exclude=./harness/reports/* --exclude=./harness/target --exclude=./driver/target)
  case "$CLONE" in
    "$KIT"/*) REL=${CLONE#"$KIT"/}; REL=${REL%%/*}
              RS_EXCL+=(--exclude=/"$REL"/); TAR_EXCL+=(--exclude=./"$REL") ;;
  esac
  if command -v rsync >/dev/null 2>&1 && ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOXB" 'command -v rsync >/dev/null' 2>/dev/null; then
    say "  rsync $KIT/ -> $BOXB:$BOXB_CHECKOUT/"
    rsync -az --delete "${RS_EXCL[@]}" "$KIT/" "$BOXB:$BOXB_CHECKOUT/" \
      || die "could not ship the kit to $BOXB:$BOXB_CHECKOUT"
  else
    say "  no rsync on one side: tar over ssh (stale files on Box B are not removed)"
    tar -C "$KIT" "${TAR_EXCL[@]}" -cf - . \
      | ssh "$BOXB" "mkdir -p '$BOXB_CHECKOUT' && tar -C '$BOXB_CHECKOUT' -xf -" \
      || die "could not ship the kit to $BOXB:$BOXB_CHECKOUT"
  fi
  say "  ./runBoxB.sh on $BOXB: builds the driver, fetches Chromium -- minutes, the first time"
  ssh "$BOXB" "cd '$BOXB_CHECKOUT' && VIEW='$VIEW' BOXB_ROOT='$BOXB_ROOT'${SIZING_SKIP_BROWSERS:+ SIZING_SKIP_BROWSERS=1}${SIZING_DRIVER_PREBUILT:+ SIZING_DRIVER_PREBUILT=1} ./runBoxB.sh" \
    || die "runBoxB.sh did not complete on $BOXB (its output is above)"
fi

say "==== ready ===="
say "  server jar : $CLONE/target/$FINAL_NAME.jar"
say "  load box   : $BOXB:${BOXB_CHECKOUT:-?}"
say "  next       : ./runSizing.sh"
