# piece_data.gd — Static tetromino definitions and SRS wall kick tables.
# Autoload as "PieceData" in project settings so it's available everywhere.
#
# All positions use grid coordinates: x = column (right), y = row (down).
# SRS offset data (which uses y-up) is negated on y for our y-down grid.
extends Node

# ── Rotation state constants ──
const ROT_0: int = 0
const ROT_R: int = 1   # CW from spawn
const ROT_2: int = 2   # 180°
const ROT_L: int = 3   # CCW from spawn (or CW from 180°)

# ── Tetromino cell offsets ──
# Each piece has 4 rotation states. Each state is 4 cell offsets (Vector2i)
# from the piece origin position on the grid.
# The "origin" cell is the cell whose board coordinates the piece tracks.
# For T/S/Z/J/L it's the center of the 3×3 bounding box.
# For I it's cell (1,1) of its 4×4 SRS bounding box (fixed across states).
# For O it's the top-left cell of the 2×2 block.

const CELLS: Dictionary = {
	Constants.PieceType.I: [
		# SRS 4×4 box, origin fixed at box cell (1,1).
		# State 0: horizontal, box row 1
		[Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		# State 1 (CW): vertical, box column 2
		[Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)],
		# State 2 (180°): horizontal, box row 2
		[Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)],
		# State 3 (CCW): vertical, box column 1
		[Vector2i(0, -1), Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2)],
	],

	Constants.PieceType.O: [
		# All 4 states identical — 2×2 block, origin = top-left
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
	],

	Constants.PieceType.T: [
		# State 0: T up    .X. / XXX
		[Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, -1)],
		# State 1: T right  .X / XX / .X
		[Vector2i(0, -1), Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
		# State 2: T down   XXX / .X.
		[Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
		# State 3: T left   X. / XX / X.
		[Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(0, 1)],
	],

	Constants.PieceType.S: [
		# State 0: .XX / XX. (rows -1, 0)
		[Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(0, 0)],
		# State 1 (CW): X. / XX / .X in columns 0-1
		[Vector2i(0, -1), Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)],
		# State 2 (180°): .XX / XX. (rows 0, 1 — one row below state 0)
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1)],
		# State 3 (CCW): same shape as state 1, one column left
		[Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(0, 1)],
	],

	Constants.PieceType.Z: [
		# State 0: XX. / .XX (rows -1, 0)
		[Vector2i(-1, -1), Vector2i(0, -1), Vector2i(0, 0), Vector2i(1, 0)],
		# State 1 (CW): .X / XX / X. in columns 0-1
		[Vector2i(1, -1), Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)],
		# State 2 (180°): XX. / .XX (rows 0, 1 — one row below state 0)
		[Vector2i(-1, 0), Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1)],
		# State 3 (CCW): same shape as state 1, one column left
		[Vector2i(0, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(-1, 1)],
	],

	Constants.PieceType.J: [
		# State 0: J  X.. / XXX
		[Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0)],
		# State 1: J (CW)  XX / X. / X.
		[Vector2i(0, -1), Vector2i(1, -1), Vector2i(0, 0), Vector2i(0, 1)],
		# State 2: J (180°)  XXX / ..X
		[Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)],
		# State 3: J (CCW)  .X / .X / XX
		[Vector2i(0, -1), Vector2i(0, 0), Vector2i(-1, 1), Vector2i(0, 1)],
	],

	Constants.PieceType.L: [
		# State 0: L  ..X / XXX
		[Vector2i(1, -1), Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0)],
		# State 1: L (CW)  X. / X. / XX
		[Vector2i(0, -1), Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1)],
		# State 2: L (180°)  XXX / X..
		[Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 1)],
		# State 3: L (CCW)  XX / .X / .X
		[Vector2i(-1, -1), Vector2i(0, -1), Vector2i(0, 0), Vector2i(0, 1)],
	],
}

# ── SRS Wall Kick Data ──
# Keyed by "from_rot,to_rot" → array of 5 kick offsets to try.
# SRS original uses y-up; we store y-down offsets (y is negated vs spec).
# First offset is always (0,0) — no kick.

const KICKS_JLSTZ: Dictionary = {
	"0,1": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, 2), Vector2i(-1, 2)],
	"1,0": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, -2), Vector2i(1, -2)],
	"1,2": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, -2), Vector2i(1, -2)],
	"2,1": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, 2), Vector2i(-1, 2)],
	"2,3": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, 2), Vector2i(1, 2)],
	"3,2": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, -2), Vector2i(-1, -2)],
	"3,0": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, -2), Vector2i(-1, -2)],
	"0,3": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, 2), Vector2i(1, 2)],
}

const KICKS_I: Dictionary = {
	"0,1": [Vector2i(0, 0), Vector2i(-2, 0), Vector2i(1, 0), Vector2i(-2, 1), Vector2i(1, -2)],
	"1,0": [Vector2i(0, 0), Vector2i(2, 0), Vector2i(-1, 0), Vector2i(2, -1), Vector2i(-1, 2)],
	"1,2": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(2, 0), Vector2i(-1, -2), Vector2i(2, 1)],
	"2,1": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-2, 0), Vector2i(1, 2), Vector2i(-2, -1)],
	"2,3": [Vector2i(0, 0), Vector2i(2, 0), Vector2i(-1, 0), Vector2i(2, -1), Vector2i(-1, 2)],
	"3,2": [Vector2i(0, 0), Vector2i(-2, 0), Vector2i(1, 0), Vector2i(-2, 1), Vector2i(1, -2)],
	"3,0": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-2, 0), Vector2i(1, 2), Vector2i(-2, -1)],
	"0,3": [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(2, 0), Vector2i(-1, -2), Vector2i(2, 1)],
}


# ── Public API ──

func get_cells(piece_type: Constants.PieceType, rotation: int) -> Array[Vector2i]:
	"""Return the 4 cell offsets for a piece at the given rotation state."""
	var result: Array[Vector2i] = []
	if not CELLS.has(piece_type):
		return result  # EMPTY or unknown type — return empty
	result.assign(CELLS[piece_type][rotation])
	return result


func get_kicks(piece_type: Constants.PieceType, from_rot: int, to_rot: int) -> Array[Vector2i]:
	"""Return the 5 wall-kick offsets to test for this rotation attempt."""
	var key: String = "%d,%d" % [from_rot, to_rot]
	var table: Dictionary = KICKS_I if piece_type == Constants.PieceType.I else KICKS_JLSTZ
	var result: Array[Vector2i] = []
	result.assign(table[key])
	return result
