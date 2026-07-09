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
var _sprint_new_record: bool = false      # true if this run set a record
var _sprint_menu: Control = null          # MenuRoot of scenes/sprint_menu.tscn
var _mobile_controls: Control = null      # ButtonPanel of scenes/mobile_controls.tscn
var _game_settings: Node = null           # GameSettings autoload

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

# Line clear animation (off by default — set to true to enable flash)
const LINE_CLEAR_ANIMATION: bool = false
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
var _bg_bake_size: Vector2 = Vector2.ZERO

# Water splash ripples (piece lock). Each entry is a Dictionary:
# cells: PackedVector2Array (4 cell centers, board px, origin at board
# center), age: float, amp: float, half: float (cell half-size px).
const SPLASH_MAX: int = 6
const SPLASH_LIFE: float = 1.6
var _splashes: Array = []
var _splashes_clean: bool = false

# Piece shader resource (shared by all piece cells)
var _piece_shader: Shader = null
var _game_layer: CanvasLayer = null

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
	_setup_glow_environment()
	_create_render_nodes()
	_sprint_menu = get_node("SprintMenu/MenuRoot")
	_sprint_menu.setup(SPRINT_TARGETS, sprint_records)
	_sprint_menu.target_selected.connect(_start_sprint)
	_mobile_controls = get_node_or_null("MobileControls/ButtonPanel")
	_game_settings = get_node_or_null("/root/GameSettings")
	if _game_settings:
		_game_settings.changed.connect(_update_board_texture)
	_show_menu()
	print("=== _ready() done — state: SPRINT_MENU ===")

func _setup_glow_environment() -> void:
	"""Bloom for emissive blocks. glow_bloom MUST stay 0.0 — any higher
	blooms the entire screen (that was the white-wash bug). With it at 0,
	ONLY pixels above glow_hdr_threshold (i.e. the emissive blocks) glow."""
	var env := Environment.new()
	env.glow_enabled = true
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.25
	env.glow_intensity = 1.0
	env.glow_strength = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	var we := WorldEnvironment.new()
	we.name = "GlowEnvironment"
	we.environment = env
	add_child(we)

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
	_create_input_event("tetris_rotate_cw", KEY_K)
	_create_input_event("tetris_rotate_cw", KEY_UP)

	_add_action_if_missing("tetris_rotate_ccw")
	_create_input_event("tetris_rotate_ccw", KEY_J)

	_add_action_if_missing("tetris_hold")
	_create_input_event("tetris_hold", KEY_C)

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
			# Taps are handled by the menu scene itself (SprintMenu/MenuRoot)
			if event is InputEventKey and event.pressed and not event.echo:
				for i in range(SPRINT_TARGETS.size()):
					if event.keycode == KEY_1 + i:
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
	# Without IGNORE_SIZE the rect's minimum size is the texture's native
	# size (4K) — it can never shrink to the window, so the screen shows a
	# 1:1 top-left corner crop that never matches the baked board bg_tex.
	_bg_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
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

