shader_type canvas_item;

// Liquid Glass button shader — iOS 26 Liquid Glass style.
// Screen-space blur, chromatic aberration, rim light, specular sheen,
// squircle corners, and waterdrop wobble press effect.

uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

// ── Shape ──
uniform float corner_radius : hint_range(0.0, 0.5) = 0.15;
uniform float edge_smoothness : hint_range(0.5, 3.0) = 1.0;

// ── Glass body ──
uniform float blur_amount : hint_range(0.0, 8.0) = 2.5;
uniform vec4 tint : source_color = vec4(0.2, 0.25, 0.5, 0.55);
uniform float warp_intensity : hint_range(0.0, 1.0) = 0.25;
uniform float warp_strength : hint_range(0.0, 30.0) = 10.0;

// ── Edge / border ──
uniform float border_width : hint_range(0.0, 8.0) = 1.5;
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 0.45);
uniform float rim_intensity : hint_range(0.0, 1.0) = 0.5;

// ── Chromatic aberration (light dispersion at glass edges) ──
uniform float chromatic_strength : hint_range(0.0, 5.0) = 3.0;

// ── Top specular sheen ──
uniform float sheen_intensity : hint_range(0.0, 0.5) = 0.10;
uniform float sheen_falloff : hint_range(0.2, 0.8) = 0.4;

// ── Press state (static) ──
uniform float pressed : hint_range(0.0, 1.0) = 0.0;
uniform vec4 glow_color : source_color = vec4(1.0, 0.9, 0.5, 0.7);

// ── Waterdrop wobble press effect ──
// touch_uv: UV of the touch point (-1 = no touch). driven by mobile_controls.gd.
uniform vec2 touch_uv = vec2(-1.0);
// touch_depth: how deep the depression is (0 = none, 1 = fully pressed).
// Driven by spring animation in GDScript.
uniform float touch_depth : hint_range(0.0, 1.2) = 0.0;
// touch_time: TIME value when last press/release happened, for ripple animation.
uniform float touch_time = -10.0;


// ── Signed distance field for continuous-corner rounded rectangle ──
// Squircle blend (exponent 2.5) for Apple-style smooth corners.
float rounded_box_sdf(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	float d = min(max(q.x, q.y), 0.0);
	vec2 corner = max(q, vec2(0.0));
	float corner_dist = pow(pow(corner.x, 2.5) + pow(corner.y, 2.5), 1.0 / 2.5);
	return d + corner_dist - r;
}


