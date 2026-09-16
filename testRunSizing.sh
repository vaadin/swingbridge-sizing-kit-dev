#!/usr/bin/env bash
# runSizing.sh against a stubbed runCeilingMatrix.sh: the heaps it derives from a
# range, what it passes on, what it records, what it refuses.
#   ./testRunSizing.sh [-v]
set -uo pipefail
cd "$(dirname "$0")" || exit 1
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0; FAILED_NAMES=()
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && printf '  \033[32mok\033[0m   %-58s %s\n' "$1" "$2"
      else FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m %-58s expected [%s] got [%s]\n' "$1" "$2" "$3"; fi; return 0; }

KIT="$TMP/kit"; H="$KIT/harness"; mkdir -p "$H/target" "$H/reports"
cp runSizing.sh "$KIT/"; cp harness/probes.sh harness/harness-env.sh "$H/"
printf 'x\0' > "$H/target/server-argv.cache"
printf '#!/usr/bin/env bash\nexit "${STUB_CHECKENV_RC:-0}"\n' > "$H/checkEnv.sh"
cat > "$H/runCeilingMatrix.sh" <<'STUB'
#!/usr/bin/env bash
cd "$(dirname "$0")"
echo "BUDGET=$BUDGET SB_CAPS=[$SB_CAPS] SB_MAX=$SB_MAX" >> "$STUB_CALLS"
for cap in $SB_CAPS; do
  sleep 1
  plan=$(tr ' ' '\n' <<<"${STUB_PLAN:-}" | awk -F: -v c="$cap" '$1==c{print $2}')
  idx=$(cat "$STUB_CALLS.$cap" 2>/dev/null || echo 0); echo $((idx+1)) > "$STUB_CALLS.$cap"
  val=$(tr ',' '\n' <<<"$plan" | sed -n "$((idx+1))p"); [ -n "$val" ] || val=$(tr ',' '\n' <<<"$plan" | tail -1); [ -n "$val" ] || val=30
  log="reports/$(date -u +%Y%m%d%H%M%S)-ceiling-sb-$cap.log"
  if [ "$val" = K ]; then
    printf '  last healthy : 20 active tenants\n  kernel kill       : YES -- the SERVER died\n  java OOM in log   : 0\n  tenants reached   : 20\n  scope alive thru  : 20 tenants\n' > "$log"
  else
    printf '  last healthy : %s active tenants\n  kernel kill       : no (systemd journal)\n  java OOM in log   : 0\n  tenants reached   : %s\n  scope alive thru  : %s tenants\n' "$val" "$val" "$val" > "$log"
  fi
