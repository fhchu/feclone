# unit.gd
# Attached to the Area2D root of unit.tscn.
# Handles sprite selection, drag-and-drop input, and hover reporting.
# Does NOT know game rules — it signals main.gd for all decisions.
#
# @tool so level designers get live feedback in the editor: instance
# unit.tscn under Main/Units, drag it over a tile, and pick Unit Class /
# Team / Move Range in the Inspector — the sprite updates immediately.
# main.gd snaps every placed unit to its nearest cell when the game starts.

@tool
extends Area2D

# ── Sprite sheet layout ────────────────────────────────────────────────────────
# Must match the actual pixel dimensions of sprites_unit_map.png.
const SPRITE_SIZE : int = 64

# Sprite cells come from ClassStats (classes and cells are no longer
# 1:1 — variants and shared art exist). The sheet is stacked blue/red
# row-pairs: ClassStats picks the (column, pair) cell and the team
# picks the row within that pair.
const TEAM_ROW : Dictionary = {
    "blue": 0, "red": 1
}

# ── Designer-facing properties (set in the Inspector) ──────────────────────────
@export_enum("archer", "cavalier", "cleric", "knight", "lord", "mage", "pegasus_knight", "soldier")
var unit_class : String = "lord":
    set(value):
        unit_class = value
        _refresh_sprite()

## Cosmetic sprite variant where the class offers one (the lord's
## male/female pair); classes without the variant show their default.
@export_enum("female", "male")
var sprite_variant : String = "male":
    set(value):
        sprite_variant = value
        _refresh_sprite()

## Optional unique-character name ("Lyon", "Cormag"). Empty means the
## unit is a generic and displays its class name.
@export var character_name : String = ""

@export_enum("blue", "red")
var team : String = "blue":
    set(value):
        team = value
        _refresh_sprite()
        queue_redraw()  # health bar fill colour follows the team

# Stats come from the class (see scripts/class_stats.gd) — no exp or
# levels yet, so class bases are the whole stat line.
var move_range : int:
    get:
        return ClassStats.mov(unit_class)

@export_range(1, 99) var max_hp : int = 2:
    set(value):
        max_hp = value
        hp = value  # editor shows a full bar; runtime starts at full health
        queue_redraw()

## Base attack power. Combat damage is attack + the equipped weapon's
## might (see _attack_damage in main.gd), so an unarmed unit deals this.
@export_range(0, 99) var attack : int = 1

## SP (skill points) generated every time this unit strikes or is
## struck; the equipped weapon's aptitude adds on top (see _sp_gain in
## main.gd). Stat name is provisional — the mechanic is unique to this
## game.
@export_range(0, 99) var aptitude : int = 0

## Ceiling on stored SP; generation past it is simply lost.
@export_range(0, 99) var max_sp : int = 10

## Item ids this unit carries (definitions in scripts/items.gd). The
## items menu lists them in order and shows at most Items.MAX_SLOTS.
@export var inventory : Array[String] = []

## Charges left per inventory slot, parallel to `inventory` — runtime
## state, filled from the item definitions when main.gd registers the
## unit (levels re-instance their units, so charges reset per level).
var inventory_uses : Array[int] = []

func init_inventory_uses() -> void:
    inventory_uses = []
    for id in inventory:
        inventory_uses.append(Items.max_uses(id))

# Which EnemyAI strategies drive this unit while it's on the enemy team
# (ignored for player units) — see scripts/enemy_ai.gd. The dropdowns
# grow as new behaviours land (thieves, bosses, reinforcements…).
@export_group("Enemy AI")
@export_enum("aggressive", "guard") var ai_movement : String = "guard"
@export_enum("default") var ai_targeting : String = "default"
@export_group("")

# ── Runtime state ──────────────────────────────────────────────────────────────
var cell : Vector2i = Vector2i(-1, -1)   # assigned by main.gd on registration
var hp   : int      = 2                  # kept in sync by the max_hp setter
var sp   : int      = 0                  # skill points; builds in combat, and levels re-instance units so each starts at 0

## True once the unit has taken its action this phase; main.gd resets it
## at phase start. The sprite greys out while set.
var has_acted : bool = false:
    set(value):
        has_acted = value
        _apply_acted_tint()

# Shader uniforms while has_acted (see assets/unit_tint.gdshader).
const ACTED_SATURATION : float = 0.15
const ACTED_BRIGHTNESS : float = 0.7

