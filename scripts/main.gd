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

# ── Shader rendering nodes ──
# Board (data texture + shader)
var _board_rect: ColorRect = null
var _board_material: ShaderMaterial = null
var _board_image: Image = null
var _board_texture: ImageTexture = null
const BOARD_TEX_W: int = 10
const BOARD_TEX_H: int = 22

# Active piece (4 pooled cells)
var _piece_container: Node2D = null
var _piece_cells: Array[ColorRect] = []
var _piece_materials: Array[ShaderMaterial] = []

# Ghost piece (4 pooled cells)
var _ghost_container: Node2D = null
var _ghost_cells: Array[ColorRect] = []
var _ghost_materials: Array[ShaderMaterial] = []

# HUD Labels
var _score_label: Label = null
var _lines_label: Label = null
var _time_label: Label = null
var _level_label: Label = null
var _hold_title_label: Label = null
var _next_title_label: Label = null

# Hold preview (4 pooled cells)
var _hold_container: Node2D = null
var _hold_cells: Array[ColorRect] = []
var _hold_materials: Array[ShaderMaterial] = []

# Next preview (3 pieces x 4 cells each)
var _next_container: Node2D = null
var _next_sub_containers: Array[Node2D] = []
var _next_cells: Array = []
var _next_materials: Array = []

# Background fallback
var _bg_fallback_rect: ColorRect = null

# Piece shader resource (shared by all piece cells)
var _piece_shader: Shader = null

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
	_create_render_nodes()
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
	_position_all_nodes()

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

# ═══════════════════════════════════════════════════════════
# ── Shader rendering node creation ──
# ═══════════════════════════════════════════════════════════

func _create_render_nodes() -> void:
	# Pre-load piece shader (shared by all piece/ghost/hold/next cells)
	_piece_shader = load("res://shaders/piece.gdshader") as Shader

	_create_board_node()
	_create_piece_cells()
	_create_ghost_cells()
	_create_hud_labels()
	_create_hold_preview()
	_create_next_preview()
	_create_bg_fallback()
	_position_all_nodes()
	_update_board_texture()

func _make_piece_cell(color: Color, alpha: float, glow: float, size: float = -1.0) -> ColorRect:
	"""Create a single ColorRect with piece.gdshader material."""
	var cr := ColorRect.new()
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if size > 0:
		cr.size = Vector2(size, size)
	var mat := ShaderMaterial.new()
	mat.shader = _piece_shader
	mat.set_shader_parameter("fill_color", color)
	mat.set_shader_parameter("alpha", alpha)
	mat.set_shader_parameter("glow_intensity", glow)
	mat.set_shader_parameter("cell_radius", 0.18)
	cr.material = mat
	return cr

func _create_board_node() -> void:
	var shader_res := load("res://shaders/board.gdshader") as Shader
	if shader_res == null:
		push_error("Failed to load board shader")
		return

	_board_material = ShaderMaterial.new()
	_board_material.shader = shader_res

	# Colors from Constants.COLORS
	var c := Constants.COLORS
	_board_material.set_shader_parameter("color_empty", Color(0.05, 0.05, 0.08, 1.0))
	_board_material.set_shader_parameter("color_1", c[Constants.PieceType.I])
	_board_material.set_shader_parameter("color_2", c[Constants.PieceType.O])
	_board_material.set_shader_parameter("color_3", c[Constants.PieceType.T])
	_board_material.set_shader_parameter("color_4", c[Constants.PieceType.S])
	_board_material.set_shader_parameter("color_5", c[Constants.PieceType.Z])
	_board_material.set_shader_parameter("color_6", c[Constants.PieceType.J])
	_board_material.set_shader_parameter("color_7", c[Constants.PieceType.L])
	_board_material.set_shader_parameter("grid_color", Color(0.02, 0.02, 0.04, 1.0))
	_board_material.set_shader_parameter("flash_rows", Vector4(-1.0, -1.0, -1.0, -1.0))

	# Data texture (10x22, FORMAT_RF = 32-bit float per pixel)
	_board_image = Image.create(BOARD_TEX_W, BOARD_TEX_H, false, Image.FORMAT_RF)
	_board_image.fill(Color(0, 0, 0, 1))  # all empty
	_board_texture = ImageTexture.create_from_image(_board_image)
	_board_material.set_shader_parameter("board_tex", _board_texture)

	_board_rect = ColorRect.new()
	_board_rect.name = "BoardRect"
	_board_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board_rect.material = _board_material
	add_child(_board_rect)

