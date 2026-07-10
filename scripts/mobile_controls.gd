# mobile_controls.gd — On-screen touch buttons with settings & edit mode.
# Attached to a full-screen Control inside a CanvasLayer.
# Buttons use a Panel (shadow via StyleBoxFlat) + ColorRect (body via ShaderMaterial)
# + Label children. Shader is liquid_glass.gdshader — iOS 26 Liquid Glass style with
# screen-space blur, chromatic aberration, rim light, and specular sheen.
# Theme presets defined in scripts/theme.gd (ThemeData class).
# Touch dispatch via parent _gui_input; child nodes have MOUSE_FILTER_IGNORE.
# Settings UI is a separate scene (scenes/mobile_settings.tscn) instantiated
# on gear tap; it communicates back via signals.

extends Control

# Forwarded from the settings panel so main.gd can reset the HUD panel layout.
signal hud_reset_requested


# ── Layout constants ──
const ROWS: int = 2
const COLS: int = 4
const GAP: float = 10.0
const BOTTOM_MARGIN: float = 20.0
const PANEL_PADDING: float = 14.0
const BTN_ASPECT_DEFAULT: float = 0.65
const BTN_CORNER_RADIUS_FRAC: float = 0.28
const PANEL_CORNER_RADIUS: int = 8

const GEAR_SIZE: float = 44.0
const BTN_SIZE_MIN: float = 0.5
const BTN_SIZE_MAX: float = 2.0
const BTN_SIZE_STEP: float = 0.1

const HAPTIC_DURATION_MS: float = 12.0
const SHADER_PATH: String = "res://shaders/liquid_glass.gdshader"
const SETTINGS_SCENE_PATH: String = "res://scenes/mobile_settings.tscn"
const DEFAULT_THEME: String = "ios_liquid_glass"

enum Mode { NORMAL, EDIT }

const DEFAULT_BUTTONS: Array = [
	["◀",  "tetris_move_left",   Color(0.22, 0.27, 0.50, 1.0)],
	["▶",  "tetris_move_right",  Color(0.22, 0.27, 0.50, 1.0)],
	["↻",  "tetris_rotate_cw",    Color(0.22, 0.48, 0.28, 1.0)],
	["▼",  "tetris_soft_drop",    Color(0.50, 0.27, 0.22, 1.0)],
	["⬇",  "tetris_hard_drop",    Color(0.60, 0.15, 0.18, 1.0)],
	["↺",  "tetris_rotate_ccw",   Color(0.22, 0.48, 0.28, 1.0)],
	["H",  "tetris_hold",         Color(0.40, 0.35, 0.20, 1.0)],
	["R",  "tetris_restart",      Color(0.50, 0.22, 0.22, 1.0)],
]


# ── Per-button state ──
var _btn_rects: Array[Rect2] = []
var _btn_actions: Array[String] = []
var _btn_labels: Array[String] = []
var _btn_colors: Array[Color] = []
var _btn_pressed: Array[bool] = []
var _config_loaded: bool = false

# ── Mode state ──
var _mode: int = Mode.NORMAL
var _panel_rect: Rect2

# ── Gear ──
var _gear_rect: Rect2

# ── Hide-buttons setting (persisted; gear stays visible to re-enable) ──
var _buttons_hidden: bool = false

# ── Menu mode: game screens hide the buttons too (set by main.gd) ──
var _menu_mode: bool = false

# ── Edit mode ──
var _done_rect: Rect2
var _edit_reset_rect: Rect2
var _dragging: int = -1
var _drag_offset: Vector2
var _font_size: int = 28
var _btn_size_mult: float = 1.0
var _btn_aspect: float = BTN_ASPECT_DEFAULT

# ── Touch tracking ──
var _touch_map: Dictionary = {}

# ── Waterdrop wobble spring state (per button) ──
const WOBBLE_STIFFNESS: float = 120.0
const WOBBLE_DAMPING: float = 16.0
var _wobble_value: Array[float] = []
var _wobble_velocity: Array[float] = []
var _wobble_target: Array[float] = []
var _wobble_touch_uv: Array[Vector2] = []
var _wobble_event_time: Array[float] = []
var _elapsed: float = 0.0

# ── Theme ──
var _active_theme_name: String = DEFAULT_THEME
var _active_theme: Dictionary = {}  # populated in _ready()


# ═══════════════════════════════════════════════════════════
# Child node references
# ═══════════════════════════════════════════════════════════

var _panel_bg: Panel = null

# Each game button: Panel (shadow) → ColorRect (shader body) → Label (text) + Label (sub)
var _btn_panels: Array[Panel] = []         # shadow containers
var _btn_bodies: Array[ColorRect] = []     # shader body (child of panel)
var _btn_shaders: Array[ShaderMaterial] = []  # per-button shader instances
var _btn_lbls: Array[Label] = []           # main label (child of panel)
var _btn_subs: Array[Label] = []           # sub label for edit mode (child of panel)

# Gear
var _gear_node: Panel = null
var _gear_label: Label = null

