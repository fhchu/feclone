# class_stats.gd
# Base stats per unit class — the single place to touch when adding or
# tuning classes. Fire Emblem derives stats from class bases + level-up
# gains; until exp/levels exist, class bases are the whole story.
# Only mov for now; hp/atk/def/etc. join these dicts later.

class_name ClassStats

const STATS : Dictionary = {
    "lord":     {"mov": 5},
    "fighter":  {"mov": 5},   # placeholder until the class is used
    "cleric":   {"mov": 5},   # placeholder until the class is used
    "cavalier": {"mov": 7},
    "knight":   {"mov": 4},
    "mage":     {"mov": 5},   # placeholder until the class is used
}

## Movement points for a class.
static func mov(unit_class: String) -> int:
    return STATS[unit_class]["mov"]
