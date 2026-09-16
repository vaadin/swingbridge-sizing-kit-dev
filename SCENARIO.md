# The scenario file

A scenario is what one simulated user does, over and over, while the kit adds more users:
a short list of steps — *click here, press this key* — each with the parts of the screen
that must change as a result. The browser driver runs it against your application; a step
counts only if what it declared actually appeared on screen, so the number the kit reports
is a count of users doing real, verified work.

It is one JSON file, named by `SCENARIO` in `harness/harness.env` (the first run of
`runBoxA.sh` sets that to `harness/scenario/app-cycle.json`). `examples/josm/josm-cycle.json`
is a complete real one, with its reasoning in `_comment` fields. Everything below is read
from the driver's source, `driver/src/main/java/com/vaadin/swingbridge/load/ScenarioDriver.java`.

## The other half: what your application publishes

Nothing in a scenario is a pixel coordinate. Your application prints where things are, and
the driver resolves every click and every watched region against that, per user, at run
time. So while it runs, your application prints to standard output one line per update:

```
WIDGET-BOUNDS {"t":1758000000000,"window":[1600,900],"widgets":{"table":[10,60,900,700],"details":[920,60,670,700],"clear":[10,770,120,32],"statusbar":[0,870,1600,30]},"targets":{"row/42":[460,131]}}
```

| field | what | needed |
|---|---|---|
| `t` | a millisecond timestamp | always — the driver waits for a line stamped *after* each gesture, so it never reads a layout that is no longer true |
| `window` | `[width, height]` of your main window, in pixels | always — the driver checks the browser canvas against it to one pixel |
| `widgets` | `{name: [x, y, width, height]}`, rectangles relative to the top-left of your main window | always — points and crops resolve against it |
| `targets` | `{name: [x, y]}`, named points, for things that move (a row, a map object) | only if a point uses `target` |
| `scale` | a number, such as a zoom level | only if a step declares `expectScale` |

Publish every quarter of a second or so, or whenever the layout changes — a daemon thread
that walks the frame for components you gave a `setName()` and prints their bounds is a
few dozen lines. The JOSM example did exactly that as a small source patch
(`examples/josm/PATCH-LEDGER.md`, patch 1). The line must be a single line, and the
marker `WIDGET-BOUNDS ` (with the trailing space) must come right before the JSON.

## The file, line by line

```json
{
  "app": "inventory",
  "window": { "w": 1600, "h": 900 },
  "boundsMarker": "WIDGET-BOUNDS ",

  "points": {
    "firstRow":    { "widget": "table", "at": [0.5, 0.10] },
    "secondRow":   { "widget": "table", "at": [0.5, 0.18] },
    "clearButton": { "widget": "clear" },
    "park":        { "widget": "statusbar", "at": [0.5, 0.5] }
  },

  "crops": {
    "table":   { "widget": "table", "inset": 4 },
    "details": { "widget": "details" }
  },

  "cycle": [
    { "id": "open-first",  "action": "click", "at": "firstRow",    "expect": ["details"],          "settleMs": 700,
      "why": "selecting a row fills the details panel" },
    { "id": "open-second", "action": "click", "at": "secondRow",   "expect": ["details"],          "settleMs": 700,
      "why": "a different row: the panel must change again" },
    { "id": "clear",       "action": "click", "at": "clearButton", "expect": ["details", "table"], "settleMs": 700,
      "why": "back to the start: nothing selected, panel empty" }
  ]
}
```

**Top level**

- `app` — a name, printed at the start of each run.
- `window` — the window size the points were written for. For your reader; the driver
  checks the canvas against the `window` your application publishes, not this.
- `boundsMarker` — the text before the JSON on each published line. Default `WIDGET-BOUNDS `.
- `scaleTolerance` — relative tolerance for `expectScale` (default `0.02`, i.e. 2 %).
- `waitForChangeMs` — how long a step may take for its declared regions to change before
  it fails (default `8000`). Under load this is the time being measured; it is not a
  setting to tune upwards.

**`points`** — named places to click or aim a keystroke at. Two forms:

- `{ "widget": "<name>", "at": [fx, fy] }` — a fraction inside a published rectangle:
  `[0.5, 0.5]` is its centre (the default), `[0.5, 0.10]` a tenth of the way down. Add
  `"offsetPx": [dx, dy]` for a pixel nudge on top.
- `{ "target": "<name>" }` — a point your application publishes under `targets`, for things
  whose position depends on data or zoom. The driver waits until every target the scenario
  names has been published before it starts a user.