func _bake_board_bg() -> void:
	"""Bake a cover-fitted, heavily blurred copy of the background into an
	ImageTexture for the board glass shader. Sampled at SCREEN_UV, so it
	lines up 1:1 with the real background. No screen capture involved —
	works identically on every renderer."""
	if _board_material == null:
		return
	var vp_size := get_viewport_rect().size
	if vp_size.x < 1.0 or vp_size.y < 1.0:
		return

	var img: Image = null
	var tex := load("res://videos/azure-horizon.png") as Texture2D
	if tex:
		img = tex.get_image()
	if img != null and img.is_compressed():
		img.decompress()

	if img == null:
		# Fallback: same gradient as background.gdshader
		img = Image.create(8, 64, false, Image.FORMAT_RGB8)
		for y in range(64):
			var t := float(y) / 63.0
			var col := Color(0.08, 0.08, 0.12).lerp(Color(0.12, 0.12, 0.18), t)
			for x in range(8):
				img.set_pixel(x, y, col)
	else:
		# Cover-fit crop to screen aspect (matches STRETCH_KEEP_ASPECT_COVERED)
		var iw := img.get_width()
		var ih := img.get_height()
		var screen_aspect := vp_size.x / vp_size.y
		var img_aspect := float(iw) / float(ih)
		var crop_w := iw
		var crop_h := ih
		if img_aspect > screen_aspect:
			crop_w = int(round(ih * screen_aspect))
		else:
			crop_h = int(round(iw / screen_aspect))
		crop_w = clampi(crop_w, 1, iw)
		crop_h = clampi(crop_h, 1, ih)
		var ox := int((iw - crop_w) / 2.0)
		var oy := int((ih - crop_h) / 2.0)
		img = img.get_region(Rect2i(ox, oy, crop_w, crop_h))

	# Bake SHARP at ~1/3 screen res WITH mipmaps. The shader picks blur
	# per-pixel via textureLod: lod 0 (sharp) on the refracting rim so the
	# bent content is recognizable, high lod (frosted) in the interior.
	var base_h := clampi(int(vp_size.y / 1.5), 64, 1440)
	var base_w := maxi(2, int(round(base_h * vp_size.x / vp_size.y)))
	img.resize(base_w, base_h, Image.INTERPOLATE_LANCZOS)
	# HDR 2D renders in linear space. Imported textures get sRGB->linear
	# automatically, but runtime ImageTextures do NOT — without this the
	# board shows a double-gamma washed-out (white) background.
	img.srgb_to_linear()
	img.generate_mipmaps()

	_board_material.set_shader_parameter("bg_tex", ImageTexture.create_from_image(img))
	_bg_bake_size = vp_size

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

func _make_piece_cell(color: Color, alpha: float, glow: float, size: float = -1.0, emission: float = 0.0) -> ColorRect:
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
	mat.set_shader_parameter("emission", emission)
	cr.material = mat
	return cr

func _create_board_node() -> void:
	var shader_res := load("res://shaders/board.gdshader") as Shader
	if shader_res == null:
		push_error("Failed to load board shader")
		return

	_board_material = ShaderMaterial.new()
	_board_material.shader = shader_res

	# Create game layer first (everything goes here)
	_game_layer = CanvasLayer.new()
	_game_layer.name = "GameLayer"
	_game_layer.layer = 1
	add_child(_game_layer)

	# ── Pre-blurred background for the glass (baked on CPU, renderer-proof) ──
	_bake_board_bg()

	# Glass uniforms — same pipeline as the liquid glass buttons, but the
	# lens must scale with the surface: warp_offset is in SCREEN UV, so the
	# board (6x a button) needs ~6x the displacement and a fatter falloff
	# band or the refraction is proportionally invisible. Verified by A/B
	# pixel diff at these values (~11% of frame pixels move).
	_board_material.set_shader_parameter("blur_amount", 3.5)
	_board_material.set_shader_parameter("warp_intensity", 1.2)
	_board_material.set_shader_parameter("warp_strength", 4.0)
	_board_material.set_shader_parameter("wall_warp_intensity", 0.3)
	_board_material.set_shader_parameter("chromatic_strength", 3.0)
	_board_material.set_shader_parameter("border_width", 1.5)
	_board_material.set_shader_parameter("border_color", Color(1.0, 1.0, 1.0, 0.45))
	_board_material.set_shader_parameter("rim_intensity", 0.5)
	_board_material.set_shader_parameter("sheen_intensity", 0.10)
	_board_material.set_shader_parameter("sheen_falloff", 0.4)
	_board_material.set_shader_parameter("glass_tint", Color(0.06, 0.08, 0.14, 0.15))
	_board_material.set_shader_parameter("wave_strength", 0.3)
	_board_material.set_shader_parameter("wave_speed", 1.0)
	_board_material.set_shader_parameter("wave_scale", 1.0)
	_board_material.set_shader_parameter("block_emission", 1.2)

	# Colors from Constants.COLORS
	var c := Constants.COLORS
	_board_material.set_shader_parameter("color_1", c[Constants.PieceType.I])
	_board_material.set_shader_parameter("color_2", c[Constants.PieceType.O])
	_board_material.set_shader_parameter("color_3", c[Constants.PieceType.T])
	_board_material.set_shader_parameter("color_4", c[Constants.PieceType.S])
	_board_material.set_shader_parameter("color_5", c[Constants.PieceType.Z])
	_board_material.set_shader_parameter("color_6", c[Constants.PieceType.J])
	_board_material.set_shader_parameter("color_7", c[Constants.PieceType.L])
	_board_material.set_shader_parameter("flash_rows", Vector4(-1.0, -1.0, -1.0, -1.0))
	_board_material.set_shader_parameter("splash_strength", 0.7)
	_board_material.set_shader_parameter("splash_speed_px", 240.0)
	_board_material.set_shader_parameter("hole_tilt", 0.35)
	_push_splash_uniform()

	# Data texture (10x22, FORMAT_RGF: R = piece type, G = same-piece
	# connectivity mask for merged glass tiles)
	_board_image = Image.create(BOARD_TEX_W, BOARD_TEX_H, false, Image.FORMAT_RGF)
	_board_image.fill(Color(0, 0, 0, 1))  # all empty
	_board_texture = ImageTexture.create_from_image(_board_image)
	_board_material.set_shader_parameter("board_tex", _board_texture)

	_board_rect = ColorRect.new()
	_board_rect.name = "BoardRect"
	_board_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board_rect.material = _board_material
	_game_layer.add_child(_board_rect)