void fragment() {
	// ── Derive pixel size from UV gradients ──
	float dx = dFdx(UV.x);
	float dy = dFdy(UV.y);
	dx = sign(dx) * max(abs(dx), 0.0001);
	dy = sign(dy) * max(abs(dy), 0.0001);
	vec2 size = abs(vec2(1.0 / dx, 1.0 / dy));
	size = clamp(size, vec2(1.0), vec2(4096.0));

	vec2 half_size = size * 0.5;
	vec2 pixel = UV * size;
	vec2 centered = pixel - half_size;

	float max_r = min(half_size.x, half_size.y);
	float r = corner_radius * max_r;

	// ── SDF evaluation ──
	float sdf = rounded_box_sdf(centered, half_size, r);
	float shape_alpha = 1.0 - smoothstep(-edge_smoothness, edge_smoothness, sdf);

	if (shape_alpha < 0.001) {
		discard;
	}

	// w = normalized distance from center (0 at center, 1 at edge)
	float max_dist = min(half_size.x, half_size.y) * 0.5;
	float w = clamp(-sdf / max_dist, 0.0, 1.0);

	// ── Refraction warp (radial edge bulge) ──
	vec2 uv_dir = length(centered) > 0.001 ? normalize(centered) : vec2(0.0, 1.0);
	float warp_falloff = exp(-warp_strength * pow(w, 2.0));
	vec2 warp_offset = uv_dir * warp_falloff * warp_intensity / 10.0;

	// ── Waterdrop wobble: touch depression + release ripple ──
	float touch_dist = length(UV - touch_uv);
	float touch_ca_boost = 0.0;

	if (touch_uv.x >= 0.0 && touch_depth > 0.005) {
		// Depression: inward bulge that fades with distance from touch point.
		// Like pressing your finger into a water droplet surface.
		float depress_radius = 0.08 + touch_depth * 0.04;
		float depression = exp(-touch_dist * touch_dist / (depress_radius * depress_radius)) * touch_depth;
		vec2 touch_dir = touch_dist > 0.001 ? (touch_uv - UV) / touch_dist : vec2(0.0);
		warp_offset += touch_dir * depression * 0.025;

		// Ripple: expanding ring on press/release, driven by time since event.
		float time_since = TIME - touch_time;
		float ripple_life = clamp(time_since * 3.5, 0.0, 1.0); // 0→1 over ~0.3s
		float ripple_radius = ripple_life * 0.55;
		float ripple_width = 0.035 * (1.0 - ripple_life * 0.7);
		float ripple = smoothstep(ripple_radius - ripple_width, ripple_radius, touch_dist)
		             - smoothstep(ripple_radius, ripple_radius + ripple_width, touch_dist);
		// Ripple fades as it expands (energy dissipates)
		ripple *= (1.0 - ripple_life) * 0.7 * touch_depth;
		warp_offset += touch_dir * ripple * 0.015;

		// Secondary ripple (smaller, follows primary)
		float ripple2_radius = ripple_radius - 0.08;
		if (ripple2_radius > 0.0) {
			float ripple2 = smoothstep(ripple2_radius - ripple_width * 0.8, ripple2_radius, touch_dist)
			              - smoothstep(ripple2_radius, ripple2_radius + ripple_width * 0.6, touch_dist);
			ripple2 *= (1.0 - ripple_life) * 0.35 * touch_depth;
			warp_offset += touch_dir * ripple2 * 0.01;
		}

		// Chromatic aberration intensifies near touch point (applied below)
		touch_ca_boost = exp(-touch_dist * touch_dist * 80.0) * touch_depth * 1.5;
	}

	vec2 warped_uv = SCREEN_UV - warp_offset;

	// ── Chromatic aberration (R/B split near edges) ──
	float edge_proximity = 1.0 - w;
	float ca = edge_proximity * chromatic_strength + touch_ca_boost;
	vec2 chroma_offset = uv_dir * ca * SCREEN_PIXEL_SIZE;

	float bg_r = textureLod(screen_texture, warped_uv - chroma_offset, blur_amount).r;
	float bg_g = textureLod(screen_texture, warped_uv, blur_amount).g;
	float bg_b = textureLod(screen_texture, warped_uv + chroma_offset, blur_amount).b;
	vec3 bg = vec3(bg_r, bg_g, bg_b);

	// ── Tint the glass ──
	vec3 color = mix(bg, tint.rgb, tint.a);

	// ── Edge rim light ──
	float rim = (1.0 - smoothstep(0.0, border_width, -sdf)) * step(sdf, 0.0);
	rim *= rim_intensity;
	color = mix(color, border_color.rgb, rim * border_color.a);

	// ── Border stroke ──
	float border = 1.0 - smoothstep(border_width - 1.5, border_width + 1.5, abs(sdf));
	float border_alpha = border * border_color.a;
	color = mix(color, border_color.rgb, border_alpha);

	// ── Top specular sheen ──
	float sheen = smoothstep(sheen_falloff, 0.0, UV.y) * sheen_intensity * (1.0 - w * 0.6);
	color += vec3(sheen);

	// ── Touch glow: warm light radiates from touch point ──
	if (touch_uv.x >= 0.0 && touch_depth > 0.01) {
		float touch_glow = exp(-touch_dist * touch_dist * 25.0) * touch_depth;
		color += glow_color.rgb * touch_glow * glow_color.a * 0.6;
	}

	// ── Static press glow (edge-based, for keyboard/gamepad press) ──
	if (pressed > 0.01) {
		float glow = exp(-abs(sdf) * 0.35) * pressed;
		color += glow_color.rgb * glow * glow_color.a * 0.4;
	}

	COLOR = vec4(color, shape_alpha);
}
