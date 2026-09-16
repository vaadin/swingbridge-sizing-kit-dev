package com.example.swingbridge.ui;

import javax.swing.JFrame;
import javax.swing.WindowConstants;

import java.awt.Component;

import com.vaadin.flow.component.orderedlayout.VerticalLayout;
import com.vaadin.flow.router.Route;
import com.vaadin.swingbridge.SwingBridge;

/**
 * The view the sizing kit installs into a skeleton-starter clone: one page,
 * {@code /sizing}, that runs your Swing application through Swing Bridge the
 * way the skeleton's own view does -- {@code new SwingBridge(mainClass, args)}
 * -- with the main class and its arguments taken from the server's command
 * line instead of being written into this file.
 *
 * <p>
 * The kit composes that command line from {@code harness/harness.env}:
 * {@code SIZING_MAIN_CLASS} arrives as {@code -Dsizing.mainClass=...} and
 * {@code SIZING_ARGS} as {@code -Dsizing.args=...}. So this file is the same
 * for every application and is never edited; change the two settings and run
 * {@code ./runBoxA.sh} again.
 * </p>
 *
 * <p>
 * Arguments are split on whitespace. An argument that itself contains spaces
 * cannot be passed this way; for that, or for anything your application needs
 * before it starts -- a property per tenant, a seeded configuration directory
 * -- copy this file, give the copy its own {@code @Route}, override
 * {@link SwingBridge#mainMethodArgs()} or {@link SwingBridge#runSwingApp}, and
 * set {@code VIEW} to the new route. {@code examples/josm/JosmSizingView.java}
 * does all three.
 * </p>
 *
 * <p>
 * A missing main class fails here, at once and by name, rather than as a
 * tenant that never starts: a guest that never launched reads as a capacity of
 * zero.
 * </p>
 */
@Route("sizing")
public class SizingView extends VerticalLayout {

    public SizingView() {
        add(new SizingBridge());
    }

    static final class SizingBridge extends SwingBridge {

        static final String MAIN_CLASS_PROPERTY = "sizing.mainClass";
        static final String ARGS_PROPERTY = "sizing.args";

        SizingBridge() {
            super(mainClass(), args());
        }

        private static String mainClass() {
            String main = System.getProperty(MAIN_CLASS_PROPERTY, "").trim();
            if (main.isEmpty()) {
                throw new IllegalStateException("-D" + MAIN_CLASS_PROPERTY
                        + " is not set. The sizing kit passes SIZING_MAIN_CLASS from"
                        + " harness/harness.env here; set it and run ./runBoxA.sh again.");
            }
            return main;
        }

        private static String[] args() {
            String args = System.getProperty(ARGS_PROPERTY, "").trim();
            return args.isEmpty() ? new String[0] : args.split("\\s+");
        }

        /**
         * A stray window close must dispose, not exit: many Swing applications
         * give their main frame {@code EXIT_ON_CLOSE}, and an uncontained
         * {@code System.exit} would take the shared server down with every
         * other tenant. The scenario never closes the window, so in a clean run
         * this changes nothing about what is measured.
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
