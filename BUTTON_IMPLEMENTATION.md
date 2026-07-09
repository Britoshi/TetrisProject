# Liquid Glass Button — Full Implementation Spec

Recreate this button on any platform (web/Flutter/SwiftUI/Unity/etc).
All math is platform-agnostic. Shader code is GLSL (Godot dialect — trivial to port).

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────┐
│  Panel (StyleBoxFlat drop shadow)       │  ← CPU-side, circular-arc corners
│  ┌───────────────────────────────────┐  │
│  │ ColorRect (ShaderMaterial)        │  │  ← GPU: liquid_glass.gdshader
│  │  - squircle SDF mask              │  │
│  │  - screen-space blur / refraction │  │
│  │  - chromatic aberration           │  │
│  │  - rim light + specular sheen     │  │
│  │  - waterdrop wobble (touch react) │  │
│  │  ┌───────────────────────────┐    │  │
│  │  │ Label (text)              │    │  │
│  │  └───────────────────────────┘    │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

- **Shadow panel**: transparent Panel with `StyleBoxFlat` (shadow-only, no fill). Corner radius = 70% of body radius so shadow stays inside the squircle.
- **Glass body**: `ColorRect` with `ShaderMaterial`. The shader does ALL visual work.
- **Label**: plain text on top, `MOUSE_FILTER_IGNORE`.

---

## 2. Shader (`liquid_glass.gdshader`)

### 2.1 Continuous-Corner SDF (Squircle)

Apple uses "continuous corners" where curvature ramps from 0 (straight edge)
to max (corner apex) with no visible seam. Standard rounded-rect SDF uses
circular arcs — the curvature jumps from 0 to 1/r instantly.

**Our approach**: replace `length(corner)` with a p-norm where p = 2.5:

```glsl
float rounded_box_sdf(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    float d = min(max(q.x, q.y), 0.0);
    vec2 corner = max(q, vec2(0.0));
    // p=2.0 = circle arc (standard)  → visible edge-corner seam
    // p=2.5 = squircle (Apple-like)  → smooth curvature transition
    // p=4.0 = squircle (extreme)
    float corner_dist = pow(pow(corner.x, 2.5) + pow(corner.y, 2.5), 1.0 / 2.5);
    return d + corner_dist - r;
}
```

Anti-alias with `smoothstep`:
```glsl
float shape_alpha = 1.0 - smoothstep(-edge_smoothness, edge_smoothness, sdf);
```

Corner radius is proportional to the **smaller** dimension (height for landscape buttons):
```
corner_radius_fraction = 0.28  // 28% of smaller dimension
pixel_radius = 0.28 * min(width, height)
shader_uniform = pixel_radius / width  // normalized to UV
```

### 2.2 Refraction / Glass Body

All refraction samples `screen_texture` (hint_screen_texture, filter_linear_mipmap)
at an offset UV. The offset direction is radial from center; magnitude follows
a Gaussian falloff peaking at edges:

```glsl
float w = clamp(-sdf / max_dist, 0.0, 1.0);  // 0=center, 1=edge
float warp_falloff = exp(-warp_strength * pow(w, 2.0));
vec2 warp_offset = uv_dir * warp_falloff * warp_intensity / 10.0;
vec2 warped_uv = SCREEN_UV - warp_offset;
```

This creates the "bulgy lens" — edges warp more than center.

### 2.3 Chromatic Aberration

R and B channels are offset in opposite directions, proportional to edge proximity.
Boosted near touch point:

```glsl
float ca = (1.0 - w) * chromatic_strength + touch_ca_boost;
vec2 chroma_offset = uv_dir * ca * SCREEN_PIXEL_SIZE;
float bg_r = textureLod(screen_texture, warped_uv - chroma_offset, blur).r;
float bg_g = textureLod(screen_texture, warped_uv, blur).g;
float bg_b = textureLod(screen_texture, warped_uv + chroma_offset, blur).b;
```

`blur` is the mipmap LOD level (0=sharp, 8=very frosted).

### 2.4 Edge Rim Light + Border

```glsl
// Inner rim: bright line just inside the edge
float rim = (1.0 - smoothstep(0.0, border_width, -sdf)) * step(sdf, 0.0);
rim *= rim_intensity;

// Outer border stroke
float border = 1.0 - smoothstep(border_width - 1.5, border_width + 1.5, abs(sdf));
float border_alpha = border * border_color.a;
```

### 2.5 Top Specular Sheen

Bright near top edge, fading toward center:
```glsl
float sheen = smoothstep(sheen_falloff, 0.0, UV.y) * sheen_intensity * (1.0 - w * 0.6);
```

### 2.6 Waterdrop Wobble (Press Effect)

**Three uniforms driven by CPU**:

| Uniform | Type | Description |
|---------|------|-------------|
| `touch_uv` | vec2 | Touch position in button UV space. Set to `(-1, -1)` when idle. |
| `touch_depth` | float 0–1.2 | Spring-driven depression depth. 0=idle, 1=full press, overshoots to ~1.05. |
| `touch_time` | float | Timestamp of last press/release event (seconds). Used for ripple animation. |

