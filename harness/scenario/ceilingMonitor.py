#!/usr/bin/env python3
"""Which resource is about to stop us. One CSV row per sample, on both boxes.

A ceiling test that only watches memory will report a memory ceiling whatever
actually happened. With every user active rather than idle, at least four things
can bind before 4 GB does, and three of them are not on the server at all:

  memory   the intended limit — a cgroup with swap off, so it OOM-kills rather
           than quietly swapping and calling itself alive
  cpu      four cores against N working users. Saturation shows as run-queue
           depth, not as 100 % — a box at 100 % with a short queue is busy, one
           with a long queue is late
  network  10.9 MB/s to the load box. Watch the SEND QUEUE, not the byte rate:
           a backlog means the application is producing frames faster than the
           link drains them, which is visible before throughput flatlines
  threads  ~15.5 per tenant measured in round 2, so pids and threads are a real
           ceiling too, and a jump per tenant is a leak
  loadbox  the generator itself. Thirty browsers on six cores can saturate, and
           then the server looks healthy while the harness is the limit — a
           ceiling reported from that is a measurement of our own equipment

Usage:
  ceilingMonitor.py --scope <systemd-scope> --iface enp0s1 --port 8088 \\
      --peer-ssh boxb --csv reports/<ts>-ceiling-sb.csv --interval 5
"""
import argparse
import datetime
import os
import re
import subprocess
import sys
import time

FIELDS = [
    "t_utc", "elapsed_s", "tenants",
    # memory: the intended ceiling
    "cg_mem_mb", "cg_mem_max_mb", "cg_mem_pct", "cg_oom_kills", "cg_swap_mb",
    # cpu: saturation, not utilisation
    "load1", "cpu_pct", "runq", "cg_cpu_s", "cg_throttled_s",
    # network: backlog first, bytes second
    "tx_mbps", "rx_mbps", "sendq_kb", "sendq_max_kb", "estab_conns",
    # the other two hard limits
    "threads", "pids", "cg_pids_max",
    # the load box, so its saturation cannot be mistaken for the server's
    "peer_load1", "peer_cpu_pct", "peer_mem_avail_mb",
    # host, for context
    "host_avail_mb", "host_swap_mb",
    # Whether a send-queue backlog is OURS or the PATH's. A queue builds either
    # because the server stalled and stopped draining it, or because the link
    # would not take the bytes. Retransmissions separate the two: congestion and
    # loss on the path show up here, a GC pause does not. Appended rather than
    # inserted, because every existing analysis indexes these columns by
    # position.
    "tcp_retrans_d", "tcp_outsegs_d",
]


def read(path, default=""):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return default


def cg_path(scope):
    """The cgroup directory for a systemd --user scope."""
    base = "/sys/fs/cgroup/user.slice/user-%d.slice/user@%d.service" % (
        os.getuid(), os.getuid())
    for root, dirs, _ in os.walk(base):
        if os.path.basename(root) == scope:
            return root
    return None


def fmt(v, spec="%s"):
    """Blank for a value that was not measurable, formatted otherwise.

    The distinction matters more than it looks: a cgroup file that cannot be
    read falls back to its default, and a default of "0" is indistinguishable
    from a real reading of zero.
    """
    return "" if v is None else spec % v


def kv(path, key):
    for line in read(path).splitlines():
        parts = line.split()
        if parts and parts[0] == key:
            return int(parts[1])
    return 0


def net_bytes(iface):
    for line in read("/proc/net/dev").splitlines():
        if line.strip().startswith(iface + ":"):
            f = line.split(":")[1].split()
            return int(f[0]), int(f[8])          # rx, tx
    return 0, 0