done
STUB
chmod +x "$H"/*.sh "$KIT/runSizing.sh"
reset() { rm -f "$TMP"/calls*; rm -f "$H"/reports/*; : > "$TMP/calls"; }
run()   { (cd "$KIT" && env -i PATH=/usr/bin:/bin HOME="$TMP" STUB_CALLS="$TMP/calls" GUEST_JVM_EXTRA= "$@" bash ./runSizing.sh 2>&1); }
caps()  { sed -n 1p "$TMP/calls" | grep -o 'SB_CAPS=\[[^]]*\]'; }
manifest() { cat "$H"/reports/*-sizing.txt 2>/dev/null; }

echo "the default range"
reset; out=$(run STUB_PLAN="2456m:38 2864m:33 3280m:K"); rc=$?
ok "exit 0"                                        "0" "$rc"
ok "60/70/80 % of 4 GB, rounded to 8 MB"           "SB_CAPS=[2456m 2864m 3280m]" "$(caps)"
ok "one matrix run"                                "1" "$(wc -l < "$TMP/calls")"
ok "plan printed: heaps with their percentages"    "yes" "$(case "$out" in *"2456m(60%) 2864m(70%) 3280m(80%)"*) echo yes;; esac)"
ok "plan printed: cells and an estimate in hours"  "yes" "$(case "$out" in *"3 cell(s)"*"about 1.4 h"*) echo yes;; esac)"
ok "manifest: heaps line"                          "heaps=2456m 2864m 3280m" "$(manifest | grep '^heaps=')"
ok "manifest: range recorded"                      "heap_range=60% 80% 10%" "$(manifest | grep '^heap_range=')"
ok "manifest: one cell line per heap, verdicts"    "38 YES|33 YES|20 no:server-died" "$(manifest | awk '/^cell /{printf "%s%s %s", (n++?"|":""), $4, $5}')"
ok "no winner anywhere"                            "0" "$(manifest | grep -c winner)"
ok "results printed per heap, then next step"      "yes" "$(case "$out" in *"-Xmx3280m  run 1: 20 no:server-died"*"./runReport.sh"*) echo yes;; esac)"

echo "range variants"
reset; run BUDGET=8 STUB_PLAN="" >/dev/null
ok "budget 8: 4912m 5736m 6552m"                   "SB_CAPS=[4912m 5736m 6552m]" "$(caps)"
reset; run SIZING_HEAP_START=50% SIZING_HEAP_STOP=70% SIZING_HEAP_STEP=10% >/dev/null
ok "50/70/10 -> 2048m 2456m 2864m"                 "SB_CAPS=[2048m 2456m 2864m]" "$(caps)"
reset; run SIZING_HEAP_START=2g SIZING_HEAP_STOP=3g SIZING_HEAP_STEP=512m >/dev/null
ok "absolute range 2g..3g by 512m"                 "SB_CAPS=[2048m 2560m 3072m]" "$(caps)"
reset; run SIZING_HEAP_START=60% SIZING_HEAP_STOP=60% >/dev/null
ok "start = stop -> one heap"                      "SB_CAPS=[2456m]" "$(caps)"
reset; run SB_CAPS="2g 2500m" >/dev/null
ok "SB_CAPS explicit list passed verbatim"         "SB_CAPS=[2g 2500m]" "$(caps)"
ok "  and recorded as explicit"                    "heap_range=explicit" "$(manifest | grep '^heap_range=')"
reset; run SIZING_REPEATS=2 STUB_PLAN="2456m:38,39 2864m:33,34 3280m:K,K" >/dev/null
ok "repeats 2: round-robin, not grouped"           "SB_CAPS=[2456m 2864m 3280m 2456m 2864m 3280m]" "$(caps)"
ok "  two cell lines per heap, in run order"       "2456m 38|2456m 39|2864m 33|2864m 34" "$(manifest | awk '/^cell (2456m|2864m)/{printf "%s%s %s", (n++?"|":""), $2, $4}')"
reset; out=$(run SIZING_DRY_RUN=1); rc=$?
ok "dry run: plan, no matrix, exit 0"              "0 0 yes" "$rc $(wc -l < "$TMP/calls") $(case "$out" in *"dry run : stopping here"*) echo yes;; esac)"
reset; out=$(run SIZING_HEAP_START=90% SIZING_HEAP_STOP=90%); rc=$?
ok "90 %: warned, still runs"                      "0 yes" "$rc $(case "$out" in *"WARN: -Xmx3688m is 90 %"*) echo yes;; esac)"

echo "refusals"
reset; out=$(run SIZING_REPEATS=5); rc=$?
ok "3 heaps x 5 = 15 > 12 -> refused, no matrix"   "1 0 yes" "$rc $(wc -l < "$TMP/calls") $(case "$out" in *"above SIZING_MAX_CELLS=12"*) echo yes;; esac)"
reset; run SIZING_REPEATS=5 SIZING_MAX_CELLS=20 >/dev/null; rc=$?
ok "  SIZING_MAX_CELLS raised -> runs 15 cells"    "0 15" "$rc $(manifest | grep -c '^cell ')"
reset; out=$(run SIZING_HEAP_START=100% SIZING_HEAP_STOP=100%); rc=$?
ok "100 % of budget -> refused"                    "1 yes" "$rc $(case "$out" in *"wall certain"*) echo yes;; esac)"
reset; out=$(run SIZING_HEAP_START=80% SIZING_HEAP_STOP=60%); rc=$?
ok "start above stop -> refused"                   "1 yes" "$rc $(case "$out" in *"is above"*) echo yes;; esac)"
reset; out=$(run SIZING_HEAP_STEP=0%); rc=$?
ok "step 0 -> refused"                             "1 yes" "$rc $(case "$out" in *"must be positive"*) echo yes;; esac)"
reset; out=$(run SIZING_HEAP_START=2g SIZING_HEAP_STOP=80% SIZING_HEAP_STEP=10%); rc=$?
ok "mixed units -> refused"                        "1 yes" "$rc $(case "$out" in *"share one unit"*) echo yes;; esac)"
reset; out=$(run STUB_CHECKENV_RC=1); rc=$?
ok "preflight fails -> exit 1, no matrix"          "1 0" "$rc $(wc -l < "$TMP/calls")"
reset; rm -f "$H/target/server-argv.cache"; out=$(run); rc=$?
ok "no argv cache -> exit 1, points at runBoxA"    "1 yes" "$rc $(case "$out" in *"runBoxA.sh first"*) echo yes;; esac)"
printf 'x\0' > "$H/target/server-argv.cache"
reset; out=$(cd "$KIT" && env -i PATH=/usr/bin:/bin HOME="$TMP" STUB_CALLS="$TMP/calls" bash ./runSizing.sh 2>&1); rc=$?
ok "GUEST_JVM_EXTRA unset -> refuses"              "1 yes" "$rc $(case "$out" in *"GUEST_JVM_EXTRA is not set"*) echo yes;; esac)"

echo
if [ "$FAIL" -eq 0 ]; then printf '  \033[32m%d passed, 0 failed\033[0m\n' "$PASS"; exit 0
else printf '  \033[31m%d passed, %d FAILED:\033[0m %s\n' "$PASS" "$FAIL" "${FAILED_NAMES[*]}"; exit 1; fi
