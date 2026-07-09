# main.gd — Game orchestrator: state machine, gravity, input, rendering.
# Attached to the root Node2D of main.tscn.
extends Node2D

# ── Game state ──
enum State { SPRINT_MENU, PLAYING, LINE_CLEAR, GAME_OVER, SPRINT_COMPLETE }
var state: int = State.SPRINT_MENU

# ── Core objects ──
var board: Board
var controller: PieceController
var bag: BagRandomizer
var piece_data: Node  # PieceData autoload reference

# ── Scoring ──
var score: int = 0
var lines_cleared: int = 0
var level: int = 1

# ── Sprint mode ──
const SPRINT_TARGETS: Array[int] = [20, 40, 100, 200]
const SPRINT_SAVE_PATH: String = "user://sprint_records.cfg"
var sprint_target: int = 0               # 0 = menu, then 20/40/100/200
var sprint_time: float = 0.0             # elapsed seconds in current sprint
var sprint_records: Dictionary = {}      # {20: 45.2, 40: 90.1, ...}
var _menu_target_rects: Array[Rect2] = [] # hit-test rects for sprint menu
var _sprint_new_record: bool = false      # true if this run set a record

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

# ── Background image ──
var _bg_layer: CanvasLayer = null
var _bg_rect: TextureRect = null
var _bg_ok: bool = false


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
	_load_sprint_records()
	_setup_background()
	print("=== _ready() done — state: SPRINT_MENU ===")


func _setup_input_actions() -> void:
	# Only set up once
	if InputMap.has_action("tetris_move_left") and InputMap.has_action("tetris_restart"):
		return

	_add_action_if_missing("tetris_move_left")
	_create_input_event("tetris_move_left", KEY_LEFT)
	_create_input_event("tetris_move_left", KEY_A)

	_add_action_if_missing("tetris_move_right")
	_create_input_event("tetris_move_right", KEY_RIGHT)
	_create_input_event("tetris_move_right", KEY_D)

	_add_action_if_missing("tetris_soft_drop")
	_create_input_event("tetris_soft_drop", KEY_DOWN)
	_create_input_event("tetris_soft_drop", KEY_S)

	_add_action_if_missing("tetris_hard_drop")
	_create_input_event("tetris_hard_drop", KEY_SPACE)

	_add_action_if_missing("tetris_rotate_cw")
	_create_input_event("tetris_rotate_cw", KEY_X)
	_create_input_event("tetris_rotate_cw", KEY_UP)

	_add_action_if_missing("tetris_rotate_ccw")
	_create_input_event("tetris_rotate_ccw", KEY_Z)
	_create_input_event("tetris_rotate_ccw", KEY_CTRL)

	_add_action_if_missing("tetris_hold")
	_create_input_event("tetris_hold", KEY_C)
	_create_input_event("tetris_hold", KEY_SHIFT)

	_add_action_if_missing("tetris_restart")
	_create_input_event("tetris_restart", KEY_R)

func _add_action_if_missing(action: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)

