local shaders = {}

local function read(path)
  local s, err = love.filesystem.read(path)
  if not s then error("failed to read " .. path .. ": " .. tostring(err)) end
  return s
end

-- Build a shader from parts; returns shader or nil.
function shaders.load(stageName, defines, extra)
  local config = require("src.config")
  local common = read("src/shaders/common.glsl")
  local stage = read("src/shaders/" .. stageName)
  local hdrFloat = extra and extra.hdrFloat
  local hdrDefine = hdrFloat and "#define HDR_FLOAT\n" or ""
  local hdr = string.format("#define MAX_STEPS %d\n#define D0 %d\n#define SURFACE_STEPS %d\n#define HIT_EPS %f\n#define MIN_STEP %f\n#define IRR_MAX %f\n",
    config.MAX_STEPS, config.D0, config.SURFACE_STEPS, config.HIT_EPS, config.MIN_STEP, config.IRR_MAX)
  local source = hdr .. hdrDefine .. common .. stage
  local shader, err = love.graphics.newShader(source)
  if not shader then
    error("shader " .. stageName .. " failed to compile: " .. tostring(err))
  end
  -- 11.5 returns a string whose headers ("vertex shader:", "pixel shader:")
  -- are always present, so a plain length test reports a warning on every load.
  -- Emit only the lines that are not headers.
  local w = shader:getWarnings()
  if type(w) == "string" then
    for line in w:gmatch("[^\r\n]+") do
      line = line:match("^%s*(.-)%s*$")
      if line ~= "" and line ~= "vertex shader:" and line ~= "pixel shader:" then
        print(stageName .. " warning: " .. line)
      end
    end
  end
  return shader, source
end

-- Uniform-safe send. LÖVE 11.5's binding derives the element count from the
-- number of arguments after the name (see _getCount in wrap_Shader.cpp):
--   * single vecN  -> one table:  send(sh, "uSize", {w, h})
--   * vecN[] array -> varargs of component tables: send(sh, "uC", {x1,y1}, {x2,y2}, ...)
--     (a single flat table would only set element 0)
--   * float[] array -> varargs of numbers
-- Uniforms may be optimized away by the driver, so check hasUniform first.
function shaders.send(shader, name, ...)
  if not (shader and shader:hasUniform(name)) then return end
  local n = select("#", ...)
  if n == 0 then return end
  if n == 1 then
    shader:send(name, ...)
  else
    shader:send(name, {...})
  end
end

-- vecN uniform array: list is a sequence of component tables.
function shaders.sendVecs(shader, name, list)
  if not (shader and shader:hasUniform(name)) then return end
  shader:send(name, unpack(list))
end

-- Scalar uniform array (float[N]): varargs of numbers.
function shaders.sendArr(shader, name, t)
  if not (shader and shader:hasUniform(name)) then return end
  shader:send(name, unpack(t))
end

return shaders
