#include <flutter/runtime_effect.glsl>

precision highp float;

// Optical model adapted for Flutter from Kyant0/backdrop's rounded-rectangle
// lens, the implementation used by Echo Music. The original is licensed under
// Apache-2.0: https://github.com/Kyant0/AndroidLiquidGlass

// ImageFilter.shader fills the first vec2 with the bound input texture size.
uniform vec2 u_size;
// Explicit local bounds of the clipped glass surface in physical pixels.
uniform vec2 u_surface_size_px;
uniform float u_band_ratio;
uniform float u_amount_ratio;
uniform float u_depth_effect;
uniform float u_chromatic_aberration;
uniform float u_radius_top_left;
uniform float u_radius_top_right;
uniform float u_radius_bottom_right;
uniform float u_radius_bottom_left;
uniform float u_saturation;
uniform float u_edge_gain;
uniform float u_edge_mode;
uniform sampler2D u_backdrop;

out vec4 frag_color;

float radius_for(vec2 centered, float minimum_size) {
  float ratio;
  if (centered.x >= 0.0) {
    ratio = centered.y <= 0.0
        ? u_radius_top_right
        : u_radius_bottom_right;
  } else {
    ratio = centered.y <= 0.0
        ? u_radius_top_left
        : u_radius_bottom_left;
  }
  return clamp(ratio, 0.0, 0.5) * minimum_size;
}

float rounded_rect_distance(
    vec2 centered,
    vec2 half_size,
    float radius
) {
  vec2 corner = abs(centered) - (half_size - vec2(radius));
  float outside = length(max(corner, 0.0)) - radius;
  float inside = min(max(corner.x, corner.y), 0.0);
  return outside + inside;
}

vec2 safe_normalize(vec2 value) {
  return value / max(length(value), 0.0001);
}

vec2 rounded_rect_normal(
    vec2 centered,
    vec2 half_size,
    float radius
) {
  vec2 corner = abs(centered) - (half_size - vec2(radius));
  if (corner.x >= 0.0 || corner.y >= 0.0) {
    return sign(centered) * safe_normalize(max(corner, 0.0));
  }
  float horizontal = step(corner.y, corner.x);
  return sign(centered) * vec2(horizontal, 1.0 - horizontal);
}

vec4 sample_backdrop(vec2 pixel_coordinate) {
  vec2 half_texel = 0.5 / max(u_size, vec2(1.0));
  vec2 uv = clamp(pixel_coordinate / u_size, half_texel, 1.0 - half_texel);
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(u_backdrop, uv);
}

vec3 apply_saturation(vec3 color) {
  float luminance = dot(color, vec3(0.2126, 0.7152, 0.0722));
  return clamp(mix(vec3(luminance), color, u_saturation), 0.0, 1.0);
}

vec4 sample_material(vec2 pixel_coordinate) {
  vec4 sampled = sample_backdrop(pixel_coordinate);
  return vec4(apply_saturation(sampled.rgb), sampled.a);
}

float circle_map(float value) {
  float x = clamp(value, 0.0, 1.0);
  return 1.0 - sqrt(max(0.0, 1.0 - x * x));
}