# Settings UI (separate scene, lazily instantiated on the CanvasLayer)
var _settings_ui = null

# Edit toolbar
var _edit_root: Control = null
var _edit_hint_label: Label = null


# ═══════════════════════════════════════════════════════════
# Style helpers
# ═══════════════════════════════════════════════════════════

func _make_shadow_style(corner_r: int = 14) -> StyleBoxFlat:
	"""Create a transparent-fill StyleBoxFlat that only casts a drop shadow."""
	var s := StyleBoxFlat.new()
	s.corner_radius_top_left = corner_r
	s.corner_radius_top_right = corner_r
	s.corner_radius_bottom_left = corner_r
	s.corner_radius_bottom_right = corner_r
	s.bg_color = Color.TRANSPARENT
	s.shadow_size = 6
	s.shadow_offset = Vector2(0, 4)
	s.shadow_color = Color(0.0, 0.0, 0.0, 0.5)
	s.anti_aliasing = true
	return s


func _make_solid_style(bg: Color, corner_r: int, border: Color = Color(1,1,1,0.25)) -> StyleBoxFlat:
	"""Create an opaque StyleBoxFlat (for non-shader buttons: gear, settings, edit toolbar)."""
	var s := StyleBoxFlat.new()
	s.corner_radius_top_left = corner_r
	s.corner_radius_top_right = corner_r
	s.corner_radius_bottom_left = corner_r
	s.corner_radius_bottom_right = corner_r
	s.bg_color = bg
	s.shadow_size = 4
	s.shadow_offset = Vector2(0, 2)
	s.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.border_color = border
	s.anti_aliasing = true
	return s


func _make_panel(rect: Rect2, style: StyleBoxFlat, parent: Node) -> Panel:
	var p := Panel.new()
	p.position = rect.position
	p.size = rect.size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", style)
	parent.add_child(p)
	return p


func _make_label(text: String, rect: Rect2, fs: int, color: Color, parent: Node) -> Label:
	var lbl := Label.new()
	lbl.position = rect.position
	lbl.size = rect.size
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", fs)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)
	return lbl


# ═══════════════════════════════════════════════════════════
# Lifecycle
# ═══════════════════════════════════════════════════════════

func _ready() -> void:
	for def in DEFAULT_BUTTONS:
		_btn_labels.append(def[0])
		_btn_actions.append(def[1])
		_btn_colors.append(def[2])

	mouse_filter = Control.MOUSE_FILTER_STOP

	# Load theme
	_active_theme = ThemeData.get_theme(_active_theme_name)

	if size.x <= 0 or size.y <= 0:
		var vp_rect := get_viewport_rect()
		if vp_rect.size.x > 0:
			position = Vector2.ZERO
			size = vp_rect.size

	_create_panel_bg()
	_create_game_buttons()
	_create_gear()
	_create_edit_toolbar()

	_load_visibility()
	if not _load_config():
		_layout_default()

	_apply_mode()
	resized.connect(_on_resized)


func _on_resized() -> void:
	if _config_loaded:
		_apply_mode()
		return
	if _mode == Mode.NORMAL or _mode == Mode.EDIT:
		_layout_default()
	else:
		_apply_mode()


# ═══════════════════════════════════════════════════════════
# Node creation (called once in _ready)
# ═══════════════════════════════════════════════════════════

func _create_panel_bg() -> void:
	_panel_bg = Panel.new()
	_panel_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel_bg.visible = false
	add_child(_panel_bg)


func _create_game_buttons() -> void:
	var shader_res := load(SHADER_PATH) as Shader
	if shader_res == null:
		push_error("Failed to load button shader: " + SHADER_PATH)

	for i in range(DEFAULT_BUTTONS.size()):
		# Shadow panel (container)
		var panel := Panel.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_theme_stylebox_override("panel", _make_shadow_style())
		add_child(panel)
		_btn_panels.append(panel)

		# Shader body — ColorRect fills the panel
		var body := ColorRect.new()
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(body)

		var mat := ShaderMaterial.new()
		if shader_res:
			mat.shader = shader_res.duplicate()  # each button gets its own shader instance
		# Theme + per-button uniforms are set in _position_button / _apply_mode
		mat.set_shader_parameter("pressed", 0.0)
		body.material = mat
		_btn_bodies.append(body)
		_btn_shaders.append(mat)

		# Main label
		var lbl := Label.new()
		lbl.text = _btn_labels[i]
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(lbl)
		_btn_lbls.append(lbl)

		# Sub label (edit mode only)
		var sub := Label.new()
		sub.text = _action_short_name(_btn_actions[i])
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sub.visible = false
		panel.add_child(sub)
		_btn_subs.append(sub)

		_btn_pressed.append(false)
		_wobble_value.append(0.0)
		_wobble_velocity.append(0.0)
		_wobble_target.append(0.0)
		_wobble_touch_uv.append(Vector2(-1.0, -1.0))
		_wobble_event_time.append(-10.0)

	_btn_rects.resize(DEFAULT_BUTTONS.size())


