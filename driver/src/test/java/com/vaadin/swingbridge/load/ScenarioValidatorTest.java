package com.vaadin.swingbridge.load;

import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * {@code --validate} resolves a scenario against one published bounds line
 * with the run's own code, so what it accepts is what a run would resolve.
 * The positive case is the shipped JOSM example itself.
 */
class ScenarioValidatorTest {

    @TempDir
    Path tmp;

    /** The example the kit ships, from the kit's examples directory. */
    private static final Path JOSM = Path.of("..", "examples", "josm",
            "josm-cycle.json");

    /** One line as the bridge writes it: tenant prefix, marker, JSON. */
    private static final String WIDGETS = "\"widgets\":{\"map\":[273,70,1200,815],"
            + "\"tags\":[1500,300,325,208],\"selection\":[1500,520,325,208],"
            + "\"layers\":[1500,80,325,208]}";
    private static final String TARGETS = "\"targets\":{\"building/13/5163\":[496,457],"
            + "\"building/9/5188\":[600,470]}";

    private Path bounds(String json) throws Exception {
        Path f = tmp.resolve("server.log");
        Files.writeString(f, "some host line\n[swing:ab12cd] WIDGET-BOUNDS " + json
                + "\n");
        return f;
    }

    private List<String> validate(Path scenario, Path log) throws Exception {
        PrintStream quiet = new PrintStream(new ByteArrayOutputStream());
        return ScenarioDriver.validateScenario(scenario, log.toString(), quiet);
    }

    private Path scenario(String json) throws Exception {
        Path f = tmp.resolve("scenario.json");
        Files.writeString(f, json);
        return f;
    }

    /** A minimal valid scenario: one point, one crop, one click step. */
    private static final String MINIMAL = "{\"points\":{\"p\":{\"widget\":\"map\",\"at\":[0.5,0.5]}},"
            + "\"crops\":{\"c\":{\"widget\":\"map\"}},"
            + "\"cycle\":[{\"id\":\"s1\",\"action\":\"click\",\"at\":\"p\",\"expect\":[\"c\"]}]}";

    @Test
    @DisplayName("the shipped JOSM example resolves against a full bounds line")
    void josmExampleIsValid() throws Exception {
        assertTrue(Files.exists(JOSM), "example missing at " + JOSM.toAbsolutePath());
        List<String> f = validate(JOSM, bounds("{\"t\":1757900000000,\"scale\":8.0,"
                + "\"window\":[1920,1080]," + WIDGETS + "," + TARGETS + "}"));
        assertEquals(List.of(), f);
    }

    @Test
    @DisplayName("no scale: only the two expectScale steps fail, nothing else")
    void scaleIsAnOptIn() throws Exception {
        List<String> f = validate(JOSM, bounds("{\"t\":1757900000000,"
                + "\"window\":[1920,1080]," + WIDGETS + "," + TARGETS + "}"));
        assertEquals(2, f.size(), f.toString());
        assertTrue(f.get(0).contains("zoom-in") && f.get(0).contains("expectScale"), f.get(0));
        assertTrue(f.get(1).contains("zoom-out") && f.get(1).contains("expectScale"), f.get(1));
    }

    @Test
    @DisplayName("a minimal scenario without scale or targets is valid")
    void minimalWithoutScale() throws Exception {
        assertEquals(List.of(), validate(scenario(MINIMAL),
                bounds("{\"t\":1,\"window\":[800,600]," + WIDGETS + "}")));
    }

    @Test
    @DisplayName("a step aiming at an unknown point is named")
    void unknownPoint() throws Exception {
        List<String> f = validate(scenario(MINIMAL.replace("\"at\":\"p\"", "\"at\":\"nowhere\"")),
                bounds("{\"t\":1,\"window\":[800,600]," + WIDGETS + "}"));
        assertEquals(1, f.size(), f.toString());
        assertTrue(f.get(0).contains("unknown point 'nowhere'"), f.get(0));
    }

    @Test
    @DisplayName("a step expecting an undeclared crop is named")
    void unknownCrop() throws Exception {
        List<String> f = validate(scenario(MINIMAL.replace("\"expect\":[\"c\"]", "\"expect\":[\"ghost\"]")),
                bounds("{\"t\":1,\"window\":[800,600]," + WIDGETS + "}"));
        assertEquals(1, f.size(), f.toString());
        assertTrue(f.get(0).contains("unknown crop 'ghost'"), f.get(0));
    }

    @Test
    @DisplayName("a widget the guest does not report fails the point and the crop that use it")
    void widgetNotPublished() throws Exception {
        List<String> f = validate(scenario(MINIMAL),
                bounds("{\"t\":1,\"window\":[800,600],\"widgets\":{\"other\":[0,0,10,10]}}"));
        assertEquals(2, f.size(), f.toString());
        assertTrue(f.get(0).contains("wants widget map"), f.get(0));
    }

    @Test
    @DisplayName("a bounds line without t or window fails those fields")
    void boundsFieldsChecked() throws Exception {
        List<String> f = validate(scenario(MINIMAL), bounds("{" + WIDGETS + "}"));
        assertEquals(2, f.size(), f.toString());
        assertTrue(f.get(0).contains("'t'") && f.get(1).contains("'window'"), f.toString());
    }

    @Test
    @DisplayName("a scenario that is not JSON fails once, with the parser's reason")
    void notJson() throws Exception {
        List<String> f = validate(scenario("{ this is not json"),
                bounds("{\"t\":1,\"window\":[800,600]," + WIDGETS + "}"));
        assertEquals(1, f.size(), f.toString());
        assertTrue(f.get(0).contains("not readable as JSON"), f.get(0));
    }

    @Test
    @DisplayName("a log with no bounds line fails once and says the guest is not publishing")
    void noBoundsLine() throws Exception {
        Path log = tmp.resolve("empty.log");
        Files.writeString(log, "host output only\n");
        List<String> f = validate(scenario(MINIMAL), log);
        assertEquals(1, f.size(), f.toString());
        assertTrue(f.get(0).contains("publishing bounds lines"), f.get(0));
    }
}
