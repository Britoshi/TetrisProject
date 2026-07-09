# sprint_menu.gd — Sprint target-select menu, built from the same liquid
# glass parts as the touch controls: Panel (drop shadow) → ColorRect
# (liquid_glass.gdshader body) → Labels. Lives on its own CanvasLayer
# (scenes/sprint_menu.tscn); main.gd shows/hides it and listens for
# target_selected to start a sprint.

extends Control

signal target_selected(target: int)

const SHADER_PATH := "res://shaders/liquid_glass.gdshader"
const THEME_NAME := "ios_liquid_glass"
const BTN_CORNER := 0.35

const BTN_TINTS: Array[Color] = [
	Color(0.22, 0.30, 0.55),
	Color(0.20, 0.45, 0.30),
	Color(0.45, 0.36, 0.18),
	Color(0.50, 0.22, 0.24),
]

var _targets: Array = []
var _records: Dictionary = {}

var _title: Label = null
var _subtitle: Label = null
var _hint: Label = null
var _btn_panels: Array[Panel] = []
var _btn_bodies: Array[ColorRect] = []
var _btn_shaders: Array[ShaderMaterial] = []
var _btn_labels: Array[Label] = []
var _btn_subs: Array[Label] = []
var _btn_rects: Array[Rect2] = []
var _theme_data: Dictionary = {}

var _pressed_idx: int = -1
var _press_touch: int = -1


func _ready() -> void:
	# Input arrives via _input() (like main.gd's menu handling did): the
	# touch-controls panel is a full-screen Control on a higher CanvasLayer
	# that consumes all GUI events, so _gui_input would never fire here.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_layout)


func setup(targets: Array, records: Dictionary) -> void:
	"""Build the menu for the given line targets. Call once from main.gd."""
	_targets = targets.duplicate()
	_records = records
	_theme_data = ThemeData.get_theme(THEME_NAME)
	_build()
	_refresh_records()
	_layout()


func update_records(records: Dictionary) -> void:
	"""Refresh the best-time lines (call when returning to the menu)."""
	_records = records
	_refresh_records()


# ── Node construction ──

func _build() -> void:
	_title = _make_label("SPRINT MODE", 44, Color.WHITE, self)
	_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_title.add_theme_constant_override("shadow_offset_x", 0)
	_title.add_theme_constant_override("shadow_offset_y", 3)

	_subtitle = _make_label("Select Target", 18, Color(1, 1, 1, 0.65), self)
	_hint = _make_label("Press 1–4 or tap a target", 13, Color(1, 1, 1, 0.4), self)

	var shader_res := load(SHADER_PATH) as Shader
	if shader_res == null:
		push_error("Failed to load button shader: " + SHADER_PATH)

	for i in range(_targets.size()):
		# Shadow panel (container)
		var panel := Panel.new()
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(panel)
		_btn_panels.append(panel)

		# Glass body
		var body := ColorRect.new()
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.add_child(body)
		_btn_bodies.append(body)

		var mat := ShaderMaterial.new()
		if shader_res:
			mat.shader = shader_res.duplicate()
		for key in _theme_data:
			if key == "label" or key == "tint_alpha":
				continue
			mat.set_shader_parameter(key, _theme_data[key])
		var c := BTN_TINTS[i % BTN_TINTS.size()]
		mat.set_shader_parameter("tint", Color(c.r, c.g, c.b, _theme_data.get("tint_alpha", 0.55)))
		mat.set_shader_parameter("pressed", 0.0)
		mat.set_shader_parameter("corner_radius", BTN_CORNER)
		body.material = mat
		_btn_shaders.append(mat)

		_btn_labels.append(_make_label("%d Lines" % _targets[i], 22, Color.WHITE, panel))
		_btn_subs.append(_make_label("", 13, Color(1, 1, 1, 0.6), panel))

	_btn_rects.resize(_targets.size())


func _make_label(text: String, fs: int, color: Color, parent: Node) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", fs)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)
	return lbl


