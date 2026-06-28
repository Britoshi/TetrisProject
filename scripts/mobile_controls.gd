# mobile_controls.gd — On-screen touch buttons with settings & edit mode.
# Attached to a full-screen Control inside a CanvasLayer.
# Uses Input.action_press() / Input.action_release() so game logic needs no changes.
#
# Modes:
#   NORMAL   — buttons fire game actions, gear icon visible top-left
#   SETTINGS — overlay panel: Edit Layout, Reset Defaults, Close
#   EDIT     — drag buttons to reposition, "Done" saves, no game actions

extends Control


# ── Layout constants ──
const ROWS: int = 2
const COLS: int = 3
const GAP: float = 10.0
const BOTTOM_MARGIN: float = 20.0
const PANEL_PADDING: float = 14.0
const BTN_ASPECT: float = 0.65
const FONT_SIZE: int = 28
const GEAR_SIZE: float = 44.0
const BTN_SIZE_MIN: float = 0.5
const BTN_SIZE_MAX: float = 2.0
const BTN_SIZE_STEP: float = 0.1

# ── Mode enum ──
enum Mode { NORMAL, SETTINGS, EDIT }

# ── Default button definitions [label, action, color] ──
const DEFAULT_BUTTONS: Array = [
	["◀",  "tetris_move_left",   Color(0.22, 0.27, 0.50, 1.0)],
	["▶",  "tetris_move_right",  Color(0.22, 0.27, 0.50, 1.0)],
	["↻",  "tetris_rotate_cw",    Color(0.22, 0.48, 0.28, 1.0)],
	["▼",  "tetris_soft_drop",    Color(0.50, 0.27, 0.22, 1.0)],
	["⬇",  "tetris_hard_drop",    Color(0.60, 0.15, 0.18, 1.0)],
	["↺",  "tetris_rotate_ccw",   Color(0.22, 0.48, 0.28, 1.0)],
]

# ── Per-button runtime state ──
var _btn_rects: Array[Rect2] = []       # current position of each button
var _btn_actions: Array[String] = []
var _btn_labels: Array[String] = []
var _btn_colors: Array[Color] = []

# ── Mode state ──
var _mode: int = Mode.NORMAL
var _panel_rect: Rect2                  # background panel behind buttons

# ── Gear ──
var _gear_rect: Rect2

# ── Settings panel hit regions ──
var _settings_panel_bg: Rect2
var _settings_edit_rect: Rect2
var _settings_reset_rect: Rect2
var _settings_close_rect: Rect2
var _settings_size_minus_rect: Rect2
var _settings_size_plus_rect: Rect2

# ── Edit mode ──
var _done_rect: Rect2                   # "Done" button in edit mode
var _edit_reset_rect: Rect2             # "Reset" button in edit mode
var _dragging: int = -1                 # button index being dragged, -1 = none
var _drag_offset: Vector2               # offset from touch to button origin
var _font_size: int = FONT_SIZE
var _btn_size_mult: float = 1.0          # user-adjustable button size multiplier

# ── Touch tracking (NORMAL mode) ──
var _touch_map: Dictionary = {}         # event.index → button index


# ═══════════════════════════════════════════════════════════
# Lifecycle
# ═══════════════════════════════════════════════════════════

func _ready() -> void:
	# Populate defaults
	for def in DEFAULT_BUTTONS:
		_btn_labels.append(def[0])
		_btn_actions.append(def[1])
		_btn_colors.append(def[2])

	mouse_filter = Control.MOUSE_FILTER_PASS

	# Ensure we have a size
	if size.x <= 0 or size.y <= 0:
		var vp_rect := get_viewport_rect()
		if vp_rect.size.x > 0:
			position = Vector2.ZERO
			size = vp_rect.size

	# Try loading saved config; if not found, compute default layout
	if not _load_config():
		_layout_default()

	queue_redraw()
	resized.connect(_on_resized)


func _on_resized() -> void:
	if _mode == Mode.NORMAL:
		_layout_default()
	elif _mode == Mode.EDIT:
		# Re-layout in edit mode too so buttons stay on screen
		_layout_default()
	else:
		queue_redraw()


# ═══════════════════════════════════════════════════════════
# Layout
# ═══════════════════════════════════════════════════════════

