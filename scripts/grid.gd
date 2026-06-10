# grid.gd
# Attached to the Overlay TileMapLayer.
# Pure rendering — no game state. All tile indices reference overlay_tiles.png.
# The grass ground is on the Ground TileMapLayer, filled by main.gd at startup.
# Adapted from chess board.gd: "moves" became "range" (a set of reachable
# cells rather than move dicts), and the grid size is configurable.

extends TileMapLayer

# ── Overlay tile atlas coordinates ────────────────────────────────────────────
const TILE_MOVE   : Vector2i = Vector2i(0, 0)  # blue: reachable tile
const TILE_ATTACK : Vector2i = Vector2i(1, 0)  # red: attackable tile (combat later)
const TILE_HOVER  : Vector2i = Vector2i(2, 0)  # cyan: tile under the dragged unit
const SOURCE_ID   : int      = 0               # atlas source index
const DEFAULT_OVERLAY_ALPHA : float = 0.5

@export var grid_size : Vector2i = Vector2i(10, 10)

# ── Tracked cells (so we can erase selectively) ────────────────────────────────
var _range_cells : Dictionary = {}     # Vector2i → Vector2i (cell → atlas tile)
var _hover_cell  : Variant    = null   # Vector2i or null

# Overlay transparency; main.gd applies the game setting on startup.
@export_range(0.0, 1.0, 0.05) var overlay_alpha : float = DEFAULT_OVERLAY_ALPHA :
    set(value):
        overlay_alpha = value
        modulate.a = overlay_alpha

func _ready() -> void:
    modulate.a = overlay_alpha

# ── Coordinate conversion (delegates to TileMapLayer built-ins) ───────────────

func in_bounds(cell: Vector2i) -> bool:
    return cell.x >= 0 and cell.x < grid_size.x \
       and cell.y >= 0 and cell.y < grid_size.y

## Converts a global world position to a grid cell.
## Returns Vector2i(-1,-1) if out of bounds.
func world_to_cell(world_pos: Vector2) -> Vector2i:
    var cell : Vector2i = local_to_map(to_local(world_pos))
    if in_bounds(cell):
        return cell
    return Vector2i(-1, -1)

## Returns the global world-space centre of a grid cell.
func cell_center_world(cell: Vector2i) -> Vector2:
    return to_global(map_to_local(cell))

# ── Public display API ─────────────────────────────────────────────────────────

## Shows the movement range for the given list of cells.
## Clears any previous range first.
func show_range(cells: Array, tile: Vector2i = TILE_MOVE) -> void:
    clear_range()
    for cell in cells:
        set_cell(cell, SOURCE_ID, tile)
        _range_cells[cell] = tile

func clear_range() -> void:
    for cell in _range_cells:
        erase_cell(cell)
    _range_cells = {}

## Updates the hover highlight to the cell under the dragged unit.
## Pass null or an out-of-bounds cell to clear without setting a new one.
func update_hover(cell: Variant) -> void:
    if cell == _hover_cell:
        return
    clear_hover()
    if cell != null and cell != Vector2i(-1, -1):
        _hover_cell = cell
        set_cell(cell, SOURCE_ID, TILE_HOVER)

func clear_hover() -> void:
    if _hover_cell != null:
        if _range_cells.has(_hover_cell):
            # Restore the range tile that was underneath the hover tile.
            set_cell(_hover_cell, SOURCE_ID, _range_cells[_hover_cell])
        else:
            erase_cell(_hover_cell)
        _hover_cell = null

## Wipes the entire overlay — call on deselect or turn reset.
func clear_all() -> void:
    clear_range()
    clear_hover()
