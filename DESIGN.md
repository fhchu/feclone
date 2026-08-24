# feclone — design & authoring manual

The working reference for the project: what exists, where it lives, and
how to add to it. Written so that a new contributor (human or agent) can
pick the project up and keep building without reading all of `main.gd`
first.

The short version for visitors is in [README.md](README.md).

---

## Code map

The game is a **persistent shell** plus **content-only levels**.

| File | Role |
| --- | --- |
| `scenes/game.tscn` | The shell: board logic, overlay, camera, and every piece of UI. Loaded once and never swapped. |
| `scripts/main.gd` | Attached to the shell. Board state, turn flow, combat, undo, and all menu wiring. The big file — everything stateful lives here. |
| `scenes/levels/*.tscn` | Designer content only: a `Ground` terrain layer, a `Units` node, and per-level exports. No UI, no logic. |
| `scripts/level.gd` | Root script of a level scene — just the metadata exports (`loss_conditions`, `music`). |
| `scenes/unit.tscn` / `scripts/unit.gd` | One unit. `@tool`, so class/team/sprite update live in the editor. Handles input and hover; knows no rules, and signals `main.gd` for every decision. |
| `scripts/grid.gd` | The Overlay TileMapLayer. Pure rendering of the blue movement / red attack tiles. |
| `scripts/danger_layer.gd` | Custom-drawn enemy threat display (hover preview + the merged danger union with its outer-boundary outline). Draws only; `main.gd` owns the data. |
| `scripts/enemy_ai.gd` | Enemy decisions, split into a movement half and a targeting half. Pure functions — `main.gd` executes what they return, so AI attacks resolve through the same combat path as the player's. |
| `scripts/class_stats.gd` | **Balance file.** Per-class stats, movement groups, and the terrain cost tables. Nothing else knows these numbers. |
| `scripts/items.gd` | **Balance file.** Every item, weapon, and staff, keyed by inventory id. |
| `scripts/skills.gd` | **Balance file.** Every skill, keyed by the ids classes list in `class_stats.gd`. |
| `scripts/levels.gd` | The level registry, in play order. Level select and level progression both read it. |
| `scripts/loss_conditions.gd` | Defeat checks, evaluated after every death. |
| `scripts/level_select.gd` | The level grid screen. |
| `scripts/ui_sfx.gd` | Autoload (`UiSfx`). Hooks the click sound to every button in the tree automatically. |
| `assets/ground_tiles.tres` | Shared terrain TileSet — new terrain types are one edit that every map inherits. |
| `assets/overlay_tiles.tres` | The movement/attack overlay TileSet. |

Two rules the layout depends on:

- **UI changes never touch level files.** All UI lives once in the shell,
  so level diffs stay pure content.
- **Registries over special cases.** Classes, items, skills, levels, and
  loss conditions are each one table plus a dispatch on the keys an
  entry carries. Adding content should mean adding a row, not a branch.

### Running the project

Open the project folder in Godot 4.7 and press play, or from the command
line with `godot` on your `PATH`:

```bash
godot --path .
```

A headless smoke test (boots, loads level 1, exits):

```bash
godot --headless --path . --quit-after 10
```

A headless run that played any audio — which now includes every boot,
since level music starts immediately — ends with `ObjectDB instances
were leaked` / `resources still in use` warnings naming the audio
streams. That is a headless-only artifact: the dummy audio driver never
runs the mix pass that releases playbacks. Windowed runs exit clean.

---

## Level design guide (no programming required)

Levels live in `scenes/levels/` (`level1.tscn`, `level2.tscn`, …) and
contain only designer content: a **Ground** terrain layer, a **Units**
node with the placed units, and per-level metadata (like **Loss
Conditions**) on the Level root. All UI and game logic live once in
`scenes/game.tscn`, which loads levels into itself — so UI changes never
touch level files, and level diffs are pure content. The tile sets are
shared resources (`assets/ground_tiles.tres`), so new terrain types are
one edit that every map inherits.

To add a level: duplicate an existing level scene, edit it, and add its
path to the list in `scripts/levels.gd` — the level select grid and the
next-level progression both follow that list automatically.

Defeating every enemy clears the level and loads the next one (the
level select screen after the last). The **Settings** button in the
bottom-right corner opens a menu with Restart Level and Level Select.

Losing triggers a Game Over screen with Undo Last Move / Restart /
Level Select. Which defeats apply is per level: the **Loss Conditions**
list on the level scene's root node names them (just `all_units_dead`
for now; things like `lord_dies` come later — see
`scripts/loss_conditions.gd`). A level can stack several; any one of
them ends it.

