# Guest patch ledger

Every change to the hosted application, classified when written, so migration
effort is reported rather than absorbed. Method note:
https://claude.ai/code/artifact/406de2c6-620c-433b-af1f-02da87c18015

| Class | Meaning | How it counts |
|---|---|---|
| **A** | web-inevitable — any desktop→web move needs it, whatever the host | free |
| **B** | shared-JVM-only — needed because tenants share one process | **a real cost of choosing the bridge**, reported as migration effort |
| **C** | test support — instrumentation the measurement needs | free |
| **D** | anything else | excluded from the experiment |

**The rule that outranks the rest:** never patch the guest to hide a defect in
our own product. Applied once already — JOSM's icons failed to rasterise under
the bridge, and the cause was `SwingBridgeToolkit.getScreenResolution()`
returning 0, so it was fixed in the product. Patching JOSM's image loader would
have unblocked the benchmark while leaving every guest that asks the toolkit
about DPI broken.

**Host side.** `JosmApp` loads the patched artefact, sets `josm.widgetbounds` and
`josm.unattended` once for every tenant, and gives each tenant
`josm.home.<sessionId>` — no global mutation, no lock, no ordering between
launches.

## Guest: JOSM

Source: `/home/eftun/dev/git/josm` — fork `eftunv/josm` of `JOSM/josm`, branch
`web-multitenancy`, based on tag **19555-tested**, which is the exact revision the
reference jar was built from (`REVISION` says `19555`, built 2026-03-29). Keeping
the base identical to the measured jar means a memory difference cannot be a
version difference.

| # | Patch | Class | Files | Status |
|---|---|---|---|---|
| 1 | **Widget-bounds reporter** (also publishes the map scale and a timestamp, which is what let the driver tell its own tenant's readings from another's, and a fresh reading from a stale one). Publishes where widgets and map objects are, as one line on stdout, so a test driver aims by name instead of by hard-coded pixel coordinates | **C** | `tools/WidgetBounds.java` (new), `gui/MainApplication.java` (one call, one import) | done, verified natively |
| 2 | **Skippable start-up failure dialog** (`-Djosm.unattended`) | **C** | `gui/MainApplication.java` | done, verified |
| 3 | **Per-instance directories** — `josm.home.<thread-group>` preferred over `josm.home` | **B** | `data/preferences/JosmBaseDirectories.java` | done, verified with two concurrent tenants |

### 1 — Widget-bounds reporter (class C)

**Why it is test support.** A browser gives a driver nothing but pixels, so
targets would have to be coordinates, which is brittle and — worse — fails
*silently*: a driver aiming at the wrong place is indistinguishable from an
application that did nothing. This project has already retracted a published
number for exactly that reason. The hook lives in the *application*, so the driver
reads what the application itself reports. The alternative — a hook inside the
bridge — would have been an instrument that knows things a real browser cannot.

**Why stdout.** The bridge captures a guest's stdout and tags it per tenant, so
one line per update reaches the server log with the tenant's id in front of it.
A file would need a per-tenant path and a reader for it.

**Off by default.** Without `-Djosm.widgetbounds` nothing is installed, no thread
starts, and no output is produced.

Verified natively at 1280x900: reports the window size, the map view and the four
toggle dialogs, and 60 on-screen map objects as clickable points. It also caught a
defect in our own scenario — the generated extract gives every row a building
numbered 9, so the old hand-written target name was ambiguous; the hook qualifies
names with the object's unique id (`building/9/5054`).

### 2 — Skippable start-up failure dialog (class C)

JOSM counts start-up failures and, above three, asks modally whether to reset
itself. No unattended host can answer that, so start-up blocks for ever — observed
exactly that way: an unrelated launch problem pushed the counter past three, and
every later start then parked in `JOptionPane.showOptionDialog`. With
`-Djosm.unattended` the dialog is skipped, the counter cleared and a warning
logged.

`GraphicsEnvironment.isHeadless()` is **not** the right guard, which is worth
recording because it looks like the obvious one: the bridge renders a real UI
with `java.awt.headless=false`, so JOSM's existing headless checks do not cover
it. What is missing is an interactive *user*, not a display.

Class C rather than A: with per-instance directories in place production does not
need this. It is needed to run *unattended*, which is a property of the test, not
of the web.
The missing `isHeadless` guard on this one dialog is still arguably an upstream bug
worth offering back, but that is a contribution, not a line in this ledger.

Verified: counter seeded to 9, JOSM starts normally and clears it.