**Depression** — inward bulge at touch point, wide enough to see around fingertip:
```glsl
float depress_radius = 0.28 + touch_depth * 0.08;  // 28-36% of button width
float depression = exp(-dist² / depress_radius²) * touch_depth;
warp_offset += touch_dir * depression * 0.09;
```

**Release ripple** — expanding ring, driven by time since event:
```glsl
float time_since = TIME - touch_time;
float ripple_life = clamp(time_since * 2.0, 0.0, 1.0);  // 0→1 over 0.5s
float ripple_radius = 0.15 + ripple_life * 0.55;
float ripple = ring_sdf(dist, ripple_radius, ripple_width);
ripple *= (1.0 - ripple_life) * touch_depth;  // fades as it expands
warp_offset += touch_dir * ripple * 0.05;
```

**Breathing pulse** — ongoing while held, two beating sine waves:
```glsl
float pulse = (sin(TIME * 7.0 + dist * 15.0) * 0.018
             + cos(TIME * 11.0 - dist * 10.0) * 0.012) * touch_depth
             * exp(-dist² * 12.0);
warp_offset += touch_dir * pulse;
```

**Touch glow** — warm light halo:
```glsl
float touch_glow = exp(-dist² * 8.0) * touch_depth;
color += glow_color.rgb * touch_glow * glow_color.a * 0.8;
```

---

## 3. Spring Physics (CPU)

Apple's Liquid Glass uses an **underdamped harmonic oscillator** with
damping ratio ζ ≈ 0.73. This produces the characteristic overshoot-wobble-settle:

```
stiffness = 120.0
damping   = 16.0
mass      = 1.0   (implicit)

natural frequency  ω₀ = sqrt(stiffness) ≈ 10.95 rad/s
damping ratio      ζ  = damping / (2 * sqrt(stiffness)) ≈ 0.73
```

**Integration** (semi-implicit Euler, run each frame):

```python
force = stiffness * (target - value) - damping * velocity
velocity += force * delta_time
value += velocity * delta_time
value = clamp(value, -0.15, 1.15)
```

**States**:
- Press: `target = 1.0`, spring overshoots to ~1.05 then settles at 1.0
- Release: `target = 0.0`, spring dips to ~-0.05 (bounce) then settles at 0.0
- When `abs(value) < 0.002` and `abs(velocity) < 0.01`: snap to 0, set `touch_uv = (-1, -1)`

**Touch tracking**:
- On press: record `touch_uv` (screen pos → button-local UV), set `touch_time` = current time, target = 1.0
- During hold: update `touch_uv` on drag (see §4)
- On release: set `touch_time` = current time (triggers ripple), target = 0.0

All three uniforms (`touch_uv`, `touch_depth`, `touch_time`) are pushed to the shader
**every frame** regardless of spring state. This is critical — drag updates
must reach the shader even when the spring is settled at 1.0.

---

## 4. Touch/Drag State Machine

```
                    TOUCH DOWN
                        │
                        ▼
              ┌─────────────────┐
              │  on same button? │──no──▶ [ignore]
              └────────┬────────┘
                       │ yes
                       ▼
              ┌─────────────────┐
              │  record touch_uv │
              │  target = 1.0    │
              │  touch_time = now│
              │  haptic pulse    │
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │     HOLDING     │◀──────── drag on same btn: update touch_uv
              │  (spring→1.0)  │          drag to other btn: switch target
              └────────┬────────┘          drag to empty: release, keep map
                       │
              ┌────────▼────────┐
              │    RELEASE      │
              │  target = 0.0   │
              │  touch_time = now│
              │  (spring→0.0,   │
              │   ripple fires) │
              └─────────────────┘
```

**Key behaviors**:
- Finger leaves button → action releases, spring targets 0, BUT `touch_map` entry is kept
- Finger re-enters SAME button → detects `target < 0.5`, re-triggers press + haptic + spring
- Finger enters DIFFERENT button → releases old, presses new, updates `touch_map`
- Finger lifts entirely → `_touch_normal(pressed=false)` → `_release_normal_touch` cleans up

---

## 5. Theme System

Themes are dictionaries of shader uniform overrides. Defined in a data class,
swappable at runtime.

**Preset structure**:
```python
{
    "theme_name": {
        "label": "Human Readable Name",
        # All values below are shader uniforms:
        "blur_amount": 2.5,          # mipmap LOD (0=sharp, 8=frosted)
        "warp_intensity": 0.25,      # refraction strength
        "warp_strength": 10.0,       # edge-falloff sharpness
        "border_width": 1.5,         # px
        "border_color": (1,1,1,0.45),# RGBA
        "rim_intensity": 0.5,        # inner edge highlight
        "chromatic_strength": 3.0,   # R/B split amount
        "sheen_intensity": 0.10,     # top specular brightness
        "sheen_falloff": 0.4,        # how far down the sheen reaches
        "tint_alpha": 0.55,          # glass opacity (0=clear, 1=solid)
        "glow_color": (1,0.9,0.5,0.7),# press/touch glow RGBA
    }
}
```

