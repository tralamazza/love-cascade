local config = require("src.config")

local Scene = {}
Scene.__index = Scene

-- opts (optional): { r = corner radius for "roundbox", spin = rad/s,
--                    motion = {ax, ay, fx, fy, ph} Lissajous around home }
local function makePrim(type, x, y, sx, sy, angle, albedo, emission, draggable, opts)
  opts = opts or {}
  return {
    type = type, x = x, y = y, sx = sx, sy = sy, angle = angle or 0.0,
    albedo = albedo or {0,0,0}, emission = emission or {0,0,0},
    draggable = draggable or false,
    r = opts.r or 0.0, spin = opts.spin, motion = opts.motion,
    home = {x = x, y = y}, phase = opts.phase or 0.0,
  }
end

-- Demo room: warm floor, cool walls, a mullioned skylight in the ceiling and a
-- sun steep enough that the shafts land on the floor between the two pillars.
-- Single-bounce transport, so albedos are kept bright to make tinting visible.
local function demoPrims()
  return {
    -- shell
    makePrim("roundbox", 320, 342, 320, 26, 0, {0.70,0.58,0.44}, nil, false, {r = 6}),   -- floor
    makePrim("roundbox", 20, 180, 20, 180, 0, {0.46,0.52,0.62}, nil, false, {r = 6}),    -- left wall
    makePrim("roundbox", 620, 180, 20, 180, 0, {0.60,0.55,0.48}, nil, false, {r = 6}),   -- right wall
    makePrim("roundbox", 233, 18, 233, 18, 0, {0.46,0.48,0.55}, nil, false, {r = 5}),    -- ceiling left
    makePrim("roundbox", 605, 18, 35, 18, 0, {0.46,0.48,0.55}, nil, false, {r = 5}),    -- ceiling right
    makePrim("roundbox", 520, 18, 5, 20, 0, {0.26,0.27,0.32}, nil, false, {r = 3}),     -- skylight mullion
    -- blockers
    makePrim("roundbox", 200, 240, 10, 72, 0, {0.62,0.40,0.34}, nil, false, {r = 10}),  -- pillar A
    makePrim("roundbox", 470, 256, 9, 54, 0, {0.34,0.46,0.60}, nil, false, {r = 9}),    -- pillar B
    makePrim("roundbox", 296, 170, 88, 7, 0, {0.28,0.29,0.34}, nil, false,              -- rotating bar
             {r = 7, spin = 0.5}),
    -- emitters (radiance * LIGHT_GAIN lands just above 1.0 so they bloom instead
    -- of clipping to white)
    makePrim("circle", 150, 120, 13, 13, 0, {0,0,0}, {0.160,0.100,0.045}, true,
             {motion = {ax = 30, ay = 16, fx = 0.31, fy = 0.23, ph = 0.0}}),
    makePrim("circle", 500, 250, 9, 9, 0, {0,0,0}, {0.030,0.110,0.120}, true,
             {motion = {ax = 26, ay = 20, fx = 0.27, fy = 0.19, ph = 2.1}}),
    makePrim("circle", 560, 90, 8, 8, 0, {0,0,0}, {0.120,0.035,0.090}, true),
  }
end

local function testPrims()
  return {
    makePrim("box", 400, 180, 20, 80, 0, {0.8,0.8,0.8}, nil, false),
    makePrim("circle", 560, 180, 16, 16, 0, {0,0,0}, {1,1,1}, false),
  }
end

-- Analytic harness for multi-bounce: a sealed box whose every boundary emits
-- Le and reflects rho. Every ray from the interior ends on a boundary, so at
-- the fixed point the outgoing radiance L satisfies L = Le + rho * E with
-- E = L, i.e. E = Le / (1 - rho), and after n bounce iterations the mean
-- irradiance must be Le * (1 - rho^(n+1)) / (1 - rho). Shape-independent.
local function cavityPrims(rho, le)
  local alb, emi = {rho, rho, rho}, {le, le, le}
  return {
    makePrim("box", 20, 180, 20, 180, 0, alb, emi, false),    -- left   x 0..40
    makePrim("box", 620, 180, 20, 180, 0, alb, emi, false),   -- right  x 600..640
    makePrim("box", 320, 20, 320, 20, 0, alb, emi, false),    -- top    y 0..40
    makePrim("box", 320, 340, 320, 20, 0, alb, emi, false),   -- bottom y 320..360
  }
end