func _create_input_event(action: String, keycode: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	InputMap.action_add_event(action, ev)


func _input(event: InputEvent) -> void:
	match state:
		State.SPRINT_MENU:
			if event is InputEventKey and event.pressed and not event.echo:
				for i in range(SPRINT_TARGETS.size()):
					if event.keycode == KEY_1 + i:
						_start_sprint(SPRINT_TARGETS[i])
						return
			if event is InputEventScreenTouch and event.pressed:
				for i in range(_menu_target_rects.size()):
					if _menu_target_rects[i].has_point(event.position):
						_start_sprint(SPRINT_TARGETS[i])
						return
		State.SPRINT_COMPLETE:
			if (event is InputEventKey and event.pressed) or (event is InputEventScreenTouch and event.pressed):
				_restart()


func _update_layout() -> void:
	var vp_size := get_viewport_rect().size
	if vp_size.x <= 0:
		return
	var layout := Constants.calculate_layout(vp_size)
	_cell_size = layout.cell_size
	_board_x = layout.board_x
	_board_y = layout.board_y
	_font_scale = layout.font_scale
	_fit_background()


# ── Background image ──

func _setup_background() -> void:
	_bg_layer = CanvasLayer.new()
	_bg_layer.layer = -1
	_bg_layer.name = "BackgroundLayer"
	add_child(_bg_layer)

	_bg_rect = TextureRect.new()
	_bg_rect.name = "BackgroundImage"
	_bg_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_layer.add_child(_bg_rect)

	var tex := load("res://videos/azure-horizon.png") as Texture2D
	if tex:
		_bg_rect.texture = tex
		_bg_ok = true
		_fit_background()
		print("Background image loaded")
	else:
		push_warning("Background image not found, using dark fill fallback")


func _fit_background() -> void:
	if not _bg_ok or _bg_rect == null:
		return
	var vp := get_viewport_rect()
	_bg_rect.position = Vector2.ZERO
	_bg_rect.size = vp.size


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
	if _frame_count % 60 == 1 and state != State.SPRINT_MENU:
		print("Frame %d — state: %d, piece: %d, pos: %s, grav: %.2f, ground: %s" % [
			_frame_count, state,
			controller.piece_type if controller else -1,
			controller.position if controller else "N/A",
			gravity_acc,
			controller.is_on_ground() if controller else "N/A"
		])

	match state:
		State.SPRINT_MENU:
			pass  # input handled via _input()
		State.PLAYING:
			_process_playing(delta)
		State.LINE_CLEAR:
			_process_line_clear(delta)
		State.GAME_OVER:
			_process_game_over(delta)
		State.SPRINT_COMPLETE:
			pass  # input handled via _input()

	queue_redraw()


func _process_playing(delta: float) -> void:
	# ── Sprint timer ──
	if sprint_target > 0:
		sprint_time += delta

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

	if Input.is_action_just_pressed("tetris_restart"):
		_restart()
		return

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
	# Hard drop or restart returns to sprint menu
	if Input.is_action_just_pressed("tetris_hard_drop") or Input.is_action_just_pressed("tetris_restart"):
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

	# Line clear (instant — no pause)
	cleared_row_indices = board.clear_lines()
	if cleared_row_indices.size() > 0:
		_score_lines(cleared_row_indices.size(), tspin)

	# Sprint completion check
	if sprint_target > 0 and lines_cleared >= sprint_target:
		_finish_sprint()
		return

	_spawn_next_piece()


func _do_clear_lines() -> void:
	pass


func _restart() -> void:
	_restart_game_only()
	# Return to sprint menu
	sprint_target = 0
	sprint_time = 0.0
	state = State.SPRINT_MENU


func _restart_game_only() -> void:
	"""Reset board/score/level but keep sprint target. Used by _start_sprint."""
	board = Board.new()
	controller.board = board
	bag.reset()
	score = 0
	lines_cleared = 0
	level = 1
	gravity_acc = 0.0
	das_left_acc = 0.0; das_left_active = false
	das_right_acc = 0.0; das_right_active = false
	_held_piece_type = Constants.PieceType.EMPTY
	_spawn_next_piece()


func _start_sprint(target: int) -> void:
	"""Begin a new sprint with the given line target."""
	sprint_target = target
	sprint_time = 0.0
	_sprint_new_record = false
	_restart_game_only()


func _finish_sprint() -> void:
	"""Called when lines_cleared >= sprint_target. Checks/saves record."""
	var current_best: float = sprint_records.get(sprint_target, INF)
	_sprint_new_record = sprint_time < current_best
	if _sprint_new_record:
		sprint_records[sprint_target] = sprint_time
		_save_sprint_records()
	state = State.SPRINT_COMPLETE


func _format_time(seconds: float) -> String:
	if seconds < 60.0:
		return "%.1fs" % seconds
	var mins := int(seconds) / 60
	var secs := int(seconds) % 60
	var tenths := int(fmod(seconds, 1.0) * 10)
	return "%d:%02d.%d" % [mins, secs, tenths]


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




func _load_sprint_records() -> void:
	"""Load best sprint times from config file."""
	var cfg := ConfigFile.new()
	if cfg.load(SPRINT_SAVE_PATH) != OK:
		return
	for target in SPRINT_TARGETS:
		var val: float = cfg.get_value("records", str(target), 0.0)
		if val > 0.0:
			sprint_records[target] = val


func _save_sprint_records() -> void:
	"""Persist all sprint records to config file."""
	var cfg := ConfigFile.new()
	for target in sprint_records:
		cfg.set_value("records", str(target), sprint_records[target])
	cfg.save(SPRINT_SAVE_PATH)
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

	# Full background fill — only when video isn't available
	var vp_rect = get_viewport_rect()
	if not _bg_ok:
		draw_rect(Rect2(Vector2.ZERO, vp_rect.size), Color(0.1, 0.1, 0.15))

	# Sprint menu — full-screen, skip all game rendering
	if state == State.SPRINT_MENU:
		_draw_sprint_menu(font_s, font_m, font_l)
		return

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
	var font = ThemeDB.fallback_font
	var board_center_x: float = bx + board_width / 2.0
	var board_center_y: float = by + board_height / 2.0
	var right_x: int = bx + board_width + margin
	var hold_x: int = bx - cs * 2 - margin
	if hold_x < 0:
		hold_x = margin

	# Game over overlay
	if state == State.GAME_OVER:
		draw_rect(Rect2(bx - 2, by - 2, board_width + 4, board_height + 4), Color.RED, false, 3.0)
		var go_text := "GAME OVER"
		var go_size := font.get_string_size(go_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_l)
		draw_string(font, Vector2(board_center_x, board_center_y - go_size.y - 4),
			go_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_l, Color.RED)
		var restart_text := "Tap ⬇ or R for Menu"
		draw_string(font, Vector2(board_center_x, board_center_y + 8),
			restart_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_m, Color(1.0, 1.0, 1.0, 0.7))
		# Sprint progress during game over
		if sprint_target > 0:
			var prog_text := "Cleared %d/%d lines in %s" % [lines_cleared, sprint_target, _format_time(sprint_time)]
			draw_string(font, Vector2(board_center_x, board_center_y + 8 + font_m + 6),
				prog_text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_s, Color(1.0, 1.0, 1.0, 0.5))

	# Sprint complete overlay
	if state == State.SPRINT_COMPLETE:
		_draw_sprint_complete(font, font_s, font_m, font_l, board_center_x, board_center_y, board_width)
		return

	# Score display (right side, below board top)
	var score_y: float = by + cs + font_m
	var line_h: float = font_m + 8
	draw_string(font, Vector2(right_x, score_y),
		"Score: %d" % score, HORIZONTAL_ALIGNMENT_LEFT, -1, font_m)
	if sprint_target > 0:
		draw_string(font, Vector2(right_x, score_y + line_h),
			"Lines: %d/%d" % [lines_cleared, sprint_target], HORIZONTAL_ALIGNMENT_LEFT, -1, font_m)
	else:
		draw_string(font, Vector2(right_x, score_y + line_h),
			"Lines: %d" % lines_cleared, HORIZONTAL_ALIGNMENT_LEFT, -1, font_m)
	if sprint_target > 0:
		draw_string(font, Vector2(right_x, score_y + line_h * 2),
			"Time: %s" % _format_time(sprint_time), HORIZONTAL_ALIGNMENT_LEFT, -1, font_m)
		draw_string(font, Vector2(right_x, score_y + line_h * 3),
			"Level: %d" % level, HORIZONTAL_ALIGNMENT_LEFT, -1, font_m)
	else:
		draw_string(font, Vector2(right_x, score_y + line_h * 2),
			"Level: %d" % level, HORIZONTAL_ALIGNMENT_LEFT, -1, font_m)

	# Hold piece display (left side)
	var hold_label := "Hold"
	draw_string(font, Vector2(hold_x, by + cs + font_s),
		hold_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_s)
	if _held_piece_type != Constants.PieceType.EMPTY:
		var hold_color = Constants.COLORS.get(_held_piece_type, Color.GRAY)
		if _hold_locked:
			hold_color.a = 0.35
		var hold_offsets = piece_data.CELLS[_held_piece_type][0]
		var hy: int = by + cs + font_s + font_m + margin
		for off in hold_offsets:
			var hpx: int = hold_x + off.x * (cs / 2)
			draw_rect(Rect2(hpx, hy + off.y * (cs / 2), cs / 2, cs / 2), hold_color)
			draw_rect(Rect2(hpx, hy + off.y * (cs / 2), cs / 2, cs / 2), Color.BLACK, false, 1.0)

	# Next piece preview (right side, below score)
	if state != State.GAME_OVER and state != State.SPRINT_COMPLETE:
		var next_pieces = bag.peek_next(3)
		var next_y: float = score_y + line_h * 3 + margin
		if sprint_target > 0:
			next_y += line_h  # extra line for timer
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
func _draw_sprint_menu(font_s: int, font_m: int, font_l: int) -> void:
	var font := ThemeDB.fallback_font
	var vp_rect := get_viewport_rect()
	var cx := vp_rect.size.x / 2.0

	# Title
	var title := "SPRINT MODE"
	var title_y := vp_rect.size.y * 0.12
	draw_string(font, Vector2(cx, title_y),
		title, HORIZONTAL_ALIGNMENT_CENTER, -1, font_l + 8, Color.WHITE)

	var sub := "Select Target"
	draw_string(font, Vector2(cx, title_y + font_l + 14),
		sub, HORIZONTAL_ALIGNMENT_CENTER, -1, font_m, Color(1.0, 1.0, 1.0, 0.6))

	# Target buttons
	var btn_w := minf(vp_rect.size.x * 0.55, 280.0)
	var btn_h := 52.0
	var btn_gap := 12.0
	var total_h := float(SPRINT_TARGETS.size()) * btn_h + float(SPRINT_TARGETS.size() - 1) * btn_gap
	var start_y := title_y + font_l + 14 + font_m + 24

	_menu_target_rects.clear()

	for i in range(SPRINT_TARGETS.size()):
		var target := SPRINT_TARGETS[i]
		var bx := cx - btn_w / 2.0
		var by := start_y + float(i) * (btn_h + btn_gap)
		var rect := Rect2(bx, by, btn_w, btn_h)
		_menu_target_rects.append(rect)

		# Button fill
		draw_rect(rect, Color(0.2, 0.25, 0.38, 1.0), true)
		draw_rect(rect, Color(1.0, 1.0, 1.0, 0.2), false, 2.0)

		# Label: "40 Lines"
		var label := "%d Lines" % target
		# Show best time if available
		if sprint_records.has(target):
			var best_t: float = sprint_records[target]
			label += "    (best: %s)" % _format_time(best_t)

		var btn_fs := int(16 * _font_scale)
		var label_s := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, btn_fs)
		draw_string(font, Vector2(cx, by + btn_h / 2.0 - label_s.y / 2.0 + 2),
			label, HORIZONTAL_ALIGNMENT_CENTER, -1, btn_fs, Color.WHITE)

	# Footer hints
	var hint_y := start_y + total_h + 20
	draw_string(font, Vector2(cx, hint_y),
		"Keyboard: press 1-4 to select", HORIZONTAL_ALIGNMENT_CENTER, -1, int(12 * _font_scale),
		Color(1.0, 1.0, 1.0, 0.35))
	draw_string(font, Vector2(cx, hint_y + 18),
		"Mobile: tap a target above", HORIZONTAL_ALIGNMENT_CENTER, -1, int(12 * _font_scale),
		Color(1.0, 1.0, 1.0, 0.35))


