local config = require("src.config")

local args = {}

local mode = nil -- nil | "test" | "shot" | "bench" | "bouncecheck"
local sceneDragging = nil
local hudW, hudH, scale, ox, oy = 1280, 720, 1, 0, 0
local app = nil
local smoothedMs = 0
local testState = nil
local bouncesArg, rhoArg, leArg = nil, nil, nil
local runTest, doShot, doBench, runBounceCheck

local function parseArgs(a)
  for _, x in ipairs(a or {}) do
    if x == "--test" then mode = "test"
    elseif x == "--shot" then mode = "shot"
    elseif x == "--bench" then mode = "bench"
    elseif x == "--bouncecheck" then mode = "bouncecheck"
    elseif x:sub(1, 10) == "--bounces=" then bouncesArg = tonumber(x:sub(11)) or 0
    elseif x:sub(1, 6) == "--rho=" then rhoArg = tonumber(x:sub(7))
    elseif x:sub(1, 5) == "--le=" then leArg = tonumber(x:sub(6))
    end
  end
end

local function newApp()
  local Radiance = require("src.radiance")
  local useFloat = false
  local formats = love.graphics.getCanvasFormats()
  local ok = formats.rgba16f == true
  print("rgba16f available: " .. tostring(ok))
  local scenario = nil
  if mode == "test" then scenario = "test"
  elseif mode == "bouncecheck" then scenario = "cavity" end
  local r = Radiance.new(scenario, ok, {rho = rhoArg or 0.6, le = leArg or 1.0})
  r.hdrFloat = r.useFloat
  return r
end

local lastMs = 0
local function layout()
  local w, h = love.window.getMode()
  hudW, hudH = w, h
  scale = math.min(w / config.SCENE_W, h / config.SCENE_H)
  ox = (w - config.SCENE_W * scale) / 2
  oy = (h - config.SCENE_H * scale) / 2
end

local function toScene(mx, my)
  return (mx - ox) / scale, (my - oy) / scale
end

-- Clicks in the letterbox bars must be ignored, not folded onto the scene edge:
-- toScene maps bar coordinates just outside [0, SCENE_W/H], and pick() would then
-- grab a draggable that happens to sit near the border.
local function inScene(mx, my)
  return mx >= ox and mx < ox + config.SCENE_W * scale
     and my >= oy and my < oy + config.SCENE_H * scale
end

local function drawHUD(ms, view, gi)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setFont(love.graphics.getFont())
  local x, y = 12, 12
  local lines = {
    string.format("%.1f ms", ms),
    string.format("RC %dx%d  cascades %d", app.rcW, app.rcH, app.cascadeCount),
    app.hdrFloat and "HDR float" or "HDR rgba8",
    "view: " .. view,
    "GI: " .. (gi and "on" or "off"),
    "Bloom: " .. (app.bloomOn and "on" or "off"),
    "Bounces: " .. app.bounces .. " (gain " .. config.BOUNCE_GAIN .. ")",
    "Space pause | S sun | G gi | B bloom | N bounces | M motion | R reset | Esc quit",
    "1..5 cascades 6 irr 7 sdf 8 albedo 0 final",
  }
  for _, l in ipairs(lines) do
    love.graphics.print(l, x, y)
    y = y + 18
  end
end

local function viewName(debug)
  local names = {"final", "cascade0", "cascade1", "cascade2", "cascade3", "cascade4", "irradiance", "sdf", "albedo"}
  return names[debug + 1] or "?"
end

-- Fail fast in CLI/log mode: print the error + traceback and exit non-zero
-- instead of showing LÖVE's error screen (which waits for input).
function love.errorhandler(msg)
  io.stderr:write("LOVE ERROR: " .. tostring(msg) .. "\n")
  io.stderr:write(debug.traceback("", 2) .. "\n")
  io.stderr:flush()
  os.exit(1)
end

