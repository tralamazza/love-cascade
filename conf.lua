function love.conf(t)
  t.identity = "love-cascade"
  t.title = "Radiance Cascades — LÖVE"
  t.window.width = 1280
  t.window.height = 720
  -- Retina: the backbuffer and every canvas become point size * pixel factor, and
  -- src/display.lua derives the raster sizes from that factor. On a 1x display the
  -- factor is 1 and everything behaves exactly as it did without this flag.
  t.window.highdpi = true
  t.window.resizable = true
  t.vsync = 1
  t.msaa = 0
  t.gammacorrect = false
end
