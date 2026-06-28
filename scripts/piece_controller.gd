# piece_controller.gd — Active piece state, movement, SRS rotation, ghost.
# Holds the currently-falling piece and validates moves against the Board.
class_name PieceController
extends RefCounted

var board: Board
var piece_data: Node  # PieceData autoload (set from main.gd or injected)

# Active piece state
var piece_type: int = Constants.PieceType.EMPTY
var rotation: int = 0
var position: Vector2i = Vector2i.ZERO

# Lock delay
var lock_timer: float = 0.0
var lock_resets: int = 0
var is_locked: bool = false  # set true when piece locks (board write pending)


func _init(p_board: Board, p_piece_data: Node) -> void:
	board = p_board
	piece_data = p_piece_data


# ── Spawning ──

func spawn(p_type: int) -> bool:
	"""Place a new piece at the spawn position. Returns false if blocked (game over)."""
	piece_type = p_type
	rotation = piece_data.ROT_0
	position = Vector2i(Constants.SPAWN_COL, Constants.SPAWN_ROW)
	lock_timer = 0.0
	lock_resets = 0
	is_locked = false

	if not board.is_valid(get_absolute_cells()):
		return false
	return true


# ── Cell access ──

func get_absolute_cells() -> Array[Vector2i]:
	"""Current piece cells in absolute grid coordinates."""
	return get_cells_at(position, rotation)


func get_cells_at(pos: Vector2i, rot: int) -> Array[Vector2i]:
	"""Get absolute grid positions for the piece at a given position and rotation."""
	var offsets: Array[Vector2i] = piece_data.get_cells(piece_type, rot)
	var cells: Array[Vector2i] = []
	for off in offsets:
		cells.append(Vector2i(pos.x + off.x, pos.y + off.y))
	return cells


# ── Movement ──

func move_left() -> bool:
	var new_pos := Vector2i(position.x - 1, position.y)
	if board.is_valid(get_cells_at(new_pos, rotation)):
		position = new_pos
		return true
	return false


func move_right() -> bool:
	var new_pos := Vector2i(position.x + 1, position.y)
	if board.is_valid(get_cells_at(new_pos, rotation)):
		position = new_pos
		return true
	return false


func move_down() -> bool:
	"""Gravity tick / soft drop. Returns true if the piece moved down."""
	var new_pos := Vector2i(position.x, position.y + 1)
	if board.is_valid(get_cells_at(new_pos, rotation)):
		position = new_pos
		return true
	return false


func hard_drop() -> int:
	"""Drop piece to the lowest valid row. Returns distance dropped (for scoring)."""
	var distance: int = 0
	while true:
		var test_pos := Vector2i(position.x, position.y + 1)
		if board.is_valid(get_cells_at(test_pos, rotation)):
			position = test_pos
			distance += 1
		else:
			break
	return distance


# ── Rotation (SRS with wall kicks) ──

func rotate_cw() -> bool:
	return _try_rotate((rotation + 1) % 4)


func rotate_ccw() -> bool:
	return _try_rotate((rotation + 3) % 4)  # +3 mod 4 = -1 mod 4


func _try_rotate(new_rot: int) -> bool:
	"""Attempt rotation with SRS wall kicks. Returns true on success."""
	var kicks: Array[Vector2i] = piece_data.get_kicks(piece_type, rotation, new_rot)

	for kick in kicks:
		var test_pos := Vector2i(position.x + kick.x, position.y + kick.y)
		if board.is_valid(get_cells_at(test_pos, new_rot)):
			position = test_pos
			rotation = new_rot
			return true
	return false


# ── Ghost piece ──

func get_ghost_y() -> int:
	"""
	Lowest valid row for the current piece at its current x and rotation.
	Used to draw the ghost (drop preview).
	"""
	var ghost_pos := Vector2i(position.x, position.y)
	while true:
		var test_pos := Vector2i(ghost_pos.x, ghost_pos.y + 1)
		if board.is_valid(get_cells_at(test_pos, rotation)):
			ghost_pos = test_pos
		else:
			break
	return ghost_pos.y


# ── Ground / lock helpers ──

func is_on_ground() -> bool:
	"""Piece cannot move down from its current position."""
	var test_pos := Vector2i(position.x, position.y + 1)
	return not board.is_valid(get_cells_at(test_pos, rotation))
