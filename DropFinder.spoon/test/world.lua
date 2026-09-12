-- A simulator for the parts of macOS and Finder that panel.lua talks to.
-- Every behaviour here is one of the Phase 0 measurements:
--   * AX exposes only a window's ACTIVE tab -- except while minimized, when it
--     exposes them all.
--   * AppleScript sees every tab, and its window ids are the same numbers
--     hs.window:id() returns.
--   * AppKit refuses to put a window fully off the desktop: at least 40px
--     horizontally and 52px vertically stay inside the screen union.
--   * Finder refuses to be shorter than 344px (with a toolbar).
-- Locate ourselves so the suite runs from anywhere; DF_LIB lets the mutation
-- harness point the same tests at a patched copy of lib/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local S = dofile(HERE .. "/stub.lua")

local W = {}

local FINDER = "com.apple.finder"
local MIN_H  = 344            -- Finder's floor, with a toolbar
local CLAMP_X, CLAMP_Y = 40, 52

local function copy(r) return { x = r.x, y = r.y, w = r.w, h = r.h } end
local function basename(p) return (p:match("([^/]+)/?$")) or p end

function W.new(screens, opts)
  opts = opts or {}
  local hs = S.install(screens or S.REAL_SCREENS, opts)

  local world = {
    nextId    = 45000,
    windows   = {},              -- real macOS windows
    frontmost = "com.other.app",
    focusedId = nil,
    now       = 1000,
    timers    = {},
    log       = {},
    finderRunning = true,
  }

  -- ── clock and timers (drained explicitly, so tests are deterministic) ────
  hs.timer.secondsSinceEpoch = function() return world.now end
  hs.timer.doAfter = function(sec, fn)
    world.timers[#world.timers + 1] = { at = world.now + (sec or 0), fn = fn }
    return { stop = function() end }
  end

  --- Run every pending timer callback, including ones they schedule.
  function world.drain(limit)
    for _ = 1, (limit or 50) do
      if #world.timers == 0 then return end
      local due = world.timers
      world.timers = {}
      table.sort(due, function(a, b) return a.at < b.at end)
      for _, t in ipairs(due) do
        world.now = math.max(world.now, t.at)
        t.fn()
      end
    end
    error("timer queue did not settle")
  end

  --- Run exactly one round of due timers.  Lets a test interrupt an async
  --- sequence part-way through, which is where the interesting races live.
  --@return integer  how many callbacks ran
  function world.step()
    local due = world.timers
    world.timers = {}
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do
      world.now = math.max(world.now, t.at)
      t.fn()
    end
    return #due
  end

  function world.advance(sec) world.now = world.now + sec end

  -- ── the AppKit / Finder frame constraints ────────────────────────────────

  --- The screen constrainFrameRect:toScreen: would pick: the one the rect
  --- overlaps most, or, when it overlaps none, the nearest one by centre.
  --- Deliberately per-screen rather than against the union rect: a staggered
  --- layout has holes in its union (here, everything below y=1341 to the right
  --- of x=2560), and clamping to the union would happily park a window in one.
  local function bestScreen(rect)
    local best, bestArea, bestDist
    for _, s in ipairs(hs.screen.allScreens()) do
      local f = s:fullFrame()
      local iw = math.min(rect.x + rect.w, f.x + f.w) - math.max(rect.x, f.x)
      local ih = math.min(rect.y + rect.h, f.y + f.h) - math.max(rect.y, f.y)
      local area = (iw > 0 and ih > 0) and (iw * ih) or 0
      local dx = (rect.x + rect.w / 2) - (f.x + f.w / 2)
      local dy = (rect.y + rect.h / 2) - (f.y + f.h / 2)
      local dist = dx * dx + dy * dy
      if not best
         or area > bestArea
         or (area == bestArea and area == 0 and dist < bestDist) then
        best, bestArea, bestDist = s, area, dist
      end
    end
    return best
  end

  local function constrain(rect)
    local f = bestScreen(rect):fullFrame()
    local h = math.max(rect.h, MIN_H)
    local w = rect.w
    local x = math.min(rect.x, f.x + f.w - CLAMP_X)
    x = math.max(x, f.x + CLAMP_X - w)
    local y = math.min(rect.y, f.y + f.h - CLAMP_Y)
    y = math.max(y, f.y)
    return { x = x, y = y, w = w, h = h }
  end
  world.constrain = constrain

  -- ── fake hs.window ──────────────────────────────────────────────────────
  local function mkwin(rw, tabIndex)
    local o = {}
    function o:id() return rw.tabs[tabIndex] and rw.tabs[tabIndex].id or nil end
    -- staleFrame models a read-back that has not settled yet; see setFrame.
    function o:frame() return copy(rw.staleFrame or rw.frame) end
    function o:setFrame(rect)
      local prev   = rw.frame
      local target = constrain(rect)
      -- Measured: a move that crosses displays reads back for a moment with the
      -- *old* screen's bottom-edge clamp still applied, and the retry inside
      -- applyFrame is not late enough to miss it either.  The window is already
      -- where it belongs; only the read is behind.
      if opts.staleFrameReads and bestScreen(prev) ~= bestScreen(target) then
        local pf = bestScreen(prev):fullFrame()
        rw.staleFrame = { x = target.x, y = target.y, w = target.w,
                          h = math.min(target.h,
                                       math.max(MIN_H, pf.y + pf.h - target.y)) }
        hs.timer.doAfter(0.05, function() rw.staleFrame = nil end)
      end
      rw.frame = target
      rw.setFrameCount = (rw.setFrameCount or 0) + 1
      -- Measured on the three-display Mac: a window that *arrives on a display*
      -- joins whatever Space is showing there, with no hs.spaces call involved.
      -- That is the half of requirement 10 that works, and the reason a pane
      -- parked on another display needs no Space move at all.
      -- Only a move that changes display does this.  A Space belongs to one
      -- display, so sliding a window around inside its own display cannot carry
      -- it to a different Space -- and nothing measured says otherwise: the
      -- window in the experiment came over because it crossed from one display
      -- to another.  Modelling every setFrame as a Space change would quietly
      -- excuse the "activate" fallback from ever having to admit it is stuck.
      local from, to = bestScreen(prev), world.screenOfRW(rw)
      local active = world.spaceOfScreen[to]
      if active and from ~= to then world.spaceOfWindow[rw] = active end
      -- macOS emits windowMoved for our own moves too, which is exactly why the
      -- panel has a suppression window; deliver it so that gate gets tested.
      if world.onMoved then world.onMoved(mkwin(rw, rw.active)) end
    end
    function o:isMinimized() return rw.minimized end
    function o:isFullScreen() return rw.fullscreen or false end
    function o:setFullScreen(v) rw.fullscreen = v end
    function o:raise()
      rw.raised = (rw.raised or 0) + 1
      -- The asymmetry the panel's raise order exists for: AXRaise on a window of
      -- the *active* app lifts it to the top of the screen, while on a
      -- background app's window it only reorders that app's own stack.
      if world.frontmost == FINDER then world.zToFront(rw) else world.zToFrontOfFinder(rw) end
    end
    function o:focus()
      world.frontmost = FINDER
      world.focusedId = o:id()
      rw.focused = (rw.focused or 0) + 1
      -- Activating an app lifts its key window, and only that one.
      world.zToFront(rw)
    end
    -- "The screen the window is mostly on", like hs.window:screen() -- not the
    -- screen under its centre.  The difference is the whole point for a parked
    -- pane: its centre is off in the void past the corner, while the 40x52px that
    -- is still visible sits squarely on one display, and that display is the one
    -- whose Space the window belongs to (measured).
    function o:screen() return world.screenOfRW(rw) end
    o._rw = rw
    return o
  end
  world.mkwin = mkwin

  --- The display a real window is mostly on, the way hs.window:screen() decides.
  function world.screenOfRW(rw)
    local best, bestArea = nil, 0
    for _, s in ipairs(hs.screen.allScreens()) do
      local f = s:fullFrame()
      local ow = math.max(0, math.min(rw.frame.x + rw.frame.w, f.x + f.w) - math.max(rw.frame.x, f.x))
      local oh = math.max(0, math.min(rw.frame.y + rw.frame.h, f.y + f.h) - math.max(rw.frame.y, f.y))
      if ow * oh > bestArea then best, bestArea = s, ow * oh end
    end
    return best or hs.screen.mainScreen()
  end

  hs.application.frontmostApplication = function()
    local app = {}
    function app:bundleID() return world.frontmost end
    function app:focusedWindow()
      if world.frontmost ~= FINDER or not world.focusedId then return nil end
      for _, rw in ipairs(world.windows) do
        for i, t in ipairs(rw.tabs) do
          if t.id == world.focusedId then return mkwin(rw, i) end
        end
      end
      return nil
    end
    return app
  end
  --- Move the mouse to display `i` (1-based, in hs.screen.allScreens() order).
  function world.setMouseScreen(i)
    hs.mouse.getCurrentScreen = function() return hs.screen.allScreens()[i] end
  end

  hs.application.launchOrFocusByBundleID = function(bid)
    world.frontmost = bid
    world.focusedId = nil
    -- Activating an app brings its window forward, over anything that was in
    -- front of it -- a Finder window the user was working in included.  That is
    -- how requirement 12's restore turned into a defect, so the order has to
    -- model it.
    if bid ~= FINDER then world.zToFront("other") end
    -- Activating Finder is what wakes it: measured, this is the point at which
    -- `count windows` stops answering 0 and every window becomes addressable.
    if bid == FINDER and not world.stickyAsleep then world.finderAsleep = false end
    world.log[#world.log + 1] = "launchOrFocus:" .. bid
    return true
  end

  -- ── world manipulation, i.e. "what the user did" ─────────────────────────

  --- Open a window Finder-style, at Finder's own default position.
  function world.newWindow(paths, frame)
    local rw = { tabs = {}, active = 1, minimized = false,
                 frame = frame or { x = 100, y = 100, w = 920, h = 436 } }
    for _, p in ipairs(paths) do
      world.nextId = world.nextId + 5
      rw.tabs[#rw.tabs + 1] = { id = world.nextId, path = p }
    end
    world.windows[#world.windows + 1] = rw
    -- Measured: a window made while standing on another Space lands on the Space
    -- you are standing on, not on the one its siblings are on -- which is the
    -- whole reason the recreate fallback can do what moveWindowToSpace cannot.
    local active = world.spaceOfScreen[world.screenOfRW(rw)]
    if active then world.spaceOfWindow[rw] = active end
    -- A window Finder makes while it is in the background does not jump the
    -- queue; it lands in front of Finder's own windows only.
    if world.frontmost == FINDER then world.zToFront(rw) else world.zToFrontOfFinder(rw) end
    return rw
  end

  --- Add a tab to an existing window, the way Cmd+T does: it becomes active.
  function world.addTab(rw, path)
    world.nextId = world.nextId + 5
    rw.tabs[#rw.tabs + 1] = { id = world.nextId, path = path }
    rw.active = #rw.tabs
    return rw.tabs[#rw.tabs].id
  end

  --- The user dragged a tab along the tab bar.  Same tabs, same ids, new order.
  function world.reorderTabs(rw, order)
    local activeId = rw.tabs[rw.active].id
    local tabs = {}
    for _, i in ipairs(order) do tabs[#tabs + 1] = rw.tabs[i] end
    rw.tabs = tabs
    for i, t in ipairs(rw.tabs) do
      if t.id == activeId then rw.active = i end
    end
  end

  function world.closeTabById(id)
    for wi, rw in ipairs(world.windows) do
      for ti, t in ipairs(rw.tabs) do
        if t.id == id then
          table.remove(rw.tabs, ti)
          if #rw.tabs == 0 then table.remove(world.windows, wi)
          elseif rw.active > #rw.tabs then rw.active = #rw.tabs end
          return true
        end
      end
    end
    return false
  end

  -- ── Global window order ─────────────────────────────────────────────────
  -- macOS keeps ONE order for every app's windows, front to back.  "other"
  -- stands for the window of whatever app the user was in when the hotkey was
  -- pressed; what the panel has to end up doing is getting both panes in front
  -- of it.  This is the one model here derived from a *defect* rather than from a
  -- Phase 0 measurement: raising both panes and then focusing one left the
  -- sibling behind the user's window, which is what the user saw and reported.
  world.zorder = { "other" }

  local function zremove(tok)
    for i, x in ipairs(world.zorder) do
      if x == tok then table.remove(world.zorder, i); return i end
    end
    return nil
  end

  --- To the very front of the screen.
  function world.zToFront(tok)
    zremove(tok)
    table.insert(world.zorder, 1, tok)
  end

  --- In front of Finder's other windows, but no further: a background app's
  --- window cannot jump over the active app's just by being raised.
  function world.zToFrontOfFinder(tok)
    zremove(tok)
    for i, x in ipairs(world.zorder) do
      if x ~= "other" then table.insert(world.zorder, i, tok); return end
    end
    world.zorder[#world.zorder + 1] = tok
  end

  --- Front-to-back position, or nil when the window is not in the order at all.
  function world.zIndex(tok)
    for i, x in ipairs(world.zorder) do
      if x == tok then return i end
    end
    return nil
  end

  --- The user clicks into another app: it activates and its window comes forward.
  function world.activateOther(bid)
    world.frontmost = bid or "com.other.app"
    world.focusedId = nil
    world.zToFront("other")
  end

  function world.closeWindow(rw)
    zremove(rw)
    for wi, x in ipairs(world.windows) do
      if x == rw then table.remove(world.windows, wi); return true end
    end
    return false
  end

  function world.findWindowByPath(path)
    for _, rw in ipairs(world.windows) do
      for _, t in ipairs(rw.tabs) do
        if t.path == path then return rw end
      end
    end
    return nil
  end

  --- The user navigated a tab somewhere else (double-clicked a folder in it).
  --- Finder reuses the tab, so the id does not change -- only its target does.
  function world.navigate(id, path)
    local rw, i = world.windowOfId(id)
    if not rw then return false end
    rw.tabs[i].path = path
    return true
  end

  function world.windowOfId(id)
    for _, rw in ipairs(world.windows) do
      for i, t in ipairs(rw.tabs) do
        if t.id == id then return rw, i end
      end
    end
    return nil
  end

  -- ── the fake finder module (same API as lib/finder.lua) ──────────────────
  local F = {}
  function F.setLogger() end
  function F.app() return world.finderRunning and {} or nil end
  function F.ensureRunning(cb) cb(F.app()) end
  function F.automationAvailable() return true, nil end
  function F.totalFinderInjected(cb) return cb(false) end

  function F.snapshot()
    if not world.finderRunning then return nil, "Finder is not running" end
    -- Measured, and the nastier half of `world.finderAsleep`: a Finder that has
    -- just relaunched answers `id of every window` with *nothing* rather than
    -- with an error, while the windows it restored are plainly there in the AX
    -- tree.  An empty list is not the same claim as a failure, and believing it
    -- is how two freshly created panes vanished with nothing in the log.
    if world.finderAsleep then return {}, nil end
    local out = {}
    for _, rw in ipairs(world.windows) do
      for _, t in ipairs(rw.tabs) do
        -- world.snapshotOmits[id] is the same lie told about one window instead
        -- of all of them: AppleScript leaves it out, AX still hands it over.
        local lagged = world.newTabLagged and world.newTabLagged.id == t.id
        if not lagged and not (world.snapshotOmits and world.snapshotOmits[t.id]) then
          out[#out + 1] = { id = t.id, name = basename(t.path), path = t.path }
        end
      end
    end
    return out, nil
  end

  function F.pathsById()
    local list, err = F.snapshot()
    if not list then return nil, err end
    local m = {}
    for _, t in ipairs(list) do m[t.id] = t.path end
    return m, nil
  end

  --- Can Accessibility see this window from where the user is standing?
  -- Measured on macOS 26: from a Space the window is not on, Finder hands over no
  -- window at all -- app:allWindows() answers with the desktop and nothing else --
  -- while AppleScript keeps listing every tab and its path.  That asymmetry is why
  -- the panel used to be unreachable from another Space: every handle came back
  -- nil, so show() had nothing to move, lay out or focus and the hotkey looked
  -- dead.  Modelled only when a test sets both sides of the scene, so the
  -- single-Space machine the rest of the suite assumes is left alone.
  function world.axCanSee(rw)
    -- The other possible system, and the one hs.window's API reads as if it were
    -- universal: Accessibility hands over windows on every Space.  This machine
    -- is not it, but the tri-state's raise branch is written for it -- on a system
    -- where a pane one Space over is still resolvable, "shown but not focused" is
    -- what the hotkey sees, and that branch is the one that has to fetch it.
    if world.axSeesOtherSpaces then return true end
    local ws = world.spaceOfWindow[rw]
    if not ws then return true end
    local active = world.spaceOfScreen[world.screenOfRW(rw)]
    if not active then return true end
    return ws == active
  end

  function F.axWindows()
    if not world.finderRunning then return {} end
    local out = {}
    for _, rw in ipairs(world.windows) do
      if not world.axCanSee(rw) then
        -- another Space: invisible to AX, still in the AppleScript snapshot
      elseif rw.minimized then
        -- Measured: a minimized Finder window exposes every tab to AX.
        for i = 1, #rw.tabs do out[#out + 1] = mkwin(rw, i) end
      else
        -- The other half of world.newTabLagged: for one round, the AX tree has
        -- not caught up either and still hands over the tab that was active
        -- before the new one.  Both views lagging at once is what a brand-new
        -- tab looks like from the outside, and what lost one during adopt.
        local lag = world.newTabLagged
        out[#out + 1] = mkwin(rw, (lag and lag.rw == rw) and lag.active or rw.active)
      end
    end
    return out
  end

  function F.axWindowById(id)
    for _, w in ipairs(F.axWindows()) do
      if w:id() == id then return w end
    end
    return nil
  end

  function F.isBrowserWindow(win)
    return win ~= nil and win:id() ~= nil and win:id() ~= 0
  end

  function F.tabTitles(win)
    local rw = win._rw
    -- Measured: a single-tab window has no tab bar at all.
    if not rw or #rw.tabs < 2 then return {}, nil end
    local titles = {}
    for _, t in ipairs(rw.tabs) do titles[#titles + 1] = basename(t.path) end
    return titles, rw.active
  end

  function F.tabBar(win)
    local rw = win._rw
    if not rw or #rw.tabs < 2 then return nil end
    return {}
  end

  function F.selectTab(win, i)
    local rw = win._rw
    if not rw or not rw.tabs[i] then return false end
    rw.active = i
    return true
  end

  -- `world.finderAsleep` is the state measured right after `killall Finder`: the
  -- window is made and even reports an id, but nothing can address it, so its
  -- target cannot be set and it is left behind untargeted.  Activating Finder
  -- (launchOrFocusByBundleID, i.e. `open -a Finder`) is what makes the whole
  -- collection addressable, so that is what clears the flag.
  function F.openWindowAt(path)
    if not world.finderRunning then return nil, "Finder is not running" end
    if hs.fs.attributes(path, "mode") ~= "directory" then
      return nil, "not a directory: " .. tostring(path)
    end
    if world.finderAsleep then
      local rw = world.newWindow({ "/" })     -- Finder's untargeted new window
      world.log[#world.log + 1] = "openWindowAt:asleep:" .. path
      return nil, "Finder would not accept a target", rw.tabs[1].id
    end
    local rw = world.newWindow({ path })
    world.log[#world.log + 1] = "openWindowAt:" .. path
    return rw.tabs[1].id, nil
  end

  --- New Tab, the way lib/finder.lua does it: the tab lands in the window the
  --- handle belongs to, becomes the active one, and answers a moment later.
  function F.newTabAt(win, path, cb)
    cb = cb or function() end
    local rw = win and win._rw
    if not rw then return cb(nil, "no window") end
    if not world.finderRunning then return cb(nil, "Finder is not running") end
    if hs.fs.attributes(path, "mode") ~= "directory" then
      return cb(nil, "not a directory: " .. tostring(path))
    end
    -- world.failNewTabAt = n makes the n-th call fail, for the give-up paths.
    world.newTabCalls = (world.newTabCalls or 0) + 1
    if world.failNewTabAt == world.newTabCalls then
      return hs.timer.doAfter(0.15, function() cb(nil, "New Tab was not available") end)
    end
    local wasActive = rw.active
    local id = world.addTab(rw, path)
    -- world.lagNextNewTab = true: Finder takes this one tab a moment longer to
    -- publish.  The test clears world.newTabLagged when it wants Finder to catch
    -- up, so the length of the gap is the test's to decide.
    if world.lagNextNewTab then
      world.lagNextNewTab = false
      world.newTabLagged  = { id = id, rw = rw, active = wasActive }
    end
    world.frontmost = FINDER
    world.focusedId = id
    world.log[#world.log + 1] = "newTabAt:" .. path
    hs.timer.doAfter(0.15, function() cb(id, nil) end)
  end

  function F.setCollapsed(id, collapsed)
    local rw = world.windowOfId(id)
    if not rw then return false, "no such window" end
    rw.minimized = collapsed
    return true, nil
  end

  -- Measured on macOS 26: AppleScript sets bounds by id even for a window on a
  -- Space its display is not showing -- the one write that still reaches a pane
  -- Accessibility has gone blind to.  The window arrives on the target display,
  -- joins the Space showing there, and turns up in app:allWindows() again, so
  -- this is deliberately the same code path as o:setFrame rather than a
  -- shortcut: same clamp, same Space rule, same move event.
  function F.setBounds(id, rect)
    if world.setBoundsFails then return nil end
    local rw, i = world.windowOfId(id)
    if not rw or not world.finderRunning then return nil end
    world.log[#world.log + 1] = "setBounds:" .. tostring(id)
    local w = mkwin(rw, i)
    w:setFrame(rect)
    return w:frame()
  end

  function F.closeTab(id) return world.closeTabById(id), nil end
  function F.setToolbarVisible() return true, nil end

  -- ── hs.spaces (a private API, modelled only as far as panel.lua goes) ────
  -- opts.noSpaces models the API disappearing in a macOS update, which is the
  -- case every pcall in panel.lua's cross-Space section exists for.
  world.setBoundsFails  = false   -- see F.setBounds
  world.finderAsleep    = false   -- just relaunched: windows cannot be addressed
  world.snapshotOmits   = nil     -- id -> true: hidden from the AppleScript view
  world.lagNextNewTab   = false   -- the next new tab is published a round late
  world.newTabLagged    = nil     -- {id, rw, active} while that is the case
  world.zorder          = { "other" }
  world.stickyAsleep    = false   -- ... and activating Finder does not fix it
  world.spaceOfScreen   = {}      -- screen object -> space id
  world.spaceOfWindow   = {}      -- real window   -> space id
  world.defaultSpace    = 1
  world.moveSpaceFails  = false   -- moveWindowToSpace throws
  world.moveSpaceNoop   = false   -- ... or claims success and does nothing
  world.axSeesOtherSpaces = false -- see world.axCanSee

  --- A window object, or the id of one of its tabs.
  local function rwOf(w)
    if type(w) == "number" then return world.windowOfId(w) end
    return w and w._rw or nil
  end

  if not opts.noSpaces then
    hs.spaces = {
      activeSpaceOnScreen = function(screen)
        return world.spaceOfScreen[screen] or world.defaultSpace
      end,
      -- Both take a window object *or* a window id: measured from another Space,
      -- where an object is the one thing there is no way to get.
      windowSpaces = function(w)
        if world.windowSpacesFails then error("windowSpaces is unavailable") end
        local rw = rwOf(w)
        if not rw then return nil end
        return { world.spaceOfWindow[rw] or world.defaultSpace }
      end,
      moveWindowToSpace = function(w, space)
        if world.moveSpaceFails then error("moveWindowToSpace is unavailable") end
        local rw = rwOf(w)
        if not rw then return false end
        world.log[#world.log + 1] = "moveToSpace:" .. tostring(space)
        if world.moveSpaceNoop then return true end
        world.spaceOfWindow[rw] = space
        return true
      end,
    }
  end

  --- Put the window holding `id` on Space `space`.
  function world.setWindowSpace(id, space)
    local rw = world.windowOfId(id)
    if rw then world.spaceOfWindow[rw] = space end
    return rw ~= nil
  end

  --- Every alert the spoon raised, so tests can assert the user was told.
  world.alerts = {}
  hs.alert.show = function(msg) world.alerts[#world.alerts + 1] = tostring(msg) end

  --- Move the mouse pointer, for the "mouse" screen and adopt-target policies.
  function world.setMousePos(x, y) opts.mousePos = { x = x, y = y } end

  --- Bring a floating window to the front, the way clicking it would.
  function world.focusWindow(rw)
    world.frontmost = FINDER
    world.focusedId = rw.tabs[rw.active] and rw.tabs[rw.active].id or nil
    return world.focusedId
  end

  world.finder = F
  return hs, world
end

return W
