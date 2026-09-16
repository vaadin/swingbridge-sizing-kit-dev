#!/usr/bin/env python3
"""The module flags a guest jar's manifest asks for, as command-line flags.

    manifestFlags.py [--java <java>] [--by-jar] <jar>...

A jar's manifest may carry `Add-Exports` and `Add-Opens`: whitespace-separated
`module/package` entries, wrapped over continuation lines. The JDK launcher
applies them for `java -jar <that jar>` -- exporting or opening each package to
the unnamed module -- and ignores them entirely for a classpath launch, which is
how Swing Bridge starts a guest (main class from a directory of jars). So the
same grants have to be repeated on the server's command line, and this script
writes them: `--add-exports=<module>/<package>=ALL-UNNAMED` and
`--add-opens=...` -- per jar its exports then its opens, each in manifest order, as
the launcher processes them -- on one line, deduplicated across jars.

Entries naming a module this JDK does not have, or a package that module does
not contain, are dropped and named on stderr. That is what the launcher does with
them too (`LauncherHelper.addExportsOrOpens`: `ModuleLayer.boot().findModule(mn)
.filter(m -> m.getDescriptor().packages().contains(pn))`; verified on 21.0.12 with
a manifest naming jdk.deploy and com.apple.eawt: no warning, no effect), whereas
the same names on the command line make the JVM print a WARNING at every start.
Which JDK decides is the `--java` given, or JAVA_HOME's, or the first on PATH --
the one captureServerArgv.sh launches the server with.

`--by-jar` prints `<jar basename>\\t<flag>` per line instead, for a report of
which jar asked for what.

Exit 0 with the flags on stdout (an empty line when none). Exit 1, naming the
file, for a jar that cannot be read as a zip: a jar the server cannot open is not
a guest, and must not read as a capacity of zero.
"""
import os
import re
import subprocess
import sys
import zipfile


def die(msg):
    print(f"manifestFlags: {msg}", file=sys.stderr)
    sys.exit(1)


def find_java(explicit):
    if explicit:
        return explicit
    home = os.environ.get("JAVA_HOME")
    if home:
        return os.path.join(home, "bin", "java")
    return "java"


class Jdk:
    """Module and package membership, asked of the JDK itself, cached per module."""

    def __init__(self, java):
        self.java = java
        self._modules = None
        self._packages = {}

    def _run(self, *args):
        try:
            out = subprocess.run([self.java, *args], capture_output=True, text=True, check=False)
        except OSError as e:
            die(f"cannot run {self.java}: {e}")
        return out.stdout if out.returncode == 0 else ""

    def modules(self):
        if self._modules is None:
            self._modules = {line.split("@", 1)[0].strip() for line in self._run("--list-modules").splitlines() if line.strip()}
        return self._modules

    def packages(self, module):
        if module not in self._packages:
            pk = set()
            for line in self._run("--describe-module", module).splitlines():
                w = line.split()
                if len(w) >= 2 and w[0] in ("exports", "contains"):
                    pk.add(w[1])
                elif len(w) >= 3 and w[0] == "qualified" and w[1] == "exports":
                    pk.add(w[2])
            self._packages[module] = pk
        return self._packages[module]

    def has(self, module, package):
        return module in self.modules() and package in self.packages(module)


def main_attributes(jar):
    """The manifest's main section as {lowercase name: value}; {} when there is none."""
    try:
        zf = zipfile.ZipFile(jar)
    except (zipfile.BadZipFile, OSError) as e:
        die(f"{jar}: not a readable jar ({e})")
    with zf:
        names = [n for n in zf.namelist() if n.lower() == "meta-inf/manifest.mf"]
        if not names:
            return {}
        text = zf.read(names[0]).decode("utf-8", errors="replace")
    lines = re.split(r"\r\n|\r|\n", text)
    main = []
    for line in lines:
        if line == "":
            break                      # the main section ends at the first empty line
        if line.startswith(" ") and main:
            main[-1] += line[1:]       # a continuation line: one leading space, then the rest
        else:
            main.append(line)
    attrs = {}
    for line in main:
        if ":" in line:
            name, value = line.split(":", 1)
            attrs[name.strip().lower()] = value.strip()
    return attrs


def main(argv):
    java = None
    by_jar = False
    jars = []
    it = iter(argv)
    for a in it:
        if a == "--java":
            java = next(it, None) or die("--java needs a path")
        elif a == "--by-jar":
            by_jar = True
        elif a.startswith("-"):
            die(f"unknown option {a}")
        else:
            jars.append(a)
    if not jars:
        print(__doc__, file=sys.stderr)
        return 2
    jdk = Jdk(find_java(java))
    seen = []
    rows = []
    for jar in jars:
        attrs = main_attributes(jar)
        for attr, flag in (("add-exports", "--add-exports"), ("add-opens", "--add-opens")):
            for token in attrs.get(attr, "").split():
                parts = token.split("/")
                if len(parts) != 2 or not parts[0] or not parts[1]:
                    print(f"skipped {os.path.basename(jar)}: {attr} entry '{token}' is not module/package", file=sys.stderr)
                    continue
                module, package = parts
                if module not in jdk.modules():
                    print(f"skipped {os.path.basename(jar)}: {module}/{package} -- no module {module} in this JDK", file=sys.stderr)
                    continue
                if package not in jdk.packages(module):
                    print(f"skipped {os.path.basename(jar)}: {module}/{package} -- {module} has no package {package}", file=sys.stderr)
                    continue
                f = f"{flag}={module}/{package}=ALL-UNNAMED"
                if f not in seen:
                    seen.append(f)
                    rows.append((os.path.basename(jar), f))
    if by_jar:
        for jar, f in rows:
            print(f"{jar}\t{f}")
    else:
        print(" ".join(seen))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