func _layout_default() -> void:
	"""Compute default button positions based on current viewport size."""
	_btn_rects.clear()
	if size.x <= 0 or size.y <= 0:
		return

	var layout := Constants.calculate_layout(size)
	var max_w: float = layout.button_max_w * _btn_size_mult
	var btn_w: float = minf((size.x - GAP * (COLS + 1)) / COLS, max_w)
	var btn_h: float = btn_w * BTN_ASPECT
	var total_w: float = btn_w * COLS + GAP * (COLS - 1)
	var total_h: float = btn_h * ROWS + GAP * (ROWS - 1)
	var start_x: float = (size.x - total_w) / 2.0
	var start_y: float = size.y - BOTTOM_MARGIN - total_h

	_panel_rect = Rect2(
		start_x - PANEL_PADDING,
		start_y - PANEL_PADDING,
		total_w + PANEL_PADDING * 2,
		total_h + PANEL_PADDING * 2
	)

	_font_size = maxi(14, int(btn_h * 0.4))

	for i in range(DEFAULT_BUTTONS.size()):
		var col: int = i % COLS
		var row: int = i / COLS
		_btn_rects.append(Rect2(
			start_x + col * (btn_w + GAP),
			start_y + row * (btn_h + GAP),
			btn_w, btn_h
		))

	queue_redraw()


# ═══════════════════════════════════════════════════════════
# Drawing
# ═══════════════════════════════════════════════════════════

func _draw() -> void:
	match _mode:
		Mode.NORMAL:
			_draw_buttons(false)
			_draw_gear()
		Mode.SETTINGS:
			_draw_buttons(true)
			_draw_gear()
			_draw_settings_overlay()
		Mode.EDIT:
			_draw_buttons_editable()
			_draw_edit_toolbar()


# ── Gear icon ──

func _draw_gear() -> void:
	_gear_rect = Rect2(10, 10, GEAR_SIZE, GEAR_SIZE)
	var font := ThemeDB.fallback_font
	var fs := int(GEAR_SIZE * 0.55)
	var label := "⚙"
	var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	var label_pos := _gear_rect.position + (_gear_rect.size - label_size) / 2.0

	draw_rect(_gear_rect, Color(0.0, 0.0, 0.0, 0.5), true)
	draw_rect(_gear_rect, Color(1.0, 1.0, 1.0, 0.25), false, 1.5)
	draw_string(font, label_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


# ── Normal / dimmed buttons ──

func _draw_buttons(dimmed: bool) -> void:
	if _btn_rects.is_empty():
		return

	var font := ThemeDB.fallback_font
	var alpha_mod: float = 0.35 if dimmed else 1.0

	# Panel background
	var bg_color := Color(0.0, 0.0, 0.0, 0.45 * alpha_mod)
	draw_rect(_panel_rect, bg_color, true)
	draw_rect(_panel_rect, Color(1.0, 1.0, 1.0, 0.08 * alpha_mod), false, 1.0)

	for i in range(_btn_rects.size()):
		var r := _btn_rects[i]
		var base := _btn_colors[i]
		base.a *= alpha_mod
		var color: Color
		if not dimmed and Input.is_action_pressed(_btn_actions[i]):
			color = base.lightened(0.2)
			color.a = base.a
		else:
			color = base

		draw_rect(r, color, true)
		draw_rect(r, Color(1.0, 1.0, 1.0, 0.3 * alpha_mod), false, 2.0)

		var lbl := _btn_labels[i]
		var label_size := font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_CENTER, -1, _font_size)
		var label_pos := r.position + (r.size - label_size) / 2.0
		var label_color := Color.WHITE
		label_color.a = alpha_mod
		draw_string(font, label_pos, lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, label_color)


# ── Settings overlay ──

