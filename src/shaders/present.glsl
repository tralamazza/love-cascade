// Final present: add the two bloom levels back over the composed image, then a
// vignette and a mild saturation grade. Tent taps on each bloom level hide the
// boxiness of the plain box-filter downsample.
uniform sampler2D uBloom1;
uniform sampler2D uBloom2;
uniform vec2 uBloom1Texel;
uniform vec2 uBloom2Texel;
uniform float uBloom;
uniform float uVignette;
uniform float uSaturation;

vec3 tent(Image t, vec2 uv, vec2 texel) {
  vec3 s = texture2D(t, uv).rgb * 4.0;
  s = s + texture2D(t, uv + vec2( texel.x, 0.0)).rgb;
  s = s + texture2D(t, uv + vec2(-texel.x, 0.0)).rgb;
  s = s + texture2D(t, uv + vec2(0.0,  texel.y)).rgb;
  s = s + texture2D(t, uv + vec2(0.0, -texel.y)).rgb;
  return s / 8.0;
}

vec4 effect(vec4 color, Image tex, vec2 texcoord, vec2 screen_coords) {
  vec3 c = texture2D(tex, texcoord).rgb;
  if (uBloom > 0.0) {
    vec3 b1 = tent(uBloom1, texcoord, uBloom1Texel);
    vec3 b2 = tent(uBloom2, texcoord, uBloom2Texel);
    c = c + uBloom * (b1 * 0.6 + b2 * 0.4);
  }
  vec2 q = texcoord - 0.5;
  c *= 1.0 - uVignette * 2.0 * dot(q, q);
  float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c = mix(vec3(luma), c, uSaturation);
  // Ordered dither: the 8-bit store otherwise bands in the broad sky/floor
  // gradients, which are exactly where the tonemapped values change slowly.
  float n = fract(sin(dot(screen_coords, vec2(12.9898, 78.233))) * 43758.5453);
  c = clamp(c + (n - 0.5) / 255.0, 0.0, 1.0);
  return vec4(c, 1.0);
}
