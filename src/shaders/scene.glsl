uniform vec2 uSceneSize;
uniform float uSS;
uniform int uMode;
uniform int uPrimCount;
uniform vec2 uPrimCenter[24];
uniform vec2 uPrimSize[24];
uniform float uPrimAngle[24];
uniform float uPrimType[24];
uniform float uPrimRadius[24];
uniform vec3 uPrimAlbedo[24];
uniform vec3 uPrimEmission[24];

vec2 rot(vec2 p, float a) {
  float c = cos(a), s = sin(a);
  return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
  // Scene-space coordinate of this pixel; at uSS == 1 this is exactly
  // floor(screen_coords), the 1x convention the SDF is built on.
  vec2 p = (screen_coords - 0.5) / uSS;
  float dmin = 1e4;
  vec3 alb = vec3(0.0);
  vec3 emi = vec3(0.0);
  for (int i = 0; i < 24; i++) {
    if (i >= uPrimCount) break;
    vec2 q = p - uPrimCenter[i];
    vec2 rq = rot(q, -uPrimAngle[i]);
    float d;
    if (uPrimType[i] < 0.5) d = sdCircle(rq, uPrimSize[i].x);
    else if (uPrimType[i] < 1.5) d = sdBox(rq, uPrimSize[i]);
    else d = sdRoundBox(rq, uPrimSize[i], uPrimRadius[i]);
    if (d < dmin) {
      dmin = d;
      alb = uPrimAlbedo[i];
      emi = uPrimEmission[i];
    }
  }
  if (uMode == 0) {
    vec2 e = distEncode(dmin);
    return vec4(e.x, e.y, 1.0, 1.0);
  } else if (uMode == 1) {
    return vec4(alb, 1.0);
  } else {
    return vec4(emi, 1.0);
  }
}
