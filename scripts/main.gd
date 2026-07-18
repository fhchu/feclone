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
#   • Terrain: paint the level's Ground TileMapLayer. Tiles name their
#     terrain ("terrain" custom data on assets/ground_tiles.tres) and
#     ClassStats.MOVE_COSTS prices it per movement group. Unpainted
#     cells are off the map.
#   • Units:   instance unit.tscn under the level's Units node and set
#     class/team/max hp in the Inspector.
#   • Metadata: loss_conditions etc. are exports on the Level root.

extends Node2D

# ── Scene references ───────────────────────────────────────────────────────────
@onready var level_holder : Node2D         = $LevelHolder
@onready var overlay      : TileMapLayer   = $Overlay
@onready var camera       : Camera2D       = $GameCamera
@onready var undo_button  : Button         = $UI/UndoButton
@onready var phase_banner : PanelContainer = $UI/PhaseBanner
@onready var banner_label : Label          = $UI/PhaseBanner/BannerLabel
@onready var action_menu     : PanelContainer = $UI/ActionMenu
@onready var attack_button   : Button         = $UI/ActionMenu/VBoxContainer/AttackButton
@onready var wait_button     : Button         = $UI/ActionMenu/VBoxContainer/WaitButton
@onready var items_button    : Button         = $UI/ActionMenu/VBoxContainer/ItemsButton
@onready var items_panel     : PanelContainer = $UI/ItemsPanel
@onready var items_vbox      : VBoxContainer  = $UI/ItemsPanel/VBoxContainer
@onready var items_close     : Button         = $UI/ItemsPanel/VBoxContainer/Header/CloseButton
@onready var item_action_button : Button      = $UI/ItemActionButton
@onready var map_menu          : PanelContainer = $UI/MapMenu
@onready var danger_layer      : Node2D         = $DangerLayer
@onready var danger_zone_check : CheckBox       = $UI/CornerButtons/DangerPanel/DangerRow/DangerZoneCheck
@onready var settings_button  : Button         = $UI/CornerButtons/SettingsButton
@onready var settings_panel   : PanelContainer = $UI/SettingsPanel
@onready var game_over_screen : Control        = $UI/GameOverScreen
@onready var info_panel       : PanelContainer = $UI/UnitInfoPanel
@onready var info_portrait    : TextureRect    = $UI/UnitInfoPanel/HBoxContainer/Portrait
@onready var info_name        : Label          = $UI/UnitInfoPanel/HBoxContainer/Info/NameLabel
@onready var info_hp          : Label          = $UI/UnitInfoPanel/HBoxContainer/Info/HpLabel
@onready var info_bar_fill    : ColorRect      = $UI/UnitInfoPanel/HBoxContainer/Info/HpBarBack/HpBarFill
@onready var forecast_panel   : PanelContainer = $UI/ForecastPanel
@onready var fc_atk_name      : Label          = $UI/ForecastPanel/VBoxContainer/AtkNameBox/AtkName
@onready var fc_def_name      : Label          = $UI/ForecastPanel/VBoxContainer/DefNameBox/DefName
@onready var fc_atk_weapon    : Label          = $UI/ForecastPanel/VBoxContainer/AtkWeaponBox/AtkWeapon
@onready var fc_def_weapon    : Label          = $UI/ForecastPanel/VBoxContainer/DefWeaponBox/DefWeapon
@onready var fc_blue_hp       : Label          = $UI/ForecastPanel/VBoxContainer/Cols/BlueCol/Values/Hp
@onready var fc_blue_mt       : Label          = $UI/ForecastPanel/VBoxContainer/Cols/BlueCol/Values/Mt
@onready var fc_red_hp        : Label          = $UI/ForecastPanel/VBoxContainer/Cols/RedCol/Values/Hp
@onready var fc_red_mt        : Label          = $UI/ForecastPanel/VBoxContainer/Cols/RedCol/Values/Mt

const INFO_BAR_WIDTH : float = 120.0

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

# ── Camera ─────────────────────────────────────────────────────────────────────
# Edge scrolling: the mouse pressed against the screen edge pans the
# view (the mouse plays the role a cursor will have), clamped so the
# camera never shows past the map. The band is a thin 8px — the same
# inset the corner UI sits at — so reaching for buttons never drags
# the view. Minimum-size maps (10×10 — exactly one screen) collapse
# the clamp range and never scroll. Paused while input is locked.

const EDGE_SCROLL_MARGIN : float = 8.0    # edge band width, in pixels
const EDGE_SCROLL_SPEED  : float = 520.0  # pixels per second

var _cam_min : Vector2 = Vector2.ZERO  # clamp range for the camera centre
var _cam_max : Vector2 = Vector2.ZERO

func _process(delta: float) -> void:
    _tick_camera(get_viewport().get_mouse_position(), delta)

## One frame of edge scrolling; split from _process so tests can feed a
## fake mouse position.
func _tick_camera(mouse_pos: Vector2, delta: float) -> void:
    if level == null or _input_locked():
        return
    var vp     : Vector2 = get_viewport().get_visible_rect().size
    var margin : float   = EDGE_SCROLL_MARGIN
    var dir    : Vector2 = Vector2.ZERO
    if mouse_pos.x < margin:
        dir.x -= 1.0
    elif mouse_pos.x > vp.x - margin:
        dir.x += 1.0
    if mouse_pos.y < margin:
        dir.y -= 1.0
    elif mouse_pos.y > vp.y - margin:
        dir.y += 1.0
    if dir == Vector2.ZERO:
        return
    camera.position = (camera.position + dir * EDGE_SCROLL_SPEED * delta) \
            .clamp(_cam_min, _cam_max)

