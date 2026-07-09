# board.gd — Grid data, collision detection, line clearing.
# Pure data class (RefCounted, not a Node) so it can be unit-tested directly.
class_name Board
extends RefCounted

# ── Grid state ──
# grid[row][col] = piece type (0 = empty, 1-7 = PieceType)
var grid: Array[Array] = []
# id_grid[row][col] = locked piece instance id (0 = empty). Lets rendering
# know which neighboring cells came from the same tetromino placement.
var id_grid: Array[Array] = []
var _next_piece_id: int = 1
var cols: int
var rows: int

# T-spin tracking
var last_move_was_rotation: bool = false
var last_piece_type: int = Constants.PieceType.EMPTY


func _init(p_cols: int = Constants.COLS, p_rows: int = Constants.ROWS) -> void:
	cols = p_cols
	rows = p_rows
	_reset_grid()


func _reset_grid() -> void:
	grid.clear()
	id_grid.clear()
	for r in range(rows):
		var row: Array[int] = []
		row.resize(cols)
		row.fill(0)
		grid.append(row)
		var id_row: Array[int] = []
		id_row.resize(cols)
		id_row.fill(0)
		id_grid.append(id_row)


# ── Query ──

func get_cell(col: int, row: int) -> int:
	if col < 0 or col >= cols or row < 0 or row >= rows:
		return -1  # out of bounds sentinel
	return grid[row][col]


func is_valid(cells: Array[Vector2i]) -> bool:
	"""Check that all given grid positions are in bounds and unoccupied.
	Cells above the grid (y < 0) are allowed — pieces spawn partially above the playfield."""
	for cell in cells:
		if cell.x < 0 or cell.x >= cols:
			return false
		if cell.y >= rows:
			return false
		if cell.y >= 0 and grid[cell.y][cell.x] != Constants.PieceType.EMPTY:
			return false
	return true


# ── Mutation ──

func lock_piece(cells: Array[Vector2i], piece_type: int) -> void:
	"""Write a piece's cells into the grid (called when the piece locks)."""
	for cell in cells:
		if cell.y >= 0 and cell.y < rows and cell.x >= 0 and cell.x < cols:
			grid[cell.y][cell.x] = piece_type
			id_grid[cell.y][cell.x] = _next_piece_id
	_next_piece_id += 1


func get_conn_mask(col: int, row: int, style: int = 1) -> int:
	"""Bitmask of 4-neighbors this cell visually fuses with:
	1 = left, 2 = right, 4 = up, 8 = down. 0 for empty cells.
	style: 0 = separate tiles, 1 = fuse same piece, 2 = fuse everything."""
	var id: int = id_grid[row][col]
	if id == 0 or style == 0:
		return 0
	var mask: int = 0
	if col > 0 and _fuses(id_grid[row][col - 1], id, style):
		mask |= 1
	if col < cols - 1 and _fuses(id_grid[row][col + 1], id, style):
		mask |= 2
	if row > 0 and _fuses(id_grid[row - 1][col], id, style):
		mask |= 4
	if row < rows - 1 and _fuses(id_grid[row + 1][col], id, style):
		mask |= 8
	return mask


func _fuses(neighbor_id: int, id: int, style: int) -> bool:
	if style >= 2:
		return neighbor_id != 0
	return neighbor_id == id


func clear_lines() -> Array[int]:
	"""
	Find and remove all full rows. Returns the row indices that were cleared
	(before removal, so the caller can animate them).
	"""
	var full_rows: Array[int] = []
	for r in range(rows):
		var full: bool = true
		for c in range(cols):
			if grid[r][c] == Constants.PieceType.EMPTY:
				full = false
				break
		if full:
			full_rows.append(r)

	if full_rows.is_empty():
		return full_rows

	# Remove full rows (from bottom up to keep indices stable)
	full_rows.reverse()
	for r in full_rows:
		grid.remove_at(r)
		id_grid.remove_at(r)

	# Add empty rows at the top
	for _i in range(full_rows.size()):
		var new_row: Array[int] = []
		new_row.resize(cols)
		new_row.fill(0)
		grid.insert(0, new_row)
		var new_id_row: Array[int] = []
		new_id_row.resize(cols)
		new_id_row.fill(0)
		id_grid.insert(0, new_id_row)

	return full_rows


func is_game_over() -> bool:
	"""Game over if any locked cell is in the vanish zone (rows 0-1)."""
	for r in range(2):  # vanish zone = top 2 rows
		for c in range(cols):
			if grid[r][c] != Constants.PieceType.EMPTY:
				return true
	return false


# ── T-spin detection ──

func check_tspin_corners(origin: Vector2i) -> int:
	"""
	Count how many of the 4 corners around a T piece's 3×3 bounding box
	are occupied. Used to determine T-spin status.
	Corner offsets: (-1,-1), (1,-1), (-1,1), (1,1) from origin.
	"""
	var occupied: int = 0
	var corners: Array[Vector2i] = [
		Vector2i(-1, -1), Vector2i(1, -1),
		Vector2i(-1, 1), Vector2i(1, 1),
	]
	for corner in corners:
		var cx: int = origin.x + corner.x
		var cy: int = origin.y + corner.y
		# Out-of-bounds or wall cells count as occupied
		if cx < 0 or cx >= cols or cy < 0 or cy >= rows:
			occupied += 1
		elif grid[cy][cx] != Constants.PieceType.EMPTY:
			occupied += 1
	return occupied
