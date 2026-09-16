/**
 * Copyright (C) 2026 Vaadin Ltd
 *
 * This program is available under Vaadin Commercial License and Service Terms.
 *
 * See <https://vaadin.com/commercial-license-and-service-terms> for the full
 * license.
 */
package com.vaadin.swingbridge.load;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.microsoft.playwright.Browser;
import com.microsoft.playwright.BrowserContext;
import com.microsoft.playwright.BrowserType.LaunchOptions;
import com.microsoft.playwright.Locator;
import com.microsoft.playwright.Locator.WaitForOptions;
import com.microsoft.playwright.Page;
import com.microsoft.playwright.Playwright;
import com.microsoft.playwright.options.BoundingBox;
import com.microsoft.playwright.options.WaitForSelectorState;

/**
 * Runs the user-behaviour scenario against a Swing Bridge server through real
 * browsers, one per simulated user.
 *
 * <p>
 * Three properties make this an instrument rather than a convenience:
 * </p>
 *
 * <ul>
 * <li><b>One declarative scenario file</b>, resolved at run time — not a script
 * with coordinates in it.</li>
 * <li><b>Targets come from the guest.</b> The application publishes where its
 * widgets and objects are, and every point and crop is resolved against that.
 * Nothing here knows a pixel coordinate. That matters because a driver aiming
 * at a stale coordinate still clicks — it just clicks the wrong thing, which is
 * indistinguishable from an application that did nothing, and this project has
 * already retracted a published number for exactly that reason.</li>
 * <li><b>Every step must prove itself.</b> Each declares the regions that must
 * change; the driver hashes them in the page before and after. A run that does
 * not reach 100 % verification reports itself void instead of producing an
 * average.</li>
 * </ul>
 *
 * <p>
 * Canvas geometry is verified, not assumed: the guest reports its window size,
 * the picked canvas reports its own, and the driver refuses to continue if they
 * disagree by more than a pixel of rounding, because a silent scale factor
 * would put every click somewhere plausible and wrong.
 * </p>
 *
 * <pre>
 *   -Dload.url=http://host:8088/   -Dload.view=sizing
 *   -Dscenario.file=.../app-cycle.json
 *   -Dscenario.boundsLog=.../server.log   [-Dscenario.tenant=swing:abc123]
 *   -Dscenario.cycles=2
 * </pre>
 */
public final class ScenarioDriver {

    /**
     * Installed once per page: hashes a crop of the guest canvas. Reading
     * pixels in the page is the one observation a browser offers of what the
     * user actually saw.
     */
    private static final String HASH_JS =
    // @formatter:off
        "(idx) => {"
        + "const c = document.querySelectorAll('canvas')[idx];"
        + "if (!c) { return false; }"
        + "const off = document.createElement('canvas');"
        + "const octx = off.getContext('2d', { willReadFrequently: true });"
        + "window.__scn = { canvas: c, hash(x, y, w, h) {"
        // Downscaled on the way in. At full size this read back 95.5 M pixels
        // a second across 20 tenants — 382 MB/s off the GPU plus a 24 M-entry
        // JS loop — and the load box, not the server, became the limit. The
        // browser does the scaling; we hash a thumbnail of the same region.
        + "  const s = Math.min(1, MAXDIM / Math.max(w, h));"
        + "  const dw = Math.max(1, Math.round(w * s));"
        + "  const dh = Math.max(1, Math.round(h * s));"
        + "  if (off.width !== dw || off.height !== dh) { off.width = dw; off.height = dh; }"
        + "  octx.clearRect(0, 0, dw, dh);"
        + "  octx.drawImage(c, x, y, w, h, 0, 0, dw, dh);"
        + "  const d = octx.getImageData(0, 0, dw, dh).data;"
        + "  let a = 5381;"
        + "  for (let i = 0; i < d.length; i += 4) { a = ((a << 5) + a + d[i] + d[i+1]*3 + d[i+2]*7) | 0; }"
        + "  return a;"
        + "} };"
        + "return true; }";
    // @formatter:on

    /**
     * The pixel hasher, with its thumbnail size resolved.
     *
     * <p>
     * Configurable because it trades cost against sensitivity: a smaller
     * thumbnail is cheaper on the load box but eventually stops noticing a
     * change of a few pixels. 160 keeps a 14 px drawn shape visible in a 896 px
     * crop while costing about a thirtieth of a full-resolution read.
     * </p>
     */
    private static String hashJs() {
        return HASH_JS.replace("MAXDIM", prop("scenario.hashMaxDim", "160"));
    }

    /**
     * Picks the guest window's canvas: window-shaped first, then largest area.
     * A page can hold more than one canvas — an overlay, a small widget — and
     * the guest window's is the large, window-shaped one.
     */
    private static final String CANVAS_INDEX =
    // @formatter:off
        "() => { const list = [...document.querySelectorAll('canvas')];"
        + " let best = -1, bestArea = -1, bestOk = false;"
        + " list.forEach((c, i) => { const r = c.getBoundingClientRect();"
        + "   const ok = r.width >= 200 && r.height >= 200;"
        + "   const area = r.width * r.height;"
        + "   if (ok !== bestOk ? ok : area > bestArea) {"
        + "     bestOk = ok; bestArea = area; best = i; } });"
        + " return best; }";
    // @formatter:on

    private static final String WAIT_FOR_VAADIN =
    // @formatter:off
        "() => {"
        + "if (window.Vaadin && window.Vaadin.Flow && window.Vaadin.Flow.clients) {"
        + "  var clients = window.Vaadin.Flow.clients;"
        + "  for (var client in clients) { if (clients[client].isActive()) { return false; } }"
        + "  return true;"
        + "} else { return true; } }";
    // @formatter:on

    private ScenarioDriver() {
    }

    public static void main(String[] args) throws Exception {
        int exit = 0;
        try {
            if (args.length > 0 && "--validate".equals(args[0])
                    || Boolean.parseBoolean(prop("scenario.validate", "false"))) {
                exit = validateFromProperties() ? 0 : 1;
            } else {
                run(args);
            }
        } finally {
            // In a finally, not a shutdown hook: exec:java runs this inside
            // Maven's JVM, where a hook fires long after the run's own output
            // has been captured, if at all.
            warnUnreadProperties();
        }
        if (exit != 0) {
            System.exit(exit);
        }
    }

    /**
     * {@code --validate}: check a scenario against one bounds line the guest
     * published, with no browser and no load on the server.
     *
     * <p>
     * A scenario is the customer's first failure point, and without this the
     * first feedback on a bad one is a ramp timing out three minutes into a
     * live cell. This resolves every point and crop with the same code the run
     * uses ({@link #resolvePoint}, {@link #resolveCrop}, {@link #readBounds}),
     * so what passes here is what a run would resolve.
     * </p>
     */
    private static boolean validateFromProperties() throws Exception {
        String scenarioFile = prop("scenario.file", null);
        String boundsLog = prop("scenario.boundsLog", null);
        if (scenarioFile == null || boundsLog == null) {
            throw new IllegalArgumentException("--validate needs"
                    + " -Dscenario.file=<scenario.json> and"
                    + " -Dscenario.boundsLog=<file or URL holding at least one"
                    + " bounds line your guest published>");
        }
        List<String> failures = validateScenario(Path.of(scenarioFile),
                boundsLog, System.out);
        System.out.printf("%nvalidation: %s%n", failures.isEmpty()
                ? "OK -- every point and crop resolves against what the guest published"
                : failures.size() + " problem(s), listed above");
        return failures.isEmpty();
    }

