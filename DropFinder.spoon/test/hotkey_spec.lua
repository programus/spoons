-- Hotkey plumbing in init.lua: one action, any number of keys, and every handle
-- accounted for when the spoon stops.
--
-- This is the only suite that loads init.lua, so it is also the only place where
-- start() and stop() run at all offline.  The lib modules it pulls in are the
-- real ones; nothing here touches Finder, because the two Finder-facing calls in
-- start() are either switched off by the config (warnOnTotalFinder) or deferred
-- to a timer that this suite never fires.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local ROOT = HERE .. "/../"
local S = dofile(HERE .. "/stub.lua")
local W = dofile(HERE .. "/world.lua")

local pass, fail = 0, 0
local function ck(label, cond, extra)
  if cond then pass = pass + 1
  else
    fail = fail + 1
    print("  FAIL " .. label .. (extra ~= nil and ("  -> " .. tostring(extra)) or ""))
  end
end
local function section(n) print("== " .. n .. " ==") end

--- A fresh spoon on a stub Hammerspoon, plus the list of hotkeys it has bound.
-- `live` holds one entry per surviving hs.hotkey.bind, in binding order, and
-- entries disappear from it when the handle is deleted -- which is exactly the
-- question every check below asks.
local function boot(rawCfg)
  local hsStub = W.new()
  hs = hsStub

  local live = {}
  local function mkHotkey(mods, key, fn)
    local h = { mods = mods, key = key, fn = fn }
    function h:delete()
      for i, other in ipairs(live) do
        if other == self then table.remove(live, i); break end
      end
      self.deleted = true
      return self
    end
    live[#live + 1] = h
    return h
  end
  hs.hotkey = {
    bind = function(mods, key, fn) return mkHotkey(mods, key, fn) end,
    -- The real bindSpec takes the Spoon convention: { mods, key } plus an
    -- optional alert message before the function.
    bindSpec = function(spec, _msg, fn) return mkHotkey(spec[1], spec[2], fn) end,
  }
  hs.spoons = { resourcePath = function(rel) return ROOT .. rel end }
  hs.accessibilityState = function() return true end
  -- Watcher surfaces: constructed and subscribed to by watchers.start(), never
  -- fired here.  Distinct event names because they are used as table keys.
  local function watcherObj()
    local o = {}
    function o:start() self.started = true; return self end
    function o:stop() self.started = false; return self end
    return o
  end
  hs.window.filter = {
    new = function()
      local f = {}
      function f:setAppFilter() return self end
      function f:subscribe() return self end
      function f:unsubscribeAll() return self end
      function f:delete() return self end
      return f
    end,
    windowCreated = "created", windowDestroyed = "destroyed",
    windowMoved = "moved", windowMinimized = "min",
    windowUnminimized = "unmin", windowFocused = "focused",
  }
  hs.application.watcher = { new = watcherObj, launched = "launched",
                             terminated = "terminated" }
  hs.screen.watcher = { new = watcherObj }

  local cfg = { warnOnTotalFinder = false, persist = false }
  for k, v in pairs(rawCfg or {}) do cfg[k] = v end
  local obj = dofile(ROOT .. "init.lua")
  obj:configure(cfg)
  return obj, live
end

--- Is `key` with exactly `mods` among the live hotkeys?
local function has(live, mods, key)
  for _, h in ipairs(live) do
    if h.key == key and #h.mods == #mods then
      local same = true
      for i, m in ipairs(mods) do if h.mods[i] ~= m then same = false end end
      if same then return h end
    end
  end
  return nil
end

-- ── the declarative config path ───────────────────────────────────────────
section("cfg.hotkeys binds one key per action by default")
do
  local obj, live = boot()
  obj:start()
  ck("two hotkeys bound", #live == 2, #live)
  ck("toggle on ctrl+alt+f", has(live, { "ctrl", "alt" }, "f") ~= nil)
  ck("adopt on ctrl+alt+shift+f", has(live, { "ctrl", "alt", "shift" }, "f") ~= nil)
  obj:stop()
  ck("stop() unbinds them all", #live == 0, #live)
end

section("an action answers to every key in its list")
do
  local fired = 0
  local obj, live = boot({ hotkeys = { toggle = {
    { mods = { "alt" }, key = "`" },
    { mods = { "ctrl", "alt" }, key = "f" },
  } } })
  obj.toggle = function() fired = fired + 1 end
  obj:start()
  ck("three hotkeys bound", #live == 3, #live)
  local a = has(live, { "alt" }, "`")
  local b = has(live, { "ctrl", "alt" }, "f")
  ck("the first toggle key is bound", a ~= nil)
  ck("the second one too", b ~= nil)
  ck("adopt is still bound", has(live, { "ctrl", "alt", "shift" }, "f") ~= nil)
  if a and b then
    a.fn(); b.fn()
    -- The whole point: two keys, one action.  Binding the second key to
    -- something else, or to nothing, would show up right here.
    ck("both call toggle", fired == 2, fired)
  end
  obj:stop()
  -- The old code kept one handle per action, so a second key survived stop()
  -- and went on firing into a stopped spoon.
  ck("stop() unbinds the second key as well", #live == 0, #live)
end

section("hotkeys.<action> = false binds nothing for it")
do
  local obj, live = boot({ hotkeys = { adopt = false } })
  obj:start()
  ck("only the toggle key is bound", #live == 1, #live)
  ck("and it is the toggle key", has(live, { "ctrl", "alt" }, "f") ~= nil)
  obj:stop()
end

-- ── the hs.spoons mapping path ────────────────────────────────────────────
section("bindHotkeys replaces what the config bound")
do
  local toggled, adopted = 0, 0
  local obj, live = boot()
  obj.toggle = function() toggled = toggled + 1 end
  obj.adoptFrontmost = function() adopted = adopted + 1 end
  obj:start()
  ck("the config bound two", #live == 2, #live)
  obj:bindHotkeys({
    toggle          = { { "alt" }, "`" },
    adopt_frontmost = { { "alt", "shift" }, "`" },
  })
  ck("the config's keys are gone", has(live, { "ctrl", "alt" }, "f") == nil)
  ck("two new ones are bound", #live == 2, #live)
  local t = has(live, { "alt" }, "`")
  local a = has(live, { "alt", "shift" }, "`")
  ck("toggle on alt+`", t ~= nil)
  ck("adopt_frontmost on alt+shift+`", a ~= nil)
  if t and a then
    t.fn(); a.fn()
    ck("they reach the right actions", toggled == 1 and adopted == 1,
       toggled .. "/" .. adopted)
  end
  -- hs.spoons.bindHotkeysToSpec files its handles in a private table of its own,
  -- so hotkeys bound this way used to outlive stop() entirely.
  obj:stop()
  ck("stop() unbinds hotkeys bound this way too", #live == 0, #live)
end

section("bindHotkeys takes a list per action as well")
do
  local fired = 0
  local obj, live = boot()
  obj.toggle = function() fired = fired + 1 end
  obj:start()
  obj:bindHotkeys({ toggle = { { { "alt" }, "`" }, { { "ctrl" }, "pad0" } } })
  ck("both keys bound, nothing else", #live == 2, #live)
  local a = has(live, { "alt" }, "`")
  local b = has(live, { "ctrl" }, "pad0")
  ck("alt+` bound", a ~= nil)
  ck("ctrl+pad0 bound", b ~= nil)
  if a and b then
    a.fn(); b.fn()
    ck("both call toggle", fired == 2, fired)
  end
  obj:stop()
end

section("bindHotkeys ignores an action it does not have")
do
  local obj, live = boot()
  obj:start()
  obj:bindHotkeys({ nonesuch = { { "alt" }, "j" }, toggle = { { "alt" }, "`" } })
  ck("only the action it knows is bound", #live == 1, #live)
  ck("and it is toggle's key", has(live, { "alt" }, "`") ~= nil)
  obj:stop()
end

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