## Fits the camera to the loaded map: clamp bounds from the painted
## rect, starting view at the map centre. Axes where the map is no
## bigger than the screen pin to the map's centre.
func _update_camera_bounds() -> void:
    var used : Rect2i  = ground.get_used_rect()
    var tile : Vector2 = Vector2(ground.tile_set.tile_size)
    var map  : Rect2   = Rect2(ground.position + Vector2(used.position) * tile,
            Vector2(used.size) * tile)
    var half : Vector2 = get_viewport().get_visible_rect().size / 2.0
    var centre : Vector2 = map.get_center()
    _cam_min = map.position + half
    _cam_max = map.end - half
    if _cam_max.x < _cam_min.x:
        _cam_min.x = centre.x
        _cam_max.x = centre.x
    if _cam_max.y < _cam_min.y:
        _cam_min.y = centre.y
        _cam_max.y = centre.y
    camera.position = centre.clamp(_cam_min, _cam_max)

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
var _items_open             : bool       = false  # items panel is showing (modal, reached from the action menu)
var _targeting              : bool       = false  # picking an attack target
var _targetable             : Dictionary = {}     # enemy cell → true while targeting
var _forecast_target        : Variant    = null   # cell whose forecast is up; next click commits
var _menu_cancel_unit       : Variant    = null   # unit whose menu this press cancelled
var _map_menu_open          : bool       = false  # End Turn map menu is showing

# ── Undo stack / history ───────────────────────────────────────────────────────
# Full-state snapshots, one per action, each labelled ("Lord attacks
# Knight") plus one "Turn N" marker at every player-phase start — the
# history browser lists markers and player actions as jump targets.
# Unit states are keyed by node NAME (sibling-unique, stable across
# level reloads) so snapshots stay serialisable for the future
# suspend-to-disk feature.
var undo_stack  : Array = []
var turn_number : int   = 0

# ── Setup ──────────────────────────────────────────────────────────────────────

func _ready() -> void:
    overlay.overlay_alpha = 0.5
    info_portrait.texture = AtlasTexture.new()
    _slash_player = AudioStreamPlayer.new()
    _slash_player.stream = SLASH_SFX
    _slash_player.max_polyphony = 4  # rapid blows layer instead of cutting off
    add_child(_slash_player)
    _music_player = AudioStreamPlayer.new()
    _music_player.volume_db = MUSIC_DB
    add_child(_music_player)
    undo_button.pressed.connect(_open_history)
    history_confirm.pressed.connect(_on_history_confirm)
    history_panel.get_node("VBoxContainer/Buttons/CancelButton").pressed.connect(_on_history_cancel)
    attack_button.pressed.connect(_on_attack_pressed)
    wait_button.pressed.connect(_on_wait_pressed)
    items_button.pressed.connect(_on_items_pressed)
    items_close.pressed.connect(_close_items_menu)
    item_action_button.pressed.connect(_on_item_action_pressed)
    map_menu.get_node("VBoxContainer/EndTurnButton").pressed.connect(_on_end_turn_pressed)
    danger_zone_check.toggled.connect(_on_danger_all_toggled)
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
    unit_map    = {}
    undo_stack  = []
    turn_number = 0
    _history_open = false
    history_panel.visible = false
    _menu_cancel_unit = null
    _close_map_menu()
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

    _hovered_unit = null  # the hovered node is about to be freed
    current_level_path = path
    level = load(path).instantiate()
    level_holder.add_child(level)
    ground          = level.get_node("Ground")
    units_node      = level.get_node("Units")
    loss_conditions = level.loss_conditions
    _play_music(level.music if level.music != null else DEFAULT_MUSIC)
    overlay.position      = ground.position  # the map decides where it sits
    danger_layer.position = ground.position
    _update_camera_bounds()
    _danger_units = {}
    danger_layer.set_union({})
    danger_layer.clear_preview()

    _register_placed_units()
    _refresh_danger()  # the Danger Zone checkbox carries across levels
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
        unit.init_inventory_uses()
        unit.connect("drag_started",   _on_drag_started)
        unit.connect("drag_moved",     _on_drag_moved)
        unit.connect("drop_attempted", _on_drop_attempted)
        unit.connect("clicked",        _on_unit_clicked)
        unit.mouse_entered.connect(_on_unit_mouse_entered.bind(unit))
        unit.mouse_exited.connect(_on_unit_mouse_exited.bind(unit))
        unit_map[cell] = unit

# ── Map queries ────────────────────────────────────────────────────────────────

## A cell is on the map iff the designer painted ground there.
func _in_bounds(cell: Vector2i) -> bool:
    return ground.get_cell_source_id(cell) != -1

## Movement cost for THIS unit to enter a cell: the tile names its
## terrain (TileSet "terrain" custom data) and the unit's movement
## group prices it — all the numbers live in ClassStats.MOVE_COSTS,
## so cavalry pays 3 for the forest an infantry unit crosses for 2.
func _terrain_cost(cell: Vector2i, unit: Area2D) -> int:
    var data : TileData = ground.get_cell_tile_data(cell)
    if data == null:
        return 1
    var terrain : String = data.get_custom_data("terrain")
    return ClassStats.terrain_cost(unit.unit_class, terrain)

# ── Movement range (replaces ChessRules.get_legal_moves) ──────────────────────

## BFS flood-fill accumulating terrain cost, bounded by the unit's move
## range unless max_cost overrides it (the AI passes a huge bound to
## measure whole-map distances). Returns {cell: cheapest cost}. Other
## units block passage and cannot be stopped on; the unit's own cell is
## included at cost 0.
func _get_reach_costs(unit, max_cost: int = -1) -> Dictionary:
    var limit    : int        = unit.move_range if max_cost < 0 else max_cost
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
            var cost : int = costs[cur] + _terrain_cost(nxt, unit)
            if cost > limit:
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
            or _menu_open or _items_open or _targeting \
            or _history_open or _map_menu_open

