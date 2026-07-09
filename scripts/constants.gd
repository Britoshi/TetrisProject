# constants.gd — All enums and magic numbers for the Tetris project.
# Access anywhere with Constants.PIECE_T, etc. (preload once in main.gd, or use a
# class_name with const members.)
class_name Constants
extends RefCounted

# ── Piece types ──
enum PieceType {
	EMPTY = 0,
	I = 1,
	O = 2,
	T = 3,
	S = 4,
	Z = 5,
	J = 6,
	L = 7,
}

# ── Grid ──
const COLS: int = 10
const ROWS: int = 22          # rows 0-1 = vanish zone above visible playfield
const VISIBLE_ROWS: int = 20
const SPAWN_ROW: int = 0      # piece origin spawns in this row
const SPAWN_COL: int = 3      # piece origin spawns in this column

# ── Colors (hex, Godot Color) ──
const COLORS: Dictionary = {
	PieceType.I: Color(0.0, 0.88, 0.88),     # cyan
	PieceType.O: Color(1.0, 0.84, 0.0),       # yellow
	PieceType.T: Color(0.63, 0.13, 0.94),     # purple
	PieceType.S: Color(0.0, 0.82, 0.32),      # green
	PieceType.Z: Color(0.89, 0.1, 0.11),      # red
	PieceType.J: Color(0.0, 0.47, 0.95),      # blue
	PieceType.L: Color(1.0, 0.55, 0.0),       # orange
}

# ── Timing (all in seconds unless noted) ──
const GRAVITY_SPEEDS: Array[float] = [
	0.0,    # level 0 dummy
	1.0,    # level 1
	0.8,    # level 2
	0.65,   # level 3
	0.5,    # level 4
	0.4,    # level 5
	0.3,    # level 6
	0.22,   # level 7
	0.16,   # level 8
	0.11,   # level 9
	0.08,   # level 10
	0.055,  # level 11
	0.038,  # level 12
	0.025,  # level 13
	0.017,  # level 14
	0.012,  # level 15
	0.008,  # level 16 — effectively instant at 60 Hz
]
const MAX_LEVEL: int = 15    # gravity caps here

const LOCK_DELAY: float = 0.5
const MAX_LOCK_RESETS: int = 15

const DAS_INITIAL: float = 0.125   # delay before auto-shift kicks in
const DAS_REPEAT: float = 0.02     # auto-shift rate (50 Hz — smooth at 120 fps)
const SOFT_DROP_FACTOR: float = 0.02  # seconds per row during soft drop (50/s)

# ── Scoring ──
const SCORE_SINGLE: int = 100
const SCORE_DOUBLE: int = 300
const SCORE_TRIPLE: int = 500
const SCORE_TETRIS: int = 800
const SCORE_TSPIN: int = 400
const SCORE_TSPIN_SINGLE: int = 800
const SCORE_TSPIN_DOUBLE: int = 1200
const SCORE_TSPIN_TRIPLE: int = 1600
const SCORE_SOFT_DROP: int = 1  # per cell
const SCORE_HARD_DROP: int = 2  # per cell

# ── Lines per level ──
const LINES_PER_LEVEL: int = 10

# ── Render (defaults; use calculate_layout() for screen-scaled values) ──
const CELL_SIZE: int = 32
const BOARD_X: int = 100  # pixel offset from left
const BOARD_Y: int = 20   # pixel offset from top


# ── Layout calculator (call from any Node with a viewport) ──
static func calculate_layout(viewport_size: Vector2) -> Dictionary:
	"""
	Returns scaled layout values for the given viewport size.
	Keys: cell_size, board_x, board_y, font_scale, button_max_w
	"""
	var vw: float = viewport_size.x
	var vh: float = viewport_size.y

	# Fit the board to the screen HEIGHT (small margin); the width is only a
	# fallback cap so the board never spills off narrow/portrait screens.
	var margin: float = 0.04
	var cell_h: int = int((vh * (1.0 - margin)) / VISIBLE_ROWS)
	var cell_w: int = int((vw * (1.0 - margin * 2)) / COLS)
	var cell_size: int = maxi(8, mini(cell_h, cell_w))

	var board_px_w: int = cell_size * COLS
	var board_px_h: int = cell_size * VISIBLE_ROWS
	var board_x: int = int((vw - board_px_w) / 2.0)
	var board_y: int = int((vh - board_px_h) / 2.0)

	var font_scale: float = cell_size / 32.0  # relative to default 32px cell
	var button_max_w: float = minf(vw / 3.5, 180.0)

	return {
		"cell_size": cell_size,
		"board_x": board_x,
		"board_y": board_y,
		"font_scale": font_scale,
		"button_max_w": button_max_w,
	}