func _draw_sprint_complete(font: Font, font_s: int, font_m: int, font_l: int,
		board_center_x: float, board_center_y: float, board_width: float) -> void:
	# Semi-transparent overlay over the board
	var cs := _cell_size
	var bx := _board_x
	var by := _board_y
	var board_height := Constants.VISIBLE_ROWS * cs
	var overlay_rect := Rect2(bx, by, board_width, board_height)
	draw_rect(overlay_rect, Color(0.0, 0.0, 0.0, 0.7), true)
	draw_rect(Rect2(bx - 2, by - 2, board_width + 4, board_height + 4), Color(0.2, 1.0, 0.3), false, 3.0)

	# "SPRINT COMPLETE!"
	var title := "SPRINT COMPLETE!"
	var title_size := font.get_string_size(title, HORIZONTAL_ALIGNMENT_CENTER, -1, font_l)
	draw_string(font, Vector2(board_center_x, board_center_y - title_size.y - 8),
		title, HORIZONTAL_ALIGNMENT_CENTER, -1, font_l, Color(0.3, 1.0, 0.4))

	# Time
	var time_str := "Time:  %s" % _format_time(sprint_time)
	draw_string(font, Vector2(board_center_x, board_center_y + 4),
		time_str, HORIZONTAL_ALIGNMENT_CENTER, -1, font_l, Color.WHITE)

	# Best / New record
	var best_y := board_center_y + font_l + 12
	if _sprint_new_record:
		draw_string(font, Vector2(board_center_x, best_y),
			"NEW RECORD!", HORIZONTAL_ALIGNMENT_CENTER, -1, font_m, Color(1.0, 1.0, 0.3))
	else:
		var best_t: float = sprint_records.get(sprint_target, sprint_time)
		var best_str := "Best:  %s" % _format_time(best_t)
		draw_string(font, Vector2(board_center_x, best_y),
			best_str, HORIZONTAL_ALIGNMENT_CENTER, -1, font_m, Color(1.0, 1.0, 1.0, 0.7))

	# Continue hint
	var hint_y := board_center_y + font_l + 12 + font_m + 16
	draw_string(font, Vector2(board_center_x, hint_y),
		"Tap or press any key to continue",
		HORIZONTAL_ALIGNMENT_CENTER, -1, font_s, Color(1.0, 1.0, 1.0, 0.5))


func _draw_cell(col: int, visible_row: int, color: Color, cell_size: int, board_x: int, board_y: int) -> void:
	var rect := Rect2(
		board_x + col * cell_size,
		board_y + visible_row * cell_size,
		cell_size, cell_size
	)
	draw_rect(rect, color)
	draw_rect(rect, Color.BLACK, false, 1.0)
