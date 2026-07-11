# main.gd
# Root Node2D. Owns all game state and coordinates unit nodes and the
# Overlay display. Mirrors the structure of chess main.gd:
#   piece_map → unit_map, legal_moves → reachable_cells,
#   captures → melee combat, and the same undo-snapshot pattern.
#
# Levels are authored entirely in the editor — no code changes needed:
#   • Terrain: paint the Ground TileMapLayer with the TileMap editor.
#     Movement cost comes from the TileSet's "move_cost" custom data
#     (grass 1, forest 2). Unpainted cells are off the map.
#   • Units:   instance unit.tscn under Units, drag it over a tile, and
#     set class/team/move range/max hp in the Inspector. _ready() snaps
#     each placed unit to its nearest cell and registers it.

extends Node2D

# ── Scene references ───────────────────────────────────────────────────────────
@onready var ground      : TileMapLayer = $Ground
@onready var overlay     : TileMapLayer = $Overlay
@onready var units_node  : Node2D       = $Units
@onready var turn_label  : Label        = $UI/TurnLabel
@onready var undo_button : Button       = $UI/UndoButton

const PLAYER_TEAM : String = "blue"

const ORTHO_DIRS : Array = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

# ── Game state ─────────────────────────────────────────────────────────────────
# Maps Vector2i cell → Area2D unit node. Always the source of truth for
# which cell each unit occupies. Defeated units are removed.
var unit_map : Dictionary = {}

# ── Selection state ────────────────────────────────────────────────────────────
var selected_unit       : Variant    = null  # Area2D node or null (drag in progress)
var click_selected_unit : Variant    = null  # Area2D node or null (click-to-move)
var reachable_cells     : Array      = []    # Vector2i cells the unit can end on
var attack_targets      : Dictionary = {}    # enemy cell → cell to attack from

# ── Undo stack ─────────────────────────────────────────────────────────────────
var undo_stack : Array = []

# ── Setup ──────────────────────────────────────────────────────────────────────

func _ready() -> void:
    overlay.overlay_alpha = 0.5
    _register_placed_units()
    undo_button.disabled = true
    undo_button.pressed.connect(undo_move)
    turn_label.text = "Blue phase"

## Snaps every designer-placed unit under Units to its nearest cell and
## wires up its input signals.
func _register_placed_units() -> void:
    for unit in units_node.get_children():
        var cell : Vector2i = overlay.world_to_cell(unit.global_position)
        if not _in_bounds(cell):
            push_warning("Unit '%s' sits off the painted map at %s." % [unit.name, cell])
        if unit_map.has(cell):
            push_warning("Units '%s' and '%s' share cell %s." %
                    [unit_map[cell].name, unit.name, cell])
        unit.move_to(cell, overlay.cell_center_world(cell))
        unit.connect("drag_started",   _on_drag_started)
        unit.connect("drag_moved",     _on_drag_moved)
        unit.connect("drop_attempted", _on_drop_attempted)
        unit.connect("clicked",        _on_unit_clicked)
        unit_map[cell] = unit

# ── Map queries ────────────────────────────────────────────────────────────────

## A cell is on the map iff the designer painted ground there.
func _in_bounds(cell: Vector2i) -> bool:
    return ground.get_cell_source_id(cell) != -1

## Movement cost to enter a cell, read from the TileSet's "move_cost"
## custom data — so new terrain types are a TileSet edit, not a code change.
func _terrain_cost(cell: Vector2i) -> int:
    var data : TileData = ground.get_cell_tile_data(cell)
    if data == null:
        return 1
    return data.get_custom_data("move_cost")

# ── Movement range (replaces ChessRules.get_legal_moves) ──────────────────────

## BFS flood-fill out to the unit's move range, accumulating terrain cost.
## Returns {cell: cheapest cost}. Other units block passage and cannot be
## stopped on; the unit's own cell is included at cost 0.
func _get_reach_costs(unit) -> Dictionary:
    var costs    : Dictionary = {unit.cell: 0}
    var frontier : Array      = [unit.cell]
    while not frontier.is_empty():
        var cur : Vector2i = frontier.pop_front()
        for dir in ORTHO_DIRS:
            var nxt : Vector2i = cur + dir
            if not _in_bounds(nxt):
                continue
            if unit_map.has(nxt) and unit_map[nxt] != unit:
                continue  # later: allies passable but not stoppable, enemies block
            var cost : int = costs[cur] + _terrain_cost(nxt)
            if cost > unit.move_range:
                continue
            if costs.has(nxt) and costs[nxt] <= cost:
                continue
            costs[nxt] = cost
            frontier.append(nxt)
    return costs

