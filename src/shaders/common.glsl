const float TAU = 6.28318530718;
const float PI  = 3.14159265359;

float sdCircle(vec2 p, float r) { return length(p) - r; }
float sdBox(vec2 p, vec2 b) {
  vec2 d = abs(p) - b;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
// b is the half extent of the core box; r rounds it outward (r == min(b) gives a
// stadium/capsule).
float sdRoundBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec2 fixed16(float v, float maxv) {
  float x = clamp(v / maxv, 0.0, 1.0) * 255.0;
  return vec2(floor(x) / 255.0, fract(x));
}
float unfixed16(vec2 e, float maxv) { return (e.x + e.y / 255.0) * maxv; }

vec2  distEncode(float d) { return fixed16(d + 64.0, 2048.0); }
float distDecode(vec2 e)  { return unfixed16(e, 2048.0) - 64.0; }
vec2  irrEncode(float e)  { return fixed16(e, IRR_MAX); }
float irrDecode(vec2 e)   { return unfixed16(e, IRR_MAX); }

#ifdef HDR_FLOAT
vec3 storeHDR(vec3 c) { return c; }
vec3 loadHDR(vec3 c)  { return c; }
#else
const float HDR_MAX = 64.0;
vec3 storeHDR(vec3 c) { return sqrt(clamp(c, 0.0, HDR_MAX) / HDR_MAX); }
vec3 loadHDR(vec3 c)  { return c * c * HDR_MAX; }
#endif

vec3 aces(vec3 x) {
  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}
vec3 toSrgb(vec3 x) { return pow(x, vec3(1.0 / 2.2)); }
