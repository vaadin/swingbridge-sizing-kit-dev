# Test fixtures: six real round-2 cells

Unmodified cell logs and monitor CSVs from `vaadin-swing-bridge@mem-opt-load-v2`
(`swing-bridge-memory-harness/reports/`), used by `testRunReport.sh` so the report
generator is exercised against what the harness actually writes rather than a
fabrication. JOSM on the round-2 rig, 4 GiB budget:

| cell | role in the test | what it is |
|---|---|---|
| `20260910120305 … 2500m` | grid | eligible, 34 healthy — round 2's outlier, a step assertion failed at 35 |
| `20260911104905 … 2560m` | grid | eligible, 38 healthy, memory at 100 % |
| `20260910232410 … 2625m` | grid | **kernel killed the server** at 39 — disqualified under D-001 |
| `20260911080704 … 2560m` | repeat 1 | eligible, 39 |
| `20260911083610 … 2560m` | repeat 2 | eligible, 41 |
| `20260911091231 … 2560m` | repeat 3 | eligible, 39 — so the test's headline is the median, 39 |

Publication gate: these carry the round-2 rig's addresses and paths. Scrub or replace
before the public snapshot (PLAN.md §5.6).
