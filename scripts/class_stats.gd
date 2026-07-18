# class_stats.gd
# Base stats per unit class — the single place to touch when adding or
# tuning classes for balance. Fire Emblem derives stats from class
# bases + level-up gains; until exp/levels exist, class bases are the
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
# tiles can't break older groups. Mountain tiles and flying classes
# don't exist yet — their rows are ready for when they do.
const MOVE_COSTS : Dictionary = {
    "infantry": {"plains": 1, "forest": 2, "mountain": 4},
    "mounted":  {"plains": 1, "forest": 3, "mountain": IMPASSABLE},
    "magic":    {"plains": 1, "forest": 2, "mountain": 3},
    "flying":   {"plains": 1, "forest": 1, "mountain": 1},
}

# "sprites" maps variant → pieces.png column. Columns can be shared
# between classes (soldier borrows the pawn art until it gets its own)
# and a class can offer several variants (the lord's male/female pair).
# "skills" lists the class's skill ids (scripts/skills.gd); omitted
# means the class has none.
const STATS : Dictionary = {
    "lord":     {"mov": 5, "move_type": "infantry", "sprites": {"male": 0, "female": 1},
            "skills": ["brave_strike"]},
    "cleric":   {"mov": 5, "move_type": "magic",    "sprites": {"male": 2}},   # placeholder class
    "cavalier": {"mov": 7, "move_type": "mounted",  "sprites": {"male": 3}},
    "knight":   {"mov": 4, "move_type": "infantry", "sprites": {"male": 4}},
    "mage":     {"mov": 5, "move_type": "magic",    "sprites": {"male": 5}},   # placeholder class
    "soldier":  {"mov": 5, "move_type": "infantry", "sprites": {"male": 5}},   # pawn art for now
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

## Sprite-sheet column for a class. Classes without the requested
## variant fall back to their first sprite.
static func sprite_col(unit_class: String, variant: String = "male") -> int:
    var sprites : Dictionary = STATS[unit_class]["sprites"]
    if sprites.has(variant):
        return sprites[variant]
    return sprites.values()[0]