    /**
     * The checks behind {@code --validate}, as a list of failures (empty means
     * valid). Package-private so the test can drive it without a JVM exit.
     */
    static List<String> validateScenario(Path scenarioFile, String boundsLog,
            java.io.PrintStream out) throws Exception {
        List<String> failures = new ArrayList<>();
        java.util.function.BiConsumer<String, String> fail = (what, why) -> {
            failures.add(what + ": " + why);
            out.printf("  FAIL %-44s %s%n", what, why);
        };
        java.util.function.Consumer<String> ok = what -> out
                .printf("  ok   %s%n", what);

        JsonNode scenario;
        try {
            scenario = new ObjectMapper()
                    .readTree(Files.readString(scenarioFile));
        } catch (Exception e) {
            fail.accept("scenario " + scenarioFile,
                    "not readable as JSON: " + e.getMessage());
            return failures;
        }
        ok.accept("scenario parses: " + scenarioFile);
        String marker = scenario.path("boundsMarker").asText("WIDGET-BOUNDS ");

        JsonNode bounds;
        try {
            bounds = readBounds(boundsLog, marker, null);
        } catch (Exception e) {
            fail.accept("bounds from " + boundsLog, e.getMessage());
            return failures;
        }
        ok.accept("guest published a parseable '" + marker.trim() + "' line");
        if (!bounds.path("t").isNumber()) {
            fail.accept("bounds field 't'", "missing or not a number; the"
                    + " driver waits for lines stamped after each gesture");
        } else {
            ok.accept("bounds field 't' present");
        }
        JsonNode win = bounds.path("window");
        if (!win.isArray() || win.size() != 2 || win.path(0).asInt() <= 0
                || win.path(1).asInt() <= 0) {
            fail.accept("bounds field 'window'", "expected [width, height]"
                    + " > 0; the driver checks the canvas against it to 1 px");
        } else {
            ok.accept("bounds field 'window' = " + win.path(0).asInt() + "x"
                    + win.path(1).asInt());
        }
        if (!bounds.path("widgets").isObject()
                || bounds.path("widgets").isEmpty()) {
            fail.accept("bounds field 'widgets'",
                    "missing or empty; points and crops resolve against it");
        } else {
            ok.accept("bounds field 'widgets': "
                    + fieldNames(bounds.path("widgets")));
        }
        boolean hasScale = bounds.path("scale").isNumber();
        out.printf("  info bounds field 'scale' %s (needed only by steps"
                + " declaring expectScale)%n", hasScale ? "present" : "absent");
        if (bounds.path("targets").isObject()) {
            ok.accept("bounds field 'targets': " + bounds.path("targets").size()
                    + " named object(s)");
        }

        JsonNode points = scenario.path("points");
        JsonNode crops = scenario.path("crops");
        if (!points.isObject() || points.isEmpty()) {
            fail.accept("scenario 'points'", "missing or empty");
        }
        if (!crops.isObject() || crops.isEmpty()) {
            fail.accept("scenario 'crops'", "missing or empty");
        }
        points.fields().forEachRemaining(e -> {
            try {
                int[] p = resolvePoint(e.getKey(), e.getValue(), bounds);
                ok.accept("point '" + e.getKey() + "' -> (" + p[0] + ","
                        + p[1] + ")");
            } catch (RuntimeException ex) {
                fail.accept("point '" + e.getKey() + "'", ex.getMessage());
            }
        });
        crops.fields().forEachRemaining(e -> {
            try {
                int[] c = resolveCrop(e.getKey(), e.getValue(), bounds);
                ok.accept("crop '" + e.getKey() + "' -> " + c[2] + "x" + c[3]
                        + " at (" + c[0] + "," + c[1] + ")");
            } catch (RuntimeException ex) {
                fail.accept("crop '" + e.getKey() + "'", ex.getMessage());
            }
        });

        for (String phase : new String[] { "setup", "cycle" }) {
            JsonNode steps = scenario.path(phase);
            if ("cycle".equals(phase) && (!steps.isArray() || steps.isEmpty())) {
                fail.accept("scenario 'cycle'", "missing or empty");
                continue;
            }
            if (!steps.isArray()) {
                continue;
            }
            int n = 0;
            for (JsonNode step : steps) {
                n++;
                String id = step.path("id").asText(phase + "[" + n + "]");
                String action = step.path("action").asText("");
                if (!java.util.Set.of("click", "wheel", "key").contains(action)) {
                    fail.accept("step '" + id + "'", "action '" + action
                            + "' is not one of click, wheel, key");
                }
                if ("key".equals(action) && step.path("key").asText("").isEmpty()) {
                    fail.accept("step '" + id + "'", "action key needs 'key'");
                }
                if ("wheel".equals(action) && !step.path("notches").isNumber()) {
                    fail.accept("step '" + id + "'",
                            "action wheel needs 'notches'");
                }
                String at = step.path("at").asText("");
                if (!points.has(at)) {
                    fail.accept("step '" + id + "'", "'at' names unknown point '"
                            + at + "' (known: " + fieldNames(points) + ")");
                }
                for (JsonNode w : step.path("expect")) {
                    if (!crops.has(w.asText())) {
                        fail.accept("step '" + id + "'",
                                "'expect' names unknown crop '" + w.asText()
                                        + "' (known: " + fieldNames(crops) + ")");
                    }
                }
                if (step.has("expectScale") && !hasScale) {
                    fail.accept("step '" + id + "'", "declares expectScale but"
                            + " the guest publishes no 'scale'");
                }
            }
            if ("cycle".equals(phase)) {
                ok.accept("cycle: " + n + " step(s) checked");
            }
        }
        if (!points.has("park")) {
            out.println("  info no 'park' point: the at-rest snapshot is taken"
                    + " wherever the last step left the pointer");
        }
        return failures;
    }

    private static String fieldNames(JsonNode obj) {
        List<String> names = new ArrayList<>();
        obj.fieldNames().forEachRemaining(names::add);
        return String.join(", ", names);
    }

    private static void run(String[] args) throws Exception {
        String base = prop("load.url", "http://localhost:8088/");
        String view = prop("load.view", "josm");
        int cycles = Integer.parseInt(prop("scenario.cycles", "1"));
        long guestWaitMs = Long
                .parseLong(prop("scenario.guestWaitMs", "180000"));
        String scenarioFile = prop("scenario.file", null);
        String boundsLog = prop("scenario.boundsLog", null);
        String tenant = prop("scenario.tenant", null);
        if (scenarioFile == null || boundsLog == null) {
            throw new IllegalArgumentException(
                    "-Dscenario.file and -Dscenario.boundsLog are required");
        }
        String url = base.endsWith("/") ? base + view : base + "/" + view;

        JsonNode scenario = new ObjectMapper()
                .readTree(Files.readString(Path.of(scenarioFile)));
        String marker = scenario.path("boundsMarker").asText("WIDGET-BOUNDS ");

        System.out.printf("scenario: %s -> %s (%d cycles)%n",
                scenario.path("app").asText(), url, cycles);

        if (Boolean.parseBoolean(prop("scenario.activeRamp", "false"))) {
            // Every tenant works at once; each brings its own Playwright.
            activeRamp(url, scenario, marker, boundsLog, guestWaitMs,
                    !"false".equals(prop("scenario.headless", "true")));
            return;
        }

        try (Playwright playwright = Playwright.create()) {
            // Headed is offered because a real browser's wheel drives this
            // product while a headless one's identical event does not — the
            // event shape was compared field by field and matches.
            boolean headless = !"false"
                    .equals(prop("scenario.headless", "true"));
            Browser browser = playwright.chromium()
                    .launch(new LaunchOptions().setHeadless(headless)
                            .setArgs(browserArgs())
                            .setIgnoreDefaultArgs(ignoredDefaultArgs()));
            System.out
                    .println("browser: " + (headless ? "headless" : "headed"));
            int tenantCount = Integer.parseInt(prop("scenario.tenants", "1"));
            List<Tenant> tenants = new ArrayList<>();
            int attempted = 0;
            int verified = 0;

            // Ramp first, one tenant at a time, sampling after each. Marginal
            // cost is what a capacity plan needs and it can only be read from a
            // series: the FIRST tenant pays for one-time heap expansion that
            // every later one reuses, which is exactly how a difference taken
            // at one tenant came to overstate the per-user cost threefold.
            for (int i = 1; i <= tenantCount; i++) {
                Tenant t = openTenant(browser, url, scenario, marker,
                        boundsLog, tenantCount == 1 ? tenant : null,
                        guestWaitMs, i);
                tenants.add(t);
                // 15 s, not 5: a forced collection on the shared JVM pauses
                // every
                // guest in it, so a freshly sampled server can be briefly
                // silent.
                assertTenantsAlive(boundsLog, marker, tenants, 15_000);
                sampleMemory(-1, t.id, i);
            }
            if (tenantCount > 1) {
                System.out.printf("%d tenants open; %d cycles each%n",
                        tenantCount, cycles);
            }

            // Then the work, round-robin: every tenant completes cycle c before
            // any tenant starts c+1, so a sample taken between rounds describes
            // a state every tenant reached rather than a race.
            for (int c = 1; c <= cycles; c++) {
                for (Tenant t : tenants) {
                    int[] r = runCycle(t, scenario, boundsLog, marker, c,
                            tenants.size() > 1);
                    attempted += r[0];
                    verified += r[1];
                }
                assertTenantsAlive(boundsLog, marker, tenants, 15_000);
                sampleMemory(c, tenantCount == 1 ? tenants.get(0).id : "",
                        tenantCount);
            }

            // Truncate, never round: %.0f printed a clean "100 %" for 1199 of
            // 1200 on a run that was then declared void.
            System.out.printf("steps attempted=%d verified=%d (%d%%)%n",
                    attempted, verified, (int) (100L * verified / attempted));
            if (verified != attempted) {
                System.out
                        .println("RUN IS VOID: not every step took effect, so a"
                                + " memory figure from it would describe a different"
                                + " workload than the one specified.");
            }
            // Close first: Playwright only finishes writing the file then.
            tenants.forEach(t -> t.ctx.close());
            String videos = prop("scenario.video", null);
            if (videos != null) {
                String vname = Path.of(scenarioFile).getFileName().toString()
                        .replace(".json", "");
                for (int i = 0; i < tenants.size(); i++) {
                    Tenant t = tenants.get(i);
                    if (t.video == null) {
                        continue;
                    }
                    Path out = Path.of(videos, String.format("%s%s.webm",
                            vname,
                            tenants.size() == 1 ? "" : "-tenant" + (i + 1)));
                    t.video.saveAs(out);
                    System.out.println("video: " + out + " ("
                            + Files.size(out) / 1024 + " kB)");
                }
            }
            browser.close();
            if (verified != attempted) {
                System.exit(1);
            }
        }
    }

    /**
     * A scale reading that is both <b>fresher than the gesture</b> it describes
     * and <b>quiescent</b>.
     *
     * <p>
     * A fixed sleep against a periodic sampler is unsound at any interval: the
     * newest published line can predate the gesture, and then a working product
     * looks like one that ignored the input. That mistake cost this
     * investigation five wrong hypotheses, so freshness is now checked rather
     * than assumed — the guest stamps each line, and this waits for a line
     * stamped after the gesture whose value has stopped moving.
     * </p>
     *
     * <p>
     * Freshness by timestamp alone is still not enough, which took a second
     * wrong reading to learn: the sampler publishes periodically, so two
     * consecutive lines stamped after the gesture can <em>both</em> carry the
     * pre-gesture value while the guest is still working. Both then agree, the
     * value looks quiescent, and the step reports a factor of exactly 1.0000 —
     * a product that responded slowly, indistinguishable from one that ignored
     * the input. Where the caller knows the value the gesture must move away
     * from, it passes it as {@code distinctFrom} and readings equal to it are
     * not accepted as the answer.
     * </p>
     */
    private static double settledScale(String log, String marker, String tenant,
            long notBefore, double distinctFrom) throws Exception {
        double prev = Double.NaN;
        double lastFresh = Double.NaN;
        long deadline = System.currentTimeMillis() + 20_000;
        while (System.currentTimeMillis() < deadline) {
            JsonNode b = readBounds(log, marker, tenant);
            long stamped = b.path("t").asLong();
            double scale = b.path("scale").asDouble();
            if (stamped >= notBefore) {
                lastFresh = scale;
                if (!Double.isNaN(prev) && prev == scale
                        && scale != distinctFrom) {
                    return scale;
                }
                prev = scale;
            }
            Thread.sleep(300);
        }
        if (!Double.isNaN(lastFresh)) {
            // Report it rather than abort: the step then fails with the number
            // actually observed, which is the evidence worth having.
            System.out.printf(
                    "    (no settled scale within 20 s; last fresh reading"
                            + " %.6f, unchanged from before the gesture)%n",
                    lastFresh);
            return lastFresh;
        }
        throw new IllegalStateException(
                "no scale reading stamped after the gesture within 20 s"
                        + " — the guest may not be publishing (check"
                        + " -Djosm.widgetbounds)");
    }