func _create_piece_cells() -> void:
	_piece_container = Node2D.new()
	_piece_container.name = "PieceContainer"
	_game_layer.add_child(_piece_container)

	for i in range(4):
		var cr := _make_piece_cell(Color.WHITE, 1.0, 0.4, -1.0, 1.2)
		_piece_container.add_child(cr)
		_piece_cells.append(cr)
		_piece_materials.append(cr.material as ShaderMaterial)

func _create_ghost_cells() -> void:
	_ghost_container = Node2D.new()
	_ghost_container.name = "GhostContainer"
	_game_layer.add_child(_ghost_container)

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
	_game_layer.add_child(_score_label)

	_lines_label = Label.new()
	_lines_label.name = "LinesLabel"
	_lines_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lines_label.add_theme_color_override("font_color", Color.WHITE)
	_game_layer.add_child(_lines_label)

	_level_label = Label.new()
	_level_label.name = "LevelLabel"
	_level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_level_label.add_theme_color_override("font_color", Color.WHITE)
	_game_layer.add_child(_level_label)

	_time_label = Label.new()
	_time_label.name = "TimeLabel"
	_time_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_time_label.add_theme_color_override("font_color", Color.WHITE)
	_game_layer.add_child(_time_label)

	_hold_title_label = Label.new()
	_hold_title_label.name = "HoldTitleLabel"
	_hold_title_label.text = "Hold"
	_hold_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hold_title_label.add_theme_color_override("font_color", Color.WHITE)
	_game_layer.add_child(_hold_title_label)

	_next_title_label = Label.new()
	_next_title_label.name = "NextTitleLabel"
	_next_title_label.text = "Next:"
	_next_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_next_title_label.add_theme_color_override("font_color", Color.WHITE)
	_game_layer.add_child(_next_title_label)

func _create_hold_preview() -> void:
	_hold_container = Node2D.new()
	_hold_container.name = "HoldPreview"
	_game_layer.add_child(_hold_container)
	for i in range(4):
		var cr := _make_piece_cell(Color.GRAY, 1.0, 0.2, 0, 0.1)
		_hold_container.add_child(cr)
		_hold_cells.append(cr)
		_hold_materials.append(cr.material as ShaderMaterial)

func _create_next_preview() -> void:
	_next_container = Node2D.new()
	_next_container.name = "NextPreview"
	_game_layer.add_child(_next_container)
	for i in range(3):
		var sub := Node2D.new()
		sub.name = "NextPiece%d" % i
		_next_container.add_child(sub)
		_next_sub_containers.append(sub)
		var cells: Array[ColorRect] = []
		var mats: Array[ShaderMaterial] = []
		for j in range(4):
			var cr := _make_piece_cell(Color.GRAY, 1.0, 0.2, 0, 0.1)
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
	var style: int = _game_settings.block_style if _game_settings else 1
	for r in range(Constants.ROWS):
		for c in range(Constants.COLS):
			var val: float = float(board.get_cell(c, r))
			var mask: float = float(board.get_conn_mask(c, r, style))
			_board_image.set_pixel(c, r, Color(val, mask, 0, 1))
	_board_texture.update(_board_image)

