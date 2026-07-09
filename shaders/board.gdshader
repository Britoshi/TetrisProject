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
uniform float bg_dim : hint_range(0.0, 1.0) = 0.35;
uniform float blur_amount : hint_range(0.0, 8.0) = 2.5;
uniform vec4 glass_tint : source_color = vec4(0.06, 0.08, 0.14, 0.15);
uniform float warp_intensity : hint_range(0.0, 2.0) = 0.25;
uniform float warp_strength : hint_range(0.0, 30.0) = 10.0;
// Meniscus around locked blocks — MUST stay small: wall_field only sees a
// 3x3 cell window, so this warp has to die out within one cell.
uniform float wall_warp_intensity : hint_range(0.0, 2.0) = 0.3;

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
// Pulsing emissive rim around the ghost hole (HDR: crosses the bloom
// threshold like the blocks do, so the drop target visibly glows)
uniform float ghost_rim_px : hint_range(0.5, 12.0) = 3.0;
uniform float ghost_glow : hint_range(0.0, 4.0) = 1.6;
uniform float ghost_pulse_speed : hint_range(0.0, 10.0) = 3.0;

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

// ── Block emission: blocks output HDR (> 1.25) so ONLY they bloom ──
uniform float block_emission : hint_range(0.0, 4.0) = 1.2;

// ── Locked blocks as individual liquid-glass tiles ──
// Face = refracted bg + piece tint; rim = HDR piece color (bloom hugs edges)
uniform float block_tint_alpha : hint_range(0.0, 1.0) = 0.65;
uniform float block_warp_intensity : hint_range(0.0, 2.0) = 0.15;
// 0 = each block keeps its flat color; 1 = colors melt into neighbors
uniform float block_color_blend : hint_range(0.0, 1.0) = 0.4;
// Width of the color-blend seam, in cells (0.5 = full bilinear smear)
uniform float block_blend_band : hint_range(0.02, 0.5) = 0.14;

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

// (piece type, same-piece connectivity mask) for a visible-grid cell.
// Mask bits: 1 = left, 2 = right, 4 = up, 8 = down.
vec2 cell_data(vec2 cc) {
	return texture(board_tex,
		vec2((cc.x + 0.5) / 10.0, (cc.y + vanish_offset + 0.5) / 22.0)).rg;
}

// True rounded SDF of the fused mass, evaluated from one cell using its
// 8-neighbourhood (marching-squares style). Each pixel is rendered by its
// own cell, and this returns the exact signed distance to the mass outline
// in that pixel's quadrant — so CONVEX corners round out, CONCAVE corners
// fillet IN, fused seams vanish, and there are no min-union notches at
// bends (the artifact the box-union approach couldn't avoid). Walls sit at
// the cell edge; the whole mass is inset by one uniform pad in the fragment.
float mass_sdf(vec2 px, vec2 cc, int mask, float r) {
	vec2 cd = rect_size / cell_count;
	vec2 hc = cd * 0.5;
	vec2 center = ((cc + 0.5) / cell_count - 0.5) * rect_size;
	vec2 p = px - center;
	float qx = p.x >= 0.0 ? 1.0 : -1.0;
	float qy = p.y >= 0.0 ? 1.0 : -1.0;
	int bitX = qx > 0.0 ? 2 : 1;   // right : left
	int bitY = qy > 0.0 ? 8 : 4;   // down : up
	bool fx = (mask & bitX) != 0;  // this cell fused on the x-side?
	bool fy = (mask & bitY) != 0;  // fused on the y-side?
	vec2 lp = abs(p);              // corner of the cell is at hc

	if (!fx && !fy) {
		// Convex corner — squircle-rounded, radius r
		vec2 q = lp - hc + r;
		float dd = min(max(q.x, q.y), 0.0);
		vec2 qc = max(q, vec2(0.0));
		float cdst = pow(pow(qc.x, 2.5) + pow(qc.y, 2.5), 1.0 / 2.5);
		return dd + cdst - r;
	}
	if (!fx) {           // wall on the x-side only → straight vertical edge
		return lp.x - hc.x;
	}
	if (!fy) {           // wall on the y-side only → straight horizontal edge
		return lp.y - hc.y;
	}
	// Both sides fused. If the diagonal fills the corner it's interior;
	// otherwise it's a reentrant (concave) corner → fillet radius r.
	int nmaskX = int(cell_data(cc + vec2(qx, 0.0)).g + 0.5);
	bool diag_filled = (nmaskX & bitY) != 0;   // x-neighbour reaches the diagonal
	if (diag_filled) {
		return -min(hc.x, hc.y);   // deep interior
	}
	// Concave (reentrant) corner: the mass is the UNION of the two fused
	// half-cells {x<=hc} ∪ {y<=hc}; round that union's inner corner by r
	// (opUnionRound). This fillets ONLY the corner — the cell interior stays
	// deep-negative, so no triangular chunk is carved out.
	float a = lp.x - hc.x;
	float b = lp.y - hc.y;
	vec2 u = max(vec2(r - a, r - b), vec2(0.0));
	return max(r, min(a, b)) - length(u);
}

