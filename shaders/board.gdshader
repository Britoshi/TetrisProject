shader_type canvas_item;

// board.gdshader — Liquid glass board panel.
// All distances are computed in PIXELS (rect_size uniform), not UV,
// so tuning values mean what they say on any screen size.
//
// bg_tex is a pre-blurred, cover-fitted copy of the screen background
// baked on the CPU (see main.gd _bake_board_bg). It is sampled at
// SCREEN_UV, so it lines up 1:1 with the real background behind the
// board. No screen capture / SubViewport needed.

uniform sampler2D board_tex : repeat_disable, filter_nearest;
uniform sampler2D bg_tex : repeat_disable, filter_linear;

// Geometry (pixels)
uniform vec2 rect_size = vec2(320.0, 640.0);
uniform float corner_radius_px = 24.0;

// Grid
uniform vec2 cell_count = vec2(10.0, 20.0);
uniform float vanish_offset = 2.0;
uniform float cell_padding : hint_range(0.0, 0.2) = 0.04;

// Liquid glass (pixels unless noted)
uniform float blur_px : hint_range(0.0, 12.0) = 3.0;        // extra shader blur on top of baked blur
uniform float warp_band_px : hint_range(0.0, 300.0) = 80.0; // how far the edge lens reaches inward
uniform float warp_px : hint_range(0.0, 80.0) = 30.0;       // max refraction displacement at edge
uniform float chroma_px : hint_range(0.0, 20.0) = 6.0;      // chromatic aberration at edge
uniform float rim_width_px : hint_range(0.5, 10.0) = 2.5;
uniform float rim_intensity : hint_range(0.0, 2.0) = 0.9;
uniform float sheen_intensity : hint_range(0.0, 0.5) = 0.10;
uniform float sheen_falloff : hint_range(0.1, 1.0) = 0.35;
uniform vec4 glass_tint : source_color = vec4(0.05, 0.06, 0.12, 0.22);
uniform vec4 rim_color : source_color = vec4(1.0, 1.0, 1.0, 0.55);

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

// Squircle SDF (p, half-size, radius — all in pixels)
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
	// ── Shape (pixel space, origin at rect center) ──
	vec2 px = (UV - 0.5) * rect_size;
	float sdf = board_sdf(px, rect_size * 0.5, corner_radius_px);

	// 1.5px anti-aliased edge
	float board_alpha = 1.0 - smoothstep(-0.75, 0.75, sdf);
	if (board_alpha < 0.004)
		discard;

	// Edge proximity: 0 deep inside, 1 at the edge (within warp_band_px)
	float edge = clamp(1.0 + sdf / warp_band_px, 0.0, 1.0);
	// Cubic ramp = lens that bulges near the border, flat in the middle
	float lens = edge * edge * edge;

	vec2 dir = length(px) > 0.5 ? normalize(px) : vec2(0.0, 1.0);

	// ── Refraction: displace the background sample inward near edges ──
	vec2 base_uv = SCREEN_UV - dir * lens * warp_px * SCREEN_PIXEL_SIZE;

	// ── Frosted blur (9 taps; bg_tex is already pre-blurred) ──
	// Chromatic aberration grows toward the edge with the lens.
	vec2 chroma = dir * (0.3 + lens) * chroma_px * SCREEN_PIXEL_SIZE;
	vec3 bg = vec3(0.0);
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			vec2 o = vec2(float(x), float(y)) * blur_px * SCREEN_PIXEL_SIZE;
			bg.r += texture(bg_tex, base_uv + o - chroma).r;
			bg.g += texture(bg_tex, base_uv + o).g;
			bg.b += texture(bg_tex, base_uv + o + chroma).b;
		}
	}
	bg /= 9.0;

	// ── Glass tint (light, so the background stays visible) ──
	vec3 color = mix(bg, glass_tint.rgb, glass_tint.a);

	// ── Rim light: bright hairline just inside the edge ──
	float rim = 1.0 - smoothstep(0.0, rim_width_px, -sdf);
	color += rim_color.rgb * rim * rim_color.a * rim_intensity;

	// ── Top sheen ──
	float sheen = smoothstep(sheen_falloff, 0.0, UV.y) * sheen_intensity;
	color += vec3(sheen);

	// ── Cells on top of the glass ──
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
			// Grid line — slightly darker glass
			color *= 0.82;
		} else {
			float tex_u = (cell_coord.x + 0.5) / 10.0;
			float tex_v = (cell_coord.y + vanish_offset + 0.5) / 22.0;
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

	COLOR = vec4(color, board_alpha);
}