func _set_game_nodes_visible(v: bool) -> void:
	"""Show/hide all game rendering nodes (board, pieces, HUD, previews)."""
	if _board_rect:
		_board_rect.visible = v
	if _piece_container:
		_piece_container.visible = v
	if _ghost_container:
		_ghost_container.visible = v
	if _score_label:
		_score_label.visible = v
		_lines_label.visible = v
		_level_label.visible = v
		_time_label.visible = v
		_hold_title_label.visible = v
		_next_title_label.visible = v
	if _hold_container:
		_hold_container.visible = v
	if _next_container:
		_next_container.visible = v
	if _bg_fallback_rect:
		_bg_fallback_rect.visible = v and not _bg_ok


func _update_piece_positions() -> void:
	"""Position active piece cells each frame."""
	if state != State.PLAYING or controller.is_locked:
		_piece_container.visible = false
		return

	var cs: int = _cell_size
	var bx: int = _board_x
	var by: int = _board_y
	var cells: Array[Vector2i] = controller.get_absolute_cells()
	var color: Color = Constants.COLORS.get(controller.piece_type, Color.GRAY) as Color

	_piece_container.visible = true
	var idx: int = 0
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
	"""Drive the glass hole cutout at the ghost (drop preview) position.
	The old translucent cells are replaced by a piece-shaped hole in the
	liquid glass — fully see-through, lens rim wrapping around it."""
	_ghost_container.visible = false
	if _board_material == null:
		return
	if state != State.PLAYING or controller.is_locked:
		_board_material.set_shader_parameter("ghost_active", 0.0)
		return

	var cs: int = _cell_size
	var ghost_y: int = controller.get_ghost_y()
	var ghost_pos := Vector2i(controller.position.x, ghost_y)
	var cells: Array[Vector2i] = controller.get_cells_at(ghost_pos, controller.rotation)
	if cells.size() < 4:
		_board_material.set_shader_parameter("ghost_active", 0.0)
		return

	var board_size := Vector2(Constants.COLS, Constants.VISIBLE_ROWS) * float(cs)
	var p: Array = []
	for cell in cells:
		var c := Vector2(cell.x + 0.5, cell.y - 2.0 + 0.5) * float(cs)
		p.append(c - board_size * 0.5)
	var rounding: float = cs * 0.12
	var pcolor: Color = Constants.COLORS.get(controller.piece_type, Color.GRAY) as Color
	_board_material.set_shader_parameter("ghost_color", Color(pcolor.r, pcolor.g, pcolor.b, 0.38))
	_board_material.set_shader_parameter("ghost_rim_px", cs * 0.1)
	_board_material.set_shader_parameter("ghost_active", 1.0)
	_board_material.set_shader_parameter("ghost_half", cs * 0.5 - rounding)
	_board_material.set_shader_parameter("ghost_round", rounding)
	_board_material.set_shader_parameter("ghost_cells_a", Vector4(p[0].x, p[0].y, p[1].x, p[1].y))
	_board_material.set_shader_parameter("ghost_cells_b", Vector4(p[2].x, p[2].y, p[3].x, p[3].y))

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
	var offsets: Array = piece_data.CELLS[_held_piece_type][0]
	var color: Color = Constants.COLORS.get(_held_piece_type, Color.GRAY) as Color

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
	var next_pieces: Array[int] = bag.peek_next(3)

	for i in range(3):
		_next_sub_containers[i].visible = true
		var p_type: int = next_pieces[i]
		var color: Color = Constants.COLORS.get(p_type, Color.GRAY) as Color
		var offsets: Array = piece_data.CELLS[p_type][0]
		for j in range(4):
			if j >= _next_cells[i].size():
				break
			var off: Vector2i = offsets[j]
			_next_cells[i][j].position = Vector2(off.x * preview_cs, off.y * preview_cs)
			_next_cells[i][j].size = Vector2(preview_cs, preview_cs)
			_next_materials[i][j].set_shader_parameter("fill_color", color)
			_next_materials[i][j].set_shader_parameter("alpha", 1.0)
			_next_cells[i][j].visible = true