// Occupied-weighted bilinear blend of the four nearest cells' piece colors.
// Gives smooth color gradients across fused blocks; renormalizes near empty
// neighbors so lone blocks keep their own color.
vec3 blended_block_color(vec2 gp) {
	vec2 base = floor(gp - 0.5);
	vec2 f = fract(gp - 0.5);
	// f = 0.5 is a cell boundary, f = 0/1 is a cell center. Sharpen so the
	// blend is confined to a narrow seam of width block_blend_band around
	// each boundary instead of smearing across the full cell (bilinear).
	vec2 b = vec2(block_blend_band);
	f = smoothstep(0.5 - b, 0.5 + b, f);
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	for (int i = 0; i < 2; i++) {
		for (int j = 0; j < 2; j++) {
			vec2 cc = base + vec2(float(i), float(j));
			vec4 col = get_color(cell_data(cc).r);
			if (col.a > 0.01) {
				float wgt = (i == 0 ? 1.0 - f.x : f.x) * (j == 0 ? 1.0 - f.y : f.y);
				acc += col.rgb * wgt;
				wsum += wgt;
			}
		}
	}
	return wsum > 1e-4 ? acc / wsum : vec3(0.0);
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
// 3x3 cells around cc0, plus that block's piece type (for glow color).
// sd stays huge when no block is near.
void wall_field(vec2 p, vec2 cc0, out float sd, out vec2 sg, out float ntype) {
	sd = 1e6;
	sg = vec2(0.0, 1.0);
	ntype = 0.0;
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
			float prev = sd;
			cell_sdf(p - center, hc, sd, sg);
			if (sd < prev) {
				ntype = ptype;
			}
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
	float near_type;
	wall_field(px, cell_coord, wall_sd, wall_g, near_type);
	// Separate proximity fields. The rim lens spans the whole board, but
	// wall_field only sees a 3x3 cell window — the wall term must decay to
	// zero INSIDE that window (< 1 cell) or its cutoff shows up as hard
	// per-tile creases in both the warp and the blur.
	float max_dist = min(half_size.x, half_size.y) * 0.5;
	vec2 cell_dim = rect_size / cell_count;
	float wall_range = 0.9 * min(cell_dim.x, cell_dim.y);
	float w_rim = clamp(-bsdf / max_dist, 0.0, 1.0);
	float w_wall = clamp(wall_sd / wall_range, 0.0, 1.0);
	// Union proximity (0 at rim or block, 1 in open water): blur/chroma/sheen
	float w = min(w_rim, w_wall);

	// Direction toward the nearest wall. NOT the SDF gradient: a box SDF's
	// gradient is piecewise-constant and flips across the corner diagonals,
	// which the strong warp turns into a visible crease. The aspect-
	// normalized radial field (what the buttons use) is continuous.
	vec2 grad_o = normalize(px / half_size + vec2(1e-5, 0.0));
	vec2 uv_dir = w_rim <= w_wall ? grad_o : -wall_g;

	// ── Refraction warp: big lens at the rim, tight meniscus at blocks ──
	float rim_fall = exp(-warp_strength * w_rim * w_rim);
	float wall_fall = exp(-8.0 * w_wall * w_wall) * (1.0 - w_wall);
	vec2 warp_offset = grad_o * rim_fall * warp_intensity / 10.0
	                 + (-wall_g) * wall_fall * wall_warp_intensity / 10.0;

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

	// Per-pixel blur: SHARP at the refracting rim (and around the locked
	// stack, which is also "edge") so the bent content is recognizable —
	// this is what makes the lens read as liquid — frosted in the interior.
	float lod = blur_amount * smoothstep(0.03, 0.45, w);
	float bg_r = textureLod(bg_tex, warped_uv - chroma_offset, lod).r;
	float bg_g = textureLod(bg_tex, warped_uv, lod).g;
	float bg_b = textureLod(bg_tex, warped_uv + chroma_offset, lod).b;
	vec3 bg = vec3(bg_r, bg_g, bg_b) * (1.0 - bg_dim);

	// ── Tint the glass (button-identical) ──
	vec3 color = mix(bg, glass_tint.rgb, glass_tint.a);

	// ── Edge rim light (outer boundary only — each glass tile draws its
	// own rim, so tracing the walls here would double-outline every block) ──
	float rim = (1.0 - smoothstep(0.0, border_width, -bsdf)) * step(bsdf, 0.0);
	rim *= rim_intensity;
	color = mix(color, border_color.rgb, rim * border_color.a);

	// ── Border stroke (outer boundary only) ──
	float border = 1.0 - smoothstep(border_width - 1.5, border_width + 1.5, abs(bsdf));
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

		// ── Locked pieces: one merged liquid-glass container per piece ──
		// Cells of the same tetromino fuse into a single rounded shape
		// (the SDF fills the padding gaps between connected cells).
		vec2 cdata = cell_data(cell_coord);
		vec4 cc = get_color(cdata.r);
		int cmask = int(cdata.g + 0.5);
		float rr = 0.28 * min(cell_dim.x, cell_dim.y);
		float tile_sdf = 1e6;
		float raw_sdf = 1e6;
		float tile_alpha = 0.0;
		// One uniform pad inset of the WHOLE merged mass (not per-cell), so
		// concave junctions stay clean instead of stepping.
		float pad_px = cell_padding * min(cell_dim.x, cell_dim.y);
		if (cc.a > 0.01) {
			raw_sdf = mass_sdf(px, cell_coord, cmask, rr);
			tile_sdf = raw_sdf + pad_px;
			tile_alpha = 1.0 - smoothstep(-0.75, 0.75, tile_sdf);
		}

		// Grid line — barely-there etched line, hidden under glass
		if (in_pad) {
			color *= mix(0.9, 1.0, tile_alpha);
		}

		if (tile_alpha > 0.001) {
			// Lens direction from the merged surface (numerical gradient)
			// so refraction flows continuously across the whole piece
			float dgx = mass_sdf(px + vec2(1.0, 0.0), cell_coord, cmask, rr) - raw_sdf;
			float dgy = mass_sdf(px + vec2(0.0, 1.0), cell_coord, cmask, rr) - raw_sdf;
			vec2 dirc = normalize(vec2(dgx, dgy) + vec2(1e-5, 0.0));

			// Piece color, optionally melted into the neighbors' colors
			vec3 piece_col = mix(cc.rgb, blended_block_color(grid_pos), block_color_blend);

			float half_min = min(cell_dim.x, cell_dim.y) * 0.5;
			float wc = clamp(-tile_sdf / half_min, 0.0, 1.0);
			float fallc = exp(-8.0 * wc * wc);
			vec2 tuv = SCREEN_UV - dirc * fallc * block_warp_intensity / 10.0;
			float tlod = blur_amount * 0.35;
			vec3 tbg = vec3(
				textureLod(bg_tex, tuv - chroma_offset, tlod).r,
				textureLod(bg_tex, tuv, tlod).g,
				textureLod(bg_tex, tuv + chroma_offset, tlod).b);
			vec3 tile_col = mix(tbg, piece_col, block_tint_alpha);

			// Rim stroke in HDR piece color: the bloom traces the merged
			// outline of the whole piece. Interior-side band only — the
			// union SDF overestimates EXTERIOR distance at reentrant
			// (concave) corners, which breaks a two-sided abs() rim there.
			float rimc = (1.0 - smoothstep(0.0, 3.5, -tile_sdf)) * step(tile_sdf, 0.0);
			tile_col = mix(tile_col, piece_col * (1.0 + block_emission), rimc * 0.85);

			// Top sheen — only on cells whose top edge is exposed
			if ((cmask & 4) == 0) {
				vec2 inner_uv = (local_uv - pad_min) / (pad_max - pad_min);
				tile_col += smoothstep(0.35, 0.0, inner_uv.y) * 0.08;
			}

			// Flash
			if (flash_intensity > 0.01) {
				if (cell_coord.y == flash_rows.x || cell_coord.y == flash_rows.y ||
				    cell_coord.y == flash_rows.z || cell_coord.y == flash_rows.w) {
					tile_col = mix(tile_col, vec3(2.0), flash_intensity * 0.8);
				}
			}
			color = mix(color, tile_col, tile_alpha);
		}
	}

	// ── Ghost hole: see-through window with a piece-color wash ──
	float hole_mask = (1.0 - smoothstep(-0.75, 0.75, hs)) * shape_alpha;
	float pulse = 0.75 + 0.25 * sin(TIME * ghost_pulse_speed);
	color = mix(color, ghost_color.rgb * (0.8 + 0.4 * pulse), hole_mask);
	float alpha_out = mix(shape_alpha, ghost_color.a, hole_mask);

	// Emissive rim traces the hole outline; pulses to draw the eye
	float ghost_rim = (1.0 - smoothstep(0.0, ghost_rim_px, abs(hs))) * shape_alpha;
	vec3 rim_hdr = ghost_color.rgb * (1.0 + ghost_glow * pulse);
	color = mix(color, rim_hdr, ghost_rim);
	alpha_out = max(alpha_out, ghost_rim);

	COLOR = vec4(color, alpha_out);
}
