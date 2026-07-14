# feclone

A Fire Emblem-style tactics game, built on art and architecture from the
chess project.

## Level design guide (no programming required)

Levels live in `scenes/levels/` (`level1.tscn`, `level2.tscn`, …) and
each one is a self-contained scene you edit directly. To add a level:
duplicate an existing level scene, edit it, and add its path to the
list in `scripts/levels.gd` — the level select grid and the
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
2. Drag the unit roughly over the tile where it should start — it snaps
   to the nearest tile centre when the game runs. (For tidy placement,
   enable grid snap: Snapping Options → *Configure Snap* → step 64×64,
   offset 8×8.)
3. With the unit selected, set its properties in the Inspector:
   - **Unit Class** — lord, fighter, cleric, cavalier, knight, mage
     (the sprite updates immediately in the editor)
   - **Team** — blue (player) or red (enemy)
   - **Max Hp** — health (the bar under the unit; blue/red by team,
     dark grey for missing health)

Movement is a class stat, not a per-unit setting: lords move 5,
cavaliers 7, knights 4 (see `scripts/class_stats.gd` — tune classes or
add stats there as the rpg system grows).
4. To move a unit's starting position later, just drag it in the viewport.

Red units can't be controlled by the player and block movement.

### Phases

Play alternates between **Player Phase** (blue banner) and **Enemy
Phase** (red banner). Each unit acts once per phase — moving or
attacking ends its turn and greys it out until the next phase. When
every unit on a team has acted, the phase flips automatically. During
the enemy phase each red unit acts on its own (see Enemy AI below).

Undo steps back through phase changes too. Enemy actions are collapsed
into it: one undo rewinds the enemy's response together with the player
move that provoked it, landing back where it's your input.

Turns follow the classic FE rhythm: select a unit, move it, then a
centered action menu resolves the turn. **Attack** (top option, only
listed when an enemy is within reach of the new position) switches to
target selection — red squares mark the enemies in range; click one to
strike, click anywhere else to return to the menu. **Wait** ends the
turn on the spot. To wait (or attack) without moving, click the
selected unit a second time to open the menu in place. A move plus its
menu action counts as a single undo step. Items joins the menu later.

Dropping a dragged unit directly onto a red-fringe enemy still performs
the quick move-and-attack without the menu.

### Enemy AI

Each red unit picks its behaviour from two dropdowns in the Inspector
(**Enemy AI** group), one per half of the decision:

- **Ai Movement** — when the unit commits to moving.
  `guard` (default): holds position until a player unit enters its
  attack range (movement + weapon reach).
- **Ai Targeting** — who it attacks once engaged.
  `lowest_hp` (default): the player unit in reach with the least health.

More behaviours (thieves fleeing with loot, bosses holding thrones,
reinforcements rushing the front) will appear in these dropdowns as
they're implemented — mixing the two halves per unit is the point.

### Pacing

Units walk their movement paths tile-by-tile (player and enemy alike).
To speed the whole game up, select the **Main** node and raise
**Animation Speed** in the Inspector — 1.5 or 2.0 fast-forwards walking,
combat, banners, and enemy pacing uniformly. It ships at 1.0.

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
