-- Retina / HiDPI sizing.
--
-- With `t.window.highdpi = true` LÖVE keeps the whole draw API in *points*
-- (window size, draw coordinates, `canvas:getWidth()`, mouse coordinates), while
-- two other spaces move: the backbuffer and *every canvas texture* become
-- `point size * pixel factor`, and `screen_coords` inside a fragment shader is
-- the device-pixel coordinate inside that texture. Measured on macOS at factor 2:
-- `newCanvas(64,48)` reads back as 128x96; `screen_coords` at readback pixel
-- (127,95) is (127.5,95.5); `rectangle("fill",0,0,32,24)` covers device pixels
-- 0..63, i.e. draw calls stay in points.
--
-- So a pass is described by two sizes: the *device* size, which is what the shader
-- divides `screen_coords` by, and the *point* size, which is what the canvas is
-- created with and what draw calls are given.
--
-- Simulation rasters (SDF, cascade atlases, irradiance, bounce field) keep their
-- device size: one SDF texel per scene pixel is what every scene-pixel constant
-- in `config` (HIT_EPS, MIN_STEP, S0_SCENE, spacing) is calibrated against, so
-- they are created at `device / pf` and their uniforms do not move at all.
-- Presentation rasters (albedo, emission, composite, post, bloom) keep their
-- point size and therefore gain `pf` device pixels per point, which is the
-- crispness Retina is for. Those two passes take `uSS = SS * pf`, and because
-- every scene-space coordinate in them is derived through `uSS`, that single
-- uniform per pass is the whole change.
local M = { pf = 1, probed = 1 }

-- Points are the coordinate space of the draw API, device pixels that of the
-- texture, so `newCanvas` must be handed `device / pf` to get a raster that
-- measures exactly `device` pixels.
function M.probe()
  local px = love.window.toPixels(1, 0)
  local pf = math.floor(px + 0.5)
  if pf < 1 or math.abs(px - pf) > 1e-6 then return 1 end
  return pf
end

-- `sizes` are the device sizes that have to be created as size/pf. If the factor
-- does not divide one of them Retina stays off: rounding a simulation raster up
-- would silently rescale the transport instead of only resampling the
-- presentation, and a half-integer factor cannot be honoured at all.
function M.choose(pf, sizes)
  if pf <= 1 then return 1 end
  for _, n in ipairs(sizes) do
    if n % pf ~= 0 then return 1 end
  end
  return pf
end

function M.init(sizes)
  M.probed = M.probe()
  M.pf = M.choose(M.probed, sizes or {})
  if M.pf ~= M.probed then
    print(string.format("pixel factor %g does not divide the raster sizes; Retina disabled", M.probed))
  end
  return M.pf
end

-- point size to request for a raster that must measure `dev` device pixels
function M.point(dev) return dev / M.pf end

-- device size of a raster created with `pts` points
function M.dev(pts) return pts * M.pf end

return M
