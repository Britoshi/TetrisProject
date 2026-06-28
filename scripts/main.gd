# main.gd — Game orchestrator: state machine, gravity, input, rendering.
# Attached to the root Node2D of main.tscn.
extends Node2D

# ── Game state ──
enum State { PLAYING, LINE_CLEAR, GAME_OVER }
var state: int = State.PLAYING

# ── Core objects ──
var board: Board
var controller: PieceController
var bag: BagRandomizer
var piece_data: Node  # PieceData autoload reference

# ── Scoring ──
var score: int = 0
var lines_cleared: int = 0
var level: int = 1

# ── Hold (stash) ──
var _held_piece_type: int = Constants.PieceType.EMPTY
var _hold_used_this_drop: bool = false
var _hold_locked: bool = false    # true after hold; cleared on next spawn

# ── Timers (accumulated in _process) ──
var gravity_acc: float = 0.0

# DAS (Delayed Auto Shift)
var das_left_acc: float = 0.0
var das_right_acc: float = 0.0
var das_left_active: bool = false
var das_right_active: bool = false

# Line clear animation
var line_clear_timer: float = 0.0
var cleared_row_indices: Array[int] = []

# ── Scaled layout (recomputed on resize) ──
var _cell_size: int = 32
var _board_x: int = 100
var _board_y: int = 20
var _font_scale: float = 1.0


# ── Init ──

func _ready() -> void:
	print("=== _ready() start ===")
	_setup_input_actions()
	print("  input actions set up")
	_update_layout()
	get_viewport().size_changed.connect(_update_layout)
	piece_data = get_node_or_null("/root/PieceData")
	print("  piece_data autoload: ", piece_data)
	if piece_data == null:
		push_error("PieceData autoload not found! Check project.godot [autoload] section.")
		return
	board = Board.new()
	print("  board created")
	bag = BagRandomizer.new()
	print("  bag created")
	controller = PieceController.new(board, piece_data)
	print("  controller created")
	_spawn_next_piece()
	print("=== _ready() done — state:", state, "piece:", controller.piece_type, "pos:", controller.position, "===")


func _setup_input_actions() -> void:
	if InputMap.has_action("tetris_move_left"):
		return

	InputMap.add_action("tetris_move_left")
	_create_input_event("tetris_move_left", KEY_LEFT)
	_create_input_event("tetris_move_left", KEY_A)

	InputMap.add_action("tetris_move_right")
	_create_input_event("tetris_move_right", KEY_RIGHT)
	_create_input_event("tetris_move_right", KEY_D)

	InputMap.add_action("tetris_soft_drop")
	_create_input_event("tetris_soft_drop", KEY_DOWN)
	_create_input_event("tetris_soft_drop", KEY_S)

	InputMap.add_action("tetris_hard_drop")
	_create_input_event("tetris_hard_drop", KEY_SPACE)

	InputMap.add_action("tetris_rotate_cw")
	_create_input_event("tetris_rotate_cw", KEY_X)
	_create_input_event("tetris_rotate_cw", KEY_UP)

	InputMap.add_action("tetris_rotate_ccw")
	_create_input_event("tetris_rotate_ccw", KEY_Z)
	_create_input_event("tetris_rotate_ccw", KEY_CTRL)

	InputMap.add_action("tetris_hold")
	_create_input_event("tetris_hold", KEY_C)
	_create_input_event("tetris_hold", KEY_SHIFT)