void main() {
  vec2 coordinate = FlutterFragCoord().xy;
  vec2 surface_size = min(max(u_surface_size_px, vec2(1.0)), u_size);
  // FlutterFragCoord tracks the backing texture for sampling. gl_FragCoord is
  // local to this runtime-filter target, so the SDF stays attached to every
  // pill and orb regardless of its position on screen.
  vec2 local_coordinate = gl_FragCoord.xy;
#ifdef IMPELLER_TARGET_OPENGLES
  local_coordinate.y = surface_size.y - local_coordinate.y;
#endif
  vec2 half_size = surface_size * 0.5;
  vec2 centered = local_coordinate - half_size;
  float minimum_size = max(min(surface_size.x, surface_size.y), 1.0);
  float radius = radius_for(centered, minimum_size);
  float refraction_height = max(u_band_ratio * minimum_size, 0.5);
  float refraction_amount = u_amount_ratio * minimum_size;

  float signed_distance;
  vec2 shape_normal;
  if (u_edge_mode > 0.5) {
    signed_distance = local_coordinate.y - surface_size.y;
    shape_normal = vec2(0.0, 1.0);
  } else {
    signed_distance = rounded_rect_distance(centered, half_size, radius);
    float gradient_radius = min(
        radius * 1.5,
        min(half_size.x, half_size.y)
    );
    shape_normal = rounded_rect_normal(centered, half_size, gradient_radius);
  }

  float inside_distance = max(-signed_distance, 0.0);
  if (inside_distance >= refraction_height) {
    frag_color = sample_material(coordinate);
    return;
  }

  float lens_progress = 1.0 - inside_distance / refraction_height;
  // backdrop passes a negative refraction amount: the outward normal therefore
  // samples inward and produces the thick, rounded glass edge seen in Echo.
  float distance_amount = -circle_map(lens_progress) * refraction_amount;
  vec2 radial = safe_normalize(centered);
  vec2 direction = safe_normalize(
      shape_normal + u_depth_effect * radial
  );
  vec2 refracted = coordinate + distance_amount * direction;

  float quadrant = (centered.x * centered.y) /
      max(half_size.x * half_size.y, 1.0);
  vec2 dispersed = distance_amount * direction * quadrant *
      u_chromatic_aberration;

  // Echo's seven spectral taps keep the reflected backdrop color luminous at
  // both the upper and lower contours without painting a broad white bloom.
  vec4 red = sample_material(refracted + dispersed);
  vec4 orange = sample_material(refracted + dispersed * (2.0 / 3.0));
  vec4 yellow = sample_material(refracted + dispersed * (1.0 / 3.0));
  vec4 green = sample_material(refracted);
  vec4 cyan = sample_material(refracted - dispersed * (1.0 / 3.0));
  vec4 blue = sample_material(refracted - dispersed * (2.0 / 3.0));
  vec4 purple = sample_material(refracted - dispersed);

  vec4 color = vec4(0.0);
  color.r = red.r / 3.5 + orange.r / 3.5 + yellow.r / 3.5 + purple.r / 7.0;
  color.g = orange.g / 7.0 + yellow.g / 3.5 + green.g / 3.5 + cyan.g / 3.5;
  color.b = cyan.b / 3.0 + blue.b / 3.0 + purple.b / 3.0;
  color.a = (red.a + orange.a + yellow.a + green.a + cyan.a + blue.a +
      purple.a) / 7.0;
  // Build the bevel from the undispersed, inward sample. The broad shoulder
  // and compact outer lip both inherit the local backdrop hue; there is no
  // fixed white specular, so blue, amber and red artwork keep those colours
  // along the upper and lower contour instead of being washed to grey.
  float fresnel = lens_progress * lens_progress;
  float bevel_shoulder = smoothstep(0.18, 0.88, lens_progress);
  float bevel_lip = smoothstep(0.78, 0.98, lens_progress);
  vec2 light_direction = safe_normalize(vec2(-0.55, -0.84));
  float light_facing = 0.5 + 0.5 * dot(shape_normal, light_direction);

  color.rgb *= mix(1.0, u_edge_gain, fresnel);
  color.rgb *= 1.0 - 0.055 * bevel_shoulder * (1.0 - light_facing);

  vec3 reflected_lift = green.rgb * (
      0.10 * bevel_shoulder +
      (0.08 + 0.10 * light_facing) * bevel_lip
  );
  // Preserve highlight roll-off over already bright cover art. Per-channel
  // headroom retains hue while avoiding clipped, chalky rims.
  vec3 headroom = max(vec3(0.0), vec3(1.0) - color.rgb);
  color.rgb += min(reflected_lift, headroom * 0.72);
  frag_color = clamp(color, 0.0, 1.0);
}