# ── Health & SP bars ───────────────────────────────────────────────────────────
const BAR_SIZE     : Vector2 = Vector2(44, 5)
const BAR_OFFSET_Y : float   = 24.0  # below the sprite, inside the tile
const BAR_BORDER   : Color   = Color(0.0, 0.0, 0.0, 0.8)
const BAR_MISSING  : Color   = Color(0.22, 0.22, 0.25)  # dark grey
const BAR_FILL     : Dictionary = {
    "blue": Color(0.25, 0.55, 1.0),
    "red" : Color(0.95, 0.25, 0.3),
}

# The SP gauge sits directly under the health bar: black while empty,
# filling with yellow (the SP colour everywhere — forecast badge, hover
# card) as blows generate skill points. Same yellow for both teams.
const SP_BAR_SIZE : Vector2 = Vector2(44, 3)
const SP_BAR_GAP  : float   = 1.0  # below the hp bar's border
const SP_EMPTY    : Color   = Color(0.0, 0.0, 0.0)
const SP_FILL     : Color   = Color(1.0, 0.85, 0.3)

# ── Drag state ─────────────────────────────────────────────────────────────────
const DRAG_THRESHOLD : float = 6.0  # pixels of mouse travel before a press counts as a drag

var _is_dragging       : bool    = false
var _drag_offset       : Vector2 = Vector2.ZERO
var _rest_position     : Vector2 = Vector2.ZERO  # world pos of current cell
var _mouse_press_world : Vector2 = Vector2.ZERO

# ── Signals ────────────────────────────────────────────────────────────────────
## Fired when the player starts dragging this unit.
signal drag_started(unit: Area2D)
## Fired every frame while dragging with the current world position.
signal drag_moved(unit: Area2D, world_pos: Vector2)
## Fired when the player releases the unit after a drag.
signal drop_attempted(unit: Area2D, world_pos: Vector2)
## Fired when the press is released with under DRAG_THRESHOLD of movement.
signal clicked(unit: Area2D)

## Name shown in the hover info card and battle forecast.
func display_name() -> String:
    return character_name if character_name != "" else unit_class.capitalize()

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
    _refresh_sprite()
    _apply_acted_tint()
    if Engine.is_editor_hint():
        # Editor-only: snap to tile centres while being dragged, so
        # designers get grid snapping in every level with no per-scene
        # editor configuration.
        set_notify_local_transform(true)
        return
    input_pickable = true
    connect("input_event", _on_input_event)

# Tile centres sit at half a 64px tile from the map origin (0,0). If a
# level ever moves its Ground node, runtime registration still snaps
# units to real cells — this only steers the editor preview.
const EDITOR_SNAP_STEP   : Vector2 = Vector2(64, 64)
const EDITOR_SNAP_OFFSET : Vector2 = Vector2(32, 32)

func _notification(what: int) -> void:
    if what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED \
            and Engine.is_editor_hint() and is_node_ready():
        var snapped_pos : Vector2 = (position - EDITOR_SNAP_OFFSET).snapped(EDITOR_SNAP_STEP) \
                + EDITOR_SNAP_OFFSET
        if position != snapped_pos:
            position = snapped_pos  # re-notifies once; equality ends it

## Greys the sprite out while the unit has acted. The material is
## resource_local_to_scene, so each unit tints independently.
func _apply_acted_tint() -> void:
    if not is_node_ready():
        return
    var mat : ShaderMaterial = $Sprite2D.material
    mat.set_shader_parameter("saturation", ACTED_SATURATION if has_acted else 1.0)
    mat.set_shader_parameter("brightness", ACTED_BRIGHTNESS if has_acted else 1.0)

## Points the sprite region at the right sprites_unit_map.png tile for
## class + team. Runs in the editor too (exports call it from setters).
func _refresh_sprite() -> void:
    if not is_node_ready():
        return  # setters fire during scene load, before children exist
    var sprite : Sprite2D = $Sprite2D
    var cell   : Vector2i = ClassStats.sprite_cell(unit_class, sprite_variant)
    sprite.region_enabled = true
    sprite.region_rect    = Rect2(
        cell.x * SPRITE_SIZE,
        (cell.y * 2 + TEAM_ROW[team]) * SPRITE_SIZE,
        SPRITE_SIZE,
        SPRITE_SIZE
    )

