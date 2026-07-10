shader_type canvas_item;

// glass_panel.gdshader — Liquid-glass HUD panel (stats / Hold / Next frames).
// Same language as the board & pieces: a rounded rect that refracts the
// pre-baked background with a gentle edge lens, a dark glass tint for
// readability, a rim light and border stroke, and a top sheen.

uniform sampler2D bg_tex : source_color, hint_default_black, filter_linear_mipmap;
uniform vec2 rect_px = vec2(200.0, 100.0);
uniform float corner_px = 14.0;
uniform vec4 tint : source_color = vec4(0.09, 0.12, 0.20, 0.58);
uniform float bg_dim : hint_range(0.0, 1.0) = 0.4;
uniform float blur : hint_range(0.0, 8.0) = 3.0;
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 0.22);
uniform float border_px : hint_range(0.0, 6.0) = 1.5;
uniform float warp : hint_range(0.0, 20.0) = 6.0;

// Squircle SDF (exponent 2.5) — the Apple continuous corner, identical to
// the board/button/piece corners, so the panels round the same way.
float rbox(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	float d = min(max(q.x, q.y), 0.0);
	vec2 corner = max(q, vec2(0.0));
	float corner_dist = pow(pow(corner.x, 2.5) + pow(corner.y, 2.5), 1.0 / 2.5);
	return d + corner_dist - r;
}

void fragment() {
	vec2 half_size = rect_px * 0.5;
	vec2 p = (UV - 0.5) * rect_px;
	float d = rbox(p, half_size, corner_px);
	float shape = clamp(0.5 - d, 0.0, 1.0);
	if (shape < 0.003) {
		discard;
	}

	// Edge lens: bend the frosted background toward the rim
	float w = clamp(-d / max(min(half_size.x, half_size.y), 1.0), 0.0, 1.0);
	vec2 dir = normalize(p / max(half_size, vec2(1.0)) + vec2(1e-5));
	float fall = exp(-warp * w * w);
	vec2 suv = SCREEN_UV - dir * fall * 0.02;
	vec3 bg = textureLod(bg_tex, suv, blur).rgb * (1.0 - bg_dim);
	vec3 color = mix(bg, tint.rgb, tint.a);

	// Rim light + border stroke
	float rim = (1.0 - smoothstep(0.0, border_px * 2.5, -d)) * step(d, 0.0);
	color = mix(color, border_color.rgb, rim * border_color.a * 0.5);
	float border = 1.0 - smoothstep(border_px - 1.0, border_px + 1.0, abs(d));
	color = mix(color, border_color.rgb, border * border_color.a);

	// Top sheen
	color += smoothstep(0.5, 0.0, UV.y) * 0.05;

	COLOR = vec4(color, shape);
}