Two names are special. **`park`** (optional) is where the pointer rests before each at-rest
snapshot, so a hover highlight cannot be mistaken for leftover state; put it on something
inert, such as a status bar. Points named **`emptyMap`** and **`mapCentre`** are needed
only by the JOSM-era probe that drives one guest at a time; the kit's ramp does not use it.

**`crops`** — named regions to watch: `{ "widget": "<name>", "inset": <px> }`, the
rectangle shrunk by `inset` on each side (default 0), so a border repaint does not count
as a change.

**`cycle`** — the steps, in order, repeated for as long as the user is running. Each step:

| key | meaning |
|---|---|
| `id` | a short name, in the logs and the report |
| `action` | `click`, `key` or `wheel` |
| `at` | the point to act at (for `key`, the pointer is moved there first, then the key is pressed) |
| `key` | for `key`: a Playwright key name — `Enter`, `Escape`, `Tab`, `ArrowDown`, `F5`, `NumpadAdd`, `a`, `Control+a` |
| `notches` | for `wheel`: signed number of wheel notches, one event per notch |
| `repeat` | do the gesture this many times, 250 ms apart (default 1) |
| `expect` | the crops that **must all change**; the step fails if any of them does not within `waitForChangeMs`. Other crops may change too |
| `settleMs` | the quiet time after the gesture before the next step (default 500). With an empty `expect` the step just waits this long (default 700) |
| `expectScale` | for zoom steps: the factor your published `scale` must change by, within `scaleTolerance` |
| `why` | free text for the reader; the driver ignores it |

**`setup`** (optional) — steps in the same form, run once per user before its first cycle,
after which every point is resolved again. For a gesture that must happen once, such as
dismissing a welcome screen or zooming out to make room.

## How a step is judged

Before the gesture the driver hashes the pixels of every crop in the browser; after it, it
polls until every crop in `expect` differs, and records how long that took. A step passes
if they all changed in time (and, with `expectScale`, the published scale moved by the
declared factor). After each full cycle the pointer is parked and every crop is compared
with the very first snapshot; differences are printed as drift so you can see a scenario
that does not put the application back where it found it.

The quality bar for the whole set of users is built from these timings, measured against
the first user alone: the slowest step across all users may not exceed three times the
single-user step time (floor 750 ms), and no user may go without completing a cycle for
longer than six times the single-user cycle time. So the scenario needs no thresholds of
its own; keep the steps honest and the bar calibrates itself.

## Writing a good one

- **Every step must change something visible**, and declare it. A step with an empty
  `expect` proves nothing; a step that "passes" because a hover highlight moved proves the
  wrong thing (the JOSM file's `_comment` records one such case).
- **End where you began.** The cycle repeats for the life of the user. A cycle that opens
  a window and never closes it, or adds a row every time, measures a growing application.
- **No menus, no dialogs, no window close.** A modal dialog no one can answer stalls the
  user; closing the main window can end the whole shared server. Prefer keystrokes to the
  mouse wheel for zooming: a keystroke is a discrete, deterministic event.
- **Seven steps and a few seconds per cycle** is the scale the kit was built with. Longer
  cycles slow the ramp; shorter ones make the bar jittery.
- **Pin the window size** in your application (a `--geometry`-style argument, or code),
  and keep it at or under 1920x1080: the browser viewport is 2240x1200 and a larger guest
  window is clipped.

## Check it before the first long run

Start your application once on its own, so it prints at least one `WIDGET-BOUNDS` line,
and save the output:

```
java -jar yourapp.jar > /tmp/bounds.log 2>&1    # interact until the layout is complete, then quit
SIZING_BOUNDS_SAMPLE=/tmp/bounds.log ./runBoxA.sh
```

`runBoxA.sh` then runs the driver's `--validate`: it parses the scenario, checks the five
fields of your line, resolves every point and every crop against it, and checks every step
names known points and crops and declares a `key` or `notches` where its action needs one —
in seconds, with no browser and no load. Without a sample, the first single-user cell is
the check, and a bad scenario shows up there as a user that cannot start.

## Rarely needed

- `"perCycle": [dx, dy]` and `"perCycleWrap": n` on a point move it by a pixel offset per
  cycle, for a step that must not land on the same spot twice (drawing, for instance).
- `"expectDataPerCycle": { "<counter>": <delta> }` at the top level, with your application
  publishing `"data": {"<counter>": n}` in its bounds line, asserts that each cycle changed
  a counter by exactly that much; a step marked `"provenBy": "data"` is then allowed to miss
  its pixel change if the counters prove the work.
