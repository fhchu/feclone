# ui_sfx.gd
# Autoload (UiSfx): the shared click sound for the whole UI. Watches the
# SceneTree and connects itself to every BaseButton's pressed signal as
# the node enters the tree, so buttons added later — new scenes, menus
# built from code — hook up automatically and a new button never needs
# wiring. Covers CheckBoxes too (they're BaseButtons). A button that
# shouldn't click can opt out with a `no_click_sfx` metadata entry in
# the Inspector. Code-driven state changes (button_pressed = x) emit
# only `toggled`, never `pressed`, so syncing a checkbox stays silent.

extends Node

const CLICK : AudioStream = preload("res://assets/select.wav")

var _player : AudioStreamPlayer

func _ready() -> void:
    # UI must stay audible if the tree is ever paused (pause menus click too).
    process_mode = Node.PROCESS_MODE_ALWAYS
    _player = AudioStreamPlayer.new()
    _player.stream = CLICK
    add_child(_player)
    get_tree().node_added.connect(_on_node_added)
    _hook_tree(get_tree().root)

## Sweep nodes already in the tree when this autoload starts. Autoloads
## precede the main scene, so today this finds nothing — it just keeps
## the guarantee if the load order ever changes.
func _hook_tree(node: Node) -> void:
    _on_node_added(node)
    for child in node.get_children():
        _hook_tree(child)

func _on_node_added(node: Node) -> void:
    if node is not BaseButton or node.has_meta("no_click_sfx"):
        return
    # Re-adding a node (reparent) fires node_added again; don't double-connect.
    if not node.pressed.is_connected(_on_button_pressed):
        node.pressed.connect(_on_button_pressed)

func _on_button_pressed() -> void:
    _player.play()
