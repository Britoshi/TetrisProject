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

var block_style: int = BlockStyle.FUSED:
	set(v):
		block_style = clampi(v, 0, BlockStyle.size() - 1)
		_save()
		changed.emit()


func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		block_style = cfg.get_value("graphics", "block_style", BlockStyle.FUSED)


func cycle_block_style() -> void:
	block_style = (block_style + 1) % BlockStyle.size()


func block_style_name() -> String:
	return BLOCK_STYLE_NAMES[block_style]


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)  # keep any other sections
	cfg.set_value("graphics", "block_style", block_style)
	cfg.save(SAVE_PATH)
