# Setting up the two boxes

What each machine needs before a number from it means anything, and how the kit checks it.
`runBoxA.sh` and `runBoxB.sh` run every check below that can be automated; this page is for
understanding what they ask and fixing what they find.

## Box A — the server under test

**Linux with systemd and cgroup v2.** The budget is a systemd user scope with
`MemoryMax=<budget>`, `MemorySwapMax=0` and `OOMPolicy=continue`; the kill verdict is read
from the user journal. Check: `stat -fc %T /sys/fs/cgroup` prints `cgroup2fs`.

**The memory controller delegated to your user.** Without it the scope silently fails to
cap and every count would be fiction. Check:
`ls /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/memory.max`.
Most current distributions delegate `memory` to user sessions already. If the file is
missing, add a drop-in for `user@.service` with

```
[Service]
Delegate=cpu memory pids
```

then `systemctl daemon-reload` and log in again. `runBoxA.sh` proves the result the hard
way: it starts a scope of your configured budget and requires `memory.max` inside it to
equal the budget in bytes.

**Swap** can stay on: `MemorySwapMax=0` applies per scope. **Bare metal** is preferred;
`systemd-detect-virt` other than `none` produces a warning and the report says so.

**Packages:** `openjdk-21-jdk` (a JDK — the sampler uses `jcmd`, process discovery uses
`jps`, and `jar` checks your main class is in your jar), `maven`, `python3`, `git`, `rsync`,
`curl`, `openssh-client`, `iproute2` (`ss`, `ip`). `runBoxA.sh` checks for every one of
these on every run and names the package of anything missing; it installs nothing. No X
server: Swing Bridge renders without a display.

**Ports:** 8088 (the server) and 8099 (the bounds-and-samples service) must be reachable
from Box B. Verify from Box B with `curl`, not by assumption.

**Licence.** Your clone depends on `com.vaadin:vaadin`; its production build validates your
Vaadin licence as any Vaadin project with commercial components does. The kit runs the
packaged jar in production mode, where Swing Bridge performs no per-user licence check at
run time.

### The skeleton-starter clone

The first run of `runBoxA.sh` makes it: `git clone` of
`vaadin/skeleton-starter-vaadin-swing-bridge` at the revision the kit was exercised against
(`53d7028`), into `system-under-test/` under the kit unless you answer another path, with the skeleton's
sample jar and sample view removed and the kit's view, `view/SizingView.java`, installed at
`src/main/java/com/example/swingbridge/ui/SizingView.java`. Name a directory that already
holds a `pom.xml` and it is used as it is: nothing removed, the view added beside what is
there. Then:

- your application's jar(s) in `applibs/` — and nothing else, every jar there is on your
  application's classpath;
- your main class and arguments answered at the first run (`SIZING_MAIN_CLASS`,
  `SIZING_ARGS` in `harness.env`); every later run checks the class is in one of those jars;
- your jar's manifest `Add-Exports` / `Add-Opens` are read and repeated on the command line
  by every run (`harness/manifestFlags.py`, applying the launcher's own rule: entries naming
  a module or package this JDK lacks are dropped, and named); set `GUEST_MANIFEST_FLAGS` only
  to replace that list, and put anything your application needs beyond its manifest in
  `SIZING_EXTRA_JVM`;
- nothing else edited. The kit never modifies the clone's pom: in production the pom's
  `<jvmArguments>` do not apply, so the kit composes the launch itself from
  `harness/jvm-flags.conf` and warns if your pom's flag list has drifted from it.

`runBoxA.sh` packages the clone (`mvn clean package`, slow the first time — the frontend
toolchain downloads), resolves the jar name and the Swing Bridge version through Maven,
and composes `java <flags> -jar <jar>`. The flags include `-Dswingbridge.consoleLogPrefix=true`,
which stamps every guest output line with `[swing:<id>]` — the kit needs those ids to tell
users apart, and the product ships with it off.

## Box B — the load generator

**Packages:** `openjdk-21-jdk`, `maven` (the driver is built here, from source, once), `curl`,
`rsync`. No git: Box A ships the kit here and runs `runBoxB.sh` over ssh. Chromium's system libraries: after `runBoxB.sh` has built the driver, if Chromium
fails to launch, run once with privileges
`java -cp "driver/target/classes:driver/target/dependency/*" com.microsoft.playwright.CLI install-deps chromium`.

