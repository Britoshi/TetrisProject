shader_type canvas_item;

// board.gdshader — Liquid glass board panel (physically-flavored).
//
// The board is modeled as a thick glass slab with a circular beveled rim.
// Per-fragment we build the slab's surface normal from the squircle SDF
// gradient, then refract the view ray through it (Snell, IOR ~1.45) with
// per-channel dispersion. The refracted ray is projected onto the
// background plane, so the rim genuinely bends and magnifies what's
// behind it — the signature Liquid Glass rolled edge. Speculars come
// from a top-left key light and a weaker bottom-right counter glint.
//
// All distances are in PIXELS (rect_size uniform).
// bg_tex is a pre-blurred, cover-fitted copy of the screen background
// baked on the CPU (main.gd _bake_board_bg), sampled at SCREEN_UV.

uniform sampler2D board_tex : repeat_disable, filter_nearest;
uniform sampler2D bg_tex : repeat_disable, filter_linear_mipmap;

// Geometry (pixels)
uniform vec2 rect_size = vec2(320.0, 640.0);
uniform float corner_radius_px = 26.0;

// Grid
uniform vec2 cell_count = vec2(10.0, 20.0);
uniform float vanish_offset = 2.0;
uniform float cell_padding : hint_range(0.0, 0.2) = 0.04;

// Glass optics
uniform float bevel_px : hint_range(1.0, 300.0) = 70.0;      // rolled-edge width
uniform float thickness_px : hint_range(0.0, 400.0) = 90.0;  // slab thickness (refraction throw)
uniform float ior : hint_range(1.0, 2.0) = 1.45;
uniform float dispersion : hint_range(0.0, 0.2) = 0.04;      // per-channel IOR spread
uniform float frost_lod : hint_range(0.0, 6.0) = 1.8;        // interior frost (mip level)
uniform float dome : hint_range(0.0, 0.3) = 0.05;            // gentle whole-slab lens curvature
uniform float wave_strength : hint_range(0.0, 0.8) = 0.3;    // water surface tilt amplitude
uniform float wave_speed : hint_range(0.0, 4.0) = 1.0;
uniform float wave_scale : hint_range(0.2, 5.0) = 1.0;       // spatial frequency multiplier
uniform float glint_intensity : hint_range(0.0, 2.0) = 0.5;  // sun sparkle off the waves

// Splash ripples (piece locks). xy = center in board px (origin at rect
// center), z = age in seconds (< 0 inactive), w = amplitude.
uniform vec4 splashes[6];
uniform float splash_strength : hint_range(0.0, 2.0) = 0.7;
uniform float splash_speed_px : hint_range(50.0, 600.0) = 240.0; // ring expansion px/s
uniform float saturation : hint_range(0.5, 2.0) = 1.35;      // vibrancy
uniform float brightness : hint_range(0.5, 1.5) = 1.06;
uniform float spec_intensity : hint_range(0.0, 3.0) = 1.0;
uniform float rim_width_px : hint_range(0.5, 10.0) = 2.0;
uniform float sheen_intensity : hint_range(0.0, 0.5) = 0.05;
uniform float sheen_falloff : hint_range(0.1, 1.0) = 0.35;
uniform vec4 glass_tint : source_color = vec4(0.06, 0.08, 0.14, 0.15);
uniform vec4 rim_color : source_color = vec4(1.0, 1.0, 1.0, 0.8);

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

// Squircle SDF (p, half-size, radius — pixels)
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

// Refract the straight-down view ray through the slab surface and
// project it across the glass thickness onto the background plane.
vec2 refract_offset(vec3 n, float eta) {
	vec3 rd = refract(vec3(0.0, 0.0, -1.0), n, eta);
	return rd.xy / max(abs(rd.z), 0.35) * thickness_px;
}

