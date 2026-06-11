# AGENTS.md

Guidance for AI agents and contributors working in this repo.

## ⭐ The one rule: keep tests in sync with scripts

**Whenever you change anything under `scripts/`, add or update the matching
unit tests under `test/unit/`, and run the suite before committing or
pushing.** New behaviour needs a new test; changed behaviour needs an updated
test. A change is not done until `tools/run_godot_tests.sh` passes.

The pre-push hook and CI both run the suite, so untested changes will be caught
— but write the tests as part of the change, not after the gate fails.

## What this project is

`feclone` is a Fire-Emblem-style tactics game built in **Godot 4.6** (GDScript,
GL Compatibility renderer). Levels are authored entirely in the editor; the
code is deliberately small. See `README.md` for the level-design guide.

## Architecture (where logic lives)

Three scripts under `scripts/`, each with a single clear job:

- **`main.gd`** (root `Node2D`) — owns *all* game state and rules: the
  `unit_map`, selection state, the BFS movement-range flood-fill
  (`_get_reachable_cells` / `_in_bounds` / `_terrain_cost`), move application,
  and the undo stack. This is the highest-value code to test.
- **`unit.gd`** (`@tool` `Area2D`) — a "dumb" unit node. It handles sprite
  selection and drag/drop input and **only emits signals** (`drag_started`,
  `drop_attempted`, `clicked`, …); it knows no game rules. `main.gd` makes every
  decision. `@tool` so designers get live sprite feedback in the editor.
- **`grid.gd`** (`TileMapLayer`) — pure overlay rendering: tracks and draws the
  movement range and hover highlight. No game state.

Key conventions:
- Terrain movement cost is data, not code: it comes from the Ground TileSet's
  `move_cost` custom data layer (grass 1, forest 2). New terrain = a TileSet
  edit, not a code change.
- A cell is "on the map" iff the designer painted Ground there
  (`get_cell_source_id != -1`).
- Keep rules out of `unit.gd` and `grid.gd`; they belong in `main.gd`.

## Running the tests

Tests use **GUT** (Godot Unit Test, vendored at `addons/gut/`). They live in
`test/unit/`; in-code map/TileSet fixtures are in `test/fixtures/`.

Point the tooling at your Godot binary, then run the suite:

```sh
export GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"   # your install
./tools/run_godot_tests.sh
```

`run_godot_tests.sh` finds Godot (`$GODOT_BIN`, else `godot`/`godot4` on PATH),
imports the project, runs GUT, and fails on a failed assertion **or** a test
script that won't load. Without Godot it skips with a warning (so a push isn't
blocked); pass `--require` to make a missing Godot a hard error (CI uses this).

To run GUT directly: `"$GODOT_BIN" --headless -s addons/gut/gut_cmdln.gd -gexit`
(options come from `.gutconfig.json`).

## Where the gate runs

- **Pre-push hook** (`lefthook.yml`): runs the suite on every `git push`.
  Install once per clone with `./tools/setup-hooks.sh` (installs lefthook if
  needed, then `lefthook install`).
- **CI** (`.github/workflows/tests.yml`): runs on every pull request and on
  pushes to `main`, via `chickensoft-games/setup-godot` (Godot 4.6.3).

## Gotchas

- **Indentation: tabs only.** GDScript rejects mixing tabs and spaces in a file
  on a clean/headless load (the editor hides this with a cached compile, so it
  can pass locally yet break CI, exports, and fresh clones). All scripts use
  tabs — keep it that way.
- **`@tool` scripts** (`unit.gd`) run in the editor. Guard editor-only paths
  with `Engine.is_editor_hint()` and runtime wiring with `is_node_ready()`.
- **Import before headless runs.** A fresh checkout must
  `godot --headless --import` once before tests can load scenes/textures;
  `run_godot_tests.sh` does this for you.
- **Godot binary discovery.** If Godot was launched from a DMG/Downloads it may
  run from a temporary macOS "App Translocation" path that changes each launch.
  Move `Godot.app` into `/Applications` and set `GODOT_BIN` to a stable path.

## Engine version

Godot **4.6** (`project.godot` → `config/features`). CI pins 4.6.3; keep these
in step when upgrading the engine.
