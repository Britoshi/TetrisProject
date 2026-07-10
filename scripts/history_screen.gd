# history_screen.gd — Records leaderboard + recent-games list with replay.
# Lives on its own CanvasLayer (scenes/history_screen.tscn) above the touch
# controls. main.gd shows/hides it and listens for replay_requested / closed.
# Reads from the GameHistory autoload.

extends Control

signal replay_requested(index: int)
signal closed

const SPRINT_TARGETS: Array[int] = [20, 40, 100, 200]
const ROW_TINT := Color(0.20, 0.24, 0.40)
const CARD_TINT := Color(0.20, 0.24, 0.40)
const PANEL_TINT := Color(0.10, 0.13, 0.22)
const BTN_CORNER := 0.32


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_to_group("menu_input_blockers")

	# Transparent stylebox so only the glass body shows through the panel
	var clear := StyleBoxEmpty.new()
	%Panel.add_theme_stylebox_override("panel", clear)
	GlassUI.panelize(%Panel, PANEL_TINT, 0.08, 0.62)

	GlassUI.buttonize(%BackBtn, Color(0.24, 0.28, 0.44), BTN_CORNER)
	%BackBtn.add_theme_font_size_override("font_size", 18)
	%BackBtn.pressed.connect(func(): closed.emit())

	%Title.add_theme_font_size_override("font_size", 30)
	%Title.add_theme_color_override("font_color", Color.WHITE)
	%RecordsTitle.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	%HistoryTitle.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))


func refresh() -> void:
	"""Rebuild the records grid and the games list from GameHistory."""
	var gh := get_node_or_null("/root/GameHistory")
	if gh == null:
		return
	_build_records(gh)
	_build_list(gh)


# ── Records leaderboard (best time per target) ──

func _build_records(gh: Node) -> void:
	for c in %RecordsGrid.get_children():
		c.queue_free()
	for target in SPRINT_TARGETS:
		var best: float = gh.best_time(target)
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		GlassUI.panelize(card, CARD_TINT, 0.28)
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 2)
		var m := MarginContainer.new()
		for side in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + side, 8)
		m.add_child(vb)
		card.add_child(m)
		var name_lbl := Label.new()
		name_lbl.text = "%d Lines" % target
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
		var time_lbl := Label.new()
		time_lbl.text = _fmt_time(best) if best >= 0.0 else "—"
		time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		time_lbl.add_theme_font_size_override("font_size", 18)
		time_lbl.add_theme_color_override("font_color",
			Color(1, 0.85, 0.35) if best >= 0.0 else Color(1, 1, 1, 0.35))
		vb.add_child(name_lbl)
		vb.add_child(time_lbl)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		%RecordsGrid.add_child(card)


# ── Recent games list ──

func _build_list(gh: Node) -> void:
	for c in %GamesList.get_children():
		c.queue_free()

	var entries: Array = gh.recent()
	if entries.is_empty():
		var empty := Label.new()
		empty.text = "No games yet — play a sprint!"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
		empty.add_theme_font_size_override("font_size", 16)
		%GamesList.add_child(empty)
		return

	for i in range(entries.size()):
		%GamesList.add_child(_make_row(entries[i], i))


func _make_row(e: Dictionary, index: int) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(0, 58)
	GlassUI.buttonize(btn, ROW_TINT, 0.22, false)
	btn.pressed.connect(func(): replay_requested.emit(index))

	var complete: bool = str(e.get("result", "")) == "complete"
	var mode: int = int(e.get("mode", 0))
	var dur: float = float(e.get("duration", 0.0))
	var lines: int = int(e.get("lines", 0))
	var score: int = int(e.get("score", 0))
	var new_rec: bool = bool(e.get("new_record", false))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mm := MarginContainer.new()
	mm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right"]:
		mm.add_theme_constant_override("margin_" + side, 12)
	mm.set_anchors_preset(Control.PRESET_FULL_RECT)
	mm.add_child(row)
	btn.add_child(mm)

	# Result badge
	var badge := Label.new()
	badge.text = "✓" if complete else "✕"
	badge.custom_minimum_size = Vector2(24, 0)
	badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_theme_font_size_override("font_size", 20)
	badge.add_theme_color_override("font_color",
		Color(0.3, 1.0, 0.45) if complete else Color(1.0, 0.4, 0.4))
	row.add_child(badge)

	# Mode + date
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 0)
	var mode_lbl := Label.new()
	mode_lbl.text = ("%d Lines" % mode) if mode > 0 else "Endless"
	if new_rec:
		mode_lbl.text += "  ★"
	mode_lbl.add_theme_font_size_override("font_size", 17)
	mode_lbl.add_theme_color_override("font_color", Color.WHITE)
	var date_lbl := Label.new()
	date_lbl.text = _fmt_date(int(e.get("date", 0)))
	date_lbl.add_theme_font_size_override("font_size", 11)
	date_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	left.add_child(mode_lbl)
	left.add_child(date_lbl)
	row.add_child(left)

	# Stats (right-aligned)
	var stats := VBoxContainer.new()
	stats.alignment = BoxContainer.ALIGNMENT_CENTER
	var time_lbl := Label.new()
	time_lbl.text = _fmt_time(dur)
	time_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	time_lbl.add_theme_font_size_override("font_size", 17)
	time_lbl.add_theme_color_override("font_color",
		Color(1, 0.85, 0.35) if complete else Color(1, 1, 1, 0.7))
	var sub_lbl := Label.new()
	sub_lbl.text = "%d lines · %d pts" % [lines, score]
	sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	sub_lbl.add_theme_font_size_override("font_size", 11)
	sub_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	stats.add_child(time_lbl)
	stats.add_child(sub_lbl)
	row.add_child(stats)

	# Play glyph
	var play := Label.new()
	play.text = "▶"
	play.custom_minimum_size = Vector2(20, 0)
	play.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	play.add_theme_font_size_override("font_size", 15)
	play.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	row.add_child(play)

	return btn


# ── Helpers ──

func _fmt_time(seconds: float) -> String:
	if seconds < 0.0:
		return "—"
	if seconds < 60.0:
		return "%.1fs" % seconds
	var mins := int(seconds) / 60
	var secs := int(seconds) % 60
	var tenths := int(fmod(seconds, 1.0) * 10)
	return "%d:%02d.%d" % [mins, secs, tenths]


func _fmt_date(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d-%02d  %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]
