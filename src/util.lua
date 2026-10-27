-- Small helpers shared by the modules.
local M = {}

function M.copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = M.copy(x) end
  return c
end

function M.trim(s)
  return (tostring(s):match("^%s*(.-)%s*$"))
end

--- Split name: control characters become spaces, "|" becomes "/" (the text format uses "|"), trimmed, at most
--- `max` characters (default 60). Returns "" for empty input.
function M.clean_name(s, max)
  max = max or 60
  s = tostring(s or "")
  s = s:gsub("|", "/")
  s = s:gsub("%c", " ")
  s = M.trim(s)
  s = s:gsub("%s+", " ")
  local len = utf8.len(s)
  if len and len > max then
    s = s:sub(1, utf8.offset(s, max + 1) - 1)
  elseif not len and #s > max then
    s = s:sub(1, max)
  end
  return s
end

--- Deterministic string form of a value (sorted keys), to compare trees and states cheaply.
function M.ser(v)
  local tv = type(v)
  if tv == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. M.ser(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  elseif tv == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end

return M
