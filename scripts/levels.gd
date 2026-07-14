# levels.gd
# Central registry of level scenes in play order. Level select and the
# post-rout progression both read from here — adding a level means
# adding its scene path to this list, nothing else.

class_name Levels

const LEVELS : Array[String] = [
    "res://scenes/levels/level1.tscn",
    "res://scenes/levels/level2.tscn",
]

const LEVEL_SELECT : String = "res://scenes/level_select.tscn"

## The scene to load after clearing the given level, or "" if it was the
## last one (or isn't in the registry).
static func next_after(scene_path: String) -> String:
    var i : int = LEVELS.find(scene_path)
    if i >= 0 and i + 1 < LEVELS.size():
        return LEVELS[i + 1]
    return ""
