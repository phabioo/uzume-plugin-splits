local t = require("t")
local model = require("model")
local textio = require("textio")
local H = require("harness")

t.case("rule text round trip", function()
  for _, s in ipairs({ "mem 0x2000 u8 = 5", "mem 0x2000 u16 changed", "mem 0xFFFFFFF0 u32 >= 4000", "badge 3", "zone 123" }) do
    local ok, rule = textio.parse_rule(s)
    t.ok(ok, s)
    local text = textio.rule_to_text(rule)
    local ok2, rule2 = textio.parse_rule(text)
    t.ok(ok2)
    t.eq(rule2, rule)
  end
  t.eq(textio.rule_to_text(nil), "-")
  local ok, r = textio.parse_rule("-")
  t.ok(ok and r == nil)
  ok, r = textio.parse_rule("mem 4096 u8 == 1")
  t.eq(r.addr, 4096)
  t.eq(r.cmp, "=")
end)

t.case("bad rule text", function()
  for _, s in ipairs({ "mem 0x10", "mem 0x10 u8", "mem zzz u8 = 1", "mem 0x10 u8 = x", "mem 0x10 u8 = 999", "badge 0", "badge x", "zone", "foo 1" }) do
    t.ok(not textio.parse_rule(s), s)
  end
end)

t.case("export and import round trip", function()
  local list = H.list({ "First", "Second", "Third" })
  list.fps = 59.83
  list.splits[1].rule = { kind = "memory", addr = 0x2000, size = "u8", cmp = "=", value = 5 }
  list.splits[3].rule = { kind = "badge", n = 2 }
  local att = model.new_attempt()
  model.record_split(list, att, 1000); model.record_skip(list, att); model.record_split(list, att, 4000)
  list.attempts = 7
  model.commit(list, att, true)
  local text = textio.export(list)
  local back = assert(textio.import(text))
  t.eq(back.timing, "game")
  t.eq(back.fps, 59.83)
  t.eq(back.attempts, 7)
  t.eq(back.completed, list.completed)
  t.eq(#back.splits, 3)
  for i = 1, 3 do
    t.eq(back.splits[i].name, list.splits[i].name)
    t.eq(back.splits[i].rule, list.splits[i].rule)
    t.eq(model.set(back).pb.times[back.splits[i].id], model.set(list).pb.times[list.splits[i].id])
    t.eq(model.set(back).golds[back.splits[i].id], model.set(list).golds[list.splits[i].id])
  end
  t.eq(model.set(back).pb.total, 4000)
  t.eq(textio.export(back), text, "second export is identical")
end)

t.case("plain names and comments", function()
  local list = assert(textio.import("# my splits\n\nCave\r\n  Forest  \n\nTower | zone 9\n", { timing = "real", fps = 60 }))
  t.eq(#list.splits, 3)
  t.eq(list.splits[2].name, "Forest")
  t.eq(list.splits[3].rule, { kind = "location", zone = 9 })
  t.eq(list.timing, "real")
  t.eq(model.set(list).pb, nil)
end)

t.case("import errors name the line", function()
  local function fails(text, code, line)
    local list, c, l = textio.import(text)
    t.eq(list, nil)
    t.eq(c, code)
    t.eq(l, line)
  end
  fails("", "empty", 1)
  fails("# only a comment", "empty", 1)
  fails("A\n@timing sideways\nB", "header", 2)
  fails("A\n@wat 1", "header", 2)
  fails("@fps abc\nA", "number", 1)
  fails("A | - | x | -", "number", 1)
  fails("A\nB | mem 1 u8", "rule", 2)
  fails(" | - | - | -", "name", 1)
end)

t.case("import limit", function()
  local lines = {}
  for i = 1, model.MAX_SPLITS + 1 do lines[#lines + 1] = "S" .. i end
  local list, code = textio.import(table.concat(lines, "\n"))
  t.eq(list, nil)
  t.eq(code, "too_many")
end)

t.case("pb total comes from the last split when the header is missing", function()
  local list = assert(textio.import("A | - | 1000 | 1000\nB | - | 2500 | 1500"))
  t.eq(model.set(list).pb.total, 2500)
  list = assert(textio.import("A | - | 1000 | -\nB | - | - | -"))
  t.eq(model.set(list).pb, nil, "no total, no PB")
end)

t.case("names with a pipe are kept readable", function()
  local list = H.list({ "Fire | Water" })
  t.eq(list.splits[1].name, "Fire / Water")
  t.eq(assert(textio.import(textio.export(list))).splits[1].name, "Fire / Water")
end)
