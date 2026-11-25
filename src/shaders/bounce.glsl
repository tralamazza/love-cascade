// Surface radiance field: what every solid pixel sends back into the cascade
// field. Emitters pass straight through; diffuse surfaces re-emit albedo times
// the irradiance just outside the boundary (the previous iteration's result),
// which is what replaces the single-bounce "hit a wall -> black" closure and
// makes the series solvable by iteration. Doing the surface walk once per solid
// pixel here is what keeps the gather's hit path at a single texture fetch.
// Air stays black: the march only samples this where it hit something.
uniform sampler2D uSdf;
uniform sampler2D uAlbedo;
uniform sampler2D uEmission;
uniform sampler2D uIrradiance;
uniform vec2 uSceneSize;
uniform float uS0Scene;
uniform float uLightGain;
uniform float uBounceGain;

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screen_coords) {
  // Read every scene-resolution raster at its own texel centre: the bounce field
  // must be a texel-exact copy of the emitters (any blur or half-texel shift here
  // silently shrinks the effective emitter, which showed up as a 4.5% E_B shift),
  // and the walk uses the same (p + 0.5) convention the composite uses so a
  // surface and the pixel that draws it always agree on the irradiance they see.
  vec2 p = floor(screen_coords.xy);
  vec2 uvT = (p + 0.5) / uSceneSize;
  float d = distDecode(texture2D(uSdf, uvT).rg);
  // Emitters are copied ungated: with the supersampled emission raster and the
  // 1x SDF disagreeing about the sub-pixel edge, gating them on the SDF clipped
  // a half-pixel of emitter coverage the march still hits, and that cost 0.5% of
  // E_B. Only the reflection term needs the solid test.
  vec3 emit = texture2D(uEmission, uvT).rgb * uLightGain;
  vec3 alb = texture2D(uAlbedo, uvT).rgb;
  if (d > 1.0 || uBounceGain <= 0.0 || dot(alb, vec3(0.33333)) <= 0.0) {
    return vec4(storeHDR(emit), 1.0);
  }
  // Same outward projection as the composite: jump along the SDF gradient to a
  // fixed 1.5 px outside the surface, so a surface is lit by the field beside it
  // and not by the inside of itself, at a distance that does not depend on the
  // pixel's depth inside the solid.
  float dR = distDecode(texture2D(uSdf, uvT + vec2(1.0 / uSceneSize.x, 0.0)).rg);
  float dL = distDecode(texture2D(uSdf, uvT - vec2(1.0 / uSceneSize.x, 0.0)).rg);
  float dD = distDecode(texture2D(uSdf, uvT + vec2(0.0, 1.0 / uSceneSize.y)).rg);
  float dU = distDecode(texture2D(uSdf, uvT - vec2(0.0, 1.0 / uSceneSize.y)).rg);
  vec2 g = vec2(dR - dL, dD - dU);
  g = (length(g) < 1e-4) ? vec2(0.0, -1.0) : normalize(g);
  float jump = min(1.5 - d, float(SURFACE_STEPS) * uS0Scene);
  vec2 sp = clamp(p + g * jump, vec2(0.5), uSceneSize - 0.5);
  // Same air-gated 2x2 probe average as the composite: smooths the shadow
  // staircase the raw 4 px field would otherwise show on thin occluders without
  // pulling in dead probes from inside the solid.
  vec3 e;
  {
    vec2 it = uS0Scene / uSceneSize;
    vec2 uvi = (sp + 0.5) / uSceneSize;
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    for (int by = 0; by < 2; by++)
    for (int bx = 0; bx < 2; bx++) {
      vec2 o = (vec2(float(bx), float(by)) - 0.5) * it;
      if (distDecode(texture2D(uSdf, uvi + o).rg) > 0.0) {
        acc += loadHDR(texture2D(uIrradiance, uvi + o).rgb);
        wsum += 1.0;
      }
    }
    if (wsum > 0.0) e = acc / wsum;
    else e = loadHDR(texture2D(uIrradiance, uvi).rgb);
  }
  return vec4(storeHDR(emit + alb * e * uBounceGain), 1.0);
}
