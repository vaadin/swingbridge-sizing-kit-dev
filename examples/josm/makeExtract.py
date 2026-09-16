#!/usr/bin/env python3
"""
Generates the deterministic OSM extract the user-behaviour scenario edits.

Why synthetic rather than a real download: every run must start from
byte-identical data, the run must work with networking disabled, and the file
has to be committable. A real extract satisfies none of
those. The *application* is real; only its input data is generated.

Why a street grid rather than random points: the scenario needs things a user can
plausibly do — click a way and have it select, drag to pan over visible geometry,
zoom and see detail change. A grid renders predictably at every zoom level, which
also makes screenshot-based step verification stable.

Determinism: no randomness anywhere. Same output bytes on every run, verified by
the checksum this prints.

Usage:
  ./makeExtract.py > grid.osm
"""
import sys

# Helsinki, near enough to Vaadin's office to be recognisable and far enough from
# (0,0) that JOSM's projection maths behaves like it would on real data.
LAT0, LON0 = 60.1699, 24.9384
STEP = 0.00035          # ~39 m north-south; a city block
N = 24                  # grid is N x N intersections
BUILDINGS_PER_ROW = 9   # closed ways dropped into grid cells
BUILDING_INSET = 0.00009

STREET_NAMES = [
    "Aleksanterinkatu", "Mannerheimintie", "Esplanadi", "Bulevardi",
    "Fredrikinkatu", "Runeberginkatu", "Hämeentie", "Sturenkatu",
    "Topeliuksenkatu", "Mechelininkatu", "Kaisaniemenkatu", "Unioninkatu",
]


def main():
    out = []
    w = out.append
    w('<?xml version="1.0" encoding="UTF-8"?>')
    w('<osm version="0.6" generator="swing-bridge-memory-harness/makeExtract.py">')

    # Bounds first, so JOSM knows the downloaded area and does not treat the
    # layer as a partial edit.
    w('  <bounds minlat="%.7f" minlon="%.7f" maxlat="%.7f" maxlon="%.7f"/>' % (
        LAT0 - STEP, LON0 - STEP,
        LAT0 + (N + 1) * STEP, LON0 + (N + 1) * STEP * 2))

    nid = 1000
    grid = {}
    for r in range(N):
        for c in range(N):
            nid += 1
            grid[(r, c)] = nid
            # Longitude steps twice as far so blocks look roughly square at this
            # latitude, where a degree of longitude is about half a degree of
            # latitude on the ground.
            w('  <node id="%d" version="1" lat="%.7f" lon="%.7f"/>' % (
                nid, LAT0 + r * STEP, LON0 + c * STEP * 2))

    wid = 5000

    def way(node_ids, tags):
        nonlocal wid
        wid += 1
        w('  <way id="%d" version="1">' % wid)
        for n in node_ids:
            w('    <nd ref="%d"/>' % n)
        for k, v in tags:
            w('    <tag k="%s" v="%s"/>' % (k, v))
        w('  </way>')

    # Streets: one way per row and per column, so a click anywhere on a line
    # selects a long object with tags to inspect and edit.
    for r in range(N):
        way([grid[(r, c)] for c in range(N)],
            [("highway", "residential"),
             ("name", "%s %d" % (STREET_NAMES[r % len(STREET_NAMES)], r + 1)),
             ("maxspeed", "30"), ("surface", "asphalt")])
    for c in range(N):
        way([grid[(r, c)] for r in range(N)],
            [("highway", "residential"),
             ("name", "%s kuja %d" % (STREET_NAMES[c % len(STREET_NAMES)], c + 1)),
             ("maxspeed", "30"), ("surface", "asphalt")])

    # Buildings: closed ways inside the blocks. These give the renderer filled
    # areas, which makes a zoom change obvious to a pixel comparison.
    for r in range(N - 1):
        for b in range(BUILDINGS_PER_ROW):
            c = b * 2
            if c + 1 >= N:
                continue
            lat = LAT0 + r * STEP + BUILDING_INSET
            lon = LON0 + c * STEP * 2 + BUILDING_INSET
            h = STEP - 2 * BUILDING_INSET
            corners = []
            for dlat, dlon in ((0, 0), (0, h * 2), (h, h * 2), (h, 0)):
                nid += 1
                corners.append(nid)
                w('  <node id="%d" version="1" lat="%.7f" lon="%.7f"/>' % (
                    nid, lat + dlat, lon + dlon))
            way(corners + [corners[0]],
                [("building", "yes"),
                 ("addr:housenumber", str(1 + 2 * b)),
                 ("addr:street", "%s %d" % (
                     STREET_NAMES[r % len(STREET_NAMES)], r + 1))])

    w('</osm>')
    text = "\n".join(out) + "\n"
    sys.stdout.write(text)
    sys.stderr.write("nodes+ways written; bytes=%d\n" % len(text.encode()))


if __name__ == "__main__":
    main()
