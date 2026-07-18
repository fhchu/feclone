# items.gd
# Central registry of item definitions, keyed by the ids unit
# inventories store (see `inventory` on unit.gd). Dict-per-item so later
# fields (durability uses, price…) slot in beside the existing ones.
# Effects are dispatched by main.gd from the keys an item carries —
# "heal" is used on demand, "might" makes the item a wieldable weapon.

class_name Items

## Item slots a unit can hold; the items menu shows at most this many.
const MAX_SLOTS : int = 5

const DEFS : Dictionary = {
    "potion": {
        "name": "Potion",
        "heal": 10,
        "uses": 3,
    },
    # Weapons carry no "uses" for now — durability is undecided, so the
    # items menu lists them by name alone and nothing consumes charges.
    # "aptitude" is the weapon's share of the wielder's SP generation
    # (see the SP section in main.gd).
    "iron_sword": {
        "name": "Iron Sword",
        "might": 5,
        "aptitude": 2,
    },
    "iron_lance": {
        "name": "Iron Lance",
        "might": 6,
        "aptitude": 1,
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

## Weapons are the items that can be equipped (the "might" key marks
## them). Everything else — potions, future staves — is never wielded;
## it just sits in the inventory until used.
static func is_weapon(id: String) -> bool:
    return DEFS.get(id, {}).has("might")

## Damage the weapon adds on top of its wielder's attack stat (0 for
## non-weapons, so callers can pass any id).
static func might(id: String) -> int:
    return DEFS.get(id, {}).get("might", 0)

## SP the weapon adds to its wielder's per-blow generation, on top of
## the unit's own aptitude stat (0 for non-weapons).
static func aptitude(id: String) -> int:
    return DEFS.get(id, {}).get("aptitude", 0)

## Inventory index of the unit's equipped weapon, or -1 when unarmed.
## The equipped weapon is the FIRST weapon in the inventory — Equip
## moves a weapon to the top, but the rule also resolves inventories
## authored with consumables above the weapons.
static func equipped_index(unit) -> int:
    for i in unit.inventory.size():
        if is_weapon(unit.inventory[i]):
            return i
    return -1
