shader_type canvas_item;

// hud_glass.gdshader — ONE liquid-glass surface for ALL HUD panels.
// Rather than a quad per panel (which can only draw inside its own rect and
// therefore can't touch its neighbours), a single covering quad evaluates the
// smooth-union (metaball) of every panel rectangle. Panels that come close
// bridge together into one continuous piece of glass — the iOS look — while
// far-apart panels stay separate. It refracts the SAME baked background the
// board uses, so the panels read as cut from the same glass as the board.
//
// Edit mode (drag-to-rearrange) adds a travelling ripple from the press point
// and a glowing highlight around the selected panel.

uniform sampler2D bg_tex : source_color, hint_default_black, filter_linear_mipmap;
uniform vec2 origin_px = vec2(0.0);          // covering quad's top-left, screen px
uniform vec2 rect_px = vec2(400.0, 400.0);   // covering quad size, px
uniform vec4 rects[6];                        // per panel: (cx, cy, half_w, half_h) px
uniform float corner_px = 18.0;
uniform float merge_k : hint_range(0.0, 90.0) = 30.0; // fillet radius where panels meet
uniform vec4 tint : source_color = vec4(0.07, 0.10, 0.18, 0.52);
uniform float bg_dim : hint_range(0.0, 1.0) = 0.35;
uniform float blur : hint_range(0.0, 8.0) = 3.0;
uniform vec4 border_color : source_color = vec4(1.0, 1.0, 1.0, 0.22);
uniform float border_px : hint_range(0.0, 6.0) = 1.5;
uniform float warp : hint_range(0.0, 20.0) = 6.0;

// The main board, so panels near it bridge INTO the board and the whole thing
// reads as one connected piece of glass. hw<0 disables it. The board interior
// is masked out (the board draws itself); only the connecting neck is added.
uniform vec4 board_rect = vec4(0.0, 0.0, -1.0, -1.0); // (cx, cy, half_w, half_h) px
uniform float board_corner = 40.0;

// ── Edit-mode uniforms (idle defaults = fully inert) ──
uniform vec4 sel_rect = vec4(0.0, 0.0, -1.0, -1.0); // selected panel (cx,cy,hw,hh); hw<0 = none
uniform float sel_glow = 0.0;                        // 0..1 highlight strength
uniform vec2 ripple_center = vec2(0.0);              // press point, screen px
uniform float ripple_age = -1.0;                     // seconds since press; <0 = inactive
uniform vec3 accent : source_color = vec3(0.55, 0.82, 1.0);

// Squircle SDF (exponent 2.5) — the Apple continuous corner, matching the
// board / buttons / pieces so every corner in the app rounds the same way.
float rbox(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	float d = min(max(q.x, q.y), 0.0);
	vec2 c = max(q, vec2(0.0));
	return d + pow(pow(c.x, 2.5) + pow(c.y, 2.5), 1.0 / 2.5) - r;
}

// Polynomial smooth-min — the bridge fillet radius is k.
float smin(float a, float b, float k) {
	float h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-4), 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

// Combined signed distance to the union of all panels. Unused slots are padded
// far away by the CPU, so their contribution vanishes under smin (loop stays a
// constant 6 iterations for driver portability).
float field(vec2 px) {
	float d = 1e9;
	for (int i = 0; i < 6; i++) {
		d = smin(d, rbox(px - rects[i].xy, rects[i].zw, corner_px), merge_k);
	}
	return d;
}

// Signed distance to the board's rounded rect (large positive if no board).
float board_sdf(vec2 px) {
	if (board_rect.z <= 0.0) {
		return 1e9;
	}
	return rbox(px - board_rect.xy, board_rect.zw, board_corner);
}

// The fully merged surface: panels smooth-unioned with the board, so a panel
// close to the board grows a liquid neck into it.
float field_all(vec2 px) {
	return smin(field(px), board_sdf(px), merge_k);
}

void fragment() {
	vec2 px = origin_px + UV * rect_px;
	float dp = field(px);                          // panels only (always drawn)
	float shape_p = clamp(0.5 - dp, 0.0, 1.0);

	// Merge panels with the board, but keep the board interior masked out (the
	// board renders itself there) — we only add the connecting neck.
	float d = field_all(px);
	float bd = board_sdf(px);
	float board_mask = smoothstep(-1.0, 1.5, bd); // 0 inside board, 1 outside
	float shape = max(shape_p, clamp(0.5 - d, 0.0, 1.0) * board_mask);

	// Selection glow: a bright edge ring plus a soft halo that spills just
	// outside the selected panel (so the highlight reads as a ring around it).
	float glow = 0.0;
	if (sel_rect.z > 0.0 && sel_glow > 0.001) {
		float sd = rbox(px - sel_rect.xy, sel_rect.zw, corner_px);
		glow = exp(-abs(sd) / 4.5);            // bright edge ring (both sides)
		glow += exp(-max(sd, 0.0) / 9.0) * 0.8; // outer halo (outside only)
		glow *= sel_glow * (0.85 + 0.15 * sin(TIME * 4.0)); // gentle breathing
	}

	float alpha = max(shape, clamp(glow, 0.0, 1.0) * 0.85);
	if (alpha < 0.003) {
		discard;
	}

	vec3 color = vec3(0.0);
	if (shape > 0.003) {
		// Surface normal of the merged field (forward differences) — correct
		// outward direction everywhere, including across a merge bridge.
		float e = 1.5;
		float dx = field_all(px + vec2(e, 0.0)) - d;
		float dy = field_all(px + vec2(0.0, e)) - d;
		vec2 nrm = normalize(vec2(dx, dy) + vec2(1e-6));

		// Edge lens: bend the frosted background outward, strongest at the rim.
		float w = clamp(-d / 60.0, 0.0, 1.0);
		float fall = exp(-warp * w * w);
		vec2 suv = SCREEN_UV - nrm * fall * 0.02;
		vec3 bg = textureLod(bg_tex, suv, blur).rgb * (1.0 - bg_dim);
		color = mix(bg, tint.rgb, tint.a);

		// Rim light + border stroke, following the merged outline.
		float rim = (1.0 - smoothstep(0.0, border_px * 2.5, -d)) * step(d, 0.0);
		color = mix(color, border_color.rgb, rim * border_color.a * 0.5);
		float border = 1.0 - smoothstep(border_px - 1.0, border_px + 1.0, abs(d));
		color = mix(color, border_color.rgb, border * border_color.a);

		// Faint top sheen across the surface.
		color += smoothstep(0.35, 0.0, UV.y) * 0.04;

		// Ripple: a gaussian ring sweeping out from the press point across the
		// glass — the material "tap" response.
		if (ripple_age >= 0.0) {
			float rr = length(px - ripple_center);
			float radius = ripple_age * 240.0;
			float ring = exp(-pow((rr - radius) / 24.0, 2.0));
			float fade = 1.0 - clamp(ripple_age / 1.1, 0.0, 1.0);
			color += ring * fade * 0.35;
			color = mix(color, accent, ring * fade * 0.45);
		}
	}

	// Selection accent: tint the ring/halo toward the accent colour.
	color = mix(color, accent, clamp(glow, 0.0, 1.0) * 0.55);

	COLOR = vec4(color, alpha);
}
