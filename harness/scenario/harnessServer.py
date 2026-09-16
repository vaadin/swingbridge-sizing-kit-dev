#!/usr/bin/env python3
"""Box A side of a two-box scenario run. Serves two things the driver needs.

The browsers have to run on the other box: with them here, a server's RSS goes
NON-MONOTONIC as tenants are added — local Chromium competes for the same RAM and
the kernel reclaims the server's pages — so the server's memory would no longer
be its own to read. That was measured, not assumed, so the split is a
requirement rather than a convenience.

But moving the driver to Box B takes it away from two things that only exist here:

  GET /log?marker=&latest=1
                      the guest's published geometry — filtered HERE, where the
                      file is local, to the newest line per guest. Shipping the
                      raw tail meant 1508 lines of 2.8 KB so the driver could
                      read the newest one; over a 10.9 MB/s link that is ~370 ms
                      a poll, and the driver polls in several loops.

  GET /sample?cycle=&tenants=&tenant=
                      one memory sample of the processes on THIS box, taken at
                      the moment the driver asks — which is what keeps a reading
                      attached to a completed cycle rather than to a timer. The
                      row is returned to the driver and appended here, so the
                      authoritative CSV never crosses the network.

Nothing here is authenticated: it is a measurement rig for one LAN, it exposes a
log tail and a memory reading, and it should not be run anywhere else.

Usage:
  ./harnessServer.py --port 8099 --log ../target/server.log \\
      --sample-args "--channel sb --proc-pid 1234 --heap-pid 1234" \\
      --csv ../reports/<ts>-scenario-mem-sb.csv
"""
import argparse
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
LOCK = threading.Lock()
CFG = {}


def tenant_of(line, marker):
    """Which guest wrote this line: the last bracketed group before the marker.

    The bridge writes [swing:ab12cd]; a guest run outside it writes no prefix,
    and the id is then empty. Same rule as the driver's, deliberately.
    """
    m = line.find(marker)
    close = line.rfind("]", 0, m)
    if close < 0:
        return ""
    open_ = line.rfind("[", 0, close)
    return "" if open_ < 0 else line[open_:close + 1]


def _complete(line, marker):
    """Whether this line's payload is whole. A half-written line is not data."""
    try:
        json.loads(line.split(marker, 1)[1])
        return True
    except (ValueError, IndexError):
        return False


def select_lines(raw, marker, latest, max_lines, partial_first=True):
    """The lines a caller actually needs, chosen here rather than shipped whole.

    The file is local to this box; the network is not. Filtering here turns a
    4 MB transfer into a few kilobytes, and the answer is identical.

    Both ENDS of a byte tail are unsafe and both had to be trimmed:

    - the first line is cut wherever the seek landed, so it arrives without its
      "[swing:...]" prefix. That fragment was being published as the newest line
      of a guest with an empty name, and the liveness check then hunted for a
      tenant that had never existed — which ended a 31-tenant run.
    - the last line is being appended as we read, so it is often half-written.
      Parsing it raised a JsonEOFException that ended another run.

    Neither was the server failing. Both were this function reporting the edges
    of its own snapshot as data, so the edges are dropped and every line handed
    back is checked to be complete JSON first.
    """
    text = raw.decode("iso-8859-1")
    lines = text.split("\n")
    if partial_first and lines:
        lines = lines[1:]                    # cut mid-line where the seek landed
    if not text.endswith("\n") and lines:
        lines = lines[:-1]                   # still being written this instant
    lines = [l for l in lines if marker in l and _complete(l, marker)]
    if latest:
        newest = {}
        for l in lines:                      # later lines win, so one per guest
            newest[tenant_of(l, marker)] = l
        lines = list(newest.values())
    if max_lines and len(lines) > max_lines:
        lines = lines[-max_lines:]
    return ("\n".join(lines) + "\n").encode("iso-8859-1")


