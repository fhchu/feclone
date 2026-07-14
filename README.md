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
   - **Max Hp** — health (the bar under the unit; blue/red by team,
     dark grey for missing health)
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

Clicking a unit opens a small action menu beside it — **Wait** ends the
unit's turn without moving (undoable like everything else). Items and
weapon selection will join that menu later. Selecting another unit, or
anything that deselects, closes it.

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

When a player unit is selected, enemies it can reach glow red. Dropping
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