## Draws the health bar under the sprite (dark grey backing for missing
## health, team-coloured fill) and the SP gauge under it (black backing,
## yellow fill).
func _draw() -> void:
    var top_left : Vector2 = Vector2(-BAR_SIZE.x / 2.0, BAR_OFFSET_Y)
    draw_rect(Rect2(top_left - Vector2.ONE, BAR_SIZE + Vector2.ONE * 2.0), BAR_BORDER)
    draw_rect(Rect2(top_left, BAR_SIZE), BAR_MISSING)
    var fill_width : float = BAR_SIZE.x * hp / float(max_hp)
    if fill_width > 0.0:
        draw_rect(Rect2(top_left, Vector2(fill_width, BAR_SIZE.y)), BAR_FILL[team])
    var sp_top : Vector2 = Vector2(-SP_BAR_SIZE.x / 2.0,
            BAR_OFFSET_Y + BAR_SIZE.y + 1.0 + SP_BAR_GAP)  # +1: hp bar's border
    draw_rect(Rect2(sp_top - Vector2.ONE, SP_BAR_SIZE + Vector2.ONE * 2.0), BAR_BORDER)
    draw_rect(Rect2(sp_top, SP_BAR_SIZE), SP_EMPTY)
    var sp_width : float = SP_BAR_SIZE.x * sp / float(max_sp) if max_sp > 0 else 0.0
    if sp_width > 0.0:
        draw_rect(Rect2(sp_top, Vector2(sp_width, SP_BAR_SIZE.y)), SP_FILL)

func _process(_delta: float) -> void:
    if Engine.is_editor_hint() or not _is_dragging:
        return
    global_position = get_global_mouse_position() - _drag_offset
    emit_signal("drag_moved", self, global_position)

# ── Input ──────────────────────────────────────────────────────────────────────

func _on_input_event(_viewport, event: InputEvent, _shape_idx: int) -> void:
    # Physics picking runs AFTER main.gd's _unhandled_input sees the same
    # press — main always decides first whether the press acts on the
    # current selection; this only starts a drag on whatever remains.
    if event is InputEventMouseButton and \
       event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        _start_drag(get_global_mouse_position())

func _unhandled_input(event: InputEvent) -> void:
    if _is_dragging and \
       event is InputEventMouseButton and \
       event.button_index == MOUSE_BUTTON_LEFT and \
       not event.pressed:
        _end_drag()

func _start_drag(mouse_world: Vector2) -> void:
    _is_dragging       = true
    _rest_position     = global_position
    _mouse_press_world = mouse_world
    _drag_offset       = mouse_world - global_position
    z_index            = 10
    emit_signal("drag_started", self)

func _end_drag() -> void:
    _is_dragging = false
    z_index = 1
    var mouse_travel : float = get_global_mouse_position().distance_to(_mouse_press_world)

    # If the unit barely moved, treat it as a click rather than a drag.
    if mouse_travel < DRAG_THRESHOLD:
        global_position = _rest_position  # snap back cleanly
        emit_signal("clicked", self)
    else:
        emit_signal("drop_attempted", self, global_position)

# ── Public API (called by main.gd) ─────────────────────────────────────────────

## Snaps the unit to a new world position and records the new grid cell.
func move_to(new_cell: Vector2i, world_pos: Vector2) -> void:
    cell            = new_cell
    global_position = world_pos
    _rest_position  = world_pos
    z_index         = 1

## Returns the unit to its last known rest position (invalid drop).
func return_to_rest() -> void:
    global_position = _rest_position
    z_index         = 1

## Aborts a drag that main.gd rejected (enemy unit, input locked): the
## unit stops following the mouse and no drop/click signals will fire.
func cancel_drag() -> void:
    _is_dragging    = false
    global_position = _rest_position
    z_index         = 1

## Dark red shade while this unit's danger zone is being tracked.
## Tints only the sprite so the health bar stays readable.
func set_danger_marked(marked: bool) -> void:
    $Sprite2D.modulate = Color(0.75, 0.3, 0.3) if marked else Color.WHITE

## Applies damage and refreshes the health bar. Flat subtraction for now;
## main.gd computes the amount (rpg stats like def/crit plug in there later).
func take_damage(amount: int) -> void:
    hp = clampi(hp - amount, 0, max_hp)
    queue_redraw()

## Restores health (capped at max_hp) and refreshes the bar; healing
## beyond the missing amount is simply lost. main.gd applies the amounts
## (item and staff effects live there, like damage does).
func heal(amount: int) -> void:
    take_damage(-amount)  # take_damage's clamp handles the ceiling

## Adds (or, with a negative amount, spends) SP, clamped to [0, max_sp],
## and refreshes the SP gauge. main.gd computes the amounts — aptitude
## totals and skill costs live there, like damage.
func gain_sp(amount: int) -> void:
    sp = clampi(sp + amount, 0, max_sp)
    queue_redraw()

## Hides the unit without freeing it — used for defeats so undo can bring
## it back by restoring its snapshotted properties.
func defeat() -> void:
    visible        = false
    input_pickable = false