function love.load(arg)
  parseArgs(arg)
  app = newApp()
  app.bloomOn = true
  -- the transport contract is the single-bounce path, so --test never bounces
  -- unless it is explicitly asked to
  app.bounces = bouncesArg or (mode == "test" and 0 or config.BOUNCE_ITERS)
  layout()
  local maj, min, rev = love.getVersion()
  print(string.format("LOVE %d.%d.%d", maj, min, rev))
  print("RC " .. app.rcW .. "x" .. app.rcH .. "  cascades " .. app.cascadeCount .. "  HDR " .. (app.hdrFloat and "float" or "rgba8"))

  if mode == "shot" then
    app.scene.paused = true
    app.scene:setTime(0.8)
    app.scene.dirty = true
  elseif mode == "test" then
    app.scene.paused = true
    app.scene.dirty = true
  elseif mode == "bench" then
    love.window.setVSync(0)
    app.scene.paused = true
    app.scene:setTime(0.8)
    app.scene.dirty = true
  end

  -- render once before mode logic
  app:renderAll(0, true, app.bloomOn)

  if mode == "test" then
    testState = { frames = 0, passed = {} }
  elseif mode == "shot" then
    testState = { frames = 0 }
  elseif mode == "bench" then
    testState = { frames = 0, warmup = 0, times = {}, total = 0 }
  end
end

function love.resize(w, h)
  layout()
  -- A window dragged onto a display with a different pixel density keeps the
  -- canvas textures it already had, which would descale the render rather than
  -- blur it, so the rasters are rebuilt when the factor moved.
  if app and app:refresh() then layout() end
end

local frameCount = 0

function love.update(dt)
  local ms = dt * 1000
  frameCount = frameCount + 1
  lastMs = ms
  if mode == nil then
    app.scene:update(dt)
    -- bloom would halo the diagnostic views, so it only applies to the composite
    app:renderAll(app.debug or 0, app.gi ~= false, app.bloomOn and (app.debug or 0) == 0, app.bounces)
    smoothedMs = smoothedMs * 0.9 + lastMs * 0.1
  elseif mode == "test" then
    app.scene.dirty = false -- fixed scene; only render fresh once
    app:renderAll(0, true, app.bloomOn, app.bounces)
    testState.frames = testState.frames + 1
    if testState.frames == 3 then
      runTest()
    end
  elseif mode == "shot" then
    app:renderAll(0, true, app.bloomOn, app.bounces)
    testState.frames = testState.frames + 1
    if testState.frames == 30 then
      doShot()
    end
  elseif mode == "bench" then
    app:renderAll(0, true, app.bloomOn, app.bounces)
    app:sync() -- frame time is meaningless if the GPU work is still queued
    testState.frames = testState.frames + 1
    if testState.frames > 10 then
      local ms = lastMs
      table.insert(testState.times, ms)
      if #testState.times == 120 then
        doBench()
      end
    end
  elseif mode == "bouncecheck" then
    runBounceCheck()
  end
end

function love.draw()
  layout()
  love.graphics.clear(0.05, 0.05, 0.07, 1)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(app.finalCanvas, ox, oy, 0, scale / app.SS, scale / app.SS)
  -- letterbox view size
  if mode == nil then
    drawHUD(smoothedMs, viewName(app.debug or 0), app.gi ~= false)
  end
end

local function clampScene(x, y)
  return math.max(0, math.min(config.SCENE_W, x)), math.max(0, math.min(config.SCENE_H, y))
end

function love.mousepressed(x, y, button)
  if mode then return end
  if button == 1 then
    if not inScene(x, y) then return end
    local sx, sy = toScene(x, y)
    sceneDragging = app.scene:pick(sx, sy)
  end
end

function love.mousereleased(x, y, button)
  if button == 1 then sceneDragging = nil end
end

function love.mousemoved(x, y)
  if mode then return end
  if sceneDragging then
    local sx, sy = toScene(x, y)
    sx, sy = clampScene(sx, sy)
    app.scene:move(sceneDragging, sx, sy)
  end
end

