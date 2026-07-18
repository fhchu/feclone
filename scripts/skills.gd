# skills.gd
# Central registry of skill definitions, keyed by the ids classes list
# in ClassStats ("skills" there). Dict-per-skill like items.gd — main.gd
# dispatches effects from the keys a skill carries; "strikes" (an attack
# that lands extra blows) is the only effect so far. Attack-type skills
# run the normal targeting loop and only spend their SP when the strike
# commits.

class_name Skills

const DEFS : Dictionary = {
    "brave_strike": {
        "name": "Brave Strike",
        "cost": 10,     # SP spent when the attack commits
        "strikes": 2,   # the skill's attack lands this many blows
    },
}

## Display name for an id. Falls back to the raw id so a typo in a class
## skill list shows up on screen instead of crashing.
static func display_name(id: String) -> String:
    return DEFS.get(id, {}).get("name", id)

## SP spent to use the skill.
static func cost(id: String) -> int:
    return DEFS.get(id, {}).get("cost", 0)

## Blows the skill's attack lands (1 = no effect).
static func strikes(id: String) -> int:
    return DEFS.get(id, {}).get("strikes", 1)

## True when the unit can't afford the skill. The skills menu greys
## these out; board-dependent requirements (a target in reach for
## attack-type skills) are main.gd's to check on top.
static func unusable_by(id: String, unit) -> bool:
    return unit.sp < cost(id)