func _create_gear() -> void:
	_gear_node = Panel.new()
	_gear_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gear_node.add_theme_stylebox_override("panel", _make_solid_style(Color(0,0,0,0.5), 8))
	add_child(_gear_node)

	_gear_label = Label.new()
	_gear_label.text = "⚙"
	_gear_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gear_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_gear_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_gear_label)


func _create_edit_toolbar() -> void:
	_edit_root = Control.new()
	_edit_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edit_root.visible = false
	add_child(_edit_root)

	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.0, 0.0, 0.0, 0.7)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_bg.name = "ToolbarBg"
	_edit_root.add_child(bar_bg)

	# Done
	var d_btn: Panel
	d_btn = _make_panel(Rect2(), _make_solid_style(Color(0.22,0.55,0.30), 8), _edit_root)
	d_btn.name = "DoneBtn"
	_make_label("Done ✓", Rect2(), 17, Color.WHITE, _edit_root).name = "DoneLabel"

	# Reset
	var r_btn: Panel
	r_btn = _make_panel(Rect2(), _make_solid_style(Color(0.40,0.18,0.18), 8), _edit_root)
	r_btn.name = "ResetBtn"
	_make_label("Reset", Rect2(), 16, Color.WHITE, _edit_root).name = "ResetLabel"

	# Hint
	_edit_hint_label = Label.new()
	_edit_hint_label.text = "Drag buttons to reposition"
	_edit_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_edit_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_edit_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edit_hint_label.add_theme_color_override("font_color", Color(1,1,1,0.5))
	_edit_hint_label.add_theme_font_size_override("font_size", 14)
	_edit_root.add_child(_edit_hint_label)

	# Separator
	var sep := ColorRect.new()
	sep.color = Color(1,1,1,0.3)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sep.name = "Separator"
	_edit_root.add_child(sep)


# ═══════════════════════════════════════════════════════════
# Haptic feedback
# ═══════════════════════════════════════════════════════════

func _haptic_pulse() -> void:
	Input.vibrate_handheld(HAPTIC_DURATION_MS, 0.6)


# ═══════════════════════════════════════════════════════════
# Layout
# ═══════════════════════════════════════════════════════════

func _layout_default() -> void:
	if size.x <= 0 or size.y <= 0:
		return

	var layout := Constants.calculate_layout(size)
	var max_w: float = layout.button_max_w * _btn_size_mult
	var btn_w: float = minf((size.x - GAP * (COLS + 1)) / COLS, max_w)
	var btn_h: float = btn_w * _btn_aspect
	var total_w: float = btn_w * COLS + GAP * (COLS - 1)
	var total_h: float = btn_h * ROWS + GAP * (ROWS - 1)
	var start_x: float = (size.x - total_w) / 2.0
	var start_y: float = size.y - BOTTOM_MARGIN - total_h

	_panel_rect = Rect2(
		start_x - PANEL_PADDING, start_y - PANEL_PADDING,
		total_w + PANEL_PADDING * 2, total_h + PANEL_PADDING * 2
	)

	_font_size = maxi(14, int(btn_h * 0.4))

	# Position each button
	for i in range(DEFAULT_BUTTONS.size()):
		var col: int = i % COLS
		var row: int = i / COLS
		var rx: float = start_x + col * (btn_w + GAP)
		var ry: float = start_y + row * (btn_h + GAP)
		var rect := Rect2(rx, ry, btn_w, btn_h)
		_btn_rects[i] = rect
		_position_button(i, rect)

	# Panel bg (hidden but tracked for save/load)
	_panel_bg.position = _panel_rect.position
	_panel_bg.size = _panel_rect.size

	# Gear
	_gear_rect = Rect2(10, 10, GEAR_SIZE, GEAR_SIZE)
	_gear_node.position = _gear_rect.position
	_gear_node.size = _gear_rect.size
	_gear_label.position = _gear_rect.position
	_gear_label.size = _gear_rect.size
	_gear_label.add_theme_font_size_override("font_size", int(GEAR_SIZE * 0.55))
	_gear_label.add_theme_color_override("font_color", Color.WHITE)

	_apply_mode()


