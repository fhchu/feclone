# level_select.gd
# Mobile-style level grid (Cut the Rope / Angry Birds). One square button
# per entry in the Levels registry. The "thumbnails" are just numbered
# boxes until we settle on how to render map previews.

extends Control

const TILE_SIZE   : Vector2 = Vector2(120, 120)
const NUMBER_FONT : int     = 48

@onready var grid : GridContainer = $VBoxContainer/Grid

func _ready() -> void:
    for i in Levels.LEVELS.size():
        var path : String = Levels.LEVELS[i]
        var btn  : Button = Button.new()
        btn.text = str(i + 1)
        btn.custom_minimum_size = TILE_SIZE
        btn.add_theme_font_size_override("font_size", NUMBER_FONT)
        btn.pressed.connect(func() -> void:
            get_tree().change_scene_to_file(path))
        grid.add_child(btn)
