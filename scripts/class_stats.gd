# class_stats.gd
# Base stats per unit class — the single place to touch when adding or
# tuning classes for balance. The genre derives stats from class bases
# + level-up gains; until exp and levels exist, class bases are the
# whole story. Movement terrain costs live here too: each class belongs
# to a movement type group, and each group has its own price per
# terrain. Nothing else in the codebase knows these numbers.

class_name ClassStats

## A terrain cost no unit can afford — the tile is impassable for that
## movement group.
const IMPASSABLE : int = 99

# What each movement group pays to ENTER a tile of each terrain.
# Terrain names match the "terrain" custom data on the ground TileSet
# (assets/ground_tiles.tres). Unknown/unlisted terrain costs 1, so new
# tiles can't break older groups. Mountain tiles don't exist yet —
# their column is ready for when they do. Flying pays 1 for everything;
# the planned walls terrain will be its one exception (impassable even
# from the air).
const MOVE_COSTS : Dictionary = {
    "infantry": {"plains": 1, "forest": 2, "mountain": 4},
    "mounted":  {"plains": 1, "forest": 3, "mountain": IMPASSABLE},
    "magic":    {"plains": 1, "forest": 2, "mountain": 3},
    "flying":   {"plains": 1, "forest": 1, "mountain": 1},
}

# "sprites" maps variant → sprites_unit_map.png cell. The sheet is
# stacked blue/red row-PAIRS: a bare int is a column on the first pair,
# a Vector2i is (column, pair) for art on the lower pairs — the
# archer's (0, 1) is the first column of the second blue/red pair.
# Cells can be shared between classes (soldier and mage sit on the
# same cell until the soldier gets its own) and a class can offer
# several variants (the lord's male/female pair).
# "skills" lists the class's skill ids (scripts/skills.gd); omitted
# means the class has none.
const STATS : Dictionary = {
    "lord":     {"mov": 5, "move_type": "infantry", "sprites": {"male": 0, "female": 1},
            "skills": ["brave_strike"]},
    "archer":   {"mov": 5, "move_type": "infantry", "sprites": {"male": Vector2i(0, 1)}},
    "cleric":   {"mov": 5, "move_type": "magic",    "sprites": {"male": 2}},   # placeholder class
    "cavalier": {"mov": 7, "move_type": "mounted",  "sprites": {"male": 3}},
    "knight":   {"mov": 4, "move_type": "infantry", "sprites": {"male": 4}},
    "mage":     {"mov": 5, "move_type": "magic",    "sprites": {"male": 5}},   # placeholder class
    "pegasus_knight": {"mov": 7, "move_type": "flying", "sprites": {"male": Vector2i(1, 1)}},
    "soldier":  {"mov": 5, "move_type": "infantry", "sprites": {"male": 5}},   # borrowed art for now
}

## Movement points for a class.
static func mov(unit_class: String) -> int:
    return STATS[unit_class]["mov"]

## The movement group a class belongs to.
static func move_type(unit_class: String) -> String:
    return STATS[unit_class]["move_type"]

## What this class pays to enter the named terrain.
static func terrain_cost(unit_class: String, terrain: String) -> int:
    return MOVE_COSTS[move_type(unit_class)].get(terrain, 1)

## Skill ids a class knows (definitions in scripts/skills.gd); most
## classes have none yet.
static func skills(unit_class: String) -> Array:
    return STATS[unit_class].get("skills", [])

## Sprite-sheet cell for a class as (column, row-pair index). Classes
## without the requested variant fall back to their first sprite.
static func sprite_cell(unit_class: String, variant: String = "male") -> Vector2i:
    var sprites : Dictionary = STATS[unit_class]["sprites"]
    var value : Variant = sprites[variant] if sprites.has(variant) else sprites.values()[0]
    return value if value is Vector2i else Vector2i(value, 0)
