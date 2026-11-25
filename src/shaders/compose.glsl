uniform sampler2D uSdf;
uniform sampler2D uAlbedo;
uniform sampler2D uEmission;
uniform sampler2D uIrradiance;
uniform sampler2D uCascade0;
uniform sampler2D uCascade1;
uniform sampler2D uCascade2;
uniform sampler2D uCascade3;
uniform sampler2D uCascade4;
uniform vec2 uSceneSize;
uniform float uS0Scene;
uniform float uSS;
uniform float uExposure;
uniform float uAirScatter;
uniform float uAirCut;
uniform float uLightGain;
uniform int uDebug;
uniform int uGI;
uniform vec3 uSkyTop;
uniform vec3 uSkyBottom;

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
  // Scene-space coordinate of this output pixel, using the same convention as
  // the 1x rasters: at uSS == 1, uvS and uvF are both exactly
  // screen_coords / uSceneSize, so supersampling changes nothing else.
  vec2 p = (screen_coords - 0.5) / uSS;
  vec2 uvS = (p + 0.5) / uSceneSize;         // 1x rasters: sdf, irradiance
  vec2 uvF = (p + 1.0 / uSS) / uSceneSize;   // supersampled rasters: albedo, emission

  if (uDebug >= 1 && uDebug <= 5) {
    // The composite is drawn with love.graphics.rectangle, and LÖVE 11.5 hands a
    // shape draw degenerate tex_coords (measured: uv == (0,0) everywhere), so the
    // stretched cascade views must derive their 0..1 coordinate from
    // screen_coords like every other sampling here does. Reading `uv` instead
    // stretched a single atlas texel over the screen: pure black for cascades
    // 0..3 (probe (0,0) is inside the left wall, radiance 0) and flat grey for
    // cascade 4 (its probe (0,0) sees sky).
    vec2 tuv = screen_coords / (uSceneSize * uSS);
    vec4 outC;
    if (uDebug == 1) outC = vec4(loadHDR(texture2D(uCascade0, tuv).rgb), 1.0);
    else if (uDebug == 2) outC = vec4(loadHDR(texture2D(uCascade1, tuv).rgb), 1.0);
    else if (uDebug == 3) outC = vec4(loadHDR(texture2D(uCascade2, tuv).rgb), 1.0);
    else if (uDebug == 4) outC = vec4(loadHDR(texture2D(uCascade3, tuv).rgb), 1.0);
    else outC = vec4(loadHDR(texture2D(uCascade4, tuv).rgb), 1.0);
    vec3 outCol = toSrgb(aces(outC.rgb));
    return vec4(outCol, 1.0);
  }
  if (uDebug == 6) {
    vec3 e = loadHDR(texture2D(uIrradiance, uvS).rgb);
    return vec4(toSrgb(aces(e)), 1.0);
  }
  if (uDebug == 7) {
    float d = distDecode(texture2D(uSdf, uvS).rg);
    float v = 1.0 - clamp(d / 64.0, 0.0, 1.0);
    return vec4(vec3(v), 1.0);
  }
  if (uDebug == 8) {
    return vec4(texture2D(uAlbedo, uvF).rgb, 1.0);
  }
  // debug 0: final composite
  float d = distDecode(texture2D(uSdf, uvS).rg);
  vec3 alb = texture2D(uAlbedo, uvF).rgb;
  vec3 emi = texture2D(uEmission, uvF).rgb * uLightGain;
  vec3 e = loadHDR(texture2D(uIrradiance, uvS).rgb);
  if (uGI == 0) e = vec3(0.12);
  vec3 col;
  if (d < 1.0) {
    float dR = distDecode(texture2D(uSdf, uvS + vec2(1.0 / uSceneSize.x, 0.0)).rg);
    float dL = distDecode(texture2D(uSdf, uvS - vec2(1.0 / uSceneSize.x, 0.0)).rg);
    float dD = distDecode(texture2D(uSdf, uvS + vec2(0.0, 1.0 / uSceneSize.y)).rg);
    float dU = distDecode(texture2D(uSdf, uvS - vec2(0.0, 1.0 / uSceneSize.y)).rg);
    vec2 g = vec2(dR - dL, dD - dU);
    g = (length(g) < 1e-4) ? vec2(0.0, -1.0) : normalize(g);
    vec2 sp = p;
    for (int k = 0; k < SURFACE_STEPS; k++) {
      if (uGI == 0) break;
      if (distDecode(texture2D(uSdf, (sp + 0.5) / uSceneSize).rg) > 1.0) break;
      sp = clamp(sp + g * uS0Scene, vec2(0.5), uSceneSize - 0.5);
    }
    if (uGI != 0) e = loadHDR(texture2D(uIrradiance, (sp + 0.5) / uSceneSize).rgb);
    col = emi + alb * e * uExposure;
  } else {
    col = mix(uSkyBottom, uSkyTop, 1.0 - uvS.y) * 0.15;
    if (uGI != 0) {
      // Cheap in-scattering: the air glows with the local mean incoming
      // radiance, so beams through the skylight become visible shafts. The
      // ambient level is subtracted first so the effect reads as beams in air
      // rather than a room-wide haze.
      vec3 air = loadHDR(texture2D(uIrradiance, uvS).rgb);
      col = col + uAirScatter * max(air - vec3(uAirCut), vec3(0.0));
    }
  }
  vec3 outCol = toSrgb(aces(col));
  return vec4(outCol, 1.0);
}
