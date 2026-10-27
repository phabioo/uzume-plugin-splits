local t = require("t")
local fb_mock = require("fb_mock")
local J = require("json")

local LUA = (arg and arg[-1]) or "lua5.4"

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("a"); f:close()
  return s
end

t.case("bundle --check passes", function()
  local ok = os.execute(LUA .. " tools/bundle.lua --check > /dev/null 2>&1")
  t.ok(ok == true, "plugin/main.lua is stale; run tools/bundle.lua")
end)

t.case("plugin/main.lua runs in a sandbox without require/load/io/os", function()
  local mock = fb_mock.new({ game = { system = "nds", code = "ABCD", title = "Demo" } })
  local env = { fb = mock.fb }
  for _, n in ipairs({ "assert", "error", "getmetatable", "ipairs", "next", "pairs", "pcall", "select",
    "setmetatable", "tonumber", "tostring", "type", "xpcall", "rawequal", "rawget", "rawlen", "rawset",
    "string", "table", "math", "utf8", "coroutine" }) do
    env[n] = _G[n]
  end
  env.print = function(...) mock.fb.log.info(...) end
  env._VERSION = _VERSION
  for _, n in ipairs({ "require", "load", "loadstring", "dofile", "loadfile", "io", "os", "package", "debug" }) do
    t.eq(env[n], nil)
  end
  local chunk = assert(load(read("plugin/main.lua"), "=plugin/main.lua", "t", env))
  chunk()
  t.ok(mock.ui.trees.hud and mock.ui.trees.panel and mock.ui.trees.screen, "all three surfaces drawn")
  mock.action("add", "Split 1")
  mock.hotkey("split")
  mock.tick(5)
  t.ok(mock.store.data["splits.abcd"])
  for _, l in ipairs(mock.logs) do t.ok(l.level ~= "error", l.text) end
end)

local function manifest() return J.decode(read("plugin/manifest.json")) end

t.case("manifest fields", function()
  local m = manifest()
  t.eq(m.id, "uzume.splits")
  t.eq(m.api, 1)
  t.eq(m.type, "script")
  t.eq(m.games, nil, "no games filter: every game")
  t.eq(m.requires, nil, "pokemon.core is a soft dependency")
  t.ok(m.version:match("^%d+%.%d+%.%d+$"))
  local perms = {}
  for _, p in ipairs(m.permissions) do perms[p] = true end
  t.ok(perms["memory.read"] and perms.store and perms.ui and perms["run.state"])
  t.ok(m.ui.hud and m.ui.panel and m.ui.screen)
  t.eq(m.recap, { { type = "splits.pb", glyph = "note" } })
end)

t.case("hotkeys: valid ids, unique keys, no clash with the SoulLink plugin", function()
  local hk = manifest().ui.hotkeys
  t.ok(#hk <= 16)
  local ids, keys = {}, {}
  local soullink = { ["ctrl+h"] = true, ["ctrl+d"] = true, ["ctrl+r"] = true }
  for _, h in ipairs(hk) do
    t.ok(h.id:match("^[a-z0-9-]+$") and #h.id <= 32, h.id)
    t.ok(#h.label >= 1 and #h.label <= 60)
    t.ok(not ids[h.id], "duplicate id " .. h.id)
    ids[h.id] = true
    local k = h.key:lower()
    t.ok(not keys[k], "duplicate key " .. k)
    keys[k] = true
    t.ok(not soullink[k], "clashes with SoulLink: " .. k)
  end
  for _, need in ipairs({ "split", "undo", "skip", "reset", "pause" }) do t.ok(ids[need], need) end
end)

local function keys_of(path)
  local out = {}
  for k in pairs(fb_mock.read_json_flat(read(path))) do out[k] = true end
  return out
end

t.case("i18n: German has exactly the English keys", function()
  local en, de = keys_of("plugin/i18n/en.json"), keys_of("plugin/i18n/de.json")
  for k in pairs(en) do t.ok(de[k], "missing in de: " .. k) end
  for k in pairs(de) do t.ok(en[k], "extra in de: " .. k) end
end)

t.case("i18n: every key used in the sources exists, and every key is used", function()
  local en = keys_of("plugin/i18n/en.json")
  local p = assert(io.popen("ls src"))
  local used = {}
  local dynamic = { "rule.err.", "import.err.", "fps_" }
  for name in p:lines() do
    if name:match("%.lua$") then
      local src = read("src/" .. name)
      for key in src:gmatch('T%("([%w_.]+)"') do used[key] = true end
      for key in src:gmatch('fb%.i18n%.t%("([%w_.]+)"') do used[key] = true end
    end
  end
  p:close()
  for key in pairs(used) do
    if key:sub(-1) ~= "." and key:sub(-1) ~= "_" then t.ok(en[key], "undefined i18n key: " .. key) end -- "x.y." + code is dynamic
  end
  for key in pairs(en) do
    local dyn = false
    for _, prefix in ipairs(dynamic) do if key:sub(1, #prefix) == prefix then dyn = true end end
    t.ok(used[key] or dyn, "unused i18n key: " .. key)
  end
  for _, code in ipairs({ "addr", "value", "size", "cmp", "badge", "zone", "kind", "no_zone" }) do t.ok(en["rule.err." .. code]) end
  for _, code in ipairs({ "header", "number", "rule", "name", "empty", "too_many" }) do t.ok(en["import.err." .. code]) end
  for _, f in ipairs({ "60", "5983", "5973" }) do t.ok(en["fps_" .. f]) end
end)

t.case("i18n placeholders match between languages", function()
  local en = fb_mock.read_json_flat(read("plugin/i18n/en.json"))
  local de = fb_mock.read_json_flat(read("plugin/i18n/de.json"))
  for k, v in pairs(en) do
    local a, b = {}, {}
    for ph in v:gmatch("{([%w_]+)}") do a[#a + 1] = ph end
    for ph in de[k]:gmatch("{([%w_]+)}") do b[#b + 1] = ph end
    table.sort(a); table.sort(b)
    t.eq(b, a, k)
  end
end)
