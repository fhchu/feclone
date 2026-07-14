# class_stats.gd
# Base stats per unit class — the single place to touch when adding or
# tuning classes. Fire Emblem derives stats from class bases + level-up
# gains; until exp/levels exist, class bases are the whole story.
# Only mov for now; hp/atk/def/etc. join these dicts later.

class_name ClassStats

# "sprites" maps variant → pieces.png column. Columns can be shared
# between classes (soldier borrows the pawn art until it gets its own)
# and a class can offer several variants (the lord's male/female pair).
const STATS : Dictionary = {
    "lord":     {"mov": 5, "sprites": {"male": 0, "female": 1}},
    "cleric":   {"mov": 5, "sprites": {"male": 2}},   # placeholder class
    "cavalier": {"mov": 7, "sprites": {"male": 3}},
    "knight":   {"mov": 4, "sprites": {"male": 4}},
    "mage":     {"mov": 5, "sprites": {"male": 5}},   # placeholder class
    "soldier":  {"mov": 5, "sprites": {"male": 5}},   # pawn art for now
}

## Movement points for a class.
static func mov(unit_class: String) -> int:
    return STATS[unit_class]["mov"]

## Sprite-sheet column for a class. Classes without the requested
## variant fall back to their first sprite.
static func sprite_col(unit_class: String, variant: String = "male") -> int:
    var sprites : Dictionary = STATS[unit_class]["sprites"]
    if sprites.has(variant):
        return sprites[variant]
    return sprites.values()[0]
