# test/fixtures/map_builder.gd
# Helpers that build TileMapLayer/TileSet fixtures entirely in code, so unit
# tests don't depend on the editable level content of scenes/main.tscn.
#
# Not a test script (no "test_" prefix), so GUT's collector ignores it.
extends RefCounted

# Atlas coordinates of the two terrain tiles built by make_terrain_tileset().
const GRASS  : Vector2i = Vector2i(0, 0)  # move_cost 1
const FOREST : Vector2i = Vector2i(1, 0)  # move_cost 2

const TILE_SIZE : Vector2i = Vector2i(64, 64)

## A ground TileSet with a "move_cost" int custom-data layer and two tiles:
## grass (atlas 0,0 → cost 1) and forest (atlas 1,0 → cost 2). Mirrors the
## real Ground TileSet that main.gd's _terrain_cost() reads.
static func make_terrain_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = TILE_SIZE
	ts.add_custom_data_layer()
	ts.set_custom_data_layer_name(0, "move_cost")
	ts.set_custom_data_layer_type(0, TYPE_INT)
	ts.add_source(_make_atlas_source(2), 0)
	ts.get_source(0).get_tile_data(GRASS, 0).set_custom_data("move_cost", 1)
	ts.get_source(0).get_tile_data(FOREST, 0).set_custom_data("move_cost", 2)
	return ts

## An overlay TileSet with three blank tiles at atlas (0,0), (1,0), (2,0),
## matching grid.gd's TILE_MOVE / TILE_ATTACK / TILE_HOVER, so set_cell() in
## the overlay tests succeeds quietly instead of pushing errors.
static func make_overlay_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = TILE_SIZE
	ts.add_source(_make_atlas_source(3), 0)
	return ts

## Builds an atlas source backed by a blank texture wide enough for `columns`
## 1×1 tiles in a single row.
static func _make_atlas_source(columns: int) -> TileSetAtlasSource:
	var src := TileSetAtlasSource.new()
	var img := Image.create_empty(TILE_SIZE.x * columns, TILE_SIZE.y, false, Image.FORMAT_RGBA8)
	src.texture = ImageTexture.create_from_image(img)
	src.texture_region_size = TILE_SIZE
	for x in range(columns):
		src.create_tile(Vector2i(x, 0))
	return src
