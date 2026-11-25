uniform sampler2D uCascade0;
uniform vec2 uCascadeSize;
uniform int uReadback;

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
  vec2 p = floor(screen_coords.xy);
  vec3 e = vec3(0.0);
  for (int y = 0; y < D0; y++)
  for (int x = 0; x < D0; x++) {
    vec2 t = p * float(D0) + vec2(float(x), float(y));
    e += loadHDR(texture2D(uCascade0, (t + 0.5) / uCascadeSize).rgb);
  }
  e /= float(D0 * D0);
  if (uReadback == 0) {
    return vec4(storeHDR(e), 1.0);
  } else {
    float l = dot(e, vec3(0.2126, 0.7152, 0.0722));
    vec2 le = irrEncode(l);
    return vec4(le, 0.0, 1.0);
  }
}