func _draw_settings_overlay() -> void:
	# Full-screen dim
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.0, 0.0, 0.55), true)

	# Panel
	var pw: float = minf(size.x * 0.75, 340.0)
	var ph: float = 260.0
	var px: float = (size.x - pw) / 2.0
	var py: float = (size.y - ph) / 2.0
	_settings_panel_bg = Rect2(px, py, pw, ph)

	draw_rect(_settings_panel_bg, Color(0.15, 0.15, 0.18, 1.0), true)
	draw_rect(_settings_panel_bg, Color(1.0, 1.0, 1.0, 0.25), false, 2.0)

	var font := ThemeDB.fallback_font
	var fs := 18
	var row_h := 42.0
	var margin := 16.0

	# Title
	var title := "Settings"
	var title_size := font.get_string_size(title, HORIZONTAL_ALIGNMENT_CENTER, -1, fs + 2)
	var title_pos := Vector2(px + (pw - title_size.x) / 2.0, py + margin)
	draw_string(font, title_pos, title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 2, Color.WHITE)

	var y := py + margin + title_size.y + 12.0
	var btn_margin := 20.0
	var btn_w := pw - btn_margin * 2
	var btn_color := Color(0.25, 0.25, 0.30, 1.0)

	# "Edit Layout" button
	_settings_edit_rect = Rect2(px + btn_margin, y, btn_w, row_h)
	_draw_panel_button(_settings_edit_rect, "Edit Layout", font, fs, btn_color)
	y += row_h + 10.0

	# "Reset to Defaults" button
	_settings_reset_rect = Rect2(px + btn_margin, y, btn_w, row_h)
	_draw_panel_button(_settings_reset_rect, "Reset to Defaults", font, fs, Color(0.35, 0.18, 0.18, 1.0))
	y += row_h + 10.0

	# Button size row
	var size_label := "Btn Size: %.0f%%" % (_btn_size_mult * 100.0)
	var size_lbl_w := btn_w * 0.45
	var size_lbl_rect := Rect2(px + btn_margin, y, size_lbl_w, row_h)
	_draw_panel_button(size_lbl_rect, size_label, font, fs, btn_color)

	var size_btn_w := (btn_w - size_lbl_w - 10) / 2.0
	_settings_size_minus_rect = Rect2(px + btn_margin + size_lbl_w + 10, y, size_btn_w, row_h)
	_draw_panel_button(_settings_size_minus_rect, "-", font, fs, btn_color)

	_settings_size_plus_rect = Rect2(_settings_size_minus_rect.end.x + 5, y, size_btn_w, row_h)
	_draw_panel_button(_settings_size_plus_rect, "+", font, fs, btn_color)
	y += row_h + 10.0

	# "Close" button
	_settings_close_rect = Rect2(px + btn_margin, y, btn_w, row_h)
	_draw_panel_button(_settings_close_rect, "Close", font, fs, btn_color)


func _draw_panel_button(rect: Rect2, text: String, font: Font, fs: int, color: Color) -> void:
	draw_rect(rect, color, true)
	draw_rect(rect, Color(1.0, 1.0, 1.0, 0.2), false, 1.5)
	var s := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	var p := rect.position + (rect.size - s) / 2.0
	draw_string(font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)


# ── Edit mode ──

func _draw_edit_toolbar() -> void:
	# Top bar
	var bar_h := 50.0
	var bar_rect := Rect2(0, 0, size.x, bar_h)
	draw_rect(bar_rect, Color(0.0, 0.0, 0.0, 0.7), true)
	draw_rect(Rect2(0, bar_h, size.x, 2), Color(1.0, 1.0, 1.0, 0.3), true)

	var font := ThemeDB.fallback_font
	var fs := 17

	# Done button (right side)
	var done_w := 110.0
	var done_h := 34.0
	_done_rect = Rect2(size.x - done_w - 12, (bar_h - done_h) / 2.0, done_w, done_h)
	var done_color := Color(0.22, 0.55, 0.30, 1.0)
	draw_rect(_done_rect, done_color, true)
	draw_rect(_done_rect, Color.WHITE, false, 2.0)
	var done_text := "Done ✓"
	var done_s := font.get_string_size(done_text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	draw_string(font, _done_rect.position + (_done_rect.size - done_s) / 2.0, done_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)

	# Reset button (left of Done)
	var reset_w := 80.0
	_edit_reset_rect = Rect2(_done_rect.position.x - reset_w - 10, (bar_h - done_h) / 2.0, reset_w, done_h)
	var reset_color := Color(0.40, 0.18, 0.18, 1.0)
	draw_rect(_edit_reset_rect, reset_color, true)
	draw_rect(_edit_reset_rect, Color.WHITE, false, 1.5)
	var reset_text := "Reset"
	var reset_s := font.get_string_size(reset_text, HORIZONTAL_ALIGNMENT_CENTER, -1, fs - 1)
	draw_string(font, _edit_reset_rect.position + (_edit_reset_rect.size - reset_s) / 2.0, reset_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, Color.WHITE)

	# Hint text
	var hint := "Drag buttons to reposition"
	var hint_s := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_CENTER, -1, 14)
	draw_string(font, Vector2((size.x - hint_s.x) / 2.0, bar_h + hint_s.y + 6),
		hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 1.0, 1.0, 0.5))


