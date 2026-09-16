#!/usr/bin/env python3
"""
Builds the ONE patched guest artefact every run loads.

A measurement is only comparable with the next if the guest is the same bytes,
so the artefact is built once, here, and its checksum goes into each run's
provenance.
This script also prints exactly which entries differ from the reference jar,
which is the evidence for "same bytes except the patch" rather than a claim.

How it works, and why each step is needed:

* **Compile against the reference jar, with -implicit:none.** JOSM's own build
  needs ant and ivy and network access. Its released jar is a fat jar containing
  every dependency, so the sources compile against it offline. The
  `-implicit:none` and the absent `-sourcepath` matter: with a sourcepath javac
  prefers sources over the jar and silently recompiles most of JOSM — measured,
  3,532 class files instead of 10 — which would replace thousands of officially
  built classes with locally built ones and destroy the property this script
  exists to guarantee.

* **Drop the signature.** The released jar is signed by JOSMTEAM
  (`META-INF/JOSMTEAM.SF`, `.RSA`) with a per-entry SHA-256 digest in its
  manifest. Replacing a class without removing those makes the JVM refuse to
  load it: `SecurityException: SHA-256 digest error`. So signature files are
  dropped and the manifest keeps only its main section.

* **Keep the manifest's main section verbatim.** It carries `Main-class`,
  `Add-Exports` and `Add-Opens`. Note those module flags only take effect for
  `java -jar`; the bridge launches the guest as `-cp` plus a main class, which
  ignores them — which is why the flags have to be repeated on the server's
  command line, and why omitting them made the guest exit during start-up.

Usage:
  ./buildPatchedJar.py --source $JOSM_SRC \\
      --reference $HOME/dev/josm/josm-tested.jar \\
      --out $JOSM_JAR \\
      src/org/openstreetmap/josm/tools/WidgetBounds.java \\
      src/org/openstreetmap/josm/gui/MainApplication.java
"""
import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

SIG_SUFFIXES = (".SF", ".DSA", ".RSA", ".EC")


def compile_sources(source_dir, reference, files, out_dir, release):
    cmd = ["javac", "-nowarn", "-proc:none", "-implicit:none",
           "--release", str(release), "-d", out_dir, "-cp", reference] + files
    r = subprocess.run(cmd, cwd=source_dir, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("compile failed:\n" + r.stdout + r.stderr)
    produced = []
    for root, _dirs, names in os.walk(out_dir):
        for n in names:
            if n.endswith(".class"):
                produced.append(os.path.relpath(os.path.join(root, n), out_dir))
    return sorted(produced)


def manifest_main_section(raw):
    """Only the main attributes: the per-entry digest blocks must not survive."""
    for sep in (b"\r\n\r\n", b"\n\n"):
        if sep in raw:
            return raw.split(sep)[0] + sep
    return raw


def build(reference, out, classes_dir, produced):
    src = zipfile.ZipFile(reference)
    replaced = {p.replace(os.sep, "/") for p in produced}
    dropped = []
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as dst:
        for info in src.infolist():
            name = info.filename
            if name.upper().startswith("META-INF/") and \
                    name.upper().endswith(SIG_SUFFIXES):
                dropped.append(name)
                continue
            if name in replaced:
                continue                       # written from classes_dir below
            data = src.read(name)
            if name == "META-INF/MANIFEST.MF":
                data = manifest_main_section(data)
            dst.writestr(info, data)
        for rel in produced:
            with open(os.path.join(classes_dir, rel), "rb") as fh:
                dst.writestr(rel.replace(os.sep, "/"), fh.read())
    return dropped


def report(reference, out):
    a = zipfile.ZipFile(reference)
    b = zipfile.ZipFile(out)
    ai = {i.filename: i.CRC for i in a.infolist()}
    bi = {i.filename: i.CRC for i in b.infolist()}
    added = sorted(set(bi) - set(ai))
    removed = sorted(set(ai) - set(bi))
    changed = sorted(n for n in set(ai) & set(bi) if ai[n] != bi[n])
    print("  entries: %d -> %d" % (len(ai), len(bi)))
    for label, items in (("added", added), ("changed", changed),
                         ("removed", removed)):
        print("  %s (%d):" % (label, len(items)))
        for n in items[:20]:
            print("     ", n)
        if len(items) > 20:
            print("      ... and %d more" % (len(items) - 20))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="JOSM source checkout")
    ap.add_argument("--reference", required=True, help="released fat jar")
    ap.add_argument("--out", required=True)
    ap.add_argument("--release", default=11, type=int,
                    help="bytecode target; 11 matches the released jar")
    ap.add_argument("files", nargs="+", help="sources to patch, repo-relative")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="josm-patch-")
    try:
        produced = compile_sources(a.source, a.reference, a.files, tmp,
                                   a.release)
        print("compiled %d class files from %d source files"
              % (len(produced), len(a.files)))
        if len(produced) > 200:
            sys.exit("refusing to continue: %d classes produced, which means "
                     "javac recompiled far more than the named files"
                     % len(produced))
        if os.path.exists(a.out):
            os.remove(a.out)
        dropped = build(a.reference, a.out, tmp, produced)
        print("dropped signature files: %s" % (dropped or "none"))
        report(a.reference, a.out)
        print("  reference sha256: %s" % sha256(a.reference))
        print("  patched   sha256: %s" % sha256(a.out))
        print("  patched   path  : %s" % a.out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
