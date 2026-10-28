-- Boots the plugin sources against the fake uz.
local uz_mock = require("uz_mock")
local model = require("model")

local H = {}
H.GAME = { system = "nds", code = "ABCD", title = "Demo Game" }
H.KEY = "splits.abcd"

--- A stored list with the given split names (fps 60 so 60 frames are exactly one second).
function H.list(names, timing)
  local l = model.new_list(timing or "game", 60)
  for _, n in ipairs(names) do model.add(l, n) end
  return l
end

--- opts as uz_mock.new; opts.names seeds the store with a list of that many named splits.
function H.boot(opts)
  opts = opts or {}
  opts.game = opts.game or H.GAME
  if opts.names then
    opts.store = opts.store or {}
    opts.store[H.KEY] = H.list(opts.names)
    opts.names = nil
  end
  local mock = uz_mock.new(opts)
  local App = require("controller")
  local app = App.new(mock.uz)
  app:start()
  mock.tick(1) -- first snapshot: gives the timer a frame reference
  return mock, app
end

--- Text of the block with the given id in a slot's tree.
function H.text(mock, slot, id)
  local b = require("ui_validator").find(mock.ui.trees[slot], id)
  return b and b.text
end

return H
