shader_type canvas_item;

// background.gdshader — Dark gradient fallback when no background image is loaded.
// Subtle vertical gradient with slight vignette.

uniform vec4 top_color : source_color = vec4(0.08, 0.08, 0.12, 1.0);
uniform vec4 bottom_color : source_color = vec4(0.12, 0.12, 0.18, 1.0);
uniform float vignette : hint_range(0.0, 0.5) = 0.2;

void fragment() {
	vec3 color = mix(top_color.rgb, bottom_color.rgb, UV.y);

	// Subtle vignette
	float v = 1.0 - length(UV - 0.5) * vignette;
	color *= v;

	COLOR = vec4(color, 1.0);
}
