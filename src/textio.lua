-- Text format for exporting and importing a split list (shown in a textarea).
--
--   # comment
--   @timing game          header lines: @timing (game|real), @fps, @attempts, @completed, @pb (total, ms)
--   Name | rule | PB | best segment
--
-- rule: "-" (none), "mem <addr> <u8|u16|u32> <cmp> [value]", "badge <1..8>", "zone <id>"
-- PB is the cumulative time of the split in the personal best run (ms), best segment in ms; "-" when unknown.
-- A line without "|" is just a split name, so a pasted list of names works.
local model = require("model")
local util = require("util")

local M = {}

local function toint(s)
  local n = tonumber(s)
  if n and math.type(n) == "integer" then return n end
  return nil
end

--- Parses rule text. Returns true, rule (nil for none) or false, error code.
function M.parse_rule(s)
  s = util.trim(s or "")
  if s == "" or s == "-" then return true, nil end
  local tok = {}
  for w in s:gmatch("%S+") do tok[#tok + 1] = w end
  local kind = tok[1]:lower()
  if kind == "mem" then
    if #tok < 4 or #tok > 5 then return false, "rule" end
    local rule = { kind = "memory", addr = toint(tok[2]), size = tok[3]:lower(), cmp = tok[4] }
    if tok[5] then
      rule.value = toint(tok[5])
      if rule.value == nil then return false, "value" end
    end
    return model.normalize_rule(rule)
  elseif kind == "badge" then
    if #tok ~= 2 then return false, "rule" end
    return model.normalize_rule({ kind = "badge", n = toint(tok[2]) })
  elseif kind == "zone" then
    if #tok ~= 2 then return false, "rule" end
    return model.normalize_rule({ kind = "location", zone = toint(tok[2]) })
  end
  return false, "rule"
end

function M.rule_to_text(rule)
  if not rule then return "-" end
  if rule.kind == "memory" then
    local base = string.format("mem 0x%X %s %s", rule.addr, rule.size, rule.cmp)
    if rule.cmp ~= "changed" then base = base .. " " .. tostring(rule.value) end
    return base
  elseif rule.kind == "badge" then
    return "badge " .. rule.n
  elseif rule.kind == "location" then
    return "zone " .. rule.zone
  end
  return "-"
end

--- Exports the list (the data of its active timing method).
function M.export(list)
  local set = model.set(list)
  local out = { "# Splits 1 - Name | rule | PB (cumulative ms) | best segment (ms)" }
  out[#out + 1] = "@timing " .. list.timing
  out[#out + 1] = "@fps " .. string.format("%.4f", list.fps):gsub("0+$", ""):gsub("%.$", "")
  out[#out + 1] = "@attempts " .. list.attempts
  out[#out + 1] = "@completed " .. list.completed
  if set.pb then out[#out + 1] = "@pb " .. set.pb.total end
  for _, s in ipairs(list.splits) do
    local pb = set.pb and set.pb.times[s.id]
    local gold = set.golds[s.id]
    out[#out + 1] = string.format("%s | %s | %s | %s", s.name, M.rule_to_text(s.rule),
      pb and tostring(pb) or "-", gold and tostring(gold) or "-")
  end
  return table.concat(out, "\n")
end

local function opt_ms(s, allow_zero)
  s = util.trim(s or "")
  if s == "" or s == "-" then return true, nil end
  local n = toint(s)
  if not n or n < 0 or (n == 0 and not allow_zero) then return false end
  return true, n
end

--- Imports text. Returns list, or nil, code, line number. Codes: header, number, rule, name, empty, too_many.
--- The list keeps `base` timing/fps defaults (a table { timing, fps }) unless the text sets them.
function M.import(text, base)
  local list = model.new_list(base and base.timing or "game", base and base.fps or 60)
  local set = { golds = {} }
  local pb_total
  local line_no = 0
  for raw in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    line_no = line_no + 1
    local line = util.trim((raw:gsub("\r", "")))
    if line ~= "" and line:sub(1, 1) ~= "#" then
      if line:sub(1, 1) == "@" then
        local key, val = line:match("^@(%a+)%s+(.-)$")
        if not key then return nil, "header", line_no end
        key = key:lower()
        if key == "timing" then
          if val ~= "game" and val ~= "real" then return nil, "header", line_no end
          list.timing = val
        elseif key == "fps" then
          local n = tonumber(val)
          if not n or n < 1 or n > 240 then return nil, "number", line_no end
          list.fps = n
        elseif key == "attempts" or key == "completed" then
          local n = toint(val)
          if not n or n < 0 then return nil, "number", line_no end
          list[key] = n
        elseif key == "pb" then
          local n = toint(val)
          if not n or n <= 0 then return nil, "number", line_no end
          pb_total = n
        else
          return nil, "header", line_no
        end
      else
        if #list.splits >= model.MAX_SPLITS then return nil, "too_many", line_no end
        local fields = {}
        if line:find("|", 1, true) then
          for f in (line .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = f end
        else
          fields[1] = line
        end
        local name = util.clean_name(fields[1])
        if name == "" then return nil, "name", line_no end
        local ok, rule = M.parse_rule(fields[2])
        if not ok then return nil, "rule", line_no end
        local okp, pb = opt_ms(fields[3], true)
        local okg, gold = opt_ms(fields[4], false)
        if not okp or not okg then return nil, "number", line_no end
        local id = model.add(list, name, rule)
        if pb then
          set.pb = set.pb or { total = 0, times = {} }
          set.pb.times[id] = pb
        end
        if gold then set.golds[id] = gold end
      end
    end
  end
  if #list.splits == 0 then return nil, "empty", line_no end
  if set.pb then
    local last = list.splits[#list.splits]
    local total = pb_total or set.pb.times[last.id]
    if total and total > 0 then set.pb.total = total else set.pb = nil end
  end
  list.sets[list.timing] = set
  return list
end

return M