func _create_input_event(action: String, keycode: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	InputMap.action_add_event(action, ev)


func _update_layout() -> void:
	var vp_size := get_viewport_rect().size
	if vp_size.x <= 0:
		return
	var layout := Constants.calculate_layout(vp_size)
	_cell_size = layout.cell_size
	_board_x = layout.board_x
	_board_y = layout.board_y
	_font_scale = layout.font_scale


# ── Spawning ──

func _spawn_next_piece() -> void:
	var p_type: int = bag.next_piece()
	print("  spawn_next_piece: type=", p_type)
	if not controller.spawn(p_type):
		state = State.GAME_OVER
		print("  SPAWN FAILED — GAME OVER")
	else:
		state = State.PLAYING
		gravity_acc = 0.0
		controller.lock_timer = 0.0
		controller.lock_resets = 0
		_hold_used_this_drop = false
		_hold_locked = false
		print("  spawn ok — cells:", controller.get_absolute_cells())


# ── Main loop ──

var _frame_count: int = 0

func _process(delta: float) -> void:
	if controller == null:
		return  # _ready() hasn't run yet
	_frame_count += 1
	if _frame_count == 1:
		print("  FIRST _process() frame — delta:", delta)
	if _frame_count % 60 == 1:
		print("Frame %d — state: %d, piece: %d, pos: %s, grav: %.2f, ground: %s" % [
			_frame_count, state,
			controller.piece_type if controller else -1,
			controller.position if controller else "N/A",
			gravity_acc,
			controller.is_on_ground() if controller else "N/A"
		])

	match state:
		State.PLAYING:
			_process_playing(delta)
		State.LINE_CLEAR:
			_process_line_clear(delta)
		State.GAME_OVER:
			_process_game_over(delta)

	queue_redraw()


func _process_playing(delta: float) -> void:
	# ── Input ──
	if Input.is_action_just_pressed("tetris_hard_drop"):
		_hard_drop()
		return

	if Input.is_action_just_pressed("tetris_rotate_cw"):
		_try_rotate_cw()

	if Input.is_action_just_pressed("tetris_rotate_ccw"):
		_try_rotate_ccw()

	if Input.is_action_just_pressed("tetris_hold"):
		_try_hold()

	# DAS left
	if Input.is_action_pressed("tetris_move_left"):
		if not das_left_active:
			_try_move_left()
			das_left_acc = Constants.DAS_INITIAL
			das_left_active = true
		else:
			das_left_acc -= delta
			while das_left_acc <= 0.0:
				_try_move_left()
				das_left_acc += Constants.DAS_REPEAT
	else:
		das_left_active = false
		das_left_acc = 0.0

	# DAS right
	if Input.is_action_pressed("tetris_move_right"):
		if not das_right_active:
			_try_move_right()
			das_right_acc = Constants.DAS_INITIAL
			das_right_active = true
		else:
			das_right_acc -= delta
			while das_right_acc <= 0.0:
				_try_move_right()
				das_right_acc += Constants.DAS_REPEAT
	else:
		das_right_active = false
		das_right_acc = 0.0

	# Soft drop
	if Input.is_action_pressed("tetris_soft_drop"):
		_try_soft_drop(delta)

	# ── Gravity ──
	gravity_acc += delta
	var gravity_interval: float = _get_gravity_interval()
	while gravity_acc >= gravity_interval:
		gravity_acc -= gravity_interval
		if not _try_gravity():
			gravity_acc = 0.0
				break

	# ── Lock delay ──
	if controller.is_on_ground() and not controller.is_locked:
		controller.lock_timer += delta
		if controller.lock_timer >= Constants.LOCK_DELAY:
			_lock_piece()
	else:
		controller.lock_timer = 0.0


func _process_line_clear(delta: float) -> void:
	line_clear_timer -= delta
	if line_clear_timer <= 0.0:
		_do_clear_lines()
		_spawn_next_piece()


func _process_game_over(_delta: float) -> void:
	# Also restarts on hard drop / mobile hard-drop button
	if Input.is_action_just_pressed("tetris_hard_drop"):
		_restart()


# ── Actions ──

func _try_move_left() -> void:
	if controller.move_left():
		_reset_lock_if_on_ground()


func _try_move_right() -> void:
	if controller.move_right():
		_reset_lock_if_on_ground()


func _try_soft_drop(delta: float) -> void:
	gravity_acc += delta * (Constants.GRAVITY_SPEEDS[1] / Constants.SOFT_DROP_FACTOR - 1.0)
	if controller.move_down():
		score += Constants.SCORE_SOFT_DROP
		gravity_acc = 0.0


func _try_rotate_cw() -> void:
	if controller.rotate_cw():
		_reset_lock_if_on_ground()
		if controller.piece_type == Constants.PieceType.T:
			board.last_move_was_rotation = true


func _try_rotate_ccw() -> void:
	if controller.rotate_ccw():
		_reset_lock_if_on_ground()
		if controller.piece_type == Constants.PieceType.T:
			board.last_move_was_rotation = true



func _try_hold() -> void:
	if _hold_locked:
		return
	var current_type: int = controller.piece_type
	if _held_piece_type == Constants.PieceType.EMPTY:
		# First hold — store current, spawn next
		_held_piece_type = current_type
		_hold_locked = true
		_spawn_next_piece()
	else:
		# Swap held with current
		var swap_type: int = _held_piece_type
		_held_piece_type = current_type
		_hold_locked = true
		if not controller.spawn(swap_type):
			state = State.GAME_OVER
func _try_gravity() -> bool:
	return controller.move_down()


func _hard_drop() -> void:
	var distance: int = controller.hard_drop()
	score += distance * Constants.SCORE_HARD_DROP
	_lock_piece()


func _reset_lock_if_on_ground() -> void:
	if controller.is_on_ground() and controller.lock_resets < Constants.MAX_LOCK_RESETS:
		controller.lock_timer = 0.0
		controller.lock_resets += 1


func _lock_piece() -> void:
	controller.is_locked = true
	var cells = controller.get_absolute_cells()

	# Score T-spin before locking
	var tspin: bool = false
	if controller.piece_type == Constants.PieceType.T and board.last_move_was_rotation:
		var corners: int = board.check_tspin_corners(controller.position)
		tspin = (corners >= 3)

	# Write piece to board
	board.lock_piece(cells, controller.piece_type)
	board.last_move_was_rotation = false

	# Check game over (piece locked in vanish zone)
	if board.is_game_over():
		state = State.GAME_OVER
		print("GAME OVER — vanish zone breached")
		return

	# Line clear
	cleared_row_indices = board.clear_lines()
	if cleared_row_indices.size() > 0:
		_score_lines(cleared_row_indices.size(), tspin)
		state = State.LINE_CLEAR
		line_clear_timer = 0.3
	else:
		_spawn_next_piece()


func _do_clear_lines() -> void:
	pass


func _restart() -> void:
	board = Board.new()
	bag.reset()
	score = 0
	lines_cleared = 0
	level = 1
	gravity_acc = 0.0
	_held_piece_type = Constants.PieceType.EMPTY
	_spawn_next_piece()
	state = State.PLAYING


# ── Scoring ──

func _score_lines(line_count: int, is_tspin: bool) -> void:
	var base: int
	match line_count:
		1: base = Constants.SCORE_TSPIN_SINGLE if is_tspin else Constants.SCORE_SINGLE
		2: base = Constants.SCORE_TSPIN_DOUBLE if is_tspin else Constants.SCORE_DOUBLE
		3: base = Constants.SCORE_TSPIN_TRIPLE if is_tspin else Constants.SCORE_TRIPLE
		_: base = Constants.SCORE_TETRIS

	score += base * level
	lines_cleared += line_count

	var new_level: int = (lines_cleared / Constants.LINES_PER_LEVEL) + 1
	if new_level > level:
		level = min(new_level, Constants.MAX_LEVEL)
		print("Level up! %d" % level)


func _get_gravity_interval() -> float:
	var idx: int = min(level, Constants.GRAVITY_SPEEDS.size() - 1)
	return Constants.GRAVITY_SPEEDS[idx]


# ── Rendering ──

var _draw_count: int = 0

func _draw() -> void:
	if board == null or controller == null:
		return  # _ready() hasn't run yet
	_draw_count += 1
	if _draw_count == 1:
		print("  FIRST _draw() CALLED — viewport:", get_viewport_rect())
	if _draw_count == 2:
		print("  second _draw() — still alive")

	var cs: int = _cell_size
	var bx: int = _board_x
	var by: int = _board_y
	var margin: int = maxi(4, cs / 4)
	var font_s: int = int(14 * _font_scale)
	var font_m: int = int(16 * _font_scale)
	var font_l: int = int(24 * _font_scale)

	# Full background fill — confirms _draw() is running
	var vp_rect = get_viewport_rect()
	draw_rect(Rect2(Vector2.ZERO, vp_rect.size), Color(0.1, 0.1, 0.15))

	# Board background
	var board_width: int = Constants.COLS * cs
	var board_height: int = Constants.VISIBLE_ROWS * cs
	draw_rect(Rect2(bx, by, board_width, board_height), Color(0.05, 0.05, 0.08))
	draw_rect(Rect2(bx - 1, by - 1, board_width + 2, board_height + 2), Color.WHITE, false, 2.0)

	# Locked cells (visible rows only: rows 2 through 21)
	for r in range(2, Constants.ROWS):
		for c in range(Constants.COLS):
			var cell_type: int = board.get_cell(c, r)
			if cell_type != Constants.PieceType.EMPTY:
				var color = Constants.COLORS.get(cell_type, Color.GRAY)
				_draw_cell(c, r - 2, color, cs, bx, by)

	# Ghost piece
	if state == State.PLAYING and not controller.is_locked:
		var ghost_y: int = controller.get_ghost_y()
		var ghost_pos := Vector2i(controller.position.x, ghost_y)
		var ghost_cells := controller.get_cells_at(ghost_pos, controller.rotation)
		var ghost_color = Constants.COLORS.get(controller.piece_type, Color.GRAY)
		ghost_color.a = 0.25
		for cell in ghost_cells:
			if cell.y >= 2:
				_draw_cell(cell.x, cell.y - 2, ghost_color, cs, bx, by)

	# Active piece
	if state != State.GAME_OVER and not controller.is_locked:
		var active_cells = controller.get_absolute_cells()
		var active_color = Constants.COLORS.get(controller.piece_type, Color.GRAY)
		for cell in active_cells:
			if cell.y >= 2:
				_draw_cell(cell.x, cell.y - 2, active_color, cs, bx, by)

	# Line clear flash
	if state == State.LINE_CLEAR:
		for row_idx in cleared_row_indices:
			var visible_row: int = row_idx - 2
			if visible_row >= 0:
				var flash_rect := Rect2(bx, by + visible_row * cs, board_width, cs)
				draw_rect(flash_rect, Color.WHITE, false, 2.0)

	# Game over overlay
	if state == State.GAME_OVER:
		draw_rect(Rect2(bx - 2, by - 2, board_width + 4, board_height + 4), Color.RED, false, 3.0)
		var font = ThemeDB.fallback_font
		var go_text := "GAME OVER"
		var go_size := font.get_string_size(go_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_l)
		draw_string(font, Vector2(bx + (board_width - go_size.x) / 2.0, by + board_height / 2 - go_size.y),
			go_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_l, Color.RED)
		var restart_text := "Tap ⬇ to Restart"
		var restart_size := font.get_string_size(restart_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_m)
		draw_string(font, Vector2(bx + (board_width - restart_size.x) / 2.0, by + board_height / 2 + 10),
			restart_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_m, Color(1.0, 1.0, 1.0, 0.7))

	# Score display
	var font = ThemeDB.fallback_font
	var right_x: int = bx + board_width + margin
	draw_string(font, Vector2(right_x, by + cs),
		"Score: %d" % score, HORIZONTAL_ALIGNMENT_LEFT, -1, font_m)
	draw_string(font, Vector2(right_x, by + cs + font_m + 6),
		"Lines: %d" % lines_cleared, HORIZONTAL_ALIGNMENT_LEFT, -1, font_m)
	draw_string(font, Vector2(right_x, by + cs + (font_m + 6) * 2),
		"Level: %d" % level, HORIZONTAL_ALIGNMENT_LEFT, -1, font_m)

	# Hold piece display
	var hold_x: int = bx - cs * 2 - margin
	if hold_x < 0:
		hold_x = margin
	var hold_label := "Hold"
	var font2 = ThemeDB.fallback_font
	draw_string(font2, Vector2(hold_x, by + cs), hold_label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_s)
	if _held_piece_type != Constants.PieceType.EMPTY:
		var hold_color = Constants.COLORS.get(_held_piece_type, Color.GRAY)
		if _hold_locked:
			hold_color.a = 0.35
		var hold_offsets = piece_data.CELLS[_held_piece_type][0]
		var hy: int = by + cs + font_s + margin
		for off in hold_offsets:
			var hpx: int = hold_x + off.x * (cs / 2)
			draw_rect(Rect2(hpx, hy + off.y * (cs / 2), cs / 2, cs / 2), hold_color)
			draw_rect(Rect2(hpx, hy + off.y * (cs / 2), cs / 2, cs / 2), Color.BLACK, false, 1.0)

	# Next piece preview
	if state != State.GAME_OVER:
		var next_pieces = bag.peek_next(3)
		var next_y: int = by + cs + (font_m + 6) * 3 + margin
		draw_string(font, Vector2(right_x, next_y),
			"Next:", HORIZONTAL_ALIGNMENT_LEFT, -1, font_s)
		for i in range(next_pieces.size()):
			var preview_type: int = next_pieces[i]
			var preview_color = Constants.COLORS.get(preview_type, Color.GRAY)
			var preview_offsets = piece_data.CELLS[preview_type][0]
			var py: int = next_y + font_s + margin + i * (cs * 3)
			for off in preview_offsets:
				var px: int = right_x + off.x * (cs / 2)
				draw_rect(Rect2(px, py + off.y * (cs / 2), cs / 2, cs / 2), preview_color)
				draw_rect(Rect2(px, py + off.y * (cs / 2), cs / 2, cs / 2), Color.BLACK, false, 1.0)


func _draw_cell(col: int, visible_row: int, color: Color, cell_size: int, board_x: int, board_y: int) -> void:
	var rect := Rect2(
		board_x + col * cell_size,
		board_y + visible_row * cell_size,
		cell_size, cell_size
	)
	draw_rect(rect, color)
	draw_rect(rect, Color.BLACK, false, 1.0)