Every level loops the shared battle theme. To give a map its own song
(a desert theme, say), drop an audio file into the **Music** slot on
the level scene's root node — empty means the default.

Everything below happens in the Godot editor, inside a level scene.

### Painting terrain

1. Select the **Ground** node in the Scene dock.
2. The **TileMap** panel opens at the bottom — pick the grass or forest
   tile and paint. Right-click erases.
3. Unpainted cells are *off the map*: units can never enter them. The map
   does not have to be rectangular — paint any shape you like.

Every tile names its terrain (a `terrain` custom data string on the
shared TileSet: "plains", "forest"; "mountain" is reserved). What that
terrain *costs* depends on the moving unit's class: classes belong to
movement groups (infantry / mounted / magic / flying) and each group
has its own price table — infantry crosses forest for 2, cavalry pays
3, so a 7-move cavalier clears two forests and a plain but not three
forests. All of it lives in one balance file, `scripts/class_stats.gd`
(`MOVE_COSTS` for the group price tables, `move_type` on each class),
safe to edit freely: unknown terrain names cost 1, and `IMPASSABLE`
prices a terrain out entirely for a group (mounted vs mountains).
Fliers (the pegasus knight) pay 1 for everything — the planned walls
terrain will be their one exception.
Adding a new terrain type is: add its art and tile, set the tile's
`terrain` string, and add a column to the `MOVE_COSTS` rows.

### Placing and moving units

1. In the FileSystem dock, drag `scenes/unit.tscn` onto the **Units**
   node (or right-click Units → *Instantiate Child Scene*).
2. Drag the unit over the tile where it should start — units snap
   themselves to tile centres while you drag them in the editor (in
   every level, no snap configuration needed), and the game re-snaps
   on load regardless.
3. With the unit selected, set its properties in the Inspector:
   - **Unit Class** — lord, archer, cleric, cavalier, knight, mage,
     pegasus knight, soldier (the sprite updates immediately in the
     editor)
   - **Sprite Variant** — male/female, for classes that offer both
     (currently the lord)
   - **Character Name** — optional unique name ("Lyon"); empty units
     display their class name
   - **Team** — blue (player) or red (enemy)
   - **Max Hp** — health (the bar under the unit; blue/red by team,
     dark grey for missing health)
   - **Attack / Def / Magic / Res** — the two combat stat pairs (see
     Combat below)
   - **Aptitude / Max Sp** — SP generation and ceiling (see Skills)
   - **Inventory** — item ids from `scripts/items.gd`
4. Name unit nodes as neutral IDs (`Enemy1`, `Ally2`), never after
   their class — names are save/undo keys and must stay meaningful
   when you later re-class a squad. Names must be unique within a
   level and shouldn't change once a level ships.
5. To move a unit's starting position later, just drag it in the
   viewport.

Movement and sprites are class data, not per-unit settings: lords move
5, cavaliers 7, knights 4, soldiers 5 (see `scripts/class_stats.gd` —
tune classes, add stats, or point classes at sprite columns there).

Red units can't be controlled by the player and block movement.

### Phases

Play alternates between **Player Phase** (blue banner) and **Enemy
Phase** (red banner). Each unit acts once per phase — moving or
attacking ends its turn and greys it out until the next phase. When
every unit on a team has acted, the phase flips automatically. During
the enemy phase each red unit acts on its own (see Enemy AI below).

The **Undo** button opens the history browser: a left-side list of
every player action ("Cavalier attacks Knight", "Lord waits") with a
"— Turn N —" marker at each round, back to the start of the map.
Clicking an entry previews that board state; **Confirm** jumps there
for real (discarding what came after), **Cancel** — or re-clicking the
Undo button — returns to the present. Enemy responses belong to the
player action that provoked them and are never separate entries.

