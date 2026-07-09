# replay_hud.gd — Playback controls shown during a replay (bottom bar).
# Its own CanvasLayer (scenes/replay_hud.tscn) above everything. main.gd
# shows/hides it, connects the signals to its replay_* methods, and calls
# update_progress() each frame.

extends Control

signal toggle_pause
signal restart
signal cycle_speed
signal exit_pressed
signal scrubbed(fraction: float)

const CORNER := 10
var _seeking: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var bar_style := _flat(Color(0.10, 0.12, 0.19, 0.95), 14)
	bar_style.border_color = Color(1, 1, 1, 0.10)
	bar_style.border_width_top = 1
	%Bar.add_theme_stylebox_override("panel", bar_style)

	_style_btn(%PlayBtn)
	_style_btn(%RestartBtn)
	_style_btn(%SpeedBtn)
	_style_btn(%ExitBtn)

	%PlayBtn.pressed.connect(func(): toggle_pause.emit())
	%RestartBtn.pressed.connect(func(): restart.emit())
	%SpeedBtn.pressed.connect(func(): cycle_speed.emit())
	%ExitBtn.pressed.connect(func(): exit_pressed.emit())

	%Seek.min_value = 0.0
	%Seek.max_value = 1000.0
	%Seek.drag_started.connect(func(): _seeking = true)
	%Seek.drag_ended.connect(func(_v):
		_seeking = false
		scrubbed.emit(%Seek.value / 1000.0))
	%Seek.value_changed.connect(func(v):
		if _seeking:
			scrubbed.emit(v / 1000.0))

	%TimeLabel.add_theme_color_override("font_color", Color.WHITE)
	%TimeLabel.add_theme_font_size_override("font_size", 15)


func update_progress(clock: float, dur: float, paused: bool, speed: float) -> void:
	if dur > 0.0 and not _seeking:
		%Seek.set_value_no_signal(clock / dur * 1000.0)
	%PlayBtn.text = "▶" if paused else "❚❚"
	%SpeedBtn.text = _fmt_speed(speed)
	%TimeLabel.text = "%s / %s" % [_fmt(clock), _fmt(dur)]


func _fmt_speed(speed: float) -> String:
	# GDScript's % has no %g; format compactly by hand
	if speed == float(int(speed)):
		return "%dx" % int(speed)
	return "%.1fx" % speed


func _fmt(s: float) -> String:
	if s < 60.0:
		return "%.1f" % s
	return "%d:%02d" % [int(s) / 60, int(s) % 60]


func _flat(bg: Color, corner: int) -> StyleBoxFlat:
	var st := StyleBoxFlat.new()
	st.bg_color = bg
	st.corner_radius_top_left = corner
	st.corner_radius_top_right = corner
	st.corner_radius_bottom_left = corner
	st.corner_radius_bottom_right = corner
	st.anti_aliasing = true
	return st


func _style_btn(btn: Button) -> void:
	var bg := Color(0.22, 0.26, 0.38)
	btn.add_theme_stylebox_override("normal", _flat(bg, CORNER))
	btn.add_theme_stylebox_override("hover", _flat(bg.lightened(0.08), CORNER))
	btn.add_theme_stylebox_override("pressed", _flat(bg.lightened(0.16), CORNER))
	btn.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	btn.add_theme_font_size_override("font_size", 18)
	btn.add_theme_color_override("font_color", Color.WHITE)
