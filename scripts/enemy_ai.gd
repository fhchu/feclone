# enemy_ai.gd
# Enemy decision-making, split into two swappable halves, chosen per unit
# via Inspector dropdowns (see unit.gd's "Enemy AI" export group):
#   • movement trigger — WHETHER the unit commits to moving this turn
#     ("guard" now; later e.g. "advance": always close on nearest player)
#   • combat targeting — WHICH player unit it strikes among those in reach
#     ("lowest_hp" now; later e.g. "lowest_hp_retreating_when_injured")
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
        "lowest_hp":
            # Grunt default: pick off the weakest player unit in reach.
            var best_cell : Variant = null
            for cell in candidates:
                if best_cell == null or board.unit_map[cell].hp < board.unit_map[best_cell].hp:
                    best_cell = cell
            return {
                "type"   : "attack",
                "target" : board.unit_map[best_cell],
                "launch" : candidates[best_cell],
            }
        _:
            push_warning("Unknown ai_targeting '%s' on %s" % [unit.ai_targeting, unit.name])
            return PASS
