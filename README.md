# feclone

A grid-based tactics game in the Fire Emblem tradition, built in Godot 4
with GDScript.

![Level 1 — a lord selected, with reachable tiles in blue and the strike range beyond them in red](docs/level1.png)

## What it is

You command a small squad on a square grid. Play alternates between
player and enemy phases, and each unit acts once per phase: move, then
pick from an action menu — attack, heal an ally with a staff, spend SP
on a class skill, use an item, or wait.

Selecting a unit floods the map with its options. Blue tiles are where
it can walk — the cost of a tile depends on the terrain *and* on the
unit's movement group, so a cavalier pays 3 to enter a forest that
costs infantry 2, and a pegasus knight flies over both for 1. The red
fringe beyond is what it can hit from there, drawn from the reach of
the weapon it has equipped: swords and lances strike at 1, a bow only
at exactly 2 — never adjacent, not even to counter.

Before you commit, a battle forecast shows the exchange: both weapons,
both HP totals, the damage each side deals, and `--` where a defender
can't strike back. Damage is attack plus weapon might minus the
defender's defense — or magic against resistance for a tome — and a
weapon effective against the target's movement group doubles its might
first. Hovering an enemy previews its threat range; clicking one pins
that range to the map, and pinning several merges them into a single
outlined danger zone, so you can see exactly which tiles are safe before
you step.

Every action is undoable, not just the last one. The Undo button opens a
browser of the whole match — every move and attack, marked off by turn,
back to the first. Click any entry to preview that board, confirm to
jump there for real.

**Built with:** Godot 4.7, GDScript, GL Compatibility renderer. Runs at
a 640×640 design resolution that scales to any window, pixel-perfect at
integer multiples.

## Design goals

The interesting constraint is that **levels contain no code and no UI**.
A level scene is a painted terrain layer, a handful of placed units, and
a few metadata fields — everything else lives once in a persistent game
shell that levels load into. Content is authored entirely in the Godot
editor.

Everything that can be a table is a table. Classes, items, weapons,
staves, skills, levels, and defeat conditions are each one registry file
with one row per entry; the game dispatches on the keys a row carries.
Adding a bow-wielding class, a tome, or a new loss condition is a new
row, not a new branch.

## Running it

Open the project folder in Godot 4.7 and press play, or:

```bash
godot --path .
```

## Documentation

[**DESIGN.md**](DESIGN.md) is the full manual — the code map, how the
systems fit together, how to author a level without programming, and
what's planned but not yet built.

## License

Proprietary. See [LICENSE](LICENSE) — the source is public so it can be
read and evaluated, but it is not open source, and no permission is
granted to copy, modify, or reuse it. The code and the pixel art are
mine and covered by that license; the bundled audio and the default
Godot project icon are third-party works under their own licenses.
