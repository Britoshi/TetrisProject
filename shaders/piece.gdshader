shader_type canvas_item;

// piece.gdshader — Liquid-glass tetromino cell (active piece, ghost, hold,
// next). Matches the board's locked-block look: a rounded squircle tile that
// refracts the (pre-baked) background, tints it with the piece colour, and
// carries an HDR piece-colour rim so the bloom traces its edge.

uniform vec4 fill_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform float cell_radius : hint_range(0.0, 0.5) = 0.26;
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
uniform float emission : hint_range(0.0, 4.0) = 0.0;    // extra whole-cell HDR
uniform float glow_intensity : hint_range(0.0, 1.0) = 0.4;  // legacy (unused)

// Glass — same pre-baked background the board samples (set from main.gd)
uniform sampler2D bg_tex : source_color, hint_default_black, filter_linear_mipmap;
uniform float tint_alpha : hint_range(0.0, 1.0) = 0.7;
uniform float bg_dim : hint_range(0.0, 1.0) = 0.35;
uniform float block_emission : hint_range(0.0, 4.0) = 1.2;  // rim HDR (bloom)
uniform float blur_amount : hint_range(0.0, 8.0) = 2.0;

float sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	float d = min(max(q.x, q.y), 0.0);
	vec2 corner = max(q, vec2(0.0));
	float cd = pow(pow(corner.x, 2.5) + pow(corner.y, 2.5), 1.0 / 2.5);
	return d + cd - r;
}

void fragment() {
	// SDF in UV, converted to pixels (via UV derivative) for a crisp rim/AA
	float d_uv = sdf(UV - 0.5, vec2(0.5), cell_radius);
	float ppu = 1.0 / max(fwidth(UV.x), 1e-5);   // pixels per UV ≈ cell size
	float d = d_uv * ppu;
	float shape = clamp(0.5 - d, 0.0, 1.0);
	if (shape < 0.01) {
		discard;
	}

	// Refract the frosted background behind the cell, tint with piece colour
	vec3 bg = textureLod(bg_tex, SCREEN_UV, blur_amount * 0.4).rgb * (1.0 - bg_dim);
	vec3 color = mix(bg, fill_color.rgb, tint_alpha);

	// HDR rim in the piece colour — the bloom hugs the rounded edge
	float rim = (1.0 - smoothstep(0.0, 3.0, -d)) * step(d, 0.0);
	color = mix(color, fill_color.rgb * (1.0 + block_emission), rim * 0.85);

	// Top specular sheen
	color += smoothstep(0.4, 0.0, UV.y) * 0.08;

	color *= 1.0 + emission;
	COLOR = vec4(color, shape * fill_color.a * alpha);
}