func _draw_buttons_editable() -> void:
	if _btn_rects.is_empty():
		return

	var font := ThemeDB.fallback_font

	# Dim panel
	draw_rect(_panel_rect, Color(0.0, 0.0, 0.0, 0.3), true)
	draw_rect(_panel_rect, Color(1.0, 1.0, 1.0, 0.06), false, 1.0)

	for i in range(_btn_rects.size()):
		var r := _btn_rects[i]
		var color := _btn_colors[i]
		var being_dragged := (_dragging == i)

		# Button fill — lighter while dragging
		var fill := color.lightened(0.15) if being_dragged else color
		fill.a = 0.85
		draw_rect(r, fill, true)

		# Dashed border — highlight during drag
		var border_color := Color(1.0, 1.0, 0.0, 0.9) if being_dragged else Color(1.0, 1.0, 1.0, 0.5)
		var border_width := 3.0 if being_dragged else 2.0
		_draw_dashed_rect(r, border_color, border_width, 6.0, 4.0)

		# Small label with action short name
		var short_name := _action_short_name(_btn_actions[i])
		var fs := maxi(10, int(r.size.y * 0.2))
		var name_s := font.get_string_size(short_name, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
		var name_pos := Vector2(r.position.x + (r.size.x - name_s.x) / 2.0, r.position.y + r.size.y - name_s.y - 4)
		draw_string(font, name_pos, short_name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1.0, 1.0, 1.0, 0.6))

		# Main label
		var lbl := _btn_labels[i]
		var lbl_fs := _font_size
		var label_size := font.get_string_size(lbl, HORIZONTAL_ALIGNMENT_CENTER, -1, lbl_fs)
		var label_pos := r.position + (r.size - label_size) / 2.0
		label_pos.y -= name_s.y / 2.0  # nudge up to make room for action name
		draw_string(font, label_pos, lbl, HORIZONTAL_ALIGNMENT_LEFT, -1, lbl_fs, Color.WHITE)


func _draw_dashed_rect(rect: Rect2, color: Color, width: float, dash_len: float, gap_len: float) -> void:
	"""Draw a dashed rectangle border."""
	var pts_t := _dash_points(rect.position, Vector2(rect.position.x + rect.size.x, rect.position.y), dash_len, gap_len)
	var pts_r := _dash_points(Vector2(rect.position.x + rect.size.x, rect.position.y), rect.position + rect.size, dash_len, gap_len)
	var pts_b := _dash_points(rect.position + rect.size, Vector2(rect.position.x, rect.position.y + rect.size.y), dash_len, gap_len)
	var pts_l := _dash_points(Vector2(rect.position.x, rect.position.y + rect.size.y), rect.position, dash_len, gap_len)

	for seg in pts_t: draw_line(seg[0], seg[1], color, width)
	for seg in pts_r: draw_line(seg[0], seg[1], color, width)
	for seg in pts_b: draw_line(seg[0], seg[1], color, width)
	for seg in pts_l: draw_line(seg[0], seg[1], color, width)


func _dash_points(from: Vector2, to: Vector2, dash: float, gap: float) -> Array:
	var result: Array = []
	var dir := (to - from).normalized()
	var total := from.distance_to(to)
	var drawn: float = 0.0
	var drawing: bool = true
	while drawn < total:
		var seg_len: float = dash if drawing else gap
		var remaining := total - drawn
		if seg_len > remaining:
			seg_len = remaining
		if drawing:
			var a := from + dir * drawn
			var b := from + dir * (drawn + seg_len)
			result.append([a, b])
		drawn += seg_len
		drawing = not drawing
	return result


func _action_short_name(action: String) -> String:
	match action:
		"tetris_move_left":   return "LEFT"
		"tetris_move_right":  return "RIGHT"
		"tetris_soft_drop":   return "DROP"
		"tetris_hard_drop":   return "HARD"
		"tetris_rotate_cw":   return "R-CW"
		"tetris_rotate_ccw":  return "R-CCW"
		_:                    return action


# ═══════════════════════════════════════════════════════════
# Touch dispatch
# ═══════════════════════════════════════════════════════════

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		match _mode:
			Mode.NORMAL:   _touch_normal(event.position, event.pressed, event.index)
			Mode.SETTINGS: _touch_settings(event.position, event.pressed)
			Mode.EDIT:     _touch_edit(event.position, event.pressed, event.index)
	elif event is InputEventScreenDrag:
		if _mode == Mode.EDIT:
			_drag_edit(event.position, event.index)


# ── NORMAL mode touch ──