## Begins a phase: refreshes every unit (the previous team un-greys, the
## new team gets its actions back) and plays the announcement banner.
func _start_phase(team: String) -> void:
    current_team    = team
    _phase_changing = true
    _deselect()
    for unit in units_node.get_children():
        unit.has_acted = false
    if team == PLAYER_TEAM:
        # Enemy-phase snapshots are never jump targets; drop them now
        # that their round is over, then mark the new turn in history.
        while not undo_stack.is_empty() and undo_stack.back()["team"] != PLAYER_TEAM:
            undo_stack.pop_back()
        turn_number += 1
        undo_stack.append(_capture_snapshot("Turn %d" % turn_number, "turn"))
        undo_button.disabled = false
    var title : String = "Player Phase" if team == PLAYER_TEAM else "Enemy Phase"
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
        elif action["type"] == "move":
            # Advancing without a target (aggressive movement trigger).
            _push_undo_snapshot("%s advances" % unit.display_name())
            await _walk_unit(unit, action["to"])
            if gen != _level_generation:
                return
            unit.has_acted = true
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
        # Direct strike gesture: approach the enemy, then the forecast
        # asks for one confirming click before combat commits.
        var launch : Vector2i = attack_targets[target]
        var label  : String   = "%s attacks %s" % [unit.display_name(), unit_map[target].display_name()]
        _deselect()
        _push_undo_snapshot(label)
        _move_then_forecast(unit, launch, target)
        return true
    if target == unit.cell:
        # Acting in place: no move, menu decides (Wait-without-moving).
        _deselect()
        unit.return_to_rest()  # settle a drag dropped back home
        _open_action_menu(unit, false)
        return true
    if target in reachable_cells:
        _deselect()
        _push_undo_snapshot("%s moves" % unit.display_name())
        _move_unit_walking(unit, target)
        return true
    return false

# ── Drag-and-drop input ────────────────────────────────────────────────────────

func _on_drag_started(unit: Area2D) -> void:
    # Only fresh player units drag, and only while input is live.
    if _input_locked() or unit.team != PLAYER_TEAM or unit.has_acted:
        unit.cancel_drag()
        return

    _select_unit(unit)

## Makes a unit the live selection and shows its ranges — the state a
## first click (or mouse-down) puts a unit in.
func _select_unit(unit: Area2D) -> void:
    overlay.clear_range()
    selected_unit = unit
    _refresh_unit_info()      # selection hides the hover card
    _refresh_hover_preview()  # …and the enemy range preview
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
    # The press that cancelled this unit's menu ends at the selection —
    # click 3 of the cycle: select → menu → back to selection.
    if unit == _menu_cancel_unit:
        _menu_cancel_unit   = null
        click_selected_unit = unit
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
    _menu_cancel_unit = null  # only ever lives for a single press
    if _items_open:
        # Outside the items panel = the same as its × button: back to
        # the action menu, nothing spent.
        _close_items_menu()
        return
    if _menu_open:
        # Any press outside the menu panel (its buttons and backing
        # consume their own clicks) aborts the pending action.
        _cancel_action_menu()
        return
    if _map_menu_open:
        _close_map_menu()
        return
    if _targeting:
        _handle_target_click(cell)
        return
    _handle_click_at(cell)

## Click-style counterpart of _on_drop_attempted: acts on the selection
## with the clicked cell through the same _try_act_at seam. With nothing
## selected, an empty map tile opens the map menu (End Turn…).
func _handle_click_at(cell: Vector2i) -> void:
    if _input_locked():
        return
    if click_selected_unit == null:
        # Presses on player units select via physics picking after this;
        # enemies toggle their danger zone, and a genuinely empty on-map
        # tile summons the map menu.
        var occupant = unit_map.get(cell)
        if occupant != null and occupant.team == ENEMY_TEAM:
            _toggle_danger(occupant)
        elif occupant == null and _in_bounds(cell):
            _open_map_menu()
        return
    # Press on the selected unit's own cell: leave it for the clicked
    # signal, which opens the in-place action menu (or a drag begins).
    if cell == click_selected_unit.cell:
        return
    var unit : Area2D = click_selected_unit
    if not _try_act_at(unit, cell):
        _deselect()

# ── Map menu ───────────────────────────────────────────────────────────────────
# Opened by clicking an empty tile with nothing selected. End Turn stays
# the BOTTOM entry (like Wait in the unit menu); future commands (unit
# list, objectives, options…) stack above it in the same VBoxContainer.

func _open_map_menu() -> void:
    _map_menu_open   = true
    map_menu.visible = true
    map_menu.call_deferred("reset_size")

func _close_map_menu() -> void:
    _map_menu_open   = false
    map_menu.visible = false

## End Turn: hand the round to the enemy with unmoved units left as-is.
## Snapshotted like any player action, so history shows "End turn" and
## jumping there restores the moment before the hand-off.
func _on_end_turn_pressed() -> void:
    if not _map_menu_open:
        return
    _close_map_menu()
    _push_undo_snapshot("End turn")
    _start_phase(ENEMY_TEAM)

func _deselect() -> void:
    click_selected_unit = null
    selected_unit       = null
    reachable_cells     = []
    attack_targets      = {}
    overlay.clear_all()
    _clear_pending()
    _refresh_unit_info()      # the hover card may come back once nothing is selected
    _refresh_hover_preview()

# ── Danger zones ───────────────────────────────────────────────────────────────
# Clicking an enemy (with nothing selected) toggles it into the tracked
# set: the unit tints dark red and DangerLayer shades every cell any
# tracked enemy could strike, outlined only along the union's outer
# boundary. The Danger Zone button shows EVERY enemy's zone at once
# without tinting anyone; individual tracking rides on top of it.
# Hovering any unit whose zone isn't already displayed previews its
# range faintly — player units included.

var _danger_units : Dictionary = {}      # unit → true while tracked
var _danger_all   : bool       = false   # Danger Zone button state (shell-persistent)