### 3 — Per-instance directories (class B)

JOSM assumes it owns the process: one instance, one set of directories, named by
one system property. Tenants sharing a JVM would therefore share one preferences,
cache and autosave directory — one user's state leaking into another's, and a
cache warmed by one subsidising the next.

Each directory property may now also be given per instance, keyed by the thread
group the instance runs in: `josm.home.<group>` wins over `josm.home`, and
likewise for `josm.pref`, `josm.userdata`, `josm.cache`. This bridge already names
each tenant's thread group after its session, so it fits with no shared mutable
state — **and no serialised launches**, which the previous host-side workaround
required.

Two approaches that look reasonable and do **not** work, recorded so nobody
repeats them:

| Attempt | Result |
|---|---|
| `-Djosm.home` as a *program* argument | rejected: `JOSM: unrecognized option '-Djosm.home'` |
| A `Properties` subclass answering `josm.home` per calling thread | never consulted — the guest recreated its XDG directories while the interceptor logged zero queries for all four keys. `JosmBaseDirectories` does a plain `System.getProperty`, so why it was bypassed is still unexplained |

**This is class B: a cost of the shared JVM.** One process per user would need
none of it — separate processes have separate directories by construction.
Counted, not absorbed.

Verified twice: natively, with only `josm.home.<group>` set and no plain
`josm.home`, JOSM wrote its preferences, autosave and cache there and created no
XDG directories; and in the bridge with **two tenants launched concurrently**, each
got its own directory containing JOSM-written `cache/` and
`preferences.xml_backup`, with no XDG leak and no launch lock.

## Artefact

Built by `buildPatchedJar.py`, which compiles only the named sources against the
released fat jar (offline, no ant or ivy) and reports precisely which jar entries
differ. Every run loads this same file.

| | |
|---|---|
| reference | `/home/eftun/dev/josm/josm-tested.jar` · sha256 `3afa6435ea696da4a76416d1907aa821511584ac61b89613143666d67e6b7a29` |
| patched | `/home/eftun/dev/josm/josm-web-patched.jar` · sha256 `6df567638a9acd9534547bac82cfde1e5ed4c22547a68ed9ed722fd5e7993787` (all three patches, hook reporting scale) — **round 2**; round 1 recorded `09e1b01c…` for the same source, see below |
| difference | 1 entry added (`WidgetBounds.class`), 12 changed (`MainApplication` and `JosmBaseDirectories` with their inner classes, plus `MANIFEST.MF`), 2 removed (`META-INF/JOSMTEAM.SF`, `.RSA`) |

**The sha256 is not a stable identity, and was already stale.** The hash above was
re-measured on 2026-08-31 and does not match the `09e1b01c…` this table recorded on
2026-08-14 — same source, same patches, same day. Jar entries carry timestamps, so
`buildPatchedJar.py` does not produce a byte-identical artefact from identical input, and
nothing here normalises them. Two consequences: **carry the jar file itself between machines
rather than rebuilding it** (a rebuild makes the guest binary an uncontrolled variable), and
treat the hash as a record of *which file a run used*, recorded in that run's provenance, not
as proof that two files are the same patch set. The `difference` row — which entries changed
against the signed reference — is the durable identity; `buildPatchedJar.py` reports it on
every build.

Two things the build has to do, both discovered the hard way:

- **The released jar is signed.** `META-INF/JOSMTEAM.SF` / `.RSA` plus a per-entry
  SHA-256 digest for 7,219 entries. Replacing a class without dropping those makes
  the JVM refuse to load it: `SecurityException: SHA-256 digest error`.
- **Compile with `-implicit:none` and no `-sourcepath`.** Otherwise javac prefers
  sources over the jar and recompiles most of JOSM — measured, 3,532 class files
  instead of 10 — replacing thousands of officially built classes with locally
  built ones. The builder refuses to continue above 200 classes for that reason.

Also worth recording, because it explains a start-up failure that looked like a
bridge bug: the jar's manifest declares `Add-Exports` and `Add-Opens` covering
`java.base/sun.security.util`, `java.desktop/com.sun.imageio.spi` and
`java.desktop/com.sun.imageio.plugins.jpeg`. The JVM honours those for
`java -jar`, and **ignores them for `-cp` plus a main class** — which is how the
bridge launches a guest. That is why those flags must be repeated on the server's
command line, and why omitting them made JOSM call `System.exit` during start-up
and take the shared server down with it.
