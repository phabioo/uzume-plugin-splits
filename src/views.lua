-- Declarative UI trees (HUD, panel, screen) built from a view model. Pure functions, no fb access.
local fmt = require("fmt")
local model = require("model")
local rules = require("rules")

local M = {}

local function tone_of(ms)
  if ms == nil then return nil end
  if ms < 0 then return "ok" end
  if ms > 0 then return "danger" end
  return "neutral"
end

local function text(props)
  props.type = "text"
  return props
end

-- HUD ----------------------------------------------------------------------------------------------------

function M.hud(vm, T)
  local alt
  if vm.state == "paused" then
    alt = T("hud.paused")
  elseif vm.alt_ms ~= nil then
    if vm.alt_timing == "real" then
      alt = T("hud.alt.real", { time = fmt.time(vm.alt_ms) })
    else
      alt = T("hud.alt.game", { time = fmt.time(vm.alt_ms) })
    end
  end
  local top = { text({ id = "time", text = fmt.time(vm.main_ms), style = "value" }) }
  if alt then top[#top + 1] = text({ id = "alt", text = alt, style = "meta" }) end
  local kids = { { type = "row", gap = 8, align = "center", children = top } }

  local name
  if #vm.rows == 0 then
    name = T("hud.no_splits")
  elseif vm.state == "idle" then
    name = T("hud.ready", { name = vm.rows[1].name })
  elseif vm.state == "finished" then
    name = vm.result and vm.result.pb and T("hud.new_pb") or T("hud.finished")
  else
    name = vm.cur_name or "-"
  end
  local line = { text({ id = "split", text = name, style = "body" }) }
  if vm.delta ~= nil then
    line[#line + 1] = text({ id = "delta", text = fmt.delta(vm.delta), style = "body", tone = tone_of(vm.delta) })
  end
  kids[#kids + 1] = { type = "row", gap = 8, align = "center", children = line }

  if vm.prev and vm.state ~= "idle" then
    local p = vm.prev
    local label = T("hud.prev", { name = p.name, time = p.delta ~= nil and fmt.delta(p.delta) or fmt.time(p.seg) })
    if p.gold then label = label .. " " .. T("hud.gold") end
    kids[#kids + 1] = text({ id = "prev", text = label, style = "meta", tone = p.gold and "warning" or tone_of(p.delta) })
  end
  return { type = "column", gap = 4, children = kids }
end

-- Panel --------------------------------------------------------------------------------------------------

-- in_screen: the screen has its own "Edit" tab, so it does not repeat the button that opens the editor.
local function controls(vm, T, in_screen)
  local primary
  if vm.state == "idle" then
    primary = { type = "button", label = T("btn.start"), action = "split", variant = "primary" }
  elseif vm.state == "running" then
    primary = { type = "button", label = T("btn.split"), action = "split", variant = "primary" }
  else
    primary = { type = "button", label = T("btn.split"), action = "split", variant = "secondary" }
  end
  local kids = {
    primary,
    { type = "button", label = T("btn.undo"), action = "undo", variant = "secondary" },
    { type = "button", label = T("btn.skip"), action = "skip", variant = "secondary" },
    { type = "button", label = (vm.state == "paused" and T("btn.resume") or T("btn.pause")), action = "pause", variant = "secondary" },
    -- Reset throws the current attempt away: marked as destructive (no dialog, it is also a hotkey).
    { type = "button", label = T("btn.reset"), action = "reset", variant = "danger" },
  }
  if not in_screen then kids[#kids + 1] = { type = "button", label = T("btn.edit"), action = "open", variant = "quiet" } end
  return { type = "grid", gap = 8, columns = 3, children = kids }
end

function M.panel(vm, T)
  if not vm.has_game then
    return { type = "empty", title = T("empty.no_game.title"), text = T("empty.no_game.text") }
  end
  if #vm.rows == 0 then
    return { type = "column", gap = 12, children = {
      { type = "empty", title = T("empty.no_splits.title"), text = T("empty.no_splits.text"),
        action_label = T("btn.edit"), action = "open" },
    } }
  end
  local rows = {}
  for _, r in ipairs(vm.rows) do
    local cells = {
      (r.current and "> " or "") .. r.name,
      r.time and fmt.time(r.time) or (r.skipped and "-" or ""),
      r.delta ~= nil and fmt.delta(r.delta) or "",
    }
    rows[#rows + 1] = { cells = cells }
  end
  local hud = M.hud(vm, T)
  return { type = "column", gap = 12, children = {
    hud,
    controls(vm, T),
    { type = "table", columns = { T("col.split"), T("col.time"), T("col.delta") }, rows = rows },
  } }
end

-- Screen -------------------------------------------------------------------------------------------------

local function stat(id, label, value)
  return { type = "stat", id = id, label = label, value = value }
end

local function run_page(vm, T)
  local rows = {}
  for _, r in ipairs(vm.rows) do
    rows[#rows + 1] = { cells = {
      (r.current and "> " or "") .. r.name,
      r.time and fmt.time(r.time) or "",
      r.delta ~= nil and fmt.delta(r.delta) or "",
      r.pb and fmt.time(r.pb) or "-",
      r.gold and fmt.time(r.gold) or "-",
      r.rule_text or "",
    } }
  end
  local kids = {
    { type = "grid", gap = 12, columns = 4, children = {
      stat("st_attempts", T("stat.attempts"), vm.attempts),
      stat("st_completed", T("stat.completed"), vm.completed),
      stat("st_pb", T("stat.pb"), vm.pb_total and fmt.time(vm.pb_total) or "-"),
      stat("st_sob", T("stat.sob"), vm.sob and fmt.time(vm.sob) or "-"),
    } },
    controls(vm, T, true),
  }
  if #rows == 0 then
    kids[#kids + 1] = { type = "empty", title = T("empty.no_splits.title"), text = T("empty.no_splits.text") }
  else
    kids[#kids + 1] = { type = "table",
      columns = { T("col.split"), T("col.time"), T("col.delta"), T("col.pb"), T("col.best"), T("col.rule") },
      rows = rows }
  end
  return { type = "column", gap = 16, children = kids }
end

local function opt(value, label) return { value = value, label = label } end

local FPS_OPTIONS = { "60", "59.83", "59.73" }

local function fps_value(fps)
  for _, o in ipairs(FPS_OPTIONS) do
    if math.abs(tonumber(o) - fps) < 0.005 then return o end
  end
  return nil
end

local function rule_section(ed, T)
  local d = ed.draft
  local name = "?"
  for _, s in ipairs(ed.list.splits) do
    if s.id == d.id then name = s.name end
  end
  local kids = {
    { type = "select", id = "rule_kind", action = "rule_kind", selected = d.kind, options = {
      opt("none", T("rule.kind.none")), opt("memory", T("rule.kind.memory")),
      opt("badge", T("rule.kind.badge")), opt("location", T("rule.kind.location")) } },
  }
  if d.kind == "memory" then
    local cmps = {}
    for _, c in ipairs(model.CMPS) do cmps[#cmps + 1] = opt(c, c == "changed" and T("rule.cmp.changed") or c) end
    local sizes = {}
    for _, s in ipairs(model.SIZE_LIST) do sizes[#sizes + 1] = opt(s, s) end
    kids[#kids + 1] = { type = "textfield", id = "rule_addr", action = "rule_addr", text = d.addr or "",
      placeholder = T("rule.addr") }
    kids[#kids + 1] = { type = "row", gap = 8, align = "center", children = {
      { type = "select", id = "rule_size", action = "rule_size", selected = d.size, options = sizes },
      { type = "select", id = "rule_cmp", action = "rule_cmp", selected = d.cmp, options = cmps },
    } }
    if d.cmp ~= "changed" then
      kids[#kids + 1] = { type = "textfield", id = "rule_value", action = "rule_value", text = d.value or "",
        placeholder = T("rule.value") }
    end
  elseif d.kind == "badge" then
    kids[#kids + 1] = { type = "textfield", id = "rule_badge", action = "rule_badge", text = d.badge or "",
      placeholder = T("rule.badge") }
    if not ed.core_available then
      kids[#kids + 1] = text({ text = T("rule.badge.needs_core"), style = "meta", tone = "warning" })
    end
  elseif d.kind == "location" then
    kids[#kids + 1] = { type = "textfield", id = "rule_zone", action = "rule_zone", text = d.zone or "",
      placeholder = T("rule.zone") }
    kids[#kids + 1] = { type = "button", id = "rule_zone_now", label = T("rule.zone_now"), action = "rule_zone_now",
      variant = "secondary" }
    if ed.zone_hint then kids[#kids + 1] = text({ text = ed.zone_hint, style = "meta" }) end
  end
  if d.error then
    kids[#kids + 1] = text({ id = "rule_error", text = T("rule.err." .. d.error), tone = "danger", style = "body" })
  end
  kids[#kids + 1] = { type = "row", gap = 8, children = {
    { type = "button", label = T("btn.save"), action = "rule_save", variant = "primary" },
    { type = "button", label = T("btn.cancel"), action = "rule_cancel", variant = "quiet" },
  } }
  return { type = "section", id = "rule_editor", title = T("rule.title", { name = name }), children = kids }
end

local function edit_page(vm, T, ed)
  local list = ed.list
  local kids = {}
  local fps_opts = {}
  for _, o in ipairs(FPS_OPTIONS) do fps_opts[#fps_opts + 1] = opt(o, T("fps_" .. o:gsub("%.", ""))) end
  kids[#kids + 1] = { type = "section", title = T("edit.timing"), children = {
    { type = "segmented", id = "timing", action = "timing", selected = list.timing, options = {
      opt("game", T("timing.game")), opt("real", T("timing.real")) } },
    text({ text = T("timing.hint"), style = "meta" }),
    { type = "select", id = "fps", action = "fps", selected = fps_value(list.fps), options = fps_opts },
    text({ text = T("fps.hint"), style = "meta" }),
  } }

  local rows = {}
  if #list.splits == 0 then
    rows[#rows + 1] = { type = "empty", title = T("empty.no_splits.title"), text = T("empty.no_splits.text") }
  end
  for i, s in ipairs(list.splits) do
    local row = { text({ text = tostring(i), style = "meta" }),
      { type = "textfield", id = "name_" .. s.id, action = "rename:" .. s.id, text = s.name } }
    row[#row + 1] = { type = "button", id = "rule_btn_" .. s.id, label = rules.summary(s.rule) or T("btn.rule"),
      action = "rule_edit", value = s.id, variant = s.rule and "secondary" or "quiet" }
    if not ed.locked then
      row[#row + 1] = { type = "button", id = "up_" .. s.id, label = "^", action = "move_up", value = s.id, variant = "quiet" }
      row[#row + 1] = { type = "button", id = "down_" .. s.id, label = "v", action = "move_down", value = s.id, variant = "quiet" }
      row[#row + 1] = { type = "button", id = "del_" .. s.id, label = "x", action = "delete", value = s.id, variant = "danger",
        confirm = { title = T("confirm.delete.title", { name = s.name }), text = T("confirm.delete.text"), danger = true } }
    end
    rows[#rows + 1] = { type = "row", gap = 8, align = "center", children = row }
  end
  local split_kids = rows
  if ed.locked then
    table.insert(split_kids, 1, text({ text = T("edit.locked"), style = "meta", tone = "warning" }))
  else
    split_kids[#split_kids + 1] = { type = "textfield", id = "add", action = "add", placeholder = T("edit.add") }
  end
  kids[#kids + 1] = { type = "section", title = T("edit.splits"), children = split_kids }
  if ed.draft then kids[#kids + 1] = rule_section(ed, T) end
  return { type = "column", gap = 16, children = kids }
end

local function io_page(vm, T, ed)
  local import_area = { type = "textarea", id = "import_area", action = "import_text", value = ed.import_text or "",
    lines = 8, mono = true, placeholder = T("io.import.placeholder") }
  if ed.import_error then import_area.error = ed.import_error end
  return { type = "column", gap = 16, children = {
    { type = "section", title = T("io.export"), children = {
      text({ text = T("io.export.hint"), style = "meta" }),
      { type = "textarea", id = "export_area", action = "export_view", value = ed.export_text, lines = 10, mono = true },
    } },
    { type = "section", title = T("io.import"), children = {
      text({ text = T("io.import.hint"), style = "meta" }),
      import_area,
      { type = "button", id = "import_apply", label = T("io.import.apply"), action = "import_apply", variant = "primary",
        confirm = { title = T("io.import.confirm.title"), text = T("io.import.confirm.text"), danger = true } },
      ed.locked and text({ text = T("edit.locked"), style = "meta", tone = "warning" }) or nil,
    } },
  } }
end

function M.screen(vm, T, ed)
  if not vm.has_game then
    return { type = "empty", title = T("empty.no_game.title"), text = T("empty.no_game.text") }
  end
  local tab = ed.tab or 1
  return { type = "tabs", id = "tabs", action = "tab", selected = tab,
    tabs = { T("tab.run"), T("tab.edit"), T("tab.io") },
    children = { run_page(vm, T), edit_page(vm, T, ed), io_page(vm, T, ed) } }
end

return M
