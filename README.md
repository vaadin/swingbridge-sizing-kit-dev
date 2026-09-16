# Swing Bridge Sizing Kit

**New here? Start with [GETTING-STARTED.md](GETTING-STARTED.md)** — nine steps from two
empty machines to a number, in order, with the commands. [SCENARIO.md](SCENARIO.md) explains
the one file you write; [SETUP.md](SETUP.md) is the reference for what each machine needs.
This page is the overview.

Measures **how many concurrent, active users of *your* Swing application fit in a fixed
RAM budget on Swing Bridge 1.3.0 — and what ran out first.**

You clone `skeleton-starter-vaadin-swing-bridge`, drop your application's jar into its
`applibs/`, and the kit configures that clone for a sizing run, runs it inside a
kernel-enforced memory budget while real browsers drive real users through a scenario you
declare, sweeps the JVM heap for the setting that serves the most users, repeats at that
setting, and writes one report:

> **N concurrent active users fit in a B GB budget** with this application on Swing Bridge
> 1.3.0, at `-Xmx…`. That is the median of 3 publishable repeats: … **What ran out first:**
> the budget: memory reached 100 % of … MB when the set degraded.

*Active* means every user works through the scenario the whole time and every step is
asserted against what appeared on screen. *Fit* means the whole set still met a quality
bar calibrated against this run's own first user. Nothing is idle, nothing is assumed.

The kit contains no Swing Bridge source; the product arrives as a Maven dependency of your
clone, exactly as in the skeleton starter. It changes nothing about the product.

## What you need

Two Linux machines and a wired link between them. Details and checks in [SETUP.md](SETUP.md).

| | Box A — the server under test | Box B — the load generator |
|---|---|---|
| runs | your skeleton-starter clone, packaged | one Chromium per simulated user |
| needs | systemd with cgroup v2 and the memory controller delegated to your user; JDK 21 (not a JRE); Maven; Python 3; git; rsync; a Vaadin licence for the production build, as for any Vaadin project with commercial components. `runBoxA.sh` checks for each and names the package of anything missing; it installs nothing | JDK 21; Maven (the kit builds its driver there, from source); Chromium's system libraries; rsync; ≥ 8 GB of `/dev/shm` for browser temp, or disk and patience. **No git, no credentials** — Box A puts the kit there |
| reaches | Box B over ssh, passwordless | Box A on ports 8088 and 8099 |

Bare metal is preferred; a VM is warned about and the report says so. The server box needs
**no X display** — Swing Bridge renders without one.

## What your application must do

1. **Publish where its widgets are.** Once running, print one line per update to stdout:
   `WIDGET-BOUNDS {"t":<ms>,"window":[w,h],"widgets":{"name":[x,y,w,h],…},"targets":{"name":[x,y],…}}`
   — `t` a millisecond stamp, `window` the guest window's size, `widgets` the rectangles
   your scenario aims at and watches, `targets` optional named points. The driver resolves
   every click and every assertion from this, so nothing is a hard-coded pixel. A `scale`
   field is needed only if a scenario step declares `expectScale`. The JOSM example shows a
   small patch that does this (`examples/josm/PATCH-LEDGER.md`, `examples/josm/buildPatchedJar.py`).
2. **Start from a main class.** The kit's view at `/sizing` (`view/SizingView.java`, installed
   into the clone by the first run) does what the skeleton's own view does — `new
   SwingBridge(mainClass, args)` — with the class and arguments you give that first run;
   arguments are split on whitespace. Anything more — a property per tenant, a seeded home
   directory, an argument with spaces — is a view of your own: copy the kit's under another
   `@Route`, set `VIEW` to it. `examples/josm/` does exactly that.
3. **Nothing about its manifest.** If your jar's manifest declares `Add-Exports` /
   `Add-Opens`, every run reads them and repeats them on the server's command line — the
   JVM honours them for `java -jar` only, and the bridge starts your application by main
   class. Entries this JDK cannot honour are dropped and named, exactly as the launcher
   drops them. Anything your application needs *beyond* its manifest goes in
   `SIZING_EXTRA_JVM`; a `GUEST_MANIFEST_FLAGS` you set replaces the derived list.
4. **Show the first window within 5 seconds** of `main()` returning. Swing Bridge 1.3.0
   renders an error view after that, and the run records the tenant as unable to start.
   The report names this cause when it sees it.
5. **Pin the window geometry** and put the same size in the scenario's `window` block. The
   browser viewport is 2240x1200; a guest window larger than about 1920x1080 is clipped.
6. Know that tenants share one JVM: state keyed off a JVM-global system property is shared
   unless your application keys it per instance (JOSM's patch 3 is the example).

Then write a scenario — `points`, `crops`, a `cycle` of steps that each declare what must
change on screen — as [SCENARIO.md](SCENARIO.md) describes, starting from
`examples/josm/josm-cycle.json`. `runBoxA.sh` can validate it against one bounds line
your application printed, in seconds, with no browser.

## Run it

On Box A, in the kit directory, with `ssh boxb` already answering without a password
([SETUP.md](SETUP.md), *ssh from A to B*):

```
./runBoxA.sh                 # first run: checks the toolchain (names any missing package, installs
                             #   nothing), asks five questions -- where the starter project goes, your
                             #   main class and its arguments, Box B's ssh name, the budget -- proves
                             #   the budget is enforceable, writes harness/harness.env, fetches
                             #   skeleton-starter at the pinned revision with the kit's view in it, and
                             #   stops: put your jar in <clone>/applibs/, write your scenario