**One directory.** Everything the kit uses on Box B lives under one root: the kit checkout,
a `supplemental/` scratch area for the Maven repository, temp files and browsers. Nothing
is written to `~/.m2` or `~/.cache`. The root defaults to the directory the checkout sits
in; Box A must be told the same root (`BOXB_ROOT`) and checkout (`BOXB_CHECKOUT`).

**Browser temp.** Each Chromium holds ~540 MB of unlinked-but-open temp files: `df` sees
them, `du` does not, and running out stops the ramp with no error, which reads as a
ceiling. With ≥ 8 GB free in `/dev/shm` the kit uses it; otherwise it falls back to disk
under the scratch area and tells you. Watch `df`.

**Architecture.** Browsers are fetched for this box's own architecture at
`runBoxB.sh` time. Do not copy a browser cache from a machine of another architecture.

**Cores.** Round 2's generator was CPU-bound at 39 users on 14 cores. The report judges the
load box by its `load1` over the end of the ramp against its core count and, if the load
box was the limit, calls the count a floor.

## ssh from A to B

An alias in Box A's `~/.ssh/config`, passwordless, with keepalive — a run takes tens of
minutes and the connection is polled, not held:

```
Host boxb
    HostName <address>
    User <user>
    IdentityFile ~/.ssh/<key>
    ServerAliveInterval 30
    ServerAliveCountMax 6
```

The ramp itself is started detached on Box B and only tailed from A, so a dropped
connection costs visibility, not the run. Box B must reach Box A on 8088 and 8099.

## harness.env

Box A's `harness/harness.env` is written by the first run of `runBoxA.sh` from its five
answers — `SIZING_CLONE_DIR`, `SIZING_MAIN_CLASS`, `SIZING_ARGS`, `BOXB`, `BUDGET` — plus
`VIEW=sizing`, the path your scenario must appear at (`SCENARIO`), and commented lines for
`GUEST_MANIFEST_FLAGS` and `SIZING_EXTRA_JVM`. Plain text; `harness.env.example` documents
every setting the kit knows. Every later run writes what it derives — the jar's name for
process discovery, the clone as working directory, the load box's core count and root —
into a managed block at the top; your lines below it win. To answer the questions again,
move the file away and run `./runBoxA.sh` (or `--init`).

Box B's `harness/harness.env` is written by `runBoxB.sh` when Box A runs it there: `VIEW`
(from A's file) and how to launch the driver it built. Nothing is set on Box B by hand.

## What the preflight proves

Every run of `runBoxA.sh` starts with the toolchain: each tool above present, `java` at 21
or later, and a JDK rather than a JRE. The first run then proves the budget is enforceable
before writing anything. Every later run, in order: the clone (jar in `applibs`, your main
class found in one of those jars by `jar tf`, the jars' manifest module flags derived, the
scenario file present, pom flags against the kit's list); the build; the composed launch command, every jar it names present; the derived settings;
`checkEnv.sh` (address detection, cgroup v2, delegation, virtualisation, the scenario,
Box B reachable, browser temp headroom); the budget-cap proof; the scenario validated
against one bounds line if `SIZING_BOUNDS_SAMPLE` names a file holding one; then the kit
shipped to Box B (`rsync --delete`, protecting Box B's own `harness.env`, reports and builds)
and `runBoxB.sh` run there with its output streamed back. `SIZING_SKIP_SHIP=1` leaves Box B
as it is. To produce that
file, run your application once so it prints a `WIDGET-BOUNDS` line and save the output.

## Things that have already cost readings

- **A setting on the driver is not a setting on the script.** The driver echoes every
  property it resolved as `set` or `default` at the top of each run. Read that, not the
  script that launched it.
- **"Tenant N could not start" is the last symptom, not the cause.** Read the DEGRADED
  health lines before it, the report's cause, and the load box, in that order.
- **Never run a long job inside an ssh session.** The kit starts the ramp detached.
- **A tenant is ready only when it has published every target the scenario names.** Under
  load a guest publishes its layout before it has finished drawing; the driver waits.
- **`df`, not `du`**, for browser temp.
- **The first window within 5 seconds**, or Swing Bridge shows an error view and the tenant
  never produces a canvas. The report names it when it sees it.