    private static Map<String, Integer> hashAll(Page page,
            Map<String, int[]> crops) {
        Map<String, Integer> out = new LinkedHashMap<>();
        crops.forEach((n, c) -> {
            Object v = page.evaluate(
                    "([x,y,w,h]) => window.__scn.hash(x,y,w,h)",
                    List.of(c[0], c[1], c[2], c[3]));
            out.put(n, ((Number) v).intValue());
        });
        return out;
    }

    private static void act(Page page, BoundingBox box, JsonNode step,
            Map<String, int[]> points) {
        String at = step.path("at").asText();
        int[] p = points.get(at);
        if (p == null) {
            throw new IllegalStateException("step " + step.path("id").asText()
                    + " refers to unknown point " + at);
        }
        double x = box.x + p[0];
        double y = box.y + p[1];
        String action = step.path("action").asText();
        switch (action) {
        case "click" -> {
            page.mouse().move(x, y);
            page.mouse().down();
            page.mouse().up();
        }
        case "wheel" -> {
            page.mouse().move(x, y);
            // One event per notch. Measured: the bridge zooms exactly one step
            // per wheel event whatever the pixel delta is (-100, -200 and -300
            // all gave a factor of 0.5), so one large delta would do a third of
            // the work three notches do.
            int notches = step.path("notches").asInt();
            int dir = notches < 0 ? -1 : 1;
            for (int i = 0; i < Math.abs(notches); i++) {
                page.mouse().wheel(0, dir * 100);
                page.waitForTimeout(250);
            }
        }
        case "key" -> {
            // Move the pointer over the guest window first, so the keystroke
            // lands where a user's would.
            page.mouse().move(x, y);
            page.keyboard().press(step.path("key").asText());
        }
        default -> throw new IllegalStateException("unknown action: " + action);
        }
    }

    /**
     * The geometry the guest published, from the log that captured its stdout.
     */
    /** {@code "t"} and {@code "scale"} pulled out without parsing the rest. */
    private static final java.util.regex.Pattern STAMP = java.util.regex.Pattern
            .compile("\"t\":(\\d+)");
    private static final java.util.regex.Pattern SCALE = java.util.regex.Pattern
            .compile("\"scale\":([0-9.eE+-]+)");

    /**
     * The tail of a log, not the whole thing. The server's log grows for as
     * long as it runs and this is polled several times a second during a long
     * run.
     */
    private static List<String> tailLines(String log, String marker)
            throws Exception {
        if (log.startsWith("http://") || log.startsWith("https://")) {
            // Two-box run: the guest's log lives on the server box while the
            // driver runs where the browsers are. Reading it over HTTP keeps
            // every target resolved from what the application itself published,
            // which is the property the whole rig depends on.
            java.net.http.HttpResponse<String> r = java.net.http.HttpClient
                    .newHttpClient()
                    .send(java.net.http.HttpRequest
                            .newBuilder(java.net.URI.create(log
                                    + (log.contains("?") ? "&" : "?")
                                    + "tail=4194304&latest=1&marker="
                                    + java.net.URLEncoder.encode(marker,
                                            java.nio.charset.StandardCharsets.UTF_8)))
                            .timeout(java.time.Duration.ofSeconds(30)).build(),
                            java.net.http.HttpResponse.BodyHandlers.ofString(
                                    java.nio.charset.StandardCharsets.ISO_8859_1));
            if (r.statusCode() != 200) {
                throw new IllegalStateException("bounds log over HTTP: "
                        + r.statusCode() + " from " + log + " — " + r.body());
            }
            return new ArrayList<>(List.of(r.body().split("\n")));
        }
        try (java.io.RandomAccessFile f = new java.io.RandomAccessFile(log,
                "r")) {
            long len = f.length();
            long from = Math.max(0, len - 4 * 1024 * 1024);
            f.seek(from);
            byte[] buf = new byte[(int) (len - from)];
            f.readFully(buf);
            List<String> out = new ArrayList<>();
            String[] split = new String(buf,
                    java.nio.charset.StandardCharsets.ISO_8859_1).split("\n");
            // Drop a leading partial line, unless we read from the start.
            for (int i = from == 0 ? 0 : 1; i < split.length; i++) {
                out.add(split[i]);
            }
            return out;
        }
    }

    /**
     * Which guest wrote this line: the last bracketed group before the marker.
     * The bridge writes {@code [swing:rs1zaw]}; a guest run outside it writes
     * no prefix, and the id is then empty.
     */
    private static String tenantOf(String line, String marker) {
        int m = line.indexOf(marker);
        int close = line.lastIndexOf(']', m);
        if (close < 0) {
            return "";
        }
        int open = line.lastIndexOf('[', close);
        return open < 0 ? "" : line.substring(open, close + 1);
    }

    /** Newest map scale per tenant, among lines stamped at or after a time. */
    private static Map<String, Double> liveScales(String log, String marker,
            long since) throws Exception {
        Map<String, Double> out = new LinkedHashMap<>();
        for (String line : tailLines(log, marker)) {
            if (!line.contains(marker)) {
                continue;
            }
            java.util.regex.Matcher mt = STAMP.matcher(line);
            java.util.regex.Matcher ms = SCALE.matcher(line);
            if (!mt.find() || !ms.find()
                    || Long.parseLong(mt.group(1)) < since) {
                continue;
            }
            out.put(tenantOf(line, marker), Double.valueOf(ms.group(1)));
        }
        return out;
    }

    /**
     * The tenants publishing at or after a moment, identified by the stamp
     * alone.
     *
     * <p>
     * The ramp needs only <em>who</em> is publishing: {@link #discoverByArrival}
     * takes the newcomer and {@link #assertTenantsAlive} checks each opened
     * tenant is still there. Neither needs a scale — but both used to go through
     * {@link #liveScales}, which skips any line without one, so a guest that
     * publishes rectangles and no {@code scale} read as dead at the first tenant
     * and the ramp stopped with a "ceiling" of one. {@code scale} is now read only
     * where a step declares {@code expectScale}.
     * </p>
     */
    private static java.util.Set<String> liveTenants(String log, String marker,
            long since) throws Exception {
        java.util.Set<String> out = new java.util.LinkedHashSet<>();
        for (String line : tailLines(log, marker)) {
            if (!line.contains(marker)) {
                continue;
            }
            java.util.regex.Matcher mt = STAMP.matcher(line);
            if (!mt.find() || Long.parseLong(mt.group(1)) < since) {
                continue;
            }
            out.add(tenantOf(line, marker));
        }
        return out;
    }

    /**
     * Finds which tenant this browser session is driving, by zooming once and
     * seeing whose scale moved, then putting it back.
     *
     * <p>
     * Done before the resting state is recorded, so the probe leaves nothing
     * behind, and it doubles as a check that input reaches the guest at all
     * before a run's worth of steps is attempted. It refuses to guess: if no
     * tenant responds, or more than one does, it says so and stops.
     * </p>
     */
    private static String discoverTenant(Page page, BoundingBox box,
            Map<String, int[]> points, String log, String marker, String given)
            throws Exception {
        if (given != null) {
            System.out.println("tenant: " + given + " (given)");
            return given;
        }
        java.util.Set<String> publishing = liveTenants(log, marker,
                System.currentTimeMillis() - 5_000);
        if (publishing.size() == 1) {
            String only = publishing.iterator().next();
            System.out.println(
                    "tenant: " + (only.isEmpty() ? "(unprefixed)" : only)
                            + " (the only one publishing)");
            return only;
        }
        // Several guests: telling ours apart means acting and seeing whose
        // scale moves, which does need a scale.
        Map<String, Double> before = liveScales(log, marker,
                System.currentTimeMillis() - 5_000);
        if (before.isEmpty()) {
            throw new IllegalStateException(publishing.size()
                    + " guests are publishing but none reports a 'scale', and"
                    + " telling them apart by a zoom probe needs one. Run one"
                    + " tenant at a time, or use the active ramp, which identifies"
                    + " tenants by arrival and needs no scale.");
        }
        System.out.printf(
                "tenant: %d guests publishing, probing to find ours%n",
                before.size());
        // Fail with the reason rather than a null dereference: this path only
        // runs when another session is alive, so a scenario missing these
        // points
        // works until the day it does not — which is exactly how it failed.
        for (String needed : new String[] { "emptyMap", "mapCentre" }) {
            if (!points.containsKey(needed)) {
                throw new IllegalStateException("tenant discovery needs the '"
                        + needed + "' point, which this scenario does not"
                        + " define. It is only needed when more than one guest is"
                        + " publishing, which is why this can pass for a while"
                        + " and then fail. Known points: " + points.keySet());
            }
        }
        // A click first: with no window manager the guest window is not active
        // until something is clicked in it, and an inactive window drops keys.
        // emptyMap is the scenario's own harmless point.
        press(page, box, points, "emptyMap", null);
        long probeAt = System.currentTimeMillis();
        press(page, box, points, "mapCentre", "NumpadAdd");

        List<String> moved = new ArrayList<>();
        long deadline = System.currentTimeMillis() + 20_000;
        while (System.currentTimeMillis() < deadline && moved.isEmpty()) {
            Thread.sleep(400);
            liveScales(log, marker, probeAt).forEach((t, sc) -> {
                Double was = before.get(t);
                if (was != null && !was.equals(sc) && !moved.contains(t)) {
                    moved.add(t);
                }
            });
        }
        if (moved.size() != 1) {
            throw new IllegalStateException(moved.isEmpty()
                    ? "no guest responded to a zoom keystroke within 20 s, so"
                            + " this session's readings cannot be told from"
                            + " another tenant's. Nothing measured here would"
                            + " be attributable."
                    : "more than one guest responded to one keystroke: " + moved
                            + " — input is reaching sessions it should not.");
        }
        String own = moved.get(0);
        press(page, box, points, "mapCentre", "NumpadSubtract");
        Thread.sleep(1500);
        Double restored = liveScales(log, marker, 0).get(own);
        System.out.printf("tenant: %s (responded; scale %.6f -> %.6f)%n", own,
                before.get(own), restored);
        return own;
    }