function Scene.new(mode, params)
  local s = setmetatable({}, Scene)
  s.mode = mode
  s.params = params
  if mode == "test" then
    s.prims = testPrims()
  elseif mode == "cavity" then
    s.prims = cavityPrims(params and params.rho or 0.6, params and params.le or 1.0)
  else
    s.prims = demoPrims()
  end
  s.dirty = true
  s.paused = false
  s.motionOn = true
  s.isTest = (mode == "test")
  s.t = 0.8
  -- global light state
  s.skyTop = {0.30, 0.40, 0.58}
  s.skyBottom = {0.08, 0.10, 0.15}
  s.sunColor = {1.0, 0.93, 0.80}
  local sd = {0.55, -0.835}
  local n = math.sqrt(sd[1]*sd[1] + sd[2]*sd[2])
  s.sunDir = {sd[1]/n, sd[2]/n}
  s.sunAngle = 0.045
  s.sunIntensity = 60.0
  s.sunOn = true
  s.lightGain = 18.0
  if mode == "test" then
    s.skyTop = {0, 0, 0}
    s.skyBottom = {0, 0, 0}
    s.sunIntensity = 0
    s.sunOn = false
    s.lightGain = 12.0
  elseif mode == "cavity" then
    s.skyTop = {0, 0, 0}
    s.skyBottom = {0, 0, 0}
    s.sunIntensity = 0
    s.sunOn = false
    -- emission maps to radiance directly so Le is exactly what the shaders see
    s.lightGain = 1.0
    s.paused = true
  end
  return s
end

-- Animation is a pure function of self.t so --shot / --test stay deterministic.
local function applyAnim(self)
  for _, p in ipairs(self.prims) do
    if p.spin then
      p.angle = p.spin * self.t
      self.dirty = true
    end
    if p.motion and self.motionOn then
      local m = p.motion
      p.x = p.home.x + m.ax * math.sin(m.fx * self.t + m.ph)
      p.y = p.home.y + m.ay * math.sin(m.fy * self.t + m.ph * 1.7)
      self.dirty = true
    end
  end
end

function Scene.update(self, dt)
  if self.paused then return end
  self.t = self.t + dt
  applyAnim(self)
end

function Scene.setTime(self, t)
  self.t = t
  applyAnim(self)
  self.dirty = true
end

-- Moving a draggable prim moves its motion anchor too, so a dragged orb keeps
-- orbiting its new home instead of snapping back.
function Scene.move(self, prim, x, y)
  prim.x, prim.y = x, y
  if prim.motion then prim.home.x, prim.home.y = x, y end
  self.dirty = true
end

function Scene.reset(self)
  local fresh = Scene.new(self.mode, self.params)
  fresh.paused = self.paused
  self.prims = fresh.prims
  self.t = fresh.t
  self.dirty = true
end

-- SDF for a point (approx via same math in Lua) to pick draggable prims
function Scene._dist(p, prim)
  local dx = p.x - prim.x
  local dy = p.y - prim.y
  local a = -prim.angle
  local qx = math.cos(a)*dx - math.sin(a)*dy
  local qy = math.sin(a)*dx + math.cos(a)*dy
  if prim.type == "circle" then
    return math.sqrt(qx*qx + qy*qy) - prim.sx
  else
    local r = prim.r or 0.0
    local ax = math.abs(qx) - prim.sx + r
    local ay = math.abs(qy) - prim.sy + r
    local ox = math.max(ax, 0)
    local oy = math.max(ay, 0)
    return math.sqrt(ox*ox + oy*oy) + math.min(math.max(ax, ay), 0) - r
  end
end

function Scene.pick(self, x, y)
  local best, bestAbs = nil, 14.0
  for _, p in ipairs(self.prims) do
    if p.draggable then
      local d = math.abs(self._dist({x=x, y=y}, p))
      if d < bestAbs then best, bestAbs = p, d end
    end
  end
  return best
end

-- Build per-primitive uniform arrays (padded to MAX_PRIMS)
function Scene.uniformArrays(self)
  local n = math.min(#self.prims, config.MAX_PRIMS)
  local centers, sizes, angles, types, radii, alb, emi = {}, {}, {}, {}, {}, {}, {}
  for i = 1, config.MAX_PRIMS do
    if i <= n then
      local p = self.prims[i]
      centers[i] = {p.x, p.y}
      sizes[i] = {p.sx, p.sy}
      angles[i] = p.angle
      radii[i] = p.r or 0.0
      alb[i] = {p.albedo[1], p.albedo[2], p.albedo[3]}
      emi[i] = {p.emission[1], p.emission[2], p.emission[3]}
      if p.type == "roundbox" then types[i] = 2.0
      elseif p.type == "box" then types[i] = 1.0
      else types[i] = 0.0 end
    else
      centers[i] = {0, 0}
      sizes[i] = {0, 0}
      angles[i] = 0
      radii[i] = 0
      types[i] = 0
      alb[i] = {0, 0, 0}
      emi[i] = {0, 0, 0}
    end
  end
  -- LÖVE 11.5 takes vecN arrays as varargs of component tables and float
  -- arrays as varargs of numbers; see src/shaders.lua.
  return { count = n, centers = centers, sizes = sizes,
    angles = angles, types = types, radii = radii, alb = alb, emi = emi }
end

return Scene
