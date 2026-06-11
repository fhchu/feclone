# test/unit/test_grid.gd
# Covers grid.gd's overlay bookkeeping: range/hover cell tracking and the
# subtle clear_hover() branch that restores a range tile that was sitting
# under the hover highlight. A blank 3-tile overlay TileSet is supplied so
# set_cell() succeeds quietly.
extends GutTest

const GridScript = preload("res://scripts/grid.gd")
const MapBuilder = preload("res://test/fixtures/map_builder.gd")

var _grid

func before_each() -> void:
	_grid = GridScript.new()
	_grid.tile_set = MapBuilder.make_overlay_tileset()
	add_child_autofree(_grid)

# ── Range ──────────────────────────────────────────────────────────────────

func test_show_range_tracks_every_cell() -> void:
	var cells := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]
	_grid.show_range(cells)
	assert_eq(_grid._range_cells.size(), 3, "all range cells tracked")
	for c in cells:
		assert_true(_grid._range_cells.has(c), "cell %s tracked" % c)

func test_show_range_replaces_previous_range() -> void:
	_grid.show_range([Vector2i(0, 0), Vector2i(1, 0)])
	_grid.show_range([Vector2i(5, 5)])
	assert_eq(_grid._range_cells.size(), 1, "previous range cleared first")
	assert_true(_grid._range_cells.has(Vector2i(5, 5)))

func test_clear_range_empties_tracking() -> void:
	_grid.show_range([Vector2i(0, 0)])
	_grid.clear_range()
	assert_eq(_grid._range_cells.size(), 0, "tracking dictionary emptied")

# ── Hover ──────────────────────────────────────────────────────────────────

func test_update_hover_sets_then_clears() -> void:
	_grid.update_hover(Vector2i(2, 2))
	assert_eq(_grid._hover_cell, Vector2i(2, 2), "hover cell recorded")
	_grid.clear_hover()
	assert_eq(_grid._hover_cell, null, "hover cell cleared")

func test_update_hover_ignores_sentinel_cell() -> void:
	_grid.update_hover(Vector2i(-1, -1))
	assert_eq(_grid._hover_cell, null, "the -1,-1 sentinel does not set hover")

func test_clear_hover_restores_underlying_range_tile() -> void:
	_grid.show_range([Vector2i(3, 3)])     # a range tile sits under (3,3)
	_grid.update_hover(Vector2i(3, 3))     # hover lands on that range cell
	assert_eq(_grid._hover_cell, Vector2i(3, 3))
	_grid.clear_hover()
	assert_eq(_grid._hover_cell, null, "hover cleared")
	assert_eq(_grid.get_cell_atlas_coords(Vector2i(3, 3)), GridScript.TILE_MOVE,
		"the range tile is restored, not erased")
