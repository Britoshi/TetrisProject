shader_type canvas_item;

// piece.gdshader — Per-cell shader for tetromino pieces (active, ghost, hold, next).
// Rounded squircle corners, top highlight for depth, inner glow.

uniform vec4 fill_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform float cell_radius : hint_range(0.0, 0.5) = 0.18;
uniform float glow_intensity : hint_range(0.0, 1.0) = 0.4;
uniform float alpha : hint_range(0.0, 1.0) = 1.0;

// Squircle SDF — Apple-style continuous corner
float sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	float d = min(max(q.x, q.y), 0.0);
	vec2 corner = max(q, vec2(0.0));
	float corner_dist = pow(pow(corner.x, 2.5) + pow(corner.y, 2.5), 1.0 / 2.5);
	return d + corner_dist - r;
}

void fragment() {
	vec2 half_size = vec2(0.5);
	float r = cell_radius;
	float d = sdf(UV - 0.5, half_size, r);
	float shape = 1.0 - smoothstep(-1.0, 1.0, d);

	if (shape < 0.01)
		discard;

	vec3 color = fill_color.rgb;

	// Top highlight for subtle 3D depth
	color += smoothstep(0.55, 1.0, UV.y) * 0.12;

	// Inner glow from edge
	float glow = exp(-abs(d) * 6.0) * glow_intensity * 0.35;
	color += glow;

	COLOR = vec4(color, shape * fill_color.a * alpha);
}
