-- Time formatting. All inputs are integer milliseconds.
local M = {}

--- "1:02:03.45" (hours only when needed), "-" for nil. Negative values get a leading "-".
function M.time(ms)
  if ms == nil then return "-" end
  local neg = ms < 0
  if neg then ms = -ms end
  local cs = ms // 10
  local h = cs // 360000
  local m = (cs // 6000) % 60
  local s = (cs // 100) % 60
  local c = cs % 100
  local out
  if h > 0 then
    out = string.format("%d:%02d:%02d.%02d", h, m, s, c)
  else
    out = string.format("%d:%02d.%02d", m, s, c)
  end
  return (neg and "-" or "") .. out
end

--- Signed difference: "+1.23", "-0:12.30"; "" for nil.
function M.delta(ms)
  if ms == nil then return "" end
  local sign = ms < 0 and "-" or "+"
  local a = math.abs(ms)
  local body
  if a < 60000 then
    body = string.format("%d.%02d", a // 1000, (a % 1000) // 10)
  else
    body = M.time(a)
  end
  return sign .. body
end

return M