func _create_piece_cells() -> void:
	_piece_container = Node2D.new()
	_piece_container.name = "PieceContainer"
	add_child(_piece_container)

	for i in range(4):
		var cr := _make_piece_cell(Color.WHITE, 1.0, 0.4)
		_piece_container.add_child(cr)
		_piece_cells.append(cr)
		_piece_materials.append(cr.material as ShaderMaterial)

func _create_ghost_cells() -> void:
	_ghost_container = Node2D.new()
	_ghost_container.name = "GhostContainer"
	add_child(_ghost_container)

	for i in range(4):
		var cr := _make_piece_cell(Color.WHITE, 0.25, 0.15)
		_ghost_container.add_child(cr)
		_ghost_cells.append(cr)
		_ghost_materials.append(cr.material as ShaderMaterial)

func _create_hud_labels() -> void:
	var font := ThemeDB.fallback_font
	_score_label = Label.new()
	_score_label.name = "ScoreLabel"
	_score_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_score_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_score_label)

	_lines_label = Label.new()
	_lines_label.name = "LinesLabel"
	_lines_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lines_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_lines_label)

	_level_label = Label.new()
	_level_label.name = "LevelLabel"
	_level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_level_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_level_label)

	_time_label = Label.new()
	_time_label.name = "TimeLabel"
	_time_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_time_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_time_label)

	_hold_title_label = Label.new()
	_hold_title_label.name = "HoldTitleLabel"
	_hold_title_label.text = "Hold"
	_hold_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hold_title_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_hold_title_label)

	_next_title_label = Label.new()
	_next_title_label.name = "NextTitleLabel"
	_next_title_label.text = "Next:"
	_next_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_next_title_label.add_theme_color_override("font_color", Color.WHITE)
	add_child(_next_title_label)

func _create_hold_preview() -> void:
	_hold_container = Node2D.new()
	_hold_container.name = "HoldPreview"
	add_child(_hold_container)
	for i in range(4):
		var cr := _make_piece_cell(Color.GRAY, 1.0, 0.2, 0)
		_hold_container.add_child(cr)
		_hold_cells.append(cr)
		_hold_materials.append(cr.material as ShaderMaterial)

func _create_next_preview() -> void:
	_next_container = Node2D.new()
	_next_container.name = "NextPreview"
	add_child(_next_container)
	for i in range(3):
		var sub := Node2D.new()
		sub.name = "NextPiece%d" % i
		_next_container.add_child(sub)
		_next_sub_containers.append(sub)
		var cells: Array[ColorRect] = []
		var mats: Array[ShaderMaterial] = []
		for j in range(4):
			var cr := _make_piece_cell(Color.GRAY, 1.0, 0.2, 0)
			sub.add_child(cr)
			cells.append(cr)
			mats.append(cr.material as ShaderMaterial)
		_next_cells.append(cells)
		_next_materials.append(mats)

func _create_bg_fallback() -> void:
	_bg_fallback_rect = ColorRect.new()
	_bg_fallback_rect.name = "BgFallback"
	_bg_fallback_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_fallback_rect.visible = not _bg_ok
	# Show behind everything
	_bg_fallback_rect.z_index = -10
	var shader_res := load("res://shaders/background.gdshader") as Shader
	if shader_res:
		var mat := ShaderMaterial.new()
		mat.shader = shader_res
		_bg_fallback_rect.material = mat
	else:
		_bg_fallback_rect.color = Color(0.1, 0.1, 0.15)
	add_child(_bg_fallback_rect)

# ═══════════════════════════════════════════════════════════
# ── Shader rendering updates ──
# ═══════════════════════════════════════════════════════════

