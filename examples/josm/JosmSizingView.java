package com.example.swingbridge.ui;

import javax.swing.JFrame;
import javax.swing.WindowConstants;

import java.awt.Component;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.vaadin.flow.component.orderedlayout.VerticalLayout;
import com.vaadin.flow.router.Route;
import com.vaadin.swingbridge.SwingBridge;
import com.vaadin.swingbridge.SwingBridgeSession;

/**
 * The JOSM example's view for a skeleton-starter clone. Drop this file into
 * {@code src/main/java/com/example/swingbridge/ui/}, put the bounds-publishing
 * JOSM jar -- and nothing else -- into {@code applibs/}, and drive it with
 * {@code VIEW=josm}.
 *
 * <p>
 * It carries the three things the sizing kit leaves to the customer's own
 * view, taken from the round-2 rig's {@code JosmApp}:
 * </p>
 * <ul>
 * <li><b>JOSM's arguments</b>: offline for every resource it knows about (a
 * guest that waits on the network makes per-user cost a measure of the
 * network), a fixed language, and a <b>pinned window</b> of 1920x1080 -- the
 * scenario's points are window-relative, so this must match
 * {@code josm-cycle.json}'s {@code window} block.</li>
 * <li><b>Test support</b>: {@code josm.widgetbounds} makes the patched JOSM
 * publish its widget geometry every 250 ms, and {@code josm.unattended} skips
 * a modal start-up dialog no unattended host can answer (guest patches 1 and
 * 2 in {@code PATCH-LEDGER.md}, beside this file).</li>
 * <li><b>A home per tenant</b>: JOSM keeps preferences, caches and autosaves in
 * one directory named by a JVM-global property. Guest patch 3 makes it prefer
 * {@code josm.home.<thread-group>}, and each tenant already runs in a thread
 * group named after its session, so the key is unique per tenant and nothing
 * is shared or serialised. The preferences seeded there turn off the
 * message-of-the-day fetch and the minimap's tile downloads, both of which
 * reach the network despite {@code --offline=all}.</li>
 * </ul>
 *
 * <p>
 * Two inputs come from the JVM command line, through the kit's
 * {@code SIZING_EXTRA_JVM}: {@code -Djosm.data=<absolute path to
 * grid-helsinki.osm>} (required -- JOSM resolves a relative path against its own
 * working directory) and {@code -Djosm.homeBase=<scratch directory>} (default:
 * under the JVM's temp directory). A missing data file fails the view at once,
 * loudly, rather than letting a guest that never loaded read as a capacity of
 * zero -- the round-2 rig learned that one the hard way.
 * </p>
 */
@Route("josm")
public class JosmSizingView extends VerticalLayout {

    public JosmSizingView() {
        add(new JosmBridge());
    }

    static final class JosmBridge extends SwingBridge {

        private static final Logger LOG = LoggerFactory.getLogger(JosmBridge.class);

        private static final String MAIN_CLASS = "org.openstreetmap.josm.gui.MainApplication";

        /** Must match the scenario's {@code window} block. */
        private static final int WINDOW_W = 1920;
        private static final int WINDOW_H = 1080;

        private static final String HOME_BASE = System.getProperty("josm.homeBase",
                Path.of(System.getProperty("java.io.tmpdir"), "josm-sizing-tenants").toString());

        static {
            System.setProperty("josm.widgetbounds",
                    System.getProperty("josm.widgetbounds", "250"));
            System.setProperty("josm.unattended", "1");
        }

        JosmBridge() {
            super(MAIN_CLASS, args());
        }

        private static String[] args() {
            String data = System.getProperty("josm.data");
            if (data == null || data.isBlank()) {
                throw new IllegalStateException("-Djosm.data=<absolute path to the .osm extract> is not set;"
                        + " the JOSM example needs it (SIZING_EXTRA_JVM in harness.env)");
            }
            if (!Files.isReadable(Path.of(data))) {
                throw new IllegalStateException("josm.data is not readable: " + data);
            }
            return new String[] { "--offline=all", "--language=en",
                    "--geometry=" + WINDOW_W + "x" + WINDOW_H + "+0+0", "--no-maximize",
                    data };
        }

        /**
         * Gives this tenant its own JOSM home before the guest starts. Keyed by
         * the session id, which is also the tenant's thread-group name; must
         * run before {@code super} launches, because JOSM reads its home during
         * its own start-up.
         */
        @Override
        protected void runSwingApp(SwingBridgeSession session) {
            String slug = session.id().replaceAll("[^A-Za-z0-9._-]", "-");
            if (slug.length() > 48) {
                slug = slug.substring(0, 48);
            }
            Path home = Path.of(HOME_BASE, "tenant-" + slug);
            seedPreferences(home);
            System.setProperty("josm.home." + session.id(), home.toString());
            LOG.info("JOSM tenant {} home={}", session.id(), home);
            super.runSwingApp(session);
        }

        /**
         * A minimal preferences file, written only if absent. No XML comments:
         * a double hyphen inside one is illegal XML and JOSM rejects the file.
         */
        private static void seedPreferences(Path home) {
            Path prefs = home.resolve("preferences.xml");
            try {
                if (Files.exists(prefs)) {
                    return;
                }
                Files.createDirectories(prefs.getParent());
                Files.writeString(prefs, """
                        <?xml version="1.0" encoding="UTF-8"?>
                        <preferences xmlns='http://josm.openstreetmap.de/preferences-1.0' version='19555'>
                          <tag key='help.displaymotd' value='false'/>
                          <tag key='autosave.interval' value='-1'/>
                          <tag key='autosave.enabled' value='false'/>
                          <tag key='minimap.visible' value='false'/>
                        </preferences>
                        """);
            } catch (IOException | RuntimeException e) {
                LOG.warn("Could not seed JOSM preferences at {} -- tenants may stall on the"
                        + " 'Message of the day' download", prefs, e);
            }
        }

        /**
         * A stray window close must dispose, not exit: an uncontained guest
         * {@code System.exit} would take the shared server down with every
         * other tenant. This does not contain JOSM's own File > Exit; the
         * scenario never uses it.
         */
        @Override
        protected void afterInit(Component component) {
            SwingBridge.runInAppContext(component, () -> {
                if (component instanceof JFrame frame) {
                    frame.setDefaultCloseOperation(WindowConstants.DISPOSE_ON_CLOSE);
                }
            });
        }
    }
}
