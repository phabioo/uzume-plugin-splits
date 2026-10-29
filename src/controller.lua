-- Wires timer, split list, autosplitter, storage, UI and run events to the Uzume plugin API.
local fmt = require("fmt")
local model = require("model")
local rules = require("rules")
local textio = require("textio")
local timer = require("timer")
local util = require("util")
local views = require("views")

local App = {}
App.__index = App

local CORE_ID = "uzume.soullink-core" -- soft dependency: global events by id (no `requires`, no uz.call)
local PANEL_REFRESH_TICKS = 10

-- Frame rate guesses per system (the API has no frame rate; the user can change it in the editor).
local DEFAULT_FPS = { ["3ds"] = 59.83, nds = 59.83, gba = 59.73, gb = 59.73, gbc = 59.73 }

local function default_fps(system)
  return DEFAULT_FPS[system] or 60
end

--- Store key for the split list of a game: "splits.<game code>" (lower case, only [a-z0-9_.-]).
function App.store_key(game)
  local code = game and game.code
  if type(code) ~= "string" or code == "" then return nil end
  code = code:lower():gsub("[^a-z0-9_.-]", "_")
  return "splits." .. code:sub(1, 50)
end

function App.new(uz)
  local self = setmetatable({}, App)
  self.uz = uz
  self.T = function(key, vars) return uz.i18n.t(key, vars) end
  self.timer = timer.new()
  self.tab = 1
  self.ticks = 0
  self.names_seen = {}
  self.rev = 0
  self.shown = {}
  return self
end

local CLOCK_WATCH = "clock"

function App:frame()
  return self.uz.memory.frame() or self.last_frame
end

--- Brings the timer up to date with the latest snapshot frame and clock.
function App:sync()
  self.timer:update(self:frame(), self.uz.clock())
end

function App:notify(tone, title, body)
  pcall(self.uz.ui.notify, { tone = tone, title = title, text = body })
end

-- Storage -------------------------------------------------------------------------------------------------

function App:load()
  self.list, self.rev = nil, 0
  if not self.key then return end
  local value, rev = nil, 0
  if self.uz.store then
    local ok, v, r = pcall(self.uz.store.get, self.key)
    if ok then value, rev = v, r or 0 else self.uz.log.warn("store.get failed: " .. tostring(v)) end
  end
  self.rev = rev
  self.list = model.sanitize(value) or model.new_list("game", default_fps(self.uz.game.system))
  self:arm_aux()
end

function App:save()
  if not self.key or not self.list or not self.uz.store then return end
  local ok, res, why = pcall(self.uz.store.put, self.key, self.list, self.rev)
  if not ok then
    self.uz.log.warn("store.put failed: " .. tostring(res))
    self:notify("warning", self.T("store.failed.title"), self.T("store.failed.text"))
  elseif res == true then
    self.rev = why
  elseif why == "conflict" then
    self:notify("warning", self.T("store.conflict.title"), self.T("store.conflict.text"))
    self.stale = true
    self:reload_if_idle()
  else
    self.uz.log.warn("store.put refused: " .. tostring(why))
    self:notify("warning", self.T("store.failed.title"), self.T("store.failed.text"))
  end
end

--- Takes the stored version when nothing is running (a running attempt keeps its list until reset).
function App:reload_if_idle()
  if not self.stale then return end
  local st = self.timer.state
  if st == "running" or st == "paused" then return end
  self.stale = false
  self:load()
  self.att = nil
  self.draft = nil
  self:render_all()
end

-- Lifecycle -----------------------------------------------------------------------------------------------