**Built-in presets** (see `scripts/theme.gd`):
- `ios_liquid_glass` — warm, translucent, gold glow (default)
- `frosted_opaque` — heavy blur, cool white
- `neon_edge` — sharp borders, cyan glow, high chromatic aberration
- `dark_glass` — deep tint, subtle rim
- `clear_crystal` — minimal blur, strong warp, bright edges

Porting: these are just key-value maps. On your platform, store as JSON/dict
and apply to the equivalent shader/material uniforms.

---

## 6. Per-Button Colors

Each button has a base tint color (the "fill" seen through the glass).
The shader uses `tint.rgb` for color and `tint.a` for opacity.
The theme's `tint_alpha` modulates the alpha:

```python
final_alpha = theme.tint_alpha  # from theme preset
shader_tint = (button_color.r, button_color.g, button_color.b, final_alpha)
```

Default button colors (from Tetris):
```
Left/Right:  (0.22, 0.27, 0.50)  # blue-gray
Rotate CW:   (0.22, 0.48, 0.28)  # green
Soft Drop:   (0.50, 0.27, 0.22)  # warm red
Hard Drop:   (0.60, 0.15, 0.18)  # deep red
Rotate CCW:  (0.22, 0.48, 0.28)  # green
Hold:        (0.40, 0.35, 0.20)  # amber
Restart:     (0.50, 0.22, 0.22)  # muted red
```

---

## 7. Layout Math

8 buttons in a 4×2 grid, anchored to bottom of screen:

```
button_max_width = min(screen_width / 3.5, 180px) * size_multiplier
button_width     = min((screen_width - gaps) / 4, button_max_width)
button_height    = button_width * aspect_ratio   (default 0.65)
total_width      = btn_w * 4 + gap * 3
total_height     = btn_h * 2 + gap * 1
start_x          = (screen_width - total_width) / 2
start_y          = screen_height - bottom_margin - total_height
```

Configurable via settings:
- **Size multiplier**: 0.5× to 2.0× (step 0.1)
- **Aspect ratio**: 0.3 to 1.2 (step 0.05) — controls button "squareness"

---

## 8. Porting Checklist

### Minimal (static glass, no press fx):
- [ ] Port the squircle SDF (§2.1)
- [ ] Screen-space blur sample with mipmap LOD (§2.2)
- [ ] Tint overlay (§2.2)
- [ ] Corner radius proportional to smaller dimension
- [ ] Edge rim + border (§2.4)
- [ ] Top specular sheen (§2.5)

### Full (with waterdrop wobble):
- [ ] Chromatic aberration R/B split (§2.3)
- [ ] Three touch uniforms: `touch_uv`, `touch_depth`, `touch_time`
- [ ] Depression warp (§2.6)
- [ ] Release ripple (§2.6)
- [ ] Breathing pulse (§2.6)
- [ ] Touch glow (§2.6)

### Interaction (CPU):
- [ ] Underdamped spring (§3) — stiffness=120, damping=16
- [ ] Touch → UV mapping (screen pos to button-local UV)
- [ ] Drag tracking with re-entry detection (§4)
- [ ] Push uniforms every frame (even when spring settled)
- [ ] Haptic feedback on press (12ms, 0.6 intensity)

### Theme system:
- [ ] Key-value preset storage (§5)
- [ ] Runtime theme swap pushes all keys to shader
- [ ] Per-button tint color array

---

## 9. Key Numbers (Tuning Reference)

| Parameter | Value | Notes |
|-----------|-------|-------|
| Corner radius fraction | 0.28 | 28% of smaller dimension |
| SDF squircle exponent | 2.5 | 2.0=circle, 4.0=extreme squircle |
| Spring stiffness | 120 | ω₀ ≈ 10.95 rad/s |
| Spring damping | 16 | ζ ≈ 0.73 (underdamped) |
| Spring overshoot | ~1.05 | 5% past target on press |
| Spring undershoot | ~-0.05 | 5% past zero on release |
| Depression radius | 0.28–0.36 | UV fraction, wide for finger coverage |
| Depression strength | 0.09 | warp amplitude |
| Ripple duration | 0.5s | 0→1 ring expansion |
| Ripple start radius | 0.15 | UV fraction, outside fingertip |
| Ripple amplitude | 0.05 | warp amplitude |
| Pulse freq 1 | 7 Hz | sin wave |
| Pulse freq 2 | 11 Hz | cos wave (beating) |
| Touch glow spread | exp(-dist² × 8) | wide halo around finger |
| Shadow corner scale | 0.7× body | stays inside squircle |

---

## 10. File Reference (this repo)

| File | Purpose |
|------|---------|
| `shaders/liquid_glass.gdshader` | Full GLSL shader |
| `scripts/mobile_controls.gd` | Touch handling, spring physics, layout, settings |
| `scripts/theme.gd` | Theme preset definitions (`ThemeData` class) |
| `scripts/constants.gd` | Layout constants (screen → button sizing) |