def send_queues(port):
    """Backlog per connection on the served port, in kB.

    The number that matters is the maximum: one saturated connection is enough
    to say the link is not keeping up with what the server wants to send.
    """
    try:
        out = subprocess.run(["ss", "-tn", "state", "established",
                              "sport", "=", ":%d" % port],
                             capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return 0, 0, 0
    total = mx = n = 0
    for line in out.splitlines()[1:]:
        f = line.split()
        if len(f) >= 2 and f[1].isdigit():
            q = int(f[1]) // 1024
            total += q
            mx = max(mx, q)
            n += 1
    return total, mx, n


def runqueue():
    """Processes wanting a CPU right now. Saturation, rather than utilisation."""
    m = re.match(r"(\d+)/", read("/proc/loadavg").split()[3]
                 if len(read("/proc/loadavg").split()) > 3 else "0/0")
    return int(m.group(1)) if m else 0


def tcp_counters():
    """Cumulative TCP RetransSegs and OutSegs from /proc/net/snmp."""
    lines = read("/proc/net/snmp").splitlines()
    for i, line in enumerate(lines):
        if line.startswith("Tcp:") and "RetransSegs" in line:
            keys = line.split()
            vals = lines[i + 1].split()
            try:
                return (int(vals[keys.index("RetransSegs")]),
                        int(vals[keys.index("OutSegs")]))
            except (ValueError, IndexError):
                return 0, 0
    return 0, 0


def cpu_times():
    f = read("/proc/stat").splitlines()[0].split()[1:]
    vals = [int(x) for x in f[:8]]
    idle = vals[3] + vals[4]
    return sum(vals), idle


def peer(ssh_host):
    """The load box. Its saturation must never be read as the server's."""
    if not ssh_host:
        return "", "", ""
    try:
        out = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", ssh_host,
             "cat /proc/loadavg; head -1 /proc/stat; "
             "awk '/MemAvailable/{print $2}' /proc/meminfo"],
            capture_output=True, text=True, timeout=25).stdout.split("\n")
        load1 = out[0].split()[0]
        avail = float(out[2]) / 1024.0
        return load1, "", "%.0f" % avail
    except Exception:                                          # noqa: BLE001
        return "", "", ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scope", required=True, help="systemd --user scope name")
    ap.add_argument("--iface", default="enp0s1")
    ap.add_argument("--port", type=int, default=8088)
    ap.add_argument("--peer-ssh", default="")
    ap.add_argument("--csv", required=True)
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--peer-every", type=int, default=1,
                    help="poll the load box every Nth sample. The peer poll is "
                         "an ssh round trip, so it, not the cgroup or the "
                         "socket dump, is what caps the sample rate. Sampling "
                         "the send queue at 1 s while polling the peer at 5 s "
                         "gives five times the queue samples for the same ssh "
                         "load -- which matters because the queue's interesting "
                         "behaviour is a transient: one 2196 kB spike was caught "
                         "in 1 sample of 301 at a 5 s interval.")
    ap.add_argument("--tenants-file", default="",
                    help="file the driver writes its current tenant count into")
    a = ap.parse_args()

    cg = cg_path(a.scope)
    if not cg:
        print("ERROR: no cgroup for scope %r — is it running?" % a.scope,
              file=sys.stderr)
        return 2
    print("watching %s" % cg)

    new = not os.path.exists(a.csv)
    fh = open(a.csv, "a")
    if new:
        fh.write(",".join(FIELDS) + "\n")
        fh.flush()

    t0 = time.time()
    rx0, tx0 = net_bytes(a.iface)
    rt0, os0 = tcp_counters()
    tot0, idle0 = cpu_times()
    last = time.time()
    ncpu = os.cpu_count() or 1
    scope_gone_at = None
    nsample = 0

    while True:
        time.sleep(a.interval)
        nsample += 1
        now = time.time()
        dt = now - last
        last = now

        # The scope usually dies AT the wall -- that death IS the ceiling. But
        # every cgroup file then falls back to its default, and a default of
        # "0" reads exactly like a measurement. This rig therefore wrote
        # "peak 0 MB / oom kills 0" into every verdict it ever produced, and
        # hid a kernel OOM kill in a headline cell. From here the cgroup
        # columns go BLANK when the scope is gone: blank means "not
        # measurable", 0 keeps meaning "measured, and it was zero". Host-level
        # columns keep being sampled -- they are still true, and the tenant
        # count continuing to climb past this point is itself evidence.
        cg_live = cg is not None and os.path.exists(cg + "/memory.current")
        if cg_live:
            mem = int(read(cg + "/memory.current", "0") or 0) / 1048576.0
            mmax_raw = read(cg + "/memory.max", "max")
            mmax = (float("inf") if mmax_raw == "max"
                    else int(mmax_raw) / 1048576.0)
            swap = int(read(cg + "/memory.swap.current", "0") or 0) / 1048576.0
            ooms = kv(cg + "/memory.events", "oom_kill")
            cpu_us = kv(cg + "/cpu.stat", "usage_usec") / 1e6
            thr = kv(cg + "/cpu.stat", "throttled_usec") / 1e6
            pids = int(read(cg + "/pids.current", "0") or 0)
            pmax = read(cg + "/pids.max", "max")
        else:
            mem = mmax = swap = ooms = cpu_us = thr = pids = None
            pmax = ""
            if scope_gone_at is None:
                scope_gone_at = now - t0
                print("NOTE scope %s is gone %.0fs in; cgroup columns blank "
                      "from here. Anything counted after this point was not "
                      "observed against a live scope."
                      % (a.scope, scope_gone_at), flush=True)

        rx1, tx1 = net_bytes(a.iface)
        tx_mbps = (tx1 - tx0) * 8 / 1e6 / dt
        rx_mbps = (rx1 - rx0) * 8 / 1e6 / dt
        rx0, tx0 = rx1, tx1

        rt1, os1 = tcp_counters()
        retrans_d, outsegs_d = rt1 - rt0, os1 - os0
        rt0, os0 = rt1, os1

        tot1, idle1 = cpu_times()
        cpu_pct = 100.0 * (1 - (idle1 - idle0) / max(tot1 - tot0, 1))
        tot0, idle0 = tot1, idle1

        sq, sqmax, conns = send_queues(a.port)
        # Read it rather than shelling out to bash+cat+wc: at a 1 s interval
        # that was three processes a second for a line count.
        threads = (len(read(cg + "/cgroup.threads").splitlines())
                   if cg_live else None)
        # Blank on the samples between polls rather than repeating the last
        # reading: a repeated value looks like a measurement that was taken.
        if a.peer_every <= 1 or (nsample % a.peer_every) == 0:
            pl, pc, pm = peer(a.peer_ssh)
        else:
            pl = pc = pm = ""
        tenants = read(a.tenants_file, "") if a.tenants_file else ""

        avail = kv("/proc/meminfo", "MemAvailable:") / 1024.0
        hswap = (kv("/proc/meminfo", "SwapTotal:")
                 - kv("/proc/meminfo", "SwapFree:")) / 1024.0

        row = [
            datetime.datetime.now(datetime.timezone.utc)
            .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "%.0f" % (now - t0), tenants,
            fmt(mem, "%.1f"),
            "" if mmax in (None, float("inf")) else "%.0f" % mmax,
            "" if mmax in (None, float("inf")) or mem is None
            else "%.1f" % (100.0 * mem / mmax),
            fmt(ooms), fmt(swap, "%.1f"),
            read("/proc/loadavg").split()[0], "%.1f" % cpu_pct, runqueue(),
            fmt(cpu_us, "%.1f"), fmt(thr, "%.1f"),
            "%.2f" % tx_mbps, "%.2f" % rx_mbps, sq, sqmax, conns,
            fmt(threads), fmt(pids), pmax,
            pl, pc, pm,
            "%.0f" % avail, "%.0f" % hswap,
            retrans_d, outsegs_d,
        ]
        fh.write(",".join(str(v) for v in row) + "\n")
        fh.flush()
        print("  t+%-5s tenants=%-4s mem %5s/%s MB (%s%%)  cpu %5s%% runq %-3s"
              "  tx %6s Mbps sendq_max %-5s kB  thr %-4s pids %-4s  oom %s"
              % (row[1], tenants or "?", fmt(mem, "%.0f") or "-",
                 row[4] or "-", row[5] or "-", row[10], row[11],
                 row[13], sqmax, fmt(threads) or "-", fmt(pids) or "-",
                 fmt(ooms) or "-"))
        if ooms:
            print("OOM-KILL inside the scope: the memory budget was the ceiling")


if __name__ == "__main__":
    sys.exit(main())
