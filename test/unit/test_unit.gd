# test/unit/test_unit.gd
# Covers unit.gd's pure behaviour: the sprite-sheet region maths and the
# public state-mutating API (move_to / defeat). Drag/drop input is driven by
# real mouse events and viewport state, so it's left to manual/integration
# testing.
extends GutTest

const UnitScene = preload("res://scenes/unit.tscn")

var _unit : Area2D
var _sprite : Sprite2D

func before_each() -> void:
	_unit = UnitScene.instantiate()
	add_child_autofree(_unit)
	_sprite = _unit.get_node("Sprite2D")

# ── Sprite region maths (class column × team row × 64px) ───────────────────

func test_sprite_region_for_blue_lord() -> void:
	_unit.team = "blue"
	_unit.unit_class = "lord"
	assert_eq(_sprite.region_rect, Rect2(0, 0, 64, 64), "lord col 0, blue row 0")

func test_sprite_region_for_red_mage() -> void:
	_unit.team = "red"
	_unit.unit_class = "mage"
	assert_eq(_sprite.region_rect, Rect2(5 * 64, 1 * 64, 64, 64), "mage col 5, red row 1")

func test_sprite_region_for_blue_cavalier() -> void:
	_unit.team = "blue"
	_unit.unit_class = "cavalier"
	assert_eq(_sprite.region_rect, Rect2(3 * 64, 0, 64, 64), "cavalier col 3, blue row 0")

func test_refresh_enables_region() -> void:
	_unit.unit_class = "fighter"
	assert_true(_sprite.region_enabled, "region is enabled so the sheet is clipped")

# ── Public API ─────────────────────────────────────────────────────────────

func test_move_to_sets_cell_and_position() -> void:
	_unit.move_to(Vector2i(3, 4), Vector2(200, 250))
	assert_eq(_unit.cell, Vector2i(3, 4), "cell recorded")
	assert_eq(_unit.global_position, Vector2(200, 250), "snapped to world position")

func test_defeat_hides_and_disables_input() -> void:
	_unit.defeat()
	assert_false(_unit.visible, "defeated unit is hidden")
	assert_false(_unit.input_pickable, "defeated unit ignores input")
