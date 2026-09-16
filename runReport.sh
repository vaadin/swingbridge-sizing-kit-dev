#!/usr/bin/env bash
# The result: one Markdown report from a sizing run's manifest, with every run
# so far beneath it for comparison.
#
#   ./runReport.sh                 the newest harness/reports/*-sizing.txt
#   ./runReport.sh <manifest>      a particular run
#
# Two stages, deliberately split. This script reads every cell with the same
# probes.sh functions the harness used to write it -- cell_verdict (the publishability bar),
# monitor_peaks, the verdict lines -- one TSV row per cell beside each manifest.
# renderReport.py then adds what the monitor and samples CSVs say, names what ran
# out first, and writes the document. The verdict logic stays in one place, in
# bash, where testProbes.sh pins it. Every manifest's TSV is rebuilt each time, so
# the "all runs so far" table is always complete.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
KIT=$PWD
H="$KIT/harness"
say() { echo "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }
. "$H/harness-env.sh"
. "$H/probes.sh"

M="${1:-$(ls -t "$H"/reports/*-sizing.txt 2>/dev/null | head -1)}"
[ -n "$M" ] && [ -r "$M" ] || die "no sizing manifest. Run ./runSizing.sh first, or name one: ./runReport.sh harness/reports/<stamp>-sizing.txt"
STAMP=$(sed -n 's/^sizing_stamp=//p' "$M" | head -1)
[ -n "$STAMP" ] || die "$M has no sizing_stamp line; is it a sizing manifest?"

field() { grep -m1 -oP "$2\\s*: \\K.*" "$1" 2>/dev/null | head -1 | tr '\t' ' ' | cut -c1-200; }
num()   { local v; v=$(grep -m1 -oP "$2\\s*: \\K-?[0-9]+" "$1" 2>/dev/null); printf '%s' "${v:--}"; }

build_tsv() { # manifest -> writes <manifest%.txt>.cells.tsv
  local m="$1" out="${1%.txt}.cells.tsv" kind cap log _u _o users ok v kill joom live reached stopped why csv ev lt el
  {
    printf 'cap\tlog\tusers\tok\tkill\tjoom\tlive\treached\tstopped\twhy\tpeak_mb\tbudget_mb\tpeak_pct\toom_kills\tlaunch_timeouts\tevent_lines\n'
    while read -r kind cap log _u _o; do
      [ "$kind" = cell ] || continue
      if [ "$log" = "-" ] || [ ! -r "$log" ]; then
        printf '%s\t-\t-1\tno:no-log\t-\t-\t-\t-\t-\t-\t0\t0\t0\t0\t-\t-\n' "$cap"; continue
      fi
      v=$(cell_verdict "$log"); users=${v%% *}; ok=${v#* }
      kill=$(grep -m1 -oP 'kernel kill\s*: \K[A-Za-z]+' "$log" 2>/dev/null); kill=${kill:--}
      joom=$(num "$log" 'java OOM in log'); live=$(num "$log" 'scope alive thru'); reached=$(num "$log" 'tenants reached')
      stopped=$(num "$log" 'stopped at'); why=$(field "$log" 'why'); why=${why:--}
      csv="${log%.log}.monitor.csv"
      read -r peak_mb budget_mb peak_pct oom_kills <<<"$(monitor_peaks "$csv")"
      ev="${log%.log}.server-events.log"
      if [ -r "$ev" ]; then lt=$(grep -c 'launch timeout' "$ev" 2>/dev/null || echo 0); el=$(wc -l < "$ev"); else lt=-; el=-; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$cap" "$log" "$users" "$ok" "$kill" "$joom" "$live" "$reached" "$stopped" "$why" \
        "$peak_mb" "$budget_mb" "$peak_pct" "$oom_kills" "$lt" "$el"
    done < "$m"
  } > "$out"
}

for m in "$H"/reports/*-sizing.txt; do [ -r "$m" ] && build_tsv "$m"; done
CELLS="${M%.txt}.cells.tsv"
OUT="$H/reports/$STAMP-report.md"
python3 "$H/scenario/renderReport.py" "$M" "$CELLS" "$H/reports" > "$OUT" || die "renderReport.py failed"
say "report   : $OUT"
sed -n '/^## Result/,/^## /p' "$OUT" | grep -vE '^## ' | sed 's/^/  /'
