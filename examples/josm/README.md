# The JOSM example on the kit

JOSM -- the Java OpenStreetMap editor, a production-sized third-party Swing application --
is the worked example the kit was built with. Everything about it lives in this directory:
the scenario (`josm-cycle.json`), the synthetic map extract (`grid-helsinki.osm`, made by
`makeExtract.py`), the patch tooling and ledger (`buildPatchedJar.py`, `PATCH-LEDGER.md`),
the view that goes into the starter clone (`JosmSizingView.java`), and these steps. Nothing
of JOSM is wired into the kit's own scripts.

1. **Build the bounds-publishing JOSM** with `./buildPatchedJar.py` here, from the released
   jar and the three patched sources it names (see `PATCH-LEDGER.md`). Carry
   the resulting jar between machines; do not rebuild it per box -- jar entries carry
   timestamps, so a rebuild changes the checksum without changing the patch.
2. **The first run of `./runBoxA.sh`** on Box A: answer JOSM's main class,
   `org.openstreetmap.josm.gui.MainApplication`, and no arguments -- the view below carries
   JOSM's own, but the answer lets every later run check the class is in the jar. It fetches
   the starter project into `system-under-test/`.
3. **In that clone:** put the JOSM jar -- and nothing else -- into `applibs/`; copy
   `JosmSizingView.java` into `src/main/java/com/example/swingbridge/ui/`, beside the kit's
   `SizingView.java`.
4. **In Box A's `harness/harness.env`,** below the block `runBoxA.sh` keeps at the top, change
   the view and the scenario and add the JOSM lines (`$REPO_ROOT` is the kit directory,
   set before this file is read, so these expand to absolute paths):
   ```
   VIEW=josm
   SCENARIO="$REPO_ROOT/examples/josm/josm-cycle.json"
   SCENARIO_DATA="$REPO_ROOT/examples/josm/grid-helsinki.osm"
   SIZING_EXTRA_JVM="--add-exports=java.base/sun.security.action=ALL-UNNAMED --add-exports=java.desktop/com.sun.imageio.plugins.jpeg=ALL-UNNAMED --add-exports=java.desktop/com.sun.imageio.spi=ALL-UNNAMED -Djosm.data=$REPO_ROOT/examples/josm/grid-helsinki.osm -Djosm.homeBase=/scratch/josm-sizing-tenants"
   ```
   Two different things are at work, and the kit covers one of them for you. JOSM's jar
   manifest declares five `Add-Exports` and nine `Add-Opens`; every run derives those as
   flags (eleven on a JDK without JavaFX -- `com.apple.eawt`, `javafx.graphics` and
   `jdk.deploy` are dropped exactly as the launcher drops them, and named). Separately, JOSM
   checks at start-up (`PlatformHook.startupSanityChecks`) that the three literal
   `--add-exports` strings above are among the JVM's arguments -- a different list from its
   own manifest -- and, missing any, shows a Stop/Continue dialog whose Stop exits the JVM,
   taking the shared server with it. So those three go in `SIZING_EXTRA_JVM`, verbatim.
   `VIEW` travels to Box B with the kit; nothing is set there by hand.

Then `./runBoxA.sh` again, `./runSizing.sh`, `./runReport.sh` as for any application.

The reference run of this example on this kit has not been made yet. Round 2 measured the
same application on its own rig (dev-mode server, Flow 25.2.1); the kit's number is a new
measurement -- production jar, Flow 25.2.2, no Maven on the load box -- and is reported as such.
