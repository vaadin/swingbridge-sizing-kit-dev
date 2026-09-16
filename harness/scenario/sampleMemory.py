#!/usr/bin/env python3
"""One memory sample, taken at a scenario cycle boundary. Prints one CSV row.

Attached to a CYCLE COUNT, not to elapsed time. A figure sampled on a timer says
"this much memory after 90 seconds", which conflates memory with speed. A figure
sampled at a boundary says "this much after N completed cycles of a verified
workload", which is comparable between runs and is what a per-user equation needs.

Each row carries the same quantity three ways, because they answer different
questions and disagree on purpose:

  heap_used_pre     what the JVM is holding right now, garbage included. Grows
                    and falls with GC timing, so a single reading of it means
                    little; the series shows the sawtooth.
  heap_live         retained live set, measured after a forced full GC. This is
                    the accumulation signal: if it climbs cycle after cycle, the
                    workload is leaking, and no GC tuning will save it.
  rss / pss         what the operating system has actually committed — PSS
                    because summing RSS over a process tree double-counts every
                    shared page.

Forcing a full GC at a boundary is deliberate and does perturb the process: it
resets the sawtooth. That is the trade — a clean live-set reading is worth more
than an undisturbed heap curve, and heap_used_pre preserves the undisturbed
value as it was just before the collection.

Usage (the caller names the processes):
  sampleMemory.py --header
  sampleMemory.py --cycle 3 --channel sb --proc-pid 90374 --heap-pid 90374
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

FIELDS = [
    "cycle", "tenants", "channel", "tenant", "t_utc", "procs",
    "heap_used_pre_mb", "heap_live_mb", "heap_committed_mb",
    "meta_used_mb", "meta_committed_mb",
    "rss_mb", "pss_mb", "rss_postgc_mb", "pss_postgc_mb",
    "threads", "fds", "host_avail_mb", "swap_used_mb",
    "gc_ms", "gc_passes", "heap_settled",
]


def jcmd(pid, *args):
    r = subprocess.run(["jcmd", str(pid)] + list(args), capture_output=True,
                       text=True, timeout=120)
    return r.stdout


HEAP_TOTAL = re.compile(r"total\s+(\d+)K,\s+used\s+(\d+)K")
HEAP_USED_ONLY = re.compile(r"used\s+(\d+)K")
META = re.compile(r"Metaspace\s+used\s+(\d+)K,\s+committed\s+(\d+)K")


def heap_info(pids):
    """Heap used/committed and Metaspace, summed over the named JVMs."""
    used = committed = mused = mcommitted = 0.0
    for pid in pids:
        out = jcmd(pid, "GC.heap_info")
        m = HEAP_TOTAL.search(out)
        if m:
            committed += int(m.group(1)) / 1024.0
            used += int(m.group(2)) / 1024.0
        else:
            # Non-G1 collectors print the regions separately; fall back to the
            # first "used" figure rather than silently reporting zero.
            m = HEAP_USED_ONLY.search(out)
            if m:
                used += int(m.group(1)) / 1024.0
        m = META.search(out)
        if m:
            mused += int(m.group(1)) / 1024.0
            mcommitted += int(m.group(2)) / 1024.0
    return used, committed, mused, mcommitted


def collected_heap(pids, attempts=4, tol=4.0):
    """Collect to a FIXED POINT, and say whether it got there.

    One forced collection is not enough to call the result a live set. At one
    tenant it looked like it was — the number was stable — but at twelve the
    same column wandered by 349 MB between consecutive boundaries, which no
    live set does. Whatever the cause (a collection that leaves work behind, or
    genuinely reachable-but-transient state from twelve guests that have just
    finished painting), the honest reading is the one that stops moving.

    So: collect, read, repeat, and accept the value only when two consecutive
    post-collection readings agree. If they never do, the row says so in
    heap_settled rather than presenting the last guess as a measurement.
    """
    prev = None
    used = committed = mused = mcommitted = 0.0
    for i in range(1, attempts + 1):
        for pid in pids:
            jcmd(pid, "GC.run")
        used, committed, mused, mcommitted = heap_info(pids)
        if prev is not None and abs(used - prev) <= tol:
            return used, committed, mused, mcommitted, i, True
        prev = used
    return used, committed, mused, mcommitted, attempts, False


def proc_mem(pids):
    """RSS, PSS, threads and file descriptors, summed over the named processes.

    A process that has exited between two samples is skipped rather than fatal:
    a run that spans a guest's exit must still produce a row.
    """
    rss = pss = 0.0
    threads = fds = 0
    live = 0
    for pid in pids:
        try:
            with open("/proc/%d/status" % pid) as fh:
                for line in fh:
                    if line.startswith("VmRSS:"):
                        rss += int(line.split()[1]) / 1024.0
                    elif line.startswith("Threads:"):
                        threads += int(line.split()[1])
            with open("/proc/%d/smaps_rollup" % pid) as fh:
                for line in fh:
                    if line.startswith("Pss:"):
                        pss += int(line.split()[1]) / 1024.0
            fds += len(os.listdir("/proc/%d/fd" % pid))
            live += 1
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    return rss, pss, threads, fds, live


def host_mem():
    avail = swap_total = swap_free = 0.0
    with open("/proc/meminfo") as fh:
        for line in fh:
            k = line.split()
            if line.startswith("MemAvailable:"):
                avail = int(k[1]) / 1024.0
            elif line.startswith("SwapTotal:"):
                swap_total = int(k[1]) / 1024.0
            elif line.startswith("SwapFree:"):
                swap_free = int(k[1]) / 1024.0
    return avail, swap_total - swap_free


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--header", action="store_true")
    ap.add_argument("--cycle", type=int, default=-1)
    ap.add_argument("--tenants", type=int, default=1,
                    help="how many tenants the server is hosting for this row; "
                         "per-tenant cost is a slope over this, never a "
                         "difference at one point")
    ap.add_argument("--channel", default="?")
    ap.add_argument("--tenant", default="")
    ap.add_argument("--proc-pid", type=int, action="append", default=[],
                    help="count this process's RSS/PSS/threads/FDs")
    ap.add_argument("--heap-pid", type=int, action="append", default=[],
                    help="force a GC here and read its heap and Metaspace")
    ap.add_argument("--no-gc", action="store_true",
                    help="skip the forced collection; heap_live is then left "
                         "empty rather than reported as if it were a live set")
    a = ap.parse_args()

    if a.header:
        print(",".join(FIELDS))
        return 0

    proc_pids, heap_pids = list(a.proc_pid), list(a.heap_pid)
    if not proc_pids:
        print("ERROR: no processes named (--proc-pid)", file=sys.stderr)
        return 2

    used_pre, _, _, _ = heap_info(heap_pids) if heap_pids else (0, 0, 0, 0)
    rss, pss, threads, fds, live = proc_mem(proc_pids)

    gc_ms = 0.0
    passes = 0
    settled = ""
    live_heap = committed = mused = mcommitted = 0.0
    if heap_pids and not a.no_gc:
        t0 = datetime.datetime.now(datetime.timezone.utc)
        (live_heap, committed, mused, mcommitted, passes,
         ok) = collected_heap(heap_pids)
        gc_ms = (datetime.datetime.now(datetime.timezone.utc)
                 - t0).total_seconds() * 1000.0
        settled = "yes" if ok else "NO"
    elif heap_pids:
        _, committed, mused, mcommitted = heap_info(heap_pids)

    rss2, pss2, _, _, _ = proc_mem(proc_pids)
    avail, swap = host_mem()

    row = [
        a.cycle, a.tenants, a.channel, a.tenant,
        datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        live,
        "%.1f" % used_pre,
        "" if (not heap_pids or a.no_gc) else "%.1f" % live_heap,
        "%.1f" % committed, "%.1f" % mused, "%.1f" % mcommitted,
        "%.1f" % rss, "%.1f" % pss, "%.1f" % rss2, "%.1f" % pss2,
        threads, fds, "%.1f" % avail, "%.1f" % swap, "%.0f" % gc_ms,
        passes, settled,
    ]
    print(",".join(str(v) for v in row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