func _spawn_splash(cell_centers: PackedVector2Array, amp: float = 1.0) -> void:
	"""Start a piece-shaped splash ripple. cell_centers are the 4 cell
	centers in board-local pixels (origin at board center)."""
	_splashes.append({
		"cells": cell_centers,
		"age": 0.0,
		"amp": amp,
		"half": _cell_size * 0.5,
	})
	while _splashes.size() > SPLASH_MAX:
		_splashes.pop_front()

func _update_splashes(delta: float) -> void:
	"""Age active splashes and push them to the board shader. Called
	every frame; cheap no-op when no splashes are live."""
	if _board_material == null:
		return
	if _splashes.is_empty():
		if not _splashes_clean:
			_push_splash_uniform()
			_splashes_clean = true
		return
	_splashes_clean = false
	for i in range(_splashes.size() - 1, -1, -1):
		_splashes[i]["age"] += delta
		if _splashes[i]["age"] > SPLASH_LIFE:
			_splashes.remove_at(i)
	_push_splash_uniform()

func _push_splash_uniform() -> void:
	var meta := PackedVector4Array()
	var cells_a := PackedVector4Array()
	var cells_b := PackedVector4Array()
	meta.resize(SPLASH_MAX)
	cells_a.resize(SPLASH_MAX)
	cells_b.resize(SPLASH_MAX)
	for i in range(SPLASH_MAX):
		if i < _splashes.size():
			var s: Dictionary = _splashes[i]
			var c: PackedVector2Array = s["cells"]
			meta[i] = Vector4(s["age"], s["amp"], s["half"], 0.0)
			cells_a[i] = Vector4(c[0].x, c[0].y, c[1].x, c[1].y)
			cells_b[i] = Vector4(c[2].x, c[2].y, c[3].x, c[3].y)
		else:
			meta[i] = Vector4(-1.0, 0.0, 0.0, 0.0)
			cells_a[i] = Vector4.ZERO
			cells_b[i] = Vector4.ZERO
	_board_material.set_shader_parameter("splash_meta", meta)
	_board_material.set_shader_parameter("splash_cells_a", cells_a)
	_board_material.set_shader_parameter("splash_cells_b", cells_b)

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

	# HUD labels (right side); clamp so they never run off narrow screens —
	# on portrait they overlay the glass board's right edge instead
	var vw: float = get_viewport_rect().size.x
	var hud_w: float = maxf(cs * 2.5, 120.0 * _font_scale)
	var right_x: float = minf(bx + board_w + margin, vw - hud_w - margin)
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

	# Board shader geometry + re-bake blurred bg if the screen size changed
	if _board_material:
		_board_material.set_shader_parameter("rect_size", Vector2(board_w, board_h))
		_board_material.set_shader_parameter("corner_radius_px", cs * 0.8)
		_board_material.set_shader_parameter("hole_bevel_px", cs * 0.9)
		if _bg_bake_size != get_viewport_rect().size:
			_bake_board_bg()

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
			_set_game_nodes_visible(false)
		State.PLAYING:
			_set_game_nodes_visible(true)
			_process_playing(delta)
		State.LINE_CLEAR:
			_set_game_nodes_visible(true)
			_process_line_clear(delta)
		State.GAME_OVER:
			_set_game_nodes_visible(true)
			_process_game_over(delta)
		State.SPRINT_COMPLETE:
			_set_game_nodes_visible(false)

	# ── Shader-based rendering updates (every frame) ──
	_update_splashes(delta)
	if state != State.SPRINT_MENU and state != State.SPRINT_COMPLETE:
		_update_piece_positions()
		_update_ghost_positions()
		_update_hud()

	# Overlays (game over, sprint complete) still use _draw()
	if state == State.GAME_OVER or state == State.SPRINT_COMPLETE:
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
	_lock_piece(1.4)  # bigger splash — the piece hit the water hard

func _reset_lock_if_on_ground() -> void:
	if controller.is_on_ground() and controller.lock_resets < Constants.MAX_LOCK_RESETS:
		controller.lock_timer = 0.0
		controller.lock_resets += 1

