shader_type canvas_item;

// board.gdshader — Full-board shader reading a 10×22 data texture.
// Empty areas are semi-transparent dark glass (background shows through via alpha).
// Occupied cells are flat piece colors. Grid gaps between cells.
// Line clear flash on specific rows via uniforms.

uniform sampler2D board_tex : repeat_disable, filter_nearest;

// Grid
uniform vec2 cell_count = vec2(10.0, 20.0);
uniform float vanish_offset = 2.0;
uniform float cell_padding : hint_range(0.0, 0.2) = 0.04;

// Glass background (alpha-blended over whatever is behind the board)
uniform vec4 glass_color : source_color = vec4(0.02, 0.02, 0.06, 0.65);
uniform vec4 grid_color : source_color = vec4(0.0, 0.0, 0.0, 0.25);

// Piece colors (set from Constants.COLORS)
uniform vec4 color_1 : source_color = vec4(0.0, 0.88, 0.88, 1.0);
uniform vec4 color_2 : source_color = vec4(1.0, 0.84, 0.0, 1.0);
uniform vec4 color_3 : source_color = vec4(0.63, 0.13, 0.94, 1.0);
uniform vec4 color_4 : source_color = vec4(0.0, 0.82, 0.32, 1.0);
uniform vec4 color_5 : source_color = vec4(0.89, 0.1, 0.11, 1.0);
uniform vec4 color_6 : source_color = vec4(0.0, 0.47, 0.95, 1.0);
uniform vec4 color_7 : source_color = vec4(1.0, 0.55, 0.0, 1.0);

// Line clear flash
uniform vec4 flash_rows = vec4(-1.0);
uniform float flash_intensity : hint_range(0.0, 1.0) = 0.0;

vec4 get_color(float type) {
	if (type < 0.5) return vec4(0.0); // invisible — glass shows through
	if (type < 1.5) return color_1;
	if (type < 2.5) return color_2;
	if (type < 3.5) return color_3;
	if (type < 4.5) return color_4;
	if (type < 5.5) return color_5;
	if (type < 6.5) return color_6;
	return color_7;
}

void fragment() {
	vec2 grid_pos = UV * cell_count;
	vec2 cell_coord = floor(grid_pos);
	vec2 local_uv = fract(grid_pos);

	// Outside cell grid — glass border
	if (cell_coord.x < 0.0 || cell_coord.x >= cell_count.x ||
	    cell_coord.y < 0.0 || cell_coord.y >= cell_count.y) {
		COLOR = glass_color;
	} else {
		// Padding creates grid lines (slightly darker glass)
		vec2 pad_min = vec2(cell_padding);
		vec2 pad_max = vec2(1.0 - cell_padding);
		if (local_uv.x < pad_min.x || local_uv.x > pad_max.x ||
		    local_uv.y < pad_min.y || local_uv.y > pad_max.y) {
			COLOR = vec4(mix(glass_color.rgb, grid_color.rgb, grid_color.a), glass_color.a);
		} else {
			// Sample data texture — piece type
			float tex_u = cell_coord.x / 10.0;
			float tex_v = (cell_coord.y + vanish_offset) / 22.0;
			float piece_type = texture(board_tex, vec2(tex_u, tex_v)).r;

			vec4 cell_color = get_color(piece_type);

			// Empty cell — glass shows through
			if (cell_color.a < 0.01) {
				cell_color = glass_color;
			} else {
				// Line clear flash
				if (flash_intensity > 0.01) {
					if (cell_coord.y == flash_rows.x || cell_coord.y == flash_rows.y ||
					    cell_coord.y == flash_rows.z || cell_coord.y == flash_rows.w) {
						cell_color = mix(cell_color, vec4(1.0, 1.0, 1.0, 1.0), flash_intensity * 0.8);
					}
				}
				// Subtle top highlight
				vec2 inner_uv = (local_uv - pad_min) / (pad_max - pad_min);
				cell_color.rgb += smoothstep(0.6, 1.0, inner_uv.y) * 0.06;
			}

			COLOR = cell_color;
		}
	}
}