func _position_button(i: int, rect: Rect2) -> void:
	"""Position a button's panel + internal children to the given rect."""
	var panel := _btn_panels[i]
	panel.position = rect.position
	panel.size = rect.size

	# Body fills the panel
	_btn_bodies[i].position = Vector2.ZERO
	_btn_bodies[i].size = rect.size

	# Shape uniforms — corner radius proportional to smaller dimension (Apple-like)
	var min_dim := minf(rect.size.x, rect.size.y)
	var body_corner_px: float = BTN_CORNER_RADIUS_FRAC * min_dim
	_btn_shaders[i].set_shader_parameter("corner_radius", body_corner_px / maxf(rect.size.x, 1.0))
	_btn_shaders[i].set_shader_parameter("touch_uv", Vector2(-1.0, -1.0))
	_btn_shaders[i].set_shader_parameter("touch_depth", 0.0)
	# Shadow panel: smaller radius stays inside squircle body
	panel.add_theme_stylebox_override("panel", _make_shadow_style(int(body_corner_px * 0.7)))

	# Theme uniforms
	_apply_theme_to_button(i)

	# Per-button tint (theme's tint_alpha modulates the button's own color)
	var c := _btn_colors[i]
	var tint_alpha: float = _active_theme.get("tint_alpha", 0.55)
	_btn_shaders[i].set_shader_parameter("tint", Color(c.r, c.g, c.b, tint_alpha))

	# Main label fills the panel
	_btn_lbls[i].position = Vector2.ZERO
	_btn_lbls[i].size = rect.size
	_btn_lbls[i].add_theme_font_size_override("font_size", _font_size)
	_btn_lbls[i].add_theme_color_override("font_color", Color.WHITE)

	# Sub label at bottom
	var name_fs := maxi(10, int(rect.size.y * 0.2))
	var sub_h := name_fs + 4.0
	_btn_subs[i].position = Vector2(0, rect.size.y - sub_h - 2)
	_btn_subs[i].size = Vector2(rect.size.x, sub_h)
	_btn_subs[i].add_theme_font_size_override("font_size", name_fs)


func _apply_theme_to_button(i: int) -> void:
	"""Push all theme uniforms to a single button's shader."""
	if _active_theme.is_empty():
		return
	var mat := _btn_shaders[i]
	for key in _active_theme:
		if key == "label" or key == "tint_alpha":
			continue  # meta keys, not shader uniforms
		mat.set_shader_parameter(key, _active_theme[key])


func _apply_theme_to_all() -> void:
	"""Push theme uniforms to all button shaders (e.g. after theme swap)."""
	for i in range(_btn_shaders.size()):
		_apply_theme_to_button(i)
		# Update tint with per-button color
		var c := _btn_colors[i]
		var tint_alpha: float = _active_theme.get("tint_alpha", 0.55)
		_btn_shaders[i].set_shader_parameter("tint", Color(c.r, c.g, c.b, tint_alpha))


func apply_theme(theme_name: String) -> void:
	"""Swap the active theme at runtime. Call from settings or debug."""
	var t := ThemeData.get_theme(theme_name)
	if t.is_empty():
		push_warning("Theme not found: " + theme_name)
		return
	_active_theme_name = theme_name
	_active_theme = t
	_apply_theme_to_all()
	_apply_mode()


func _apply_mode() -> void:
	var in_normal := _mode == Mode.NORMAL
	var in_edit := _mode == Mode.EDIT

	# Edit mode always shows the buttons (even when hidden) so they stay editable
	var show_buttons := in_edit or (in_normal and not _buttons_hidden and not _menu_mode)
	for i in range(_btn_panels.size()):
		_btn_panels[i].visible = show_buttons
		_btn_lbls[i].visible = show_buttons
		_btn_lbls[i].modulate.a = 1.0
		_btn_subs[i].visible = in_edit

		# Shader uniforms per mode (base theme + mode overrides)
		var mat := _btn_shaders[i]
		var theme_border: Color = _active_theme.get("border_color", Color(1, 1, 1, 0.45))
		var theme_border_w: float = _active_theme.get("border_width", 1.5)
		var theme_glow: Color = _active_theme.get("glow_color", Color(1, 0.9, 0.5, 0.7))

		if in_edit:
			mat.set_shader_parameter("border_color", Color(1, 1, 1, 0.5))
			mat.set_shader_parameter("border_width", theme_border_w * 2.0)
			mat.set_shader_parameter("pressed", 0.0)
			mat.set_shader_parameter("glow_color", Color(1, 1, 1, 0.3))
		else:
			mat.set_shader_parameter("border_color", theme_border)
			mat.set_shader_parameter("border_width", theme_border_w)
			mat.set_shader_parameter("glow_color", theme_glow)
			mat.set_shader_parameter("pressed", 1.0 if _btn_pressed[i] else 0.0)

		var c := _btn_colors[i]
		var tint_alpha: float = _active_theme.get("tint_alpha", 0.55)
		mat.set_shader_parameter("tint", Color(c.r, c.g, c.b, tint_alpha))

	# Gear
	_gear_node.visible = in_normal
	_gear_label.visible = in_normal
	_gear_rect = Rect2(10, 10, GEAR_SIZE, GEAR_SIZE)
	_gear_node.position = _gear_rect.position
	_gear_node.size = _gear_rect.size
	_gear_label.position = _gear_rect.position
	_gear_label.size = _gear_rect.size
	_gear_label.add_theme_font_size_override("font_size", int(GEAR_SIZE * 0.55))
	_gear_label.add_theme_color_override("font_color", Color.WHITE)

	# Edit toolbar
	_edit_root.visible = in_edit
	if in_edit:
		_layout_edit_toolbar()


