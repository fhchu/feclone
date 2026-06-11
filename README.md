# feclone

A Fire Emblem-style tactics game, built on art and architecture from the
chess project.

## Level design guide (no programming required)

Everything below happens in the Godot editor, inside `scenes/main.tscn`.

### Painting terrain

1. Select the **Ground** node in the Scene dock.
2. The **TileMap** panel opens at the bottom — pick the grass or forest
   tile and paint. Right-click erases.
3. Unpainted cells are *off the map*: units can never enter them. The map
   does not have to be rectangular — paint any shape you like.

Movement cost lives on the tiles themselves: select the Ground node →
Inspector → **Tile Set** → **Paint** tab → choose the `move_cost` custom
data layer to view or change costs per tile (grass = 1, forest = 2).
Adding a brand-new terrain type is: add its art to
`assets/base_tiles.png`, add the tile in the TileSet editor, set its
`move_cost` — no code.

### Placing and moving units

1. In the FileSystem dock, drag `scenes/unit.tscn` onto the **Units**
   node (or right-click Units → *Instantiate Child Scene*).
2. Drag the unit roughly over the tile where it should start — it snaps
   to the nearest tile centre when the game runs. (For tidy placement,
   enable grid snap: Snapping Options → *Configure Snap* → step 64×64,
   offset 8×8.)
3. With the unit selected, set its properties in the Inspector:
   - **Unit Class** — lord, fighter, cleric, cavalier, soldier, mage
     (the sprite updates immediately in the editor)
   - **Team** — blue (player) or red (enemy)
   - **Move Range** — how many movement points it gets per move
4. To move a unit's starting position later, just drag it in the viewport.

Red units can't be controlled by the player and block movement. Combat
comes later.

## Running tests

Unit tests use [GUT](https://github.com/bitwes/Gut) (vendored at `addons/gut/`)
and live in `test/unit/`. Point the tooling at your Godot binary and run them:

```sh
export GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"   # your install
./tools/run_godot_tests.sh
```

The suite also runs automatically:

- **Before every push** — install the git hook once per clone with
  `./tools/setup-hooks.sh` (installs [lefthook](https://lefthook.dev) if needed,
  then `lefthook install`).
- **On every pull request and push to `main`** — via GitHub Actions
  (`.github/workflows/tests.yml`).

> Always update the tests when you change anything under `scripts/`. See
> [AGENTS.md](AGENTS.md) for the project's conventions and architecture.

## Running headless checks

Smoke-run the game headless (replace the path with your Godot install, or use
`$GODOT_BIN`):

```sh
"$GODOT_BIN" --headless --path . --quit-after 10
```
