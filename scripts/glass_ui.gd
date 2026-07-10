# glass_ui.gd — Shared liquid-glass styling for UI (settings, history, …).
# One material for the whole app so every panel/button reads the same:
# liquid_glass.gdshader (screen-space refraction, squircle corners, rim,
# sheen) driven by the ios_liquid_glass theme.
class_name GlassUI
extends RefCounted

const SHADER_PATH := "res://shaders/liquid_glass.gdshader"
const THEME_NAME := "ios_liquid_glass"


static func _shader() -> Shader:
	return load(SHADER_PATH) as Shader


static func _theme() -> Dictionary:
	return ThemeData.get_theme(THEME_NAME)


static func shadow_style(corner_r: int) -> StyleBoxFlat:
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


static func glass_body(tint: Color, corner: float, tint_alpha: float = -1.0) -> ColorRect:
	"""A full-rect ColorRect running its own liquid_glass instance."""
	var body := ColorRect.new()
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	var sh := _shader()
	if sh:
		mat.shader = sh.duplicate()
	var td := _theme()
	for key in td:
		if key == "label" or key == "tint_alpha":
			continue
		mat.set_shader_parameter(key, td[key])
	if tint_alpha < 0.0:
		tint_alpha = td.get("tint_alpha", 0.55)
	mat.set_shader_parameter("tint", Color(tint.r, tint.g, tint.b, tint_alpha))
	mat.set_shader_parameter("corner_radius", corner)
	mat.set_shader_parameter("pressed", 0.0)
	body.material = mat
	return body


static func panelize(panel: Control, tint: Color, corner: float, tint_alpha: float = -1.0) -> void:
	"""Give any Control a glass background (drawn behind its content)."""
	var body := glass_body(tint, corner, tint_alpha)
	panel.add_child(body)
	panel.move_child(body, 0)


static func buttonize(btn: Button, tint: Color, corner: float, keep_text: bool = true) -> void:
	"""Turn a Button into a glass button: shadow-only styleboxes, a glass
	body behind, press feedback. Keeps the button's own text label unless
	keep_text is false (caller adds its own content)."""
	var shadow := shadow_style(12)
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		btn.add_theme_stylebox_override(st, shadow)
	if keep_text:
		btn.add_theme_color_override("font_color", Color.WHITE)
		btn.add_theme_color_override("font_hover_color", Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)

	var body := glass_body(tint, corner)
	btn.add_child(body)
	btn.move_child(body, 0)

	var mat: ShaderMaterial = body.material
	btn.button_down.connect(func():
		mat.set_shader_parameter("pressed", 1.0)
		mat.set_shader_parameter("touch_depth", 0.6)
		mat.set_shader_parameter("touch_uv", Vector2(0.5, 0.5)))
	btn.button_up.connect(func():
		mat.set_shader_parameter("pressed", 0.0)
		mat.set_shader_parameter("touch_depth", 0.0))
