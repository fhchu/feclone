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
@onready var ground       : TileMapLayer   = $Ground
@onready var overlay      : TileMapLayer   = $Overlay
@onready var units_node   : Node2D         = $Units
@onready var turn_label   : Label          = $UI/TurnLabel
@onready var undo_button  : Button         = $UI/UndoButton
@onready var phase_banner : PanelContainer = $UI/PhaseBanner
@onready var banner_label : Label          = $UI/PhaseBanner/BannerLabel
@onready var action_menu  : PanelContainer = $UI/ActionMenu
@onready var wait_button  : Button         = $UI/ActionMenu/VBoxContainer/WaitButton

const PLAYER_TEAM : String = "blue"
const ENEMY_TEAM  : String = "red"

const ORTHO_DIRS : Array = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

# ── Pacing ─────────────────────────────────────────────────────────────────────
## Global animation speed multiplier. Every animated duration in the game
## (walking, combat bumps, phase banners, enemy pacing) is divided by it,
## so raising it to 1.5–2.0 fast-forwards the whole game uniformly.
@export_range(0.5, 3.0, 0.1) var animation_speed : float = 1.0

## Scales a base duration by the global animation speed.
func _anim(seconds: float) -> float:
    return seconds / animation_speed

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
    wait_button.pressed.connect(_on_wait_pressed)
    _start_phase(PLAYER_TEAM)

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

# ── Phases ─────────────────────────────────────────────────────────────────────
# Alternating team phases, Fire Emblem style: every unit on the active
# team acts once (greying out as it does), then the phase flips. The
# banner announces each phase and input stays locked while it plays —
# for the whole enemy phase, in fact, since the player never acts in it.
# The enemy phase runs each red unit through its EnemyAI strategies
# (scripts/enemy_ai.gd) one at a time, then hands back to the player.

const BANNER_FADE_IN  : float = 0.2
const BANNER_HOLD     : float = 1.0
const BANNER_FADE_OUT : float = 0.3
const BANNER_COLORS   : Dictionary = {
    "blue": Color(0.25, 0.55, 1.0),
    "red" : Color(0.95, 0.25, 0.3),
}

var current_team    : String = PLAYER_TEAM
var _phase_changing : bool   = false   # input is ignored while banners play

## True whenever the player may not act: combat playing out, a unit
## walking, or a phase banner/hand-off in progress. Every input handler
## checks this first.
func _input_locked() -> bool:
    return _combat_active or _phase_changing or _walking

## Begins a phase: refreshes every unit (the previous team un-greys, the
## new team gets its actions back) and plays the announcement banner.
func _start_phase(team: String) -> void:
    current_team    = team
    _phase_changing = true
    _deselect()
    for unit in units_node.get_children():
        unit.has_acted = false
    var title : String = "Player Phase" if team == PLAYER_TEAM else "Enemy Phase"
    turn_label.text = title
    _show_banner(title, BANNER_COLORS[team])

func _show_banner(title: String, team_color: Color) -> void:
    var style : StyleBoxFlat = phase_banner.get_theme_stylebox("panel")
    style.border_color = team_color
    # The banner background is fully transparent; the team-coloured text
    # outline is what keeps the white title readable over the map.
    banner_label.label_settings.outline_color = team_color
    banner_label.text = title
    phase_banner.modulate.a = 0.0
    phase_banner.visible    = true
    var tw : Tween = create_tween()
    tw.tween_property(phase_banner, "modulate:a", 1.0, _anim(BANNER_FADE_IN))
    tw.tween_interval(_anim(BANNER_HOLD))
    tw.tween_property(phase_banner, "modulate:a", 0.0, _anim(BANNER_FADE_OUT))
    tw.tween_callback(func() -> void: phase_banner.visible = false)
    tw.tween_callback(_on_banner_finished)

func _on_banner_finished() -> void:
    if current_team == PLAYER_TEAM:
        _phase_changing = false  # hand control to the player
    else:
        _run_enemy_phase()

const ENEMY_ACT_DELAY : float = 0.35  # beat between enemy actions

## Runs the enemy phase one unit at a time. Each red unit consults its
## EnemyAI strategies and either engages (through the same combat path
## as player attacks) or holds. The runner owns the phase hand-off —
## _finish_action never flips the phase while the enemy is acting.
func _run_enemy_phase() -> void:
    for unit in units_node.get_children():
        if unit.team != current_team or not unit.visible:
            continue
        await get_tree().create_timer(_anim(ENEMY_ACT_DELAY)).timeout
        if not unit.visible:
            continue  # defeated by a counterattack earlier this phase
        var action : Dictionary = EnemyAI.decide(unit, self)
        if action["type"] == "attack":
            _begin_combat(unit, action["target"], action["launch"])
            await combat_finished
        else:
            unit.has_acted = true  # holds position; greys until next phase
    _start_phase(PLAYER_TEAM)