func _touch_normal(pos: Vector2, pressed: bool, index: int) -> void:
	if pressed:
		# Gear?
		if _gear_rect.has_point(pos):
			_mode = Mode.SETTINGS
			queue_redraw()
			return

		# Button?
		for i in range(_btn_rects.size()):
			if _btn_rects[i].has_point(pos):
				Input.action_press(_btn_actions[i])
				_touch_map[index] = i
				accept_event()
				queue_redraw()
				return
	else:
		_release_normal_touch(index)


func _release_normal_touch(index: int) -> void:
	if index in _touch_map:
		var i: int = _touch_map[index]
		Input.action_release(_btn_actions[i])
		_touch_map.erase(index)
		queue_redraw()


# ── SETTINGS mode touch ──

func _touch_settings(pos: Vector2, pressed: bool) -> void:
	if not pressed:
		return

	# Edit Layout
	if _settings_edit_rect.has_point(pos):
		_mode = Mode.EDIT
		queue_redraw()
		return

	# Reset to Defaults
	if _settings_reset_rect.has_point(pos):
		_reset_to_defaults()
		queue_redraw()
		return

	# Close
	if _settings_close_rect.has_point(pos):
		_mode = Mode.NORMAL
		queue_redraw()
		return

	# Button size -
	if _settings_size_minus_rect.has_point(pos):
		_btn_size_mult = clampf(_btn_size_mult - BTN_SIZE_STEP, BTN_SIZE_MIN, BTN_SIZE_MAX)
		_layout_default()
		queue_redraw()
		return

	# Button size +
	if _settings_size_plus_rect.has_point(pos):
		_btn_size_mult = clampf(_btn_size_mult + BTN_SIZE_STEP, BTN_SIZE_MIN, BTN_SIZE_MAX)
		_layout_default()
		queue_redraw()
		return

	# Tap outside panel → close
	if not _settings_panel_bg.has_point(pos):
		_mode = Mode.NORMAL
		queue_redraw()


# ── EDIT mode touch ──

func _touch_edit(pos: Vector2, pressed: bool, index: int) -> void:
	if pressed:
		# Done?
		if _done_rect.has_point(pos):
			_save_config()
			_mode = Mode.NORMAL
			_dragging = -1
			queue_redraw()
			return

		# Reset?
		if _edit_reset_rect.has_point(pos):
			_reset_to_defaults()
			_dragging = -1
			queue_redraw()
			return

		# Button hit? Start dragging
		for i in range(_btn_rects.size()):
			if _btn_rects[i].has_point(pos):
				_dragging = i
				_drag_offset = pos - _btn_rects[i].position
				accept_event()
				queue_redraw()
				return
	else:
		# Release drag
		if _dragging >= 0:
			# Update panel rect to match new button positions
			_recalc_panel()
			_dragging = -1
			queue_redraw()


func _drag_edit(pos: Vector2, index: int) -> void:
	if _dragging < 0:
		return
	_btn_rects[_dragging].position = pos - _drag_offset
	queue_redraw()


func _recalc_panel() -> void:
	"""Update _panel_rect to enclose all buttons after a drag."""
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
		min_x - PANEL_PADDING,
		min_y - PANEL_PADDING,
		max_x - min_x + PANEL_PADDING * 2,
		max_y - min_y + PANEL_PADDING * 2
	)


# ═══════════════════════════════════════════════════════════
# Save / Load
# ═══════════════════════════════════════════════════════════

const SAVE_PATH := "user://mobile_controls.cfg"


func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("layout", "button_count", _btn_rects.size())
	cfg.set_value("layout", "panel_rect", var_to_str(_panel_rect))
	cfg.set_value("layout", "btn_size_mult", _btn_size_mult)
	for i in range(_btn_rects.size()):
		var section := "button_%d" % i
		cfg.set_value(section, "action", _btn_actions[i])
		cfg.set_value(section, "label", _btn_labels[i])
		cfg.set_value(section, "color", var_to_str(_btn_colors[i]))
		cfg.set_value(section, "rect", var_to_str(_btn_rects[i]))
	cfg.save(SAVE_PATH)
	print("Mobile controls saved to ", SAVE_PATH)


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
	_font_size = maxi(10, int(_btn_rects[0].size.y * 0.4)) if _btn_rects.size() > 0 else FONT_SIZE
	return true


func _reset_to_defaults() -> void:
	_btn_rects.clear()
	_btn_actions.clear()
	_btn_labels.clear()
	_btn_colors.clear()
	_btn_size_mult = 1.0
	for def in DEFAULT_BUTTONS:
		_btn_labels.append(def[0])
		_btn_actions.append(def[1])
		_btn_colors.append(def[2])
	_layout_default()