func _on_danger_all_toggled(pressed: bool) -> void:
    _danger_all = pressed
    _refresh_danger()
    _refresh_hover_preview()

## True when this unit's threat is already on screen at full strength.
func _zone_already_shown(unit: Area2D) -> bool:
    return _danger_units.has(unit) \
            or (_danger_all and unit.team == ENEMY_TEAM)

func _toggle_danger(unit: Area2D) -> void:
    if _danger_units.has(unit):
        _danger_units.erase(unit)
        unit.set_danger_marked(false)
    else:
        _danger_units[unit] = true
        unit.set_danger_marked(true)
    _refresh_danger()
    _refresh_hover_preview()  # tracked units stop showing the preview

## Every cell a unit could strike this turn: neighbours of everywhere it
## can stand (its own melee coverage), movement and blockers included.
func _threat_cells(unit: Area2D, into: Dictionary) -> void:
    var costs : Dictionary = _get_reach_costs(unit)
    for cell in costs:
        for dir in ORTHO_DIRS:
            var n : Vector2i = cell + dir
            if _in_bounds(n):
                into[n] = true

## Recomputes the union. Called whenever the board changes shape —
## moves, deaths, restores — so zones track the live battlefield.
func _refresh_danger() -> void:
    for unit in _danger_units.keys():
        if not is_instance_valid(unit) or not unit.visible:
            _danger_units.erase(unit)
    var union : Dictionary = {}
    if _danger_all:
        for unit in units_node.get_children():
            if unit.team == ENEMY_TEAM and unit.visible:
                _threat_cells(unit, union)
    else:
        for unit in _danger_units:
            _threat_cells(unit, union)
    danger_layer.set_union(union)

## Faint range preview while hovering any unit — either team — in the
## idle state, unless its zone is already displayed at full strength.
func _refresh_hover_preview() -> void:
    var show : bool = _hovered_unit != null \
            and is_instance_valid(_hovered_unit) and _hovered_unit.visible \
            and not _zone_already_shown(_hovered_unit) \
            and selected_unit == null and click_selected_unit == null \
            and not _input_locked()
    if not show:
        danger_layer.clear_preview()
        return
    var costs : Dictionary = _get_reach_costs(_hovered_unit)
    danger_layer.show_preview(costs.keys(), _get_attack_fringe(costs))

# ── Unit info card (hover) ─────────────────────────────────────────────────────
# A neutral greyscale card in the top-left showing the hovered unit's
# portrait (sprite for now), name, and hp. Shown for both teams, only
# in the idle state: it disappears the moment a unit is selected or any
# animation/menu owns the screen.

var _hovered_unit : Variant = null   # Area2D under the mouse, or null

func _on_unit_mouse_entered(unit: Area2D) -> void:
    _hovered_unit = unit
    _refresh_unit_info()
    _refresh_hover_preview()

func _on_unit_mouse_exited(unit: Area2D) -> void:
    if _hovered_unit == unit:
        _hovered_unit = null
        _refresh_unit_info()
        _refresh_hover_preview()

## Recomputes the card's visibility and contents. Called from the hover
## signals and from the selection/state transitions that should hide or
## restore it.
func _refresh_unit_info() -> void:
    var showable : bool = _hovered_unit != null \
            and is_instance_valid(_hovered_unit) and _hovered_unit.visible \
            and selected_unit == null and click_selected_unit == null \
            and not _input_locked()
    if not showable:
        info_panel.visible = false
        return
    var sprite : Sprite2D = _hovered_unit.get_node("Sprite2D")
    var portrait : AtlasTexture = info_portrait.texture
    portrait.atlas  = sprite.texture      # portrait art replaces this later
    portrait.region = sprite.region_rect
    info_name.text = _hovered_unit.display_name()
    info_hp.text   = "%d / %d" % [_hovered_unit.hp, _hovered_unit.max_hp]
    info_bar_fill.size = Vector2(
            INFO_BAR_WIDTH * _hovered_unit.hp / float(_hovered_unit.max_hp),
            info_bar_fill.size.y)
    info_panel.visible = true

# ── Action menu (the FE move-then-menu flow) ──────────────────────────────────
# Moving a unit no longer ends its turn: the unit walks, then this
# centered menu owns the turn until Attack or Wait resolves it. Attack
# only lists when an enemy stands within weapon reach of the unit's
# current cell; picking it swaps the menu for target selection (red
# squares on the adjacent enemies — click one to strike, click anything
# else to come back to the menu). Items joins these buttons later.
# Clicking anywhere OUTSIDE the open menu cancels the pending action:
# the approach move is reverted and the unit returns to being merely
# selected (the FE B-button). Menu buttons are Controls, so the GUI
# consumes their clicks before _unhandled_input or physics picking see
# them; unit drags stay locked out while the menu owns the turn.

## Opens the menu for a unit that has just moved (snapshot_taken: its
## move already pushed the undo snapshot) or is acting in place.
func _open_action_menu(unit: Area2D, snapshot_taken: bool) -> void:
    _pending_unit           = unit
    _pending_snapshot_taken = snapshot_taken
    _menu_open              = true
    attack_button.visible   = not _adjacent_enemies(unit).is_empty()
    items_button.visible    = not unit.inventory.is_empty()
    action_menu.visible     = true
    # Shrink the panel to its (new) content once the container has
    # re-sorted — fewer options means a shorter menu, same width.
    action_menu.call_deferred("reset_size")

## Resets every pending-action flag and hides the menu/forecast UI.
func _clear_pending() -> void:
    _pending_unit           = null
    _pending_snapshot_taken = false
    _menu_open              = false
    _items_open             = false
    _targeting              = false
    _targetable             = {}
    _forecast_target        = null
    action_menu.visible     = false
    items_panel.visible     = false
    forecast_panel.visible  = false
    item_action_button.visible = false

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
    _menu_open              = false
    action_menu.visible     = false
    _targeting              = true
    _targetable             = {}
    _forecast_target        = null
    forecast_panel.visible  = false
    for cell in _adjacent_enemies(_pending_unit):
        _targetable[cell] = true
    overlay.show_attack_cells(_targetable.keys())