## Marks a completed action. Called from the _try_act_at move branch and
## from _end_combat, so both action kinds end a unit's turn identically.
## Future game-over checks (all player units dead / boss slain) evaluate
## here, before the phase is allowed to flip.
func _finish_action(unit: Area2D) -> void:
    unit.has_acted = true
    # Only the player phase auto-flips; _run_enemy_phase sequences its own.
    if current_team == PLAYER_TEAM and _team_done(current_team):
        _start_phase(ENEMY_TEAM)

## A team is done when none of its living units still has an action.
func _team_done(team: String) -> bool:
    for unit in units_node.get_children():
        if unit.team == team and unit.visible and not unit.has_acted:
            return false
    return true

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
        _move_unit_walking(unit, target)
        return true
    return false

# ── Drag-and-drop input ────────────────────────────────────────────────────────

func _on_drag_started(unit: Area2D) -> void:
    # Only fresh player units drag, and only while input is live.
    if _input_locked() or unit.team != PLAYER_TEAM or unit.has_acted:
        unit.cancel_drag()
        return

    # Clear previous selection's range tiles; the menu stays hidden while
    # the mouse is down and reopens from the clicked signal on release.
    overlay.clear_range()
    _hide_action_menu()

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
    if _input_locked():
        return
    # Rejected units never emit clicked (their drags are cancelled at
    # start), but guard anyway so they can never become the selection.
    if unit.team != PLAYER_TEAM or unit.has_acted:
        return
    # Second click on the same unit → deselect. (_handle_click_at left
    # this press for us — see the own-cell carve-out there.)
    if unit == click_selected_unit:
        _deselect()
        return
    # First click: drag_started already fired on mouse-down and showed this
    # unit's range; record the click-selection and open its action menu.
    click_selected_unit = unit
    _show_action_menu(unit)

func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventMouseButton and
            event.button_index == MOUSE_BUTTON_LEFT and
            event.pressed):
        return
    _handle_click_at(overlay.world_to_cell(get_global_mouse_position()))

## Click-style counterpart of _on_drop_attempted: acts on the selection
## with the clicked cell through the same _try_act_at seam.
func _handle_click_at(cell: Vector2i) -> void:
    if click_selected_unit == null or _input_locked():
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
    _hide_action_menu()

# ── Action menu ────────────────────────────────────────────────────────────────
# A small dropdown that pops up beside the click-selected unit. Wait is
# its only entry for now; Items and the weapon picker become sibling
# buttons in the same VBoxContainer later. Menu buttons are Controls, so
# the GUI consumes their clicks before _unhandled_input or physics
# picking can deselect the unit underneath.

## Places the menu beside the unit, flipping to its left when it would
## poke past the painted map's right edge (plus margin). Measured off
## the map rather than the window so any viewport behaves the same.
## There is no camera, so world coords are canvas coords.
func _show_action_menu(unit: Area2D) -> void:
    action_menu.reset_size()
    var pos : Vector2 = unit.global_position + Vector2(40, -20)
    var map_right : float = ground.position.x + \
            ground.get_used_rect().end.x * ground.tile_set.tile_size.x
    if pos.x + action_menu.size.x > map_right + 36:
        pos.x = unit.global_position.x - 40 - action_menu.size.x
    action_menu.position = pos
    action_menu.visible  = true

func _hide_action_menu() -> void:
    action_menu.visible = false

## Wait: end the selected unit's turn without moving.
func _on_wait_pressed() -> void:
    if _input_locked() or click_selected_unit == null:
        return
    var unit : Area2D = click_selected_unit
    _deselect()
    _push_undo_snapshot()
    _finish_action(unit)

# ── Move application ───────────────────────────────────────────────────────────

const WALK_TIME_PER_TILE : float = 0.1  # seconds per step at 1x speed

var _walking : bool = false   # input is ignored while a unit walks

## Commits a move instantly: updates unit_map, cell, and rest position.
func _move_unit(unit: Area2D, to_cell: Vector2i) -> void:
    unit_map.erase(unit.cell)
    unit.move_to(to_cell, overlay.cell_center_world(to_cell))
    unit_map[to_cell] = unit