func _update_board_texture() -> void:
	"""Copy board.grid → 10×22 ImageTexture. Call after lock/clear/reset."""
	if _board_image == null or board == null:
		return
	for r in range(Constants.ROWS):
		for c in range(Constants.COLS):
			var val: float = float(board.get_cell(c, r))
			_board_image.set_pixel(c, r, Color(val, 0, 0, 1))
	_board_texture.update(_board_image)

func _update_piece_positions() -> void:
	"""Position active piece cells each frame."""
	if state != State.PLAYING or controller.is_locked:
		_piece_container.visible = false
		return

	var cs: int = _cell_size
	var bx: int = _board_x
	var by: int = _board_y
	var cells := controller.get_absolute_cells()
	var color := Constants.COLORS.get(controller.piece_type, Color.GRAY)

	_piece_container.visible = true
	var idx := 0
	for cell in cells:
		if idx >= _piece_cells.size():
			break
		if cell.y >= 2:
			_piece_cells[idx].position = Vector2(bx + cell.x * cs, by + (cell.y - 2) * cs)
			_piece_cells[idx].size = Vector2(cs, cs)
			_piece_materials[idx].set_shader_parameter("fill_color", color)
			_piece_cells[idx].visible = true
		else:
			_piece_cells[idx].visible = false
		idx += 1

func _update_ghost_positions() -> void:
	"""Position ghost piece cells each frame."""
	if state != State.PLAYING or controller.is_locked:
		_ghost_container.visible = false
		return

	var cs: int = _cell_size
	var bx: int = _board_x
	var by: int = _board_y
	var ghost_y: int = controller.get_ghost_y()
	var ghost_pos := Vector2i(controller.position.x, ghost_y)
	var cells := controller.get_cells_at(ghost_pos, controller.rotation)
	var color := Constants.COLORS.get(controller.piece_type, Color.GRAY)

	_ghost_container.visible = true
	var idx := 0
	for cell in cells:
		if idx >= _ghost_cells.size():
			break
		if cell.y >= 2:
			_ghost_cells[idx].position = Vector2(bx + cell.x * cs, by + (cell.y - 2) * cs)
			_ghost_cells[idx].size = Vector2(cs, cs)
			_ghost_materials[idx].set_shader_parameter("fill_color", color)
			_ghost_cells[idx].visible = true
		else:
			_ghost_cells[idx].visible = false
		idx += 1

func _update_hud() -> void:
	"""Update HUD label text. Called each frame during gameplay."""
	_score_label.text = "Score: %d" % score
	_level_label.text = "Level: %d" % level

	if sprint_target > 0:
		_lines_label.text = "Lines: %d/%d" % [lines_cleared, sprint_target]
	else:
		_lines_label.text = "Lines: %d" % lines_cleared

	if sprint_target > 0:
		_time_label.text = "Time: %s" % _format_time(sprint_time)
		_time_label.visible = true
	else:
		_time_label.visible = false

func _update_hold_preview() -> void:
	"""Update hold piece display. Call when hold piece changes."""
	if _held_piece_type == Constants.PieceType.EMPTY:
		for i in range(_hold_cells.size()):
			_hold_cells[i].visible = false
		return

	var preview_cs: int = maxi(4, _cell_size / 2)
	var offsets := piece_data.CELLS[_held_piece_type][0]
	var color := Constants.COLORS.get(_held_piece_type, Color.GRAY)

	for i in range(4):
		if i >= _hold_cells.size():
			break
		var off: Vector2i = offsets[i]
		_hold_cells[i].position = Vector2(off.x * preview_cs, off.y * preview_cs)
		_hold_cells[i].size = Vector2(preview_cs, preview_cs)
		var alpha: float = 0.35 if _hold_locked else 1.0
		_hold_materials[i].set_shader_parameter("fill_color", color)
		_hold_materials[i].set_shader_parameter("alpha", alpha)
		_hold_cells[i].visible = true