func _layout_edit_toolbar() -> void:
	var bar_h := 50.0

	var bar_bg: ColorRect = _edit_root.get_node("ToolbarBg")
	bar_bg.position = Vector2.ZERO
	bar_bg.size = Vector2(size.x, bar_h)

	var done_btn: Panel = _edit_root.get_node("DoneBtn")
	var done_lbl: Label = _edit_root.get_node("DoneLabel")
	var done_w := 110.0
	var done_h := 36.0
	_done_rect = Rect2(size.x - done_w - 12, (bar_h - done_h) / 2.0, done_w, done_h)
	done_btn.position = _done_rect.position
	done_btn.size = _done_rect.size
	done_lbl.position = _done_rect.position
	done_lbl.size = _done_rect.size
	done_lbl.add_theme_font_size_override("font_size", 17)
	done_lbl.add_theme_color_override("font_color", Color.WHITE)

	var reset_btn: Panel = _edit_root.get_node("ResetBtn")
	var reset_lbl: Label = _edit_root.get_node("ResetLabel")
	var reset_w := 80.0
	_edit_reset_rect = Rect2(_done_rect.position.x - reset_w - 10, (bar_h - done_h) / 2.0, reset_w, done_h)
	reset_btn.position = _edit_reset_rect.position
	reset_btn.size = _edit_reset_rect.size
	reset_lbl.position = _edit_reset_rect.position
	reset_lbl.size = _edit_reset_rect.size
	reset_lbl.add_theme_font_size_override("font_size", 16)
	reset_lbl.add_theme_color_override("font_color", Color.WHITE)

	var sep: ColorRect = _edit_root.get_node("Separator")
	sep.position = Vector2(0, bar_h)
	sep.size = Vector2(size.x, 2)

	_edit_hint_label.position = Vector2(0, bar_h + 8)
	_edit_hint_label.size = Vector2(size.x, 20)


# ═══════════════════════════════════════════════════════════
# Press state tracking
# ═══════════════════════════════════════════════════════════

func _process(_delta: float) -> void:
	_elapsed += _delta

	if _mode != Mode.NORMAL or _settings_open() or _buttons_hidden or _menu_mode:
		# Still decay wobble springs in settings/edit mode
		for i in range(_btn_panels.size()):
			_wobble_target[i] = 0.0  # release all wobbles
			var val = _wobble_value[i]
			if abs(val) < 0.002 and abs(_wobble_velocity[i]) < 0.01:
				_wobble_value[i] = 0.0
				_wobble_velocity[i] = 0.0
				_wobble_touch_uv[i] = Vector2(-1.0, -1.0)
				_btn_shaders[i].set_shader_parameter("touch_uv", Vector2(-1.0, -1.0))
				_btn_shaders[i].set_shader_parameter("touch_depth", 0.0)
				continue
			var force = WOBBLE_STIFFNESS * (_wobble_target[i] - val) - WOBBLE_DAMPING * _wobble_velocity[i]
			_wobble_velocity[i] += force * _delta
			_wobble_value[i] = clampf(val + _wobble_velocity[i] * _delta, -0.15, 1.15)
			_btn_shaders[i].set_shader_parameter("touch_depth", _wobble_value[i])
		return

	for i in range(_btn_panels.size()):
		# ── Static press (keyboard/gamepad) ──
		var pressed := Input.is_action_pressed(_btn_actions[i])
		if _btn_pressed[i] != pressed:
			_btn_pressed[i] = pressed
			_btn_shaders[i].set_shader_parameter("pressed", 1.0 if pressed else 0.0)
			# Trigger wobble on keyboard press too
			if pressed:
				_wobble_touch_uv[i] = Vector2(0.5, 0.5)  # center press
				_wobble_target[i] = 1.0
				_wobble_event_time[i] = _elapsed
			else:
				_wobble_target[i] = 0.0
				_wobble_event_time[i] = _elapsed

		# ── Update wobble spring ──
		var val = _wobble_value[i]
		var vel = _wobble_velocity[i]
		var target = _wobble_target[i]
		if abs(val - target) > 0.0005 or abs(vel) > 0.001:
			var force = WOBBLE_STIFFNESS * (target - val) - WOBBLE_DAMPING * vel
			vel += force * _delta
			val += vel * _delta
			val = clampf(val, -0.15, 1.15)
			_wobble_value[i] = val
			_wobble_velocity[i] = vel
		elif abs(val) < 0.002:
			# Snap to zero when fully released
			_wobble_value[i] = 0.0
			_wobble_velocity[i] = 0.0
			_wobble_touch_uv[i] = Vector2(-1.0, -1.0)
		# Always push current state to shader (drag updates need this even when settled)
		_btn_shaders[i].set_shader_parameter("touch_uv", _wobble_touch_uv[i])
		_btn_shaders[i].set_shader_parameter("touch_depth", _wobble_value[i])
		_btn_shaders[i].set_shader_parameter("touch_time", _wobble_event_time[i])


