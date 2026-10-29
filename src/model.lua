-- Split list, personal best, best segments and one attempt. Pure data logic, no uz.
--
-- list = { v = 1, timing = "game"|"real", fps = number, next_id = n, attempts = n, completed = n,
--          compare = "pb"|"best" (comparison for deltas, default "pb"), start_rule? / reset_rule? (same format as a split rule),
--          splits = { { id, name, rule? }, ... },
--          sets = { game = { pb = { total, times = { [id] = cumulative ms } }, golds = { [id] = ms } }, real = {...} } }
-- Times are per timing method, so switching between game and real time never mixes them.
-- attempt = { results = { { time = cumulative ms } | { skipped = true }, ... } } (one entry per passed split)
local util = require("util")

local M = {}
M.MAX_SPLITS = 100
M.SIZES = { u8 = 1, u16 = 2, u32 = 4 }
M.MAX = { u8 = 0xFF, u16 = 0xFFFF, u32 = 0xFFFFFFFF }
M.CMPS = { "=", "!=", ">", ">=", "<", "<=", "changed" }
M.SIZE_LIST = { "u8", "u16", "u32" }
local CMP = {}
for _, c in ipairs(M.CMPS) do CMP[c] = true end

local function is_int(v) return math.type(v) == "integer" end

function M.new_list(timing, fps)
  return { v = 1, timing = timing or "game", fps = fps or 60, next_id = 1, attempts = 0, completed = 0,
           compare = "pb", splits = {}, sets = {} }
end

--- The data set of the active timing method (created on demand).
function M.set(list)
  local s = list.sets[list.timing]
  if not s then
    s = { golds = {} }
    list.sets[list.timing] = s
  end
  s.golds = s.golds or {}
  return s
end

function M.index_of(list, id)
  for i, s in ipairs(list.splits) do
    if s.id == id then return i end
  end
  return nil
end

--- Normalizes an autosplit rule. Returns true, rule (nil for "no rule") or false, error code.
function M.normalize_rule(r)
  if r == nil or r == false then return true, nil end
  if type(r) ~= "table" then return false, "kind" end
  if r.kind == "memory" then
    if not is_int(r.addr) or r.addr < 0 or r.addr > 0xFFFFFFFF then return false, "addr" end
    if not M.SIZES[r.size] then return false, "size" end
    local cmp = r.cmp == "==" and "=" or r.cmp
    if not CMP[cmp] then return false, "cmp" end
    local out = { kind = "memory", addr = r.addr, size = r.size, cmp = cmp }
    if cmp ~= "changed" then
      if not is_int(r.value) or r.value < 0 or r.value > M.MAX[r.size] then return false, "value" end
      out.value = r.value
    end
    return true, out
  elseif r.kind == "badge" then
    if not is_int(r.n) or r.n < 1 or r.n > 8 then return false, "badge" end
    return true, { kind = "badge", n = r.n }
  elseif r.kind == "location" then
    if not is_int(r.zone) or r.zone < 0 or r.zone > 0xFFFFFFFF then return false, "zone" end
    return true, { kind = "location", zone = r.zone }
  end
  return false, "kind"
end

