# main.gd
# Attached to the game shell (scenes/game.tscn): the persistent board
# logic, Overlay, and all UI. Levels are separate content-only scenes
# (Ground + Units + metadata, see scripts/level.gd) instanced under
# LevelHolder — _load_level() swaps them in place, so the shell survives
# across levels and restarts. Mirrors the structure of chess main.gd:
#   piece_map → unit_map, legal_moves → reachable_cells,
#   captures → melee combat, and the same undo-snapshot pattern.
#
# Levels are authored entirely in the editor — no code changes needed:
#   • Terrain: paint the level's Ground TileMapLayer. Movement cost is
#     the shared TileSet's "move_cost" custom data (grass 1, forest 2;
#     assets/ground_tiles.tres). Unpainted cells are off the map.
#   • Units:   instance unit.tscn under the level's Units node and set
#     class/team/max hp in the Inspector.
#   • Metadata: loss_conditions etc. are exports on the Level root.

extends Node2D

# ── Scene references ───────────────────────────────────────────────────────────
@onready var level_holder : Node2D         = $LevelHolder
@onready var overlay      : TileMapLayer   = $Overlay
@onready var turn_label   : Label          = $UI/TurnLabel
@onready var undo_button  : Button         = $UI/UndoButton
@onready var phase_banner : PanelContainer = $UI/PhaseBanner
@onready var banner_label : Label          = $UI/PhaseBanner/BannerLabel
@onready var action_menu     : PanelContainer = $UI/ActionMenu
@onready var attack_button   : Button         = $UI/ActionMenu/VBoxContainer/AttackButton
@onready var wait_button     : Button         = $UI/ActionMenu/VBoxContainer/WaitButton
@onready var settings_button  : Button         = $UI/SettingsButton
@onready var settings_panel   : PanelContainer = $UI/SettingsPanel
@onready var game_over_screen : Control        = $UI/GameOverScreen

# ── Current level ──────────────────────────────────────────────────────────────
# Set by _load_level(); ground and units_node point into the level
# instance. loss_conditions copies the level's metadata export.
var level              : Node2D       = null
var ground             : TileMapLayer = null
var units_node         : Node2D       = null
var current_level_path : String       = ""
var loss_conditions    : Array        = ["all_units_dead"]

# Bumped on every _load_level; coroutines waiting on timers or signals
# compare it after resuming so a restart/level-swap orphans them safely.
var _level_generation : int = 0

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

# ── Pending action state (the FE move-then-menu flow) ──────────────────────────
# After a unit moves (or elects to act in place), it becomes the pending
# unit: the action menu owns the turn until Attack or Wait resolves it.
var _pending_unit           : Variant    = null   # Area2D awaiting a menu decision
var _pending_snapshot_taken : bool       = false  # its move already pushed an undo snapshot
var _menu_open              : bool       = false  # action menu is showing (modal)
var _targeting              : bool       = false  # picking an attack target
var _targetable             : Dictionary = {}     # enemy cell → true while targeting

# ── Undo stack ─────────────────────────────────────────────────────────────────
var undo_stack : Array = []

# ── Setup ──────────────────────────────────────────────────────────────────────

func _ready() -> void:
    overlay.overlay_alpha = 0.5
    undo_button.pressed.connect(undo_move)
    attack_button.pressed.connect(_on_attack_pressed)
    wait_button.pressed.connect(_on_wait_pressed)
    settings_button.pressed.connect(_on_settings_pressed)
    settings_panel.get_node("VBoxContainer/RestartButton").pressed.connect(_on_restart_pressed)
    settings_panel.get_node("VBoxContainer/LevelSelectButton").pressed.connect(_on_level_select_pressed)
    settings_panel.get_node("VBoxContainer/BackButton").pressed.connect(_on_settings_back)
    game_over_screen.get_node("VBoxContainer/UndoButton").pressed.connect(_on_game_over_undo)
    game_over_screen.get_node("VBoxContainer/RestartButton").pressed.connect(_on_restart_pressed)
    game_over_screen.get_node("VBoxContainer/LevelSelectButton").pressed.connect(_on_level_select_pressed)

    # Level select stashes its pick in tree metadata (the chess-menu
    # pattern); a plain boot starts the campaign from the top.
    var start : String = Levels.LEVELS[0]
    if get_tree().has_meta("level_path"):
        start = get_tree().get_meta("level_path")
        get_tree().remove_meta("level_path")
    _load_level(start)