# ═══════════════════════════════════════════════════════════
# Touch dispatch
# ═══════════════════════════════════════════════════════════

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		match _mode:
			Mode.NORMAL:   _touch_normal(event.position, event.pressed, event.index)
			Mode.EDIT:     _touch_edit(event.position, event.pressed, event.index)
		accept_event()
	elif event is InputEventScreenDrag:
		if _mode == Mode.EDIT:
			_drag_edit(event.position, event.index)
			accept_event()
		elif _mode == Mode.NORMAL:
			_drag_normal(event.position, event.index)
			accept_event()


# ── NORMAL mode ──

func _touch_normal(pos: Vector2, pressed: bool, index: int) -> void:
	if pressed:
		if _gear_rect.has_point(pos):
			_haptic_pulse()
			_open_settings()
			return

		if _buttons_hidden or _menu_mode:
			return

		# Snap to the nearest button so taps in the gaps still register
		var i := _button_at(pos)
		if i >= 0:
			_press_touch_button(i, pos, index)
			return
	else:
		_release_normal_touch(index)


func _dist_to_rect_sq(p: Vector2, r: Rect2) -> float:
	"""Squared distance from p to rect r (0 if inside)."""
	var dx := maxf(maxf(r.position.x - p.x, 0.0), p.x - r.end.x)
	var dy := maxf(maxf(r.position.y - p.y, 0.0), p.y - r.end.y)
	return dx * dx + dy * dy


func _button_at(pos: Vector2) -> int:
	"""Button under a touch: exact hit if any, else the NEAREST button as long
	as the touch is within the button cluster (grown by ~half a button so
	slipping off the edge still counts). Kills the dead zones between buttons."""
	if _btn_rects.is_empty():
		return -1
	for i in range(_btn_rects.size()):
		if _btn_rects[i].has_point(pos):
			return i
	# Only snap within the cluster's bounding box + a half-button margin
	var bounds := _btn_rects[0]
	for i in range(1, _btn_rects.size()):
		bounds = bounds.merge(_btn_rects[i])
	var reach := maxf(_btn_rects[0].size.x, _btn_rects[0].size.y) * 0.5
	if not bounds.grow(reach).has_point(pos):
		return -1
	var best := -1
	var best_d := 1e20
	for i in range(_btn_rects.size()):
		var d := _dist_to_rect_sq(pos, _btn_rects[i])
		if d < best_d:
			best_d = d
			best = i
	return best


func _press_touch_button(i: int, pos: Vector2, index: int) -> void:
	_haptic_pulse()
	Input.action_press(_btn_actions[i])
	_touch_map[index] = i
	_btn_pressed[i] = true
	_btn_shaders[i].set_shader_parameter("pressed", 1.0)
	var r := _btn_rects[i]
	var uv := Vector2(clampf((pos.x - r.position.x) / r.size.x, 0.0, 1.0),
					  clampf((pos.y - r.position.y) / r.size.y, 0.0, 1.0))
	_wobble_touch_uv[i] = uv
	_wobble_target[i] = 1.0
	_wobble_event_time[i] = _elapsed


func _release_normal_touch(index: int) -> void:
	if index in _touch_map:
		var i: int = _touch_map[index]
		Input.action_release(_btn_actions[i])
		_touch_map.erase(index)
		_btn_pressed[i] = false
		_btn_shaders[i].set_shader_parameter("pressed", 0.0)
		# Trigger release ripple
		_wobble_target[i] = 0.0
		_wobble_event_time[i] = _elapsed


func _drag_normal(pos: Vector2, index: int) -> void:
	"""Slide handling with the same nearest-button snapping as a tap, so a
	finger crossing the gaps stays on the closest button (Voronoi)."""
	if not (index in _touch_map):
		return
	var ci: int = _touch_map[index]
	var target := _button_at(pos)

	# Still on the same (nearest) button — update wobble, re-press if decayed
	if target == ci:
		var r := _btn_rects[ci]
		_wobble_touch_uv[ci] = Vector2(clampf((pos.x - r.position.x) / r.size.x, 0.0, 1.0),
									   clampf((pos.y - r.position.y) / r.size.y, 0.0, 1.0))
		if _wobble_target[ci] < 0.5:
			_haptic_pulse()
			Input.action_press(_btn_actions[ci])
			_btn_pressed[ci] = true
			_btn_shaders[ci].set_shader_parameter("pressed", 1.0)
			_wobble_target[ci] = 1.0
			_wobble_event_time[ci] = _elapsed
		return

	# Finger left the current button — release it (keep touch_map for re-entry)
	if _wobble_target[ci] > 0.5:
		Input.action_release(_btn_actions[ci])
		_btn_pressed[ci] = false
		_btn_shaders[ci].set_shader_parameter("pressed", 0.0)
		_wobble_target[ci] = 0.0
		_wobble_event_time[ci] = _elapsed

	# Entered a different button — cross-fade to it
	if target >= 0:
		_press_touch_button(target, pos, index)
	# else finger is beyond the cluster — keep touch_map so re-entry works

func set_menu_mode(on: bool) -> void:
	"""Hide the game buttons on menu screens (gear stays). Called by main.gd."""
	_menu_mode = on
	_apply_mode()