./runBoxA.sh                 # every later run: check your main class is in your jar, package the clone,
                             #   compose the launch, prove the budget, validate the scenario, then ship
                             #   the kit to Box B over ssh and run its setup there
./runSizing.sh               # one cell per heap, 60 / 70 / 80 % of the budget by default, each ramped
                             #   until the set breaks  (~1.3 h for a ~40-user app)
./runReport.sh               # the table, in harness/reports/<stamp>-report.md -- read it, choose a heap
SB_CAPS=2456m SIZING_REPEATS=3 ./runSizing.sh   # then: three runs at the heap you chose -> a published count
```

The five answers can also be given as environment variables (`SIZING_CLONE_DIR`,
`SIZING_MAIN_CLASS`, `SIZING_ARGS`, `BOXB`, `BUDGET`) or piped in one per line; everything
else lives in `harness/harness.env`, plain text, documented line by line in
`harness/harness.env.example`.

**Box A is the only box you touch.** It ships the kit to Box B by rsync over the ssh alias it needs anyway, runs Box B's setup there, and later drives every ramp from there — the pattern the harness already uses. Box B holds no git checkout and no credentials, and the two boxes cannot run different revisions.
Every script refuses, by name, on anything that would otherwise produce a plausible wrong
number — a jar the server cannot read, a budget the kernel is not enforcing, a scenario that
does not resolve, a load box that cannot be reached.

## Reading the report

- **Publishable** is a mechanical bar: no kernel kill of the server, no `OutOfMemoryError`
  in its log, no user counted after the last live reading of the budget, and the ramp itself
  completed. Cells that fail it are shown, never counted. The kill verdict is read from the
  systemd journal, not from the cgroup's counter, because the counter dies with the scope
  and never records the kill that ends a cell.
- **One run per heap is a picture, not a count.** Spread at one heap is as wide as the gap
  between neighbouring heaps, so the first pass shows the shape — where the heap starves,
  where the wall is hit, where the count peaks — and *heap at the ceiling* says which way to
  move. The report decides nothing: pick a heap from its table and run three cells there;
  the median of the publishable ones is the headline.
- **The heap range** is yours: `SIZING_HEAP_START / STOP / STEP` as percentages of the budget
  or as heaps (`2g`, `2560m`), or `SB_CAPS` for an explicit list. More than 12 cells needs
  `SIZING_MAX_CELLS` raised; a cell is ~27 min for a ~40-user application.
- **What ran out first** is decided from evidence in a fixed order: a killed server, a Java
  OOM, the 5-second first-window limit, a guest-contract failure the driver named, a
  saturated load box, memory at the wall, and otherwise the quality bar — response time or
  staleness gave out before memory did.
- **If the load box was the limit, the number is a floor, not a ceiling.** The report says
  so, judging the load box's `load1` over the end of the ramp against its core count — not
  its peak, which every browser launch spikes.

## The example: JOSM

`examples/josm/` carries the worked example the kit was built with, all of it — nothing of
JOSM is wired into the kit's own scripts: `josm-cycle.json` (seven steps — select, select,
deselect, zoom in, zoom out, layer off, layer on — each asserted), `grid-helsinki.osm` (a
synthetic, deterministic extract from `makeExtract.py`), `buildPatchedJar.py` (builds the
bounds-publishing JOSM from its released jar), `PATCH-LEDGER.md` (every change to the guest,
classified), the view, and a README with the steps. JOSM's manifest declares five
exports and nine opens, which the kit derives; JOSM also checks for three literal
`--add-exports` strings itself at start-up and stops without them, so those three go in
`SIZING_EXTRA_JVM` — the example's README has the lines.

The view for your clone -- JOSM's arguments, its test-support properties, a home per
tenant -- is `examples/josm/JosmSizingView.java`; `examples/josm/README.md` walks through
the four steps. The reference run of this example on this kit has not been made yet.

## Time

A cell that reaches about 40 users takes ~27 minutes including turnaround: about 0.6 min
per tenant added, so it scales with the count your application reaches, not with the
budget. Three heaps, one run each, is ~1.3 h; three runs at one heap another ~1.3 h. From
the rig the kit was developed on.

## A note on the network

`harness/scenario/harnessServer.py` serves the guest's bounds lines and memory samples to
Box B on `0.0.0.0:8099`, unauthenticated, and runs a sampler per request. It is a measurement
rig for one LAN. Do not run it anywhere else.

## Layout and tests

```
GETTING-STARTED.md  SCENARIO.md  SETUP.md          start here; the file you write; what each box needs
runBoxA.sh  runBoxB.sh  runSizing.sh  runReport.sh    the four entry points
harness/        the measurement harness -- unchanged scripts where possible, each edit
                `${NEW_VAR:-<original>}`; harness.env.example; jvm-flags.conf
harness/scenario/   the monitors and the report renderer; your scenario goes here by default
examples/josm/  the worked example, all of it: scenario, extract, patch tooling and ledger, view, README
view/           SizingView.java, the page the first run installs into the clone
system-under-test/  where that first run puts the skeleton-starter clone by default (gitignored)
driver/         the browser driver, built from source on Box B
testdata/       six real cells the report generator is tested against
```

```
harness/testProbes.sh  harness/testCaptureServerArgv.sh  harness/testManifestFlags.sh  harness/testRunScenarioRemote.sh
./testRunBoxA.sh  ./testRunSizing.sh  ./testRunReport.sh
( cd driver && mvn test )
```

All hermetic: no server, no load box, no network.

## What it does not measure

Bandwidth and latency to the browser; CPU headroom as a first-class result (the report shows
CPU peaks; a CPU-bound answer is a later harness); anything about any other product. One measurement, stated plainly, with its evidence attached.