function love.keypressed(key)
  if mode then return end
  if key == "escape" then love.event.quit()
  elseif key == "space" then
    app.scene.paused = not app.scene.paused
    app.scene.dirty = true
  elseif key == "s" then
    app.scene.sunOn = not app.scene.sunOn
    app.scene.dirty = true
  elseif key == "g" then
    app.gi = app.gi == false and true or false
  elseif key == "m" then
    app.scene.motionOn = not app.scene.motionOn
    app.scene.dirty = true
  elseif key == "b" then
    app.bloomOn = not app.bloomOn
  elseif key == "n" then
    app.bounces = (app.bounces + 1) % 4
  elseif key == "r" then
    app.scene:reset()
  elseif key == "0" then
    app.debug = 0
  elseif key == "1" then
    app.debug = 1
  elseif key == "2" then
    app.debug = 2
  elseif key == "3" then
    app.debug = 3
  elseif key == "4" then
    app.debug = 4
  elseif key == "5" then
    app.debug = 5
  elseif key == "6" then
    app.debug = 6
  elseif key == "7" then
    app.debug = 7
  elseif key == "8" then
    app.debug = 8
  end
end

-- test mode
local probe = { A = {204, 180}, B = {484, 180}, C = {420, 20} }

local function sampleReadback(px, py)
  local grid = app.grid0
  local sx = math.floor(px / config.S0_SCENE)
  local sy = math.floor(py / config.S0_SCENE)
  sx = math.max(0, math.min(grid[1] - 1, sx))
  sy = math.max(0, math.min(grid[2] - 1, sy))
  app:renderIrradianceReadback()
  local img = app.irradianceReadback:newImageData()
  local r, g = img:getPixel(sx, sy)
  return (r + g / 255.0) * config.IRR_MAX
end

local function sampleFinalPixel(px, py)
  local img = app.finalCanvas:newImageData()
  -- finalCanvas is supersampled by SS * (pixel factor), and ImageData is 0-based:
  -- take the device pixel nearest the centre of the scene pixel being probed.
  local ss = math.floor(img:getWidth() / config.SCENE_W + 0.5)
  local off = math.floor(ss / 2)
  local r, g, b = img:getPixel(px * ss + off, py * ss + off)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

-- Analytic gate for the bounce loop. In a sealed cavity whose boundary emits Le
-- and reflects rho, every ray from the interior ends on a boundary, so the fixed
-- point is exactly E = Le/(1-rho) and after N bounce iterations the partial sum
-- must be Le*(1-rho^(N+1))/(1-rho). Successive convergence deltas must shrink by
-- rho; if they do not, the feedback is not the geometric series the model claims.
-- The loop applies BOUNCE_GAIN to the reflection term, so the series actually
-- converges in rho*gain and both the target and the delta ratio use that.
-- N=0 is the rig check: the field must be exactly the direct Le, so a harness bug
-- (wrong probe cell, mis-encoded readback) shows up before any bounce logic.
runBounceCheck = function()
  local p = app.scene.params or {}
  local rho, le = p.rho or 0.6, p.le or 1.0
  local gain = config.BOUNCE_GAIN or 1.0
  local rhoEff = rho * gain
  local fixed = (rhoEff < 1) and le / (1 - rhoEff) or math.huge
  -- The readback saturates at IRR_MAX, so the largest term this loop measures
  -- (N=4 of 5 iterations) must fit; the fixed point itself may exceed it.
  local lastTerm = (rhoEff < 1) and le * (1 - rhoEff ^ 5) / (1 - rhoEff) or math.huge
  -- Out-of-range parameters make the analytic target 0, inf or nan, and every
  -- `nan > tol` comparison then silently passes: --le=0 used to PASS. Refuse
  -- all of them up front.
  if not (rho > 0 and rho < 1) or not (rhoEff > 0 and rhoEff < 1)
     or not (le > 0) or not (lastTerm <= config.IRR_MAX) then
    print(string.format("[bouncecheck] FAIL: need 0 < rho*gain < 1, le > 0 and N=4 term <= IRR_MAX" ..
      " (got rho=%.3f gain=%.3f le=%.3f N4=%.3f)", rho, gain, le, lastTerm))
    love.event.quit(1)
    return
  end
  local finite = function(x) return type(x) == "number" and x == x and x ~= math.huge end
  local probe = {320, 180}
  local tolRig, tolSeries, tolRatio = 0.03, 0.06, 0.05
  print(string.format("bouncecheck: rho=%.2f gain=%.2f le=%.2f probe=(%d,%d) fixed point=%.4f",
    rho, gain, le, probe[1], probe[2], fixed))
  local prevE, prevDelta, ok, reason = nil, nil, true, nil
  for n = 0, 4 do
    app:renderAll(0, true, false, n)
    local e = sampleReadback(probe[1], probe[2])
    local want = le * (1 - rhoEff ^ (n + 1)) / (1 - rhoEff)
    local rel = e / want - 1
    local line = string.format("  N=%d measured=%.4f analytic=%.4f rel=%+.3f", n, e, want, rel)
    if not finite(rel) then
      ok, reason = false, string.format("non-finite error at N=%d (measured=%.4f analytic=%.4f)", n, e, want)
    end
    if prevE then
      local delta = e - prevE
      if prevDelta and prevDelta > 1e-4 then
        local ratio = delta / prevDelta
        line = line .. string.format("  delta_ratio=%.3f (want %.2f)", ratio, rhoEff)
        if not finite(ratio) or math.abs(ratio - rhoEff) > tolRatio then
          ok, reason = false, string.format("delta ratio %.3f not rho*gain %.3f at N=%d", ratio, rhoEff, n)
        end
      end
      prevDelta = delta
    elseif ok and math.abs(rel) > tolRig then
      ok, reason = false, string.format("direct field off by %.1f%% (rig)", rel * 100)
    end
    if ok and n > 0 and math.abs(rel) > tolSeries then
      ok, reason = false, string.format("series term off by %.1f%% at N=%d", rel * 100, n)
    end
    prevE = e
    print(line)
  end
  if ok then
    print("[bouncecheck] PASS")
    love.event.quit(0)
  else
    print("[bouncecheck] FAIL: " .. tostring(reason))
    love.event.quit(1)
  end
