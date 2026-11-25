local M = {}
M.SCENE_W, M.SCENE_H = 640, 360
M.WINDOW_W, M.WINDOW_H = 1280, 720
M.RC_SCALE = 1.0
M.S0_RC = 4
M.D0 = 4
M.MAX_CASCADES = 6
M.MAX_STEPS = 64
M.DIST_MAX, M.DIST_BIAS = 2048.0, 64.0
-- Hit radius. A large value counts grazing near-misses as hits, inflating every
-- emitter and occluder by ~HIT_EPS px; measured against the analytic disc
-- falloff, 0.75 costs 2-5x accuracy, while 0.05 costs nothing (the march's
-- min step overshoots inside the surface anyway, so the test still fires).
M.HIT_EPS, M.MIN_STEP = 0.05, 0.75
M.LIGHT_GAIN = 12.0
M.SUN_INTENSITY, M.SUN_ANGLE = 25.0, 0.035
M.EXPOSURE = 1.2
-- Transport iterations: 0 = single bounce (the --test contract), N = N extra
-- gather passes in which surfaces re-emit albedo * irradiance. BOUNCE_GAIN
-- scales the reflection term, so the effective per-bounce factor is
-- albedo * BOUNCE_GAIN.
M.BOUNCE_ITERS = 2
M.BOUNCE_GAIN = 1.0
M.AIR_SCATTER = 0.12
M.AIR_CUT = 0.06
-- Presentation: supersample factor for the geometry/composite layers, and the
-- bloom / grade knobs of the present pass (bloom strength is display-referred).
M.SS = 2
M.BLOOM_STRENGTH = 0.15
M.BLOOM_THRESHOLD = 0.70
M.VIGNETTE = 0.22
M.SATURATION = 1.06
M.IRR_MAX = 8.0
M.SURFACE_STEPS = 6
M.MAX_PRIMS = 24
M.S0_SCENE = M.S0_RC / M.RC_SCALE
return M
