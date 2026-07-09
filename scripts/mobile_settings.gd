# mobile_settings.gd — Standalone settings UI for the mobile controls.
# Lives in its own scene (scenes/mobile_settings.tscn) and is instantiated by
# mobile_controls.gd when the gear is tapped. It knows nothing about the
# button overlay's internals — all communication goes through signals.
#
# Visuals use the same liquid glass construction as the game buttons:
# each Button gets empty styleboxes (shadow only) plus a ColorRect child
# running liquid_glass.gdshader and a Label on top.

extends Control

signal edit_layout_requested
signal reset_requested
signal size_stepped(direction: float)
signal aspect_stepped(direction: float)
signal buttons_visible_toggled(buttons_visible: bool)
signal closed

const SHADER_PATH := "res://shaders/liquid_glass.gdshader"
const THEME_NAME := "ios_liquid_glass"
const BTN_CORNER := 0.45

const TINT_NEUTRAL := Color(0.26, 0.30, 0.46)
const TINT_RESET := Color(0.50, 0.20, 0.22)
const TINT_ON := Color(0.20, 0.52, 0.30)
const TINT_OFF := Color(0.30, 0.32, 0.38)

var _shader: Shader = null
var _theme_data: Dictionary = {}
var _toggle_mat: ShaderMaterial = null
var _toggle_label: Label = null
var _block_style_label: Label = null


func _ready() -> void:
	# While visible, screens that read pre-GUI input (sprint menu) must ignore
	# taps — they'd steal presses meant for this panel's buttons.
	add_to_group("menu_input_blockers")

	_shader = load(SHADER_PATH) as Shader
	_theme_data = ThemeData.get_theme(THEME_NAME)

	# Panel: drop shadow from the stylebox, glass body as the bottom child
	%Panel.add_theme_stylebox_override("panel", _make_shadow_style(14))
	var panel_glass := _make_glass_rect(Color(0.13, 0.17, 0.30), 0.085, 0.35)
	%Panel.add_child(panel_glass)
	%Panel.move_child(panel_glass, 0)

	_glassify(%EditBtn, TINT_NEUTRAL)
	_glassify(%ResetBtn, TINT_RESET)
	_glassify(%SizeMinus, TINT_NEUTRAL)
	_glassify(%SizePlus, TINT_NEUTRAL)
	_glassify(%AspectMinus, TINT_NEUTRAL)
	_glassify(%AspectPlus, TINT_NEUTRAL)
	_glassify(%CloseBtn, TINT_NEUTRAL)
	var tg := _glassify(%ShowButtonsToggle, TINT_ON)
	_toggle_mat = tg["mat"]
	_toggle_label = tg["label"]
	var bs := _glassify(%BlockStyleBtn, TINT_NEUTRAL)
	_block_style_label = bs["label"]

	%EditBtn.pressed.connect(func(): edit_layout_requested.emit())
	%ResetBtn.pressed.connect(func(): reset_requested.emit())
	%SizeMinus.pressed.connect(func(): size_stepped.emit(-1.0))
	%SizePlus.pressed.connect(func(): size_stepped.emit(1.0))
	%AspectMinus.pressed.connect(func(): aspect_stepped.emit(-1.0))
	%AspectPlus.pressed.connect(func(): aspect_stepped.emit(1.0))
	%CloseBtn.pressed.connect(func(): closed.emit())
	%ShowButtonsToggle.toggled.connect(_on_toggle)
	%BlockStyleBtn.pressed.connect(_on_block_style)
	_sync_toggle(%ShowButtonsToggle.button_pressed)
	_refresh_block_style()


func _on_block_style() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if gs:
		gs.cycle_block_style()
	_refresh_block_style()


func _refresh_block_style() -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if gs and _block_style_label:
		_block_style_label.text = gs.block_style_name()


func setup(size_mult: float, aspect: float, buttons_visible: bool) -> void:
	"""Sync the whole panel to the controller's current state. Call before showing."""
	update_values(size_mult, aspect)
	%ShowButtonsToggle.set_pressed_no_signal(buttons_visible)
	_sync_toggle(buttons_visible)


func update_values(size_mult: float, aspect: float) -> void:
	%SizeLabel.text = "Button Size: %.0f%%" % (size_mult * 100.0)
	%AspectLabel.text = "Button Shape: %.0f%%" % (aspect * 100.0)


func _on_toggle(on: bool) -> void:
	_sync_toggle(on)
	buttons_visible_toggled.emit(on)


func _sync_toggle(on: bool) -> void:
	if _toggle_label:
		_toggle_label.text = "On" if on else "Off"
	if _toggle_mat:
		var c := TINT_ON if on else TINT_OFF
		_toggle_mat.set_shader_parameter("tint",
			Color(c.r, c.g, c.b, _theme_data.get("tint_alpha", 0.55)))


func _gui_input(event: InputEvent) -> void:
	# Panel children consume their own events, so a press reaching the root
	# means the tap landed outside the panel — dismiss.
	# ScreenTouch ONLY: every mouse click is duplicated as an emulated touch
	# (emulate_touch_from_mouse), and the gear click that opens this panel
	# delivers its mouse half here after the touch half opened it — reacting
	# to mouse presses would close the panel on the same click.
	if event is InputEventScreenTouch and event.pressed:
		accept_event()
		closed.emit()


# ── Glass construction ──

func _make_glass_rect(tint: Color, corner: float, tint_alpha: float = -1.0) -> ColorRect:
	"""Full-rect ColorRect running its own liquid_glass shader instance."""
	var body := ColorRect.new()
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	if _shader:
		mat.shader = _shader.duplicate()
	for key in _theme_data:
		if key == "label" or key == "tint_alpha":
			continue
		mat.set_shader_parameter(key, _theme_data[key])
	if tint_alpha < 0.0:
		tint_alpha = _theme_data.get("tint_alpha", 0.55)
	mat.set_shader_parameter("tint", Color(tint.r, tint.g, tint.b, tint_alpha))
	mat.set_shader_parameter("corner_radius", corner)
	mat.set_shader_parameter("pressed", 0.0)
	body.material = mat
	return body


func _glassify(btn: Button, tint: Color) -> Dictionary:
	"""Replace a Button's flat styleboxes with a glass body + label on top.
	The button keeps handling input/layout; visuals come from the shader."""
	var shadow := _make_shadow_style(12)
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(st, shadow)

	var body := _make_glass_rect(tint, BTN_CORNER)
	btn.add_child(body)

	var lbl := Label.new()
	lbl.text = btn.text
	btn.text = ""
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	btn.add_child(lbl)

	var mat: ShaderMaterial = body.material
	btn.button_down.connect(func():
		mat.set_shader_parameter("pressed", 1.0)
		mat.set_shader_parameter("touch_depth", 0.6)
		mat.set_shader_parameter("touch_uv", Vector2(0.5, 0.5))
		Input.vibrate_handheld(12, 0.6))
	btn.button_up.connect(func():
		mat.set_shader_parameter("pressed", 0.0)
		mat.set_shader_parameter("touch_depth", 0.0)
		mat.set_shader_parameter("touch_uv", Vector2(-1.0, -1.0)))

	return {"mat": mat, "label": lbl}


func _make_shadow_style(corner_r: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.corner_radius_top_left = corner_r
	s.corner_radius_top_right = corner_r
	s.corner_radius_bottom_left = corner_r
	s.corner_radius_bottom_right = corner_r
	s.bg_color = Color.TRANSPARENT
	s.shadow_size = 7
	s.shadow_offset = Vector2(0, 3)
	s.shadow_color = Color(0, 0, 0, 0.4)
	s.anti_aliasing = true
	return s
