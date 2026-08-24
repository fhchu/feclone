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
    # (see the SP section in main.gd). "range" is the Manhattan
    # distance(s) the weapon strikes at: an int for a single distance,
    # or [min, max] for the 1-2 range swords/lances planned later. The
    # bow's flat 2 means it can neither attack nor counter adjacent.
    # "effective" multiplies the weapon's MIGHT against defenders whose
    # movement group it names (weapon effectiveness — bows punish fliers).
    "iron_sword": {
        "name": "Iron Sword",
        "might": 5,
        "aptitude": 2,
        "range": 1,
    },
    "iron_lance": {
        "name": "Iron Lance",
        "might": 6,
        "aptitude": 1,
        "range": 1,
    },
    "iron_bow": {
        "name": "Iron Bow",
        "might": 6,
        "aptitude": 1,
        "range": 2,
        "effective": {"flying": 2},
    },
    # The first magic weapon: "damage_type": "magic" swaps combat onto
    # the magic/res stat pair (see _attack_damage). Numbers are a
    # placeholder and it ships in no level — it only matters once a unit
    # is actually handed one, so it's here as the working example of the
    # magic/res groundwork, not as balanced content.
    "fire": {
        "name": "Fire",
        "might": 5,
        "aptitude": 2,
        "range": 1,
        "damage_type": "magic",
    },
    # Staffs (marked by "staff" = base healing power) are neither
    # weapons nor use-from-items consumables: they list in the items
    # menu but act through the unit menu's Staff command (main.gd).
    # Reach reuses "range"; no "uses" while durability is undecided,
    # same as weapons.
    "heal": {
        "name": "Heal",
        "staff": 8,
        "range": 1,
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

## Staffs are the items carrying the "staff" key. They are never
## wielded as weapons and never Use-d from the items menu — the unit
## menu's Staff command drives them.
static func is_staff(id: String) -> bool:
    return DEFS.get(id, {}).has("staff")

## Base healing power of a staff (0 for non-staffs); the wielder's
## stats add on top in main.gd's _staff_heal_amount.
static func staff_base(id: String) -> int:
    return DEFS.get(id, {}).get("staff", 0)

## Inventory index of the unit's first staff, or -1 — the staff the
## Staff command wields, mirroring equipped_index's first-weapon rule.
static func staff_index(unit) -> int:
    for i in unit.inventory.size():
        if is_staff(unit.inventory[i]):
            return i
    return -1

## Might multiplier the weapon carries against a defender movement
## group ("effective": {"flying": 2}); 1 whenever nothing applies, so
## callers can pass any id and any group.
static func effectiveness(id: String, move_type: String) -> int:
    return DEFS.get(id, {}).get("effective", {}).get(move_type, 1)

## A weapon's damage type picks the stat pair combat uses: the default
## "physical" pits the wielder's attack against the target's def, while
## "magic" pits magic against res (see _attack_damage in main.gd). The
## Fire tome carries it; another tome is just another such entry.
static func is_magic(id: String) -> bool:
    return DEFS.get(id, {}).get("damage_type", "") == "magic"

## A weapon's reach as a [min, max] pair of Manhattan distances —
## "range" in DEFS is an int (exact distance) or already such a pair.
## Undeclared means melee 1.
static func reach_of(id: String) -> Array:
    var r : Variant = DEFS.get(id, {}).get("range", 1)
    return r if r is Array else [r, r]

## Reach of the unit's equipped weapon. Bare fists are melee 1, so
## unarmed units keep bumping (and counter-bumping) adjacent enemies.
static func reach(unit) -> Array:
    var equipped : int = equipped_index(unit)
    return reach_of(unit.inventory[equipped]) if equipped >= 0 else [1, 1]

## Inventory index of the unit's equipped weapon, or -1 when unarmed.
## The equipped weapon is the FIRST weapon in the inventory — Equip
## moves a weapon to the top, but the rule also resolves inventories
## authored with consumables above the weapons.
static func equipped_index(unit) -> int:
    for i in unit.inventory.size():
        if is_weapon(unit.inventory[i]):
            return i
    return -1