## Swaps in a level scene and resets every per-level piece of state.
## Used for boot, restarts, and rout-victory progression alike.
func _load_level(path: String) -> void:
    _level_generation += 1
    if level != null:
        level.queue_free()

    # Reset match state. _deselect also clears menu/targeting/pending.
    unit_map   = {}
    undo_stack = []
    _deselect()
    undo_button.disabled     = true
    _combat_active           = false
    _walking                 = false
    _phase_changing          = false
    _settings_open           = false
    _level_over              = false
    _game_over               = false
    settings_panel.visible   = false
    game_over_screen.visible = false

    current_level_path = path
    level = load(path).instantiate()
    level_holder.add_child(level)
    ground          = level.get_node("Ground")
    units_node      = level.get_node("Units")
    loss_conditions = level.loss_conditions
    overlay.position = ground.position  # the map decides where it sits

    _register_placed_units()
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

## Every cell the unit could strike but not stand on: the red fringe one
## weapon-reach (melee 1 for now) beyond the movement range, whether or
## not anything is standing there.
func _get_attack_fringe(costs: Dictionary) -> Array:
    var fringe : Dictionary = {}
    for cell in costs:
        for dir in ORTHO_DIRS:
            var n : Vector2i = cell + dir
            if _in_bounds(n) and not costs.has(n):
                fringe[n] = true
    return fringe.keys()

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
## walking, a phase banner/hand-off in progress, the settings menu open,
## or the level already decided. Every input handler checks this first.
func _input_locked() -> bool:
    return _combat_active or _phase_changing or _walking \
            or _settings_open or _level_over or _game_over \
            or _menu_open or _targeting

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
    # Bound to the level: swapping levels kills the tween and its
    # callbacks, so a stale banner can never advance a dead phase.
    var tw : Tween = create_tween()
    tw.bind_node(level)
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
    var gen : int = _level_generation
    for unit in units_node.get_children():
        if _level_over or _game_over:
            return  # the level was decided mid-phase
        if unit.team != current_team or not unit.visible:
            continue
        await get_tree().create_timer(_anim(ENEMY_ACT_DELAY)).timeout
        if gen != _level_generation:
            return  # the level was swapped out from under us
        if not unit.visible:
            continue  # defeated by a counterattack earlier this phase
        var action : Dictionary = EnemyAI.decide(unit, self)
        if action["type"] == "attack":
            _begin_combat(unit, action["target"], action["launch"])
            await combat_finished
            if gen != _level_generation:
                return
        else:
            unit.has_acted = true  # holds position; greys until next phase
    if _level_over or _game_over:
        return
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
## target holds an enemy in range, opens the in-place action menu on the
## unit's own cell, and moves (then opens the menu) if the target is
## reachable. Returns false (selection untouched) if none apply.
func _try_act_at(unit: Area2D, target: Vector2i) -> bool:
    if attack_targets.has(target):
        # Direct strike: dropping/clicking straight onto an enemy is the
        # quick path that skips the menu.
        var defender : Area2D   = unit_map[target]
        var launch   : Vector2i = attack_targets[target]
        _deselect()
        _begin_combat(unit, defender, launch)
        return true
    if target == unit.cell:
        # Acting in place: no move, menu decides (Wait-without-moving).
        _deselect()
        unit.return_to_rest()  # settle a drag dropped back home
        _open_action_menu(unit, false)
        return true
    if target in reachable_cells:
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

    # Clear previous selection's range tiles.
    overlay.clear_range()

    selected_unit = unit
    var costs : Dictionary = _get_reach_costs(unit)
    reachable_cells = costs.keys()
    attack_targets  = _get_attack_targets(unit, costs)
    overlay.show_range(reachable_cells)
    # The whole strike fringe reads red; only cells in attack_targets
    # (the ones holding enemies) are actually actionable.
    overlay.show_attack_cells(_get_attack_fringe(costs))

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
    # Second click on the same unit → act in place: the action menu opens
    # without moving. (_handle_click_at left this press for us — see the
    # own-cell carve-out there.) Deselecting is done by clicking any
    # invalid tile instead.
    if unit == click_selected_unit:
        _try_act_at(unit, unit.cell)
        return
    # First click: drag_started already fired on mouse-down and showed
    # this unit's range; just record the click-selection.
    click_selected_unit = unit

