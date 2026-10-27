-- Fake `fb` for tests (synthetic data only). See M.new for the options.
local ui_validator = require("ui_validator")
local M = {}

-- Minimal reader for flat JSON objects with string values (i18n files).
function M.read_json_flat(s)
  local out = {}
  local esc = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
  local pos = 1
  while true do
    local k, e = s:match('^%s*[{,]?%s*"([^"]*)"%s*:%s*()', pos)
    if not k then break end
    pos = e
    assert(s:sub(pos, pos) == '"', "flat string values only")
    pos = pos + 1
    local buf = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local n = s:sub(pos + 1, pos + 1)
        if n == "u" then
          buf[#buf + 1] = utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16))
          pos = pos + 6
        else
          buf[#buf + 1] = assert(esc[n], "bad escape")
          pos = pos + 2
        end
      else
        buf[#buf + 1] = c
        pos = pos + 1
      end
    end
    out[k] = table.concat(buf)
  end
  return out
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a")
  f:close()
  return s
end

local function check_value(v, depth)
  local tv = type(v)
  if tv == "function" or tv == "userdata" or tv == "thread" then
    error("value of type " .. tv .. " cannot be passed between plugins", 3)
  end
  if tv == "table" then
    if depth > 32 then error("value too deep", 3) end
    for k, x in pairs(v) do
      if type(k) == "table" then error("table used as key", 3) end
      check_value(x, depth + 1)
    end
  end
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local c = {}
  for k, x in pairs(v) do c[k] = deep_copy(x) end
  return c
end
M.deep_copy = deep_copy

-- Store values must be JSON-like: no mixed tables, no sparse arrays, no float keys.
local function check_json_like(v, depth)
  local tv = type(v)
  if tv == "function" or tv == "userdata" or tv == "thread" then error("store: not JSON-like (" .. tv .. ")", 3) end
  if tv ~= "table" then return end
  if depth > 32 then error("store: value too deep", 3) end
  local n, arr = 0, true
  for k in pairs(v) do
    n = n + 1
    if math.type(k) ~= "integer" then arr = false end
  end
  if arr and n > 0 then
    for i = 1, n do if v[i] == nil then error("store: sparse array", 3) end end
  elseif not arr then
    for k in pairs(v) do if type(k) ~= "string" then error("store: mixed or non-string keys", 3) end end
  end
  for _, x in pairs(v) do check_json_like(x, depth + 1) end
end

--- opts: game = { system, code, title, language }, language (i18n), i18n_dir, plugin = { id, version },
---   store = false (no permission) | { [key] = value }, run = { current = {...} },
---   no_ui_open (older app), memory = { { addr, data }, ... }
function M.new(opts)
  opts = opts or {}
  local mock = { logs = {}, events = {}, provided = {}, watches = {}, calls = {}, providers = {} }
  local fb = { api = 1, plugin = opts.plugin or { id = "uzume.test", version = "0.0.0" } }
  fb.game = opts.game or {}
  if opts.language and not fb.game.language then fb.game.language = opts.language end
  mock.fb = fb

  -- Memory: mutable regions, a settable snapshot frame.
  local regions = {}
  mock.regions = regions
  for _, r in ipairs(opts.memory or {}) do regions[#regions + 1] = { addr = r.addr, data = r.data } end
  local function read(addr, len)
    if type(addr) ~= "number" or len < 0 then return nil end
    for _, r in ipairs(regions) do
      if addr >= r.addr and addr + len <= r.addr + #r.data then
        local o = addr - r.addr
        return r.data:sub(o + 1, o + len)
      end
    end
    return nil
  end
  local function reader(fmt, size)
    return function(addr)
      local s = read(addr, size)
      if not s then return nil end
      return (string.unpack(fmt, s))
    end
  end
  --- mock.poke(addr, size, value): writes a little-endian integer into a region (creates one when missing).
  function mock.poke(addr, size, value)
    local data = string.pack("<I" .. size, value)
    for _, r in ipairs(regions) do
      if addr >= r.addr and addr + size <= r.addr + #r.data then
        local o = addr - r.addr
        r.data = r.data:sub(1, o) .. data .. r.data:sub(o + size + 1)
        return
      end
    end
    regions[#regions + 1] = { addr = addr, data = data }
  end
  mock.frame_value = nil
  fb.memory = {
    watch = function(key, addr, len)
      if type(key) ~= "string" or type(addr) ~= "number" or type(len) ~= "number" or len < 1 then error("bad watch", 2) end
      mock.watches[key] = { addr = addr, len = len }
    end,
    unwatch = function(key) mock.watches[key] = nil end,
    u8 = reader("<I1", 1), u16 = reader("<I2", 2), u32 = reader("<I4", 4), u64 = reader("<i8", 8),
    s8 = reader("<i1", 1), s16 = reader("<i2", 2), s32 = reader("<i4", 4),
    bytes = function(addr, len) return read(addr, len) end,
    frame = function() return mock.frame_value end,
  }

  fb.log = {}
  for _, level in ipairs({ "debug", "info", "warn", "error" }) do
    fb.log[level] = function(...)
      local parts = table.pack(...)
      for i = 1, parts.n do parts[i] = tostring(parts[i]) end
      mock.logs[#mock.logs + 1] = { level = level, text = table.concat(parts, "\t", 1, parts.n) }
    end
  end

  -- Events: emit records, on subscribes; mock.fire_event delivers.
  local handlers = {}
  function mock.fire_event(plugin_id, name, value)
    for _, h in ipairs(handlers) do
      if (h[1] == "*" or h[1] == plugin_id) and h[2] == name then h[3](deep_copy(value), plugin_id, name) end
    end
  end
  fb.events = {
    emit = function(name, value)
      check_value(value, 1)
      mock.events[#mock.events + 1] = { name = name, value = deep_copy(value) }
    end,
    on = function(plugin_id, name, fn)
      if type(fn) ~= "function" then error("events.on: function expected", 2) end
      handlers[#handlers + 1] = { plugin_id, name, fn }
    end,
  }
  fb.provide = function(name, tbl)
    assert(type(name) == "string" and type(tbl) == "table", "bad provide")
    mock.provided[name] = tbl
  end

  -- Clock and ticks. mock.tick(n, frames_per_tick, ms_per_tick) advances the snapshot frame and the clock.
  local now = 1000
  fb.clock = function() return now end
  function mock.advance(ms) now = now + ms end
  local tick_fn
  fb.on_tick = function(fn) tick_fn = fn end
  function mock.tick(n, frames, ms)
    for _ = 1, n or 1 do
      mock.frame_value = (mock.frame_value or 0) + (frames or 2)
      now = now + (ms or 33)
      if tick_fn then tick_fn(mock.frame_value) end
    end
  end
  --- A tick in which the game is paused: the clock moves, the snapshot frame stays.
  function mock.tick_paused(n, ms)
    for _ = 1, n or 1 do
      now = now + (ms or 33)
      if tick_fn then tick_fn(mock.frame_value) end
    end
  end

  -- i18n from the plugin's own files.
  local dir = opts.i18n_dir or "plugin/i18n"
  local strings = M.read_json_flat(read_file(dir .. "/en.json"))
  if opts.language and opts.language ~= "en" then
    local f = io.open(dir .. "/" .. opts.language .. ".json", "rb")
    if f then
      local s = f:read("a"); f:close()
      for k, v in pairs(M.read_json_flat(s)) do strings[k] = v end
    end
  end
  mock.strings = strings
  fb.i18n = {
    t = function(key, vars)
      local s = strings[key] or key
      return (s:gsub("{([%w_]+)}", function(k)
        if vars and vars[k] ~= nil then return tostring(vars[k]) end
      end))
    end,
  }

  -- fb.call: fake providers. mock.set_provider("pokemon.core", { fn = function ... end }).
  -- A name without a provider raises like an interface the plugin did not list in `requires`.
  function mock.set_provider(name, tbl) mock.providers[name] = tbl end
  fb.call = function(name, fn, ...)
    local p = mock.providers[name]
    if not p then error("no plugin provides " .. tostring(name), 2) end
    local f = p[fn]
    if type(f) ~= "function" then error("interface " .. name .. " has no function " .. tostring(fn), 2) end
    local args = table.pack(...)
    for i = 1, args.n do check_value(args[i], 1); args[i] = deep_copy(args[i]) end
    mock.calls[#mock.calls + 1] = { name = name, fn = fn }
    local res = table.pack(f(table.unpack(args, 1, args.n)))
    for i = 1, res.n do check_value(res[i], 1); res[i] = deep_copy(res[i]) end
    return table.unpack(res, 1, res.n)
  end

  -- fb.store (permission store): revisions, stale-write conflicts. opts.store = false leaves it out.
  mock.store = { data = {}, revs = {}, puts = 0, conflicts = {} }
  if opts.store ~= false then
    for k, v in pairs(type(opts.store) == "table" and opts.store or {}) do
      mock.store.data[k] = deep_copy(v)
      mock.store.revs[k] = 1
    end
    fb.store = {
      get = function(key)
        if type(key) ~= "string" or not key:match("^[a-z0-9_.-]+$") or #key > 64 then error("store: bad key", 2) end
        local v = mock.store.data[key]
        if v == nil then return nil, 0 end
        return deep_copy(v), mock.store.revs[key]
      end,
      put = function(key, value, base)
        if type(key) ~= "string" or not key:match("^[a-z0-9_.-]+$") or #key > 64 then error("store: bad key", 2) end
        check_json_like(value, 1)
        mock.store.puts = mock.store.puts + 1
        local rev = mock.store.revs[key] or 0
        if base ~= nil and base ~= rev then
          local c = mock.store.conflicts[key] or {}
          c[#c + 1] = { value = deep_copy(value), revision = base, source = "local" }
          mock.store.conflicts[key] = c
          return nil, "conflict"
        end
        mock.store.data[key] = deep_copy(value)
        mock.store.revs[key] = rev + 1
        mock.store.conflicts[key] = nil
        return true, rev + 1
      end,
      conflicts = function(key) return deep_copy(mock.store.conflicts[key] or {}) end,
    }
    --- Simulates another PC writing first: the server's version replaces the local one.
    function mock.store_remote_write(key, value)
      mock.store.data[key] = deep_copy(value)
      mock.store.revs[key] = (mock.store.revs[key] or 0) + 1
    end
  end

  -- fb.run (permission run.state): opts.run = { current = { id, status, ... } }
  mock.run_events = {}
  if opts.run then
    mock.run = { current = deep_copy(opts.run.current), refuse = nil }
    fb.run = {
      current = function() return deep_copy(mock.run.current) end,
      event = function(spec)
        if type(spec) ~= "table" or type(spec.type) ~= "string" then error("event: type required", 2) end
        if spec.text ~= nil and (type(spec.text) ~= "string" or utf8.len(spec.text) > 280) then error("event: text too long", 2) end
        if spec.payload ~= nil then check_value(spec.payload, 1) end
        if mock.run.refuse then return nil, mock.run.refuse end
        mock.run_events[#mock.run_events + 1] = deep_copy(spec)
        return string.format("00000000-0000-4000-8000-%012d", #mock.run_events)
      end,
    }
  end

  -- fb.ui validates every tree against the documented catalog and records what was shown.
  local ui = { trees = {}, sets = {}, notes = {}, titles = {}, opened = {}, closed = {}, dot = nil, badge = nil }
  mock.ui = ui
  local function declared(slot)
    if opts.slots and not opts.slots[slot] then return false end
    return slot == "panel" or slot == "hud" or slot == "screen" or slot == "detail" or slot == "run"
      or slot:match("^tile:[%w_.%-]+$") ~= nil
  end
  fb.ui = {
    set = function(slot, tree)
      if not declared(slot) then error("slot " .. tostring(slot) .. " not declared in manifest", 2) end
      local ok, err = ui_validator.validate(tree)
      if not ok then error("ui tree: " .. err, 2) end
      ui.trees[slot] = deep_copy(tree)
      ui.sets[slot] = (ui.sets[slot] or 0) + 1
    end,
    patch = function(slot, id, props)
      local tree = ui.trees[slot]
      if not tree then error("no tree in slot " .. tostring(slot), 2) end
      local b = ui_validator.find(tree, id)
      if not b then error("unknown id " .. tostring(id), 2) end
      if props.type or props.id or props.children then error("patch: type/id/children not allowed", 2) end
      for k, v in pairs(props) do b[k] = deep_copy(v) end
    end,
    clear = function(slot) ui.trees[slot] = nil end,
    title = function(slot, text) ui.titles[slot] = text end,
    badge = function(n) ui.badge = n end,
    dot = function(kind) ui.dot = kind end,
    notify = function(n)
      if type(n) ~= "table" or type(n.text) ~= "string" or #n.text < 1 or #n.text > 300 then error("notify: bad text", 2) end
      if n.title and #n.title > 80 then error("notify: title too long", 2) end
      if n.tone and n.tone ~= "info" and n.tone ~= "important" and n.tone ~= "warning" then error("notify: bad tone", 2) end
      if n.actions and #n.actions > 2 then error("notify: at most 2 actions", 2) end
      ui.notes[#ui.notes + 1] = deep_copy(n)
      return #ui.notes
    end,
    on_action = function(fn) ui.handler = fn end,
  }
  if not opts.no_ui_open then
    fb.ui.open = function(slot)
      if slot ~= "screen" and slot ~= "panel" then error("open: slot " .. tostring(slot) .. " not supported", 2) end
      ui.opened[#ui.opened + 1] = slot
      return true
    end
    fb.ui.close = function(slot) ui.closed[#ui.closed + 1] = slot end
  end
  --- mock.action(action, value, slot) calls the registered fb.ui.on_action handler.
  function mock.action(action, value, slot) return ui.handler(action, deep_copy(value), slot) end
  --- mock.hotkey(id) presses a plugin hotkey.
  function mock.hotkey(id) return ui.handler(id, nil, "hotkey") end

  return mock
end

return M
