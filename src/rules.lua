-- Autosplit rule evaluation for the current split. Pure except for the memory reads through `uz`.
--
-- A condition that is already true when a split becomes current does not fire; it fires on the next change
-- from false to true. This keeps a flag that is still set from the previous split from splitting again.
local model = require("model")

local M = {}

function M.compare(op, a, b)
  if op == "=" then return a == b
  elseif op == "!=" then return a ~= b
  elseif op == ">" then return a > b
  elseif op == ">=" then return a >= b
  elseif op == "<" then return a < b
  elseif op == "<=" then return a <= b
  end
  return false
end

--- Starts watching for `rule` (nil = no rule). Returns the evaluation state, or nil without a rule.
--- `key` is the watch key ("rule" for the autosplit rule of the current split, "start" / "reset" for the list rules).
function M.arm(uz, rule, key)
  key = key or "rule"
  if not rule then
    uz.memory.unwatch(key)
    return nil
  end
  if rule.kind == "memory" then
    uz.memory.watch(key, rule.addr, model.SIZES[rule.size])
  else
    uz.memory.unwatch(key)
  end
  return { rule = rule }
end

function M.disarm(uz, key)
  uz.memory.unwatch(key or "rule")
end

--- Feeds a boolean condition; true exactly once, on the change from false to true after the baseline.
function M.feed_cond(st, cond)
  if st.base == nil then
    st.base = cond
    return false
  end
  local fired = cond and not st.base
  st.base = cond
  return fired
end

--- One evaluation step of a memory rule. Returns true when the split should fire.
function M.step_memory(uz, st)
  local rule = st.rule
  local v = uz.memory[rule.size](rule.addr)
  if v == nil then return false end
  if rule.cmp == "changed" then
    if st.prev == nil then
      st.prev = v
      return false
    end
    local changed = v ~= st.prev
    st.prev = v
    return changed
  end
  return M.feed_cond(st, M.compare(rule.cmp, v, rule.value))
end

--- Short human-readable summary of a rule (no names, only ids and numbers).
function M.summary(rule)
  if not rule then return nil end
  if rule.kind == "memory" then
    local s = string.format("0x%X %s %s", rule.addr, rule.size, rule.cmp)
    if rule.cmp ~= "changed" then s = s .. " " .. rule.value end
    return s
  elseif rule.kind == "badge" then
    return "badge " .. rule.n
  elseif rule.kind == "location" then
    return "zone " .. rule.zone
  end
  return nil
end

return M