func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventMouseButton and
            event.button_index == MOUSE_BUTTON_LEFT and
            event.pressed):
        return
    var cell : Vector2i = overlay.world_to_cell(get_global_mouse_position())
    if _targeting:
        _handle_target_click(cell)
        return
    _handle_click_at(cell)

## Click-style counterpart of _on_drop_attempted: acts on the selection
## with the clicked cell through the same _try_act_at seam.
func _handle_click_at(cell: Vector2i) -> void:
    if click_selected_unit == null or _input_locked():
        return
    # Press on the selected unit's own cell: leave it for the clicked
    # signal, which opens the in-place action menu (or a drag begins).
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
    _clear_pending()

# ── Action menu (the FE move-then-menu flow) ──────────────────────────────────
# Moving a unit no longer ends its turn: the unit walks, then this
# centered menu owns the turn until Attack or Wait resolves it. Attack
# only lists when an enemy stands within weapon reach of the unit's
# current cell; picking it swaps the menu for target selection (red
# squares on the adjacent enemies — click one to strike, click anything
# else to come back to the menu). Items joins these buttons later.
# Menu buttons are Controls, so the GUI consumes their clicks before
# _unhandled_input or physics picking see them; everything else is
# locked out by _menu_open/_targeting while the menu owns the turn.

## Opens the menu for a unit that has just moved (snapshot_taken: its
## move already pushed the undo snapshot) or is acting in place.
func _open_action_menu(unit: Area2D, snapshot_taken: bool) -> void:
    _pending_unit           = unit
    _pending_snapshot_taken = snapshot_taken
    _menu_open              = true
    attack_button.visible   = not _adjacent_enemies(unit).is_empty()
    action_menu.visible     = true
    # Shrink the panel to its (new) content once the container has
    # re-sorted — fewer options means a shorter menu, same width.
    action_menu.call_deferred("reset_size")

## Resets every pending-action flag and hides the menu UI.
func _clear_pending() -> void:
    _pending_unit           = null
    _pending_snapshot_taken = false
    _menu_open              = false
    _targeting              = false
    _targetable             = {}
    action_menu.visible     = false

## Living enemies within weapon reach (melee 1) of the unit's cell.
func _adjacent_enemies(unit: Area2D) -> Array:
    var cells : Array = []
    for dir in ORTHO_DIRS:
        var n : Vector2i = unit.cell + dir
        if unit_map.has(n) and unit_map[n].team != unit.team:
            cells.append(n)
    return cells

## Attack: hide the menu and mark the enemies in reach for targeting.
func _on_attack_pressed() -> void:
    if _pending_unit == null:
        return
    _menu_open          = false
    action_menu.visible = false
    _targeting          = true
    _targetable         = {}
    for cell in _adjacent_enemies(_pending_unit):
        _targetable[cell] = true
    overlay.show_attack_cells(_targetable.keys())

## A click while picking a target: strike a marked enemy; anything else
## returns to the action menu.
func _handle_target_click(cell: Vector2i) -> void:
    var unit          : Area2D = _pending_unit
    var have_snapshot : bool   = _pending_snapshot_taken
    if _targetable.has(cell):
        var defender : Area2D = unit_map[cell]
        _clear_pending()
        overlay.clear_all()
        _begin_combat(unit, defender, unit.cell, not have_snapshot)
    else:
        _targeting  = false
        _targetable = {}
        overlay.clear_range()
        _open_action_menu(unit, have_snapshot)

## Wait: end the pending unit's turn where it stands.
func _on_wait_pressed() -> void:
    if _pending_unit == null:
        return
    var unit          : Area2D = _pending_unit
    var have_snapshot : bool   = _pending_snapshot_taken
    _clear_pending()
    if not have_snapshot:
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
        # Bound to the level: a restart mid-walk kills the tween (and
        # this coroutine never resumes — the fresh level owns the flags).
        var tw : Tween = create_tween()
        tw.bind_node(level)
        for i in range(1, path.size()):
            tw.tween_property(unit, "global_position",
                    overlay.cell_center_world(path[i]), _anim(WALK_TIME_PER_TILE))
        await tw.finished
    _move_unit(unit, target)
    _walking = false

