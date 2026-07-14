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
# Must match the actual pixel dimensions of pieces.png.
const SPRITE_SIZE : int = 64

# Columns in pieces.png, reinterpreted as unit classes.
# (Chess K Q B N R P → lord, fighter, cleric, cavalier, knight, mage.)
const CLASS_COL : Dictionary = {
    "lord": 0, "fighter": 1, "cleric": 2, "cavalier": 3, "knight": 4, "mage": 5
}
const TEAM_ROW : Dictionary = {
    "blue": 0, "red": 1
}

# ── Designer-facing properties (set in the Inspector) ──────────────────────────
@export_enum("lord", "fighter", "cleric", "cavalier", "knight", "mage")
var unit_class : String = "lord":
    set(value):
        unit_class = value
        _refresh_sprite()

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

# Which EnemyAI strategies drive this unit while it's on the enemy team
# (ignored for player units) — see scripts/enemy_ai.gd. The dropdowns
# grow as new behaviours land (thieves, bosses, reinforcements…).
@export_group("Enemy AI")
@export_enum("guard") var ai_movement : String = "guard"
@export_enum("default") var ai_targeting : String = "default"
@export_group("")

# ── Runtime state ──────────────────────────────────────────────────────────────
var cell : Vector2i = Vector2i(-1, -1)   # assigned by main.gd on registration
var hp   : int      = 2                  # kept in sync by the max_hp setter

## True once the unit has taken its action this phase; main.gd resets it
## at phase start. The sprite greys out while set.
var has_acted : bool = false:
    set(value):
        has_acted = value
        _apply_acted_tint()

# Shader uniforms while has_acted (see assets/unit_tint.gdshader).
const ACTED_SATURATION : float = 0.15
const ACTED_BRIGHTNESS : float = 0.7

# ── Health bar ─────────────────────────────────────────────────────────────────
const BAR_SIZE     : Vector2 = Vector2(44, 5)
const BAR_OFFSET_Y : float   = 24.0  # below the sprite, inside the tile
const BAR_BORDER   : Color   = Color(0.0, 0.0, 0.0, 0.8)
const BAR_MISSING  : Color   = Color(0.22, 0.22, 0.25)  # dark grey
const BAR_FILL     : Dictionary = {
    "blue": Color(0.25, 0.55, 1.0),
    "red" : Color(0.95, 0.25, 0.3),
}

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

## Name shown in the hover info card. Unique characters ("Lyon",
## "Cormag") will override this with a real name property later.
func display_name() -> String:
    return unit_class.capitalize()

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
    _refresh_sprite()
    _apply_acted_tint()
    if Engine.is_editor_hint():
        return
    input_pickable = true
    connect("input_event", _on_input_event)

## Greys the sprite out while the unit has acted. The material is
## resource_local_to_scene, so each unit tints independently.
func _apply_acted_tint() -> void:
    if not is_node_ready():
        return
    var mat : ShaderMaterial = $Sprite2D.material
    mat.set_shader_parameter("saturation", ACTED_SATURATION if has_acted else 1.0)
    mat.set_shader_parameter("brightness", ACTED_BRIGHTNESS if has_acted else 1.0)

## Points the sprite region at the right pieces.png tile for class + team.
## Runs in the editor too (exports call it from their setters).
func _refresh_sprite() -> void:
    if not is_node_ready():
        return  # setters fire during scene load, before children exist
    var sprite : Sprite2D = $Sprite2D
    sprite.region_enabled = true
    sprite.region_rect    = Rect2(
        CLASS_COL[unit_class] * SPRITE_SIZE,
        TEAM_ROW[team]        * SPRITE_SIZE,
        SPRITE_SIZE,
        SPRITE_SIZE
    )

## Draws the health bar under the sprite: dark grey backing for missing
## health, team-coloured fill for the rest.
func _draw() -> void:
    var top_left : Vector2 = Vector2(-BAR_SIZE.x / 2.0, BAR_OFFSET_Y)
    draw_rect(Rect2(top_left - Vector2.ONE, BAR_SIZE + Vector2.ONE * 2.0), BAR_BORDER)
    draw_rect(Rect2(top_left, BAR_SIZE), BAR_MISSING)
    var fill_width : float = BAR_SIZE.x * hp / float(max_hp)
    if fill_width > 0.0:
        draw_rect(Rect2(top_left, Vector2(fill_width, BAR_SIZE.y)), BAR_FILL[team])

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

## Applies damage and refreshes the health bar. Flat subtraction for now;
## main.gd computes the amount (rpg stats like def/crit plug in there later).
func take_damage(amount: int) -> void:
    hp = clampi(hp - amount, 0, max_hp)
    queue_redraw()

## Hides the unit without freeing it — used for defeats so undo can bring
## it back by restoring its snapshotted properties.
func defeat() -> void:
    visible        = false
    input_pickable = false
