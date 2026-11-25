uniform sampler2D uSdf;
uniform sampler2D uSource;
uniform sampler2D uUpper;
uniform vec2 uSceneSize;
uniform vec2 uSpacing;
uniform vec2 uUpperGrid;
uniform vec2 uUpperSize;
uniform int uDirs;
uniform int uUpperDirs;
uniform int uCascadeIndex;
uniform int uCascadeCount;
uniform float uT0;
uniform float uT1;
uniform vec3 uSkyTop;
uniform vec3 uSkyBottom;
uniform vec3 uSunColor;
uniform vec2 uSunDir;
uniform float uSunAngle;
uniform float uSunIntensity;

vec3 skyRadiance(vec2 dir) {
  float h = 0.5 - 0.5 * dir.y;
  vec3 sky = mix(uSkyBottom, uSkyTop, h);
  float ang = acos(clamp(dot(dir, uSunDir), -1.0, 1.0));
  sky += uSunColor * uSunIntensity * (1.0 - smoothstep(0.0, uSunAngle, ang));
  return sky;
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
  vec2 texel = floor(screen_coords.xy);
  vec2 probe = floor(texel / float(uDirs));
  vec2 local = texel - probe * float(uDirs);
  int di = int(local.x) + int(local.y) * uDirs;
  float theta = TAU * (float(di) + 0.5) / float(uDirs * uDirs);
  vec2 dir = vec2(cos(theta), sin(theta));
  vec2 center = (probe + 0.5) * uSpacing;

  bool hit = false;
  vec3 rad = vec3(0.0);
  float t = uT0;
  for (int i = 0; i < MAX_STEPS; i++) {
    if (t > uT1) break;
    vec2 p = center + dir * t;
    if (p.x < 0.0 || p.y < 0.0 || p.x >= uSceneSize.x || p.y >= uSceneSize.y) break;
    float d = distDecode(texture2D(uSdf, (p + 0.5) / uSceneSize).rg);
    if (d < HIT_EPS) {
      hit = true;
      // the source field already carries emitter radiance and the previous
      // iteration's reflected radiance, in absolute units
      rad = texture2D(uSource, (p + 0.5) / uSceneSize).rgb;
      break;
    }
    t += max(d - 0.5, MIN_STEP);
  }

  if (!hit) {
    if (uCascadeIndex == uCascadeCount - 1) {
      rad = skyRadiance(dir);
    } else {
      vec2 u = center / (2.0 * uSpacing) - 0.5;
      vec2 base = floor(u), f = u - base;
      vec3 acc = vec3(0.0);
      for (int by = 0; by < 2; by++)
      for (int bx = 0; bx < 2; bx++) {
        float w = ((bx == 0) ? 1.0 - f.x : f.x) * ((by == 0) ? 1.0 - f.y : f.y);
        vec2 bp = clamp(base + vec2(bx, by), vec2(0.0), uUpperGrid - 1.0);
        vec3 s = vec3(0.0);
        for (int j = 0; j < 4; j++) {
          float uk = 4.0 * float(di) + float(j);
          float ux = mod(uk, float(uUpperDirs));
          float uy = floor(uk / float(uUpperDirs));
          vec2 ut = bp * float(uUpperDirs) + vec2(ux, uy);
          s += loadHDR(texture2D(uUpper, (ut + 0.5) / uUpperSize).rgb);
        }
        acc += w * (s * 0.25);
      }
      rad = acc;
    }
  }
  return vec4(storeHDR(rad), 1.0);
}
