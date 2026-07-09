shader_type canvas_item;

// board.gdshader — Liquid glass board panel with squircle SDF edges,
// screen-space blur, chromatic aberration, rim light, and specular sheen.
// Piece cells render as flat colors on top. Grid gaps between cells.

uniform sampler2D board_tex : repeat_disable, filter_nearest;
uniform sampler2D bg_tex : repeat_disable, filter_linear_mipmap;

// Grid
uniform vec2 cell_count = vec2(10.0, 20.0);
uniform float vanish_offset = 2.0;
uniform float cell_padding : hint_range(0.0, 0.2) = 0.04;

// Board shape (squircle SDF)
uniform float corner_radius : hint_range(0.0, 0.5) = 0.08;
uniform float edge_smoothness : hint_range(0.5, 3.0) = 1.2;

// Liquid glass
uniform float blur_amount : hint_range(0.0, 8.0) = 3.0;
uniform float warp_intensity : hint_range(0.0, 1.0) = 0.3;
uniform float warp_strength : hint_range(0.0, 30.0) = 12.0;
uniform float chromatic_strength : hint_range(0.0, 5.0) = 2.5;
uniform float rim_intensity : hint_range(0.0, 1.0) = 0.35;
uniform float sheen_intensity : hint_range(0.0, 0.5) = 0.08;
uniform float sheen_falloff : hint_range(0.2, 0.8) = 0.4;
uniform vec4 glass_tint : source_color = vec4(0.03, 0.03, 0.08, 0.7);
uniform vec4 rim_color : source_color = vec4(1.0, 1.0, 1.0, 0.2);

// Piece colors
uniform vec4 color_1 : source_color = vec4(0.0, 0.88, 0.88, 1.0);
uniform vec4 color_2 : source_color = vec4(1.0, 0.84, 0.0, 1.0);
uniform vec4 color_3 : source_color = vec4(0.63, 0.13, 0.94, 1.0);
uniform vec4 color_4 : source_color = vec4(0.0, 0.82, 0.32, 1.0);
uniform vec4 color_5 : source_color = vec4(0.89, 0.1, 0.11, 1.0);
uniform vec4 color_6 : source_color = vec4(0.0, 0.47, 0.95, 1.0);
uniform vec4 color_7 : source_color = vec4(1.0, 0.55, 0.0, 1.0);

// Flash
uniform vec4 flash_rows = vec4(-1.0);
uniform float flash_intensity : hint_range(0.0, 1.0) = 0.0;

// ── Squircle SDF ──
float board_sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	float d = min(max(q.x, q.y), 0.0);
	vec2 corner = max(q, vec2(0.0));
	float corner_dist = pow(pow(corner.x, 2.5) + pow(corner.y, 2.5), 1.0 / 2.5);
	return d + corner_dist - r;
}

vec4 get_color(float type) {
	if (type < 0.5) return vec4(0.0);
	if (type < 1.5) return color_1;
	if (type < 2.5) return color_2;
	if (type < 3.5) return color_3;
	if (type < 4.5) return color_4;
	if (type < 5.5) return color_5;
	if (type < 6.5) return color_6;
	return color_7;
}

void fragment() {
	// Board SDF
	vec2 half_size = vec2(0.5);
	float r = corner_radius;
	float sdf = board_sdf(UV - 0.5, half_size, r);
	float board_alpha = 1.0 - smoothstep(-edge_smoothness, edge_smoothness, sdf);

	if (board_alpha < 0.001)
		discard;

	// Edge proximity (0=center, 1=edge)
	float w = clamp(-sdf / 0.3, 0.0, 1.0);

	// ── Refraction warp (radial edge bulge, same as liquid glass buttons) ──
	vec2 uv_dir = length(UV - 0.5) > 0.001 ? normalize(UV - 0.5) : vec2(0.0, 1.0);
	float warp_falloff = exp(-warp_strength * pow(w, 2.0));
	vec2 warp_offset = uv_dir * warp_falloff * warp_intensity * 0.01;
	vec2 warped_uv = SCREEN_UV - warp_offset;

	// ── Chromatic aberration at edges ──
	float ca = w * chromatic_strength;
	vec2 chroma_offset = uv_dir * ca * SCREEN_PIXEL_SIZE;

	float bg_r = textureLod(bg_tex, warped_uv - chroma_offset, blur_amount).r;
	float bg_g = textureLod(bg_tex, warped_uv, blur_amount).g;
	float bg_b = textureLod(bg_tex, warped_uv + chroma_offset, blur_amount).b;
	vec3 bg = vec3(bg_r, bg_g, bg_b);

	// Tint
	vec3 color = mix(bg, glass_tint.rgb, glass_tint.a);

	// ── Rim light ──
	float rim = smoothstep(0.0, 0.06, w) * rim_intensity;
	color = mix(color, rim_color.rgb, rim * rim_color.a);

	// ── Top sheen ──
	float sheen = smoothstep(sheen_falloff, 0.0, UV.y) * sheen_intensity * (1.0 - w * 0.5);
	color += vec3(sheen);

	// ── Cell rendering on top ──
	vec2 grid_pos = UV * cell_count;
	vec2 cell_coord = floor(grid_pos);
	vec2 local_uv = fract(grid_pos);

	if (cell_coord.x >= 0.0 && cell_coord.x < cell_count.x &&
	    cell_coord.y >= 0.0 && cell_coord.y < cell_count.y) {

		vec2 pad_min = vec2(cell_padding);
		vec2 pad_max = vec2(1.0 - cell_padding);
		bool in_pad = local_uv.x < pad_min.x || local_uv.x > pad_max.x ||
		              local_uv.y < pad_min.y || local_uv.y > pad_max.y;

		if (in_pad) {
			// Grid line — slightly darker
			color *= 0.75;
		} else {
			float tex_u = cell_coord.x / 10.0;
			float tex_v = (cell_coord.y + vanish_offset) / 22.0;
			float piece_type = texture(board_tex, vec2(tex_u, tex_v)).r;

			vec4 cc = get_color(piece_type);
			if (cc.a > 0.01) {
				// Flat piece color on top of glass
				color = cc.rgb;

				// Flash
				if (flash_intensity > 0.01) {
					if (cell_coord.y == flash_rows.x || cell_coord.y == flash_rows.y ||
					    cell_coord.y == flash_rows.z || cell_coord.y == flash_rows.w) {
						color = mix(color, vec3(1.0), flash_intensity * 0.8);
					}
				}
				// Subtle highlight
				vec2 inner_uv = (local_uv - pad_min) / (pad_max - pad_min);
				color += smoothstep(0.6, 1.0, inner_uv.y) * 0.06;
			}
		}
	}

	COLOR = vec4(color, 1.0);
}