def tail_bytes(path, n):
    """The last n bytes, and whether that cut into a line.

    Spans a rotation. A server that rolls its log moves everything written so
    far into <path>.1, and this function reopens <path>
    on every request -- so the instant a rotation happens, every line published
    before it disappears from view. A tenant whose WIDGET-BOUNDS line was
    written just before the roll then becomes unfindable, and the driver kills
    it as though its guest had never started. That is exactly what ended a cell
    at four tenants, in the same run whose OOM count went negative for the same
    reason. Reading the predecessor when the current file is shorter than the
    window keeps the view continuous across the boundary.
    """
    chunks = []
    want = n
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        start = max(0, size - want)
        fh.seek(start)
        chunks.append(fh.read())
        want -= size - start
        partial = start > 0
    if want > 0:
        try:
            with open(path + ".1", "rb") as fh:
                fh.seek(0, os.SEEK_END)
                psize = fh.tell()
                pstart = max(0, psize - want)
                fh.seek(pstart)
                chunks.insert(0, fh.read())
                partial = pstart > 0
        except OSError:
            pass                      # no predecessor; the window is what it is
    return b"".join(chunks), partial


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass                                  # one line per poll is noise

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        try:
            if u.path == "/health":
                self._send(200, "ok\n")
            elif u.path == "/log":
                n = int(q.get("tail", ["4194304"])[0])
                raw, partial = tail_bytes(CFG["log"], n)
                marker = q.get("marker", [None])[0]
                if marker:
                    raw = select_lines(
                        raw, marker,
                        q.get("latest", ["0"])[0] == "1",
                        int(q.get("lines", ["0"])[0]), partial)
                self._send(200, raw)
            elif u.path == "/sample":
                self._send(200, self.sample(q))
            else:
                self._send(404, "no such endpoint\n")
        except Exception as exc:                       # noqa: BLE001
            # Answer with the error rather than dropping the connection: the
            # driver treats a failed sample as fatal, and a silent hang would
            # instead look like a slow one.
            self._send(500, "ERROR: %s: %s\n" % (type(exc).__name__, exc))

    def sample(self, q):
        # The driver runs on the OTHER box, so it cannot tell the monitor here
        # how many tenants are live — but every sample request carries the
        # count, and this side can write it down.
        if CFG.get("tenants_file") and "tenants" in q:
            with open(CFG["tenants_file"], "w") as fh:
                fh.write(q["tenants"][0])
        args = [os.path.join(HERE, "sampleMemory.py")]
        args += CFG["sample_args"]
        for key in ("cycle", "tenants", "tenant"):
            if key in q:
                args += ["--" + key, q[key][0]]
        with LOCK:                       # one forced GC at a time, and one writer
            r = subprocess.run(args, capture_output=True, text=True, timeout=300)
            if r.returncode != 0:
                raise RuntimeError(r.stderr.strip() or "sampler failed")
            row = r.stdout.strip()
            if CFG.get("csv"):
                new = not os.path.exists(CFG["csv"])
                with open(CFG["csv"], "a") as fh:
                    if new:
                        h = subprocess.run(args[:1] + ["--header"],
                                           capture_output=True, text=True)
                        fh.write(h.stdout)
                    fh.write(row + "\n")
        return row + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--log", required=True,
                    help="guest stdout log to serve the tail of")
    ap.add_argument("--sample-args", default="",
                    help="arguments passed through to sampleMemory.py, e.g. "
                         "'--channel sb --proc-pid 123 --heap-pid 123'")
    ap.add_argument("--csv", help="append every sampled row here")
    ap.add_argument("--tenants-file",
                    help="write the tenant count from each sample request here, "
                         "so the monitor on this box can label its rows")
    a = ap.parse_args()

    CFG["log"] = os.path.abspath(a.log)
    CFG["sample_args"] = a.sample_args.split()
    CFG["csv"] = os.path.abspath(a.csv) if a.csv else None
    CFG["tenants_file"] = a.tenants_file
    if not os.path.exists(CFG["log"]):
        print("ERROR: no log at %s" % CFG["log"], file=sys.stderr)
        return 2

    print("serving  /log     <- %s" % CFG["log"])
    print("         /sample  -> sampleMemory.py %s" % " ".join(CFG["sample_args"]))
    print("         /health")
    print("listening on %s:%d" % (a.bind, a.port))
    if CFG["csv"]:
        print("appending rows to %s" % CFG["csv"])
    ThreadingHTTPServer((a.bind, a.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