--- Validates stored data and returns a clean list, or nil when it is not a list at all.
function M.sanitize(v)
  if type(v) ~= "table" or v.v ~= 1 or type(v.splits) ~= "table" then return nil end
  local timing = v.timing == "real" and "real" or "game"
  local fps = type(v.fps) == "number" and v.fps >= 1 and v.fps <= 240 and v.fps or 60
  local list = M.new_list(timing, fps)
  list.compare = v.compare == "best" and "best" or "pb"
  for _, key in ipairs({ "start_rule", "reset_rule" }) do
    local ok, rule = M.normalize_rule(v[key])
    list[key] = ok and rule or nil
  end
  local seen = {}
  for _, s in ipairs(v.splits) do
    if type(s) == "table" and type(s.id) == "string" and not seen[s.id] and #list.splits < M.MAX_SPLITS then
      local name = util.clean_name(s.name)
      if name ~= "" then
        seen[s.id] = true
        local ok, rule = M.normalize_rule(s.rule)
        list.splits[#list.splits + 1] = { id = s.id, name = name, rule = ok and rule or nil }
      end
    end
  end
  local top = 0
  for id in pairs(seen) do
    local n = tonumber(id:match("^s(%d+)$"))
    if n and n > top then top = n end
  end
  list.next_id = math.max(top + 1, is_int(v.next_id) and v.next_id or 1)
  list.attempts = is_int(v.attempts) and v.attempts >= 0 and v.attempts or 0
  list.completed = is_int(v.completed) and v.completed >= 0 and v.completed or 0
  for _, key in ipairs({ "game", "real" }) do
    local src = type(v.sets) == "table" and v.sets[key]
    if type(src) == "table" then
      local set = { golds = {} }
      if type(src.golds) == "table" then
        for id, ms in pairs(src.golds) do
          if type(id) == "string" and is_int(ms) and ms > 0 then set.golds[id] = ms end
        end
      end
      local pb = src.pb
      if type(pb) == "table" and is_int(pb.total) and pb.total > 0 and type(pb.times) == "table" then
        set.pb = { total = pb.total, times = {} }
        for id, ms in pairs(pb.times) do
          if type(id) == "string" and is_int(ms) and ms >= 0 then set.pb.times[id] = ms end
        end
      end
      list.sets[key] = set
    end
  end
  return list
end

-- Editing -------------------------------------------------------------------------------------------------

--- Adds a split at the end (or at `index`). Returns the id, or nil, "full" | "name".
function M.add(list, name, rule, index)
  name = util.clean_name(name)
  if name == "" then return nil, "name" end
  if #list.splits >= M.MAX_SPLITS then return nil, "full" end
  local id = "s" .. list.next_id
  list.next_id = list.next_id + 1
  local entry = { id = id, name = name, rule = rule }
  table.insert(list.splits, index or (#list.splits + 1), entry)
  return id
end

function M.rename(list, id, name)
  local i = M.index_of(list, id)
  name = util.clean_name(name)
  if not i or name == "" then return false end
  list.splits[i].name = name
  return true
end

function M.delete(list, id)
  local i = M.index_of(list, id)
  if not i then return false end
  table.remove(list.splits, i)
  for _, set in pairs(list.sets) do
    if set.pb then set.pb.times[id] = nil end
    if set.golds then set.golds[id] = nil end
  end
  return true
end

--- dir = -1 (up) or 1 (down).
function M.move(list, id, dir)
  local i = M.index_of(list, id)
  if not i then return false end
  local j = i + dir
  if j < 1 or j > #list.splits then return false end
  list.splits[i], list.splits[j] = list.splits[j], list.splits[i]
  return true
end

function M.set_rule(list, id, rule)
  local i = M.index_of(list, id)
  if not i then return false end
  local ok, norm = M.normalize_rule(rule)
  if not ok then return false end
  list.splits[i].rule = norm
  return true
end

-- Attempt -------------------------------------------------------------------------------------------------

function M.new_attempt() return { results = {} } end

--- Index of the split the attempt is on; > #splits when every split has a result.
function M.current_index(att) return #att.results + 1 end

function M.is_done(list, att) return #att.results >= #list.splits end

--- Records a split at cumulative time `ms`. Returns true when this was the last split.
function M.record_split(list, att, ms)
  if M.is_done(list, att) then return false end
  att.results[#att.results + 1] = { time = ms }
  return M.is_done(list, att)
end

--- Skips the current split (never the last one). Returns true when skipped.
function M.record_skip(list, att)
  local i = M.current_index(att)
  if i >= #list.splits then return false end
  att.results[i] = { skipped = true }
  return true
end

--- Removes the last result. Returns true when there was one.
function M.undo(att)
  if #att.results == 0 then return false end
  att.results[#att.results] = nil
  return true
end

--- Segment times by split index. A segment after a skipped split would span several splits, so it has none.
function M.segments(list, att)
  local segs = {}
  local prev_cum, prev_ok = 0, true
  for i, r in ipairs(att.results) do
    if r.skipped then
      prev_ok = false
    else
      if prev_ok then segs[i] = r.time - prev_cum end
      prev_cum, prev_ok = r.time, true
    end
  end
  return segs
end

--- Personal best cumulative time of a split (nil without PB or when that PB skipped it).
function M.pb_time(list, id)
  local pb = M.set(list).pb
  return pb and pb.times[id] or nil
end

--- True when the segment at index `i` of the attempt beats the stored best segment (or there is none yet).
function M.is_gold(list, att, i)
  local seg = M.segments(list, att)[i]
  if not seg or seg <= 0 then return false end
  local best = M.set(list).golds[list.splits[i].id]
  return best == nil or seg < best
end

--- Cumulative best-segment time per split id (sum of the golds up to and including it). The map ends at the first
--- split without a best segment, because later cumulative times would be unknown.
function M.best_cumulative(list)
  local golds, out, total = M.set(list).golds, {}, 0
  for _, s in ipairs(list.splits) do
    if not golds[s.id] then break end
    total = total + golds[s.id]
    out[s.id] = total
  end
  return out
end

--- Cumulative times (by split id) the attempt is compared against: personal best (default) or best segments.
function M.comparison(list)
  if list.compare == "best" then return M.best_cumulative(list) end
  local pb = M.set(list).pb
  return pb and pb.times or {}
end

--- Total of the comparison: PB total or sum of best; nil when unknown.
function M.comparison_total(list)
  if list.compare == "best" then return M.sum_of_best(list) end
  local pb = M.set(list).pb
  return pb and pb.total or nil
end

--- Sets (or clears with nil) the list-wide "start_rule" / "reset_rule". Returns true, or false for a bad rule.
function M.set_list_rule(list, which, rule)
  if which ~= "start_rule" and which ~= "reset_rule" then return false end
  local ok, norm = M.normalize_rule(rule)
  if not ok then return false end
  list[which] = norm
  return true
end

--- Sum of the best segments, or nil when a split has none.
function M.sum_of_best(list)
  if #list.splits == 0 then return nil end
  local golds, total = M.set(list).golds, 0
  for _, s in ipairs(list.splits) do
    if not golds[s.id] then return nil end
    total = total + golds[s.id]
  end
  return total
end

--- Applies the attempt to the list: best segments always, the personal best when the run is finished and faster.
--- Returns { pb = bool, old_total = n|nil, total = n|nil, golds = { ids } }.
function M.commit(list, att, finished)
  local set = M.set(list)
  local info = { pb = false, golds = {} }
  local segs = M.segments(list, att)
  for i = 1, #att.results do
    local seg = segs[i]
    local id = list.splits[i] and list.splits[i].id
    if id and seg and seg > 0 and (set.golds[id] == nil or seg < set.golds[id]) then
      set.golds[id] = seg
      info.golds[#info.golds + 1] = id
    end
  end
  if finished then
    local last = att.results[#list.splits]
    if last and last.time then
      info.total = last.time
      list.completed = list.completed + 1
      info.old_total = set.pb and set.pb.total or nil
      if not set.pb or last.time < set.pb.total then
        local times = {}
        for i, r in ipairs(att.results) do
          if r.time and list.splits[i] then times[list.splits[i].id] = r.time end
        end
        set.pb = { total = last.time, times = times }
        info.pb = true
      end
    end
  end
  return info
end

return M