func _update_next_preview() -> void:
	"""Update next-piece preview display. Call when bag advances or on reset."""
	if state == State.GAME_OVER or state == State.SPRINT_COMPLETE:
		for sub in _next_sub_containers:
			sub.visible = false
		return

	var preview_cs: int = maxi(4, _cell_size / 2)
	var next_pieces := bag.peek_next(3)

	for i in range(3):
		_next_sub_containers[i].visible = true
		var p_type: int = next_pieces[i]
		var color := Constants.COLORS.get(p_type, Color.GRAY)
		var offsets := piece_data.CELLS[p_type][0]
		for j in range(4):
			if j >= _next_cells[i].size():
				break
			var off: Vector2i = offsets[j]
			_next_cells[i][j].position = Vector2(off.x * preview_cs, off.y * preview_cs)
			_next_cells[i][j].size = Vector2(preview_cs, preview_cs)
			_next_materials[i][j].set_shader_parameter("fill_color", color)
			_next_materials[i][j].set_shader_parameter("alpha", 1.0)
			_next_cells[i][j].visible = true

func _set_flash_rows(rows: Array, intensity: float) -> void:
	"""Set line clear flash uniforms on the board shader."""
	if _board_material == null:
		return
	var r := Vector4(-1.0, -1.0, -1.0, -1.0)
	for i in range(mini(rows.size(), 4)):
		# Convert grid row to visible row (row - 2)
		r[i] = float(rows[i] - 2)
	_board_material.set_shader_parameter("flash_rows", r)
	_board_material.set_shader_parameter("flash_intensity", intensity)

func _position_all_nodes() -> void:
	var cs: int = _cell_size
	var bx: float = _board_x
	var by: float = _board_y
	var board_w: float = Constants.COLS * cs
	var board_h: float = Constants.VISIBLE_ROWS * cs
	var margin: float = maxf(4, cs / 4.0)
	var font_s: int = int(14 * _font_scale)
	var font_m: int = int(16 * _font_scale)

	# Board
	if _board_rect:
		_board_rect.position = Vector2(bx, by)
		_board_rect.size = Vector2(board_w, board_h)

	# HUD labels (right side)
	var right_x: float = bx + board_w + margin
	var line_h: float = font_m + 8
	var score_y: float = by + cs + font_m

	if _score_label:
		_score_label.position = Vector2(right_x, score_y)
		_score_label.add_theme_font_size_override("font_size", font_m)
	if _lines_label:
		_lines_label.position = Vector2(right_x, score_y + line_h)
		_lines_label.add_theme_font_size_override("font_size", font_m)
	if _level_label:
		_level_label.position = Vector2(right_x, score_y + line_h * 2)
		_level_label.add_theme_font_size_override("font_size", font_m)
	if _time_label:
		_time_label.position = Vector2(right_x, score_y + line_h * 3)
		_time_label.add_theme_font_size_override("font_size", font_m)

	# Hold (left side)
	var hold_x: float = bx - cs * 2 - margin
	if hold_x < 0:
		hold_x = margin
	if _hold_title_label:
		_hold_title_label.position = Vector2(hold_x, by + cs + font_s)
		_hold_title_label.add_theme_font_size_override("font_size", font_s)
	if _hold_container:
		_hold_container.position = Vector2(hold_x, by + cs + font_s + font_m + margin)

	# Next (right side, below score)
	var next_y: float = score_y + line_h * 3 + margin
	if sprint_target > 0:
		next_y += line_h
	if _next_title_label:
		_next_title_label.position = Vector2(right_x, next_y)
		_next_title_label.add_theme_font_size_override("font_size", font_s)
	if _next_container:
		_next_container.position = Vector2(right_x, next_y + font_s + margin)
		var preview_spacing: float = cs * 3
		for i in range(_next_sub_containers.size()):
			_next_sub_containers[i].position = Vector2(0, i * preview_spacing)

	# Background fallback
	if _bg_fallback_rect:
		var vp := get_viewport_rect()
		_bg_fallback_rect.position = Vector2.ZERO
		_bg_fallback_rect.size = vp.size

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
		_update_next_preview()
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

	# ── Shader-based rendering updates (every frame) ──
	if state != State.SPRINT_MENU and state != State.SPRINT_COMPLETE:
		_update_piece_positions()
		_update_ghost_positions()
		_update_hud()

	# Overlays (sprint menu, game over, sprint complete) still use _draw()
	if state == State.SPRINT_MENU or state == State.GAME_OVER or state == State.SPRINT_COMPLETE:
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
	# Flash animation: pulse intensity
	var t: float = 1.0 - (line_clear_timer / 0.4)
	var intensity: float = sin(t * PI)  # 0→1→0
	_set_flash_rows(cleared_row_indices, intensity)
	if line_clear_timer <= 0.0:
		_set_flash_rows([], 0.0)
		_do_clear_lines()
		# Only spawn if we didn't transition to sprint complete / game over
		if state == State.LINE_CLEAR:
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
		_update_hold_preview()
		_spawn_next_piece()
	else:
		# Swap held with current
		var swap_type: int = _held_piece_type
		_held_piece_type = current_type
		_hold_locked = true
		_update_hold_preview()
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
	_update_board_texture()

	# Check game over (piece locked in vanish zone)
	if board.is_game_over():
		state = State.GAME_OVER
		print("GAME OVER — vanish zone breached")
		return

	# Line clear — pause for flash animation
	cleared_row_indices = board.clear_lines()
	if cleared_row_indices.size() > 0:
		line_clear_timer = 0.4
		state = State.LINE_CLEAR
		return  # _process_line_clear handles scoring + spawn

	# Sprint completion check
	if sprint_target > 0 and lines_cleared >= sprint_target:
		_finish_sprint()
		return

	_spawn_next_piece()

