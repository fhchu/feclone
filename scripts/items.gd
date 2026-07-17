# items.gd
# Central registry of item definitions, keyed by the ids unit
# inventories store (see `inventory` on unit.gd). Dict-per-item so later
# fields (weapon might, durability uses, price…) slot in beside the
# existing ones. Effects are dispatched by main.gd from the keys an item
# carries — "heal" is the only effect so far.

class_name Items

## Item slots a unit can hold; the items menu shows at most this many.
const MAX_SLOTS : int = 5

const DEFS : Dictionary = {
    "potion": {
        "name": "Potion",
        "heal": 10,
        "uses": 3,
    },
}

## Display name for an id. Falls back to the raw id so a typo in a level
## file shows up on screen instead of crashing.
static func display_name(id: String) -> String:
    return DEFS.get(id, {}).get("name", id)

## Health restored on use (0 for items that aren't healing items).
static func heal_amount(id: String) -> int:
    return DEFS.get(id, {}).get("heal", 0)

## Charges an item starts with. Units are re-instanced with their level,
## so this is also the per-level total. Undeclared means single-use.
static func max_uses(id: String) -> int:
    return DEFS.get(id, {}).get("uses", 1)

## True when the unit's state makes the item pointless right now — a
## healing item at full health. The items menu greys these out.
static func unusable_by(id: String, unit) -> bool:
    return heal_amount(id) > 0 and unit.hp >= unit.max_hp
