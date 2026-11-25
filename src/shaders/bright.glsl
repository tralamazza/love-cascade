// Bright pass, rendered straight into a quarter-resolution canvas so the
// downsample and the threshold are one pass. A 2x2 box keeps small highlights
// from being dropped by bilinear's two-tap filter; the threshold works in
// display-referred values because the input is already tonemapped.
uniform float uThreshold;
uniform vec2 uSourceTexel;

vec4 effect(vec4 color, Image tex, vec2 texcoord, vec2 screen_coords) {
  vec2 o = uSourceTexel;
  vec3 c = texture2D(tex, texcoord + vec2(-o.x, -o.y)).rgb
         + texture2D(tex, texcoord + vec2( o.x, -o.y)).rgb
         + texture2D(tex, texcoord + vec2(-o.x,  o.y)).rgb
         + texture2D(tex, texcoord + vec2( o.x,  o.y)).rgb;
  c = c * 0.25;
  float luma = max(max(c.r, c.g), c.b);
  float w = smoothstep(uThreshold, 1.0, luma);
  return vec4(c * w, 1.0);
}
