#!/usr/bin/env python3
"""Render the sizing report: a manifest, its cells TSV, and the reports dir -> Markdown.

runReport.sh has read every cell with the harness's own verdict functions; this
adds what the monitor and samples CSVs say about CPU, the load box and the heap,
decides what ran out first for each cell, groups by heap, and writes the document.
There is no winner logic: when one heap has two or more publishable runs their
median is the headline; otherwise the table is the result and the reader chooses
the next heap. Every number can be traced to a file named at the bottom.

Usage: renderReport.py <manifest> <cells.tsv> <reports_dir> > report.md
"""
import csv
import glob
import os
import statistics
import sys
from collections import Counter, OrderedDict
from datetime import datetime, timezone


def num(v, kind=float):
    try:
        return kind(v)
    except (TypeError, ValueError):
        return None


def heap_mb(v):
    v = (v or "").strip().lower()
    try:
        if v.endswith("g"):
            return int(v[:-1]) * 1024
        if v.endswith("m"):
            return int(v[:-1])
        if v.endswith("k"):
            return int(v[:-1]) // 1024
        return int(v) // 1048576
    except ValueError:
        return 0


def fmt(v, spec="{:.0f}", dash="-"):
    return dash if v is None else spec.format(v)


def csv_stats(path):
    """Peaks and extremes from one monitor CSV, by column name."""
    st = {}
    if not path or not os.path.exists(path):
        return st
    with open(path, newline="") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        return st

    def mx(col):
        vals = [num(r.get(col)) for r in rows]
        vals = [v for v in vals if v is not None]
        return max(vals) if vals else None

    st["cpu_max"] = mx("cpu_pct")
    st["threads_max"] = mx("threads")
    st["peer_load1_max"] = mx("peer_load1")
    live = [r for r in rows if r.get("cg_mem_mb")]
    # The load box's load1 at the END of the ramp, as a median over the last
    # quarter of the live samples. Not the peak: load1 is a one-minute average
    # that counts D-state, and every Chromium launch spikes it -- round 2 saw
    # peaks of 30 on a box whose median sat under 4 while the ceiling was being
    # reached. The peak is shown; the median decides.
    late = [num(r.get("peer_load1")) for r in live[len(live) * 3 // 4:]]
    late = [v for v in late if v is not None]
    st["peer_load1_late"] = statistics.median(late) if late else None
    st["duration_s"] = num(live[-1].get("elapsed_s")) if live else None
    return st


def samples_stats(path):
    """The JVM's own view at the last sample: heap used and committed, metaspace."""
    st = {}
    if not path or not os.path.exists(path):
        return st
    with open(path, newline="") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        return st
    last = rows[-1]
    st["heap_used"] = num(last.get("heap_used_pre_mb"))
    st["heap_committed"] = num(last.get("heap_committed_mb"))
    st["meta_used"] = num(last.get("meta_used_mb"))
    st["rss"] = num(last.get("rss_mb"))
    return st


def cause(r, st, boxb_cores):
    """What ran out first, in words, from the evidence -- with any caveats."""
    notes = []
    ok = r["ok"]
    why = (r["why"] or "").lower()
    joom = num(r["joom"], int) or 0
    lt = r["launch_timeouts"]
    pct = num(r["peak_pct"]) or 0.0
    users, live = num(r["users"], int), num(r["live"], int)
    if r["kill"] == "survived":
        notes.append("kernel verdict 'survived' -- a process in the scope was killed and the server went on; unexpected for a single-JVM server, inspect this cell before trusting it")
    if users is not None and live is not None and users > live:
        notes.append(f"counted past the last live cgroup reading; trust at most {live}")
    if ok.startswith("no:") and not ok.startswith("no:void"):
        notes.append(f"not publishable: {ok[3:]}")
    if ok.startswith("no:void"):
        return "void -- the ramp did not complete (the driver exited non-zero); nothing in this cell is a limit", notes
    if r["kill"] == "YES":
        return "the budget, hard: the kernel killed the server at the wall -- not publishable", notes
    if joom > 0:
        return f"the heap: {joom} OutOfMemoryError(s) in the server log -- -Xmx{r['cap']} is too small for this application at this count", notes
    if lt not in ("", "-") and (num(lt, int) or 0) > 0:
        return f"the bridge's 5-second first-window limit: {lt} guest(s) failed to show a window in time (not memory)", notes
    if "liveness failed" in why:
        return "the guest contract: a tenant stopped publishing bounds lines within the window", notes
    if "no new guest published" in why:
        return "the guest contract: the guest never published a bounds line after the page loaded", notes
    if "canvas settled at" in why:
        return "the guest contract: the canvas and the published window disagree -- pin the geometry", notes
    peer = st.get("peer_load1_late")
    cores = num(boxb_cores, int)
    if peer is not None and cores and peer >= 0.8 * cores:
        return f"your load box: load1 {peer:.1f} on {cores} cores through the end of the ramp -- the generator was at its limit; treat this count as a floor", notes
    if st.get("peer_load1_max") is not None and cores and st["peer_load1_max"] >= cores:
        notes.append(f"load box load1 peaked at {st['peer_load1_max']:.1f} on {cores} cores -- a launch transient, not sustained; the late-ramp median was {fmt(peer, '{:.1f}')}")
    if pct >= 90:
        if "could not start" in why and lt in ("", "-"):
            notes.append("the driver saw a tenant fail to start and no server events were kept for this cell, so the 5-second launch limit cannot be ruled out")
        return f"the budget: memory reached {pct:.0f} % of {r['budget_mb']} MB when the set degraded", notes
    cpu = st.get("cpu_max")
    return (f"the quality bar: the set degraded at {pct:.0f} % memory"
            + (f" (CPU peak {cpu:.0f} %)" if cpu is not None else "")
            + " -- response time or staleness gave out before memory did"), notes


def heap_cell(c):
    """'2560 / 2560 MB (100 %)': heap committed at the ceiling against -Xmx."""
    xmx = heap_mb(c["cap"])
    com = c["sm"].get("heap_committed")
    if com is None or not xmx:
        return "-"
    return f"{com:.0f} / {xmx} MB ({100.0 * com / xmx:.0f} %)"


def load_cells(tsv, boxb_cores):
    with open(tsv, newline="") as fh:
        cells = list(csv.DictReader(fh, delimiter="\t"))
    for c in cells:
        base = c["log"][:-4] if c["log"] not in ("-", "") else None
        c["st"] = csv_stats(base + ".monitor.csv" if base else None)
        c["sm"] = samples_stats(base + ".samples.csv" if base else None)
        c["cause"], c["notes"] = cause(c, c["st"], boxb_cores)
        c["stamp"] = os.path.basename(c["log"])[:14] if base else ""
    return cells


def by_heap(cells):
    groups = OrderedDict()
    for c in sorted(cells, key=lambda c: (heap_mb(c["cap"]), c["stamp"])):
        groups.setdefault(c["cap"], []).append(c)
    return groups


def median_lower(vals):
    vals = sorted(vals)
    return vals[(len(vals) - 1) // 2] if vals else None


def per_heap_rows(groups, budget_mb, p):
    p("| -Xmx | of budget | runs: healthy users | publishable | median | heap at the ceiling | what ran out first |")
    p("|---|---|---|---|---|---|---|")
    for cap, cs in groups.items():
        pub = [num(c["users"], int) for c in cs if c["ok"] == "YES" and num(c["users"], int) is not None]
        counts = ", ".join(c["users"] if c["users"] != "-1" else "-" for c in cs)
        med = str(median_lower(pub)) if len(pub) >= 2 else ("-" if not pub else f"({pub[0]}, one run)")
        pct = f"{100.0 * heap_mb(cap) / budget_mb:.0f} %" if budget_mb else "-"
        with_heap = [heap_cell(c) for c in cs if c["sm"].get("heap_committed") is not None]
        heap = with_heap[-1] if with_heap else "-"
        causes = Counter(c["cause"].split(":")[0] for c in (cs if not pub else [c for c in cs if c["ok"] == "YES"]))
        dom = causes.most_common(1)[0][0] if causes else "-"
        p(f"| {cap} | {pct} | {counts} | {len(pub)} of {len(cs)} | {med} | {heap} | {dom} |")


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    manifest, cells_tsv, reports_dir = sys.argv[1:4]
    meta = {}
    for line in open(manifest):
        if "=" in line and not line.startswith("cell "):
            k, v = line.rstrip("\n").split("=", 1)
            meta[k] = v
    boxb_cores = meta.get("boxb_cores", "")
    cells = load_cells(cells_tsv, boxb_cores)
    groups = by_heap(cells)
    budget = meta.get("budget_gb", "?")
    budget_mb = (num(budget, int) or 0) * 1024
    jar = os.path.basename(meta.get("server_jar", "")) or "the application"
    sbv = meta.get("swing_bridge_version", "") or "?"

    # The headline rule, and nothing cleverer: one heap with two or more
    # publishable runs -> their median. Zero -> a picture. Several -> the table.
    repeated = {cap: [num(c["users"], int) for c in cs if c["ok"] == "YES" and num(c["users"], int) is not None]
                for cap, cs in groups.items()}
    repeated = {cap: v for cap, v in repeated.items() if len(v) >= 2}

    out = []
    p = out.append
    stamp = meta.get("sizing_stamp", "")
    try:
        when = datetime.strptime(stamp, "%Y%m%d%H%M%S").replace(tzinfo=timezone.utc).strftime("%d %b %Y, %H:%M UTC")
    except ValueError:
        when = stamp
    p(f"# Sizing report -- {jar} on Swing Bridge {sbv}")
    p("")
    p(f"*{when} · budget **{budget} GB** · heaps {meta.get('heaps','?')} ({meta.get('heap_range','?')}) · {meta.get('repeats','?')} run(s) per heap*")
    p("")
    p("## Result")
    p("")
    if len(repeated) == 1:
        cap, vals = next(iter(repeated.items()))
        in_order = [c["users"] for c in groups[cap] if c["ok"] == "YES"]
        med = median_lower(vals)
        how = "median" if len(vals) % 2 else "lower middle of the two medians"
        p(f"**{med} concurrent active users fit in a {budget} GB budget** with this application on Swing Bridge {sbv}, at `-Xmx{cap}`.")
        p("")
        p(f"That is the {how} of {len(vals)} publishable runs at that heap: {', '.join(in_order)} (min {min(vals)}, max {max(vals)}).")
        p("*Active* means every user was working through the scenario the whole time, every step asserted; *fit* means the whole set still met the quality bar -- see *How to read this*.")
        causes = [c["cause"] for c in groups[cap] if c["ok"] == "YES"]
        p("")
        p("**What ran out first:** " + (causes[0] if len(set(causes)) == 1 else "it differs between runs -- see the table") + ".")
    elif len(repeated) == 0:
        p(f"**A picture, not a published count.** One run per heap at {budget} GB:")
        p("")
        for cap, cs in groups.items():
            c = cs[0]
            verdict = "publishable" if c["ok"] == "YES" else c["ok"].replace("no:", "not publishable: ")
            p(f"- `-Xmx{cap}` -> **{c['users'] if c['users'] != '-1' else '-'}** healthy users, {verdict}; {c['cause']}")
        p("")
        p("Run-to-run spread at one heap is as wide as the gap between neighbouring heaps, so a single run cannot rank them. Choose a heap from the table and repeat there (`SB_CAPS=<heap> SIZING_REPEATS=3 ./runSizing.sh`) for a publishable count.")
    else:
        p("**Several heaps have repeated runs; the table ranks them -- choose.** Medians by heap: "
          + ", ".join(f"`-Xmx{cap}` {median_lower(v)}" for cap, v in repeated.items()) + ".")
    p("")
    p("## Per heap")
    p("")
    per_heap_rows(groups, budget_mb, p)
    p("")
    p("## Every cell")
    p("")
    p("| -Xmx | run | healthy users | verdict | memory peak | heap committed | CPU peak | load box load1 (late median / peak) | duration | what ran out first |")
    p("|---|---|---|---|---|---|---|---|---|---|")
    for cap, cs in groups.items():
        for i, c in enumerate(cs, 1):
            st = c["st"]
            verdict = "publishable" if c["ok"] == "YES" else c["ok"].replace("no:", "no: ")
            mem = f"{fmt(num(c['peak_mb']))} / {c['budget_mb']} MB ({fmt(num(c['peak_pct']))} %)" if num(c["peak_mb"]) else "-"
            dur = fmt(st.get("duration_s"), "{:.0f} s") if st.get("duration_s") else "-"
            note = (" ".join(f"*{n}*" for n in c["notes"])) if c["notes"] else ""
            p(f"| {cap} | {i} | {c['users'] if c['users'] != '-1' else '-'} | {verdict} | {mem} | {heap_cell(c)} | {fmt(st.get('cpu_max'))} % | {fmt(st.get('peer_load1_late'), '{:.1f}')} / {fmt(st.get('peer_load1_max'), '{:.1f}')} | {dur} | {c['cause']} {note} |")
    p("")

    # Every run so far, across every manifest in the reports directory.
    others = sorted(t for t in glob.glob(os.path.join(reports_dir, "*-sizing.cells.tsv")) if os.path.abspath(t) != os.path.abspath(cells_tsv))
    if others:
        all_cells = list(cells)
        for t in others:
            all_cells += load_cells(t, boxb_cores)
        p("## All runs so far")
        p("")
        p(f"Every cell from {len(others) + 1} sizing runs in this reports directory, by heap.")
        p("")
        per_heap_rows(by_heap(all_cells), budget_mb, p)
        p("")

    p("## How to read this")
    p("")
    p("- **Healthy users** is the last tenant count at which the whole set still met the quality bar: every step's declared screen change observed, the slowest step within 3x the single-user step time (floor 750 ms), and no tenant stale for longer than 2x that factor times the single-user cycle time. The bar is measured against this run's own first tenant, so it needs no tuning for your application. (Defaults; `EXTRA_RAMP` can change them.)")
    p("- **Publishable** is a mechanical bar: no kernel kill of the server, no `OutOfMemoryError` in the server log, no tenant counted after the last live cgroup reading, and the ramp itself did not exit non-zero. A cell failing any of these is shown but never counted. The kill verdict comes from the systemd journal, not from the cgroup's own counter: the counter dies with the scope and never records the kill that ends a cell.")
    p("- **Heap at the ceiling** is the JVM's committed heap at the last sample against `-Xmx`. Committed at `-Xmx` with the budget at the wall: heap and budget filled together, a balanced cap. A Java OOM: the cap is too small -- try larger. Committed well under `-Xmx` with the budget at the wall: the heap had room, the rest of the JVM did not -- try smaller.")
    p("- **What ran out first** is decided from evidence in this order: a killed server, a Java OOM, the bridge's 5-second first-window limit (from the server's event log), a guest-contract failure named by the driver, a saturated load box (its `load1` over the last quarter of the ramp against its core count -- the peak is a launch transient and is shown but not used), memory at the wall, and otherwise the quality bar.")
    p("- **The load box** is the generator, not the server: if it is the limit, the count is a floor, not a ceiling.")
    p("- **One run per heap is a picture.** Spread at one heap in round 2 was 34-39 and 38-41; a count worth publishing is the median of at least three runs at one heap.")
    p("")
    p("## Provenance")
    p("")
    p(f"- application jar: `{jar}`" + (f" (sha256 {meta['server_jar_sha256']}…)" if meta.get("server_jar_sha256") not in (None, "", "unknown") else "")
      + (f"; main class `{meta['main_class']}`" if meta.get("main_class") else "")
      + (f"; view `/{meta['view']}`" if meta.get("view") else ""))
    p(f"- Swing Bridge {sbv}; skeleton-starter clone at `{meta.get('skeleton_rev','?')}`; sizing kit at `{meta.get('kit_rev','?')}`")
    p(f"- server box: {meta.get('box_cores','?')} cores, {meta.get('box_ram_gb','?')} GB RAM, virtualisation `{meta.get('box_virt','?')}`"
      + (" -- a VM; say so when quoting the number" if meta.get("box_virt") not in ("none", "", None, "unknown") else ""))
    p(f"- load box: {boxb_cores or '?'} cores; browsers there, server here; the budget enforced by a systemd scope with `MemoryMax={budget}G`, swap off")
    p(f"- ramp: one tenant at a time up to {meta.get('sb_max','?')}, {meta.get('settle_ms','?')} ms settle before each judgement")
    p("")
    p("## Files")
    p("")
    p(f"- manifest `{os.path.basename(manifest)}`, cells `{os.path.basename(cells_tsv)}`")
    for cap, cs in groups.items():
        for c in cs:
            if c["log"] not in ("-", ""):
                b = os.path.basename(c["log"])
                p(f"- `{b}` -- with `{b[:-4]}.monitor.csv`, `{b[:-4]}.samples.csv`" + (f", `{b[:-4]}.server-events.log`" if c["event_lines"] not in ("-", "") else ""))
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