## A click while picking a target: the first click on a marked enemy
## raises the battle forecast, a second click on the same enemy commits
## the attack (clicking another target re-forecasts it); anything else
## returns to the action menu.
func _handle_target_click(cell: Vector2i) -> void:
    var unit          : Area2D = _pending_unit
    var have_snapshot : bool   = _pending_snapshot_taken
    if _targetable.has(cell):
        if _forecast_target == cell:
            var defender : Area2D = unit_map[cell]
            if have_snapshot:
                _set_last_label("%s attacks %s" % [unit.display_name(), defender.display_name()])
            _clear_pending()
            overlay.clear_all()
            _begin_combat(unit, defender, unit.cell, not have_snapshot)
        else:
            _forecast_target = cell
            _show_forecast(unit, unit_map[cell])
    else:
        _targeting              = false
        _targetable             = {}
        _forecast_target        = null
        forecast_panel.visible  = false
        overlay.clear_range()
        _open_action_menu(unit, have_snapshot)

## Direct attack gesture: walk to the launch cell, then enter targeting
## with the forecast already up on the chosen enemy — the confirming
## click keeps attacks deliberate. The approach snapshot is already
## pushed, so cancelling from here rewinds cleanly.
func _move_then_forecast(unit: Area2D, launch: Vector2i, target_cell: Vector2i) -> void:
    await _walk_unit(unit, launch)
    _pending_unit           = unit
    _pending_snapshot_taken = true
    _targeting              = true
    _targetable             = {}
    for cell in _adjacent_enemies(unit):
        _targetable[cell] = true
    overlay.show_attack_cells(_targetable.keys())
    _forecast_target = target_cell
    _show_forecast(unit, unit_map[target_cell])

# ── Battle forecast ────────────────────────────────────────────────────────────
# The pre-combat readout: attacker name in a blue box on top, enemy in
# a red box below, each unit's equipped weapon under/over its name, and
# three columns between — blue attacker values, grey stat labels
# (HP / Might; hit and crit later), red defender values. Shown opposite
# the attacker's half of the map so it never covers the fight.

var _forecast_side_left : bool = false

## Display name of the unit's equipped weapon, for the forecast.
func _equipped_weapon_name(unit: Area2D) -> String:
    var index : int = Items.equipped_index(unit)
    return Items.display_name(unit.inventory[index]) if index >= 0 else "Unarmed"

func _show_forecast(attacker: Area2D, defender: Area2D) -> void:
    fc_atk_name.text   = attacker.display_name()
    fc_def_name.text   = defender.display_name()
    fc_atk_weapon.text = _equipped_weapon_name(attacker)
    fc_def_weapon.text = _equipped_weapon_name(defender)
    fc_blue_hp.text    = str(attacker.hp)
    fc_blue_mt.text    = str(_attack_damage(attacker, defender))
    fc_red_hp.text     = str(defender.hp)
    fc_red_mt.text     = str(_attack_damage(defender, attacker))
    # Side-pick from the attacker's on-SCREEN position (camera-aware):
    # the panel goes to whichever half the attacker isn't on.
    var screen_x : float = attacker.get_global_transform_with_canvas().origin.x
    _forecast_side_left = screen_x >= get_viewport().get_visible_rect().size.x / 2.0
    forecast_panel.visible = true
    forecast_panel.call_deferred("reset_size")
    call_deferred("_place_forecast")

## Positions the panel after the container has sized itself: vertically
## centred, hugging the side of the screen away from the attacker.
func _place_forecast() -> void:
    if not forecast_panel.visible:
        return
    var vp : Vector2 = forecast_panel.get_viewport_rect().size
    var x  : float   = 16.0 if _forecast_side_left \
            else vp.x - forecast_panel.size.x - 16.0
    forecast_panel.position = Vector2(x, (vp.y - forecast_panel.size.y) / 2.0)

## A click outside the open action menu: abort the pending action, snap
## the unit back to where its turn started (reverting the approach move
## by popping its own undo snapshot), and leave it merely selected — as
## if it had just been clicked once.
func _cancel_action_menu() -> void:
    if _pending_unit == null:
        return
    var unit  : Area2D = _pending_unit
    var moved : bool   = _pending_snapshot_taken
    _clear_pending()
    if moved:
        _restore_snapshot(undo_stack.pop_back())
        undo_button.disabled = undo_stack.is_empty()
    _select_unit(unit)
    click_selected_unit = unit
    # If this press was on the unit itself, its clicked signal is about
    # to fire — remember to swallow it so the third click in the
    # click-click-click cycle lands on the selection, not a fresh menu.
    _menu_cancel_unit = unit

## Wait: end the pending unit's turn where it stands.
func _on_wait_pressed() -> void:
    if _pending_unit == null:
        return
    var unit          : Area2D = _pending_unit
    var have_snapshot : bool   = _pending_snapshot_taken
    var label         : String = "%s waits" % unit.display_name()
    _clear_pending()
    if have_snapshot:
        _set_last_label(label)
    else:
        _push_undo_snapshot(label)
    _finish_action(unit)

# ── Items menu ─────────────────────────────────────────────────────────────────
# Reached from the action menu's Items entry (shown only when the unit
# carries something). The panel lists up to Items.MAX_SLOTS rows —
# fewer items make a shorter panel, sized like the action menu. Clicking
# a row pops the shared ItemActionButton just OUTSIDE the panel's right
# edge, aligned with that row — it floats beside the box so the box
# itself never resizes. The button reads Equip for weapons, Use for
# everything else (potions now, staves later — those are never equipped,
# they just sit in the inventory). Equip is free — the weapon moves to
# the top of the inventory (the equipped slot) and the turn continues;
# Use is the unit's action for the turn, ending it like Wait does. The ×
# button and any click outside both return to the action menu with
# nothing spent.