## A player move: walk there, then the action menu decides the turn —
## Attack if anything is in reach from the new cell, or Wait.
func _move_unit_walking(unit: Area2D, target: Vector2i) -> void:
    await _walk_unit(unit, target)
    _open_action_menu(unit, true)

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

## push_snapshot is false when the attacker's approach move already
## pushed one (the menu flow) — move + attack stay a single undo step.
func _begin_combat(attacker: Area2D, defender: Area2D, launch_cell: Vector2i,
        push_snapshot: bool = true) -> void:
    if push_snapshot:
        _push_undo_snapshot()  # one undo reverts approach move and damage
    _combat_active = true

    # Walk the approach (or just settle home when attacking in place).
    await _walk_unit(attacker, launch_cell)

    var atk_home : Vector2 = overlay.cell_center_world(attacker.cell)
    var def_home : Vector2 = overlay.cell_center_world(defender.cell)
    var atk_dmg  : int     = _attack_damage(attacker, defender)
    var counters : bool    = defender.hp > atk_dmg  # the defeated don't counter

    var tw : Tween = create_tween()
    tw.bind_node(level)
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
    # Level outcomes preempt phase bookkeeping. Defeat is checked first:
    # in any simultaneous reading, losing your army loses the level.
    if LossConditions.any_met(loss_conditions, self):
        _show_game_over()
    elif _team_wiped(ENEMY_TEAM):
        _level_cleared()
    else:
        _finish_action(attacker)
    combat_finished.emit()

## True when a team has no living units left.
func _team_wiped(team: String) -> bool:
    for unit in units_node.get_children():
        if unit.team == team and unit.visible:
            return false
    return true

# ── Level flow ─────────────────────────────────────────────────────────────────

const LEVEL_CLEAR_DELAY : float = 0.8  # beat after the final blow lands
const GAME_OVER_DELAY   : float = 0.8  # beat before the defeat screen

var _settings_open : bool = false
var _level_over    : bool = false
var _game_over     : bool = false

## Rout victory: brief beat so the kill reads, then the next level is
## swapped in place (level select after the last one).
func _level_cleared() -> void:
    _level_over = true
    _deselect()
    turn_label.text = "Victory!"
    var gen : int = _level_generation
    await get_tree().create_timer(_anim(LEVEL_CLEAR_DELAY)).timeout
    if gen != _level_generation:
        return  # restarted (or otherwise swapped) during the beat
    var next : String = Levels.next_after(current_level_path)
    if next != "":
        _load_level(next)
    else:
        get_tree().change_scene_to_file(Levels.LEVEL_SELECT)

## Defeat: brief beat so the killing blow reads, then the Game Over
## screen. The phase machinery stops where it was; _game_over owns the
## input lock from here (any stale _phase_changing is cleared so Undo
## can hand control back cleanly).
func _show_game_over() -> void:
    _game_over      = true
    _phase_changing = false
    _deselect()
    turn_label.text = "Game Over"
    var gen : int = _level_generation
    await get_tree().create_timer(_anim(GAME_OVER_DELAY)).timeout
    if gen != _level_generation:
        return  # restarted during the beat
    game_over_screen.visible = true

## Undo Last Move on the defeat screen: rewind the fatal exchange (the
## enemy phase collapses into the player action that provoked it) and
## resume playing from there.
func _on_game_over_undo() -> void:
    _game_over = false
    game_over_screen.visible = false
    undo_move()

## The Settings button works even while input is otherwise locked —
## scene changes tear down any animation safely.
func _on_settings_pressed() -> void:
    _settings_open = true
    settings_panel.visible = true

func _on_settings_back() -> void:
    _settings_open = false
    settings_panel.visible = false

func _on_restart_pressed() -> void:
    _load_level(current_level_path)

func _on_level_select_pressed() -> void:
    get_tree().change_scene_to_file(Levels.LEVEL_SELECT)

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