    /**
     * A layout the guest published <b>after</b> a given moment, or a failure
     * that says why. Anything older belongs to a state that is no longer true —
     * an earlier session, or the layout from before a setup gesture moved
     * everything — and resolving points against it aims every later click at
     * where things used to be.
     */
    private static JsonNode boundsAfter(String log, String marker,
            String tenant, long notBefore, long timeoutMs, String what)
            throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            JsonNode candidate = readBounds(log, marker, tenant);
            if (candidate.path("t").asLong() >= notBefore) {
                return candidate;
            }
            Thread.sleep(500);
        }
        throw new IllegalStateException("the guest published no geometry after "
                + what + " within " + timeoutMs / 1000
                + " s, so every point would be resolved against a layout that is"
                + " no longer true");
    }

    /**
     * Hashes only the named crops: pixel readback is work, and at N tenants the
     * harness must not become the load it is measuring.
     */
    private static Map<String, Integer> hashSome(Page page,
            Map<String, int[]> crops, List<String> names) {
        Map<String, Integer> out = new LinkedHashMap<>();
        for (String n : names) {
            int[] c = crops.get(n);
            Object v = page.evaluate(
                    "([x,y,w,h]) => window.__scn.hash(x,y,w,h)",
                    List.of(c[0], c[1], c[2], c[3]));
            out.put(n, ((Number) v).intValue());
        }
        return out;
    }

    /**
     * Waits for every declared region to change, and returns how long it took.
     *
     * <p>
     * A fixed settle asks "did it change by now", which under load answers no
     * for work that did happen — the smoke test failed a step whose panel
     * updated a moment after the sleep expired. Polling asks "how long did it
     * take", which is the same check when the system is fast and a measurement
     * when it is not. Returns -1 if the deadline passed without the change,
     * which is a real failure rather than a late frame.
     * </p>
     */
    private static long waitForChange(Page page, Map<String, int[]> crops,
            Map<String, Integer> before, List<String> want, long deadlineMs)
            throws Exception {
        long t0 = System.currentTimeMillis();
        long deadline = t0 + deadlineMs;
        while (true) {
            Map<String, Integer> now = hashSome(page, crops, want);
            boolean all = true;
            for (String n : want) {
                if (now.get(n).equals(before.get(n))) {
                    all = false;
                    break;
                }
            }
            if (all) {
                return System.currentTimeMillis() - t0;
            }
            if (System.currentTimeMillis() >= deadline) {
                return -1;
            }
            Thread.sleep(150);
        }
    }

    /**
     * One tenant: its own Playwright, its own browser, its own endless cycle.
     */
    private static final class Worker implements Runnable {
        final int n;
        final String url;
        final JsonNode scenario;
        final String marker;
        final String boundsLog;
        final long guestWaitMs;
        final boolean headless;
        final java.util.concurrent.CountDownLatch ready = new java.util.concurrent.CountDownLatch(
                1);
        volatile Tenant tenant;
        volatile boolean stop;
        volatile int cycles;
        volatile int stepsFailed;
        volatile long lastCycleMs;
        volatile long lastCycleAt;
        volatile long slowestStepMs;
        volatile String error;

        Worker(int n, String url, JsonNode scenario, String marker,
                String boundsLog, long guestWaitMs, boolean headless) {
            this.n = n;
            this.url = url;
            this.scenario = scenario;
            this.marker = marker;
            this.boundsLog = boundsLog;
            this.guestWaitMs = guestWaitMs;
            this.headless = headless;
            // Staleness is measured from here until the first cycle lands.
            // Left at 0, "now - lastCycleAt" is the current Unix time: one 4
            // GiB
            // cell reported "stalest 1789042934143 ms" and every set containing
            // a tenant that had not yet cycled was judged DEGRADED on it.
            this.lastCycleAt = System.currentTimeMillis();
        }

        @Override
        public void run() {
            try (Playwright pw = Playwright.create()) {
                Browser b = pw.chromium()
                        .launch(new LaunchOptions().setHeadless(headless)
                                .setArgs(browserArgs())
                                .setIgnoreDefaultArgs(ignoredDefaultArgs()));
                tenant = openTenant(b, url, scenario, marker, boundsLog,
                        null, guestWaitMs, n);
                ready.countDown();
                while (!stop) {
                    long t0 = System.currentTimeMillis();
                    int[] r = runCycle(tenant, scenario, boundsLog, marker,
                            cycles + 1, true);
                    stepsFailed += r[0] - r[1];
                    slowestStepMs = Math.max(slowestStepMs, r[2]);
                    cycles++;
                    lastCycleMs = System.currentTimeMillis() - t0;
                    lastCycleAt = System.currentTimeMillis();
                }
                b.close();
            } catch (Throwable e) { // NOSONAR
                // A dead tenant is the signal, not an accident: record why and
                // let the coordinator decide whether the ceiling has been hit.
                error = e.getClass().getSimpleName() + ": " + e.getMessage();
            } finally {
                ready.countDown();
            }
        }
    }

    /**
     * Ramp active users until something stops us, and say what did.
     *
     * <p>
     * Every tenant works continuously from the moment it is ready, so N is a
     * count of users doing something rather than users sitting still. The
     * coordinator adds one at a time, lets the whole set run, and records both
     * the last count at which everyone was still keeping up and the count at
     * which it broke — because a server that answers while serving nobody has
     * been mistaken for a healthy one before.
     * </p>
     */
    private static void activeRamp(String url, JsonNode scenario,
            String marker, String boundsLog, long guestWaitMs,
            boolean headless) throws Exception {
        int maxTenants = Integer.parseInt(prop("scenario.maxTenants", "60"));
        long settleMs = Long.parseLong(prop("scenario.rampSettleMs", "25000"));
        double slowFactor = Double
                .parseDouble(prop("scenario.slowFactor", "3.0"));
        String countFile = prop("scenario.tenantCountFile", null);
        // Add tenants in groups until fineFrom, then one at a time. Stepping
        // singly from 1 to a count we already know is safe is pure ceremony;
        // the resolution only matters near the ceiling.
        int fineFrom = Integer.parseInt(prop("scenario.fineFrom", "0"));
        int coarseStep = Integer.parseInt(prop("scenario.coarseStep", "3"));
        boolean degradedWhileCoarse = false;

        List<Worker> workers = new ArrayList<>();
        List<Tenant> tenants = new ArrayList<>();
        List<Thread> threads = new ArrayList<>();
        long baselineCycleMs = 0;
        long baselineStepMs = 0;
        int lastHealthy = 0;
        String stopReason = "reached the configured maximum";

        int i = 0;
        boolean startFailed = false;
        // Print the verdict even when the ramp throws. Everything the run
        // learned
        // up to the failure is still worth having -- two cells that crashed
        // here
        // produced no "last healthy" at all, so nobody could tell how far they
        // got. The throwable is rethrown after the report, so a genuinely
        // unexpected failure still exits non-zero and runCeiling.sh voids the
        // cell: this makes the failure legible, it does not make it a result.
        RuntimeException rampFailure = null;
        try {
            while (i < maxTenants && !startFailed) {
                // The first step is always singular: the one-tenant cycle time
                // is
                // the baseline every later health check is judged against, and
                // a
                // group start would never produce it.
                int batch = i == 0 ? 1
                        : Math.min(i + coarseStep <= fineFrom ? coarseStep : 1,
                                maxTenants - i);
                Worker w = null;
                for (int k = 0; k < batch; k++) {
                    int n = i + 1;
                    Worker nw = new Worker(n, url, scenario, marker,
                            boundsLog, guestWaitMs, headless);
                    Thread th = new Thread(nw, "tenant-" + n);
                    th.setDaemon(true);
                    th.start();
                    workers.add(nw);
                    threads.add(th);

                    if (!nw.ready.await(guestWaitMs + 120_000,
                            java.util.concurrent.TimeUnit.MILLISECONDS)
                            || nw.error != null) {
                        stopReason = "tenant " + n + " could not start: "
                                + (nw.error == null ? "timed out" : nw.error);
                        workers.remove(nw);
                        startFailed = true;
                        break;
                    }
                    tenants.add(nw.tenant);
                    i = n;
                    w = nw;
                }
                if (w == null) {
                    break;
                }
                if (countFile != null) {
                    Files.writeString(Path.of(countFile), String.valueOf(i));
                }
                System.out.printf("%n=== %d active tenant(s): %s ===%s%n", i,
                        w.tenant.id, batch > 1 ? "  (+" + batch + ")" : "");

                // Let the whole set work together before judging anything.
                Thread.sleep(settleMs);

                Worker dead = workers.stream().filter(x -> x.error != null)
                        .findFirst().orElse(null);
                if (dead != null) {
                    stopReason = "tenant " + dead.n + " died with " + dead.n
                            + " running: " + dead.error;
                    break;
                }
                // A tenant that stopped publishing is the ceiling, not a crash.
                //
                // The check above catches a worker that recorded its own error.
                // This one catches the same event seen from the other side: the
                // guest went quiet. Which of the two notices first is a race,
                // and letting this one throw meant the identical event ended
                // the run with a verdict or killed the JVM depending on timing
                // -- cells died here with no "last healthy" line while others
                // recorded a count, from runs that measured the same thing.
                try {
                    assertTenantsAlive(boundsLog, marker, tenants, 20_000);
                } catch (RuntimeException e) {
                    stopReason = "tenant liveness failed with " + i
                            + " running: " + e.getMessage();
                    break;
                }
                sampleMemory(-1, w.tenant.id, i);

                // Health: everyone still completing cycles, and not far slower
                // than
                // the first tenant managed alone.
                long slowest = 0;
                int failed = 0;
                long stalest = 0;
                long slowestStep = 0;
                for (Worker x : workers) {
                    slowest = Math.max(slowest, x.lastCycleMs);
                    failed += x.stepsFailed;
                    slowestStep = Math.max(slowestStep, x.slowestStepMs);
                    stalest = Math.max(stalest, stalenessMs(
                            System.currentTimeMillis(), x.lastCycleAt));
                }
                if (i == 1) {
                    baselineCycleMs = Math.max(w.lastCycleMs, 1);
                    baselineStepMs = Math.max(w.slowestStepMs, 1);
                }
                // Judge on what a user feels — how long an interaction takes to
                // reach the screen — with a floor, because a fast baseline
                // would
                // otherwise make ordinary jitter look like collapse.
                long stepBudget = Math.max((long) (baselineStepMs * slowFactor),
                        750);
                boolean healthy = failed == 0 && slowestStep <= stepBudget
                        && stalest <= baselineCycleMs * slowFactor * 2;
                System.out.printf(
                        "    cycles=%s  slowest cycle %d ms (1 tenant: %d)  "
                                + "slowest step %d ms (budget %d)  stalest %d ms  failed %d -> %s%n",
                        workers.stream().map(x -> String.valueOf(x.cycles))
                                .reduce((a, b) -> a + "," + b).orElse(""),
                        slowest, baselineCycleMs, slowestStep, stepBudget,
                        stalest, failed, healthy ? "healthy" : "DEGRADED");
                if (healthy) {
                    lastHealthy = i;
                } else if (batch > 1) {
                    // Degrading inside a group means the resolution is not
                    // there:
                    // if 18 was healthy and 21 is not, 19 and 20 were never
                    // observed and "last healthy 18" would understate by up to
                    // two users. Void rather than report a number with slop
                    // hidden inside it -- rerun with a lower fineFrom.
                    degradedWhileCoarse = true;
                }
            }
        } catch (RuntimeException e) {
            rampFailure = e;
            stopReason = "ramp aborted after " + i + " tenants: " + e;
        }

        workers.forEach(x -> x.stop = true);
        for (Thread th : threads) {
            th.join(30_000);
        }

        System.out.printf("%n==== ACTIVE-USER CEILING ====%n");
        if (rampFailure != null) {
            System.out.printf("  ABORTED      : the ramp threw and this cell is"
                    + " VOID. The counts below are what was observed before it,"
                    + " reported so the failure can be diagnosed -- they are not"
                    + " a ceiling.%n");
        }
        if (samplerFailures > 0) {
            System.out.printf(
                    "  NOTE         : %d memory sample(s) could not be"
                            + " taken; those rows are absent from the samples CSV.%n"
                            + "                 The ramp itself is unaffected -- this is"
                            + " a gap in instrumentation, not in the result.%n",
                    samplerFailures);
        }
        System.out.printf("  last healthy : %d active tenants%n", lastHealthy);
        if (degradedWhileCoarse) {
            System.out.printf("  RUN IS VOID  : degraded while adding %d at a"
                    + " time, so the counts between the last healthy group and"
                    + " this one were never observed. Rerun with a lower"
                    + " -Dscenario.fineFrom.%n", coarseStep);
        }
        System.out.printf("  stopped at   : %d%n", workers.size());
        System.out.printf("  why          : %s%n", stopReason);
        System.out.printf("  cycles run   : %d total%n",
                workers.stream().mapToInt(x -> x.cycles).sum());
        System.out.println("  which resource ran out is in the monitor's CSV,"
                + " not here: this side only knows that it stopped");
        if (rampFailure != null) {
            throw rampFailure;
        }
    }

    /**
     * How long since this worker last completed a cycle, in milliseconds.
     *
     * <p>
     * A worker's {@code lastCycleAt} is seeded when it is constructed, so a
     * tenant that has not finished its first cycle is measured from its own
     * start rather than from the epoch. Before that, {@code now - 0} returned
     * the current Unix time -- a 4 GiB cell printed
     * {@code stalest 1789042934143 ms}, and any set containing a not-yet-cycled
     * tenant failed the staleness half of the health check for a reason that
     * had nothing to do with the server.
     * </p>
     *
     * <p>
     * The zero guard is defence rather than logic: with the seed in place it
     * cannot trigger, and it returns 0 rather than a huge number so an unseeded
     * worker can never fail the bar on arithmetic alone. A clock that steps
     * backwards is clamped for the same reason.
     * </p>
     */
    static long stalenessMs(long nowMs, long lastCycleAtMs) {
        if (lastCycleAtMs <= 0L) {
            return 0L;
        }
        return Math.max(0L, nowMs - lastCycleAtMs);
    }

    /**
     * One browser session driving one guest, with everything resolved for it.
     */
    private static final class Tenant {
        BrowserContext ctx;
        Page page;
        BoundingBox box;
        String id;
        Map<String, int[]> points;
        Map<String, int[]> crops;
        JsonNode pointSpecs;
        Map<String, Integer> start;
        com.microsoft.playwright.Video video;
    }

    /**
     * Geometry from this guest in which everything the scenario aims at exists.
     *
     * <p>
     * A guest starting up under load publishes its layout before it has
     * finished drawing its data: 11 of 80 map objects, then 33, then all of
     * them. Reading the first line that arrives and demanding a particular
     * landmark ended every run of a six-run matrix — not because a server
     * refused to serve another user, but because the driver looked too early.
     * Waiting for completeness turns that into what it actually is: a tenant
     * that took longer to start.
     * </p>
     */
    private static JsonNode boundsReady(String log, String marker,
            String tenant, long notBefore, long timeoutMs, JsonNode scenario)
            throws Exception {
        List<String> needed = new ArrayList<>();
        scenario.path("points").fields().forEachRemaining(e -> {
            JsonNode tgt = e.getValue().path("target");
            if (tgt.isTextual()) {
                needed.add(tgt.asText());
            }
        });
        long deadline = System.currentTimeMillis() + timeoutMs;
        JsonNode last = null;
        while (System.currentTimeMillis() < deadline) {
            JsonNode b = readBounds(log, marker, tenant);
            if (b.path("t").asLong() >= notBefore) {
                last = b;
                boolean all = true;
                for (String n : needed) {
                    if (!b.path("targets").has(n)) {
                        all = false;
                        break;
                    }
                }
                if (all) {
                    return b;
                }
            }
            Thread.sleep(500);
        }
        throw new IllegalStateException(String.format(
                "guest %s never published every target this scenario aims at"
                        + " within %d s (last line had %d of them, needs %s)."
                        + " Under load a guest publishes its layout before it has"
                        + " finished drawing, so this means slow to start — not a"
                        + " server refusing to serve another user",
                tenant == null ? "(unidentified)" : tenant, timeoutMs / 1000,
                last == null ? 0 : last.path("targets").size(), needed));
    }

    /**
     * The guest that appeared after this page loaded.
     *
     * <p>
     * The probe-based identification — zoom once and see whose scale moves — is
     * unambiguous only while every other tenant is idle. Under an all-active
     * ramp several scales are moving at once, so identity comes from arrival
     * instead: whichever id is publishing now and was not publishing before.
     * Exact while tenants are opened one at a time, and it costs no gesture.
     * </p>
     */
    private static String discoverByArrival(String log, String marker,
            java.util.Set<String> knownBefore, long navAt, long timeoutMs)
            throws Exception {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            List<String> fresh = new ArrayList<>();
            for (String id : liveTenants(log, marker, navAt)) {
                // An interleaved write can drop the [swing:...] prefix, which
                // would otherwise look like a brand new guest with no name —
                // and later make the liveness check hunt for a tenant that
                // never existed. One such line ended a 31-tenant run.
                if (!id.isEmpty() && !knownBefore.contains(id)) {
                    fresh.add(id);
                }
            }
            if (fresh.size() == 1) {
                return fresh.get(0);
            }
            if (fresh.size() > 1) {
                throw new IllegalStateException(
                        "two guests appeared while one page was loading: "
                                + fresh
                                + " — tenants must be opened one at a time for"
                                + " arrival to identify them");
            }
            Thread.sleep(400);
        }
        throw new IllegalStateException("no new guest published within "
                + timeoutMs / 1000
                + " s of this page loading; the server may be"
                + " unable to start another one, which is itself the ceiling");
    }

    /**
     * Opens one session and prepares it: its own browser context, so the server
     * sees a separate user; its canvas checked against the guest's own window
     * size; its targets resolved from what that guest published; and its
     * identity established by acting and seeing which guest responds.
     */
    private static Tenant openTenant(Browser browser, String url,
            JsonNode scenario, String marker, String boundsLog, String given,
            long guestWaitMs, int n) throws Exception {
        Tenant t = new Tenant();
        // A video of what the driver actually did, where the only other record
        // is a hash. Recorded at the browser, so it shows the
        // pixels a user would have seen rather than the pixels we sampled.
        String videoDir = prop("scenario.video", null);
        Browser.NewContextOptions opts = new Browser.NewContextOptions();
        if (videoDir != null) {
            opts.setRecordVideoDir(Path.of(videoDir)).setRecordVideoSize(1400,
                    1000);
        }
        t.ctx = browser.newContext(opts);
        // A real user's browser can read and write the clipboard; a headless
        // one
        // cannot unless told to. Granting it removes the test environment as an
        // explanation when a copy/paste gesture does nothing.
        try {
            t.ctx.grantPermissions(
                    List.of("clipboard-read", "clipboard-write"));
        } catch (RuntimeException e) {
            System.out.println(
                    "clipboard permissions not granted: " + e.getMessage());
        }
        t.page = t.ctx.newPage();
        // Big enough for the whole guest window PLUS the page's own chrome.
        // The drawer alone puts the canvas origin at x=273, so a 1920-wide
        // guest reaches x=2193 and a 2040 viewport cut 153px off its right
        // edge -- measured, not estimated: the layer name came back truncated
        // mid-word and the tags and selection crops both sat in the clipped
        // band, so their hashes were comparing regions that were partly not
        // there. A clipped canvas does not fail, it just quietly answers a
        // different question.
        t.page.setViewportSize(2240, 1200);
        t.page.setDefaultTimeout(60_000);

        // Who is already publishing, so the one that appears next is ours.
        boolean active = Boolean
                .parseBoolean(prop("scenario.activeRamp", "false"));
        java.util.Set<String> knownBefore = active
                ? new java.util.HashSet<>(liveTenants(boundsLog, marker, 0))
                : java.util.Set.of();
        long navAt = System.currentTimeMillis();
        t.page.navigate(url);
        t.page.waitForFunction(WAIT_FOR_VAADIN);
        t.page.locator("canvas").first()
                .waitFor(new WaitForOptions()
                        .setState(WaitForSelectorState.VISIBLE)
                        .setTimeout(guestWaitMs));
        t.page.waitForFunction(
                "() => [...document.querySelectorAll('canvas')].some(c => {"
                        + " const r = c.getBoundingClientRect();"
                        + " return r.width >= 200 && r.height >= 200; })",
                null, new Page.WaitForFunctionOptions().setTimeout(guestWaitMs)
                        .setPollingInterval(500));
        Thread.sleep(2_000);

        int idx = ((Number) t.page.evaluate(CANVAS_INDEX)).intValue();
        if (idx < 0) {
            throw new IllegalStateException("no canvas at " + url);
        }
        Locator canvas = t.page.locator("canvas").nth(idx);
        t.box = canvas.boundingBox();

        // Its own geometry, published after this page loaded. Several tenants
        // running the same guest do lay out identically, but it is still read
        // per tenant: assuming they match is how a driver ends up aiming one
        // session's clicks with another session's coordinates.
        // Identity first, so the readiness wait below reads THIS guest's lines
        // rather than whichever one happened to publish most recently.
        String arrived = active
                ? discoverByArrival(boundsLog, marker, knownBefore, navAt,
                        guestWaitMs)
                : null;
        JsonNode fresh = boundsReady(boundsLog, marker,
                active ? arrived : given, navAt, guestWaitMs, scenario);
        int gw = fresh.path("window").path(0).asInt();
        int gh = fresh.path("window").path(1).asInt();
        long geo = System.currentTimeMillis() + 30_000;
        while ((Math.abs(gw - t.box.width) > 1
                || Math.abs(gh - t.box.height) > 1)
                && System.currentTimeMillis() < geo) {
            Thread.sleep(500);
            t.box = canvas.boundingBox();
        }
        if (Math.abs(gw - t.box.width) > 1 || Math.abs(gh - t.box.height) > 1) {
            throw new IllegalStateException(String.format(
                    "tenant %d: canvas settled at %.0fx%.0f but the guest"
                            + " window is %dx%d — coordinates would not map 1:1",
                    n, t.box.width, t.box.height, gw, gh));
        }

        idx = ((Number) t.page.evaluate(CANVAS_INDEX)).intValue();
        canvas = t.page.locator("canvas").nth(idx);
        t.box = canvas.boundingBox();
        t.page.evaluate(hashJs(), idx);

        final JsonNode bounds = fresh;
        t.crops = new LinkedHashMap<>();
        scenario.path("crops").fields()
                .forEachRemaining(e -> t.crops.put(e.getKey(),
                        resolveCrop(e.getKey(), e.getValue(), bounds)));
        t.points = new LinkedHashMap<>();
        scenario.path("points").fields()
                .forEachRemaining(e -> t.points.put(e.getKey(),
                        resolvePoint(e.getKey(), e.getValue(), bounds)));

        // Identity, by acting and seeing who responds. The other tenants are
        // already open and idle, so only the one being driven moves and this
        // stays unambiguous as the ramp grows.
        t.pointSpecs = scenario.path("points");

        // Setup, once per session: whatever the profile needs before its first
        // cycle. The accumulating profile zooms out here so there is empty map
        // to draw on — it cannot be a per-cycle step, which would zoom out for
        // ever, and the guest has no command-line option for it.
        if (scenario.has("setup")) {
            for (JsonNode step : scenario.path("setup")) {
                for (int r = 0; r < step.path("repeat").asInt(1); r++) {
                    act(t.page, t.box, step, t.points);
                    t.page.waitForTimeout(250);
                }
                Thread.sleep(step.path("settleMs").asLong(500));
            }
            // Re-resolve: the zoom moved every map object, and a point resolved
            // before it would aim at where things used to be.
            final JsonNode m = boundsAfter(boundsLog, marker, given,
                    System.currentTimeMillis(), 20_000, "setup");
            scenario.path("crops").fields().forEachRemaining(e -> t.crops
                    .put(e.getKey(), resolveCrop(e.getKey(), e.getValue(), m)));
            scenario.path("points").fields()
                    .forEachRemaining(e -> t.points.put(e.getKey(),
                            resolvePoint(e.getKey(), e.getValue(), m)));
        }
        t.id = active ? arrived
                : discoverTenant(t.page, t.box, t.points, boundsLog, marker,
                        given);

        park(t.page, t.box, t.points);
        Map<String, Integer> settling = hashAll(t.page, t.crops);
        long quiet = System.currentTimeMillis() + 30_000;
        while (System.currentTimeMillis() < quiet) {
            Thread.sleep(1000);
            Map<String, Integer> again = hashAll(t.page, t.crops);
            if (again.equals(settling)) {
                break;
            }
            settling = again;
        }
        t.start = settling;
        t.video = t.page.video();
        System.out.printf("tenant %d ready: %s  canvas %.0fx%.0f%n", n,
                t.id.isEmpty() ? "(unprefixed)" : t.id, t.box.width,
                t.box.height);
        return t;
    }

    /**
     * Point positions for cycle N, with any per-cycle offset applied.
     *
     * <p>
     * An accumulating cycle that draws in the same place twice does not
     * accumulate: JOSM's draw mode snaps to nearby nodes, so the second pass
     * extends the first pass's way instead of creating a new one — fewer
     * objects, and silently.
     * </p>
     */
    private static Map<String, int[]> pointsForCycle(Tenant t, int cycle) {
        Map<String, int[]> out = new LinkedHashMap<>();
        t.points.forEach((name, p) -> {
            JsonNode spec = t.pointSpecs.path(name);
            JsonNode per = spec.path("perCycle");
            int wrap = spec.path("perCycleWrap").asInt(0);
            // A lattice, so a long run stays inside the widget: dy walks down a
            // column of `wrap` cells, dx steps across to the next column.
            // Without it, 200 cycles at 20 px would put the point 4000 px below
            // the map and the clicks would land on whatever else is there.
            int dx = per.path(0).asInt(0) * (wrap > 0 ? cycle / wrap : cycle);
            int dy = per.path(1).asInt(0) * (wrap > 0 ? cycle % wrap : cycle);
            out.put(name, new int[] { p[0] + dx, p[1] + dy });
        });
        return out;
    }

    /**
     * The object counts the guest publishes, from a line newer than a moment.
     */
    private static JsonNode readData(String log, String marker, String tenant,
            long notBefore) throws Exception {
        JsonNode best = null;
        for (String line : tailLines(log, marker)) {
            if (!line.contains(marker)
                    || (tenant != null && !line.contains(tenant))) {
                continue;
            }
            JsonNode d;
            try {
                d = new ObjectMapper().readTree(
                        line.substring(line.indexOf(marker) + marker.length()));
            } catch (Exception ignored) {
                continue;
            }
            if (d.path("t").asLong() >= notBefore && d.has("data")) {
                best = d.path("data");
            }
        }
        return best;
    }

    /**
     * One full cycle for one tenant, every step and declared effect checked.
     */
    private static int[] runCycle(Tenant t, JsonNode scenario, String boundsLog,
            String marker, int c, boolean terse) throws Exception {
        int attempted = 0;
        int verified = 0;
        long slowestStepMs = 0;
        // Steps whose pixel change was not seen, but whose work the cycle's
        // data
        // assertion may yet prove. Decided at the end of the cycle.
        List<String> pendingWitness = new ArrayList<>();
        // The tab being driven is the tab in front, as it would be for the user
        // whose session it is. Browsers throttle background pages, and a client
        // that paints on requestAnimationFrame stops painting in one — which is
        // indistinguishable, to a pixel check, from a server that sent nothing.
        // Symmetric across products and closer to the situation being modelled.
        t.page.bringToFront();
        Map<String, int[]> cyc = pointsForCycle(t, c - 1);
        JsonNode wantData = scenario.path("expectDataPerCycle");
        JsonNode dataBefore = wantData.isMissingNode() ? null
                : readData(boundsLog, marker, t.id, 0);
        long cycleAt = System.currentTimeMillis();
        for (JsonNode step : scenario.path("cycle")) {
            Map<String, Integer> before = hashAll(t.page, t.crops);
            double scaleBefore = step.has("expectScale")
                    ? settledScale(boundsLog, marker, t.id, 0, Double.NaN)
                    : 0;
            // From here, so the number is what a user would wait: the gesture
            // being dispatched plus the pixels coming back. Timing from after
            // the gesture returned measured only the tail and floored at 5 ms,
            // against ~151 ms measured for the bridge's input-to-pixel.
            long stepStartedAt = System.currentTimeMillis();
            for (int r = 0; r < step.path("repeat").asInt(1); r++) {
                act(t.page, t.box, step, cyc);
                t.page.waitForTimeout(250);
            }
            long gestureAt = System.currentTimeMillis();
            List<String> want = new ArrayList<>();
            step.path("expect").forEach(n -> want.add(n.asText()));

            // Wait for what was declared, and time it. A step that declares
            // nothing has nothing to wait for, so it keeps its fixed settle.
            long responseMs = 0;
            if (want.isEmpty()) {
                Thread.sleep(step.path("settleMs").asLong(700));
            } else {
                long waited = waitForChange(t.page, t.crops, before, want,
                        scenario.path("waitForChangeMs").asLong(8000));
                responseMs = waited < 0 ? -1
                        : System.currentTimeMillis() - stepStartedAt;
            }
            Map<String, Integer> after = hashAll(t.page, t.crops);

            List<String> changed = new ArrayList<>();
            t.crops.keySet().forEach(n -> {
                if (!before.get(n).equals(after.get(n))) {
                    changed.add(n);
                }
            });
            boolean ok = changed.containsAll(want) && responseMs >= 0;
            if (responseMs > slowestStepMs) {
                slowestStepMs = responseMs;
            }

            String scaleNote = "";
            if (step.has("expectScale")) {
                double factor = settledScale(boundsLog, marker, t.id, gestureAt,
                        scaleBefore) / scaleBefore;
                double wanted = step.path("expectScale").asDouble();
                double tol = scenario.path("scaleTolerance").asDouble(0.02);
                boolean scaleOk = Math.abs(factor - wanted) <= wanted * tol;
                ok = ok && scaleOk;
                scaleNote = String.format(" scale x%.4f (want x%.4f)%s", factor,
                        wanted, scaleOk ? "" : " <-- MISMATCH");
            }
            attempted++;
            // A step whose effect the cycle's data assertion covers is not
            // disproven by a missed pixel change: the guest's own counters are
            // the stronger witness, and voiding a 120-cycle run because one
            // frame was late would throw away a sound measurement.
            if (!ok && "data".equals(step.path("provenBy").asText(null))) {
                pendingWitness.add(step.path("id").asText());
            }
            verified += ok ? 1 : 0;
            if (!ok || !terse) {
                // Name the tenant: with N of them a bare FAIL cannot be traced
                // to a session, and the first N-tenant run produced 49 failures
                // that could not be attributed to anyone.
                System.out.printf(
                        "  cycle %d %-12s %s %s expected=%s changed=%s%s%s%n",
                        c, step.path("id").asText(), ok ? "PASS" : "FAIL",
                        t.id.isEmpty() ? "" : t.id, String.join(",", want),
                        changed.isEmpty() ? "-" : String.join(",", changed),
                        responseMs > 0 ? String.format(" %dms", responseMs)
                                : (responseMs < 0 ? " NEVER CHANGED" : ""),
                        scaleNote);
            }

            // Pace the NEXT gesture, having already measured this one's
            // response. waitForChange returns the moment the pixels differ, so
            // a fast step used to be followed immediately by the next -- and
            // the two layer steps click the identical point, which put two
            // clicks ~300 ms apart and Chromium delivered them as a
            // double-click. JOSM then acted on the row instead of toggling it,
            // so layer-hide "passed" and layer-show did nothing.
            //
            // settleMs is the declared quiet time after a gesture; honouring it
            // as a floor keeps pacing deterministic without touching the
            // measurement, which is still time-to-change. Under load responses
            // exceed the floor and cycle time grows, which is the signal the
            // quality bar is reading.
            long quiet = step.path("settleMs").asLong(500)
                    - (System.currentTimeMillis() - gestureAt);
            if (quiet > 0) {
                Thread.sleep(quiet);
            }
        }
        if (verified == 0 && attempted > 0) {
            // Distinct from ordinary failure: nothing this tenant did produced
            // any pixel at all. Its guest may be fine — the zoom assertion can
            // still read a correct scale — while frames stop reaching this
            // page. Reporting it as "no frames" rather than N failed steps is
            // the difference between a diagnosis and a tally.
            System.out.printf(
                    "  cycle %d %s: NO FRAMES REACHED THIS PAGE for any of the"
                            + " %d steps%n",
                    c, t.id.isEmpty() ? "tenant" : t.id, attempted);
        }
        // Did this cycle leave behind exactly what it was supposed to? An
        // accumulating profile that cannot prove it accumulated is just a
        // steady
        // one with drift, and the two would be reported the same way.
        if (dataBefore != null) {
            JsonNode afterData = readData(boundsLog, marker, t.id, cycleAt);
            StringBuilder got = new StringBuilder();
            boolean okData = true;
            java.util.Iterator<String> keys = wantData.fieldNames();
            while (keys.hasNext()) {
                String k = keys.next();
                int delta = (afterData == null ? 0 : afterData.path(k).asInt())
                        - dataBefore.path(k).asInt();
                got.append(got.length() == 0 ? "" : ", ")
                        .append(String.format("%s%+d", k, delta));
                okData = okData && delta == wantData.path(k).asInt();
            }
            attempted++;
            verified += okData ? 1 : 0;
            if (okData && !pendingWitness.isEmpty()) {
                verified += pendingWitness.size();
                System.out.printf(
                        "  cycle %d %s: %d step(s) unwitnessed (%s) — the frame"
                                + " was late, but this cycle's counters prove"
                                + " the work%n",
                        c, t.id, pendingWitness.size(),
                        String.join(",", pendingWitness));
            }
            System.out.printf("  cycle %d %s accumulated %s%s%n", c,
                    t.id.isEmpty() ? "" : t.id, got,
                    okData ? "" : "  <-- WANTED " + wantData);
        }

        park(t.page, t.box, cyc);
        Map<String, Integer> now = hashAll(t.page, t.crops);
        List<String> drift = new ArrayList<>();
        t.crops.keySet().forEach(n -> {
            if (!now.get(n).equals(t.start.get(n))) {
                drift.add(n);
            }
        });
        if (!drift.isEmpty() || !terse) {
            System.out.printf("  cycle %d %s: crops differing from start: %s%n",
                    c, t.id.isEmpty() ? "tenant" : t.id,
                    drift.isEmpty() ? "none" : String.join(",", drift));
        }
        return new int[] { attempted, verified, (int) slowestStepMs };
    }

    /**
     * Every tenant we opened is still publishing. Checked before each sample.
     *
     * <p>
     * A guest that stops — a dropped connection, a session reaped, a process
     * killed — would otherwise go unnoticed, and the ramp would keep
     * attributing N tenants' memory to a server hosting fewer, understating the
     * cost per user. Checked by id rather than by count, so a stale tenant from
     * an earlier session cannot make up the numbers.
     * </p>
     */
    private static void assertTenantsAlive(String log, String marker,
            List<Tenant> tenants, long windowMs) throws Exception {
        java.util.Set<String> live = liveTenants(log, marker,
                System.currentTimeMillis() - windowMs);
        List<String> gone = new ArrayList<>();
        for (Tenant t : tenants) {
            if (t.id != null && !t.id.isEmpty() && !live.contains(t.id)) {
                gone.add(t.id);
            }
        }
        if (!gone.isEmpty()) {
            throw new IllegalStateException(String.format(
                    "%d of %d tenants stopped publishing within the last %d s: %s"
                            + " — every later sample would charge this server's"
                            + " memory to more users than it is actually serving",
                    gone.size(), tenants.size(), windowMs / 1000,
                    String.join(",", gone)));
        }
    }

    /**
     * One memory row, taken at a cycle boundary rather than on a timer. A timer
     * conflates memory with speed, while a boundary sample says "after N
     * completed cycles of a workload every step of which was verified".
     *
     * <p>
     * The sampler itself is a command supplied by the caller, because which
     * processes to sample is the caller's knowledge, not the driver's. The
     * driver only guarantees <em>when</em> the sample is taken.
     * </p>
     */
    /** Samples that could not be taken. Reported, never fatal. */
    private static int samplerFailures = 0;

    private static void sampleMemory(int cycle, String tenant, int tenants)
            throws Exception {
        String cmd = prop("scenario.memoryCmd", null);
        if (cmd == null) {
            return;
        }
        String csv = prop("scenario.memoryCsv", null);
        List<String> lines = new ArrayList<>();
        boolean templated = cmd.contains("{cycle}")
                || cmd.contains("{tenants}");
        if (csv != null && !Files.exists(Path.of(csv)) && !templated) {
            lines.add(run(cmd + " --header"));
        }
        // A local sampler takes flags; a two-box run calls Box A over HTTP,
        // where the same values go into a URL. One template covers both rather
        // than a second code path for the remote case — and the remote case is
        // the one that produces the real numbers, so it must not be the
        // less-tested one.
        String call = templated
                ? cmd.replace("{cycle}", String.valueOf(cycle))
                        .replace("{tenants}", String.valueOf(tenants))
                        // Square brackets are not legal in a query string,
                        // and the tag carries them ([swing:ab12cd]).
                        .replace("{tenant}",
                                tenant == null ? ""
                                        : tenant.replace("[", "").replace("]",
                                                ""))
                : cmd + " --cycle " + cycle + " --tenants " + tenants
                        + (tenant == null || tenant.isEmpty() ? ""
                                : " --tenant " + tenant);
        // Retry before giving up. The remote sampler walks a whole process
        // tree, and under load one call can take longer than the client will
        // wait — which killed a ten-minute cell at five tenants and reported
        // no verdict at all. A transient sampler failure is not a result, and
        // it should not be able to void a run that was going fine.
        String out = null;
        Exception last = null;
        for (int attempt = 1; attempt <= 3 && out == null; attempt++) {
            try {
                out = run(call);
            } catch (Exception e) {
                last = e;
                System.out.printf("  mem sampler attempt %d/3 failed: %s%n",
                        attempt, e.getMessage());
                Thread.sleep(2000L * attempt);
            }
        }
        if (out == null) {
            // Do NOT throw. The comment above states that a sampler failure
            // must not void a run, and this line did exactly that: two round-2
            // cells died here, at five tenants, with the ramp perfectly
            // healthy, and printed no ceiling verdict at all --
            // while the runner around them still wrote a full result. The
            // memory sample is instrumentation; the ramp is the measurement.
            // A sample that could not be taken is recorded as missing.
            samplerFailures++;
            System.out.printf(
                    "  mem sampler gave up after 3 attempts: %s%n"
                            + "    recording a MISSING sample and continuing; "
                            + "instrumentation must not void a measurement%n",
                    last == null ? "unknown" : last.getMessage());
            return;
        }
        lines.add(out);
        lines.forEach(l -> System.out.println("  mem " + l));
        if (csv != null) {
            Files.writeString(Path.of(csv), String.join("\n", lines) + "\n",
                    java.nio.file.StandardOpenOption.CREATE,
                    java.nio.file.StandardOpenOption.APPEND);
        }
    }

    private static String run(String cmd) throws Exception {
        Process p = new ProcessBuilder("bash", "-lc", cmd)
                .redirectErrorStream(true).start();
        String out = new String(p.getInputStream().readAllBytes()).trim();
        if (!p.waitFor(3, java.util.concurrent.TimeUnit.MINUTES)
                || p.exitValue() != 0) {
            throw new IllegalStateException(
                    "memory sampler failed: " + cmd + " -> " + out);
        }
        return out;
    }

    /**
     * Pointer to the scenario's neutral point, for an at-rest reading. JOSM
     * highlights whatever is under the pointer, so an at-rest snapshot taken
     * with it on the map is not comparable with one taken after the last step
     * left it on a panel.
     */
    private static void park(Page page, BoundingBox box,
            Map<String, int[]> points) {
        int[] p = points.get("park");
        if (p == null) {
            return;
        }
        page.mouse().move(box.x + p[0], box.y + p[1]);
        page.waitForTimeout(400);
    }

    /**
     * One click, or one keystroke after moving the pointer, at a named point.
     */
    private static void press(Page page, BoundingBox box,
            Map<String, int[]> points, String at, String key) {
        int[] p = points.get(at);
        page.mouse().move(box.x + p[0], box.y + p[1]);
        if (key == null) {
            page.mouse().click(box.x + p[0], box.y + p[1]);
        } else {
            page.keyboard().press(key);
        }
        page.waitForTimeout(400);
    }

    private static JsonNode readBounds(String log, String marker, String tenant)
            throws Exception {
        // Newest first, and skip anything that does not parse. At 30+ tenants
        // the shared stdout log interleaves and lines arrive truncated: one run
        // ended on a JsonEOFException from exactly that, which is noise being
        // mistaken for a ceiling. A corrupt line is discarded, not fatal.
        List<String> candidates = new ArrayList<>();
        for (String line : tailLines(log, marker)) {
            if (!line.contains(marker)) {
                continue;
            }
            if (tenant != null && !tenant.isEmpty() && !line.contains(tenant)) {
                continue;
            }
            candidates.add(line);
        }
        int corrupt = 0;
        for (int i = candidates.size() - 1; i >= 0; i--) {
            String line = candidates.get(i);
            try {
                return new ObjectMapper().readTree(
                        line.substring(line.indexOf(marker) + marker.length()));
            } catch (Exception truncated) {
                corrupt++;
            }
        }
        throw new IllegalStateException(
                "no parseable '" + marker.trim() + "' line in " + log
                        + (tenant == null ? "" : " for tenant " + tenant) + " ("
                        + corrupt + " corrupt line(s) skipped)"
                        + " — is the guest publishing bounds lines? (see the kit's"
                + " guest contract)");
    }

    private static int[] resolvePoint(String name, JsonNode spec,
            JsonNode bounds) {
        if (spec.has("target")) {
            JsonNode pt = bounds.path("targets")
                    .path(spec.get("target").asText());
            if (pt.isMissingNode() || !pt.isArray()) {
                throw new IllegalStateException(String.format(
                        "point %s wants target %s, which the guest did not"
                                + " report (%d targets reported)",
                        name, spec.get("target").asText(),
                        bounds.path("targets").size()));
            }
            return new int[] { pt.path(0).asInt(), pt.path(1).asInt() };
        }
        JsonNode w = widget(name, spec, bounds);
        double fx = spec.path("at").path(0).asDouble(0.5);
        double fy = spec.path("at").path(1).asDouble(0.5);
        // A pixel offset on top of the fraction, because some constraints are
        // in pixels: JOSM's node snap radius is 10 px, so a shape meant to
        // clear it has to be sized in the units it is measured in, not as a
        // fraction of a widget whose size varies with the window.
        int ox = spec.path("offsetPx").path(0).asInt(0);
        int oy = spec.path("offsetPx").path(1).asInt(0);
        return new int[] {
                (int) (w.path(0).asInt() + w.path(2).asInt() * fx) + ox,
                (int) (w.path(1).asInt() + w.path(3).asInt() * fy) + oy };
    }

    private static int[] resolveCrop(String name, JsonNode spec,
            JsonNode bounds) {
        JsonNode w = widget(name, spec, bounds);
        int i = spec.path("inset").asInt(0);
        return new int[] { w.path(0).asInt() + i, w.path(1).asInt() + i,
                Math.max(1, w.path(2).asInt() - 2 * i),
                Math.max(1, w.path(3).asInt() - 2 * i) };
    }

    private static JsonNode widget(String name, JsonNode spec,
            JsonNode bounds) {
        String key = spec.path("widget").asText();
        JsonNode w = bounds.path("widgets").path(key);
        if (w.isMissingNode() || !w.isArray()) {
            List<String> have = new ArrayList<>();
            bounds.path("widgets").fieldNames().forEachRemaining(have::add);
            throw new IllegalStateException(String.format(
                    "%s wants widget %s, which the guest did not report (has: %s)",
                    name, key, String.join(", ", have)));
        }
        return w;
    }

    /**
     * Every setting this driver reads goes through here, and every resolution
     * is echoed once, with whether the value was supplied or defaulted.
     *
     * <p>
     * That echo is the point. Three readings in this project were lost to a
     * property that existed on the driver but on no script: the value fell back
     * to its default in silence while the run label went on claiming otherwise,
     * and it was only caught by reading run headers long afterwards. A run is
     * now auditable from its own output rather than from the script that
     * launched it, and a setting added later is covered automatically instead
     * of having to be added to a list someone maintains — which would be the
     * same failure again, one level up.
     * </p>
     */
    private static String prop(String name, String fallback) {
        String v = System.getProperty(name);
        boolean supplied = v != null && !v.isBlank();
        String value = supplied ? v.trim() : fallback;
        if (!RESOLVED.containsKey(name)) {
            RESOLVED.put(name, value);
            System.out.printf("prop %-28s = %-34s [%s]%n", name,
                    value == null ? "<unset>" : value,
                    supplied ? "set" : "default");
        }
        return value;
    }

    /**
     * Chromium flags that stop each browser hoarding disk.
     *
     * <p>
     * Measured: a browser holds ~370-540 MB of its profile directory, almost
     * all of it in files it creates, unlinks and keeps open — so {@code du}
     * cannot see them and only {@code df} moves. On a load box with 18 GB free
     * that exhausts the disk at roughly 35-45 tenants, which is exactly where
     * two calibration ramps stopped. Both looked like browser-launch failures,
     * because a browser that cannot write its profile cannot start.
     * </p>
     *
     * <p>
     * These touch caching only. Nothing here changes how the page renders,
     * which matters because the pixels are the measurement; a flag like
     * {@code --disable-gpu} would have made the run cheaper and the result
     * meaningless. Override with {@code -Dscenario.browserArgs=a,b,c}, or set
     * it empty to launch stock for comparison.
     * </p>
     */
    /**
     * Whether to let Chromium back shared memory with {@code /dev/shm}.
     *
     * <p>
     * Playwright passes {@code --disable-dev-shm-usage} by default, forcing
     * those segments into files on disk instead. That default is for Docker,
     * where {@code /dev/shm} is often capped at 64 MB. On a load box it is
     * backwards, and expensively so: measured at 1,042 MB across 187
     * deleted-but-open files for four tenants, about 260 MB each, scaling with
     * canvas area — so Full HD made it bite. It exhausted an 18 GB disk at
     * roughly 35-45 tenants and surfaced as browsers that could not start,
     * which is what stopped two calibration ramps.
     * </p>
     *
     * <p>
     * Off by default because {@code /dev/shm} is outside the directory this rig
     * is allowed to use on the load box, so enabling it is a decision rather
     * than a default. When on, the same bytes live in RAM instead — the right
     * trade on a box with far more memory than disk.
     * </p>
     */
    private static boolean useDevShm() {
        return Boolean.parseBoolean(prop("scenario.useDevShm", "false"));
    }

    private static List<String> ignoredDefaultArgs() {
        return useDevShm() ? List.of("--disable-dev-shm-usage") : List.of();
    }

    private static List<String> browserArgs() {
        String custom = prop("scenario.browserArgs", null);
        if (custom != null) {
            return custom.isEmpty() ? List.of() : List.of(custom.split(","));
        }
        return List.of("--disk-cache-size=1", "--media-cache-size=1",
                "--disable-gpu-shader-disk-cache",
                "--disable-background-networking");
    }

    /** Insertion-ordered, so the echo reads in the order the run needs them. */
    private static final Map<String, String> RESOLVED = new LinkedHashMap<>();

    /**
     * Complains, at exit, about any {@code -Dscenario.*} or {@code -Dload.*}
     * that was supplied and never read.
     *
     * <p>
     * The echo above catches a setting that defaulted; this catches the other
     * half, which is the half that actually bit. {@code LOAD_RAMP_MS} was
     * passed by a script to a driver that had no such property, so the ramp ran
     * unpaced and the run labels stopped meaning tenant counts — discovered
     * only by reading headers afterwards. A typo fails the same silent way.
     * </p>
     *
     * <p>
     * Runs after the run finishes rather than at startup, because some settings
     * are resolved late — inside the ramp — and checking early would report a
     * property that is about to be read.
     * </p>
     */
    private static void warnUnreadProperties() {
        List<String> unread = new ArrayList<>();
        for (String name : System.getProperties().stringPropertyNames()) {
            if ((name.startsWith("scenario.") || name.startsWith("load."))
                    && !RESOLVED.containsKey(name)) {
                unread.add(name);
            }
        }
        if (unread.isEmpty()) {
            return;
        }
        java.util.Collections.sort(unread);
        for (String name : unread) {
            System.out.printf(
                    "WARNING %s was set to '%s' and never read by this driver"
                            + " — misspelt, or meant for another driver%n",
                    name, System.getProperty(name));
        }
    }
}