const ITEM_ACTION_GAP : float = 10.0  # panel edge → floating button

var _item_selected : int   = -1  # row the floating action button is on
var _item_rows     : Array = []  # row Buttons in list order (for placement)

## Items: swap the action menu for this unit's item list.
func _on_items_pressed() -> void:
    if _pending_unit == null:
        return
    _menu_open          = false
    action_menu.visible = false
    _items_open         = true
    _rebuild_item_list(_pending_unit)
    items_panel.visible = true
    items_panel.call_deferred("reset_size")

## Fills the panel with one button per carried item (menu-button style,
## created fresh each opening — freed and rebuilt so the panel always
## matches the inventory). Weapons list by name alone (durability is
## undecided, so no charge readout); consumables keep their "2/3"; the
## equipped weapon is marked (E).
func _rebuild_item_list(unit: Area2D) -> void:
    _item_selected             = -1
    _item_rows                 = []
    item_action_button.visible = false
    for child in items_vbox.get_children():
        if child.name != "Header":
            # Deferred free: Equip rebuilds from inside a row button's own
            # pressed signal, and freeing the emitter mid-emission crashes.
            items_vbox.remove_child(child)
            child.queue_free()
    var equipped : int = Items.equipped_index(unit)
    for index in mini(unit.inventory.size(), Items.MAX_SLOTS):
        var id  : String = unit.inventory[index]
        var btn : Button = Button.new()
        btn.text = Items.display_name(id) if Items.is_weapon(id) \
                else "%s %d/%d" % [Items.display_name(id),
                        unit.inventory_uses[index], Items.max_uses(id)]
        if index == equipped:
            btn.text += " (E)"
        btn.disabled = Items.unusable_by(id, unit)  # e.g. healing at full hp
        btn.custom_minimum_size = Vector2(200, 48)
        btn.add_theme_font_size_override("font_size", 24)
        btn.pressed.connect(_on_item_row_pressed.bind(index))
        _item_rows.append(btn)
        items_vbox.add_child(btn)

## Clicking a row toggles the floating Equip/Use button, parked beside
## the panel's right edge in line with that row — the pop-out is pure
## selection, nothing is spent yet.
func _on_item_row_pressed(index: int) -> void:
    if not _items_open or _pending_unit == null:
        return
    if _item_selected == index:
        _item_selected             = -1
        item_action_button.visible = false
        return
    _item_selected = index
    var id  : String = _pending_unit.inventory[index]
    var row : Button = _item_rows[index]
    item_action_button.text = "Equip" if Items.is_weapon(id) else "Use"
    item_action_button.reset_size()  # width follows the label
    item_action_button.global_position = Vector2(
            items_panel.global_position.x + items_panel.size.x + ITEM_ACTION_GAP,
            row.global_position.y + (row.size.y - item_action_button.size.y) / 2.0)
    item_action_button.visible = true

## The floating button dispatches on what its row holds: Equip for
## weapons (free), Use for consumables (the unit's action).
func _on_item_action_pressed() -> void:
    if not _items_open or _pending_unit == null or _item_selected < 0:
        return
    var index : int = _item_selected
    if index >= _pending_unit.inventory.size():
        return
    if Items.is_weapon(_pending_unit.inventory[index]):
        _on_equip_pressed(index)
    else:
        _on_item_pressed(index)

## Equip: move the weapon (and its charges) to the top of the inventory,
## where the equipped weapon lives. Free — the items panel stays open and
## the unit still has its action. No snapshot is pushed: equipping isn't
## an undoable action, and if the pending move's snapshot predates it we
## sync that snapshot so cancelling the move keeps the new weapon (FE
## behaviour: item management survives the B-cancel).
func _on_equip_pressed(index: int) -> void:
    if _pending_unit == null or not _items_open:
        return
    var unit : Area2D = _pending_unit
    if index >= unit.inventory.size():
        return
    var id   : String = unit.inventory[index]
    var uses : int    = unit.inventory_uses[index]
    unit.inventory.remove_at(index)
    unit.inventory_uses.remove_at(index)
    unit.inventory.insert(0, id)
    unit.inventory_uses.insert(0, uses)
    if _pending_snapshot_taken and not undo_stack.is_empty():
        var state : Variant = undo_stack.back()["unit_states"].get(String(unit.name))
        if state != null:
            state["items"]     = unit.inventory.duplicate()
            state["item_uses"] = unit.inventory_uses.duplicate()
    _rebuild_item_list(unit)
    items_panel.call_deferred("reset_size")

## × or a click outside the panel: back to the unit's action menu.
func _close_items_menu() -> void:
    _items_open                = false
    items_panel.visible        = false
    item_action_button.visible = false
    if _pending_unit != null:
        _open_action_menu(_pending_unit, _pending_snapshot_taken)

## Use (the floating action button on a consumable's row): using an item
## ends the unit's turn. Effects dispatch on the item's definition keys —
## only "heal" exists yet; the undo snapshot is taken before anything is
## consumed, so undo returns charge and health alike. Spending the last
## charge removes the item from the inventory.
func _on_item_pressed(index: int) -> void:
    if _pending_unit == null or not _items_open:
        return
    var unit          : Area2D = _pending_unit
    var have_snapshot : bool   = _pending_snapshot_taken
    if index >= unit.inventory.size():
        return
    var id    : String = unit.inventory[index]
    var label : String = "%s uses %s" % [unit.display_name(), Items.display_name(id)]
    _clear_pending()
    if have_snapshot:
        _set_last_label(label)
    else:
        _push_undo_snapshot(label)
    unit.inventory_uses[index] -= 1
    if unit.inventory_uses[index] <= 0:
        unit.inventory.remove_at(index)
        unit.inventory_uses.remove_at(index)
    unit.heal(Items.heal_amount(id))
    _finish_action(unit)

