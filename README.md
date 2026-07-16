# feclone

A Fire Emblem-style tactics game, built on art and architecture from the
chess project.

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
list on the Main node names them (just `all_units_dead` for now; things
like `lord_dies` come later — see `scripts/loss_conditions.gd`). A
level can stack several; any one of them ends it.

Everything below happens in the Godot editor, inside a level scene.

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
2. Drag the unit over the tile where it should start — units snap
   themselves to tile centres while you drag them in the editor (in
   every level, no snap configuration needed), and the game re-snaps
   on load regardless.
3. With the unit selected, set its properties in the Inspector:
   - **Unit Class** — lord, cleric, cavalier, knight, mage, soldier
     (the sprite updates immediately in the editor)
   - **Sprite Variant** — male/female, for classes that offer both
     (currently the lord)
   - **Character Name** — optional unique name ("Lyon"); empty units
     display their class name
   - **Team** — blue (player) or red (enemy)
   - **Max Hp** — health (the bar under the unit; blue/red by team,
     dark grey for missing health)
4. Name unit nodes as neutral IDs (`Enemy1`, `Ally2`), never after
   their class — names are save/undo keys and must stay meaningful
   when you later re-class a squad. Names must be unique within a
   level and shouldn't change once a level ships.

Movement and sprites are class data, not per-unit settings: lords move
5, cavaliers 7, knights 4, soldiers 5 (see `scripts/class_stats.gd` —
tune classes, add stats, or point classes at sprite columns there).
4. To move a unit's starting position later, just drag it in the viewport.

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
Undo button — returns to the present. Enemy responses belong to the player action that provoked
them and are never separate entries.

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
seals it. **Wait** ends the turn on the spot. Clicking anywhere outside the menu cancels the whole
action — the unit snaps back to where it started, still selected, as
if it had only been clicked. Clicking the same unit cycles its states:
select → in-place menu → back to selection. A move plus its menu
action counts as a single undo step. Items joins the menu later.

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

### Display & camera

The window can be resized, maximised, or fullscreened to any
resolution: the 640×640 design space scales up (letterboxed square),
UI text re-renders crisply at the real resolution, and the pixel art
stays hard-edged via nearest-neighbour filtering (pixel-perfect at
integer scales: 1280, 1920, 2560…).

One screen shows exactly a 10×10 map — the minimum map size, filling
the view with no border. Bigger maps scroll: moving the mouse into the
outermost two tiles of the screen pans the camera (the mouse stands in
for the cursor), clamped to the map's edges. Maps should start at the
scene origin and be at least 10 tiles on each axis.

### Pacing

Units walk their movement paths tile-by-tile (player and enemy alike).
To speed the whole game up, select the **Main** node and raise
**Animation Speed** in the Inspector — 1.5 or 2.0 fast-forwards walking,
combat, banners, and enemy pacing uniformly. It ships at 1.0.

### Unit info

Hovering any unit (either team) shows a neutral greyscale card in the
top-left corner: portrait (the map sprite until real portraits exist),
name (class name for now; unique characters get real names later), and
current/max hp with a bar. It hides while a unit is selected or
anything else owns the screen.

### Danger zones

Hovering any unit — yours or theirs — faintly previews its movement
and strike range. Clicking an enemy (with nothing selected) toggles it
into danger tracking: the unit tints dark red and every tile any
tracked enemy could strike is shaded translucent grey, outlined in red
along the outer boundary only — toggling more enemies merges their
zones into one outline. The **Danger Zone** checkbox (bottom-right, stacked above
the Settings button; shows an × when on) displays every enemy's
combined zone at once without tinting anyone, and stays on across
levels; individual tracking works on top of it. Zones update live as
units move or fall.

### Combat

When a player unit is selected, its whole strike range beyond the blue
movement tiles glows red; enemies standing anywhere in that red fringe
can be attacked. Dropping
(or clicking) on a red enemy moves the unit next to it and the two bump
into each other: the attacker strikes first, then the defender
counterattacks if it survived. Damage is a flat 1 for now — weapons and
rpg stats (def/crit/…) come later, as does a weapon-choice menu before
the strike. Undo reverts a whole engagement, including deaths.

## Running headless checks

The Godot binary (Steam install):

```
"/Users/felicity/Library/Application Support/Steam/steamapps/common/Godot Engine/Godot.app/Contents/MacOS/Godot" --headless --path . --quit-after 10
```
