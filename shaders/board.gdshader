shader_type canvas_item;

// board.gdshader — Liquid glass board, SAME FX pipeline as the buttons
// (liquid_glass.gdshader): Gaussian edge warp, textureLod blur,
// chromatic aberration, rim light, border stroke, top sheen.
//
// Differences from the button (only where they must differ):
//  - The SDF is the union of the outer rounded rect AND the locked
//    stack contour (blocks are walls), read from board_tex.
//  - bg_tex is a pre-baked mipmapped copy of the background sampled at
//    SCREEN_UV (screen_texture doesn't work reliably on this platform).
//  - Water waves + piece-lock splash ripples add to warp_offset the
//    same way the button's wobble/ripple effects do.
//  - Ghost drop preview is a see-through tinted cutout.

uniform sampler2D board_tex : repeat_disable, filter_nearest;
uniform sampler2D bg_tex : repeat_disable, filter_linear_mipmap;

// ── Shape (pixels) ──
uniform vec2 rect_size = vec2(320.0, 640.0);
uniform float corner_radius_px = 26.0;

// ── Grid ──
uniform vec2 cell_count = vec2(10.0, 20.0);
uniform float vanish_offset = 2.0;
uniform float cell_padding : hint_range(0.0, 0.2) = 0.04;

// ── Glass body (button-identical) ──
uniform float blur_amount : hint_range(0.0, 8.0) = 2.5;
uniform vec4 glass_tint : source_color = vec4(0.06, 0.08, 0.14, 0.15);
uniform float warp_intensity : hint_range(0.0, 1.0) = 0.25;
uniform float warp_strength : hint_range(0.0, 30.0) = 10.0;

// ── Edge / border (button-identical) ──
uniform float border_width : hint_range(0.0, 8.0) = 1.5;
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 0.45);
uniform float rim_intensity : hint_range(0.0, 1.0) = 0.5;

// ── Chromatic aberration (button-identical) ──
uniform float chromatic_strength : hint_range(0.0, 5.0) = 3.0;

// ── Top specular sheen (button-identical) ──
uniform float sheen_intensity : hint_range(0.0, 0.5) = 0.10;
uniform float sheen_falloff : hint_range(0.2, 0.8) = 0.4;

// ── Water waves (add to warp_offset like the button wobble) ──
uniform float wave_strength : hint_range(0.0, 0.8) = 0.3;
uniform float wave_speed : hint_range(0.0, 4.0) = 1.0;
uniform float wave_scale : hint_range(0.2, 5.0) = 1.0;

// ── Splash ripples (piece locks; shaped by the piece's cells) ──
// meta: x = age s (< 0 inactive), y = amplitude, z = cell half-size px.
uniform vec4 splash_meta[6];
uniform vec4 splash_cells_a[6];
uniform vec4 splash_cells_b[6];
uniform float splash_strength : hint_range(0.0, 2.0) = 0.7;
uniform float splash_speed_px : hint_range(50.0, 600.0) = 240.0;

// ── Ghost hole (drop preview cutout) ──
uniform float ghost_active = 0.0;
uniform vec4 ghost_cells_a = vec4(0.0);
uniform vec4 ghost_cells_b = vec4(0.0);
uniform float ghost_half = 12.0;
uniform float ghost_round = 4.0;
uniform float hole_bevel_px : hint_range(1.0, 200.0) = 34.0;
uniform float hole_tilt : hint_range(0.0, 1.0) = 0.35;
uniform vec4 ghost_color : source_color = vec4(1.0, 1.0, 1.0, 0.28);

// ── Piece colors ──
uniform vec4 color_1 : source_color = vec4(0.0, 0.88, 0.88, 1.0);
uniform vec4 color_2 : source_color = vec4(1.0, 0.84, 0.0, 1.0);
uniform vec4 color_3 : source_color = vec4(0.63, 0.13, 0.94, 1.0);
uniform vec4 color_4 : source_color = vec4(0.0, 0.82, 0.32, 1.0);
uniform vec4 color_5 : source_color = vec4(0.89, 0.1, 0.11, 1.0);
uniform vec4 color_6 : source_color = vec4(0.0, 0.47, 0.95, 1.0);
uniform vec4 color_7 : source_color = vec4(1.0, 0.55, 0.0, 1.0);

// ── Flash ──
uniform vec4 flash_rows = vec4(-1.0);
uniform float flash_intensity : hint_range(0.0, 1.0) = 0.0;