## Enemy cells the unit can strike this move (melee range 1), mapped to
## the cheapest reachable cell to launch the attack from — possibly the
## cell it already stands on.
func _get_attack_targets(unit, costs: Dictionary) -> Dictionary:
    var targets : Dictionary = {}
    for enemy_cell in unit_map:
        if unit_map[enemy_cell].team == unit.team:
            continue
        var best : Variant = null
        for dir in ORTHO_DIRS:
            var launch : Vector2i = enemy_cell + dir
            if costs.has(launch) and (best == null or costs[launch] < costs[best]):
                best = launch
        if best != null:
            targets[enemy_cell] = best
    return targets

# ── Player input ───────────────────────────────────────────────────────────────
# Two interchangeable input styles — drag-and-drop and click-then-click —
# kept in lockstep BY CONTRACT: every destination decision (attack, move,
# or invalid) flows through _try_act_at(), no matter which style produced
# it. When adding a new action, add it to that seam, never to just one
# handler, so the styles can never drift apart.
#
# Engine ordering note: _unhandled_input sees a press BEFORE physics
# picking delivers it to the unit under the cursor, so on every click
# main acts on the current selection first, and only then does a unit
# emit drag_started/clicked for whatever selection remains.

## The single decision point shared by both input styles. Attacks if the
## target holds an enemy in range, moves if the target is reachable.
## Returns false (leaving selection state untouched) if neither applies.
func _try_act_at(unit: Area2D, target: Vector2i) -> bool:
    if attack_targets.has(target):
        var defender : Area2D   = unit_map[target]
        var launch   : Vector2i = attack_targets[target]
        _deselect()
        _begin_combat(unit, defender, launch)
        return true
    if target in reachable_cells and target != unit.cell:
        _deselect()
        _push_undo_snapshot()
        _move_unit(unit, target)
        return true
    return false

# ── Drag-and-drop input ────────────────────────────────────────────────────────

func _on_drag_started(unit: Area2D) -> void:
    # Enemy units aren't player-controlled, and nothing drags mid-combat.
    if _combat_active or unit.team != PLAYER_TEAM:
        unit.cancel_drag()
        return

    # Clear previous selection's range tiles.
    overlay.clear_range()

    selected_unit = unit
    var costs : Dictionary = _get_reach_costs(unit)
    reachable_cells = costs.keys()
    attack_targets  = _get_attack_targets(unit, costs)
    overlay.show_range(reachable_cells)
    overlay.show_attack_cells(attack_targets.keys())

func _on_drag_moved(unit: Area2D, world_pos: Vector2) -> void:
    if unit != selected_unit:
        return
    var cell : Vector2i = overlay.world_to_cell(world_pos)
    # Only highlight reachable destinations and attackable enemies.
    var is_target : bool = cell in reachable_cells or attack_targets.has(cell)
    @warning_ignore("incompatible_ternary")
    overlay.update_hover(cell if is_target else null)

func _on_drop_attempted(unit: Area2D, world_pos: Vector2) -> void:
    click_selected_unit = null  # a completed drag clears any click-selection
    overlay.clear_hover()

    if unit != selected_unit:
        unit.return_to_rest()
        return

    if not _try_act_at(unit, overlay.world_to_cell(world_pos)):
        # Dropped somewhere not actionable — snap back and drop selection.
        _deselect()
        unit.return_to_rest()

# ── Click-to-move input ────────────────────────────────────────────────────────

func _on_unit_clicked(unit: Area2D) -> void:
    if _combat_active:
        return
    # Enemy units never emit clicked (their drags are cancelled at start),
    # but guard anyway so a red unit can never become the selection.
    if unit.team != PLAYER_TEAM:
        return
    # Second click on the same unit → deselect. (_handle_click_at left
    # this press for us — see the own-cell carve-out there.)
    if unit == click_selected_unit:
        _deselect()
        return
    # First click: drag_started already fired on mouse-down and showed this
    # unit's range, so all we need to do here is record the click-selection.
    click_selected_unit = unit

func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventMouseButton and
            event.button_index == MOUSE_BUTTON_LEFT and
            event.pressed):
        return
    _handle_click_at(overlay.world_to_cell(get_global_mouse_position()))

## Click-style counterpart of _on_drop_attempted: acts on the selection
## with the clicked cell through the same _try_act_at seam.
func _handle_click_at(cell: Vector2i) -> void:
    if click_selected_unit == null or _combat_active:
        return
    # Press on the selected unit's own cell: leave it for the clicked
    # signal, which toggles the selection off (or starts a fresh drag).
    if cell == click_selected_unit.cell:
        return
    var unit : Area2D = click_selected_unit
    if not _try_act_at(unit, cell):
        _deselect()

