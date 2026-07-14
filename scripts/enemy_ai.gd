# enemy_ai.gd
# Enemy decision-making, split into two swappable halves, chosen per unit
# via Inspector dropdowns (see unit.gd's "Enemy AI" export group):
#   • movement trigger — WHETHER the unit commits to moving this turn
#     ("guard" now; later e.g. "advance": always close on nearest player)
#   • combat targeting — WHICH player unit it strikes among those in reach
#     ("default" now; later e.g. "default_retreating_when_injured")
# Adding a strategy = add the name to the unit.gd enum + a case here.
# Thieves, bosses, and reinforcements become combinations of these.
#
# Strategies are pure decisions — no state changes, no animation. main.gd
# executes the returned action, so AI attacks resolve through the exact
# same combat path as player attacks.

class_name EnemyAI

const PASS : Dictionary = {"type": "pass"}

## Decides one unit's action for this phase. board is main.gd, used for
## map queries. Returns one of:
##   {"type": "pass"}                                     — hold position
##   {"type": "attack", "target": Area2D, "launch": Vector2i}
static func decide(unit: Area2D, board: Node2D) -> Dictionary:
    # Player units this unit could strike this turn (target cell → cell
    # to attack from), movement included.
    var candidates : Dictionary = board._get_attack_targets(unit, board._get_reach_costs(unit))

    # ── Half 1: movement trigger ───────────────────────────────────────
    match unit.ai_movement:
        "guard":
            # Grunt default: hold position until a player unit enters
            # attack range, then engage.
            if candidates.is_empty():
                return PASS
        _:
            push_warning("Unknown ai_movement '%s' on %s" % [unit.ai_movement, unit.name])
            return PASS

    # ── Half 2: combat targeting ───────────────────────────────────────
    match unit.ai_targeting:
        "default":
            # Grunt default: priority can-kill → most damage → lowest hp
            # → closest, so target choice never falls to arbitrary
            # registration order.
            var best_cell : Variant = null
            for cell in candidates:
                if best_cell == null or _target_beats(unit, board, cell, best_cell):
                    best_cell = cell
            return {
                "type"   : "attack",
                "target" : board.unit_map[best_cell],
                "launch" : candidates[best_cell],
            }
        _:
            push_warning("Unknown ai_targeting '%s' on %s" % [unit.ai_targeting, unit.name])
            return PASS

## True when candidate cell a is a strictly better target than b:
## can-kill, then more damage dealt, then lower hp, then closer by
## Manhattan distance. Damage comes from board._attack_damage(), so the
## kill/damage tiers sharpen automatically once rpg stats vary it (with
## today's flat 1 they only ever tie). A full tie keeps the earlier
## candidate — stable placement order.
static func _target_beats(unit, board: Node2D, a: Vector2i, b: Vector2i) -> bool:
    var unit_a = board.unit_map[a]
    var unit_b = board.unit_map[b]
    var dmg_a  : int  = board._attack_damage(unit, unit_a)
    var dmg_b  : int  = board._attack_damage(unit, unit_b)
    var kill_a : bool = dmg_a >= unit_a.hp
    var kill_b : bool = dmg_b >= unit_b.hp
    if kill_a != kill_b:
        return kill_a
    if dmg_a != dmg_b:
        return dmg_a > dmg_b
    if unit_a.hp != unit_b.hp:
        return unit_a.hp < unit_b.hp
    var dist_a : int = absi(a.x - unit.cell.x) + absi(a.y - unit.cell.y)
    var dist_b : int = absi(b.x - unit.cell.x) + absi(b.y - unit.cell.y)
    return dist_a < dist_b