# ── Move application ───────────────────────────────────────────────────────────

const WALK_TIME_PER_TILE : float = 0.1  # seconds per step at 1x speed

var _walking : bool = false   # input is ignored while a unit walks

## Commits a move instantly: updates unit_map, cell, and rest position.
func _move_unit(unit: Area2D, to_cell: Vector2i) -> void:
    unit_map.erase(unit.cell)
    unit.move_to(to_cell, overlay.cell_center_world(to_cell))
    unit_map[to_cell] = unit
    _refresh_danger()  # blockers moved; tracked zones may have reshaped

## Reconstructs the cheapest path from the unit to target (start cell
## included) within its move range.
func _build_path(unit: Area2D, target: Vector2i) -> Array:
    return _build_path_through(_get_reach_costs(unit), unit.cell, target, unit)

## Path reconstruction over any cost field, by descending it: each step
## back goes to a neighbour whose cost is exactly this cell's cost minus
## its terrain cost (for the pathing unit — costs are per movement
## group) — such a neighbour always exists on an optimal field.
func _build_path_through(costs: Dictionary, start: Vector2i, target: Vector2i,
        unit: Area2D) -> Array:
    var path : Array    = [target]
    var cur  : Vector2i = target
    while cur != start:
        var stepped : bool = false
        for dir in ORTHO_DIRS:
            var prev : Vector2i = cur + dir
            if costs.has(prev) and costs[prev] == costs[cur] - _terrain_cost(cur, unit):
                cur     = prev
                stepped = true
                break
        if not stepped:
            push_warning("No path back from %s to %s" % [target, start])
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
# survives. Damage is attack + equipped weapon might — _attack_damage() is
# the seam where the remaining rpg stats (def, crit, …) plug in later. The
# future weapon-choice menu opens inside _begin_combat, between the
# approach move and the bump — same stash-state-and-resume pattern as the
# chess promotion panel.

const BUMP_TIME     : float = 0.12  # seconds each way
const BUMP_DISTANCE : float = 0.45  # fraction of the way into the target's cell
const SLASH_SFX     : AudioStream = preload("res://assets/slash.wav")

var _combat_active : bool = false   # input is ignored while the bumps play
var _slash_player  : AudioStreamPlayer  # created in _ready

## Fired when an engagement fully resolves; _run_enemy_phase awaits it.
signal combat_finished

func _attack_damage(attacker, _defender) -> int:
    var equipped : int = Items.equipped_index(attacker)
    var might    : int = Items.might(attacker.inventory[equipped]) if equipped >= 0 else 0
    return attacker.attack + might  # defender's def subtracts here later

## A blow landing at the bump's apex: the slash sound plus the damage.
## Future impact effects (crit flashes, hit sparks) belong here too.
func _strike(target: Area2D, dmg: int) -> void:
    _slash_player.play()
    target.take_damage(dmg)

## push_snapshot is false when the attacker's approach move already
## pushed one (the menu flow) — move + attack stay a single undo step.
func _begin_combat(attacker: Area2D, defender: Area2D, launch_cell: Vector2i,
        push_snapshot: bool = true) -> void:
    if push_snapshot:
        _push_undo_snapshot("%s attacks %s" %
                [attacker.display_name(), defender.display_name()])
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
    tw.tween_callback(_strike.bind(defender, atk_dmg))
    tw.tween_property(attacker, "global_position", atk_home, _anim(BUMP_TIME))
    tw.tween_callback(func() -> void: attacker.z_index = 1)

    if counters:
        var def_dmg : int = _attack_damage(defender, attacker)
        tw.tween_callback(func() -> void: defender.z_index = 10)
        tw.tween_property(defender, "global_position",
                def_home.lerp(atk_home, BUMP_DISTANCE), _anim(BUMP_TIME))
        tw.tween_callback(_strike.bind(attacker, def_dmg))
        tw.tween_property(defender, "global_position", def_home, _anim(BUMP_TIME))
        tw.tween_callback(func() -> void: defender.z_index = 1)

    tw.tween_callback(_end_combat.bind(attacker, defender))

func _end_combat(attacker: Area2D, defender: Area2D) -> void:
    for unit in [attacker, defender]:
        if unit.hp <= 0:
            unit_map.erase(unit.cell)
            unit.defeat()
    _combat_active = false
    _refresh_danger()  # deaths reshape (or dissolve) tracked zones
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

# ── Music ──────────────────────────────────────────────────────────────────────
# One looping track while a level runs. Levels pick their song via the
# `music` export on the Level root (empty = the default battle theme),
# so a desert map can swap in its own in the Inspector with no code.
# _play_music is a no-op when the incoming level reuses the playing
# track, so restarts and same-song progression never skip a beat; the
# loop itself is baked at import (edit/loop_mode=2 = Forward in
# battle.wav.import — NB the importer's enum is offset from the
# stream's: import 2 = AudioStreamWAV.LOOP_FORWARD).

const DEFAULT_MUSIC : AudioStream = preload("res://assets/battle.wav")
const MUSIC_DB      : float       = -6.0  # sits under the sfx

var _music_player : AudioStreamPlayer  # created in _ready

func _play_music(track: AudioStream) -> void:
    if _music_player.stream == track and _music_player.playing:
        return
    _music_player.stream = track
    _music_player.play()

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

## The Settings button toggles its panel, and works even while input is
## otherwise locked — scene changes tear down any animation safely.
## (Lord appearance is level-authored via each unit's sprite_variant.)
func _on_settings_pressed() -> void:
    if _settings_open:
        _on_settings_back()
        return
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

