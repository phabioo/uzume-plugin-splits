-- Timer on two clocks: game time (snapshot frames) and real time (uz.clock milliseconds).
-- Pure: the caller passes the latest snapshot frame and the monotonic clock into every call.
-- Game time stops by itself when the snapshot frame stops (the game is paused). A frame number that goes
-- back (reset, loaded state) is a discontinuity: it counts nothing and becomes the new reference.
local T = {}
T.__index = T

function T.new()
  return setmetatable({ state = "idle", frames = 0, real = 0, last_frame = nil, last_now = nil }, T)
end

function T:reset()
  self.state, self.frames, self.real, self.last_frame, self.last_now = "idle", 0, 0, nil, nil
end

--- Adds what happened since the last call. Only a running timer accumulates.
function T:update(frame, now)
  if self.state == "running" then
    if frame ~= nil then
      if self.last_frame ~= nil and frame >= self.last_frame then
        self.frames = self.frames + (frame - self.last_frame)
      end
      self.last_frame = frame
    end
    if now ~= nil and self.last_now ~= nil and now > self.last_now then
      self.real = self.real + (now - self.last_now)
    end
    if now ~= nil then self.last_now = now end
  else
    if frame ~= nil then self.last_frame = frame end
    if now ~= nil then self.last_now = now end
  end
end

function T:start(frame, now)
  self.frames, self.real = 0, 0
  self.last_frame, self.last_now = frame, now
  self.state = "running"
end

function T:pause(frame, now)
  if self.state ~= "running" then return false end
  self:update(frame, now)
  self.state = "paused"
  return true
end

function T:resume(frame, now)
  if self.state ~= "paused" then return false end
  self:update(frame, now) -- not running: only moves the references
  self.state = "running"
  return true
end

--- Freezes the times (finished run).
function T:stop(frame, now)
  if self.state ~= "running" and self.state ~= "paused" then return false end
  self:update(frame, now)
  self.state = "finished"
  return true
end

--- Continues a finished run (undo of the last split); the time in between does not count.
function T:continue(frame, now)
  if self.state ~= "finished" then return false end
  self:update(frame, now)
  self.state = "running"
  return true
end

function T:game_ms(fps)
  return math.floor(self.frames * 1000 / fps + 0.5)
end

function T:real_ms()
  return math.floor(self.real + 0.5)
end

--- Elapsed time in the given timing method ("game" or "real").
function T:ms(timing, fps)
  if timing == "real" then return self:real_ms() end
  return self:game_ms(fps)
end

return T