func _lock_piece(splash_amp: float = 1.0) -> void:
	controller.is_locked = true
	var cells = controller.get_absolute_cells()

	# Piece-shaped splash where the piece landed
	var board_size := Vector2(Constants.COLS, Constants.VISIBLE_ROWS) * float(_cell_size)
	var centers := PackedVector2Array()
	for cell in cells:
		var c := Vector2(cell.x + 0.5, cell.y - 2.0 + 0.5) * float(_cell_size)
		centers.append(c - board_size * 0.5)
	if centers.size() == 4:
		_spawn_splash(centers, splash_amp)

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

	# Line clear
	cleared_row_indices = board.clear_lines()
	if cleared_row_indices.size() > 0:
		if LINE_CLEAR_ANIMATION:
			line_clear_timer = 0.4
			state = State.LINE_CLEAR
			return  # _process_line_clear handles scoring + spawn
		else:
			# Instant — no animation
			_score_lines(cleared_row_indices.size(), false)
			_update_board_texture()

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
	_show_menu()

func _show_menu() -> void:
	"""Return to (or start at) the sprint menu."""
	sprint_target = 0
	sprint_time = 0.0
	state = State.SPRINT_MENU
	_sprint_menu.update_records(sprint_records)
	_sprint_menu.get_parent().visible = true
	if _mobile_controls:
		_mobile_controls.set_menu_mode(true)
	queue_redraw()  # clear any game-over / complete overlay drawing

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
	_sprint_menu.get_parent().visible = false
	if _mobile_controls:
		_mobile_controls.set_menu_mode(false)
	_restart_game_only()
	_position_all_nodes()  # sprint HUD adds the Time row — shift Next below it

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

	# Sprint menu is its own scene (SprintMenu/MenuRoot) — nothing to draw
	if state == State.SPRINT_MENU:
		return

	var board_width: int = Constants.COLS * cs
	var board_height: int = Constants.VISIBLE_ROWS * cs
	var board_center_x: float = bx + board_width / 2.0
	var board_center_y: float = by + board_height / 2.0
	var font = ThemeDB.fallback_font

	# Game over overlay
	if state == State.GAME_OVER:
		draw_rect(Rect2(bx - 2, by - 2, board_width + 4, board_height + 4), Color.RED, false, 3.0)
		_draw_text_centered(font, board_center_x, board_center_y - font_l - 4,
			"GAME OVER", font_l, Color.RED)
		_draw_text_centered(font, board_center_x, board_center_y + 8,
			"Tap ⬇ or R for Menu", font_m, Color(1.0, 1.0, 1.0, 0.7))
		if sprint_target > 0:
			_draw_text_centered(font, board_center_x, board_center_y + 8 + font_m + 6,
				"Cleared %d/%d lines in %s" % [lines_cleared, sprint_target, _format_time(sprint_time)],
				font_s, Color(1.0, 1.0, 1.0, 0.5))
		return

	# Sprint complete overlay
	if state == State.SPRINT_COMPLETE:
		_draw_sprint_complete(font, font_s, font_m, font_l, board_center_x, board_center_y, board_width)
		return

func _draw_text_centered(font: Font, cx: float, baseline_y: float, text: String,
		fs: int, color: Color) -> void:
	# draw_string ignores HORIZONTAL_ALIGNMENT_CENTER when width is -1,
	# so center manually from the measured string width.
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, Vector2(cx - w / 2.0, baseline_y), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)

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
	var title_size := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_l)
	_draw_text_centered(font, board_center_x, board_center_y - title_size.y - 8,
		title, font_l, Color(0.3, 1.0, 0.4))

	# Time
	_draw_text_centered(font, board_center_x, board_center_y + 4,
		"Time:  %s" % _format_time(sprint_time), font_l, Color.WHITE)

	# Best / New record
	var best_y := board_center_y + font_l + 12
	if _sprint_new_record:
		_draw_text_centered(font, board_center_x, best_y,
			"NEW RECORD!", font_m, Color(1.0, 1.0, 0.3))
	else:
		var best_t: float = sprint_records.get(sprint_target, sprint_time)
		_draw_text_centered(font, board_center_x, best_y,
			"Best:  %s" % _format_time(best_t), font_m, Color(1.0, 1.0, 1.0, 0.7))

	# Continue hint
	var hint_y := board_center_y + font_l + 12 + font_m + 16
	_draw_text_centered(font, board_center_x, hint_y,
		"Tap or press any key to continue", font_s, Color(1.0, 1.0, 1.0, 0.5))
