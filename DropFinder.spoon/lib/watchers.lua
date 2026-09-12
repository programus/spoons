--- watchers.lua — Event plumbing for DropFinder.spoon
-- Owns the subscriptions and the timing (debounce, settle delays); all state
-- changes happen in panel.lua.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

---@type any
local panel
---@type any
local log = hs.logger.new("DropFinder.watchers", "info")
---@type any
local cfg = nil

---@type table|nil
local paneFilter = nil
---@type table|nil
local appWatcher = nil
---@type table|nil
local screenWatcher = nil
---@type table|nil
local moveTimer = nil
---@type table|nil
local destroyTimer = nil
---@type function|nil
local prevShutdown = nil
---@type boolean
local shutdownHooked = false

function M.setDeps(deps)
  panel = deps.panel
  log   = deps.log or log
end

function M.setConfig(c) cfg = c end

--- Subscribe to everything.
function M.start()
  -- The filter is intentionally unconstrained.  Every tempting option here is a
  -- trap: `visible = true` and `allowRoles = {"AXStandardWindow"}` both drop a
  -- minimized pane, and minimized is exactly when its events matter most
  -- (Finder flips a minimized window's AXSubrole to AXDialog).  `currentSpace`
  -- and `allowScreens` drop a pane that is on another Space or another display,
  -- which is the other case we need to hear about.
  --
  -- Construction and subscribe are safe on the main loop.  filter:getWindows()
  -- is NOT -- it deadlocked Hammerspoon for over two minutes in testing, taking
  -- every hotkey in the session down with it.  Snapshots go through
  -- finder.snapshot() and app:allWindows() instead.
  paneFilter = hs.window.filter.new(false):setAppFilter("Finder", {})

  paneFilter:subscribe(hs.window.filter.windowCreated, function(win)
    -- Finder publishes the window before it has finished setting its target, so
    -- classifying immediately would read an empty path.
    hs.timer.doAfter(cfg.settleDelay, function()
      local ok, err = pcall(panel.onWindowCreated, win)
      if not ok then log.e("onWindowCreated: " .. tostring(err)) end
    end)
  end)

  paneFilter:subscribe(hs.window.filter.windowDestroyed, function()
    -- No argument is used on purpose: the window object is already dead.
    --
    -- Coalesced like windowMoved, and for a sharper reason: closing a pane with
    -- seven tabs emits seven of these, and each onWindowDestroyed costs three
    -- AppleScript queries plus an AX enumeration.  Run back to back that is
    -- seconds of main loop, and a busy main loop is the user's hotkeys not
    -- answering.  One pass after the last close reaches the same conclusion,
    -- because it diffs the whole model against a fresh snapshot rather than
    -- handling one id.
    if destroyTimer then destroyTimer:stop() end
    destroyTimer = hs.timer.doAfter(cfg.settleDelay, function()
      destroyTimer = nil
      local ok, err = pcall(panel.onWindowDestroyed)
      if not ok then log.e("onWindowDestroyed: " .. tostring(err)) end
    end)
  end)

  paneFilter:subscribe(hs.window.filter.windowMoved, function(win)
    if panel.isSuppressed() then return end
    if moveTimer then moveTimer:stop() end
    moveTimer = hs.timer.doAfter(0.3, function()
      moveTimer = nil
      local ok, err = pcall(panel.onWindowMoved, win)
      if not ok then log.e("onWindowMoved: " .. tostring(err)) end
    end)
  end)

  paneFilter:subscribe(hs.window.filter.windowMinimized, function(win)
    pcall(panel.onMinimizeChanged, win, true)
  end)

  paneFilter:subscribe(hs.window.filter.windowUnminimized, function(win)
    pcall(panel.onMinimizeChanged, win, false)
  end)

  paneFilter:subscribe(hs.window.filter.windowFocused, function(win)
    pcall(panel.onWindowFocused, win)
  end)

  -- ── Finder restarts ───────────────────────────────────────────────────
  appWatcher = hs.application.watcher.new(function(_, event, app)
    if not app or app:bundleID() ~= "com.apple.finder" then return end
    if event == hs.application.watcher.terminated then
      pcall(panel.onFinderTerminated)
    elseif event == hs.application.watcher.launched then
      -- Must be async: touching AX on a Finder that has just started blocks the
      -- main thread for tens of seconds.
      hs.timer.doAfter(1.5, function()
        local ok, err = pcall(panel.onFinderLaunched)
        if not ok then log.e("onFinderLaunched: " .. tostring(err)) end
      end)
    end
  end)
  appWatcher:start()

  -- ── Display changes ───────────────────────────────────────────────────
  screenWatcher = hs.screen.watcher.new(function()
    hs.timer.doAfter(0.5, function()
      local ok, err = pcall(panel.onScreensChanged)
      if not ok then log.e("onScreensChanged: " .. tostring(err)) end
    end)
  end)
  screenWatcher:start()

  -- ── Shutdown ──────────────────────────────────────────────────────────
  -- Chained politely so an existing callback still runs.  This only persists;
  -- it never calls stop(), which would move the user's windows during quit.
  if not shutdownHooked then
    prevShutdown = hs.shutdownCallback
    hs.shutdownCallback = function()
      pcall(panel.persistNow)
      if prevShutdown then prevShutdown() end
    end
    shutdownHooked = true
  end

  -- No hs.spaces.watcher: the toggle hotkey handles Space changes explicitly,
  -- and reacting to every Space switch would move the panel behind the user's
  -- back.
  log.d("watchers started")
end

--- Unsubscribe from everything and release it.
function M.stop()
  if paneFilter then
    paneFilter:unsubscribeAll()
    paneFilter = nil
  end
  if appWatcher then
    appWatcher:stop()
    appWatcher = nil
  end
  if screenWatcher then
    screenWatcher:stop()
    screenWatcher = nil
  end
  if moveTimer then
    moveTimer:stop()
    moveTimer = nil
  end
  if destroyTimer then
    destroyTimer:stop()
    destroyTimer = nil
  end
  -- Only give the shutdown callback back if it is still ours to give.
  if shutdownHooked then
    hs.shutdownCallback = prevShutdown
    prevShutdown = nil
    shutdownHooked = false
  end
  log.d("watchers stopped")
end

return M
