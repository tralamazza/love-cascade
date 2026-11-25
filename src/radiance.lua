local config = require("src.config")
local display = require("src.display")
local shaders = require("src.shaders")
local Scene = require("src.scene")

local Radiance = {}
Radiance.__index = Radiance

-- `w`/`h` are DEVICE pixels. The canvas is created at point size so its texture
-- comes out at exactly w x h whatever the pixel factor is (see src/display.lua):
-- these are the simulation rasters, whose device resolution the transport is
-- calibrated against and which therefore must not grow on a Retina display.
local function makeCanvas(w, h, useFloat)
  local fmt = "rgba8"
  if useFloat then fmt = "rgba16f" end
  local c = love.graphics.newCanvas(display.point(w), display.point(h), {format = fmt})
  if not c then
    c = love.graphics.newCanvas(display.point(w), display.point(h), {format = "rgba8"})
    return c, false
  end
  return c, true
end

function Radiance.new(scenario, hdrFloatOk, params)
  local self = setmetatable({}, Radiance)
  self.useFloat = hdrFloatOk ~= false -- default true; caller may override
  self.scene = Scene.new(scenario, params)
  self.diag = math.sqrt(config.SCENE_W*config.SCENE_W + config.SCENE_H*config.SCENE_H)
  self.base = config.S0_SCENE
  self.rcW = math.floor(config.SCENE_W * config.RC_SCALE)
  self.rcH = math.floor(config.SCENE_H * config.RC_SCALE)
  self.levels = {}
  local c = 0
  while c < config.MAX_CASCADES do
    local spacingRC = config.S0_RC * 2^c
    local spacingScn = self.base * 2^c
    local t0 = self.base * (4^c - 1) / 3
    local t1 = self.base * (4^(c+1) - 1) / 3
    local gridX = math.floor(self.rcW / spacingRC)
    local gridY = math.floor(self.rcH / spacingRC)
    if gridX < 1 or gridY < 1 then break end
    local dirs = config.D0 * 2^c
    local lv = {
      c = c, spacingRC = spacingRC, spacingScn = spacingScn,
      t0 = t0, t1 = t1, gridX = gridX, gridY = gridY, dirs = dirs,
      texW = gridX * dirs, texH = gridY * dirs,
    }
    self.levels[#self.levels + 1] = lv
    if t1 >= self.diag then break end
    c = c + 1
  end
  self.cascadeCount = #self.levels
  assert(self.cascadeCount >= 1, "no cascades constructed")
  assert(self.cascadeCount <= config.MAX_CASCADES, "too many cascades")
  for _, lv in ipairs(self.levels) do
    assert(lv.texW > 0 and lv.texH > 0, "cascade texture dim <= 0")
  end

  self.grid0 = {self.levels[1].gridX, self.levels[1].gridY}
  self:alloc()
  self:createShaders()
  return self
end

-- Allocate every render target. Split out of Radiance.new so a window that moves
-- to a display with a different pixel density can rebuild them: an existing
-- canvas keeps the texture size it was created with, so a stale factor would
-- descale the render rather than merely blur it.
function Radiance.alloc(self)
  -- Unbind first and collect afterwards: a refresh replaces every canvas while the
  -- old ones may still be the bound render target, and releasing them lazily in
  -- that state is not something to trust across drivers.
  love.graphics.setCanvas()
  local sizes = {config.SCENE_W, config.SCENE_H, self.grid0[1], self.grid0[2]}
  for _, lv in ipairs(self.levels) do
    sizes[#sizes + 1] = lv.texW
    sizes[#sizes + 1] = lv.texH
  end
  self.pf = display.init(sizes)

  -- Presentation layers (albedo/emission/compose/post) are supersampled: edges
  -- come from the analytic prim layer, the GI field does not, so only they pay
  -- for the extra pixels. Their *point* size is scene * SS, so their device size
  -- is scene * SS * pf -- exactly the Retina window -- and their passes read the
  -- 1x field through `uSS = SS * pf`. The SDF stays at scene resolution in device
  -- pixels, which keeps the raymarch step semantics and HIT_EPS calibration
  -- untouched and keeps --test/--bouncecheck numerically identical.
  local SS = config.SS or 1
  self.SS = SS
  self.devSS = SS * self.pf
  self.outW = math.floor(config.SCENE_W * SS)
  self.outH = math.floor(config.SCENE_H * SS)
  self.sceneSdf = makeCanvas(config.SCENE_W, config.SCENE_H, false)
  self.sceneAlbedo = love.graphics.newCanvas(self.outW, self.outH, {format = "rgba8"})
  self.sceneEmission = love.graphics.newCanvas(self.outW, self.outH, {format = "rgba8"})

  self.cascadeCanvases = {}
  for i, lv in ipairs(self.levels) do
    local useF = self.useFloat
    local c, ok = makeCanvas(lv.texW, lv.texH, useF)
    self.cascadeCanvases[i] = c
    if not ok and useF then
      self.useFloat = false
      print("cascade float canvas unavailable; falling back to rgba8")
    end
  end
  -- cascade float must agree with useFloat for shaders; re-check after fallback
  if not self.useFloat then
    -- recreate all cascade canvases as rgba8 (some may have been created as float already)
    for i, lv in ipairs(self.levels) do
      self.cascadeCanvases[i] = makeCanvas(lv.texW, lv.texH, false)
    end
  end

  local irrFloat = self.useFloat
  local irrCanvas, irrOk = makeCanvas(self.grid0[1], self.grid0[2], irrFloat)
  self.irradianceCanvas = irrCanvas
  self.useIrradianceFloat = irrOk
  self.irradianceReadback = makeCanvas(self.grid0[1], self.grid0[2], false)

  self.finalCanvas = love.graphics.newCanvas(self.outW, self.outH, {format = "rgba8"})
  self.ldrCanvas = love.graphics.newCanvas(self.outW, self.outH, {format = "rgba8"})
  -- Surface radiance field the gather reads on a hit (emitters + reflections of
  -- the previous iteration), in absolute radiance units, so it needs the float
  -- format whenever float canvases are available.
  self.bounceCanvas = makeCanvas(config.SCENE_W, config.SCENE_H, self.useFloat)
  -- 1x1 target used by --bench to force a pipeline flush before timing stops. It
  -- is a flush, not a raster, so it stays in point space on purpose.
  self.syncCanvas = love.graphics.newCanvas(1, 1, {format = "rgba8"})
  -- Bloom chain: threshold + 1/4 downsample in one pass, then two box
  -- downsamples; present re-adds the two levels with a tent filter. All the
  -- bloom taps are offsets in UV space, so the chain gains resolution with the
  -- pixel factor without changing its radius on screen.
  local w4, h4 = math.max(1, math.floor(self.outW / 4)), math.max(1, math.floor(self.outH / 4))
  local w8, h8 = math.max(1, math.floor(self.outW / 8)), math.max(1, math.floor(self.outH / 8))
  local w16, h16 = math.max(1, math.floor(self.outW / 16)), math.max(1, math.floor(self.outH / 16))
  self.brightCanvas = love.graphics.newCanvas(w4, h4, {format = "rgba8"})
  self.blur1Canvas = love.graphics.newCanvas(w8, h8, {format = "rgba8"})
  self.blur2Canvas = love.graphics.newCanvas(w16, h16, {format = "rgba8"})

  print(string.format("pixel factor %d | presentation %dx%d device px | simulation %dx%d device px",
    self.pf, display.dev(self.outW), display.dev(self.outH), config.SCENE_W, config.SCENE_H))
  collectgarbage("collect")
end

-- Rebuild the rasters when the window moves to a display whose pixel factor
-- differs. Returns true when they were rebuilt.
function Radiance.refresh(self)
  if display.probe() == self.pf then return false end
  self:alloc()
  self.scene.dirty = true
  return true
end

function Radiance.createShaders(self)
  self.sceneShader = shaders.load("scene.glsl", nil, {hdrFloat = self.useFloat})
  self.cascadeShader = shaders.load("cascade.glsl", nil, {hdrFloat = self.useFloat})
  self.irradianceShader = shaders.load("irradiance.glsl", nil, {hdrFloat = self.useFloat})
  self.composeShader = shaders.load("compose.glsl", nil, {hdrFloat = self.useFloat})
  self.bounceShader = shaders.load("bounce.glsl", nil, {hdrFloat = self.useFloat})
  self.brightShader = shaders.load("bright.glsl")
  self.presentShader = shaders.load("present.glsl")
end

function Radiance.renderScene(self)
  local scene = self.scene
  local data = scene.uniformArrays(scene)
  for _, mode in ipairs({0, 1, 2}) do
    local target = mode == 0 and self.sceneSdf or (mode == 1 and self.sceneAlbedo or self.sceneEmission)
    -- mode 0 is the raymarch SDF (scene resolution); 1/2 are the surface
    -- attribute layers drawn supersampled. `uSS` is device pixels per scene
    -- pixel, which on a Retina display is SS * pf: the shader derives every
    -- scene-space coordinate from it, so one uniform carries the pixel factor.
    local ss = (mode == 0) and 1 or self.devSS
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setShader(self.sceneShader)
    shaders.send(self.sceneShader, "uSceneSize", config.SCENE_W, config.SCENE_H)
    shaders.send(self.sceneShader, "uSS", ss)
    shaders.send(self.sceneShader, "uMode", mode)
    shaders.send(self.sceneShader, "uPrimCount", data.count)
    shaders.sendVecs(self.sceneShader, "uPrimCenter", data.centers)
    shaders.sendVecs(self.sceneShader, "uPrimSize", data.sizes)
    shaders.sendArr(self.sceneShader, "uPrimAngle", data.angles)
    shaders.sendArr(self.sceneShader, "uPrimType", data.types)
    shaders.sendArr(self.sceneShader, "uPrimRadius", data.radii)
    shaders.sendVecs(self.sceneShader, "uPrimAlbedo", data.alb)
    shaders.sendVecs(self.sceneShader, "uPrimEmission", data.emi)
    -- Draw calls are in points, so a fullscreen quad is the canvas' own logical
    -- size; `screen_coords` inside the shader is then device pixels.
    love.graphics.rectangle("fill", 0, 0, target:getWidth(), target:getHeight())
  end
  self.scene.dirty = false
  love.graphics.setShader()
  love.graphics.setCanvas()
end

function Radiance._setCascadeUniforms(self, cascadeIndex)
  local scene = self.scene
  local lv = self.levels[cascadeIndex]
  local sh = self.cascadeShader
  local isTop = cascadeIndex == self.cascadeCount
  local upper = self.levels[cascadeIndex + 1]
  shaders.send(sh, "uSdf", self.sceneSdf)
  shaders.send(sh, "uSource", self.bounceCanvas)
  if upper then
    shaders.send(sh, "uUpper", self.cascadeCanvases[cascadeIndex + 1])
    shaders.send(sh, "uUpperGrid", upper.gridX, upper.gridY)
    shaders.send(sh, "uUpperSize", upper.texW, upper.texH)
    shaders.send(sh, "uUpperDirs", upper.dirs)
  else
    shaders.send(sh, "uUpper", self.cascadeCanvases[cascadeIndex])
    shaders.send(sh, "uUpperGrid", lv.gridX, lv.gridY)
    shaders.send(sh, "uUpperSize", lv.texW, lv.texH)
    shaders.send(sh, "uUpperDirs", lv.dirs)
  end
  shaders.send(sh, "uSceneSize", config.SCENE_W, config.SCENE_H)
  shaders.send(sh, "uSpacing", lv.spacingScn, lv.spacingScn)
  shaders.send(sh, "uDirs", lv.dirs)
  shaders.send(sh, "uCascadeIndex", lv.c)
  shaders.send(sh, "uCascadeCount", self.cascadeCount)
  shaders.send(sh, "uT0", lv.t0)
  shaders.send(sh, "uT1", lv.t1 + 0.5 * lv.spacingScn)
  shaders.send(sh, "uSkyTop", scene.skyTop[1], scene.skyTop[2], scene.skyTop[3])
  shaders.send(sh, "uSkyBottom", scene.skyBottom[1], scene.skyBottom[2], scene.skyBottom[3])
  shaders.send(sh, "uSunColor", scene.sunColor and scene.sunColor[1] or 1.0, scene.sunColor and scene.sunColor[2] or 0.93, scene.sunColor and scene.sunColor[3] or 0.80)
  shaders.send(sh, "uSunDir", scene.sunDir and scene.sunDir[1] or 0.45, scene.sunDir and scene.sunDir[2] or -0.89)
  shaders.send(sh, "uSunAngle", scene.sunAngle or config.SUN_ANGLE)
  shaders.send(sh, "uSunIntensity", scene.sunOn and scene.sunIntensity or 0.0)
end

function Radiance.renderCascades(self)
  for cascadeIndex = self.cascadeCount, 1, -1 do
    local target = self.cascadeCanvases[cascadeIndex]
    love.graphics.setCanvas(target)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setShader(self.cascadeShader)
    self:_setCascadeUniforms(cascadeIndex)
    love.graphics.rectangle("fill", 0, 0, target:getWidth(), target:getHeight())
  end
  love.graphics.setShader()
  love.graphics.setCanvas()
end

function Radiance.renderIrradiance(self)
  local target = self.irradianceCanvas
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setShader(self.irradianceShader)
  shaders.send(self.irradianceShader, "uCascade0", self.cascadeCanvases[1])
  shaders.send(self.irradianceShader, "uCascadeSize", self.levels[1].texW, self.levels[1].texH)
  shaders.send(self.irradianceShader, "uReadback", 0)
  love.graphics.rectangle("fill", 0, 0, target:getWidth(), target:getHeight())
  love.graphics.setShader()
  love.graphics.setCanvas()
end

function Radiance.renderIrradianceReadback(self)
  local target = self.irradianceReadback
  love.graphics.setCanvas(target)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setShader(self.irradianceShader)
  shaders.send(self.irradianceShader, "uCascade0", self.cascadeCanvases[1])
  shaders.send(self.irradianceShader, "uCascadeSize", self.levels[1].texW, self.levels[1].texH)
  shaders.send(self.irradianceShader, "uReadback", 1)
  love.graphics.rectangle("fill", 0, 0, target:getWidth(), target:getHeight())
  love.graphics.setShader()
  love.graphics.setCanvas()
end

-- Surface radiance: emitters plus albedo * irradiance-outside, the term that
-- closes the transport loop. bounceGain 0 fills emitters only, which is the
-- single-bounce source the first gather needs before any irradiance exists.
function Radiance.renderBounce(self, bounceGain)
  local scene = self.scene
  love.graphics.setCanvas(self.bounceCanvas)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setShader(self.bounceShader)
  local sh = self.bounceShader
  shaders.send(sh, "uSdf", self.sceneSdf)
  shaders.send(sh, "uAlbedo", self.sceneAlbedo)
  shaders.send(sh, "uEmission", self.sceneEmission)
  shaders.send(sh, "uIrradiance", self.irradianceCanvas)
  shaders.send(sh, "uSceneSize", config.SCENE_W, config.SCENE_H)
  shaders.send(sh, "uS0Scene", self.base)
  shaders.send(sh, "uLightGain", scene.lightGain or config.LIGHT_GAIN)
  shaders.send(sh, "uBounceGain", bounceGain)
  love.graphics.rectangle("fill", 0, 0, self.bounceCanvas:getWidth(), self.bounceCanvas:getHeight())
  love.graphics.setShader()
  love.graphics.setCanvas()
end

function Radiance.renderCompose(self, debug, gi, sunOn, scene)
  love.graphics.setCanvas(self.ldrCanvas)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setShader(self.composeShader)
  local sh = self.composeShader
  shaders.send(sh, "uSdf", self.sceneSdf)
  shaders.send(sh, "uAlbedo", self.sceneAlbedo)
  shaders.send(sh, "uEmission", self.sceneEmission)
  shaders.send(sh, "uIrradiance", self.irradianceCanvas)
  for i = 1, self.cascadeCount do
    shaders.send(sh, "uCascade" .. (i-1), self.cascadeCanvases[i])
  end
  shaders.send(sh, "uSceneSize", config.SCENE_W, config.SCENE_H)
  shaders.send(sh, "uSS", self.devSS)
  shaders.send(sh, "uS0Scene", self.base)
  shaders.send(sh, "uExposure", config.EXPOSURE)
  shaders.send(sh, "uAirScatter", config.AIR_SCATTER)
  shaders.send(sh, "uAirCut", config.AIR_CUT)
  shaders.send(sh, "uLightGain", scene.lightGain or config.LIGHT_GAIN)
  shaders.send(sh, "uDebug", debug)
  shaders.send(sh, "uGI", gi and 1 or 0)
  shaders.send(sh, "uSkyTop", scene.skyTop[1], scene.skyTop[2], scene.skyTop[3])
  shaders.send(sh, "uSkyBottom", scene.skyBottom[1], scene.skyBottom[2], scene.skyBottom[3])
  love.graphics.rectangle("fill", 0, 0, self.ldrCanvas:getWidth(), self.ldrCanvas:getHeight())
  love.graphics.setShader()
  love.graphics.setCanvas()
end

-- Threshold + downsample + blur + composite. bloomOn == false skips the chain
-- and copies the composed image straight through (bloom toggle in the demo).
function Radiance.renderPost(self, bloomOn)
  local strength = (bloomOn == false) and 0 or config.BLOOM_STRENGTH
  if strength > 0 then
    love.graphics.setCanvas(self.brightCanvas)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setShader(self.brightShader)
    shaders.send(self.brightShader, "uThreshold", config.BLOOM_THRESHOLD)
    shaders.send(self.brightShader, "uSourceTexel",
      1 / self.ldrCanvas:getWidth(), 1 / self.ldrCanvas:getHeight())
    love.graphics.draw(self.ldrCanvas, 0, 0, 0,
      self.brightCanvas:getWidth() / self.ldrCanvas:getWidth(),
      self.brightCanvas:getHeight() / self.ldrCanvas:getHeight())
    love.graphics.setShader()
    -- box downsamples (canvas default linear filter averages the footprint)
    love.graphics.setCanvas(self.blur1Canvas)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.draw(self.brightCanvas, 0, 0, 0,
      self.blur1Canvas:getWidth() / self.brightCanvas:getWidth(),
      self.blur1Canvas:getHeight() / self.brightCanvas:getHeight())
    love.graphics.setCanvas(self.blur2Canvas)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.draw(self.blur1Canvas, 0, 0, 0,
      self.blur2Canvas:getWidth() / self.blur1Canvas:getWidth(),
      self.blur2Canvas:getHeight() / self.blur1Canvas:getHeight())
  end
  love.graphics.setCanvas(self.finalCanvas)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setShader(self.presentShader)
  local sh = self.presentShader
  shaders.send(sh, "uBloom1", self.blur1Canvas)
  shaders.send(sh, "uBloom2", self.blur2Canvas)
  shaders.send(sh, "uBloom1Texel", 1 / self.blur1Canvas:getWidth(), 1 / self.blur1Canvas:getHeight())
  shaders.send(sh, "uBloom2Texel", 1 / self.blur2Canvas:getWidth(), 1 / self.blur2Canvas:getHeight())
  shaders.send(sh, "uBloom", strength)
  shaders.send(sh, "uVignette", config.VIGNETTE)
  shaders.send(sh, "uSaturation", config.SATURATION)
  love.graphics.draw(self.ldrCanvas, 0, 0)
  love.graphics.setShader()
  love.graphics.setCanvas()
end

-- A single gather is cascades + irradiance. `bounces` extra iterations rebuild
-- the surface radiance field from the current irradiance and gather again: after
-- iteration k every probe holds light that has bounced at most k+1 times, so the
-- series converges to the transport fixed point geometrically in the surface
-- albedo. Iterating per frame (rather than reusing last frame's field) keeps the
-- result frame-count independent, which is what keeps --test/--shot deterministic.
function Radiance.renderAll(self, debug, gi, bloomOn, bounces)
  local n = math.max(0, bounces or 0)
  if self.scene.dirty then self:renderScene() end
  self:renderBounce(0)
  for k = 1, n + 1 do
    self:renderCascades()
    self:renderIrradiance()
    if k <= n then self:renderBounce(config.BOUNCE_GAIN) end
  end
  self:renderCompose(debug, gi, true, self.scene)
  self:renderPost(bloomOn)
end

-- Force the GPU to finish this frame's work: LÖVE only queues draw calls, so
-- without a readback --bench times submission, not frame cost.
function Radiance.sync(self)
  love.graphics.setCanvas(self.syncCanvas)
  love.graphics.draw(self.finalCanvas, 0, 0, 0,
    self.syncCanvas:getWidth() / self.finalCanvas:getWidth(),
    self.syncCanvas:getHeight() / self.finalCanvas:getHeight())
  love.graphics.setCanvas()
  self.syncCanvas:newImageData():getPixel(0, 0)
end

return Radiance