## Reconstructs the cheapest path from the unit to target (start cell
## included) by descending the BFS cost field: each step back goes to a
## neighbour whose cost is exactly this cell's cost minus its terrain
## cost — such a neighbour always exists on an optimal field.
func _build_path(unit: Area2D, target: Vector2i) -> Array:
    var costs : Dictionary = _get_reach_costs(unit)
    var path  : Array      = [target]
    var cur   : Vector2i   = target
    while cur != unit.cell:
        var stepped : bool = false
        for dir in ORTHO_DIRS:
            var prev : Vector2i = cur + dir
            if costs.has(prev) and costs[prev] == costs[cur] - _terrain_cost(cur):
                cur     = prev
                stepped = true
                break
        if not stepped:
            push_warning("No path back from %s for %s" % [target, unit.name])
            break
        path.push_front(cur)
    return path

## Walks the unit tile-by-tile to target, then commits the move. Input
## stays locked for the duration. Awaitable; safe when target is the
## unit's own cell (no tween — it just settles home, e.g. after a drag).
func _walk_unit(unit: Area2D, target: Vector2i) -> void:
    var path : Array = _build_path(unit, target)
    _walking = true
    # A dragged unit hangs at its drop point; walking starts from home.
    unit.global_position = overlay.cell_center_world(unit.cell)
    if path.size() > 1:
        var tw : Tween = create_tween()
        for i in range(1, path.size()):
            tw.tween_property(unit, "global_position",
                    overlay.cell_center_world(path[i]), _anim(WALK_TIME_PER_TILE))
        await tw.finished
    _move_unit(unit, target)
    _walking = false

## A plain (non-combat) move: walk there, then the unit's turn is done.
func _move_unit_walking(unit: Area2D, target: Vector2i) -> void:
    await _walk_unit(unit, target)
    _finish_action(unit)

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

## Fired when an engagement fully resolves; _run_enemy_phase awaits it.
signal combat_finished

func _attack_damage(_attacker, _defender) -> int:
    return 1  # flat subtraction for now

func _begin_combat(attacker: Area2D, defender: Area2D, launch_cell: Vector2i) -> void:
    _push_undo_snapshot()  # one undo reverts the approach move and the damage
    _combat_active = true

    # Walk the approach (or just settle home when attacking in place).
    await _walk_unit(attacker, launch_cell)

    var atk_home : Vector2 = overlay.cell_center_world(attacker.cell)
    var def_home : Vector2 = overlay.cell_center_world(defender.cell)
    var atk_dmg  : int     = _attack_damage(attacker, defender)
    var counters : bool    = defender.hp > atk_dmg  # the defeated don't counter

    var tw : Tween = create_tween()
    tw.tween_callback(func() -> void: attacker.z_index = 10)
    tw.tween_property(attacker, "global_position",
            atk_home.lerp(def_home, BUMP_DISTANCE), _anim(BUMP_TIME))
    tw.tween_callback(func() -> void: defender.take_damage(atk_dmg))
    tw.tween_property(attacker, "global_position", atk_home, _anim(BUMP_TIME))
    tw.tween_callback(func() -> void: attacker.z_index = 1)

    if counters:
        var def_dmg : int = _attack_damage(defender, attacker)
        tw.tween_callback(func() -> void: defender.z_index = 10)
        tw.tween_property(defender, "global_position",
                def_home.lerp(atk_home, BUMP_DISTANCE), _anim(BUMP_TIME))
        tw.tween_callback(func() -> void: attacker.take_damage(def_dmg))
        tw.tween_property(defender, "global_position", def_home, _anim(BUMP_TIME))
        tw.tween_callback(func() -> void: defender.z_index = 1)

    tw.tween_callback(_end_combat.bind(attacker, defender))

func _end_combat(attacker: Area2D, defender: Area2D) -> void:
    for unit in [attacker, defender]:
        if unit.hp <= 0:
            unit_map.erase(unit.cell)
            unit.defeat()
    _combat_active = false
    _finish_action(attacker)
    combat_finished.emit()

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
            "acted"    : unit.has_acted,
        }
    undo_stack.append({"unit_states": states, "team": current_team})
    undo_button.disabled = false

## Called by the Undo button. Restores phase state too, so undoing the
## action that ended a phase steps back into that phase. Enemy actions
## are deterministic reactions, so snapshots taken during the enemy
## phase collapse into the player action that provoked them: one undo
## lands back on a state where it's the player's input.
func undo_move() -> void:
    if _input_locked():
        return
    _deselect()
    if undo_stack.is_empty():
        return

    var snap : Dictionary = undo_stack.pop_back()
    while snap["team"] != PLAYER_TEAM and not undo_stack.is_empty():
        snap = undo_stack.pop_back()
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
        unit.has_acted       = s["acted"]
        unit.queue_redraw()
        if unit.visible:
            unit_map[unit.cell] = unit

    current_team    = snap["team"]
    turn_label.text = "Player Phase" if current_team == PLAYER_TEAM else "Enemy Phase"
    undo_button.disabled = undo_stack.is_empty()
