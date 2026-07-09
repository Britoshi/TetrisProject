# theme.gd — Swappable button theme presets for mobile_controls.gd.
# Each theme is a Dictionary of shader uniform name → value.
# Load with ThemeData.get_theme("name") or access ThemeData.PRESETS directly.
#
# Adding a new theme:
#   1. Add an entry to PRESETS below
#   2. Override any uniforms from the shader (shaders/liquid_glass.gdshader)
#
# shader uniforms reference:
#   blur_amount, warp_intensity, warp_strength,
#   border_width, border_color, rim_intensity,
#   chromatic_strength, sheen_intensity, sheen_falloff,
#   tint_alpha (modulates per-button fill_color),
#   glow_color, corner_radius_fraction, edge_smoothness

class_name ThemeData
extends RefCounted


static var PRESETS: Dictionary = {
	"ios_liquid_glass": {
		"label": "iOS Liquid Glass",
		"blur_amount": 2.5,
		"warp_intensity": 0.25,
		"warp_strength": 10.0,
		"border_width": 1.5,
		"border_color": Color(1.0, 1.0, 1.0, 0.45),
		"rim_intensity": 0.5,
		"chromatic_strength": 3.0,
		"sheen_intensity": 0.10,
		"sheen_falloff": 0.4,
		"tint_alpha": 0.55,
		"glow_color": Color(1.0, 0.9, 0.5, 0.7),
	},

	"frosted_opaque": {
		"label": "Frosted Opaque",
		"blur_amount": 4.5,
		"warp_intensity": 0.15,
		"warp_strength": 8.0,
		"border_width": 1.0,
		"border_color": Color(1.0, 1.0, 1.0, 0.25),
		"rim_intensity": 0.3,
		"chromatic_strength": 1.5,
		"sheen_intensity": 0.06,
		"sheen_falloff": 0.5,
		"tint_alpha": 0.75,
		"glow_color": Color(1.0, 1.0, 1.0, 0.4),
	},

	"neon_edge": {
		"label": "Neon Edge",
		"blur_amount": 1.5,
		"warp_intensity": 0.35,
		"warp_strength": 14.0,
		"border_width": 2.5,
		"border_color": Color(1.0, 1.0, 1.0, 0.8),
		"rim_intensity": 0.8,
		"chromatic_strength": 5.0,
		"sheen_intensity": 0.14,
		"sheen_falloff": 0.3,
		"tint_alpha": 0.35,
		"glow_color": Color(0.4, 0.8, 1.0, 0.9),
	},

	"dark_glass": {
		"label": "Dark Glass",
		"blur_amount": 3.0,
		"warp_intensity": 0.2,
		"warp_strength": 9.0,
		"border_width": 1.8,
		"border_color": Color(1.0, 1.0, 1.0, 0.35),
		"rim_intensity": 0.45,
		"chromatic_strength": 2.5,
		"sheen_intensity": 0.08,
		"sheen_falloff": 0.45,
		"tint_alpha": 0.7,
		"glow_color": Color(0.6, 0.6, 0.7, 0.5),
	},

	"clear_crystal": {
		"label": "Clear Crystal",
		"blur_amount": 0.8,
		"warp_intensity": 0.45,
		"warp_strength": 16.0,
		"border_width": 0.8,
		"border_color": Color(1.0, 1.0, 1.0, 0.6),
		"rim_intensity": 0.7,
		"chromatic_strength": 4.0,
		"sheen_intensity": 0.16,
		"sheen_falloff": 0.28,
		"tint_alpha": 0.2,
		"glow_color": Color(1.0, 1.0, 1.0, 0.8),
	},
}


static func get_theme(name: String) -> Dictionary:
	"""Return a copy of the named theme, or the default if not found."""
	if PRESETS.has(name):
		return PRESETS[name].duplicate()
	return PRESETS["ios_liquid_glass"].duplicate()


static func list_theme_names() -> Array[String]:
	var names: Array[String] = []
	for key in PRESETS:
		names.append(key)
	return names
