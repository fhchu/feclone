# unit.gd
# Attached to the Area2D root of unit.tscn.
# Handles sprite selection, drag-and-drop input, and hover reporting.
# Does NOT know game rules — it signals main.gd for all decisions.
# Adapted from chess piece.gd: piece type/color became unit class/team,
# and units carry stats (move_range for now, more later).

extends Area2D

# ── Sprite sheet layout ────────────────────────────────────────────────────────
# Must match the actual pixel dimensions of pieces.png.
const SPRITE_SIZE : int = 64

# Columns in pieces.png, reinterpreted as unit classes.
# (Chess K Q B N R P → lord, fighter, cleric, cavalier, soldier, mage.)
const CLASS_COL : Dictionary = {
    "lord": 0, "fighter": 1, "cleric": 2, "cavalier": 3, "soldier": 4, "mage": 5
}
const TEAM_ROW : Dictionary = {
    "blue": 0, "red": 1
}

# ── Unit identity & stats ──────────────────────────────────────────────────────
var unit_class : String   = ""               # key into CLASS_COL
var team       : String   = ""               # "blue" or "red"
var cell       : Vector2i = Vector2i(-1, -1)
var move_range : int      = 3

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

# ── Setup ──────────────────────────────────────────────────────────────────────

## Called by main.gd immediately after instancing.
func setup(p_class: String, p_team: String, sheet: Texture2D,
        p_cell: Vector2i, p_move_range: int) -> void:
    unit_class = p_class
    team       = p_team
    cell       = p_cell
    move_range = p_move_range
    _apply_sprite(sheet)

func _apply_sprite(sheet: Texture2D) -> void:
    var sprite : Sprite2D = $Sprite2D
    sprite.texture        = sheet
    sprite.region_enabled = true
    sprite.region_rect    = Rect2(
        CLASS_COL[unit_class] * SPRITE_SIZE,
        TEAM_ROW[team]        * SPRITE_SIZE,
        SPRITE_SIZE,
        SPRITE_SIZE
    )

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
    input_pickable = true
    connect("input_event", _on_input_event)

func _process(_delta: float) -> void:
    if not _is_dragging:
        return
    global_position = get_global_mouse_position() - _drag_offset
    emit_signal("drag_moved", self, global_position)

# ── Input ──────────────────────────────────────────────────────────────────────

func _on_input_event(_viewport, event: InputEvent, _shape_idx: int) -> void:
    if event is InputEventMouseButton and \
       event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
        # Claim the press so it doesn't also reach main.gd's _unhandled_input.
        get_viewport().set_input_as_handled()
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

## Hides the unit without freeing it — used for defeats so undo can bring
## it back by restoring its snapshotted properties.
func defeat() -> void:
    visible        = false
    input_pickable = false
