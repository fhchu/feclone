# level.gd
# Root of every level scene: only the designer-authored content (Ground
# terrain + Units) plus per-level metadata exports. The game shell
# (scenes/game.tscn) instances one of these under LevelHolder and runs
# the match — levels contain no UI and no game logic.

extends Node2D

## Defeat conditions active on this level — names defined in
## scripts/loss_conditions.gd; any one of them triggering loses the
## level. Several can be listed at once.
@export var loss_conditions : Array[String] = ["all_units_dead"]