func buttons_visible() -> bool:
	"""True when the game touch buttons are actually on screen (so main.gd
	only pays for the over-the-buttons board overlay when it's needed)."""
	return not _buttons_hidden and not _menu_mode


# ── SETTINGS (separate scene: scenes/mobile_settings.tscn) ──

# Public wrappers so main.gd can open/close settings (e.g. from Esc).
func open_settings() -> void:
	if _mode == Mode.NORMAL:
		_open_settings()

func close_settings() -> void:
	_close_settings()

func is_settings_open() -> bool:
	return _settings_open()


func _settings_open() -> bool:
	return _settings_ui != null and _settings_ui.visible


func _open_settings() -> void:
	if _settings_ui == null:
		var packed := load(SETTINGS_SCENE_PATH) as PackedScene
		if packed == null:
			push_error("Failed to load settings scene: " + SETTINGS_SCENE_PATH)
			return
		_settings_ui = packed.instantiate()
		_settings_ui.edit_layout_requested.connect(_on_settings_edit_layout)
		_settings_ui.reset_requested.connect(_on_settings_reset)
		_settings_ui.hud_reset_requested.connect(_on_settings_hud_reset)
		_settings_ui.size_stepped.connect(_on_settings_size_stepped)
		_settings_ui.aspect_stepped.connect(_on_settings_aspect_stepped)
		_settings_ui.buttons_visible_toggled.connect(_on_settings_buttons_toggled)
		_settings_ui.closed.connect(_close_settings)
		# Sibling on the CanvasLayer so it draws (and takes input) above the buttons
		get_parent().add_child(_settings_ui)
	_settings_ui.setup(_btn_size_mult, _btn_aspect, not _buttons_hidden)
	_settings_ui.visible = true


func _close_settings() -> void:
	if _settings_ui and _settings_ui.visible:
		_haptic_pulse()
		_settings_ui.visible = false


func _on_settings_edit_layout() -> void:
	_haptic_pulse()
	_settings_ui.visible = false
	_mode = Mode.EDIT
	# Editing over the sprint menu: block the menu's pre-GUI input
	add_to_group("menu_input_blockers")
	_apply_mode()


func _on_settings_reset() -> void:
	_haptic_pulse()
	_reset_to_defaults()
	_settings_ui.setup(_btn_size_mult, _btn_aspect, not _buttons_hidden)


func _on_settings_hud_reset() -> void:
	_haptic_pulse()
	hud_reset_requested.emit()


func _on_settings_size_stepped(direction: float) -> void:
	_haptic_pulse()
	_btn_size_mult = clampf(_btn_size_mult + direction * BTN_SIZE_STEP, BTN_SIZE_MIN, BTN_SIZE_MAX)
	_layout_default()
	_settings_ui.update_values(_btn_size_mult, _btn_aspect)


func _on_settings_aspect_stepped(direction: float) -> void:
	_haptic_pulse()
	_btn_aspect = clampf(_btn_aspect + direction * 0.05, 0.3, 1.2)
	_layout_default()
	_settings_ui.update_values(_btn_size_mult, _btn_aspect)


func _on_settings_buttons_toggled(buttons_visible: bool) -> void:
	_haptic_pulse()
	_buttons_hidden = not buttons_visible
	_save_visibility()
	_apply_mode()


# ── EDIT mode ──

func _touch_edit(pos: Vector2, pressed: bool, _index: int) -> void:
	if pressed:
		if _done_rect.has_point(pos):
			_haptic_pulse()
			_save_config()
			_mode = Mode.NORMAL
			_dragging = -1
			if is_in_group("menu_input_blockers"):
				remove_from_group("menu_input_blockers")
			_apply_mode()
			return

		if _edit_reset_rect.has_point(pos):
			_haptic_pulse()
			_reset_to_defaults()
			_dragging = -1
			_apply_mode()
			return

		for i in range(_btn_rects.size()):
			if _btn_rects[i].has_point(pos):
				_dragging = i
				_drag_offset = pos - _btn_rects[i].position
				# Yellow highlight on dragged button
				_btn_shaders[i].set_shader_parameter("border_color", Color(1, 1, 0, 0.9))
				_btn_shaders[i].set_shader_parameter("border_width", 0.05)
				_btn_shaders[i].set_shader_parameter("glow_color", Color(1, 1, 0, 0.6))
				_btn_shaders[i].set_shader_parameter("pressed", 0.3)
				return
	else:
		if _dragging >= 0:
			# Restore edit-mode shader params
			var i := _dragging
			_btn_shaders[i].set_shader_parameter("border_color", Color(1, 1, 1, 0.5))
			_btn_shaders[i].set_shader_parameter("border_width", 0.04)
			_btn_shaders[i].set_shader_parameter("glow_color", Color(1, 1, 1, 0.3))
			_btn_shaders[i].set_shader_parameter("pressed", 0.0)
			_recalc_panel()
			_dragging = -1


func _drag_edit(pos: Vector2, _index: int) -> void:
	if _dragging < 0:
		return
	var new_pos := pos - _drag_offset
	_btn_rects[_dragging].position = new_pos
	_btn_panels[_dragging].position = new_pos


