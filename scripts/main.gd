# main.gd
# Root Node2D. Owns all game state and coordinates unit nodes and the
# Overlay display. Mirrors the structure of chess main.gd:
#   piece_map → unit_map, legal_moves → reachable_cells,
#   and the same undo-snapshot pattern (much simpler without chess state).
#
# Levels are authored entirely in the editor — no code changes needed:
#   • Terrain: paint the Ground TileMapLayer with the TileMap editor.
#     Movement cost comes from the TileSet's "move_cost" custom data
#     (grass 1, forest 2). Unpainted cells are off the map.
#   • Units:   instance unit.tscn under Units, drag it over a tile, and
#     set class/team/move range in the Inspector. _ready() snaps each
#     placed unit to its nearest cell and registers it.

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
# which cell each unit occupies.
var unit_map : Dictionary = {}

# ── Selection state ────────────────────────────────────────────────────────────
var selected_unit       : Variant = null   # Area2D node or null (drag in progress)
var click_selected_unit : Variant = null   # Area2D node or null (click-to-move)
var reachable_cells     : Array   = []     # Vector2i cells for the selected unit

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
## Other units block passage and cannot be stopped on. The unit's own cell
## is included so the range reads correctly on screen.
func _get_reachable_cells(unit) -> Array:
	var costs    : Dictionary = {unit.cell: 0}   # cell → cheapest cost found
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
	return costs.keys()

# ── Drag-and-drop input ────────────────────────────────────────────────────────

func _on_drag_started(unit: Area2D) -> void:
	# Enemy units aren't player-controlled; they snap back on release.
	if unit.team != PLAYER_TEAM:
		unit.return_to_rest()
		return

	# Clear previous selection's range tiles.
	overlay.clear_range()

	selected_unit   = unit
	reachable_cells = _get_reachable_cells(unit)
	overlay.show_range(reachable_cells)

func _on_drag_moved(unit: Area2D, world_pos: Vector2) -> void:
	if unit != selected_unit:
		return
	var cell : Vector2i = overlay.world_to_cell(world_pos)
	# Only highlight if the cell is a reachable destination.
	@warning_ignore("incompatible_ternary")
	overlay.update_hover(cell if cell in reachable_cells else null)

func _on_drop_attempted(unit: Area2D, world_pos: Vector2) -> void:
	click_selected_unit = null  # a completed drag clears any click-selection
	overlay.clear_hover()

	if unit != selected_unit:
		unit.return_to_rest()
		return

	var target : Vector2i = overlay.world_to_cell(world_pos)
	var valid  : bool     = target in reachable_cells and target != unit.cell

	overlay.clear_range()
	selected_unit   = null
	reachable_cells = []

	if not valid:
		# Dropped out of range (or back on its own cell) — snap back.
		unit.return_to_rest()
		return

	_push_undo_snapshot()
	_move_unit(unit, target)

# ── Click-to-move input ────────────────────────────────────────────────────────

func _on_unit_clicked(unit: Area2D) -> void:
	# Second click on the same unit → deselect.
	if unit == click_selected_unit:
		_deselect()
		return
	# Clicking an enemy does nothing yet (later: attack target selection).
	if unit.team != PLAYER_TEAM:
		return
	# First click: drag_started already fired on mouse-down and showed this
	# unit's range, so all we need to do here is record the click-selection.
	click_selected_unit = unit

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and
			event.button_index == MOUSE_BUTTON_LEFT and
			event.pressed):
		return
	if click_selected_unit == null:
		return

	var cell  : Vector2i = overlay.world_to_cell(get_global_mouse_position())
	var unit  : Area2D   = click_selected_unit
	var valid : bool     = cell in reachable_cells and cell != unit.cell
	_deselect()

	if valid:
		_push_undo_snapshot()
		_move_unit(unit, cell)

func _deselect() -> void:
	click_selected_unit = null
	selected_unit       = null
	reachable_cells     = []
	overlay.clear_all()

# ── Move application ───────────────────────────────────────────────────────────

func _move_unit(unit: Area2D, to_cell: Vector2i) -> void:
	unit_map.erase(unit.cell)
	unit.move_to(to_cell, overlay.cell_center_world(to_cell))
	unit_map[to_cell] = unit

# ── Undo ───────────────────────────────────────────────────────────────────────

func _push_undo_snapshot() -> void:
	# {node: state} for every unit node, so undo can restore each one's
	# position and visibility (visibility matters once combat exists).
	var states : Dictionary = {}
	for unit in units_node.get_children():
		states[unit] = {
			"cell"     : unit.cell,
			"world"    : unit.global_position,
			"rest"     : unit._rest_position,
			"visible"  : unit.visible,
			"pickable" : unit.input_pickable,
		}
	undo_stack.append({"unit_states": states})
	undo_button.disabled = false

## Called by the Undo button.
func undo_move() -> void:
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
		if unit.visible:
			unit_map[unit.cell] = unit

	undo_button.disabled = undo_stack.is_empty()