void fragment() {
	// ── Shape (pixel space, origin at rect center) ──
	vec2 half_size = rect_size * 0.5;
	vec2 px = (UV - 0.5) * rect_size;
	float sdf = board_sdf(px, half_size, corner_radius_px);

	// 1.5px anti-aliased edge
	float board_alpha = 1.0 - smoothstep(-0.75, 0.75, sdf);
	if (board_alpha < 0.004)
		discard;

	// ── Surface normal of the glass slab ──
	// Lateral direction: SDF gradient (central differences, 1px step)
	float gx = board_sdf(px + vec2(1.0, 0.0), half_size, corner_radius_px)
	         - board_sdf(px - vec2(1.0, 0.0), half_size, corner_radius_px);
	float gy = board_sdf(px + vec2(0.0, 1.0), half_size, corner_radius_px)
	         - board_sdf(px - vec2(0.0, 1.0), half_size, corner_radius_px);
	vec2 grad = normalize(vec2(gx, gy) + vec2(1e-5, 0.0));

	// Circular bevel profile: normal tilts fully sideways at the rim,
	// flattens to straight-up over bevel_px.
	float bev = clamp(1.0 + sdf / bevel_px, 0.0, 1.0);
	vec2 lat = grad * bev;

	// ── Water surface: sum of travelling directional waves ──
	// Four octaves: slow swell (~300px), waves (~150px), chop (~75px),
	// fine ripple (~40px). Each tilts the surface normal along its
	// travel direction; the refraction below does the rest.
	float t = TIME * wave_speed;
	vec2 wp = px * wave_scale;
	vec2 water = vec2(0.0);
	water += vec2(0.83, 0.55) * cos(dot(wp, vec2(0.83, 0.55)) * 0.021 - t * 1.4) * 0.42;
	water += vec2(-0.60, 0.80) * cos(dot(wp, vec2(-0.60, 0.80)) * 0.041 + t * 2.0) * 0.28;
	water += vec2(0.31, -0.95) * cos(dot(wp, vec2(0.31, -0.95)) * 0.083 - t * 2.9) * 0.18;
	water += vec2(-0.95, -0.31) * cos(dot(wp, vec2(-0.95, -0.31)) * 0.150 + t * 3.7) * 0.12;
	water *= wave_strength;

	// ── Splash ripples: expanding damped rings where pieces land ──
	// Main ring + trailing wavelet + initial plunge dimple, like a drop
	// hitting the surface.
	vec2 splash_lat = vec2(0.0);
	float splash_glow = 0.0;
	for (int i = 0; i < 6; i++) {
		float age = splashes[i].z;
		float amp = splashes[i].w;
		if (age < 0.0 || amp <= 0.001) {
			continue;
		}
		vec2 d = px - splashes[i].xy;
		float dist = length(d);
		vec2 sdir = dist > 0.5 ? d / dist : vec2(0.0);
		float R = age * splash_speed_px;
		float damp = exp(-age * 2.0) * amp;
		float q1 = (dist - R) / 26.0;
		float q2 = (dist - R * 0.62) / 20.0;
		float ring = exp(-q1 * q1);
		float ring2 = 0.5 * exp(-q2 * q2);
		float plunge = exp(-dist * dist / 900.0) * clamp(1.0 - age * 6.0, 0.0, 1.0);
		splash_lat += sdir * (ring + ring2) * damp;
		splash_lat -= sdir * plunge * amp * 0.8;
		splash_glow += ring * damp;
	}

	// Gentle dome + water + splashes, fading out where the rim bevel takes over
	vec2 dome_dir = px / half_size;
	lat += (dome_dir * dome + water + splash_lat * splash_strength) * (1.0 - bev);

	// Cap lateral tilt and build the unit normal
	float lat_len = length(lat);
	lat *= min(1.0, 0.97 / max(lat_len, 1e-4));
	vec3 n = vec3(lat, sqrt(max(1.0 - dot(lat, lat), 0.001)));
	float nxy = length(lat);

	// ── Refraction with dispersion (separate IOR per channel) ──
	vec2 off_r = refract_offset(n, 1.0 / (ior - dispersion));
	vec2 off_g = refract_offset(n, 1.0 / ior);
	vec2 off_b = refract_offset(n, 1.0 / (ior + dispersion));

	// Rim shows SHARP bent content (that's what makes the lens readable);
	// interior is frosted via mip lod.
	float rim_w = smoothstep(0.15, 0.75, bev);
	float lod = mix(frost_lod, 0.3, rim_w);

	vec3 bg;
	bg.r = textureLod(bg_tex, SCREEN_UV + off_r * SCREEN_PIXEL_SIZE, lod).r;
	bg.g = textureLod(bg_tex, SCREEN_UV + off_g * SCREEN_PIXEL_SIZE, lod).g;
	bg.b = textureLod(bg_tex, SCREEN_UV + off_b * SCREEN_PIXEL_SIZE, lod).b;

	// ── Vibrancy: glass saturates and lifts what's behind it ──
	float luma = dot(bg, vec3(0.299, 0.587, 0.114));
	bg = clamp(mix(vec3(luma), bg, saturation) * brightness, 0.0, 1.0);

	// Light tint so the panel reads as material without hiding the bg
	vec3 color = mix(bg, glass_tint.rgb, glass_tint.a);

	// ── Speculars: key light top-left, counter glint bottom-right ──
	vec3 L1 = normalize(vec3(-0.4, -0.65, 0.65));
	vec3 L2 = normalize(vec3(0.4, 0.65, 0.5));
	float spec = pow(max(dot(n, L1), 0.0), 24.0)
	           + 0.55 * pow(max(dot(n, L2), 0.0), 24.0);

	// Sun glint: broad sparkle where wave crests tilt toward the key light
	float glint = pow(max(dot(n, L1), 0.0), 10.0) * glint_intensity;

	// Fresnel-ish bright band hugging the whole rim
	float fresnel = pow(nxy, 3.0) * 0.16;

	// Hairline at the very edge
	float hairline = (1.0 - smoothstep(0.0, rim_width_px, -sdf)) * 0.25;

	color += rim_color.rgb * rim_color.a *
	         (spec * spec_intensity + glint + fresnel + hairline +
	          splash_glow * 0.25);

	// ── Faint top sheen ──
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
			// Grid line — barely-there etched line, keeps the slab feel
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

	COLOR = vec4(color, board_alpha);
}
