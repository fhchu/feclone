# loss_conditions.gd
# Defeat checks, evaluated after every death. Each level lists the
# conditions that apply to it (the loss_conditions export on Main) and
# several can be active at once — any one of them triggering ends the
# level in defeat. Adding a condition = a name + a case here, then list
# it on whichever levels use it.
# Future entries: "lord_dies", "npc_unit_dies", turn limits…

class_name LossConditions

## True if the named condition is met on the current board.
static func check(condition: String, board: Node2D) -> bool:
    match condition:
        "all_units_dead":
            return board._team_wiped(board.PLAYER_TEAM)
        _:
            push_warning("Unknown loss condition '%s'" % condition)
            return false

## True if any of the level's conditions is met.
static func any_met(conditions: Array, board: Node2D) -> bool:
    for condition in conditions:
        if check(condition, board):
            return true
    return false
