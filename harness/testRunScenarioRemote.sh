#!/usr/bin/env bash
# runScenarioRemote.sh with ssh and scp stubbed: what it ships to Box B, what it
# generates there, what it refuses, and how the remote exit code comes back.
#   ./testRunScenarioRemote.sh [-v]
set -uo pipefail
cd "$(dirname "$0")" || exit 1
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; FAILED_NAMES=()
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  \033[32mok\033[0m   %-58s %s\n' "$1" "$2"
      else FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m %-58s expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; return 0; }

HD="$TMP/harness"; mkdir -p "$HD"; cp runScenarioRemote.sh harness-env.sh "$HD/"
SCN="$TMP/my-cycle.json"; echo '{"cycle":[]}' > "$SCN"
BIN="$TMP/bin"; mkdir -p "$BIN"; CALLS="$TMP/calls"; : > "$CALLS"
# One stub answers every ssh the script makes, keyed on the remote command.
# Most specific first: the script-writing command also says mkdir, and the temp
# check also says mkdir and df.
cat > "$BIN/ssh" <<'S'
#!/usr/bin/env bash
cmd="${@: -1}"
case "$cmd" in
  *'cat > '*)                   cat > "$STUB_DIR/rscript"; echo "ssh-script" >> "$STUB_CALLS" ;;
  *'setsid nohup'*)             echo "ssh-start" >> "$STUB_CALLS"; echo started ;;
  *'tail -n +'*)                echo "ssh-tail" >> "$STUB_CALLS"; printf 'remote line\nREMOTE-EXIT=%s\n' "${STUB_REMOTE_EXIT:-0}" ;;
  *'echo "$HOME/dev_load_v2"'*) echo /home/b/dev_load_v2 ;;
  *'df -Pm /dev/shm'*)          echo "${STUB_SHM_MB:-20000}" ;;
  *"df -Pm '"*)                 echo "${STUB_TMP_MB:-30000}" ;;
  *'curl -sf'*)                 echo "ssh-curl $cmd" >> "$STUB_CALLS"; exit "${STUB_CURL_RC:-0}" ;;
  *"mkdir -p '"*)               echo "ssh-mkdir $cmd" >> "$STUB_CALLS" ;;
  *)                            echo "ssh-other $cmd" >> "$STUB_CALLS" ;;