Turns follow the classic FE rhythm: select a unit, move it, then a
centered action menu resolves the turn. **Attack** (top option, only
listed when an enemy is within reach of the new position) switches to
target selection — red squares mark the enemies in range; click one to
strike. The first click on a target raises the **battle forecast** — a
side panel (opposite your unit's half of the map) showing both names
and an HP/Might comparison, blue column for you, red for the enemy —
and a second click on the same enemy commits the attack. Clicking a
different target re-forecasts it; clicking anywhere else returns to
the menu. Attacking an enemy directly from the range view works the
same way: the unit approaches, the forecast raises, and one more click
seals it. **Wait** ends the turn on the spot. Clicking anywhere outside
the menu cancels the whole action — the unit snaps back to where it
started, still selected, as if it had only been clicked. Clicking the
same unit cycles its states: select → in-place menu → back to
selection. A move plus its menu action counts as a single undo step.

The full menu order is **Attack**, **Staff**, **Skills**, **Items**,
**Wait**; entries that don't apply to the unit and its position are
hidden rather than greyed.

Clicking an empty tile with nothing selected opens the map menu, with
**End Turn** as its bottom entry (future commands stack above it) —
handing the round to the enemy with unmoved units staying put. It's a
history entry like any action, so it can be undone or jumped past.

Dropping a dragged unit directly onto a red-fringe enemy still performs
the quick move-and-attack without the menu.

### Enemy AI

Each red unit picks its behaviour from two dropdowns in the Inspector
(**Enemy AI** group), one per half of the decision:

- **Ai Movement** — when the unit commits to moving.
  `guard` (default): holds position until a player unit enters its
  attack range (movement + weapon reach).
  `aggressive`: hunts from turn one — marches along the cheapest path
  toward whichever player unit is fewest movement-turns away, and
  attacks as soon as someone is in reach.
- **Ai Targeting** — who it attacks once engaged.
  `default`: priority is can-kill, then most damage, then least
  health, then closest.

More behaviours (thieves fleeing with loot, bosses holding thrones,
reinforcements rushing the front) will appear in these dropdowns as
they're implemented — mixing the two halves per unit is the point.

Strategies are pure decisions: no state changes, no animation. `main.gd`
executes the returned action, so an AI attack resolves through the exact
same combat path as a player's.

### Display & camera

The window can be resized, maximised, or fullscreened to any
resolution: the 640×640 design space scales up (letterboxed square),
UI text re-renders crisply at the real resolution, and the pixel art
stays hard-edged via nearest-neighbour filtering (pixel-perfect at
integer scales: 1280, 1920, 2560…).

One screen shows exactly a 10×10 map — the minimum map size, filling
the view with no border. Bigger maps scroll: pressing the mouse
against the screen edge pans the camera (the mouse stands in for the
cursor), clamped to the map's edges; the corner buttons sit outside
the thin scroll band, so reaching them never moves the view. Maps
should start at the scene origin and be at least 10 tiles on each axis.

### Pacing

Units walk their movement paths tile-by-tile (player and enemy alike).
To speed the whole game up, select the **Main** node and raise
**Animation Speed** in the Inspector — 1.5 or 2.0 fast-forwards walking,
combat, banners, and enemy pacing uniformly. It ships at 1.0.

### Sound

Every UI button plays the shared select sound when clicked. This is
automatic: a global watcher (`scripts/ui_sfx.gd`, autoloaded as
`UiSfx`) hooks each button as it enters the scene tree, so new buttons
and menus need no wiring. To silence a specific button, give it a
`no_click_sfx` metadata entry in the Inspector.

Combat plays a slash as each blow lands — the strike and, if the
defender survives, the counterattack.

Music: `assets/battle.wav` loops throughout every level (restarts and
same-song level changes don't interrupt it). A level's **Music**
export overrides the track; the loop point is baked into the wav
import settings.

### Unit info

Hovering any unit (either team) shows a neutral greyscale card:
portrait (the map sprite until real portraits exist), name (class name
for now; unique characters get real names later), current/max HP with a
bar, current/max SP with a yellow bar, and the equipped weapon's name.
It sits in the top-left corner, flipping to the top-right when the
hovered unit is on the left half of the screen, so the card never
covers the mouse. It hides while a unit is selected or anything else
owns the screen.

### Danger zones

Hovering any unit — yours or theirs — faintly previews its movement
and strike range. Clicking an enemy (with nothing selected) toggles it
into danger tracking: the unit tints dark red and every tile any
tracked enemy could strike is shaded translucent grey, outlined in red
along the outer boundary only — toggling more enemies merges their
zones into one outline. The **Danger Zone** checkbox (bottom-right,
stacked above the Settings button) displays every enemy's combined
zone at once without tinting anyone, and stays on across levels;
individual tracking works on top of it. Zones update live as units
move or fall.

### Combat

When a player unit is selected, its whole strike range beyond the blue
movement tiles glows red; enemies standing anywhere in that red fringe
can be attacked. Attack range comes from the equipped weapon (the
`range` entry in `scripts/items.gd`): iron swords and lances reach 1,
the iron bow exactly 2 — so a bow can neither attack nor counter an
adjacent enemy, and its red ring skips the four adjacent tiles.

Dropping (or clicking) on a red enemy moves the unit into range and the
two bump at each other: the attacker strikes first, then the defender
counterattacks if it survived and its own weapon reaches back (the
forecast shows `--` for a defender that can't). Damage is the
attacker's **attack** plus weapon might, minus the defender's **def**;
a weapon *effective* against the defender's movement group multiplies
its might first (the iron bow doubles to 12 against fliers), and
defense can only chip damage down to 0, never below. Magic weapons
(`damage_type: "magic"`) swap in the **magic** and **res** stats in
place of attack and def; the **Fire** tome is the first, though it
ships in no level yet — add its id to a unit's inventory to try it.
Crit and a weapon-choice menu come later. Undo reverts a whole
engagement, including deaths.

The equipped weapon is simply the **first weapon in the inventory**.
That rule resolves inventories authored with consumables above the
weapons, and it is what the items menu's Equip command manipulates.

### Items

Units can carry up to five items (`Items.MAX_SLOTS`). When a unit with
any opens its action menu, an **Items** entry appears; it swaps the
menu for the item list (a shorter panel when fewer are carried), with
the equipped weapon marked `(E)`. The × — or clicking anywhere outside
— returns to the action menu with nothing spent.

Clicking a row raises a floating action button beside it, reading
**Equip** for weapons and **Use** for everything else:

- **Equip** is free: the weapon (and its charges) moves to the top of
  the inventory, the panel stays open, and the unit still has its
  action.
- **Use** spends the unit's turn; undo returns both the charge and its
  effect.

Items carry limited uses, shown on their button ("Potion 2/3");
spending the last one removes the item. Levels re-instance their units,
so charges reset every level. Healing items grey out at full health.
One consumable exists so far: the **Potion** — heals 10 (capped at max
hp), three uses per level. Weapons carry no uses; durability is
undecided.

Staffs are their own category, neither weapon nor consumable: they
appear in the item list (name only) but can't be equipped or used
there. Instead, when a unit carrying one has an injured ally within
staff range after moving, a **Staff** entry appears in its action menu
(under Attack); pick it and click the ally — the heal lands on the
first click, no battle forecast, and takes the unit's turn. One staff
exists so far: **Heal** — range 1, restores 8 + half the healer's
attack. Full-health allies are never valid targets, and enemies never
are.

To give a unit items: select it in a level scene and add item ids to
its **Inventory** array in the Inspector. Ids, effects, and use counts
live in `scripts/items.gd` — new items are new entries in that table.

### Skills & SP

SP is this game's own resource, not an FE mechanic. Every unit
generates SP whenever it **strikes or is struck** — its own `aptitude`
stat plus the equipped weapon's `aptitude` entry, on both sides of the
exchange. `max_sp` caps the pool; generation past it is lost. The
hover info card shows the pool as a yellow bar. (The stat name
`aptitude` is provisional.)

Classes know skills, units spend SP on them. `ClassStats.STATS` lists a
class's skill ids under `"skills"`; the definitions live in
`scripts/skills.gd`. A unit whose class knows any gets a **Skills**
entry in its action menu, listing every skill it knows — rows grey out
when the unit can't afford the cost, or (for attack-type skills) when
nothing is in reach to hit.

Choosing an attack-type skill enters the same targeting loop as the
Attack command, tagged with the skill: the forecast badges the blue
Might in yellow, and the SP cost is only spent when the strike
actually commits — so backing out costs nothing, and undoing the
attack refunds it.

One skill exists so far: **Brave Strike** (lord, 10 SP) — its attack
lands two blows instead of one.

Adding a skill is a row in `Skills.DEFS` plus its id in a class's
`"skills"` list; a new *kind* of skill is a new effect key plus its
dispatch in `main.gd`.

---

## Planned / not yet built

Collected from the TODOs scattered through the code, roughly in the
order the rest of the design assumes them:

- **Terrain**: a walls terrain (impassable even to fliers) and mountain
  tiles — `MOVE_COSTS` already prices both.
- **Combat**: crit, a weapon-choice menu, weapon durability, the 1–2
  range weapons that `Items.reach_of`'s `[min, max]` form is there for.
- **Progression**: exp and level-ups (class bases are currently the
  whole story), real character names and portraits.
- **Loss conditions**: `lord_dies`, `npc_unit_dies`, turn limits.
- **Enemy AI**: thieves that flee with loot, bosses that hold thrones,
  reinforcements — each a combination of the two existing dropdowns.
- **Level select**: real map preview thumbnails instead of numbered
  boxes.