end

runTest = function()
  local app2 = app
  app2:renderIrradianceReadback()
  local E_A = sampleReadback(probe.A[1], probe.A[2])
  local E_B = sampleReadback(probe.B[1], probe.B[2])
  local E_C = sampleReadback(probe.C[1], probe.C[2])
  local wallPix = sampleFinalPixel(418, 180)
  local orbPix = sampleFinalPixel(560, 180)
  print(string.format("E_A=%.4f  E_B=%.4f  E_C=%.4f", E_A, E_B, E_C))
  print(string.format("wall pixel=%.4f  orb pixel=%.4f", wallPix, orbPix))
  local ok = true
  local reason = nil
  if not (E_B > 0.15) then ok = false; reason = "E_B <= 0.15" end
  if not (E_C > 0.05) then ok = false; reason = reason or "E_C <= 0.05" end
  if not (E_A < 0.005) then ok = false; reason = reason or "E_A >= 0.005" end
  if not (E_A < 0.05 * E_B) then ok = false; reason = reason or "E_A not < 0.05*E_B" end
  if not (wallPix > 0.15) then ok = false; reason = reason or "wall pixel <= 0.15" end
  if not (orbPix > 0.8) then ok = false; reason = reason or "orb pixel <= 0.8" end
  if ok then
    print("[test] PASS")
    local name = "test-final.png"
    local img = app2.finalCanvas:newImageData()
    img:encode("png", name)
    print("test-final.png: " .. tostring(img:getWidth()) .. "x" .. tostring(img:getHeight()))
    print("absolute path: " .. tostring(love.filesystem.getSaveDirectory()) .. "/" .. name)
    love.event.quit(0)
  else
    print("[test] FAIL: " .. tostring(reason))
    love.event.quit(1)
  end
end

doShot = function()
  local img = app.finalCanvas:newImageData()
  local name = "demo.png"
  img:encode("png", name)
  local abs = tostring(love.filesystem.getSaveDirectory()) .. "/" .. name
  print("demo.png: " .. abs)
  love.event.quit(0)
end

doBench = function()
  local times = testState.times
  table.sort(times)
  local sum = 0
  for _, t in ipairs(times) do sum = sum + t end
  local avg = sum / #times
  local min = times[1]
  local max = times[#times]
  print(string.format("bench: avg %.2f ms | min %.2f | max %.2f (%d frames)", avg, min, max, #times))
  love.event.quit(0)
end

function love.quit()
  -- nothing
end
