# danger_layer.gd
# Custom-drawn enemy threat display, sitting between the tile overlay
# and the units. Two jobs:
#   • hover preview — one enemy's movement + strike range at very high
#     transparency while the mouse rests on it
#   • danger union — the combined attackable area of every toggled
#     enemy: translucent grey fill with a red outline that only traces
#     the OUTER boundary (an edge is drawn only where the neighbouring
#     cell is outside the union, so interior seams can't exist)
# main.gd owns the data and calls set_union/show_preview; this node
# only draws.

extends Node2D

const TILE : float = 64.0
const DIRS : Array = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]

const UNION_FILL     : Color = Color(0.2, 0.2, 0.22, 0.35)   # translucent grey
const UNION_BORDER   : Color = Color(0.85, 0.15, 0.18, 0.9)  # red outline
const BORDER_WIDTH   : float = 3.0
const PREVIEW_MOVE   : Color = Color(0.3, 0.55, 1.0, 0.14)   # faint blue
const PREVIEW_ATTACK : Color = Color(0.95, 0.3, 0.3, 0.12)   # faint red

var _union          : Dictionary = {}   # Vector2i → true
var _preview_move   : Array      = []
var _preview_attack : Array      = []

func set_union(cells: Dictionary) -> void:
    _union = cells
    queue_redraw()

func show_preview(move_cells: Array, attack_cells: Array) -> void:
    _preview_move   = move_cells
    _preview_attack = attack_cells
    queue_redraw()

func clear_preview() -> void:
    if _preview_move.is_empty() and _preview_attack.is_empty():
        return
    _preview_move   = []
    _preview_attack = []
    queue_redraw()

# The node sits at the map origin, so cell (x, y) spans local
# (x*64, y*64) → +64 on each axis, same as the TileMapLayers.
func _cell_rect(cell: Vector2i) -> Rect2:
    return Rect2(Vector2(cell) * TILE, Vector2(TILE, TILE))

func _draw() -> void:
    for cell in _preview_move:
        draw_rect(_cell_rect(cell), PREVIEW_MOVE)
    for cell in _preview_attack:
        draw_rect(_cell_rect(cell), PREVIEW_ATTACK)
    for cell in _union:
        draw_rect(_cell_rect(cell), UNION_FILL)
    # Outline pass: an edge strip per side whose neighbour is outside.
    for cell in _union:
        var r : Rect2 = _cell_rect(cell)
        if not _union.has(cell + Vector2i.UP):
            draw_rect(Rect2(r.position, Vector2(TILE, BORDER_WIDTH)), UNION_BORDER)
        if not _union.has(cell + Vector2i.DOWN):
            draw_rect(Rect2(r.position + Vector2(0, TILE - BORDER_WIDTH),
                    Vector2(TILE, BORDER_WIDTH)), UNION_BORDER)
        if not _union.has(cell + Vector2i.LEFT):
            draw_rect(Rect2(r.position, Vector2(BORDER_WIDTH, TILE)), UNION_BORDER)
        if not _union.has(cell + Vector2i.RIGHT):
            draw_rect(Rect2(r.position + Vector2(TILE - BORDER_WIDTH, 0),
                    Vector2(BORDER_WIDTH, TILE)), UNION_BORDER)