function App:start()
  local uz = self.uz
  self.key = App.store_key(uz.game)
  self:load()
  -- The app copies a memory snapshot (frame number and ticks) only while a plugin watches a range, so game
  -- time needs one even without a rule. Address 0 may be unmapped: the snapshot still carries the frame.
  uz.memory.watch(CLOCK_WATCH, 0, 1)
  uz.on_tick(function(frame) self:tick(frame) end)
  uz.ui.on_action(function(a, v, s) self:action(a, v, s) end)
  uz.events.on(CORE_ID, "location.changed", function(v) self:on_location(v) end)
  uz.events.on(CORE_ID, "badges.changed", function(v) self:on_badges(v) end)
  uz.events.on("app", "store.changed", function(k)
    if k == self.key then
      self.stale = true
      self:reload_if_idle()
    end
  end)
  uz.events.on("app", "store.conflict", function(k)
    if k == self.key then
      self:notify("warning", self.T("store.conflict.title"), self.T("store.conflict.text"))
    end
  end)
  self:render_all()
end

-- Timer actions -------------------------------------------------------------------------------------------

function App:arm()
  self:arm_aux()
  if self.timer.state ~= "running" or not self.att then
    rules.disarm(self.uz)
    self.rule_state = nil
    return
  end
  local split = self.list.splits[model.current_index(self.att)]
  self.rule_state = rules.arm(self.uz, split and split.rule)
end

-- Start and reset rules (list-wide, optional, off by default). The start rule is armed while the timer is idle,
-- the reset rule while an attempt is running, paused or finished. Both use the autosplit rule evaluator, each
-- with its own memory watch ("start" / "reset"). A reset through the rule is an ordinary reset: best segments
-- of the attempt count, the personal best is never saved.
local AUX = { "start", "reset" }

--- The rule of `which` that is active in the current timer state (nil when none).
function App:aux_rule(which)
  local list = self.list
  if not list then return nil end
  local state = self.timer.state
  if which == "start" then
    return state == "idle" and #list.splits > 0 and list.start_rule or nil
  end
  return state ~= "idle" and list.reset_rule or nil
end

function App:arm_aux()
  self.aux = self.aux or {}
  for _, which in ipairs(AUX) do
    local rule = self:aux_rule(which)
    local cur = self.aux[which]
    if not rule then
      rules.disarm(self.uz, which)
      self.aux[which] = nil
    elseif not cur or cur.rule ~= rule then
      self.aux[which] = rules.arm(self.uz, rule, which) -- same rule table: keep the baseline
    end
  end
end

function App:fire_aux(which)
  if which == "start" then
    if self.timer.state == "idle" then self:start_run() end
  else
    self:reset()
  end
end

--- Evaluates the memory start / reset rules for one tick. Returns true when one fired and was applied.
function App:aux_tick()
  for _, which in ipairs({ "reset", "start" }) do
    local st = self.aux and self.aux[which]
    if st and st.rule.kind == "memory" and self:aux_rule(which) == st.rule and rules.step_memory(self.uz, st) then
      self:fire_aux(which)
      return true
    end
  end
  return false
end

--- Start / reset rules of the event kinds "location" and "badge". `matches(rule)` decides. True when one fired.
function App:aux_event(kind, matches)
  for _, which in ipairs({ "reset", "start" }) do
    local rule = self:aux_rule(which)
    if rule and rule.kind == kind and matches(rule) then
      self:fire_aux(which)
      return true
    end
  end
  return false
end

function App:start_run()
  if not self.list or #self.list.splits == 0 then return end
  self.att = model.new_attempt()
  self.result = nil
  self.backup = nil
  self.timer:start(self:frame(), self.uz.clock())
  self.list.attempts = self.list.attempts + 1
  self:save()
  self:arm()
end

function App:do_split()
  local list, att = self.list, self.att
  self.timer:update(self:frame(), self.uz.clock())
  local ms = self.timer:ms(list.timing, list.fps)
  if model.record_split(list, att, ms) then
    self:finish()
  else
    self:arm()
  end
end

function App:finish()
  local list, att = self.list, self.att
  local set = model.set(list)
  local old_sob = model.sum_of_best(list)
  self.backup = { pb = util.copy(set.pb), golds = util.copy(set.golds), completed = list.completed }
  self.timer:stop(self:frame(), self.uz.clock())
  local info = model.commit(list, att, true)
  self.result = { total = info.total, old_total = info.old_total, pb = info.pb, old_sob = old_sob }
  self:save()
  self:arm()
  if info.pb then self:post_pb(info) end
