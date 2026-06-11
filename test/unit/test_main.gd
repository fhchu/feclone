# test/unit/test_main.gd
# Covers main.gd's pure game logic: bounds, terrain cost, the BFS movement
# range, and undo snapshot/restore. The main.gd instance is built without
# being added to the tree (so _ready()'s scene wiring never runs) and its
# scene references are injected directly.
extends GutTest

const MapBuilder = preload("res://test/fixtures/map_builder.gd")
const MainScript = preload("res://scripts/main.gd")
const GridScript = preload("res://scripts/grid.gd")
const UnitScene  = preload("res://scenes/unit.tscn")

# Stand-in for a unit in reachable-cell queries: the BFS only reads `cell`
# and `move_range` and identity-compares against unit_map values.
class FakeUnit:
	var cell : Vector2i
	var move_range : int
	func _init(p_cell: Vector2i, p_range: int = 3) -> void:
		cell = p_cell
		move_range = p_range

var _main
var _ground : TileMapLayer

func before_each() -> void:
	_main = autofree(MainScript.new())
	_ground = TileMapLayer.new()
	_ground.tile_set = MapBuilder.make_terrain_tileset()
	add_child_autofree(_ground)
	_main.ground = _ground
	_main.unit_map = {}

# Paints a filled square of grass covering x,y in [-r..r].
func _paint_grass_square(r: int) -> void:
	for x in range(-r, r + 1):
		for y in range(-r, r + 1):
			_ground.set_cell(Vector2i(x, y), 0, MapBuilder.GRASS)

# ── Bounds + terrain cost ──────────────────────────────────────────────────

func test_in_bounds_true_for_painted_cell() -> void:
	_ground.set_cell(Vector2i(0, 0), 0, MapBuilder.GRASS)
	assert_true(_main._in_bounds(Vector2i(0, 0)), "painted cell is in bounds")

func test_in_bounds_false_for_unpainted_cell() -> void:
	assert_false(_main._in_bounds(Vector2i(9, 9)), "unpainted cell is off the map")

func test_terrain_cost_reads_move_cost_custom_data() -> void:
	_ground.set_cell(Vector2i(0, 0), 0, MapBuilder.GRASS)
	_ground.set_cell(Vector2i(1, 0), 0, MapBuilder.FOREST)
	assert_eq(_main._terrain_cost(Vector2i(0, 0)), 1, "grass costs 1")
	assert_eq(_main._terrain_cost(Vector2i(1, 0)), 2, "forest costs 2")

func test_terrain_cost_defaults_to_one_when_no_tile_data() -> void:
	assert_eq(_main._terrain_cost(Vector2i(9, 9)), 1, "no tile data -> default cost 1")

# ── Movement range (BFS flood-fill) ────────────────────────────────────────

func test_reachable_cells_open_grass_is_a_diamond() -> void:
	_paint_grass_square(3)
	var unit := FakeUnit.new(Vector2i(0, 0), 2)
	var cells : Array = _main._get_reachable_cells(unit)
	# Uniform cost-1 terrain: every cell with Manhattan distance <= 2.
	# 1 (self) + 4 (dist 1) + 8 (dist 2) = 13.
	assert_eq(cells.size(), 13, "diamond of radius 2 has 13 cells")
	assert_true(Vector2i(0, 0) in cells, "own cell is included")
	assert_true(Vector2i(2, 0) in cells, "edge of range reachable")
	assert_false(Vector2i(3, 0) in cells, "beyond range not reachable")

func test_reachable_cells_excludes_unaffordable_forest() -> void:
	_paint_grass_square(2)
	_ground.set_cell(Vector2i(1, 0), 0, MapBuilder.FOREST)  # entering costs 2
	var unit := FakeUnit.new(Vector2i(0, 0), 1)
	var cells : Array = _main._get_reachable_cells(unit)
	assert_false(Vector2i(1, 0) in cells, "forest (cost 2) unreachable with 1 move")
	assert_true(Vector2i(0, 1) in cells, "adjacent grass still reachable")

func test_reachable_cells_blocked_by_other_unit() -> void:
	_paint_grass_square(3)
	var unit := FakeUnit.new(Vector2i(0, 0), 2)
	var blocker := FakeUnit.new(Vector2i(1, 0), 2)
	_main.unit_map = {Vector2i(1, 0): blocker}
	var cells : Array = _main._get_reachable_cells(unit)
	assert_false(Vector2i(1, 0) in cells, "cannot stop on an occupied cell")
	assert_false(Vector2i(2, 0) in cells, "cannot pass through a blocker")
	assert_true(Vector2i(0, 1) in cells, "an open direction is still reachable")

func test_reachable_cells_clipped_to_painted_map() -> void:
	_paint_grass_square(1)  # only the 3x3 around the origin is on the map
	var unit := FakeUnit.new(Vector2i(0, 0), 5)  # range exceeds the map
	var cells : Array = _main._get_reachable_cells(unit)
	assert_eq(cells.size(), 9, "reach is clipped to the 9 painted cells")
	assert_false(Vector2i(2, 0) in cells, "off-map cell never reachable")

# ── Undo snapshot / restore ────────────────────────────────────────────────

func test_undo_restores_unit_state_and_button() -> void:
	var overlay := GridScript.new()
	overlay.tile_set = MapBuilder.make_overlay_tileset()
	add_child_autofree(overlay)
	var units_node := Node2D.new()
	add_child_autofree(units_node)
	var button := Button.new()
	add_child_autofree(button)

	_main.overlay = overlay
	_main.units_node = units_node
	_main.undo_button = button

	var unit = UnitScene.instantiate()
	units_node.add_child(unit)
	unit.move_to(Vector2i(0, 0), Vector2(32, 32))
	_main.unit_map = {Vector2i(0, 0): unit}

	button.disabled = true
	_main._push_undo_snapshot()
	assert_eq(_main.undo_stack.size(), 1, "a snapshot is pushed")
	assert_false(button.disabled, "undo button enabled after a move")

	_main._move_unit(unit, Vector2i(2, 0))
	assert_eq(unit.cell, Vector2i(2, 0), "unit moved to the new cell")

	_main.undo_move()
	assert_eq(unit.cell, Vector2i(0, 0), "unit restored to its original cell")
	assert_true(_main.unit_map.has(Vector2i(0, 0)), "unit_map rebuilt at the original cell")
	assert_false(_main.unit_map.has(Vector2i(2, 0)), "moved-to cell cleared from unit_map")
	assert_true(_main.undo_stack.is_empty(), "undo stack emptied")
	assert_true(button.disabled, "undo button disabled when the stack is empty")
