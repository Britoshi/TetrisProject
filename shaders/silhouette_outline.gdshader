shader_type canvas_item;

// silhouette_outline.gdshader — outline of the COMBINED glass form (board
// smooth-unioned with every HUD panel — one silhouette, not per-element
// outlines), drawn on the over-the-buttons layer so the shape stays readable
// where the touch buttons cover it. Fades in near the button panel so it
// doesn't double-stroke the glass rim that is already visible elsewhere.

uniform vec4 rects[6];                        // panels: (cx, cy, half_w, half_h) px
uniform vec4 board_rect = vec4(0.0, 0.0, -1.0, -1.0);
uniform float board_corner = 40.0;
uniform float corner_px = 18.0;
uniform float merge_k : hint_range(0.0, 90.0) = 30.0;
uniform vec4 line_color : source_color = vec4(1.0, 1.0, 1.0, 0.55);
uniform float line_px : hint_range(0.5, 6.0) = 1.5;
uniform float clip_top = 0.0;                 // button panel top (screen px)
uniform float fade_px : hint_range(1.0, 120.0) = 28.0;
uniform vec2 screen_px = vec2(540.0, 960.0);

// Same squircle + smooth-union math as hud_glass.gdshader / board.gdshader,
// so this outline sits exactly on the visible glass edge.
float rbox(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + r;
	float d = min(max(q.x, q.y), 0.0);
	vec2 c = max(q, vec2(0.0));
	return d + pow(pow(c.x, 2.5) + pow(c.y, 2.5), 1.0 / 2.5) - r;
}

float smin(float a, float b, float k) {
	float h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-4), 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

float field_all(vec2 px) {
	float d = 1e9;
	for (int i = 0; i < 6; i++) {
		d = smin(d, rbox(px - rects[i].xy, rects[i].zw, corner_px), merge_k);
	}
	if (board_rect.z > 0.0) {
		d = smin(d, rbox(px - board_rect.xy, board_rect.zw, board_corner), merge_k);
	}
	return d;
}

void fragment() {
	vec2 px = UV * screen_px;
	float d = field_all(px);
	float stroke = 1.0 - smoothstep(line_px - 1.0, line_px + 1.0, abs(d));
	float fade = smoothstep(clip_top - fade_px, clip_top, px.y);
	float a = stroke * fade * line_color.a;
	if (a < 0.004) {
		discard;
	}
	COLOR = vec4(line_color.rgb, a);
}