esac
S
cat > "$BIN/scp" <<'S'
#!/usr/bin/env bash
echo "scp $*" >> "$STUB_CALLS"; exit "${STUB_SCP_RC:-0}"
S
chmod +x "$BIN"/*
run() { (cd "$HD" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" STUB_CALLS="$CALLS" STUB_DIR="$TMP" \
          A_IP=10.0.0.5 BOXB=boxb BOXB_CHECKOUT=/home/b/dev_load_v2/kit BOXB_HARNESS_SUBDIR=harness FOLLOW_INTERVAL=0 \
          "$@" bash ./runScenarioRemote.sh sb 1 1 2>&1); }
reset() { : > "$CALLS"; rm -f "$TMP/rscript"; }
script() { cat "$TMP/rscript" 2>/dev/null; }

echo "the scenario travels with the run"
reset; out=$(run SCENARIO="$SCN"); rc=$?
ok "exit 0, remote exit relayed"                   "0 yes" "$rc $(case "$out" in *"remote exit: 0"*) echo yes;; esac)"
ok "the file copied to Box B's scratch area, stamped" "yes" "$(grep -qE "^scp -q -o BatchMode=yes $SCN boxb:/home/b/dev_load_v2/supplemental/scenario-[0-9]+-p8088\.json$" "$CALLS" && echo yes)"
ok "  after the scratch directory was made"        "yes" "$(grep -q "^ssh-mkdir mkdir -p '/home/b/dev_load_v2/supplemental'$" "$CALLS" && echo yes)"
ok "  and said so"                                 "yes" "$(case "$out" in *"scenario:   $SCN -> boxb:/home/b/dev_load_v2/supplemental/scenario-"*) echo yes;; esac)"
ok "generated script: into the kit's harness dir"  "yes" "$(script | grep -q '^cd /home/b/dev_load_v2/kit/harness || exit 1$' && echo yes)"
ok "  exports SCENARIO as the shipped copy"        "yes" "$(script | grep -qE '^export SCENARIO="/home/b/dev_load_v2/supplemental/scenario-[0-9]+-p8088\.json"$' && echo yes)"
ok "  URL and bounds log point at this box"        "2" "$(script | grep -cE '^export (URL="http://10\.0\.0\.5:8088/"|BOUNDS_LOG="http://10\.0\.0\.5:8099/log")$')"
ok "  scratch redirects for Maven, Playwright, tmp" "3" "$(script | grep -cE '^export (MAVEN_OPTS=.*supplemental/\.m2|PLAYWRIGHT_BROWSERS_PATH="/home/b/dev_load_v2/supplemental/ms-playwright"|TMPDIR="/dev/shm/sbbench")')"
ok "  runs the sb channel, one cycle"              "yes" "$(script | grep -q '^\./runScenario.sh sb 1$' && echo yes)"
ok "  and ends by printing the exit code"          "yes" "$(script | grep -q 'REMOTE-EXIT=' && echo yes)"
ok "started detached, then tailed"                 "yes" "$(grep -q '^ssh-start$' "$CALLS" && grep -q '^ssh-tail$' "$CALLS" && echo yes)"

echo "variants"
reset; out=$(run SCENARIO="$SCN" SCENARIO_REMOTE=/home/b/already/there.json); rc=$?
ok "SCENARIO_REMOTE given: used verbatim, nothing copied" "0 yes 0" "$rc $(script | grep -q '^export SCENARIO="/home/b/already/there.json"$' && echo yes) $(grep -c '^scp' "$CALLS")"
reset; out=$(run); rc=$?
ok "no SCENARIO at all: the original behaviour, no export" "0 0 0" "$rc $(grep -c '^scp' "$CALLS") $(script | grep -c '^export SCENARIO=')"
reset; out=$(run SCENARIO="$SCN" EXTRA_REMOTE='-Dscenario.activeRamp=true -Dscenario.maxTenants=8'); rc=$?
ok "EXTRA_REMOTE forwarded whole, quotes intact"   "yes" "$(script | grep -q '^export EXTRA="-Dscenario.activeRamp=true -Dscenario.maxTenants=8"$' && echo yes)"
ok "  and sized the temp check to maxTenants"      "yes" "$(case "$out" in *"ramp to 8 needs ~4320 MB"*) echo yes;; esac)"
reset; out=$(run SCENARIO="$SCN" STUB_SHM_MB=100); rc=$?
ok "small /dev/shm: warned, browsers' temp on disk" "0 yes yes" "$rc $(case "$out" in *"falling back to on-disk"*) echo yes;; esac) $(script | grep -q '^export TMPDIR="/home/b/dev_load_v2/supplemental/tmp"$' && echo yes)"
reset; out=$(run SCENARIO="$SCN" STUB_REMOTE_EXIT=3); rc=$?
ok "remote exit 3 -> exit 3, said"                 "3 yes" "$rc $(case "$out" in *"remote exit: 3"*) echo yes;; esac)"

echo "refusals, each before anything starts on Box B"
reset; out=$(run SCENARIO="$TMP/nowhere.json"); rc=$?
ok "unreadable SCENARIO -> exit 1, names it"       "1 yes 0" "$rc $(case "$out" in *"SCENARIO is not readable: $TMP/nowhere.json"*) echo yes;; esac) $(grep -c '^ssh-start' "$CALLS")"
reset; out=$(run SCENARIO="$SCN" STUB_SCP_RC=1); rc=$?
ok "copy fails -> exit 1, names both ends"         "1 yes 0" "$rc $(case "$out" in *"could not copy $SCN to boxb:"*) echo yes;; esac) $(grep -c '^ssh-start' "$CALLS")"
reset; out=$(run SCENARIO="$SCN" STUB_CURL_RC=7); rc=$?
ok "Box B cannot reach this box -> exit 1"         "1 yes 0" "$rc $(case "$out" in *"cannot reach http://10.0.0.5:8088/"*) echo yes;; esac) $(grep -c '^ssh-start' "$CALLS")"
reset; out=$(run SCENARIO="$SCN" STUB_TMP_MB=100); rc=$?
ok "no room for the ramp's browser temp -> exit 1" "1 yes 0" "$rc $(case "$out" in *"not enough room in /dev/shm/sbbench"*) echo yes;; esac) $(grep -c '^ssh-start' "$CALLS")"

echo
if [ "$FAIL" -eq 0 ]; then printf '  \033[32m%d passed, 0 failed\033[0m\n' "$PASS"; exit 0
else printf '  \033[31m%d passed, %d FAILED:\033[0m %s\n' "$PASS" "$FAIL" "${FAILED_NAMES[*]}"; exit 1; fi