func _do_clear_lines() -> void:
	# Lines were already removed from grid in _lock_piece.
	# Score them (no T-spin — that was already scored if applicable).
	_score_lines(cleared_row_indices.size(), false)
	_update_board_texture()

	# Sprint completion check
	if sprint_target > 0 and lines_cleared >= sprint_target:
		_finish_sprint()

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
	_hold_locked = false
	_hold_used_this_drop = false
	_update_board_texture()
	_set_flash_rows([], 0.0)
	_update_hold_preview()
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
		return
	_draw_count += 1

	var cs: int = _cell_size
	var bx: int = _board_x
	var by: int = _board_y
	var font_s: int = int(14 * _font_scale)
	var font_m: int = int(16 * _font_scale)
	var font_l: int = int(24 * _font_scale)

	# Sprint menu — full-screen, skip all game rendering
	if state == State.SPRINT_MENU:
		_draw_sprint_menu(font_s, font_m, font_l)
		return

	var board_width: int = Constants.COLS * cs
	var board_height: int = Constants.VISIBLE_ROWS * cs
	var board_center_x: float = bx + board_width / 2.0
	var board_center_y: float = by + board_height / 2.0
	var font = ThemeDB.fallback_font

	# Game over overlay
	if state == State.GAME_OVER:
		draw_rect(Rect2(bx - 2, by - 2, board_width + 4, board_height + 4), Color.RED, false, 3.0)
		draw_string(font, Vector2(board_center_x, board_center_y - font_l - 4),
			"GAME OVER", HORIZONTAL_ALIGNMENT_CENTER, -1, font_l, Color.RED)
		draw_string(font, Vector2(board_center_x, board_center_y + 8),
			"Tap ⬇ or R for Menu", HORIZONTAL_ALIGNMENT_CENTER, -1, font_m, Color(1.0, 1.0, 1.0, 0.7))
		if sprint_target > 0:
			draw_string(font, Vector2(board_center_x, board_center_y + 8 + font_m + 6),
				"Cleared %d/%d lines in %s" % [lines_cleared, sprint_target, _format_time(sprint_time)],
				HORIZONTAL_ALIGNMENT_CENTER, -1, font_s, Color(1.0, 1.0, 1.0, 0.5))
		return

	# Sprint complete overlay
	if state == State.SPRINT_COMPLETE:
		_draw_sprint_complete(font, font_s, font_m, font_l, board_center_x, board_center_y, board_width)
		return
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