## Captures the complete board state as pure data (unit states keyed by
## node name — no object references, so this is disk-serialisable).
func _capture_snapshot(label: String, type: String = "action") -> Dictionary:
    var states : Dictionary = {}
    for unit in units_node.get_children():
        states[String(unit.name)] = {
            "cell"     : unit.cell,
            "world"    : unit.global_position,
            "rest"     : unit._rest_position,
            "visible"  : unit.visible,
            "pickable" : unit.input_pickable,
            "hp"       : unit.hp,
            "acted"    : unit.has_acted,
            "items"    : unit.inventory.duplicate(),
            "item_uses": unit.inventory_uses.duplicate(),
        }
    return {
        "unit_states": states,
        "team"       : current_team,
        "turn"       : turn_number,
        "label"      : label,
        "type"       : type,
    }

func _push_undo_snapshot(label: String) -> void:
    undo_stack.append(_capture_snapshot(label))
    undo_button.disabled = false

## Rewrites the newest snapshot's label once the action it precedes is
## fully decided (a move finalises as "… waits" or "… attacks …").
func _set_last_label(label: String) -> void:
    if not undo_stack.is_empty():
        undo_stack.back()["label"] = label

# ── History browser ────────────────────────────────────────────────────────────
# The Undo button opens a left-side panel listing every player action
# and "Turn N" marker back to the start of the map, newest first.
# Clicking an entry PREVIEWS that board state live (the camera will let
# players scout it fully later); Confirm commits the jump and discards
# the forward history, Cancel returns to the present.

@onready var history_panel   : PanelContainer = $UI/HistoryPanel
@onready var history_list    : VBoxContainer  = $UI/HistoryPanel/VBoxContainer/Scroll/HistoryList
@onready var history_confirm : Button         = $UI/HistoryPanel/VBoxContainer/Buttons/ConfirmButton

var _history_open     : bool       = false
var _history_selected : int        = -1   # index into undo_stack, -1 = none
var _history_present  : Dictionary = {}   # live state to return to on cancel

func _open_history() -> void:
    if _history_open:
        # The Undo button toggles the browser shut (previews cancel).
        _on_history_cancel()
        return
    if _input_locked() or undo_stack.is_empty():
        return
    _history_open     = true
    _history_selected = -1
    _history_present  = _capture_snapshot("Present")
    history_confirm.disabled = true
    _deselect_hover_only()
    for child in history_list.get_children():
        child.queue_free()
    # Newest first; enemy snapshots are pruned each turn and never listed.
    for i in range(undo_stack.size() - 1, -1, -1):
        var snap : Dictionary = undo_stack[i]
        if snap["team"] != PLAYER_TEAM:
            continue
        var btn : Button = Button.new()
        btn.text = ("— %s —" % snap["label"]) if snap["type"] == "turn" else snap["label"]
        btn.alignment = HORIZONTAL_ALIGNMENT_CENTER if snap["type"] == "turn" \
                else HORIZONTAL_ALIGNMENT_LEFT
        btn.toggle_mode = true
        btn.button_group = _history_group
        btn.pressed.connect(_on_history_entry.bind(i))
        history_list.add_child(btn)
    history_panel.visible = true

var _history_group : ButtonGroup = ButtonGroup.new()

func _deselect_hover_only() -> void:
    _hovered_unit = null
    _refresh_unit_info()

## Clicking an entry: preview that snapshot on the board.
func _on_history_entry(index: int) -> void:
    if not _history_open:
        return
    _history_selected = index
    _restore_snapshot(undo_stack[index])
    history_confirm.disabled = false

## Confirm: the previewed state becomes the present; everything after
## it (including the selected entry itself) is discarded.
func _on_history_confirm() -> void:
    if not _history_open:
        return
    if _history_selected < 0:
        return
    undo_stack.resize(_history_selected)
    _close_history()

## Cancel: back to the present exactly as it was.
func _on_history_cancel() -> void:
    if not _history_open:
        return
    if _history_selected >= 0:
        _restore_snapshot(_history_present)
    _close_history()

func _close_history() -> void:
    _history_open         = false
    _history_selected     = -1
    _history_present      = {}
    history_panel.visible = false
    undo_button.disabled  = undo_stack.is_empty()

## Quick single-step undo — still used by the Game Over screen. Restores
## phase state too, so undoing the action that ended a phase steps back
## into that phase. Enemy actions are deterministic reactions, so
## snapshots taken during the enemy phase collapse into the player
## action that provoked them: one undo lands back on the player's input.
func undo_move() -> void:
    if _input_locked():
        return
    _deselect()
    if undo_stack.is_empty():
        return

    var snap : Dictionary = undo_stack.pop_back()
    while snap["team"] != PLAYER_TEAM and not undo_stack.is_empty():
        snap = undo_stack.pop_back()
    _restore_snapshot(snap)
    undo_button.disabled = undo_stack.is_empty()

## Restores a snapshot's unit states and phase bookkeeping. Shared by
## undo, the action-menu cancel, and the history browser's preview/jump.
func _restore_snapshot(snap: Dictionary) -> void:
    var states : Dictionary = snap["unit_states"]
    unit_map.clear()
    for unit in units_node.get_children():
        if not states.has(String(unit.name)):
            # Not in this snapshot (a unit spawned later, once
            # reinforcements exist) — it doesn't exist at that moment.
            unit.defeat()
            continue
        var s : Dictionary = states[String(unit.name)]
        unit.cell            = s["cell"]
        unit.global_position = s["world"]
        unit._rest_position  = s["rest"]
        unit.visible         = s["visible"]
        unit.input_pickable  = s["pickable"]
        unit.hp              = s["hp"]
        unit.has_acted       = s["acted"]
        unit.inventory       = s["items"].duplicate()
        unit.inventory_uses  = s["item_uses"].duplicate()
        unit.queue_redraw()
        if unit.visible:
            unit_map[unit.cell] = unit

    current_team    = snap["team"]
    turn_number     = snap["turn"]
    _refresh_danger()  # restored board; tracked zones follow it