func _make_shadow_style(corner_r: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.corner_radius_top_left = corner_r
	s.corner_radius_top_right = corner_r
	s.corner_radius_bottom_left = corner_r
	s.corner_radius_bottom_right = corner_r
	s.bg_color = Color.TRANSPARENT
	s.shadow_size = 8
	s.shadow_offset = Vector2(0, 4)
	s.shadow_color = Color(0, 0, 0, 0.45)
	s.anti_aliasing = true
	return s


func _refresh_records() -> void:
	for i in range(_targets.size()):
		var target: int = _targets[i]
		if _records.has(target):
			_btn_subs[i].text = "Best  %s" % _format_time(_records[target])
		else:
			_btn_subs[i].text = ""


# ── Layout ──

func _layout() -> void:
	if _btn_panels.is_empty() or size.x <= 0 or size.y <= 0:
		return

	var n := _btn_panels.size()
	var cx := size.x / 2.0
	var btn_w := minf(size.x * 0.62, 340.0)
	var btn_h := 64.0
	var gap := 16.0
	var title_fs := clampi(int(size.x * 0.055), 28, 46)
	var title_h := title_fs + 12.0
	var sub_h := 26.0
	var total_btn := n * btn_h + (n - 1) * gap
	var block_h := title_h + 4.0 + sub_h + 30.0 + total_btn + 28.0 + 18.0
	var top := maxf((size.y - block_h) / 2.0, size.y * 0.04)

	_title.add_theme_font_size_override("font_size", title_fs)
	_title.position = Vector2(0, top)
	_title.size = Vector2(size.x, title_h)

	_subtitle.position = Vector2(0, top + title_h + 4.0)
	_subtitle.size = Vector2(size.x, sub_h)

	var y := top + title_h + 4.0 + sub_h + 30.0
	for i in range(n):
		var rect := Rect2(cx - btn_w / 2.0, y, btn_w, btn_h)
		_btn_rects[i] = rect

		_btn_panels[i].position = rect.position
		_btn_panels[i].size = rect.size
		_btn_panels[i].add_theme_stylebox_override("panel",
			_make_shadow_style(int(btn_h * 0.24)))

		_btn_bodies[i].position = Vector2.ZERO
		_btn_bodies[i].size = rect.size

		# Main label sits slightly high; best-time line hugs the bottom
		_btn_labels[i].position = Vector2.ZERO
		_btn_labels[i].size = Vector2(btn_w, btn_h - 14.0)
		_btn_subs[i].position = Vector2(0, btn_h - 24.0)
		_btn_subs[i].size = Vector2(btn_w, 18.0)

		y += btn_h + gap

	_hint.position = Vector2(0, y + 10.0)
	_hint.size = Vector2(size.x, 18.0)


# ── Input (Node._input, pre-GUI — same path the old menu used) ──

func _input(event: InputEvent) -> void:
	if not get_parent().visible:
		return
	# A modal overlay (settings panel, layout edit mode) is on top — since
	# this menu reads pre-GUI input, it must stand down or it steals taps.
	for blocker in get_tree().get_nodes_in_group("menu_input_blockers"):
		if blocker.visible:
			return

	if event is InputEventScreenTouch:
		if event.pressed:
			for i in range(_btn_rects.size()):
				if _btn_rects[i].has_point(event.position):
					_pressed_idx = i
					_press_touch = event.index
					_set_pressed(i, true, event.position)
					get_viewport().set_input_as_handled()
					return
		elif _pressed_idx >= 0 and event.index == _press_touch:
			var i := _pressed_idx
			_set_pressed(i, false, event.position)
			_pressed_idx = -1
			_press_touch = -1
			if _btn_rects[i].has_point(event.position):
				get_viewport().set_input_as_handled()
				target_selected.emit(_targets[i])
	elif event is InputEventScreenDrag:
		# Sliding off the button cancels the press
		if _pressed_idx >= 0 and event.index == _press_touch \
				and not _btn_rects[_pressed_idx].has_point(event.position):
			_set_pressed(_pressed_idx, false, event.position)
			_pressed_idx = -1
			_press_touch = -1


func _set_pressed(i: int, on: bool, pos: Vector2) -> void:
	var mat := _btn_shaders[i]
	mat.set_shader_parameter("pressed", 1.0 if on else 0.0)
	mat.set_shader_parameter("touch_depth", 0.6 if on else 0.0)
	if on:
		var r := _btn_rects[i]
		mat.set_shader_parameter("touch_uv",
			Vector2((pos.x - r.position.x) / r.size.x, (pos.y - r.position.y) / r.size.y))
		Input.vibrate_handheld(12, 0.6)
	else:
		mat.set_shader_parameter("touch_uv", Vector2(-1.0, -1.0))


func _format_time(seconds: float) -> String:
	if seconds < 60.0:
		return "%.1fs" % seconds
	var mins := int(seconds) / 60
	var secs := int(seconds) % 60
	var tenths := int(fmod(seconds, 1.0) * 10)
	return "%d:%02d.%d" % [mins, secs, tenths]