// ── Squircle SDF (identical to the button's rounded_box_sdf) ──
float rounded_box_sdf(vec2 p, vec2 b, float r) {
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

// Plain box SDF (no gradient)
float box_sdf(vec2 rel, float hc) {
	vec2 q = abs(rel) - vec2(hc);
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
}

// SDF of the ghost hole: union of its 4 cells, corners rounded
float hole_sdf(vec2 p) {
	if (ghost_active < 0.5)
		return 1e6;
	float d = box_sdf(p - ghost_cells_a.xy, ghost_half);
	d = min(d, box_sdf(p - ghost_cells_a.zw, ghost_half));
	d = min(d, box_sdf(p - ghost_cells_b.xy, ghost_half));
	d = min(d, box_sdf(p - ghost_cells_b.zw, ghost_half));
	return d - ghost_round;
}

// Accumulate signed distance (+gradient) to one splash/wall cell —
// an axis-aligned square of half-size hc. Union via min.
void cell_sdf(vec2 rel, float hc, inout float sd, inout vec2 sg) {
	vec2 q = abs(rel) - vec2(hc);
	float dj;
	vec2 gj;
	if (max(q.x, q.y) > 0.0) {
		vec2 qc = max(q, vec2(0.0));
		dj = length(qc);
		gj = sign(rel) * qc / max(dj, 1e-4);
	} else {
		dj = max(q.x, q.y);
		gj = q.x > q.y ? vec2(sign(rel.x), 0.0) : vec2(0.0, sign(rel.y));
	}
	if (dj < sd) {
		sd = dj;
		sg = gj;
	}
}

// Distance (+gradient) from p to the nearest locked block among the
// 3x3 cells around cc0. sd stays huge when no block is near.
void wall_field(vec2 p, vec2 cc0, out float sd, out vec2 sg) {
	sd = 1e6;
	sg = vec2(0.0, 1.0);
	vec2 cell_px = rect_size / cell_count;
	float hc = min(cell_px.x, cell_px.y) * 0.5;
	for (int j = -1; j <= 1; j++) {
		for (int k = -1; k <= 1; k++) {
			vec2 cc = cc0 + vec2(float(j), float(k));
			if (cc.x < 0.0 || cc.x >= cell_count.x ||
			    cc.y < 0.0 || cc.y >= cell_count.y) {
				continue;
			}
			float ptype = texture(board_tex,
				vec2((cc.x + 0.5) / 10.0, (cc.y + vanish_offset + 0.5) / 22.0)).r;
			if (ptype < 0.5) {
				continue;
			}
			vec2 center = ((cc + 0.5) / cell_count - 0.5) * rect_size;
			cell_sdf(p - center, hc, sd, sg);
		}
	}
}

void fragment() {
	// ── Pixel space (origin at rect center) ──
	vec2 half_size = rect_size * 0.5;
	vec2 px = (UV - 0.5) * rect_size;

	// Outer rounded rect
	float bsdf = rounded_box_sdf(px, half_size, corner_radius_px);
	float shape_alpha = 1.0 - smoothstep(-1.0, 1.0, bsdf);
	if (shape_alpha < 0.001)
		discard;

	// Locked stack = walls. Union with the outer boundary.
	vec2 grid_pos = UV * cell_count;
	vec2 cell_coord = floor(grid_pos);
	float wall_sd;
	vec2 wall_g;
	wall_field(px, cell_coord, wall_sd, wall_g);
	float sdf = max(bsdf, -wall_sd); // glass SDF: walls cut in like edges

	// w: 0 at any wall, 1 in open water (button formula)
	float max_dist = min(half_size.x, half_size.y) * 0.5;
	float w = clamp(-sdf / max_dist, 0.0, 1.0);

	// Direction toward the nearest wall (button: radial from center)
	float gx = rounded_box_sdf(px + vec2(1.0, 0.0), half_size, corner_radius_px)
	         - rounded_box_sdf(px - vec2(1.0, 0.0), half_size, corner_radius_px);
	float gy = rounded_box_sdf(px + vec2(0.0, 1.0), half_size, corner_radius_px)
	         - rounded_box_sdf(px - vec2(0.0, 1.0), half_size, corner_radius_px);
	vec2 grad_o = normalize(vec2(gx, gy) + vec2(1e-5, 0.0));
	vec2 uv_dir = (-bsdf) <= wall_sd ? grad_o : -wall_g;

	// ── Refraction warp (button-identical Gaussian edge bulge) ──
	float warp_falloff = exp(-warp_strength * w * w);
	vec2 warp_offset = uv_dir * warp_falloff * warp_intensity / 10.0;

	// ── Water waves: travelling ripples add to warp_offset ──
	float t = TIME * wave_speed;
	vec2 wp = px * wave_scale;
	vec2 water = vec2(0.0);
	water += vec2(0.83, 0.55) * cos(dot(wp, vec2(0.83, 0.55)) * 0.021 - t * 1.4) * 0.42;
	water += vec2(-0.60, 0.80) * cos(dot(wp, vec2(-0.60, 0.80)) * 0.041 + t * 2.0) * 0.28;
	water += vec2(0.31, -0.95) * cos(dot(wp, vec2(0.31, -0.95)) * 0.083 - t * 2.9) * 0.18;
	water += vec2(-0.95, -0.31) * cos(dot(wp, vec2(-0.95, -0.31)) * 0.150 + t * 3.7) * 0.12;
	warp_offset += water * wave_strength * 0.05;

	// ── Splash ripples: piece-shaped wavefronts add to warp_offset ──
	float splash_glow = 0.0;
	for (int i = 0; i < 6; i++) {
		float age = splash_meta[i].x;
		float amp = splash_meta[i].y;
		if (age < 0.0 || amp <= 0.001) {
			continue;
		}
		float hc = splash_meta[i].z;
		float sd = 1e6;
		vec2 sg = vec2(0.0, 1.0);
		cell_sdf(px - splash_cells_a[i].xy, hc, sd, sg);
		cell_sdf(px - splash_cells_a[i].zw, hc, sd, sg);
		cell_sdf(px - splash_cells_b[i].xy, hc, sd, sg);
		cell_sdf(px - splash_cells_b[i].zw, hc, sd, sg);

		float R = age * splash_speed_px;
		float damp = exp(-age * 2.0) * amp;
		float dpos = max(sd, 0.0);
		float q1 = (dpos - R) / 24.0;
		float q2 = (dpos - R * 0.62) / 18.0;
		float ring = exp(-q1 * q1);
		float ring2 = 0.5 * exp(-q2 * q2);
		float inside = clamp(-sd / max(hc, 1.0), 0.0, 1.0);
		float plunge = (inside + 0.5 * exp(-dpos * dpos / 400.0))
		             * clamp(1.0 - age * 5.0, 0.0, 1.0);
		warp_offset += sg * (ring + ring2 - plunge) * damp * splash_strength * 0.05;
		splash_glow += ring * damp;
	}

	// ── Ghost hole rim: gentle pull toward the cutout ──
	float hs = hole_sdf(px);
	if (ghost_active > 0.5) {
		float hx = hole_sdf(px + vec2(1.0, 0.0)) - hole_sdf(px - vec2(1.0, 0.0));
		float hy = hole_sdf(px + vec2(0.0, 1.0)) - hole_sdf(px - vec2(0.0, 1.0));
		vec2 grad_h = -normalize(vec2(hx, hy) + vec2(1e-5, 0.0));
		float bev_hole = clamp(1.0 - hs / hole_bevel_px, 0.0, 1.0);
		bev_hole *= bev_hole;
		warp_offset += grad_h * bev_hole * hole_tilt * 0.05;
	}

	vec2 warped_uv = SCREEN_UV - warp_offset;

	// ── Chromatic aberration (button-identical R/B split near walls) ──
	float edge_proximity = 1.0 - w;
	float ca = edge_proximity * chromatic_strength;
	vec2 chroma_offset = uv_dir * ca * SCREEN_PIXEL_SIZE;

	float bg_r = textureLod(bg_tex, warped_uv - chroma_offset, blur_amount).r;
	float bg_g = textureLod(bg_tex, warped_uv, blur_amount).g;
	float bg_b = textureLod(bg_tex, warped_uv + chroma_offset, blur_amount).b;
	vec3 bg = vec3(bg_r, bg_g, bg_b);

	// ── Tint the glass (button-identical) ──
	vec3 color = mix(bg, glass_tint.rgb, glass_tint.a);

	// ── Edge rim light (button-identical, traces walls too) ──
	float rim = (1.0 - smoothstep(0.0, border_width, -sdf)) * step(sdf, 0.0);
	rim *= rim_intensity;
	color = mix(color, border_color.rgb, rim * border_color.a);

	// ── Border stroke (button-identical, traces walls too) ──
	float border = 1.0 - smoothstep(border_width - 1.5, border_width + 1.5, abs(sdf));
	color = mix(color, border_color.rgb, border * border_color.a);

	// ── Top specular sheen (button-identical) ──
	float sheen = smoothstep(sheen_falloff, 0.0, UV.y) * sheen_intensity * (1.0 - w * 0.6);
	color += vec3(sheen);

	// Splash crest gleam
	color += border_color.rgb * splash_glow * 0.2;

	// ── Cells on top of the glass ──
	vec2 local_uv = fract(grid_pos);
	if (cell_coord.x >= 0.0 && cell_coord.x < cell_count.x &&
	    cell_coord.y >= 0.0 && cell_coord.y < cell_count.y) {

		vec2 pad_min = vec2(cell_padding);
		vec2 pad_max = vec2(1.0 - cell_padding);
		bool in_pad = local_uv.x < pad_min.x || local_uv.x > pad_max.x ||
		              local_uv.y < pad_min.y || local_uv.y > pad_max.y;

		if (in_pad) {
			// Grid line — barely-there etched line
			color *= 0.9;
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

	// ── Ghost hole: see-through window with a piece-color wash ──
	float hole_mask = (1.0 - smoothstep(-0.75, 0.75, hs)) * shape_alpha;
	color = mix(color, ghost_color.rgb, hole_mask);
	float alpha_out = mix(shape_alpha, ghost_color.a, hole_mask);

	COLOR = vec4(color, alpha_out);
}