func _recalc_panel() -> void:
	if _btn_rects.is_empty():
		return
	var min_x := _btn_rects[0].position.x
	var min_y := _btn_rects[0].position.y
	var max_x := _btn_rects[0].end.x
	var max_y := _btn_rects[0].end.y
	for r in _btn_rects:
		min_x = minf(min_x, r.position.x)
		min_y = minf(min_y, r.position.y)
		max_x = maxf(max_x, r.end.x)
		max_y = maxf(max_y, r.end.y)
	_panel_rect = Rect2(
		min_x - PANEL_PADDING, min_y - PANEL_PADDING,
		max_x - min_x + PANEL_PADDING * 2, max_y - min_y + PANEL_PADDING * 2
	)
	_panel_bg.position = _panel_rect.position
	_panel_bg.size = _panel_rect.size


# ═══════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════

func _action_short_name(action: String) -> String:
	match action:
		"tetris_move_left":   return "LEFT"
		"tetris_move_right":  return "RIGHT"
		"tetris_soft_drop":   return "DROP"
		"tetris_hard_drop":   return "HARD"
		"tetris_rotate_cw":   return "R-CW"
		"tetris_rotate_ccw":  return "R-CCW"
		"tetris_hold":        return "HOLD"
		"tetris_restart":     return "RESTART"
		_:                    return action


# ═══════════════════════════════════════════════════════════
# Save / Load
# ═══════════════════════════════════════════════════════════

const SAVE_PATH := "user://mobile_controls.cfg"


func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "buttons_visible", not _buttons_hidden)
	cfg.set_value("layout", "button_count", _btn_rects.size())
	cfg.set_value("layout", "panel_rect", var_to_str(_panel_rect))
	cfg.set_value("layout", "btn_size_mult", _btn_size_mult)
	cfg.set_value("layout", "btn_aspect", _btn_aspect)
	for i in range(_btn_rects.size()):
		var section := "button_%d" % i
		cfg.set_value(section, "action", _btn_actions[i])
		cfg.set_value(section, "label", _btn_labels[i])
		cfg.set_value(section, "color", var_to_str(_btn_colors[i]))
		cfg.set_value(section, "rect", var_to_str(_btn_rects[i]))
	cfg.save(SAVE_PATH)
	print("Mobile controls saved to ", SAVE_PATH)


func _load_visibility() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		_buttons_hidden = not cfg.get_value("settings", "buttons_visible", true)


func _save_visibility() -> void:
	# Persist immediately on toggle; keep any saved layout sections intact.
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("settings", "buttons_visible", not _buttons_hidden)
	cfg.save(SAVE_PATH)


func _load_config() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return false

	var count: int = cfg.get_value("layout", "button_count", 0)
	if count <= 0:
		return false

	_btn_rects.clear()
	_btn_actions.clear()
	_btn_labels.clear()
	_btn_colors.clear()

	for i in range(count):
		var section := "button_%d" % i
		_btn_actions.append(cfg.get_value(section, "action", ""))
		_btn_labels.append(cfg.get_value(section, "label", "?"))
		_btn_colors.append(str_to_var(cfg.get_value(section, "color", "")))
		_btn_rects.append(str_to_var(cfg.get_value(section, "rect", "")))

	_panel_rect = str_to_var(cfg.get_value("layout", "panel_rect", ""))
	_btn_size_mult = cfg.get_value("layout", "btn_size_mult", 1.0)
	_btn_aspect = cfg.get_value("layout", "btn_aspect", BTN_ASPECT_DEFAULT)

	if _btn_rects.size() != DEFAULT_BUTTONS.size():
		_reset_to_defaults()
		return false

	# Sync nodes from loaded data
	for i in range(_btn_rects.size()):
		_position_button(i, _btn_rects[i])
		_btn_lbls[i].text = _btn_labels[i]
		_font_size = maxi(10, int(_btn_rects[i].size.y * 0.4)) if i == 0 else _font_size

	_panel_bg.position = _panel_rect.position
	_panel_bg.size = _panel_rect.size
	_config_loaded = true

	_apply_mode()
	return true


func _reset_to_defaults() -> void:
	DirAccess.remove_absolute(SAVE_PATH)
	_btn_rects.clear()
	_btn_actions.clear()
	_btn_labels.clear()
	_btn_colors.clear()
	for def in DEFAULT_BUTTONS:
		_btn_labels.append(def[0])
		_btn_actions.append(def[1])
		_btn_colors.append(def[2])
	_btn_size_mult = 1.0
	_btn_aspect = BTN_ASPECT_DEFAULT
	_buttons_hidden = false
	_config_loaded = false

	# Reset shader fill colors and labels
	for i in range(_btn_labels.size()):
		_btn_lbls[i].text = _btn_labels[i]
		_btn_subs[i].text = _action_short_name(_btn_actions[i])

	# Re-apply theme
	_active_theme = ThemeData.get_theme(_active_theme_name)
	_layout_default()