func _deselect() -> void:
    click_selected_unit = null
    selected_unit       = null
    reachable_cells     = []
    attack_targets      = {}
    overlay.clear_all()

# ── Move application ───────────────────────────────────────────────────────────

func _move_unit(unit: Area2D, to_cell: Vector2i) -> void:
    unit_map.erase(unit.cell)
    unit.move_to(to_cell, overlay.cell_center_world(to_cell))
    unit_map[to_cell] = unit

# ── Combat ─────────────────────────────────────────────────────────────────────
# A melee engagement: the attacker moves to its launch cell, bumps into the
# defender (damage lands mid-swing), and the defender counter-bumps if it
# survives. Damage is a flat 1 for now — _attack_damage() is the seam where
# weapons and rpg stats (def, crit, …) plug in later. The future
# weapon-choice menu opens inside _begin_combat, between the approach move
# and the bump — same stash-state-and-resume pattern as the chess
# promotion panel.

const BUMP_TIME     : float = 0.12  # seconds each way
const BUMP_DISTANCE : float = 0.45  # fraction of the way into the target's cell

var _combat_active : bool = false   # input is ignored while the bumps play

func _attack_damage(_attacker, _defender) -> int:
    return 1  # flat subtraction for now

func _begin_combat(attacker: Area2D, defender: Area2D, launch_cell: Vector2i) -> void:
    _push_undo_snapshot()  # one undo reverts the approach move and the damage

    if launch_cell != attacker.cell:
        _move_unit(attacker, launch_cell)
    else:
        attacker.return_to_rest()  # settle a mid-drag drop before the bump

    _combat_active = true

    var atk_home : Vector2 = overlay.cell_center_world(attacker.cell)
    var def_home : Vector2 = overlay.cell_center_world(defender.cell)
    var atk_dmg  : int     = _attack_damage(attacker, defender)
    var counters : bool    = defender.hp > atk_dmg  # the defeated don't counter

    var tw : Tween = create_tween()
    tw.tween_callback(func() -> void: attacker.z_index = 10)
    tw.tween_property(attacker, "global_position",
            atk_home.lerp(def_home, BUMP_DISTANCE), BUMP_TIME)
    tw.tween_callback(func() -> void: defender.take_damage(atk_dmg))
    tw.tween_property(attacker, "global_position", atk_home, BUMP_TIME)
    tw.tween_callback(func() -> void: attacker.z_index = 1)

    if counters:
        var def_dmg : int = _attack_damage(defender, attacker)
        tw.tween_callback(func() -> void: defender.z_index = 10)
        tw.tween_property(defender, "global_position",
                def_home.lerp(atk_home, BUMP_DISTANCE), BUMP_TIME)
        tw.tween_callback(func() -> void: attacker.take_damage(def_dmg))
        tw.tween_property(defender, "global_position", def_home, BUMP_TIME)
        tw.tween_callback(func() -> void: defender.z_index = 1)

    tw.tween_callback(_end_combat.bind(attacker, defender))

func _end_combat(attacker: Area2D, defender: Area2D) -> void:
    for unit in [attacker, defender]:
        if unit.hp <= 0:
            unit_map.erase(unit.cell)
            unit.defeat()
    _combat_active = false

# ── Undo ───────────────────────────────────────────────────────────────────────

func _push_undo_snapshot() -> void:
    # {node: state} for every unit node, so undo can restore each one's
    # position, health, and visibility (defeats revert too).
    var states : Dictionary = {}
    for unit in units_node.get_children():
        states[unit] = {
            "cell"     : unit.cell,
            "world"    : unit.global_position,
            "rest"     : unit._rest_position,
            "visible"  : unit.visible,
            "pickable" : unit.input_pickable,
            "hp"       : unit.hp,
        }
    undo_stack.append({"unit_states": states})
    undo_button.disabled = false

## Called by the Undo button.
func undo_move() -> void:
    if _combat_active:
        return
    _deselect()
    if undo_stack.is_empty():
        return

    var snap   : Dictionary = undo_stack.pop_back()
    var states : Dictionary = snap["unit_states"]
    unit_map.clear()
    for unit in states:
        var s : Dictionary = states[unit]
        unit.cell            = s["cell"]
        unit.global_position = s["world"]
        unit._rest_position  = s["rest"]
        unit.visible         = s["visible"]
        unit.input_pickable  = s["pickable"]
        unit.hp              = s["hp"]
        unit.queue_redraw()
        if unit.visible:
            unit_map[unit.cell] = unit

    undo_button.disabled = undo_stack.is_empty()
