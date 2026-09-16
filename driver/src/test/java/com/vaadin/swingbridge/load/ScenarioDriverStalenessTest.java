/**
 * Copyright (C) 2026 Vaadin Ltd
 *
 * This program is available under Vaadin Commercial License and Service Terms.
 *
 * See <https://vaadin.com/commercial-license-and-service-terms> for the full
 * license.
 */
package com.vaadin.swingbridge.load;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Staleness is half of the health check, so an arithmetic slip in it fails a
 * healthy set of tenants for a reason that has nothing to do with the server.
 * One did: {@code lastCycleAt} defaulted to 0, {@code now - 0} is the current
 * Unix time, and a 4 GiB cell printed {@code stalest 1789042934143 ms}.
 */
class ScenarioDriverStalenessTest {

    private static final long NOW = 1_789_043_000_000L;

    @Test
    @DisplayName("a worker that cycled recently is barely stale")
    void recentCycle() {
        assertEquals(2_500L, ScenarioDriver.stalenessMs(NOW, NOW - 2_500L));
    }

    @Test
    @DisplayName("a worker stuck for a minute reports a minute")
    void stuckWorker() {
        assertEquals(60_000L, ScenarioDriver.stalenessMs(NOW, NOW - 60_000L));
    }

    @Test
    @DisplayName("cycled this instant is zero, not negative")
    void justCycled() {
        assertEquals(0L, ScenarioDriver.stalenessMs(NOW, NOW));
    }

    @Test
    @DisplayName("an unseeded worker reports 0, never the epoch")
    void unseededIsNotEpoch() {
        // The defect: this returned 1789043000000, and the health check read it
        // as a tenant idle for fifty-six years.
        assertEquals(0L, ScenarioDriver.stalenessMs(NOW, 0L));
    }

    @Test
    @DisplayName("a negative timestamp is also not the epoch")
    void negativeIsNotEpoch() {
        assertEquals(0L, ScenarioDriver.stalenessMs(NOW, -1L));
    }

    @Test
    @DisplayName("a clock stepping backwards clamps to 0, never negative")
    void clockWentBackwards() {
        assertEquals(0L, ScenarioDriver.stalenessMs(NOW, NOW + 5_000L));
    }
}