end

--- Run event "splits.pb" (a note in the run recap) when a run is open in the game.
function App:post_pb(info)
  local uz = self.uz
  if not uz.run or not uz.run.event then return end
  local ok, cur = pcall(uz.run.current)
  if not ok or not cur then return end
  local text = self.T("event.pb", { time = fmt.time(info.total) })
  local ok2, res, why = pcall(uz.run.event, {
    type = "splits.pb", text = text, source = "automatic",
    payload = { total_ms = info.total, timing = self.list.timing, splits = #self.list.splits },
  })
  if not ok2 then
    uz.log.warn("run event failed: " .. tostring(res))
  elseif res == nil then
    uz.log.info("run event refused: " .. tostring(why))
  end
end

function App:split_key()
  local st = self.timer.state
  if st == "idle" then
    self:start_run()
  elseif st == "running" then
    self:do_split()
  end
end

function App:undo()
  local st = self.timer.state
  if not self.att then return end
  if st == "finished" then
    if self.backup then
      local set = model.set(self.list)
      set.pb, set.golds, self.list.completed = self.backup.pb, self.backup.golds, self.backup.completed
      self.backup = nil
      self:save()
    end
    model.undo(self.att)
    self.result = nil
    self.timer:continue(self:frame(), self.uz.clock())
    self:arm()
  elseif st == "running" or st == "paused" then
    if model.undo(self.att) then self:arm() end
  end
end

function App:skip()
  if self.timer.state == "running" and model.record_skip(self.list, self.att) then self:arm() end
end

function App:reset()
  local st = self.timer.state
  if st == "idle" then return end
  if st ~= "finished" then
    model.commit(self.list, self.att, false) -- best segments of an unfinished attempt still count
  end
  self.timer:reset()
  self.att, self.result, self.backup = nil, nil, nil
  self:save()
  self:arm()
  self:reload_if_idle()
end

function App:pause()
  local st = self.timer.state
  if st == "running" then
    self.timer:pause(self:frame(), self.uz.clock())
    rules.disarm(self.uz)
    self.rule_state = nil
  elseif st == "paused" then
    self.timer:resume(self:frame(), self.uz.clock())
    self:arm()
  end
end

-- Autosplitter --------------------------------------------------------------------------------------------

function App:current_rule()
  if self.timer.state ~= "running" or not self.att then return nil end
  local split = self.list.splits[model.current_index(self.att)]
  return split and split.rule
end

function App:on_location(v)
  if type(v) ~= "table" or math.type(v.zone) ~= "integer" then return end
  self.last_zone = v.zone
  if type(v.name) == "string" and v.name ~= "" then self.names_seen[v.zone] = v.name end
  if self:aux_event("location", function(r) return r.zone == v.zone end) then
    self:render_all()
    return
  end
  local rule = self:current_rule()
  if rule and rule.kind == "location" and rule.zone == v.zone then
    self:do_split()
    self:render_all()
  end
end

function App:on_badges(v)
  if type(v) ~= "table" or type(v.new) ~= "table" then return end
  local function has(n)
    for _, x in pairs(v.new) do
      if x == n then return true end
    end
    return false
  end
  if self:aux_event("badge", function(r) return has(r.n) end) then
    self:render_all()
    return
  end
  local rule = self:current_rule()
  if not rule or rule.kind ~= "badge" then return end
  for _, n in pairs(v.new) do
    if n == rule.n then
      self:do_split()
      self:render_all()
      return
    end
  end
end

function App:autosplit()
  local rule = self:current_rule()
  if not rule or not self.rule_state then return false end
  if rule.kind == "memory" then
    return rules.step_memory(self.uz, self.rule_state)
  end
  return false
end

-- Tick ----------------------------------------------------------------------------------------------------

function App:tick(frame)
  self.last_frame = frame
  self.ticks = self.ticks + 1
  self.timer:update(frame, self.uz.clock())
  local changed = false
  if self:aux_tick() then
    changed = true
  elseif self.timer.state == "running" and self:autosplit() then
    self:do_split()
    changed = true
  end
  local st = self.timer.state
  if st == "running" or changed then
    self:render_hud()
    if changed or self.ticks % PANEL_REFRESH_TICKS == 0 then
      self:render_panel()
      if self.tab == 1 then self:render_screen() end
    end
  end
end

-- View model ----------------------------------------------------------------------------------------------

function App:vm()
  local list, att = self.list, self.att
  local vm = { has_game = list ~= nil, state = self.timer.state, rows = {}, attempts = 0, completed = 0 }
  if not list then return vm end
  local set = model.set(list)
  vm.timing = list.timing
  vm.main_ms = self.timer:ms(list.timing, list.fps)
  vm.alt_timing = list.timing == "game" and "real" or "game"
  if vm.state ~= "idle" then vm.alt_ms = self.timer:ms(vm.alt_timing, list.fps) end
  vm.attempts, vm.completed = list.attempts, list.completed
  vm.pb_total = set.pb and set.pb.total or nil
  vm.sob = model.sum_of_best(list)
  vm.compare = list.compare == "best" and "best" or "pb"
  vm.cmp_total = model.comparison_total(list)
  if vm.sob and vm.pb_total then vm.sob_gap = vm.pb_total - vm.sob end
  local cmp_times = model.comparison(list)
  vm.result = self.result
  local results = att and att.results or {}
  local active = vm.state == "running" or vm.state == "paused"
  local cur = att and model.current_index(att) or 1
  local last_done
  for i, s in ipairs(list.splits) do
    local r = results[i]
    local row = { id = s.id, name = s.name, current = active and i == cur, skipped = r and r.skipped or false,
      time = r and r.time or nil, pb = set.pb and set.pb.times[s.id] or nil, gold = set.golds[s.id],
      cmp = cmp_times[s.id], rule_text = rules.summary(s.rule) }
    if row.time and row.cmp then row.delta = row.time - row.cmp end
    if row.time then last_done = i end
    vm.rows[#vm.rows + 1] = row
  end
  if active and list.splits[cur] then
    vm.cur_name = list.splits[cur].name
    local pbc = vm.rows[cur].cmp
    if pbc and vm.main_ms > pbc then
      vm.delta = vm.main_ms - pbc
    elseif last_done then
      vm.delta = vm.rows[last_done].delta
    end
  elseif vm.state == "finished" and self.result then
    local old
    if vm.compare == "best" then old = self.result.old_sob else old = self.result.old_total end
    if old then vm.delta = self.result.total - old end
  end
  if last_done then
    vm.prev = { name = vm.rows[last_done].name, seg = model.segments(list, att)[last_done],
      delta = vm.rows[last_done].delta, gold = model.is_gold(list, att, last_done) }
  end
  return vm
end

-- Rendering -----------------------------------------------------------------------------------------------

-- Remove every `disabled` prop (apps before Uzume 0.22 reject the unknown key).
local function strip_disabled(b)
  if type(b) ~= "table" then return end
  b.disabled = nil
  for _, c in ipairs(b.children or {}) do strip_disabled(c) end
end

-- `disabled` (Uzume 0.22) is emitted whenever an action makes no sense. The plugin API exposes no app version, so
-- the first tree with `disabled` is tried as is; when the app raises because of that key, `disabled` is dropped
-- for this and all later trees (the buttons then stay clickable and the actions ignore the call as before).
function App:set_if_changed(slot, tree)
  if self.no_disabled then strip_disabled(tree) end
  local key = util.ser(tree)
  if self.shown[slot] == key then return end
  local ok, err = pcall(self.uz.ui.set, slot, tree)
  if not ok then
    if not self.no_disabled and tostring(err):find("disabled", 1, true) then
      self.no_disabled = true
      strip_disabled(tree)
      key = util.ser(tree)
      if self.shown[slot] == key then return end
      self.uz.ui.set(slot, tree)
    else
      error(err, 0)
    end
  end
  self.shown[slot] = key
end

function App:render_hud()
  if not self.list then return end
  self:set_if_changed("hud", views.hud(self:vm(), self.T))
end

function App:render_panel()
  self:set_if_changed("panel", views.panel(self:vm(), self.T))
end

function App:editor_state()
  local locked = self.timer.state == "running" or self.timer.state == "paused"
  local hint
  if self.draft and self.draft.kind == "location" then
    local zone = tonumber(self.draft.zone or "")
    local name = zone and self.names_seen[zone]
    if name then hint = name end
  end
  return { list = self.list, tab = self.tab, locked = locked, draft = self.draft, import_text = self.import_text,
    import_error = self.import_error, export_text = self.list and textio.export(self.list) or "",
    zone_hint = hint }
end

function App:render_screen()
  self:set_if_changed("screen", views.screen(self:vm(), self.T, self:editor_state()))
end

function App:render_all()
  self:render_hud()
  self:render_panel()
  self:render_screen()
end

-- Actions -------------------------------------------------------------------------------------------------

local function structure_locked(self)
  local st = self.timer.state
  return st == "running" or st == "paused"
end

local function mutate(self, fn)
  if not self.list then return false end
  local ok = fn(self.list)
  if ok ~= false then self:save() end
  return ok ~= false
end

local LIST_RULE = { ["@start"] = "start_rule", ["@reset"] = "reset_rule" }

local function new_draft(self, id)
  local split, r
  if LIST_RULE[id] then
    split = {}
    r = self.list[LIST_RULE[id]]
  else
    for _, s in ipairs(self.list.splits) do
      if s.id == id then split = s end
    end
    if not split then return nil end
    r = split.rule
  end
  local d = { id = id, kind = "none", size = "u8", cmp = "=" }
  if r then
    d.kind = r.kind
    if r.kind == "memory" then
      d.addr, d.size, d.cmp = string.format("0x%X", r.addr), r.size, r.cmp
      d.value = r.value ~= nil and tostring(r.value) or ""
    elseif r.kind == "badge" then
      d.badge = tostring(r.n)
    elseif r.kind == "location" then
      d.zone = tostring(r.zone)
    end
  end
  return d
end

local function draft_rule(d)
  if d.kind == "none" then return true, nil end
  local function int(s)
    local n = tonumber(s)
    return n and math.type(n) == "integer" and n or nil
  end
  if d.kind == "memory" then
    local addr = int(d.addr)
    if not addr then return false, "addr" end
    local rule = { kind = "memory", addr = addr, size = d.size, cmp = d.cmp }
    if d.cmp ~= "changed" then
      rule.value = int(d.value)
      if rule.value == nil then return false, "value" end
    end
    return model.normalize_rule(rule)
  elseif d.kind == "badge" then
    return model.normalize_rule({ kind = "badge", n = int(d.badge) })
  elseif d.kind == "location" then
    return model.normalize_rule({ kind = "location", zone = int(d.zone) })
  end
  return false, "kind"
end

local function current_zone(self)
  if self.last_zone then return self.last_zone end
  local ok, loc = pcall(self.uz.call, "pokemon.core", "location")
  if ok and type(loc) == "table" and math.type(loc.zone) == "integer" then
    if type(loc.name) == "string" then self.names_seen[loc.zone] = loc.name end
    return loc.zone
  end
  return nil
end

local H = {}

function H.split(self) self:split_key() end
function H.undo(self) self:undo() end
function H.skip(self) self:skip() end
function H.reset(self) self:reset() end
function H.pause(self) self:pause() end
function H.open(self)
  if self.uz.ui.open then self.uz.ui.open("screen") end
end
function H.tab(self, v)
  if math.type(v) == "integer" and v >= 1 and v <= 3 then self.tab = v end
end
function H.timing(self, v)
  if structure_locked(self) or (v ~= "game" and v ~= "real") then return end
  mutate(self, function(l) l.timing = v end)
end
function H.compare(self, v)
  if v ~= "pb" and v ~= "best" then return end
  mutate(self, function(l) l.compare = v end)
end
function H.fps(self, v)
  local n = tonumber(v)
  if structure_locked(self) or not n or n < 1 or n > 240 then return end
  mutate(self, function(l) l.fps = n end)
end
function H.add(self, v)
  if structure_locked(self) then return end
  local id, why = nil, nil
  mutate(self, function(l)
    id, why = model.add(l, v)
    return id ~= nil
  end)
  if not id and why == "full" then
    self:notify("warning", self.T("edit.full.title"), self.T("edit.full.text", { max = model.MAX_SPLITS }))
  end
end
function H.move_up(self, v)
  if structure_locked(self) then return end
  mutate(self, function(l) return model.move(l, v, -1) end)
end
function H.move_down(self, v)
  if structure_locked(self) then return end
  mutate(self, function(l) return model.move(l, v, 1) end)
end
function H.delete(self, v)
  if structure_locked(self) then return end
  if self.draft and self.draft.id == v then self.draft = nil end
  mutate(self, function(l) return model.delete(l, v) end)
end
function H.rule_edit(self, v)
  if self.list then self.draft = new_draft(self, v) end
end
function H.rule_kind(self, v)
  if self.draft and (v == "none" or v == "memory" or v == "badge" or v == "location") then
    self.draft.kind, self.draft.error = v, nil
  end
end
local function draft_field(name)
  return function(self, v)
    if self.draft then
      self.draft[name] = tostring(v or "")
      self.draft.error = nil
    end
  end
end
H.rule_addr = draft_field("addr")
H.rule_value = draft_field("value")
H.rule_badge = draft_field("badge")
H.rule_zone = draft_field("zone")
function H.rule_size(self, v)
  if self.draft and model.SIZES[v] then self.draft.size = v end
end
function H.rule_cmp(self, v)
  if self.draft then self.draft.cmp = v end
end
function H.rule_zone_now(self)
  if not self.draft then return end
  local zone = current_zone(self)
  if zone then
    self.draft.zone = tostring(zone)
    self.draft.error = nil
  else
    self.draft.error = "no_zone"
  end
end
function H.rule_save(self)
  local d = self.draft
  if not d then return end
  local ok, rule = draft_rule(d)
  if not ok then
    d.error = rule
    return
  end
  if LIST_RULE[d.id] then
    mutate(self, function(l) return model.set_list_rule(l, LIST_RULE[d.id], rule) end)
  else
    mutate(self, function(l) return model.set_rule(l, d.id, rule) end)
  end
  self.draft = nil
  self:arm_aux()
  if self.timer.state == "running" then self:arm() end
end
function H.rule_cancel(self) self.draft = nil end
function H.import_text(self, v)
  self.import_text = tostring(v or "")
  self.import_error = nil
end
function H.export_view() end
function H.import_apply(self)
  if structure_locked(self) or not self.list then return end
  local list, code, line = textio.import(self.import_text or "", { timing = self.list.timing, fps = self.list.fps, compare = self.list.compare })
  if not list then
    self.import_error = self.T("import.err." .. code, { line = line })
    return
  end
  list.attempts = math.max(list.attempts, 0)
  self.list = list
  self.timer:reset()
  self.att, self.result, self.backup = nil, nil, nil
  self.draft, self.import_error = nil, nil
  self:save()
  self:arm() -- re-arms the start / reset watches for the imported rules
  self.tab = 2
end

local PREFIX = {}
function PREFIX.rename(self, id, v)
  mutate(self, function(l) return model.rename(l, id, v) end)
end

function App:action(action, value, slot)
  self:sync()
  local h = H[action]
  if h then
    h(self, value)
  else
    local name, arg = tostring(action):match("^(%a+):(.+)$")
    if name and PREFIX[name] then PREFIX[name](self, arg, value) end
  end
  if action == "import_text" or action == "export_view" then return end -- typing: do not redraw under the cursor
  self:render_all()
end

App.default_fps = default_fps

return App
