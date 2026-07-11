# game_settings.gd — Global game/graphics settings (autoload: GameSettings).
# Persisted to user://settings.cfg. Emits `changed` whenever a value is set
# so renderers can re-apply (main.gd re-uploads the board texture).

extends Node

signal changed

enum BlockStyle {
	SEPARATE,  # every placed cell is its own glass tile
	BY_PIECE,  # cells of the same tetromino fuse into one container
	FUSED,     # the whole placed stack fuses into one glass mass
}

const SAVE_PATH := "user://settings.cfg"
const BLOCK_STYLE_NAMES: Array[String] = ["Separate", "By Piece", "Fused"]

# True while _ready() restores values from disk. Property setters call
# _save(), and saving mid-load persists half-loaded state — e.g. the
# block_style setter used to write hud_layout={} to disk before the layout
# had been read, wiping the player's dragged HUD layout every other launch.
var _loading: bool = false

var block_style: int = BlockStyle.FUSED:
	set(v):
		block_style = clampi(v, 0, BlockStyle.size() - 1)
		if not _loading:
			_save()
			changed.emit()

# Per-panel HUD overrides the player set by dragging. Keyed "stats"/"hold"/
# "next" → {"x", "y" (top-left as a fraction of the viewport), "s" (scale)}.
# Empty when a panel is at its default computed spot.
var hud_layout: Dictionary = {}


func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		_loading = true
		var hl = cfg.get_value("hud", "layout", {})
		if hl is Dictionary:
			hud_layout = hl
		block_style = cfg.get_value("graphics", "block_style", BlockStyle.FUSED)
		_loading = false


func get_hud_panel(key: String) -> Dictionary:
	var v = hud_layout.get(key, null)
	return v if v is Dictionary else {}


func set_hud_panel(key: String, x: float, y: float, s: float) -> void:
	hud_layout[key] = {"x": x, "y": y, "s": s}
	_save()


func save_hud_layout(layout: Dictionary) -> void:
	hud_layout = layout.duplicate(true)
	_save()


func reset_hud_layout() -> void:
	hud_layout = {}
	_save()


func cycle_block_style() -> void:
	block_style = (block_style + 1) % BlockStyle.size()


func block_style_name() -> String:
	return BLOCK_STYLE_NAMES[block_style]


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)  # keep any other sections
	cfg.set_value("graphics", "block_style", block_style)
	cfg.set_value("hud", "layout", hud_layout)
	cfg.save(SAVE_PATH)
