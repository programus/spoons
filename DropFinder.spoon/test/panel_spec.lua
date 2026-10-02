-- Locate ourselves so the suite runs from anywhere; DF_LIB lets the mutation
-- harness point the same tests at a patched copy of lib/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local R = os.getenv("DF_LIB") or (HERE .. "/../lib/")
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

local HOME = os.getenv("HOME")

--- Fresh spoon + fresh world.  Returns panel, world, cfg.
local function boot(rawCfg, screens, opts)
  local hsStub, world = W.new(screens, opts)
  hs = hsStub
  local configLib = dofile(R .. "config.lua")
  local geometry  = dofile(R .. "geometry.lua")
  local store     = dofile(R .. "store.lua")
  local panel     = dofile(R .. "panel.lua")
  local cfg = configLib.loadConfig(rawCfg)
  panel.setDeps({ finder = world.finder, geometry = geometry, store = store,
                  log = hs.logger.new() })
  panel.setConfig(cfg)
  panel.loadState()
  panel.reconcile()
  -- watchers.lua delivers windowMoved straight to the panel (after its own
  -- debounce); the panel's suppression gate is what has to hold here.
  world.onMoved = function(w) panel.onWindowMoved(w) end
  return panel, world, cfg, geometry, store
end

local function paneOf(panel, side) return panel.panes()[side] end
local function liveSide(panel, side) return #panel.panes()[side].tabIds > 0 end
local function countLog(world, pat)
  local n = 0
  for _, line in ipairs(world.log) do if line:match(pat) then n = n + 1 end end
  return n
end
local function frameOf(panel, side)
  local w = panel.paneWindow(side)
  return w and w:frame() or nil
end

-- ══ 1. cold start ══════════════════════════════════════════════════════════
section("cold start and show()")
local panel, world, cfg, geometry = boot()
ck("no panes before the first show()", #paneOf(panel, "left").tabIds == 0
   and #paneOf(panel, "right").tabIds == 0)
ck("state is hidden", panel.state() == "hidden", panel.state())
ck("Finder has no windows yet", #world.windows == 0)

world.frontmost = "com.apple.Safari"
panel.show()
world.drain()

ck("two windows were created", #world.windows == 2, #world.windows)
ck("left pane is live", #paneOf(panel, "left").tabIds == 1)
ck("right pane is live", #paneOf(panel, "right").tabIds == 1)
ck("left opened at the configured default", paneOf(panel, "left").pathList[1] == HOME .. "/Downloads",
   paneOf(panel, "left").pathList[1])
ck("right opened at the configured default", paneOf(panel, "right").pathList[1] == HOME)
ck("origin is create", paneOf(panel, "left").origin == "create")

local lf, rf = frameOf(panel, "left"), frameOf(panel, "right")
local mainF = hs.screen.mainScreen():frame()
ck("panel hugs the bottom of the mouse screen",
   lf.y + lf.h == mainF.y + mainF.h, lf.y .. "+" .. lf.h)
ck("both panes are the same height", lf.h == rf.h, lf.h .. "/" .. rf.h)
ck("both panes are the same y", lf.y == rf.y)
ck("panes are side by side with no seam", lf.x + lf.w == rf.x)
ck("panes span the screen width",
   lf.x == mainF.x and rf.x + rf.w == mainF.x + mainF.w)
ck("each pane is about half the width", math.abs(lf.w - rf.w) <= 1, lf.w .. "/" .. rf.w)
ck("height honours the ratio", lf.h == math.floor(mainF.h * 0.25), lf.h)
ck("panel is on screen", geometry.isOnScreen(lf) and geometry.isOnScreen(rf))
ck("state is shown_focused", panel.state() == "shown_focused", panel.state())
ck("the panel took focus", world.frontmost == "com.apple.finder")
ck("both panes came out in front of the app the hotkey was pressed from",
   world.zIndex(world.windows[1]) < world.zIndex("other")
   and world.zIndex(world.windows[2]) < world.zIndex("other"),
   table.concat({ world.zIndex(world.windows[1]), world.zIndex(world.windows[2]),
                  world.zIndex("other") }, "/"))

-- ══ 2. tri-state ═══════════════════════════════════════════════════════════
section("tri-state toggle")
world.activateOther("com.apple.Safari")
ck("focus elsewhere means shown_unfocused", panel.state() == "shown_unfocused", panel.state())
ck("and Safari's window is in front of both panes",
   world.zIndex("other") == 1, world.zIndex("other"))

panel.toggle()
world.drain()
ck("toggle from shown_unfocused raises instead of hiding",
   panel.state() == "shown_focused", panel.state())
-- The defect this pins down was reported from the screen, not from a test: one
-- pane came forward and the other stayed behind the window the user had been in.
ck("both panes end up in front of the app the user came from",
   world.zIndex(world.windows[1]) < world.zIndex("other")
   and world.zIndex(world.windows[2]) < world.zIndex("other"),
   table.concat({ world.zIndex(world.windows[1]), world.zIndex(world.windows[2]),
                  world.zIndex("other") }, "/"))
ck("and the focused pane is the frontmost of the two",
   world.zIndex(world.windows[panel.getLastSide() == "left" and 1 or 2]) == 1,
   world.zIndex(world.windows[1]))
ck("nothing moved off screen", geometry.isOnScreen(frameOf(panel, "left")))

-- ══ 3. hide (park) ═════════════════════════════════════════════════════════
section("hide by parking")
world.frontmost = "com.apple.Safari"; world.focusedId = nil
panel.show(); world.drain()          -- re-focus so the next toggle hides
world.frontmost = "com.apple.finder"
local idsBefore = { paneOf(panel, "left").tabIds[1], paneOf(panel, "right").tabIds[1] }
panel.toggle()
world.drain()

local pl, pr = frameOf(panel, "left"), frameOf(panel, "right")
ck("state is hidden after parking", panel.state() == "hidden", panel.state())
ck("left pane is off screen", not geometry.isOnScreen(pl),
   string.format("%d,%d %dx%d", pl.x, pl.y, pl.w, pl.h))
ck("right pane is off screen", not geometry.isOnScreen(pr))
ck("parking left a sliver, not nothing", geometry.visibleArea(pl) > 0,
   geometry.visibleArea(pl))
ck("the sliver is under parkMaxVisible", geometry.visibleArea(pl) < cfg.parkMaxVisible,
   geometry.visibleArea(pl))
ck("the sliver is the 40x52 minimum", geometry.visibleArea(pl) == 40 * 52,
   geometry.visibleArea(pl))
ck("parking preserved the pane size", pl.w == lf.w and pl.h == lf.h)
ck("windows were not closed", #world.windows == 2)
ck("tab ids are unchanged", paneOf(panel, "left").tabIds[1] == idsBefore[1]
   and paneOf(panel, "right").tabIds[1] == idsBefore[2])
ck("focus went back to the previous app", world.frontmost == "com.apple.Safari",
   world.frontmost)

-- ══ 4. show again reuses the same windows ══════════════════════════════════
section("show() after hide()")
panel.toggle()
world.drain()
ck("no new windows were created", #world.windows == 2, #world.windows)
ck("the same tab ids came back", paneOf(panel, "left").tabIds[1] == idsBefore[1])
ck("the panel is back on screen", geometry.isOnScreen(frameOf(panel, "left")))
ck("back to half width each",
   math.abs(frameOf(panel, "left").w - frameOf(panel, "right").w) <= 1)
ck("state is shown_focused", panel.state() == "shown_focused", panel.state())

-- ══ 5. floating windows are never adopted and never touched ════════════════
section("floating windows (requirements 2 and 4)")
local floatRW = world.newWindow({ "/Applications" }, { x = 300, y = 200, w = 800, h = 500 })
local floatFrame = { x = floatRW.frame.x, y = floatRW.frame.y,
                     w = floatRW.frame.w, h = floatRW.frame.h }
panel.onWindowCreated(world.mkwin(floatRW, 1))
world.drain()
ck("a user-opened window is not adopted",
   panel.sideOfTab(floatRW.tabs[1].id) == nil)
ck("panes still have one tab each",
   #paneOf(panel, "left").tabIds == 1 and #paneOf(panel, "right").tabIds == 1)

panel.hide(); world.drain()
ck("hiding the panel left the floating window exactly where it was",
   floatRW.frame.x == floatFrame.x and floatRW.frame.y == floatFrame.y
   and floatRW.frame.w == floatFrame.w and floatRW.frame.h == floatFrame.h,
   string.format("%d,%d %dx%d", floatRW.frame.x, floatRW.frame.y,
                 floatRW.frame.w, floatRW.frame.h))
ck("the floating window was not minimized", not floatRW.minimized)
ck("the floating window was not closed", world.windowOfId(floatRW.tabs[1].id) ~= nil)
panel.show(); world.drain()
ck("showing the panel left the floating window alone",
   floatRW.frame.x == floatFrame.x and floatRW.frame.w == floatFrame.w)
ck("state is hidden for a floating-only Finder is not claimed",
   panel.sideOfTab(floatRW.tabs[1].id) == nil)

-- a floating window that happens to sit exactly where a pane sits
local decoy = world.newWindow({ "/Users" }, frameOf(panel, "left"))
panel.onWindowCreated(world.mkwin(decoy, 1))
world.drain()
ck("a floating window at the pane's exact frame is still not adopted",
   panel.sideOfTab(decoy.tabs[1].id) == nil)
world.closeWindow(decoy)
panel.onWindowDestroyed(); world.drain()

-- ══ 6. the user adds a tab inside a pane ═══════════════════════════════════
section("tab tracking inside a pane")
local leftRW = world.windowOfId(paneOf(panel, "left").tabIds[1])
local newTabId = world.addTab(leftRW, "/private/tmp")
panel.onWindowCreated(world.mkwin(leftRW, leftRW.active))
world.drain()
ck("the new tab was adopted into the left pane",
   panel.sideOfTab(newTabId) == "left", panel.sideOfTab(newTabId))
ck("the left pane now has two tabs", #paneOf(panel, "left").tabIds == 2,
   #paneOf(panel, "left").tabIds)
ck("its path was recorded", paneOf(panel, "left").pathList[2] == "/private/tmp",
   paneOf(panel, "left").pathList[2])
ck("the right pane was not affected", #paneOf(panel, "right").tabIds == 1)
ck("the new tab is the active one", paneOf(panel, "left").activeId == newTabId)
ck("pane geometry did not change", frameOf(panel, "left").w == lf.w)

-- switching tabs must not look like a user drag
local before = { x = leftRW.frame.x, y = leftRW.frame.y, w = leftRW.frame.w, h = leftRW.frame.h }
world.advance(5)
world.finder.selectTab(world.mkwin(leftRW, 1), 1)
panel.onWindowMoved(world.mkwin(leftRW, 1))
ck("a tab switch with an unchanged frame is ignored",
   leftRW.frame.x == before.x and leftRW.frame.w == before.w)

-- ══ 7. closing one tab vs the whole pane ═══════════════════════════════════
section("closing tabs and panes")
world.closeTabById(newTabId)
panel.onWindowDestroyed(); world.drain()
ck("the closed tab is gone from the model", panel.sideOfTab(newTabId) == nil)
ck("the left pane survives with one tab", #paneOf(panel, "left").tabIds == 1)
ck("the left pane did not move", frameOf(panel, "left").w == lf.w,
   frameOf(panel, "left").w)

local rightRW = world.windowOfId(paneOf(panel, "right").tabIds[1])
local rightId = paneOf(panel, "right").tabIds[1]
world.closeWindow(rightRW)
panel.onWindowDestroyed(); world.drain()
ck("the right pane is gone", #paneOf(panel, "right").tabIds == 0)
ck("its rebuild paths were kept", #paneOf(panel, "right").pathList > 0,
   #paneOf(panel, "right").pathList)
ck("requirement 9: the survivor took the full panel width",
   frameOf(panel, "left").w == mainF.w, frameOf(panel, "left").w)
ck("the survivor still hugs the bottom",
   frameOf(panel, "left").y + frameOf(panel, "left").h == mainF.y + mainF.h)
ck("state is still shown", panel.state() ~= "hidden", panel.state())

-- ══ 8. next show() rebuilds the missing side ═══════════════════════════════
section("rebuilding a closed side (requirement 5)")
panel.hide(); world.drain()
panel.show(); world.drain()
ck("the right pane was recreated", #paneOf(panel, "right").tabIds == 1)
ck("it got a fresh id", paneOf(panel, "right").tabIds[1] ~= rightId)
ck("both panes are back to half width",
   math.abs(frameOf(panel, "left").w - frameOf(panel, "right").w) <= 1,
   frameOf(panel, "left").w .. "/" .. frameOf(panel, "right").w)
ck("both panes are the same height",
   frameOf(panel, "left").h == frameOf(panel, "right").h)

-- Requirement 5 as written says "that side's configured default directory", but
-- desiredPathFor deliberately prefers the path the side was last at: parking
-- does not destroy windows, so coming back somewhere else would feel like a
-- reset.  Confirmed with the user 2026-09-11.  The section above cannot see the
-- difference -- the saved path happens to equal the default -- so pin it here.
section("a rebuilt side returns to where it was, not to the default")
do
  local p2, w2, c2 = boot()
  p2.show(); w2.drain()
  local id = paneOf(p2, "right").tabIds[1]
  w2.navigate(id, "/Applications")
  p2.reconcile()
  ck("the default is genuinely a different folder",
     c2.defaultPaths.right ~= "/Applications", c2.defaultPaths.right)

  w2.closeWindow(w2.windowOfId(id))
  p2.onWindowDestroyed(); w2.drain()
  ck("the right pane is gone", #paneOf(p2, "right").tabIds == 0)

  p2.hide(); w2.drain()
  p2.show(); w2.drain()
  ck("it came back where it was, not at the default",
     paneOf(p2, "right").pathList[1] == "/Applications",
     paneOf(p2, "right").pathList[1])
end


-- ══ 11. Finder's minimum height is discovered, not hardcoded ═══════════════
section("min-height self-correction")
do
  local p2, w2, c2, geo = boot({ heightRatio = 0.05 })   -- 1410 * 0.05 = 70px
  p2.show(); w2.drain()
  local a, b = p2.paneWindow("left"):frame(), p2.paneWindow("right"):frame()
  ck("Finder's floor won over the ratio", a.h == 344, a.h)
  ck("both panes ended up the same height", a.h == b.h, a.h .. "/" .. b.h)
  ck("both still hug the bottom", a.y + a.h == b.y + b.h)
  local mf = w2.constrain({ x = 0, y = 0, w = 10, h = 10 })
  ck("the panel is not taller than the screen", a.h <= hs.screen.mainScreen():frame().h, mf and a.h)
  ck("nothing in geometry.lua hardcodes 344", (function()
    local src = io.open(R .. "geometry.lua"):read("*a")
    -- only the explanatory comment may mention it
    for line in src:gmatch("[^\n]+") do
      if line:find("344") and not line:find("^%s*%-%-") then return false end
    end
    return true
  end)())
end

-- ══ 12. Finder quit and relaunched ════════════════════════════════════════
section("Finder restart (requirement 3 fallback)")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local leftPath = paneOf(p2, "left").pathList[1]
  local oldIds = { paneOf(p2, "left").tabIds[1], paneOf(p2, "right").tabIds[1] }

  w2.windows = {}                       -- killall Finder
  p2.onFinderTerminated(); w2.drain()
  ck("tab ids were dropped", #paneOf(p2, "left").tabIds == 0)
  ck("rebuild paths were kept", paneOf(p2, "left").pathList[1] == leftPath,
     paneOf(p2, "left").pathList[1])
  ck("state is hidden with no windows", p2.state() == "hidden", p2.state())

  p2.onFinderLaunched(); w2.drain()
  p2.show(); w2.drain()
  ck("both panes were rebuilt", #w2.windows == 2, #w2.windows)
  ck("the left pane came back at its remembered path",
     paneOf(p2, "left").pathList[1] == leftPath, paneOf(p2, "left").pathList[1])
  ck("the ids are new ones", paneOf(p2, "left").tabIds[1] ~= oldIds[1])
  ck("and it is laid out again", geometry.isOnScreen(p2.paneWindow("left"):frame()))
end

-- ══ 13. hs.reload(): same Finder, persisted ids still valid ════════════════
section("reattach across a Hammerspoon reload (requirement 3)")
do
  local hsStub, w2 = W.new()
  hs = hsStub
  local configLib = dofile(R .. "config.lua")
  local geo       = dofile(R .. "geometry.lua")
  local st        = dofile(R .. "store.lua")
  local p2        = dofile(R .. "panel.lua")
  local c2 = configLib.loadConfig()
  p2.setDeps({ finder = w2.finder, geometry = geo, store = st, log = hs.logger.new() })
  p2.setConfig(c2); p2.loadState(); p2.reconcile()
  p2.show(); w2.drain()
  local ids = { paneOf(p2, "left").tabIds[1], paneOf(p2, "right").tabIds[1] }
  local frames = { p2.paneWindow("left"):frame(), p2.paneWindow("right"):frame() }
  p2.persistNow()

  -- A brand new set of module instances against the SAME world and the same
  -- hs.settings store: exactly what hs.reload() does.
  local p3 = dofile(R .. "panel.lua")
  local st3 = dofile(R .. "store.lua")
  p3.setDeps({ finder = w2.finder, geometry = dofile(R .. "geometry.lua"),
               store = st3, log = hs.logger.new() })
  p3.setConfig(c2)
  p3.loadState()
  ck("ids survived the reload", paneOf(p3, "left").tabIds[1] == ids[1],
     tostring(paneOf(p3, "left").tabIds[1]))
  ck("origin is reattach", paneOf(p3, "left").origin == "reattach",
     paneOf(p3, "left").origin)
  p3.reconcile()
  ck("reconcile kept the reattached ids", paneOf(p3, "left").tabIds[1] == ids[1])
  ck("it found their live paths", paneOf(p3, "left").pathList[1] == HOME .. "/Downloads",
     paneOf(p3, "left").pathList[1])
  ck("it saw them as shown", p3.state() ~= "hidden", p3.state())

  local created = #w2.windows
  p3.show(); w2.drain()
  ck("show() after a reload creates no windows", #w2.windows == created, #w2.windows)
  ck("and does not move them either",
     p2.paneWindow("left"):frame().x == frames[1].x)
end

-- ══ 14. hideMode = "minimize" ══════════════════════════════════════════════
section('hideMode = "minimize"')
do
  local p2, w2 = boot({ hideMode = "minimize" })
  w2.frontmost = "com.apple.Safari"
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  local shownFrame = { x = lw.frame.x, y = lw.frame.y, w = lw.frame.w, h = lw.frame.h }
  ck("shown and focused", p2.state() == "shown_focused", p2.state())

  p2.toggle(); w2.drain()
  ck("both panes are minimized", lw.minimized
     and w2.windowOfId(paneOf(p2, "right").tabIds[1]).minimized)
  ck("state is hidden", p2.state() == "hidden", p2.state())
  ck("minimizing did not move anything", lw.frame.x == shownFrame.x)
  ck("focus went back to the previous app", w2.frontmost == "com.apple.Safari",
     w2.frontmost)
  ck("the model knows it is collapsed", paneOf(p2, "left").collapsed == true)

  p2.toggle(); w2.drain()
  ck("both panes came back", not lw.minimized)
  ck("and were laid out", geometry.isOnScreen(p2.paneWindow("left"):frame()))
  ck("state is shown_focused again", p2.state() == "shown_focused", p2.state())

  -- the user's own Cmd+M must move the state machine too
  local pw = p2.paneWindow("left")
  w2.windowOfId(pw:id()).minimized = true
  p2.onMinimizeChanged(pw, true)
  ck("a manual Cmd+M is noticed", paneOf(p2, "left").collapsed == true)
  p2.show(); w2.drain()
  ck("the next show() restores it instead of hiding again",
     not w2.windowOfId(paneOf(p2, "left").tabIds[1]).minimized)
end

-- ══ 15. the user drags a pane ══════════════════════════════════════════════
section("user-initiated moves")
do
  local p2, w2, c2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  local movesBefore = lw.setFrameCount

  -- our own applyFrame calls are suppressed
  ck("events are suppressed right after a layout", p2.isSuppressed())
  w2.advance(1)
  ck("suppression expires", not p2.isSuppressed())

  lw.frame.x = lw.frame.x + 200          -- the user dragged it
  p2.onWindowMoved(w2.mkwin(lw, lw.active))
  w2.drain()
  ck("we did not fight the drag", lw.setFrameCount == movesBefore,
     lw.setFrameCount .. " vs " .. movesBefore)
  ck("the model recorded where it now is",
     paneOf(p2, "left").frame.x == lw.frame.x, paneOf(p2, "left").frame.x)

  p2.hide(); w2.drain(); p2.show(); w2.drain()
  local lf2 = p2.paneWindow("left"):frame()
  ck("the next show() puts it back on the panel grid", lf2.x == mainF.x, lf2.x)
end

-- ══ 16. the panel follows the mouse ════════════════════════════════════════
section("screen selection (requirement 8)")
do
  -- mouse on the second display (HS133PS at 2560,261 1920x1080)
  local p2, w2, c2, geo = boot(nil, nil, { mouseIndex = 2 })
  p2.show(); w2.drain()
  local sf = hs.screen.allScreens()[2]:frame()
  local a, b = p2.paneWindow("left"):frame(), p2.paneWindow("right"):frame()
  ck("the panel is on the mouse's screen", a.x == sf.x, a.x)
  ck("it spans that screen", b.x + b.w == sf.x + sf.w, b.x + b.w)
  ck("it hugs that screen's bottom", a.y + a.h == sf.y + sf.h, a.y + a.h)
  ck("its height follows that screen", a.h == math.max(344, math.floor(sf.h * 0.25)), a.h)

  -- mouse moves to the third display; the panel follows on the next show()
  w2.setMouseScreen(3)
  p2.hide(); w2.drain()
  p2.show(); w2.drain()
  local sf3 = hs.screen.allScreens()[3]:frame()
  local c = p2.paneWindow("left"):frame()
  ck("the panel moved to the new mouse screen", c.x == sf3.x, c.x)
  ck("with no new windows", #w2.windows == 2, #w2.windows)
end

-- ══ 17. stop() puts everything back ═══════════════════════════════════════
section("restoreAll()")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local float = w2.newWindow({ "/Applications" }, { x = 400, y = 300, w = 700, h = 450 })
  local ff = { x = float.frame.x, y = float.frame.y }
  p2.hide(); w2.drain()
  ck("panes are parked", not geometry.isOnScreen(p2.paneWindow("left"):frame()))
  p2.restoreAll(); w2.drain()
  ck("the left pane is back on screen", geometry.isOnScreen(p2.paneWindow("left"):frame()))
  ck("the right pane is back on screen", geometry.isOnScreen(p2.paneWindow("right"):frame()))
  ck("nothing is left minimized", not w2.windowOfId(paneOf(p2, "left").tabIds[1]).minimized)
  ck("the floating window was never touched",
     float.frame.x == ff.x and float.frame.y == ff.y)
  ck("no windows were closed", #w2.windows == 3, #w2.windows)
end


-- ══ 18. snapBack must not fight our own moves ══════════════════════════════
-- With snapBack on, an unsuppressed windowMoved triggers a relayout -- so if the
-- suppression window around applyFrame were missing, hide() would immediately
-- pull the panes it just parked back onto the screen (or recurse).
section("snapBack = true")
do
  local p2, w2 = boot({ snapBack = true })
  p2.show(); w2.drain()
  ck("show() still lands on the panel grid",
     p2.paneWindow("left"):frame().x == mainF.x)
  -- Wait out layout()'s suppression window first, so that hide()'s own is the
  -- only thing standing between the park and snapBack undoing it.
  w2.advance(2)
  ck("nothing is suppressed any more", not p2.isSuppressed())
  p2.hide(); w2.drain()
  ck("parked panes stay parked", not geometry.isOnScreen(p2.paneWindow("left"):frame()),
     (function() local f = p2.paneWindow("left"):frame()
        return string.format("%d,%d %dx%d", f.x, f.y, f.w, f.h) end)())
  ck("state is hidden", p2.state() == "hidden", p2.state())

  p2.show(); w2.drain()
  w2.advance(1)                          -- suppression expires
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  local moves = lw.setFrameCount
  lw.frame.x = lw.frame.x + 300          -- now a real user drag
  p2.onWindowMoved(w2.mkwin(lw, lw.active))
  w2.drain()
  ck("a real drag does get snapped back", lw.setFrameCount > moves)
  ck("and lands back on the grid", lw.frame.x == mainF.x, lw.frame.x)
end


-- ══ 19. the user navigates inside a pane ═══════════════════════════════════
-- Finder reuses the tab, so nothing is created or destroyed and no event of ours
-- fires: reconcile() has to notice on its own, or hide() would persist a stale
-- path and the next rebuild would open the wrong folder.
section("navigating a tab")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local id = paneOf(p2, "left").tabIds[1]
  w2.navigate(id, "/Applications")
  p2.reconcile()
  ck("reconcile picked up the new path",
     paneOf(p2, "left").pathList[1] == "/Applications",
     paneOf(p2, "left").pathList[1])
  ck("the tab id did not change", paneOf(p2, "left").tabIds[1] == id)

  p2.hide(); w2.drain()
  w2.windows = {}                       -- Finder restarts, ids are gone
  p2.onFinderTerminated(); w2.drain()
  p2.show(); w2.drain()
  ck("the rebuilt pane opens where the user had navigated to",
     paneOf(p2, "left").pathList[1] == "/Applications",
     paneOf(p2, "left").pathList[1])
end

-- ══ 20. switching tabs must not be read as a drag ══════════════════════════
-- Measured: AXPress on a tab emits windowMoved with an unchanged frame.  With
-- snapBack on, treating that as a user drag would relayout on every tab switch.
section("tab switch vs drag")
do
  local p2, w2 = boot({ snapBack = true })
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/private/tmp")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  ck("the tab was adopted", #paneOf(p2, "left").tabIds == 2)

  w2.advance(2)                          -- suppression expires
  ck("nothing is suppressed", not p2.isSuppressed())
  local moves = lw.setFrameCount
  w2.finder.selectTab(w2.mkwin(lw, 1), 1) -- Cmd+1: switch back to the first tab
  p2.onWindowMoved(w2.mkwin(lw, 1))       -- the windowMoved macOS emits for it
  w2.drain()
  ck("a tab switch triggers no relayout", lw.setFrameCount == moves,
     lw.setFrameCount .. " vs " .. moves)
end

-- ══ 21. the user minimizes a shown pane by hand ════════════════════════════
-- A minimized window is not visible even though its frame still says it is on
-- screen, so state() has to consult isMinimized() and not geometry alone --
-- otherwise the hotkey would park an already-invisible panel instead of
-- bringing it back.
section("the hotkey re-reads the world before deciding")
do
  -- state() answers from the AX table the last reconcile filled in.  From the
  -- machine: the spoon started while the screen was locked, so that reconcile saw
  -- no windows at all, and afterwards state() still said "hidden" about a panel
  -- sitting on the grid -- the first press would have shown it again instead of
  -- putting it away.
  local p2, w2 = boot()
  p2.show(); w2.drain()
  ck("the panel is up and focused", p2.state() == "shown_focused", p2.state())

  local realAx = w2.finder.axWindows
  w2.finder.axWindows = function() return {} end
  p2.reconcile()                      -- as if run with the screen locked
  w2.finder.axWindows = realAx
  ck("state() on its own is fooled by the stale table",
     p2.state() == "hidden", p2.state())

  p2.toggle(); w2.drain()
  ck("the hotkey put the panel away anyway",
     not geometry.isOnScreen(p2.paneWindow("left"):frame()),
     hs.inspect(p2.paneWindow("left"):frame()))
  ck("both sides, not just one",
     not geometry.isOnScreen(p2.paneWindow("right"):frame()))
  ck("and the tabs were not touched", #paneOf(p2, "left").tabIds == 1)
end

section("manual Cmd+M while shown")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local frameBefore = p2.paneWindow("left"):frame()
  for _, side in ipairs({ "left", "right" }) do
    local rw = w2.windowOfId(paneOf(p2, side).tabIds[1])
    rw.minimized = true
    p2.onMinimizeChanged(w2.mkwin(rw, rw.active), true)
  end
  ck("the frames still look on-screen", geometry.isOnScreen(frameBefore))
  ck("but state() says hidden", p2.state() == "hidden", p2.state())
  -- And a reconcile in between must not talk itself out of it.  From the machine:
  -- dumpState (which reconciles) reported collapsed=false on a pane that was
  -- sitting in the Dock, so stop() would have left it there.
  local activeBefore = paneOf(p2, "left").activeId
  p2.reconcile()
  ck("a reconcile keeps knowing both panes are minimized",
     paneOf(p2, "left").collapsed and paneOf(p2, "right").collapsed,
     tostring(paneOf(p2, "left").collapsed) .. "/" .. tostring(paneOf(p2, "right").collapsed))
  ck("and does not lose which tab was active",
     paneOf(p2, "left").activeId == activeBefore, paneOf(p2, "left").activeId)
  ck("state() still says hidden", p2.state() == "hidden", p2.state())

  p2.toggle(); w2.drain()
  ck("the hotkey restored them instead of hiding again",
     not w2.windowOfId(paneOf(p2, "left").tabIds[1]).minimized)
  ck("and they are on the panel grid", p2.paneWindow("left"):frame().x == mainF.x)
  ck("state is shown_focused", p2.state() == "shown_focused", p2.state())
end

section("restoreAll() empties the Dock after a manual Cmd+M")
do
  -- stop() promises to leave no pane stranded -- in a corner or in the Dock --
  -- and it acts on pane.collapsed, so the flag surviving a reconcile is what
  -- makes this work.  In the default park hideMode a collapsed pane can only be
  -- the user's own Cmd+M, and that used to be left behind.
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local rw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  rw.minimized = true
  p2.onMinimizeChanged(w2.mkwin(rw, rw.active), true)
  p2.reconcile()
  p2.restoreAll(); w2.drain()
  ck("the pane the user minimized is out of the Dock", not rw.minimized)
  ck("and it is back on the panel grid",
     p2.paneWindow("left"):frame().x == mainF.x, p2.paneWindow("left"):frame().x)
  ck("the other side was left alone",
     not w2.windowOfId(paneOf(p2, "right").tabIds[1]).minimized)
end

section("Cmd+M on only one side")
do
  -- The machine caught this one: with the other half still on screen, state()
  -- used to answer "shown", so the hotkey put the survivor away instead of
  -- bringing the minimized half back.
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local rw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  rw.minimized = true
  p2.onMinimizeChanged(w2.mkwin(rw, rw.active), true)

  ck("the right pane is still on screen",
     geometry.isOnScreen(p2.paneWindow("right"):frame()))
  ck("a half-shown panel counts as hidden", p2.state() == "hidden", p2.state())

  p2.toggle(); w2.drain()
  ck("so the hotkey completed the panel", not rw.minimized)
  ck("both sides are back on the grid",
     p2.paneWindow("left"):frame().x == mainF.x
     and p2.paneWindow("right"):frame().x > mainF.x)
  ck("and the panel is shown again", p2.state() == "shown_focused", p2.state())
end

section("a pane whose active tab is not ours yet does not read as hidden")
do
  -- The transient right after Cmd+T: the pane's new active tab is the only one
  -- AX exposes, and it is not in tabIds yet, so the pane cannot be resolved at
  -- all.  Unknown must not be mistaken for hidden, or tab adoption bails out.
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local rw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(rw, "/private/tmp")            -- becomes the active tab
  p2.reconcile()                           -- what onWindowCreated does first
  ck("the left pane no longer resolves", p2.paneWindow("left") == nil)
  ck("state is still shown", p2.state() ~= "hidden", p2.state())
end

section("a show that crosses displays models the frame it really got")
do
  -- The machine caught this one too: AX answered the pane's old-screen geometry
  -- for a moment after the move, and that stale read became pane.frame -- which
  -- is what tab adoption and drag detection compare against.
  local p2, w2, c2, g2 = boot(nil, nil, { mouseIndex = 2, staleFrameReads = true })
  p2.show(); w2.drain()
  local onSecond = frameOf(p2, "left")
  ck("the panel opened on the display under the mouse",
     onSecond.x >= 2560, onSecond.x)

  w2.setMouseScreen(1)
  p2.hide(); w2.drain()
  p2.show(); w2.drain()

  local real  = frameOf(p2, "left")
  local model = paneOf(p2, "left").frame
  ck("the panel moved to the first display", real.x < 2560, real.x)
  ck("and the model matches the window", g2.framesEqual(model, real, c2.frameTolerance),
     string.format("model %dx%d vs real %dx%d", model.w, model.h, real.w, real.h))
  ck("at the full configured height", real.h == math.floor(1410 * c2.heightRatio), real.h)
end


-- ══ 25. Finder delivers our own park late ══════════════════════════════════
-- Measured on the machine: the second pane's move event arrives *after* hide()'s
-- suppression window has lapsed.  With snapBack on, mistaking that for a hand
-- drag relayouts the panel and silently undoes the hide.  Two things stop it —
-- hide() recording the park as pane.frame, and onWindowMoved comparing against
-- pane.parked — and they guard the same comparison, so only removing both is
-- observable.  That is what the mutation gate mutates.
section("a late move event from our own park is not a user drag")
do
  local p2, w2, _, g2 = boot({ snapBack = true })
  p2.show(); w2.drain()
  p2.hide(); w2.drain()
  local rw = w2.windowOfId(paneOf(p2, "right").tabIds[1])
  ck("the right pane is parked", not g2.isOnScreen(rw.frame))
  w2.advance(2)                          -- hide()'s suppression lapses
  ck("nothing is suppressed any more", not p2.isSuppressed())

  local moves = rw.setFrameCount
  p2.onWindowMoved(w2.mkwin(rw, rw.active))
  w2.drain()
  ck("the late move moved nothing", rw.setFrameCount == moves, rw.setFrameCount)
  ck("the right pane stayed parked", not g2.isOnScreen(rw.frame),
     string.format("%d,%d %dx%d", rw.frame.x, rw.frame.y, rw.frame.w, rw.frame.h))
  ck("state is still hidden", p2.state() == "hidden", p2.state())
end


-- ══ 26. requirement 3: every tab comes back, with the right one active ══════
-- The pane opens with its first tab and the rest arrive over the following
-- ticks, so this is also the test that the async chain terminates.
section("all tabs come back after Finder restarts (requirement 3)")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")               -- the user presses Cmd+T twice
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/usr")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  ck("the left pane has three tabs", #paneOf(p2, "left").tabIds == 3,
     #paneOf(p2, "left").tabIds)

  w2.finder.selectTab(w2.mkwin(lw, 1), 2)      -- settle on the middle one
  p2.hide(); w2.drain()
  ck("hide() persisted the tab that was active",
     paneOf(p2, "left").activePath == "/Applications",
     paneOf(p2, "left").activePath)

  w2.windows = {}                              -- killall Finder: every id is gone
  p2.onFinderTerminated(); w2.drain()
  ck("the ids are gone but the recipe is not", #paneOf(p2, "left").tabIds == 0
     and #paneOf(p2, "left").pathList == 3, #paneOf(p2, "left").pathList)

  p2.show(); w2.drain()
  local pane = paneOf(p2, "left")
  ck("all three tabs came back", #pane.tabIds == 3, #pane.tabIds)
  ck("in the same order", table.concat(pane.pathList, ",")
     == HOME .. "/Downloads,/Applications,/usr", table.concat(pane.pathList, ","))
  local rw = w2.windowOfId(pane.tabIds[1])
  ck("as tabs of one real window, not three windows", #rw.tabs == 3, #w2.windows)
  ck("the remembered tab is the active one", rw.tabs[rw.active].path == "/Applications",
     rw.tabs[rw.active].path)
  ck("and the model agrees about which that is", pane.activeId == pane.tabIds[2],
     tostring(pane.activeId))
  ck("nothing is left queued", paneOf(p2, "left").pending == nil)
  ck("the right pane was rebuilt too", #paneOf(p2, "right").tabIds == 1)
end

-- ══ 27. restoreTabs = false ════════════════════════════════════════════════
section("restoreTabs = false rebuilds one tab, the active one")
do
  local p2, w2 = boot({ restoreTabs = false })
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()
  p2.show(); w2.drain()
  local pane = paneOf(p2, "left")
  ck("only one tab was rebuilt", #pane.tabIds == 1, #pane.tabIds)
  ck("and it is the one that was active", pane.pathList[1] == "/Applications",
     pane.pathList[1])
end

-- ══ 28. a tab that cannot be recreated ═════════════════════════════════════
section("one failed New Tab does not abandon the rest")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/usr")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()

  w2.failNewTabAt = 1                          -- Finder refuses the first one
  p2.show(); w2.drain()
  local pane = paneOf(p2, "left")
  -- A path taken off the queue for a New Tab that then failed used to be simply
  -- dropped, which is half of how 8 remembered tabs came back as 5.  New Tab
  -- misses transiently while Finder is still waking, so it goes back on the queue.
  ck("the pane came back whole", #pane.tabIds == 3, #pane.tabIds)
  ck("in the order it was remembered in", table.concat(pane.pathList, ",")
     == HOME .. "/Downloads,/Applications,/usr", table.concat(pane.pathList, ","))
  ck("nothing is left queued", pane.pending == nil)
end

-- ══ 28b. ... but a path Finder will never accept must not block the rest ════
section("a tab Finder keeps refusing is given up on, not retried forever")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/usr")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()

  w2.failNewTabFor = "/Applications"           -- this one never works
  p2.show(); w2.drain()
  local pane = paneOf(p2, "left")
  ck("the tabs behind it still arrived", #pane.tabIds == 2, #pane.tabIds)
  ck("and they are the two that could be made", table.concat(pane.pathList, ",")
     == HOME .. "/Downloads,/usr", table.concat(pane.pathList, ","))
  ck("the drain ended", pane.pending == nil, pane.pending and #pane.pending.paths)
  ck("having tried the refused path more than once",
     countLog(w2, "^newTabAt:/Applications$") == 0 and #w2.timers == 0, #w2.timers)
end

-- ══ 29. the pane is closed while its tabs are still arriving ═══════════════
-- Cmd+W on a pane that is mid-rebuild.  Every later step reads a window that no
-- longer exists, so this is where a nil would raise inside a timer callback --
-- somewhere nothing can catch it.
section("closing a pane mid-restore does not raise")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/usr")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()

  p2.show()
  -- Step until the first tab exists and there is still a queue behind it.
  local guard = 0
  while paneOf(p2, "left").pending == nil and guard < 20 do
    w2.step(); guard = guard + 1
  end
  ck("the restore really is in flight", paneOf(p2, "left").pending ~= nil)
  w2.closeWindow(w2.windowOfId(paneOf(p2, "left").tabIds[1]))
  local ok, err = pcall(function()
    p2.onWindowDestroyed()
    w2.drain()
  end)
  ck("draining the rest of the restore did not raise", ok, err)
  ck("the left pane is recorded as gone", #paneOf(p2, "left").tabIds == 0,
     #paneOf(p2, "left").tabIds)
  -- It stops draining -- there is nothing left to drain into -- but the queue is
  -- the other half of the rebuild recipe, and dropping it is how the tabs went
  -- missing for good.  pathList holds the tabs that were made and pending the
  -- rest, so between them the whole recipe is still there for the next show().
  local left = paneOf(p2, "left")
  ck("the queue survived for the next rebuild", left.pending ~= nil)
  ck("and recipe plus queue still add up to every remembered tab",
     #left.pathList + #(left.pending or { paths = {} }).paths == 3,
     #left.pathList .. "+" .. #((left.pending or { paths = {} }).paths))
  ck("the right pane is untouched and full width",
     frameOf(p2, "right").w == hs.screen.mainScreen():frame().w,
     frameOf(p2, "right").w)
end


-- ══ 30. tab order comes from the tab bar, not from our own bookkeeping ══════
section("a tab dragged along the bar is re-ordered in the model")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/usr")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  local first = paneOf(p2, "left").tabIds[1]
  ck("the model starts in creation order",
     table.concat(paneOf(p2, "left").pathList, ",")
       == HOME .. "/Downloads,/Applications,/usr",
     table.concat(paneOf(p2, "left").pathList, ","))

  w2.reorderTabs(lw, { 3, 1, 2 })              -- the user drags /usr to the front
  p2.reconcile()
  local pane = paneOf(p2, "left")
  ck("the model followed the tab bar",
     table.concat(pane.pathList, ",") == "/usr," .. HOME .. "/Downloads,/Applications",
     table.concat(pane.pathList, ","))
  ck("the ids moved with their paths", pane.tabIds[2] == first, tostring(pane.tabIds[2]))
  ck("the active tab is still the same one", pane.activePath == "/usr", pane.activePath)

  -- And the new order is what a rebuild uses.
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()
  p2.show(); w2.drain()
  ck("a rebuild follows the order the user left",
     table.concat(paneOf(p2, "left").pathList, ",")
       == "/usr," .. HOME .. "/Downloads,/Applications",
     table.concat(paneOf(p2, "left").pathList, ","))
end

-- ══ 31. two tabs with the same folder name ═════════════════════════════════
-- The known degradation: the bar only shows basenames, so the order cannot be
-- recovered.  What must not happen is a *path* being lost or duplicated.
section("duplicate folder names leave the order alone but keep every path")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/usr/bin")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/bin")                        -- also basename "bin"
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  local before = table.concat(paneOf(p2, "left").pathList, ",")
  w2.reorderTabs(lw, { 3, 2, 1 })
  p2.reconcile()
  local pane = paneOf(p2, "left")
  ck("the order was left as it was", table.concat(pane.pathList, ",") == before,
     table.concat(pane.pathList, ","))
  ck("all three paths are still there", #pane.pathList == 3, #pane.pathList)
  ck("and all three ids", #pane.tabIds == 3, #pane.tabIds)
end

-- ══ 31b. a display change while the panel is away ══════════════════════════
-- If the corner a pane was parked in stops existing, macOS drags the window
-- somewhere visible — and a visible pane reads as a shown panel, so the next
-- hotkey press would raise a wrongly-sized window instead of opening the panel.
section("a display change re-parks a panel that was put away")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  p2.hide(); w2.drain()
  ck("the panel is away", p2.state() == "hidden", p2.state())

  -- What a display change does to a parked window: the corner it was clamped
  -- against is gone, so macOS drags it somewhere visible.
  for _, side in ipairs({ "left", "right" }) do
    local rw = w2.windowOfId(paneOf(p2, side).tabIds[1])
    rw.frame = { x = 500, y = 400, w = rw.frame.w, h = rw.frame.h }
  end
  ck("a display change left it in the middle of a screen", p2.state() ~= "hidden",
     p2.state())

  p2.onScreensChanged(); w2.drain()
  ck("it is parked again", p2.state() == "hidden", p2.state())
  ck("and the pane recorded where", paneOf(p2, "left").parked ~= nil)
  ck("in the same corner as its sibling",
     paneOf(p2, "left").parked.x == paneOf(p2, "right").parked.x)
end

-- The same event must not disturb a minimized pane: it is not parked, and
-- restoring it here would put it on screen unasked.
section("a display change leaves a minimized panel minimized")
do
  local p2, w2 = boot({ hideMode = "minimize" })
  p2.show(); w2.drain()
  p2.hide(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  local moves = lw.setFrameCount or 0
  p2.onScreensChanged(); w2.drain()
  ck("still minimized", lw.minimized == true)
  ck("and not moved", (lw.setFrameCount or 0) == moves, lw.setFrameCount)
  ck("still hidden", p2.state() == "hidden", p2.state())
end

-- The mixed case is the one the isMinimized guard is really for: hideMode is
-- "park", so the pane has a park frame and the re-park loop reaches it, but the
-- user hit Cmd+M on the parked sliver.  Moving a minimized window is meaningless
-- at best and un-minimizes it at worst.
section("a display change leaves a hand-minimized parked pane alone")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  p2.hide(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  local lw  = w2.windowOfId(lid)
  local rw  = w2.windowOfId(paneOf(p2, "right").tabIds[1])
  w2.finder.setCollapsed(lid, true)   -- as if the user pressed Cmd+M on it
  local moves, rmoves = lw.setFrameCount or 0, rw.setFrameCount or 0

  p2.onScreensChanged(); w2.drain()
  ck("the minimized pane was not moved", (lw.setFrameCount or 0) == moves,
     lw.setFrameCount)
  ck("and is still minimized", lw.minimized == true)
  ck("its parked sibling was re-parked", (rw.setFrameCount or 0) > rmoves,
     rw.setFrameCount)
end

-- The same mixed case, at stop() instead of a display change: waking the pane is
-- only half the job, because minimize hands it back at the park corner.
section("restoreAll() brings a hand-minimized parked pane back on screen")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  p2.hide(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  local lw  = w2.windowOfId(lid)
  w2.finder.setCollapsed(lid, true)   -- as if the user pressed Cmd+M on the sliver
  ck("the sliver is in the Dock", lw.minimized == true)

  p2.restoreAll(); w2.drain()
  ck("restoreAll took it out of the Dock", lw.minimized == false, lw.minimized)
  ck("and did not leave it at the park corner it woke up in",
     geometry.isOnScreen(p2.paneWindow("left"):frame()),
     hs.inspect(p2.paneWindow("left"):frame()))
  ck("it is on the panel grid", p2.paneWindow("left"):frame().x == mainF.x,
     p2.paneWindow("left"):frame().x)
  ck("so is the side that was only parked",
     geometry.isOnScreen(p2.paneWindow("right"):frame()),
     hs.inspect(p2.paneWindow("right"):frame()))
end

-- ══ 32. cross-Space: the panel comes to the Space the mouse is on ═══════════
-- Requirement 10.  Every hs.spaces call is private API, so the interesting cases
-- are the failures, not the happy path.  None of this could be verified on the
-- real machine: all three of its displays have exactly one Space.
section("the panel is moved to the current Space (requirement 10)")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  local rid = paneOf(p2, "right").tabIds[1]
  -- The user switches Spaces: the panes stay on the display they were on, and
  -- keep the frames they had, but the Space showing there is not theirs any
  -- more.  They are on screen by every geometric test and invisible all the
  -- same.  This -- same display, stale Space -- is the shape requirement 10
  -- actually has; a pane put away in the park corner is a different case and
  -- gets its own section below.
  w2.setWindowSpace(lid, 7)
  w2.setWindowSpace(rid, 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  local moves = #w2.log
  p2.show(); w2.drain()

  local lrw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  local rrw = w2.windowOfId(paneOf(p2, "right").tabIds[1])
  ck("both panes ended up on the mouse screen's Space",
     w2.spaceOfWindow[lrw] == 3 and w2.spaceOfWindow[rrw] == 3,
     tostring(w2.spaceOfWindow[lrw]) .. "/" .. tostring(w2.spaceOfWindow[rrw]))
  local nmoves = 0
  for i = moves + 1, #w2.log do
    if w2.log[i]:match("^moveToSpace") then nmoves = nmoves + 1 end
  end
  ck("it took one move per pane, not one per tab", nmoves == 2, nmoves)
  ck("the windows themselves were not recreated",
     paneOf(p2, "left").tabIds[1] == lid and paneOf(p2, "right").tabIds[1] == rid)
  ck("the panel is up and focused", p2.state() == "shown_focused", p2.state())
end

-- A pane already on the right Space must not be moved at all: moveWindowToSpace
-- on a window that is already there is a needless private-API call.
section("a pane already on this Space is left alone")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local moves = #w2.log
  p2.hide(); w2.drain()
  p2.show(); w2.drain()
  local n = 0
  for i = moves + 1, #w2.log do
    if w2.log[i]:match("^moveToSpace") then n = n + 1 end
  end
  ck("no Space move was attempted", n == 0, n)
end

-- The other half of that: a pane put away in the park corner normally sits on
-- another *display*, so its Space differs from the target screen's for a reason
-- that has nothing to do with the user switching Spaces.  Measured on the real
-- three-display Mac: layout() moving the frame onto the target display is enough
-- -- the window joins the Space active there by itself -- while asking hs.spaces
-- to do it as well fails every time.  That failure used to warn on every single
-- show, and with crossSpaceFallback = "recreate" tore both panes down and
-- rebuilt them on every show.
section("a pane parked on another display is not moved between Spaces")
do
  local p2, w2 = boot({ crossSpaceFallback = "recreate" })
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  p2.hide(); w2.drain()
  -- The park corner is on the second display, which shows its own Space.
  local pw = w2.windowOfId(lid)
  local pf = paneOf(p2, "left").parked
  ck("the parked pane really is on another display",
     pf ~= nil and pf.x >= hs.screen.allScreens()[1]:frame().w,
     pf and pf.x)
  w2.spaceOfWindow[pw] = 7
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  w2.alerts = {}
  local before = #w2.log
  p2.show(); w2.drain()
  local n = 0
  for i = before + 1, #w2.log do
    if w2.log[i]:match("^moveToSpace") then n = n + 1 end
  end
  ck("no Space move was attempted", n == 0, n)
  ck("and nothing was recreated", paneOf(p2, "left").tabIds[1] == lid,
     paneOf(p2, "left").tabIds[1])
  ck("the user was not warned about anything", #w2.alerts == 0, #w2.alerts)
  ck("the panel is up on the mouse screen", p2.state() == "shown_focused", p2.state())
  local lf = frameOf(p2, "left")
  local mf = hs.screen.mainScreen():frame()
  ck("laid out at the bottom as usual", lf.y + lf.h == mf.y + mf.h, lf.y + lf.h)
end

-- The tri-state's middle branch has the same problem as show(): "shown but not
-- focused" is a geometric verdict, and a panel one Space over satisfies it.
-- Raising without moving would leave the screen unchanged.
section("the raise branch of the hotkey also brings the panel over")
do
  local p2, w2 = boot()
  -- On the machine this was measured on, a pane one Space over is invisible to
  -- Accessibility, so the hotkey reads "hidden" and it is show() that fetches it
  -- (section 35b).  This branch is for the system hs.window's API assumes, where
  -- the pane is still resolvable and the verdict is therefore "shown but not
  -- focused" -- raising it without moving it would leave the screen unchanged.
  w2.axSeesOtherSpaces = true
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  local rid = paneOf(p2, "right").tabIds[1]
  w2.setWindowSpace(lid, 7)
  w2.setWindowSpace(rid, 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  w2.frontmost = "com.apple.Safari"    -- the user is in another app
  w2.focusedId = nil
  ck("the state the hotkey sees", p2.state() == "shown_unfocused", p2.state())
  local before = #w2.log
  p2.toggle(); w2.drain()
  local n = 0
  for i = before + 1, #w2.log do
    if w2.log[i]:match("^moveToSpace") then n = n + 1 end
  end
  ck("both panes were brought over", n == 2, n)
  ck("and they really are here now",
     w2.spaceOfWindow[w2.windowOfId(lid)] == 3
       and w2.spaceOfWindow[w2.windowOfId(rid)] == 3)
  ck("the panel was raised, not put away", p2.state() == "shown_focused", p2.state())
  ck("without recreating anything", paneOf(p2, "left").tabIds[1] == lid
     and paneOf(p2, "right").tabIds[1] == rid)
end

-- ══ 33. hs.spaces is gone (a macOS update removed it) ═══════════════════════
section("the panel still opens when hs.spaces is unavailable")
do
  local p2, w2 = boot(nil, nil, { noSpaces = true })
  ck("the stub really has no hs.spaces", hs.spaces == nil)
  p2.show(); w2.drain()
  ck("the panel came up anyway", p2.state() == "shown_focused", p2.state())
  ck("both panes exist", #paneOf(p2, "left").tabIds == 1
     and #paneOf(p2, "right").tabIds == 1)
  local lf = frameOf(p2, "left")
  local mainF = hs.screen.mainScreen():frame()
  ck("and it is laid out normally", lf.y + lf.h == mainF.y + mainF.h)
  ck("the user was told once", #w2.alerts == 1, #w2.alerts)
  p2.hide(); w2.drain()
  p2.show(); w2.drain()
  ck("and not told again", #w2.alerts == 1, #w2.alerts)
end

-- ══ 33b. half of hs.spaces still works ═════════════════════════════════════
-- windowSpaces is the one call whose answer decides whether a window gets moved
-- at all, so an unanswerable one must mean "leave it alone", not "move it".
section("a Space that cannot be read is not a Space to move away from")
do
  local p2, w2 = boot({ crossSpaceFallback = "recreate" })
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  w2.windowSpacesFails = true
  local before = #w2.log
  p2.show(); w2.drain()
  local n = 0
  for i = before + 1, #w2.log do
    if w2.log[i]:match("^moveToSpace") then n = n + 1 end
  end
  ck("no move was attempted", n == 0, n)
  ck("and nothing was recreated either", paneOf(p2, "left").tabIds[1] == lid)
  ck("the panel is up", p2.state() == "shown_focused", p2.state())
end

-- ══ 34. the move is refused: "activate" keeps the windows ═══════════════════
section("crossSpaceFallback = activate leaves the panes where they are")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  w2.setWindowSpace(lid, 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  w2.moveSpaceFails = true
  w2.alerts = {}
  p2.show(); w2.drain()
  ck("the pane was not recreated", paneOf(p2, "left").tabIds[1] == lid,
     paneOf(p2, "left").tabIds[1])
  ck("it is still on the other Space",
     w2.spaceOfWindow[w2.windowOfId(lid)] == 7)
  ck("the panel is up regardless", p2.state() == "shown_focused", p2.state())
  ck("the user was told", #w2.alerts == 1, #w2.alerts)
end

-- ══ 35. the move is refused: "recreate" rebuilds here ══════════════════════
section("crossSpaceFallback = recreate rebuilds the stuck pane in this Space")
do
  local p2, w2, c2 = boot({ crossSpaceFallback = "recreate" })
  p2.show(); w2.drain()
  -- Give the left pane a second tab, so the rebuild has to restore both.
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  local lid  = paneOf(p2, "left").tabIds[1]
  local rid  = paneOf(p2, "right").tabIds[1]
  local want = table.concat(paneOf(p2, "left").pathList, ",")

  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  w2.setWindowSpace(lid, 7)        -- the left pane is elsewhere ...
  w2.setWindowSpace(rid, 3)        -- ... the right one is already here
  w2.moveSpaceNoop = true          -- claims success, window does not move
  p2.show(); w2.drain()

  local pane = paneOf(p2, "left")
  ck("the left pane is a new window", pane.tabIds[1] ~= lid, pane.tabIds[1])
  ck("with both of its paths back, in order",
     table.concat(pane.pathList, ",") == want,
     table.concat(pane.pathList, ",") .. " want " .. want)
  ck("in one real window", #pane.tabIds == 2 and #w2.windows == 2,
     #pane.tabIds .. "/" .. #w2.windows)
  ck("it is on this Space now",
     w2.spaceOfWindow[w2.windowOfId(pane.tabIds[1])] == 3
       or w2.spaceOfWindow[w2.windowOfId(pane.tabIds[1])] == nil)
  ck("the right pane, which was fine, was not touched",
     paneOf(p2, "right").tabIds[1] == rid)
  ck("the old window is gone", w2.windowOfId(lid) == nil)
  ck("the panel is up", p2.state() == "shown_focused", p2.state())
  ck("recreate really was the configured fallback", c2.crossSpaceFallback == "recreate")
end

-- ══ 35b. another Space, where Finder hands over no window at all ═══════════
-- Measured on macOS 26 with a Space added for the purpose: standing on a Space
-- the panes are not on, `Finder:allWindows()` answers with the desktop and
-- nothing else, while AppleScript still lists every tab and its path.  Every
-- window handle therefore comes back nil, and the cross-Space code used to be
-- gated on having one -- so it skipped both panes, layout had nothing to lay out,
-- and the hotkey looked dead.  What is still willing to answer is the window
-- *id*: hs.spaces read the pane's Space from it, and AppleScript closes by it.
section("the panel is fetched from another Space although Finder shows no window")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lid, rid = paneOf(p2, "left").tabIds[1], paneOf(p2, "right").tabIds[1]

  w2.setWindowSpace(lid, 7)
  w2.setWindowSpace(rid, 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  p2.reconcile()
  ck("Finder hands over no window for either pane",
     p2.paneWindow("left") == nil and p2.paneWindow("right") == nil)
  ck("both sides are still live, because AppleScript can see their tabs",
     liveSide(p2, "left") and liveSide(p2, "right"))
  ck("so the hotkey reads the panel as hidden", p2.state() == "hidden", p2.state())

  p2.toggle(); w2.drain()
  ck("both panes were brought to the Space the mouse is on",
     w2.spaceOfWindow[w2.windowOfId(lid)] == 3
       and w2.spaceOfWindow[w2.windowOfId(rid)] == 3,
     tostring(w2.spaceOfWindow[w2.windowOfId(lid)]))
  ck("by moving them, not by rebuilding them",
     paneOf(p2, "left").tabIds[1] == lid and paneOf(p2, "right").tabIds[1] == rid)
  ck("and the panel is up and focused", p2.state() == "shown_focused", p2.state())
  local lf = frameOf(p2, "left")
  local mf = hs.screen.mainScreen():frame()
  ck("laid out on the bottom strip", lf and lf.y + lf.h == mf.y + mf.h, lf and lf.y)
end

-- The case the machine actually presents.  moveWindowToSpace returns true and
-- moves nothing there, so "recreate" is the only fallback that puts the panel in
-- front of the user -- and it can do it because closing by id works from another
-- Space and a window made there lands on the Space you are standing on.
section("when the private move only claims to work, recreate still delivers")
do
  local p2, w2 = boot({ crossSpaceFallback = "recreate" })
  p2.show(); w2.drain()
  local lid, rid = paneOf(p2, "left").tabIds[1], paneOf(p2, "right").tabIds[1]
  local want = paneOf(p2, "left").pathList[1]

  w2.setWindowSpace(lid, 7)
  w2.setWindowSpace(rid, 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  w2.moveSpaceNoop = true
  p2.reconcile()
  p2.toggle(); w2.drain()

  ck("both panes are new windows",
     paneOf(p2, "left").tabIds[1] ~= lid and paneOf(p2, "right").tabIds[1] ~= rid)
  ck("the left one kept its path", paneOf(p2, "left").pathList[1] == want,
     paneOf(p2, "left").pathList[1])
  ck("the old windows are gone",
     w2.windowOfId(lid) == nil and w2.windowOfId(rid) == nil)
  ck("what is on screen is on this Space",
     w2.spaceOfWindow[w2.windowOfId(paneOf(p2, "left").tabIds[1])] == 3)
  ck("and Finder will talk about them again",
     p2.paneWindow("left") ~= nil and p2.paneWindow("right") ~= nil)
  ck("the panel is up and focused", p2.state() == "shown_focused", p2.state())
end

-- With the default fallback the panel cannot follow the user on this system, so
-- the one thing that must not happen is a hotkey that quietly does nothing.
section("the default fallback says so when the panel cannot follow")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  w2.setWindowSpace(lid, 7)
  w2.setWindowSpace(paneOf(p2, "right").tabIds[1], 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  w2.moveSpaceNoop = true
  w2.alerts = {}
  p2.reconcile()
  p2.toggle(); w2.drain()
  ck("the windows were left alone", paneOf(p2, "left").tabIds[1] == lid)
  ck("the user was told, once", #w2.alerts == 1, #w2.alerts)
  ck("and told what happened",
     (w2.alerts[1] or ""):match("Space") ~= nil, w2.alerts[1])
end

-- Both awkward things at once: the pane is parked on the second display *and* on
-- a Space that is not showing there, so Finder hands over no window and the only
-- evidence of which display it is on is the frame it was last seen at.  It must
-- still be left alone -- layout is about to move it onto the target display,
-- where it joins that display's Space by itself.
section("a pane on another display and another Space is still not moved")
do
  local p2, w2 = boot({ crossSpaceFallback = "recreate" })
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  p2.hide(); w2.drain()
  local pw = w2.windowOfId(lid)
  w2.spaceOfScreen[hs.screen.allScreens()[2]] = 9   -- the park display shows 9 ...
  w2.setWindowSpace(lid, 7)                          -- ... the pane is on 7
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3   -- and the mouse screen shows 3
  p2.reconcile()
  ck("the parked pane is invisible to Accessibility", p2.paneWindow("left") == nil)
  w2.alerts = {}
  local before = #w2.log
  p2.show(); w2.drain()
  local n = 0
  for i = before + 1, #w2.log do
    if w2.log[i]:match("^moveToSpace") then n = n + 1 end
  end
  ck("no Space move was attempted for it", n == 0, n)
  ck("nothing was recreated", paneOf(p2, "left").tabIds[1] == lid,
     paneOf(p2, "left").tabIds[1])
  ck("nobody was warned", #w2.alerts == 0, #w2.alerts)
  local byId = 0
  for i = before + 1, #w2.log do
    if w2.log[i] == "setBounds:" .. lid then byId = byId + 1 end
  end
  ck("it was laid out by id, because there was no window to lay out", byId > 0, byId)
  ck("and it came back on the mouse screen",
     w2.spaceOfWindow[pw] == 3, tostring(w2.spaceOfWindow[pw]))
  local mf = hs.screen.allScreens()[1]:frame()
  ck("on the bottom strip of it", pw.frame.y + pw.frame.h == mf.y + mf.h, pw.frame.y)
  ck("visible to Accessibility again", p2.paneWindow("left") ~= nil)
  ck("the panel is up", p2.state() == "shown_focused", p2.state())
end

-- ══ 35f. the id path is the only way a blind pane gets laid out ═════════════
-- Measured on macOS 26: with the pane on a Space its display is not showing,
-- `set bounds of window id N` still works, the window arrives on the display the
-- rect names, joins the Space showing there, and turns up in app:allWindows()
-- again -- one write does the whole job.  Without it a blind pane cannot be
-- moved at all, and the panel came up a side short in silence.  So when even
-- that write fails, the pane must be reported stuck rather than assumed placed.
section("a blind pane that cannot even be set by id is left to the fallback")
do
  local p2, w2 = boot({ crossSpaceFallback = "recreate" })
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  p2.hide(); w2.drain()
  local pw = w2.windowOfId(lid)
  local was = pw.frame
  w2.spaceOfScreen[hs.screen.allScreens()[2]] = 9
  w2.setWindowSpace(lid, 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  w2.setBoundsFails = true
  p2.reconcile()
  ck("the parked pane is invisible to Accessibility", p2.paneWindow("left") == nil)
  p2.show(); w2.drain()
  ck("it did not move", pw.frame.x == was.x and pw.frame.y == was.y,
     pw.frame.x .. "," .. pw.frame.y)
  ck("it is still on the Space it was on", w2.spaceOfWindow[pw] == 7,
     tostring(w2.spaceOfWindow[pw]))
  ck("and it is still remembered as parked", paneOf(p2, "left").parked ~= nil)
  ck("the other side still came up", p2.state() ~= "hidden", p2.state())
end

-- ══ 36. crossSpace = false ═════════════════════════════════════════════════
section("crossSpace = false never calls the private API")
do
  local p2, w2 = boot({ crossSpace = false })
  p2.show(); w2.drain()
  w2.setWindowSpace(paneOf(p2, "left").tabIds[1], 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  local before = #w2.log
  p2.show(); w2.drain()
  local n = 0
  for i = before + 1, #w2.log do
    if w2.log[i]:match("^moveToSpace") then n = n + 1 end
  end
  ck("nothing was moved between Spaces", n == 0, n)
  ck("the panel still works", p2.state() == "shown_focused", p2.state())
end

-- ══ 37. adopt: a floating window becomes tabs of a pane ════════════════════
-- Requirement 11.  Merge All Windows is refused on purpose (it is global), so
-- the source is rebuilt tab by tab and each tab is closed only once its
-- replacement exists.
section("adopt merges the frontmost floating window into the near pane")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local rid = paneOf(p2, "right").tabIds[1]
  -- Three floating tabs, in this order, well away from the panel.  Built with
  -- addTab rather than in one go, so the *newest* tab is the active one -- which
  -- is what a window the user has been pressing Cmd+T in looks like, and the
  -- case where "read the active tab, move it, repeat" walks the bar backwards.
  local fw = w2.newWindow({ "/usr" }, { x = 300, y = 200, w = 800, h = 500 })
  w2.addTab(fw, "/bin")
  w2.addTab(fw, "/Applications")
  ck("the source's newest tab is the active one", fw.active == 3, fw.active)
  w2.focusWindow(fw)
  local rf = frameOf(p2, "right")
  w2.setMousePos(rf.x + rf.w / 2, rf.y + rf.h / 2)   -- mouse over the right pane

  local ok, err = p2.adoptFrontmost()
  w2.drain()
  ck("adopt started", ok and err == nil, tostring(err))
  local pane = paneOf(p2, "right")
  ck("it went into the pane nearest the mouse", #pane.tabIds == 4, #pane.tabIds)
  ck("paths arrived in the source's order",
     table.concat(pane.pathList, ",") == HOME .. ",/usr,/bin,/Applications",
     table.concat(pane.pathList, ","))
  ck("the pane's original tab is still first", pane.tabIds[1] == rid)
  ck("the source window is gone", w2.closeWindow(fw) == false)
  ck("Finder is left with just the two panes", #w2.windows == 2, #w2.windows)
  ck("all four tabs are in one real window",
     #w2.windowOfId(pane.tabIds[1]).tabs == 4)
  ck("the left pane was not involved", #paneOf(p2, "left").tabIds == 1)
  ck("the panel is focused", p2.state() == "shown_focused", p2.state())
  ck("focus went to the side that received the tabs", p2.getLastSide() == "right",
     p2.getLastSide())
  ck("and to one of its tabs", p2.sideOfTab(w2.focusedId) == "right",
     tostring(p2.sideOfTab(w2.focusedId)))
end

-- ══ 38. adopt refuses what it should ═══════════════════════════════════════
section("adopt refuses a pane, a non-Finder front app and no window")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local before = #w2.windows

  local ok, err = p2.adoptFrontmost()      -- the panel itself is frontmost
  ck("a pane is refused", ok == false and err:match("part of the panel"), tostring(err))

  w2.frontmost = "com.apple.Safari"
  local ok2, err2 = p2.adoptFrontmost()
  ck("a non-Finder front app is refused", ok2 == false and err2:match("not Finder"),
     tostring(err2))

  w2.frontmost = "com.apple.finder"
  w2.focusedId = nil
  local ok3, err3 = p2.adoptFrontmost()
  ck("no focused Finder window is refused", ok3 == false and err3:match("no Finder window"),
     tostring(err3))
  w2.drain()
  ck("nothing was created or closed", #w2.windows == before, #w2.windows)
  ck("neither pane grew", #paneOf(p2, "left").tabIds == 1
     and #paneOf(p2, "right").tabIds == 1)
end

-- ══ 39. adopt with the panel hidden brings it out first ════════════════════
-- Otherwise the window the user just adopted would seem to vanish into a corner.
section("adopt on a hidden panel shows it")
do
  local p2, w2 = boot({ adoptTarget = "left" })
  p2.show(); w2.drain()
  p2.hide(); w2.drain()
  ck("the panel is away", p2.state() == "hidden", p2.state())
  local fw = w2.newWindow({ "/usr" }, { x = 300, y = 200, w = 800, h = 500 })
  w2.focusWindow(fw)
  p2.adoptFrontmost(); w2.drain()
  ck("the panel came out", p2.state() == "shown_focused", p2.state())
  ck("and the tab landed in the configured side", #paneOf(p2, "left").tabIds == 2,
     #paneOf(p2, "left").tabIds)
  ck("with the source's path", paneOf(p2, "left").pathList[2] == "/usr",
     tostring(paneOf(p2, "left").pathList[2]))
  ck("the source window is gone", #w2.windows == 2, #w2.windows)
end

-- ══ 40. adopt stops on failure without losing a tab ════════════════════════
-- The whole reason each tab is closed only after its replacement exists.
section("a failed New Tab during adopt leaves the rest of the source alone")
do
  local p2, w2 = boot({ adoptTarget = "right" })
  p2.show(); w2.drain()
  local fw = w2.newWindow({ "/usr", "/bin", "/Applications" }, { x = 300, y = 200, w = 800, h = 500 })
  w2.focusWindow(fw)
  w2.failNewTabAt = 2                       -- the second tab cannot be created
  p2.adoptFrontmost(); w2.drain()

  ck("one tab made it across", #paneOf(p2, "right").tabIds == 2,
     #paneOf(p2, "right").tabIds)
  ck("and it is the first one", paneOf(p2, "right").pathList[2] == "/usr",
     tostring(paneOf(p2, "right").pathList[2]))
  ck("the source still has the other two", #fw.tabs == 2, #fw.tabs)
  ck("no path was lost",
     fw.tabs[1].path == "/bin" and fw.tabs[2].path == "/Applications",
     fw.tabs[1].path .. "," .. fw.tabs[2].path)
  ck("the user was told adopt stopped",
     (w2.alerts[#w2.alerts] or ""):match("adopt stopped"), w2.alerts[#w2.alerts])
  ck("the source window still exists", w2.windowOfId(fw.tabs[1].id) == fw)
end

-- ══ 40b. adopt stands down while a rebuild is still pouring tabs in ════════
-- Both would be pressing Cmd+T into the same window through the same one-at-a
-- -time channel, and the queue has no way to notice tabs it did not ask for.
section("adopt refuses to race a queued rebuild")
do
  local p2, w2 = boot({ adoptTarget = "left" })
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  p2.hide(); w2.drain()
  w2.windows = {}; p2.onFinderTerminated()          -- Finder restarted

  p2.show()
  -- Stop the moment the panel is up but the second tab has not arrived yet.
  local caught = false
  for _ = 1, 30 do
    if p2.state() ~= "hidden" and paneOf(p2, "left").pending then caught = true; break end
    if w2.step() == 0 then break end
  end
  ck("caught the panel mid-rebuild", caught, p2.state())

  local fw = w2.newWindow({ "/etc" }, { x = 300, y = 200, w = 800, h = 500 })
  w2.focusWindow(fw)
  w2.alerts = {}
  p2.adoptFrontmost()
  ck("adopt stood down and said why",
     (w2.alerts[1] or ""):match("still restoring"), tostring(w2.alerts[1]))
  w2.drain()
  ck("the floating window still has its tab", #fw.tabs == 1, #fw.tabs)
  ck("it is still floating", p2.sideOfTab(fw.tabs[1].id) == nil)
  ck("the rebuild finished undisturbed", #paneOf(p2, "left").tabIds == 2,
     #paneOf(p2, "left").tabIds)
  ck("with both remembered paths",
     table.concat(paneOf(p2, "left").pathList, ",") == HOME .. "/Downloads,/Applications",
     table.concat(paneOf(p2, "left").pathList, ","))
end

-- ══ 41. adopt never touches a second floating window ═══════════════════════
-- The frame match plus the tab-count budget is what keeps a lookalike safe.
section("adopt leaves other floating windows alone")
do
  local p2, w2 = boot({ adoptTarget = "left" })
  p2.show(); w2.drain()
  local victim = w2.newWindow({ "/etc", "/var" }, { x = 900, y = 700, w = 600, h = 400 })
  local fw     = w2.newWindow({ "/usr" }, { x = 300, y = 200, w = 800, h = 500 })
  w2.focusWindow(fw)
  p2.adoptFrontmost(); w2.drain()
  ck("only the source was adopted", #paneOf(p2, "left").tabIds == 2,
     #paneOf(p2, "left").tabIds)
  ck("the other floating window kept both tabs", #victim.tabs == 2, #victim.tabs)
  ck("and its frame", victim.frame.x == 900 and victim.frame.y == 700)
  ck("it is still floating", p2.sideOfTab(victim.tabs[1].id) == nil)
end

-- ══ 43. dumpState is a debugging tool, so it must not lie ══════════════════
-- Found against the real Finder: navigating a tab and then dumping showed the
-- path the tab had when the panel last opened.  Paths are only refreshed by
-- reconcile(), and between two hotkey presses nothing calls it -- which is
-- precisely the moment someone asks for a dump.
section("dumpState reflects where the tabs are now")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  w2.navigate(lid, "/private/tmp")     -- the user double-clicks a folder
  local dump = p2.dumpState()
  ck("the new path is in the dump", dump:find("/private/tmp", 1, true) ~= nil, dump)
  ck("and the model was updated too",
     paneOf(p2, "left").pathList[1] == "/private/tmp",
     paneOf(p2, "left").pathList[1])
  ck("the dump still reports the state and both sides",
     dump:find("shown_focused", 1, true) and dump:find("right", 1, true) ~= nil)
end

-- ══ 44. persisting is entered from outside, so it refreshes first ══════════
-- The shutdown hook and stop() call persistNow() straight from Hammerspoon, with
-- no reconcile anywhere near.  Found for real: navigate a tab, hs.reload(), and
-- the path written down -- and rebuilt from after a Finder restart -- was the old
-- one.
section("persistNow writes down where the tabs are now")
do
  local p2, w2, _, _, store = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  w2.navigate(lid, "/private/tmp")
  p2.persistNow()                       -- as the shutdown hook does it
  local st = store.load()
  ck("the persisted path is the new one",
     st.panes.left.paths[1] == "/private/tmp", st.panes.left.paths[1])

  -- And a Finder that has gone away must not turn a persist into an erasure.
  w2.navigate(lid, "/usr")
  w2.finderRunning = false              -- Finder died before the hook ran
  p2.persistNow()
  local st2 = store.load()
  ck("a dead Finder leaves the last known paths alone",
     st2.panes.left.paths[1] == "/private/tmp", st2.panes.left.paths[1])
  ck("and keeps the tab ids", st2.panes.left.tabIds[1] == lid, st2.panes.left.tabIds[1])
end

-- ══ 45. the hotkey right after `killall Finder` ════════════════════════════
-- Measured, and the reason this section exists: a Finder that has just relaunched
-- and has never been activated hands out windows that cannot be addressed, so
-- both sides failed to open, the hotkey did nothing, and two untargeted windows
-- were left on screen.
section("show() wakes a Finder that has just restarted and retries")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local paths = { paneOf(p2, "left").pathList[1], paneOf(p2, "right").pathList[1] }
  -- Finder dies and comes back with its window collection unaddressable.
  p2.onFinderTerminated(); w2.drain()
  w2.windows = {}
  w2.finderAsleep = true
  w2.frontmost = "com.apple.Safari"; w2.focusedId = nil

  p2.show(); w2.drain()
  ck("both panes came up on the retry", liveSide(p2, "left") and liveSide(p2, "right"),
     tostring(#paneOf(p2, "left").tabIds) .. "/" .. tostring(#paneOf(p2, "right").tabIds))
  ck("at the paths they had", paneOf(p2, "left").pathList[1] == paths[1]
     and paneOf(p2, "right").pathList[1] == paths[2],
     paneOf(p2, "left").pathList[1] .. "/" .. paneOf(p2, "right").pathList[1])
  ck("Finder was woken exactly once",
     countLog(w2, "^launchOrFocus:com%.apple%.finder$") == 1,
     countLog(w2, "^launchOrFocus:com%.apple%.finder$"))
  ck("the windows it could not address were taken back", #w2.windows == 2, #w2.windows)
  ck("the panel is up", p2.state() == "shown_focused", p2.state())
  ck("and laid out", geometry.isOnScreen(frameOf(p2, "left")))
end

-- A Finder that stays broken must not turn the hotkey into a retry loop.
section("a Finder that never wakes up is given exactly one second chance")
do
  local p2, w2 = boot()
  w2.finderAsleep = true
  w2.stickyAsleep = true          -- activating it does not help either
  p2.show(); w2.drain()
  ck("it tried twice and stopped", countLog(w2, "^openWindowAt:asleep:") == 4,
     countLog(w2, "^openWindowAt:asleep:"))
  ck("no pane was invented", not liveSide(p2, "left") and not liveSide(p2, "right"))
  ck("the state is still coherent", p2.state() == "hidden", p2.state())
end

-- The failure this pair exists for was silent: two panes that had just been
-- created went missing within two seconds, and the only thing that could have
-- done it left nothing in the log.  An empty AppleScript snapshot is a claim,
-- not a fact, and Accessibility is the way to check it.
section("Finder claiming it has no windows does not delete the panel")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  -- Two tabs on the left, because AX only ever exposes the active one: a guard
  -- that leans on Accessibility alone would quietly drop the other.
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/private/tmp")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  local ids = { paneOf(p2, "left").tabIds[1], paneOf(p2, "right").tabIds[1] }
  local tabs = #paneOf(p2, "left").tabIds
  local windows = #w2.windows
  ck("the left pane has two tabs to start with", tabs == 2, tabs)

  w2.finderAsleep = true          -- `id of every window` answers nothing
  ck("reconcile refuses to work from it", p2.reconcile() == false)
  ck("both panes survive", liveSide(p2, "left") and liveSide(p2, "right"))
  ck("with the same tab ids", paneOf(p2, "left").tabIds[1] == ids[1]
     and paneOf(p2, "right").tabIds[1] == ids[2])
  ck("including the tab Accessibility cannot see on its own",
     #paneOf(p2, "left").tabIds == tabs, #paneOf(p2, "left").tabIds)
  ck("and nothing was rebuilt", #w2.windows == windows, #w2.windows)

  w2.finderAsleep = false
  ck("and it picks up again once Finder answers", p2.reconcile() == true)
  ck("the panel never left the screen", p2.state() == "shown_focused", p2.state())
end

section("a tab missing from the snapshot alone is kept, at its last known path")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  local was = paneOf(p2, "left").pathList[1]

  w2.snapshotOmits = { [lid] = true }
  ck("reconcile still runs", p2.reconcile() == true)
  ck("the tab is kept", liveSide(p2, "left") and paneOf(p2, "left").tabIds[1] == lid)
  ck("at the path we last read", paneOf(p2, "left").pathList[1] == was,
     paneOf(p2, "left").pathList[1])
  ck("the other side is untouched", liveSide(p2, "right"))

  -- Closed for real: neither view can see it, and it goes.
  w2.snapshotOmits = nil
  w2.closeWindow(w2.windowOfId(lid))
  ck("a genuinely closed tab is still dropped", p2.reconcile() == true
     and not liveSide(p2, "left"), #paneOf(p2, "left").tabIds)
  ck("and its path is kept for the rebuild", paneOf(p2, "left").pathList[1] == was)
end

-- Requirement 12 read literally ("give focus back to the app the panel came up
-- over") is wrong in one case the user hit immediately: the panel can come up
-- over a *floating Finder window*.  Handing focus to the app they were in before
-- Finder then shoved that window behind it -- the panel went away and took their
-- window's place in the order with it.
section("hiding gives focus back to the floating Finder window it came up over")
do
  local p2, w2 = boot()
  -- A full round from the user's editor first, so "the app before Finder" is on
  -- record and the assertion below that it is left alone means something.
  w2.activateOther("dev.zed.Zed")
  p2.show(); w2.drain()
  p2.hide(); w2.drain()
  ck("that app got focus back the ordinary way",
     countLog(w2, "^launchOrFocus:dev%.zed%.Zed$") == 1,
     countLog(w2, "^launchOrFocus:dev%.zed%.Zed$"))

  local fl   = w2.newWindow({ HOME .. "/Pictures" }, { x = 815, y = 175, w = 811, h = 399 })
  local flid = fl.tabs[1].id
  local rect = { x = fl.frame.x, y = fl.frame.y, w = fl.frame.w, h = fl.frame.h }
  w2.mkwin(fl, 1):focus()               -- the user clicks into their own window
  ck("the floating window is the front one", w2.zIndex(fl) == 1, w2.zIndex(fl))

  p2.show(); w2.drain()
  ck("the panel came up focused", p2.state() == "shown_focused", p2.state())
  ck("and over the floating window", w2.zIndex(fl) > 2, w2.zIndex(fl))

  p2.hide(); w2.drain()
  ck("the panel is away", p2.state() == "hidden", p2.state())
  ck("Finder still has focus", w2.frontmost == "com.apple.finder", w2.frontmost)
  ck("on the floating window", w2.focusedId == flid, w2.focusedId)
  ck("which is back in front", w2.zIndex(fl) == 1, w2.zIndex(fl))
  ck("the app before Finder was not activated a second time",
     countLog(w2, "^launchOrFocus:dev%.zed%.Zed$") == 1,
     countLog(w2, "^launchOrFocus:dev%.zed%.Zed$"))
  -- Requirement 4 all the same: focus is the only thing that touched it.
  ck("and it was never moved or resized",
     fl.frame.x == rect.x and fl.frame.y == rect.y
     and fl.frame.w == rect.w and fl.frame.h == rect.h,
     string.format("%d,%d %dx%d", fl.frame.x, fl.frame.y, fl.frame.w, fl.frame.h))
  ck("nor minimized or closed", not fl.minimized and w2.windowOfId(flid) == fl)
end

section("a floating window that is gone by hide() falls back to the app")
do
  local p2, w2 = boot()
  -- One round from Safari first, so there is an app on record to fall back to.
  w2.activateOther("com.apple.Safari")
  p2.show(); w2.drain()
  p2.hide(); w2.drain()
  ck("the ordinary case still goes back to the app",
     countLog(w2, "^launchOrFocus:com%.apple%.Safari$") == 1,
     countLog(w2, "^launchOrFocus:com%.apple%.Safari$"))

  local fl   = w2.newWindow({ HOME .. "/Pictures" })
  local flid = fl.tabs[1].id
  w2.mkwin(fl, 1):focus()
  p2.show(); w2.drain()

  w2.closeWindow(fl)                              -- Cmd+W while the panel is up
  p2.hide(); w2.drain()
  ck("focus went to the app instead",
     countLog(w2, "^launchOrFocus:com%.apple%.Safari$") == 2,
     countLog(w2, "^launchOrFocus:com%.apple%.Safari$"))
  ck("and nothing tried to focus the dead window", w2.focusedId ~= flid)
end

-- The lost tab this exists for was real: adopting three tabs in a row reported
-- three and left the pane with six tabs in Finder and five in the model.  A tab
-- is created, and for a moment afterwards *neither* view can see it -- Finder
-- has not published it to `id of every window` and AX still hands over the tab
-- that was active before.  The next round starts with a reconcile, and a
-- reconcile that believes both views deletes the tab it just made.
section("a new tab neither view has published yet is not dropped")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications"); p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/usr");          p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  local want = table.concat(paneOf(p2, "left").pathList, "|")
  ck("three tabs to restore", #paneOf(p2, "left").tabIds == 3,
     #paneOf(p2, "left").tabIds)
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()

  w2.lagNextNewTab = true          -- the middle tab of the rebuild
  p2.show()
  local guard = 0
  while w2.step() > 0 and guard < 80 do guard = guard + 1 end
  ck("the rebuild finished", paneOf(p2, "left").pending == nil)
  ck("the tab Finder had not published yet is still in the model",
     #paneOf(p2, "left").tabIds == 3, #paneOf(p2, "left").tabIds)
  ck("and the model matches the window", #w2.windowOfId(paneOf(p2, "left").tabIds[1]).tabs == 3,
     #w2.windowOfId(paneOf(p2, "left").tabIds[1]).tabs)

  w2.newTabLagged = nil            -- Finder catches up
  ck("reconcile keeps it once both views agree",
     p2.reconcile() and #paneOf(p2, "left").tabIds == 3,
     #paneOf(p2, "left").tabIds)
  ck("at the paths it was restoring", table.concat(paneOf(p2, "left").pathList, "|") == want,
     table.concat(paneOf(p2, "left").pathList, "|"))

  -- And it really is only a grace: a tab that never turns up at all is not kept
  -- for ever, or a New Tab that opened somewhere unreachable would haunt the
  -- model.  Same rebuild, but Finder never catches up.
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()
  w2.lagNextNewTab = true
  p2.show()
  guard = 0
  while w2.step() > 0 and guard < 80 do guard = guard + 1 end
  ck("the unpublished tab is in the model to begin with",
     #paneOf(p2, "left").tabIds == 3, #paneOf(p2, "left").tabIds)
  -- Three seconds is the interval that actually lost a tab on the machine: one
  -- adopt round, then the reconcile at the top of the next one.  The grace has to
  -- outlast it by a margin, so this wait must change nothing.
  w2.advance(3)
  p2.reconcile()
  ck("a wait the length of one adopt round does not drop it",
     #paneOf(p2, "left").tabIds == 3, #paneOf(p2, "left").tabIds)
  w2.advance(20)
  p2.reconcile()
  ck("a tab that never turns up is dropped in the end",
     #paneOf(p2, "left").tabIds == 2, #paneOf(p2, "left").tabIds)
end

-- The same lag, on the path that actually lost a tab: three tabs adopted in a
-- row, the middle one published late.  Reported as "adopted 3 tab(s)" with the
-- pane holding six tabs in Finder and five in the model.
section("adopt keeps a tab Finder was slow to publish")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local fw = w2.newWindow({ "/usr" }, { x = 300, y = 200, w = 800, h = 500 })
  w2.addTab(fw, "/bin")
  w2.addTab(fw, "/Applications")
  w2.focusWindow(fw)
  local rf = frameOf(p2, "right")
  w2.setMousePos(rf.x + rf.w / 2, rf.y + rf.h / 2)

  ck("adopt started", (p2.adoptFrontmost()))
  local guard, armed = 0, false
  while w2.step() > 0 and guard < 120 do
    guard = guard + 1
    -- Arm the lag for the *middle* tab, so the reconcile at the top of the next
    -- round is the one that has to keep it.
    if not armed and #paneOf(p2, "right").tabIds == 2 then
      w2.lagNextNewTab, armed = true, true
    end
  end
  ck("the lag was armed part way through", armed)
  ck("all three tabs arrived in the model", #paneOf(p2, "right").tabIds == 4,
     #paneOf(p2, "right").tabIds)
  ck("the source window is gone", w2.closeWindow(fw) == false)

  w2.newTabLagged = nil
  p2.reconcile()
  local pane = paneOf(p2, "right")
  ck("Finder and the model agree on the tab count",
     #pane.tabIds == #w2.windowOfId(pane.tabIds[1]).tabs,
     #pane.tabIds .. " vs " .. #w2.windowOfId(pane.tabIds[1]).tabs)
  ck("in the source's order",
     table.concat(pane.pathList, ",") == HOME .. ",/usr,/bin,/Applications",
     table.concat(pane.pathList, ","))
end

-- ══ 46. a tab Finder appended without selecting it ═════════════════════════
-- Measured on a pane holding fourteen tabs, and the reason this section exists:
-- File > New Tab put every tab in the tab bar without making it active, so the
-- new id never reached the AX tree and the two original signals were both blind
-- to it -- thirteen tabs in a row were left floating, and a hide()/show() would
-- have thrown them away.
section("a tab appended without being selected is still adopted")
do
  local p2, w2, _, geometry = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  local id = w2.addBackgroundTab(lw, "/Applications")
  ck("Finder did not switch to it", lw.tabs[lw.active].id ~= id,
     tostring(lw.tabs[lw.active].id))
  ck("and it is nowhere in the AX tree", w2.finder.axWindowById(id) == nil)
  ck("its own handle has no tab bar to read",
     #w2.finder.tabTitles(w2.mkwin(lw, #lw.tabs)) == 0)

  p2.onWindowCreated(w2.mkwin(lw, #lw.tabs)); w2.drain()
  local pane = paneOf(p2, "left")
  ck("the pane adopted it anyway", p2.sideOfTab(id) == "left", tostring(p2.sideOfTab(id)))
  ck("with its path", table.concat(pane.pathList, ",")
     == HOME .. "/Downloads,/Applications", table.concat(pane.pathList, ","))
  ck("and the pane's active tab was left alone", pane.activeId == lw.tabs[lw.active].id,
     tostring(pane.activeId))

  -- Requirement 2 still holds: a window the user opened lands at the same place
  -- and the pane's tab bar is still one tab ahead of the model, but it comes with
  -- an AX window of its own, and that is the difference.
  local before = #pane.tabIds
  local untracked = w2.addBackgroundTab(lw, "/usr")   -- never announced
  local fl = w2.newWindow({ "/etc" }, { x = pane.frame.x, y = pane.frame.y,
                                        w = pane.frame.w, h = pane.frame.h })
  local flx, fly = fl.frame.x, fl.frame.y
  p2.onWindowCreated(w2.mkwin(fl, 1))

  -- Before draining, because this is the one moment a mistake here cannot be
  -- taken back: a tab just adopted is a fresh tab, the regroup leaves fresh tabs
  -- alone for a second or two, and a press in that gap parks whatever the side
  -- resolves to.  Take the window and the next press takes it away with the panel.
  p2.hide(); w2.drain()
  ck("a press straight afterwards did not park the window the user opened",
     fl.frame.x == flx and fl.frame.y == fly, fl.frame.x .. "," .. fl.frame.y)
  ck("it parked the pane's own window instead",
     not geometry.isOnScreen(w2.windowOfId(pane.tabIds[1]).frame))
  p2.show(); w2.drain()

  ck("the floating window was not adopted", p2.sideOfTab(fl.tabs[1].id) == nil)
  ck("the pane gained nothing from it", #paneOf(p2, "left").tabIds == before,
     #paneOf(p2, "left").tabIds)
  ck("nor did it swallow the untracked tab", p2.sideOfTab(untracked) == nil)
end

-- ══ 46b. the same signal must not reach into someone else's window ══════════
-- The growth test is a comparison, so it needs its boundary pinned: a pane whose
-- tab bar is exactly as long as the model has not grown.  A Cmd+T in the user's
-- own floating window -- which they may well have dragged over the panel -- looks
-- from the outside exactly like the case above, minus that growth.
section("a tab appended to a floating window at the pane's place is left alone")
do
  local p2, w2, _, _, store = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  local pane = paneOf(p2, "left")
  ck("the pane owns two tabs", #pane.tabIds == 2, #pane.tabIds)
  ck("and its tab bar lists exactly those",
     #w2.finder.tabTitles(p2.paneWindow("left")) == #pane.tabIds,
     #w2.finder.tabTitles(p2.paneWindow("left")))

  local fl = w2.newWindow({ "/etc", "/var" }, { x = pane.frame.x, y = pane.frame.y,
                                                w = pane.frame.w, h = pane.frame.h })
  local id = w2.addBackgroundTab(fl, "/usr")
  p2.onWindowCreated(w2.mkwin(fl, #fl.tabs)); w2.drain()
  ck("the pane did not take the other window's tab", p2.sideOfTab(id) == nil,
     tostring(p2.sideOfTab(id)))
  ck("and still owns two", #paneOf(p2, "left").tabIds == 2,
     #paneOf(p2, "left").tabIds)
  -- The model recovers from a mistake here on its own -- the regroup gives back
  -- any tab of ours a window we do not manage turns out to be holding -- but the
  -- record on disk does not: a persist that happened while the tab was ours
  -- leaves its path in the recipe, and a Finder restart would then rebuild
  -- someone else's tab as one of the panel's.
  local st = store.load()
  ck("and the recipe on disk never mentioned it",
     table.concat(st.panes.left.paths, "|"):find("/usr", 1, true) == nil,
     table.concat(st.panes.left.paths, "|"))
end

-- ══ 47. an interrupted rebuild must not be a lost rebuild ══════════════════
-- The measured failure this whole section exists for: after `killall Finder`, the
-- hotkey brought the left pane back with 5 of its 8 tabs and the other 3 were
-- gone from memory *and* from disk.  Three things had to be true at once, and
-- this is the first: a pane rebuilt from a recipe goes on screen with one tab, so
-- the paths array -- which is index-aligned with the tab ids -- can only describe
-- that one tab, and show() persists right there, before the rest are made.
section("the recipe on disk stays whole while a rebuild is still running")
do
  local hsStub, w2 = W.new()
  hs = hsStub
  local configLib = dofile(R .. "config.lua")
  local geo = dofile(R .. "geometry.lua")
  local st  = dofile(R .. "store.lua")
  local p2  = dofile(R .. "panel.lua")
  local c2  = configLib.loadConfig()
  p2.setDeps({ finder = w2.finder, geometry = geo, store = st, log = hs.logger.new() })
  p2.setConfig(c2); p2.loadState(); p2.reconcile()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  for _, path in ipairs({ "/Applications", "/usr", "/etc" }) do
    w2.addTab(lw, path)
    p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  end
  ck("four tabs to remember", #paneOf(p2, "left").tabIds == 4,
     #paneOf(p2, "left").tabIds)
  p2.hide(); w2.drain()
  w2.windows = {}                              -- killall Finder
  p2.onFinderTerminated(); w2.drain()

  -- Press the hotkey and stop the world mid-drain: the panel is up with its
  -- first tab and the other three are still queued.
  -- Press the hotkey and stop the world at the exact step show() writes the
  -- rebuilt pane down -- before completeRebuilds() has made a single extra tab.
  -- That write is the one that used to truncate the recipe to one folder.
  p2.show()
  local guard = 0
  while guard < 40 and #st.load().panes.left.tabIds ~= 1 do
    w2.step(); guard = guard + 1
  end
  local disk = st.load()
  ck("the panel is up and written down with one tab",
     #disk.panes.left.tabIds == 1, #disk.panes.left.tabIds)
  ck("the pane still has a queue behind it", paneOf(p2, "left").pending ~= nil)
  local queued = (disk.panes.left.pending or { paths = {} }).paths
  ck("but what is written down is the whole recipe",
     #disk.panes.left.paths + #queued == 4,
     #disk.panes.left.paths .. "+" .. #queued)
  ck("and it says which tab was meant to end up active",
     (disk.panes.left.pending or {}).activePath ~= nil)

  -- Now lose Hammerspoon in the middle of it.  Fresh modules against the same
  -- Finder and the same settings -- and no timers, because a reload takes the
  -- whole Lua state with it, in-flight drain included.  The New Tab that was in
  -- flight goes with it: what was written down is what exists.
  local rw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  while #rw.tabs > 1 do w2.closeTabById(rw.tabs[#rw.tabs].id) end
  w2.timers = {}
  local p3 = dofile(R .. "panel.lua")
  p3.setDeps({ finder = w2.finder, geometry = dofile(R .. "geometry.lua"),
               store = dofile(R .. "store.lua"), log = hs.logger.new() })
  p3.setConfig(c2); p3.loadState(); p3.reconcile()
  ck("the queue came back with it", paneOf(p3, "left").pending ~= nil)
  p3.show(); w2.drain()
  local pane = paneOf(p3, "left")
  ck("and the next press finishes the job", #pane.tabIds == 4, #pane.tabIds)
  ck("with every folder in its place", table.concat(pane.pathList, ",")
     == HOME .. "/Downloads,/Applications,/usr,/etc", table.concat(pane.pathList, ","))
  ck("nothing left over", pane.pending == nil)
  ck("as tabs of one window", #w2.windowOfId(pane.tabIds[1]).tabs == 4)
end

-- ══ 47b. the one moment a reload cannot be papered over ════════════════════
-- A New Tab that Finder has already made but whose id has not come back yet: the
-- tab exists, nothing knows about it, and a reload right there leaves it as the
-- pane's active tab with no entry in the model.  AX only ever exposes the active
-- tab, so the drain has no handle to press New Tab in -- and guessing which real
-- window is ours from tab-bar folder names could pour tabs into one of the user's
-- own windows, which is the one thing this spoon must never do.  So it stops.
-- What it must still do is lose nothing: the recipe is intact and the next
-- rebuild of that side puts every tab back.
section("a reload between a tab and its bookkeeping loses no paths")
do
  local hsStub, w2 = W.new()
  hs = hsStub
  local configLib = dofile(R .. "config.lua")
  local st  = dofile(R .. "store.lua")
  local p2  = dofile(R .. "panel.lua")
  local c2  = configLib.loadConfig()
  p2.setDeps({ finder = w2.finder, geometry = dofile(R .. "geometry.lua"),
               store = st, log = hs.logger.new() })
  p2.setConfig(c2); p2.loadState(); p2.reconcile()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  for _, path in ipairs({ "/Applications", "/usr", "/etc" }) do
    w2.addTab(lw, path)
    p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  end
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()

  p2.show()
  local guard = 0
  while guard < 40 and #st.load().panes.left.tabIds ~= 1 do
    w2.step(); guard = guard + 1
  end
  local rw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  ck("Finder has made a tab nothing has been told about yet", #rw.tabs == 2, #rw.tabs)
  w2.timers = {}                               -- hs.reload() lands right here

  local p3 = dofile(R .. "panel.lua")
  p3.setDeps({ finder = w2.finder, geometry = dofile(R .. "geometry.lua"),
               store = dofile(R .. "store.lua"), log = hs.logger.new() })
  p3.setConfig(c2); p3.loadState(); p3.reconcile()
  p3.show(); w2.drain()
  local pane = paneOf(p3, "left")
  local queued = (pane.pending or { paths = {} }).paths
  ck("every remembered folder is still accounted for",
     #pane.pathList + #queued == 4, #pane.pathList .. "+" .. #queued)
  ck("and nothing was poured into a window we could not identify",
     #w2.windows == 2 and #rw.tabs == 2, #w2.windows .. "/" .. #rw.tabs)

  -- The next rebuild of that side is what makes it whole again.
  w2.windows = {}
  p3.onFinderTerminated(); w2.drain()
  p3.show(); w2.drain()
  local after = paneOf(p3, "left")
  ck("a rebuild brings all four back", #after.tabIds == 4, #after.tabIds)
  ck("in order", table.concat(after.pathList, ",")
     == HOME .. "/Downloads,/Applications,/usr,/etc", table.concat(after.pathList, ","))
end

-- ══ 48. "its window is gone" is two different things ═══════════════════════
-- The second of the three: a Finder that has just relaunched can answer "no
-- windows" from its AX tree for a long time while AppleScript lists them all --
-- measured, and confirmed through System Events, so it is Finder's AX server and
-- not Hammerspoon's doing.  The drain used to read that as "the pane is gone",
-- drop the queue and log one warning.
section("a rebuild waits out an AX tree that has gone blind")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/usr")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()

  w2.axBlindRounds = 4                         -- Finder is back; its AX tree is not
  p2.show(); w2.drain()
  local pane = paneOf(p2, "left")
  ck("every remembered tab still came back", #pane.tabIds == 3, #pane.tabIds)
  ck("in order", table.concat(pane.pathList, ",")
     == HOME .. "/Downloads,/Applications,/usr", table.concat(pane.pathList, ","))
  ck("and the queue is empty because it was drained, not dropped",
     pane.pending == nil)
end

-- ══ 48b. ... and when it really is gone, the queue is kept for later ═══════
-- The pane is not coming back on its own, so the drain has to stop.  What it must
-- not do is take the paths with it: the next hotkey press is the thing that
-- rebuilds the pane, and it needs the recipe.
section("a pane that is really gone keeps its queue for the next press")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/usr")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()

  p2.show()
  local guard = 0
  while paneOf(p2, "left").pending == nil and guard < 20 do
    w2.step(); guard = guard + 1
  end
  -- Cmd+W on the pane while its tabs are still arriving, and Finder never
  -- answers for it again.
  w2.closeWindow(w2.windowOfId(paneOf(p2, "left").tabIds[1]))
  p2.onWindowDestroyed(); w2.drain()
  ck("the pane is recorded as gone", #paneOf(p2, "left").tabIds == 0)
  ck("the queue is still there", paneOf(p2, "left").pending ~= nil)

  -- And the next press rebuilds from recipe plus queue, not from the one tab that
  -- happened to exist when the pane died.
  p2.show(); w2.drain()
  local pane = paneOf(p2, "left")
  ck("the pane came back with all three tabs", #pane.tabIds == 3, #pane.tabIds)
  ck("in the remembered order", table.concat(pane.pathList, ",")
     == HOME .. "/Downloads,/Applications,/usr", table.concat(pane.pathList, ","))
end

-- ══ 48c. stop() calls the drain off without forgetting what it owed ═════════
section("stop() ends a restore in flight but keeps its paths")
do
  local p2, w2, _, _, st = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  w2.addTab(lw, "/Applications")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/usr")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  p2.hide(); w2.drain()
  w2.windows = {}
  p2.onFinderTerminated(); w2.drain()

  p2.show()
  local guard = 0
  while paneOf(p2, "left").pending == nil and guard < 20 do
    w2.step(); guard = guard + 1
  end
  local before = #paneOf(p2, "left").tabIds
  p2.persistNow()
  p2.restoreAll()                              -- what stop() does
  w2.drain()
  ck("the restore stopped where it was", #paneOf(p2, "left").tabIds == before,
     #paneOf(p2, "left").tabIds .. "/" .. before)
  local disk = st.load()
  local queued = (disk.panes.left.pending or { paths = {} }).paths
  ck("and every path is still written down",
     #disk.panes.left.paths + #queued == 3,
     #disk.panes.left.paths .. "+" .. #queued)
end

-- ══ 49. a window we made and then lost sight of is taken back, not abandoned ══
-- The defect this section exists for, measured on the machine: reconcile drops an
-- id the moment Finder stops listing it, which is right for the model and wrong
-- for the window.  Finder omits live windows for reasons of its own (for minutes
-- after a relaunch, and for a pane whose display is showing another Space), and
-- the id that was dropped was also forgotten -- so two windows DropFinder had
-- made itself sat in the panel's two slots for an hour, with the rebuilt panes
-- laid out exactly on top of them.  From the outside the panel had stopped
-- hiding and the hotkey only moved focus.
section("a pane Finder stopped mentioning is reclaimed, not duplicated")
do
  local p2, w2, _, geo, st = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  local rid = paneOf(p2, "right").tabIds[1]
  local lrw = w2.windowOfId(lid)
  local shown = lrw.frame

  -- Finder stops mentioning the left pane, and its display is showing another
  -- Space so Accessibility cannot vouch for it either.  The right pane keeps
  -- answering, so this is not the total blindness the snapshot guard covers.
  w2.snapshotOmits = { [lid] = true }
  w2.setWindowSpace(lid, 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  p2.reconcile()
  ck("the model has let the left pane go", not liveSide(p2, "left"),
     #paneOf(p2, "left").tabIds)
  ck("but the window is still there, in the panel's slot", w2.windowOfId(lid) ~= nil)

  -- Finder starts answering again -- which is all that ever happened in reality.
  w2.snapshotOmits = nil
  w2.setWindowSpace(lid, 3)
  local before = #w2.windows
  p2.show(); w2.drain()
  ck("the stranded window is the left pane again",
     paneOf(p2, "left").tabIds[1] == lid, paneOf(p2, "left").tabIds[1])
  ck("no second pane was made for that side", #w2.windows == before, #w2.windows)
  ck("the right pane was left alone", paneOf(p2, "right").tabIds[1] == rid)
  ck("and it is laid out, not left where it was stranded",
     geo.isOnScreen(frameOf(p2, "left")))

  -- The whole point: it hides again.
  p2.hide(); w2.drain()
  ck("the reclaimed pane parks with the other", p2.state() == "hidden", p2.state())
  ck("off the screen it was stranded on",
     not geo.framesEqual(w2.windowOfId(lid).frame, shown, 4))
  local disk = st.load()
  ck("and the reclaim is on disk", disk.panes.left.tabIds[1] == lid,
     tostring(disk.panes.left.tabIds[1]))
end

-- The record has to outlive the process that made it, because the reload is
-- exactly when the model is at its thinnest.
section("a window stranded before a reload is reclaimed after it")
do
  local p2, w2, cfg2, geo, st = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]

  -- Lose it from the model, then reload: nothing in memory remembers the window,
  -- so only what was written down can save it.
  w2.snapshotOmits = { [lid] = true }
  w2.setWindowSpace(lid, 7)
  w2.spaceOfScreen[hs.screen.allScreens()[1]] = 3
  p2.reconcile()
  p2.persistNow()
  ck("the id is gone from the model", not liveSide(p2, "left"))
  local disk = st.load()
  ck("but it was minted, and that is written down",
     disk.panes.left.minted and disk.panes.left.minted[1] == lid,
     disk.panes.left.minted and disk.panes.left.minted[1])

  -- A fresh module set, same world: hs.reload().
  local panel2 = dofile(R .. "panel.lua")
  panel2.setDeps({ finder = w2.finder, geometry = geo, store = st,
                   log = hs.logger.new() })
  panel2.setConfig(cfg2)
  panel2.loadState()
  w2.snapshotOmits = nil
  w2.setWindowSpace(lid, 3)
  panel2.reconcile()
  local before = #w2.windows
  panel2.show(); w2.drain()
  ck("the reloaded panel took the window back",
     panel2.panes().left.tabIds[1] == lid, panel2.panes().left.tabIds[1])
  ck("without opening anything new", #w2.windows == before, #w2.windows)
end

-- Requirement 4 is the reason this is a list of ids and not a search for windows
-- that look like panes.
section("a window the user opened is never reclaimed")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  local lrw = w2.windowOfId(lid)
  local shown = { x = lrw.frame.x, y = lrw.frame.y, w = lrw.frame.w, h = lrw.frame.h }

  -- The user's own window, opened at exactly the pane's place and never adopted.
  p2.hide(); w2.drain()
  local floater = w2.newWindow({ "/Applications" }, shown)
  local fid = floater.tabs[1].id

  -- And the left pane closes for real.
  w2.closeTabById(lid)
  p2.reconcile()
  ck("the left side is missing", not liveSide(p2, "left"))

  local before = #w2.windows
  p2.show(); w2.drain()
  ck("the floating window was not taken for the pane",
     paneOf(p2, "left").tabIds[1] ~= fid, paneOf(p2, "left").tabIds[1])
  ck("a real pane was made instead", #w2.windows == before + 1, #w2.windows)
  ck("and the floater stayed where the user left it",
     w2.windowOfId(fid).frame.x == shown.x and w2.windowOfId(fid).frame.y == shown.y)
end

-- Finder hands ids out per process.  Termination clears the record, but Finder
-- can also be restarted while Hammerspoon is not running, and then a fresh
-- window could wear a remembered number.
section("ids from an earlier Finder are not trusted")
do
  local p2, w2, cfg2, geo, st = boot()
  p2.show(); w2.drain()
  local lid = paneOf(p2, "left").tabIds[1]
  p2.persistNow()

  -- Finder restarts behind our back: same numbers handed out, different process,
  -- and no terminated event ever reached us.
  local panel2 = dofile(R .. "panel.lua")
  panel2.setDeps({ finder = w2.finder, geometry = geo, store = st,
                   log = hs.logger.new() })
  panel2.setConfig(cfg2)
  panel2.loadState()
  w2.windows = {}
  w2.finderPid = 9999
  -- A fresh process starts its numbering over, so the first window it makes can
  -- wear the number the old pane had.
  w2.nextId = lid - 5
  local floater = w2.newWindow({ "/Applications" })
  local fid = floater.tabs[1].id
  ck("the new window wears the old pane's number", fid == lid, fid .. "/" .. lid)

  panel2.reconcile()
  local before = #w2.windows
  panel2.show(); w2.drain()
  ck("it was not taken for the pane",
     panel2.panes().left.tabIds[1] ~= fid, panel2.panes().left.tabIds[1])
  ck("panes were made for both sides", #w2.windows == before + 2, #w2.windows)
  ck("the remembered path came back instead of the floater's",
     paneOf(panel2, "left").pathList[1] == HOME .. "/Downloads",
     tostring(paneOf(panel2, "left").pathList[1]))
  ck("and the floater was left where it was made",
     w2.windowOfId(fid).frame.x == 100 and w2.windowOfId(fid).frame.y == 100,
     w2.windowOfId(fid).frame.x .. "," .. w2.windowOfId(fid).frame.y)
end

-- ══ 12. a tab the user dragged between windows ══════════════════════════════
-- The model has no door for this: the id does not change, the real window that
-- owns it does.  Reported from the machine as "the right window vanished, and it
-- turned out to be sitting on top of the left one".

local function idOfPath(panel, side, path)
  local pane = panel.panes()[side]
  for i, p in ipairs(pane.pathList) do
    if p == path then return pane.tabIds[i] end
  end
  return nil
end
local function ownerOf(world, id)
  return world.windowOfId(id)
end
local function addTabs(panel, world, rw, paths)
  for _, p in ipairs(paths) do
    world.addTab(rw, p)
    panel.onWindowCreated(world.mkwin(rw, rw.active))
    world.drain()
  end
end

section("a tab dragged into the other pane's window changes sides")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  local R = ownerOf(w2, paneOf(p2, "right").tabIds[1])
  addTabs(p2, w2, L, { "/Applications", "/usr" })
  ck("left holds three tabs", #paneOf(p2, "left").tabIds == 3, #paneOf(p2, "left").tabIds)

  local moved = idOfPath(p2, "left", "/Applications")
  w2.moveTabToWindow(moved, R)
  local before = #w2.windows
  ck("neither view announces the drag",
     #w2.finder.snapshot() == 4 and #w2.finder.axWindows() == 2)

  p2.reconcile()
  ck("the tab is filed under right now", p2.sideOfTab(moved) == "right",
     tostring(p2.sideOfTab(moved)))
  ck("left kept the other two", #paneOf(p2, "left").tabIds == 2, #paneOf(p2, "left").tabIds)
  ck("right has its own tab and the one that arrived",
     #paneOf(p2, "right").tabIds == 2, #paneOf(p2, "right").tabIds)
  ck("right's active tab is the one that arrived",
     paneOf(p2, "right").activeId == moved, tostring(paneOf(p2, "right").activeId))
  ck("its path came with it",
     paneOf(p2, "right").pathList[2] == "/Applications",
     tostring(paneOf(p2, "right").pathList[2]))
  ck("nothing was created or closed", #w2.windows == before, #w2.windows)
  ck("each side still resolves to its own window",
     ownerOf(w2, paneOf(p2, "left").activeId) == L
     and ownerOf(w2, paneOf(p2, "right").activeId) == R)
end

section("a pane spread over two windows gets one window per side back")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  local R = ownerOf(w2, paneOf(p2, "right").tabIds[1])
  addTabs(p2, w2, L, { "/Applications", "/usr", "/private/tmp", "/Library" })
  ck("left holds five tabs", #paneOf(p2, "left").tabIds == 5, #paneOf(p2, "left").tabIds)
  local lf0 = frameOf(p2, "left")

  -- The drag that produced the defect: two of the left pane's tabs into the right
  -- pane's window, the last of them left active there.  Both windows now hold ids
  -- filed under "left", which is the state in which paneWindow("left") answered
  -- with the *right* pane's window and every press moved that one into the left
  -- slot.
  -- Order matters, and this is the order that bit: the tab left active in the
  -- right window comes *earlier* in the left pane's own list than the tab its own
  -- window is showing, so "the first of my ids Accessibility can resolve" answers
  -- with the right pane's window.
  for _, path in ipairs({ "/Library", "/usr" }) do
    w2.moveTabToWindow(idOfPath(p2, "left", path), R)
  end
  local before = #w2.windows
  p2.reconcile()

  ck("left is still the window it started in",
     ownerOf(w2, paneOf(p2, "left").activeId) == L)
  ck("right is still the window it started in",
     ownerOf(w2, paneOf(p2, "right").activeId) == R)
  ck("left owns what its window holds", #paneOf(p2, "left").tabIds == 3,
     #paneOf(p2, "left").tabIds)
  ck("right owns what its window holds", #paneOf(p2, "right").tabIds == 3,
     #paneOf(p2, "right").tabIds)
  local all = {}
  for _, side in ipairs({ "left", "right" }) do
    for _, p in ipairs(paneOf(p2, side).pathList) do all[p] = (all[p] or 0) + 1 end
  end
  ck("every path is still in the model exactly once",
     all["/usr"] == 1 and all["/Library"] == 1 and all["/Applications"] == 1
     and all["/private/tmp"] == 1 and all[HOME] == 1 and all[HOME .. "/Downloads"] == 1)
  ck("in tab-bar order on the side that received them",
     table.concat(paneOf(p2, "right").pathList, "|") == HOME .. "|/Library|/usr",
     table.concat(paneOf(p2, "right").pathList, "|"))
  ck("nothing was created or closed", #w2.windows == before, #w2.windows)

  -- And the layout follows: one window per slot, the left one right where it was.
  p2.hide(); w2.drain()
  p2.show(); w2.drain()
  local lf, rf = frameOf(p2, "left"), frameOf(p2, "right")
  ck("the left window is back in the left slot",
     lf ~= nil and lf.x == lf0.x and lf.y == lf0.y and lf.w == lf0.w,
     lf and (lf.x .. "," .. lf.y) or "no window")
  ck("the right window is in the right slot, not on top of the left one",
     lf ~= nil and rf ~= nil and rf.x == lf.x + lf.w,
     rf and rf.x or "no window")
  ck("and they are still two different windows",
     ownerOf(w2, paneOf(p2, "left").activeId) ~= ownerOf(w2, paneOf(p2, "right").activeId))
end

section("a tab dragged out into a window of its own leaves the panel")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  addTabs(p2, w2, L, { "/Applications", "/usr" })
  local gone = idOfPath(p2, "left", "/usr")
  local nw = w2.detachTab(gone)
  local before = #w2.windows
  p2.reconcile()

  ck("the tab is not the panel's any more", p2.sideOfTab(gone) == nil,
     tostring(p2.sideOfTab(gone)))
  ck("left kept the two that stayed", #paneOf(p2, "left").tabIds == 2,
     #paneOf(p2, "left").tabIds)
  ck("right was not touched by any of it", #paneOf(p2, "right").tabIds == 1,
     #paneOf(p2, "right").tabIds)
  ck("the side did not take the new window instead",
     ownerOf(w2, paneOf(p2, "left").activeId) == L)
  ck("nothing was created or closed", #w2.windows == before, #w2.windows)

  p2.hide(); w2.drain()
  ck("and the window the tab was dropped into stays where the user dropped it",
     nw.frame.x == 140 and nw.frame.y == 140, nw.frame.x .. "," .. nw.frame.y)
end

section("a drag that cannot be read leaves the model alone")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  local R = ownerOf(w2, paneOf(p2, "right").tabIds[1])
  addTabs(p2, w2, L, { "/private/tmp/bin" })
  addTabs(p2, w2, R, { "/usr/bin" })
  local moved = idOfPath(p2, "left", "/private/tmp/bin")
  w2.moveTabToWindow(moved, R)
  -- The user switched back to the tab that was active before, so neither "bin"
  -- is the selected entry that would pin it: the tab bar reads
  -- [wangyuan | bin | bin] and nothing says which bin is which.
  R.active = 1
  p2.reconcile()
  ck("the tab is still filed where it was", p2.sideOfTab(moved) == "left",
     tostring(p2.sideOfTab(moved)))
  ck("both sides keep the tabs they had",
     #paneOf(p2, "left").tabIds == 2 and #paneOf(p2, "right").tabIds == 2,
     #paneOf(p2, "left").tabIds .. "/" .. #paneOf(p2, "right").tabIds)
  ck("and no path was lost",
     table.concat(paneOf(p2, "left").pathList, "|"):find("/private/tmp/bin", 1, true) ~= nil,
     table.concat(paneOf(p2, "left").pathList, "|"))
end

section("a minimized pane is not regrouped")
do
  local p2, w2 = boot({ hideMode = "minimize" })
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  addTabs(p2, w2, L, { "/Applications" })
  p2.hide(); w2.drain()
  ck("both sides are collapsed", paneOf(p2, "left").collapsed
     and paneOf(p2, "right").collapsed)
  -- Minimized, Finder puts every tab of the window in the AX tree, so its handles
  -- cannot be told from separate windows -- exactly the reading that would look
  -- like a pane spread over two of them.
  p2.reconcile()
  ck("left still owns both its tabs", #paneOf(p2, "left").tabIds == 2,
     #paneOf(p2, "left").tabIds)
  ck("right still owns its own", #paneOf(p2, "right").tabIds == 1,
     #paneOf(p2, "right").tabIds)
  p2.show(); w2.drain()
  ck("and both come back", #paneOf(p2, "left").tabIds == 2
     and #paneOf(p2, "right").tabIds == 1)
end

local function mintedHas(panel, side, id)
  for _, m in ipairs(paneOf(panel, side).minted) do
    if m == id then return true end
  end
  return false
end

section("the tab a side was resolving through is the one that moved")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  local R = ownerOf(w2, paneOf(p2, "right").tabIds[1])
  addTabs(p2, w2, L, { "/Applications" })
  -- The user switched back to the first tab, so that is the one the model calls
  -- active -- and it is the one they then drag across.  What makes this the
  -- narrow case: the window it lands in ends up holding exactly as many tabs as
  -- the left side owns, so nothing but the folder names says anything is wrong.
  L.active = 1
  p2.reconcile()
  local moved = idOfPath(p2, "left", HOME .. "/Downloads")
  ck("the model was resolving left through that tab",
     paneOf(p2, "left").activeId == moved, tostring(paneOf(p2, "left").activeId))
  w2.moveTabToWindow(moved, R)
  local before = #w2.windows
  ck("and the counts alone say nothing",
     #w2.finder.tabTitles(w2.mkwin(R, R.active)) == #paneOf(p2, "left").tabIds)

  p2.reconcile()
  ck("the tab is filed under right now", p2.sideOfTab(moved) == "right",
     tostring(p2.sideOfTab(moved)))
  ck("left is the window it never left",
     ownerOf(w2, paneOf(p2, "left").activeId) == L)
  ck("left kept the one tab that stayed", #paneOf(p2, "left").tabIds == 1,
     #paneOf(p2, "left").tabIds)
  ck("right holds both of its own now", #paneOf(p2, "right").tabIds == 2,
     #paneOf(p2, "right").tabIds)
  ck("provenance went with the tab", mintedHas(p2, "right", moved))
  ck("and did not stay behind", not mintedHas(p2, "left", moved))
  ck("nothing was created or closed", #w2.windows == before, #w2.windows)
end

section("a tab dropped into a window the user opened leaves the panel")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  addTabs(p2, w2, L, { "/Applications" })
  local F = w2.newWindow({ "/etc" }, { x = 300, y = 200, w = 800, h = 440 })
  local gone = idOfPath(p2, "left", "/Applications")
  w2.moveTabToWindow(gone, F)
  -- ... and the user carried on in the tab that window came with, so nothing of
  -- ours is active in it: it is a window we may read but never take.
  F.active = 1
  local before = #w2.windows
  p2.reconcile()

  ck("the tab is not the panel's any more", p2.sideOfTab(gone) == nil,
     tostring(p2.sideOfTab(gone)))
  ck("left kept the one that stayed", #paneOf(p2, "left").tabIds == 1,
     #paneOf(p2, "left").tabIds)
  ck("left is still its own window", ownerOf(w2, paneOf(p2, "left").activeId) == L)
  ck("the side was not handed the user's window instead",
     ownerOf(w2, paneOf(p2, "left").activeId) ~= F
     and ownerOf(w2, paneOf(p2, "right").activeId) ~= F)
  ck("nothing was created or closed", #w2.windows == before, #w2.windows)

  p2.hide(); w2.drain()
  ck("and the user's window is where the user left it",
     F.frame.x == 300 and F.frame.y == 200 and F.frame.w == 800,
     F.frame.x .. "," .. F.frame.y .. " " .. F.frame.w)
end

section("a side whose own window is gone is not handed one of someone else's")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  addTabs(p2, w2, L, { "/Applications" })
  w2.closeTabById(paneOf(p2, "right").tabIds[1])   -- the whole right window
  p2.reconcile()
  ck("right is gone", #paneOf(p2, "right").tabIds == 0, #paneOf(p2, "right").tabIds)
  -- A tab dragged out onto the desktop is now the only other Finder window
  -- there is.  Handing it to the side that lost its own would be DropFinder
  -- adopting a window the user made, by the back door.
  local gone = idOfPath(p2, "left", "/Applications")
  local nw = w2.detachTab(gone)
  local before = #w2.windows
  p2.reconcile()

  ck("the dragged-out tab left the panel", p2.sideOfTab(gone) == nil,
     tostring(p2.sideOfTab(gone)))
  ck("right did not take that window", #paneOf(p2, "right").tabIds == 0,
     #paneOf(p2, "right").tabIds)
  ck("left is still its own window", ownerOf(w2, paneOf(p2, "left").activeId) == L)
  ck("nothing was created or closed here", #w2.windows == before, #w2.windows)

  p2.show(); w2.drain()
  ck("the next press rebuilds right instead", #w2.windows == before + 1, #w2.windows)
  ck("at the path it remembered", paneOf(p2, "right").pathList[1] == HOME,
     tostring(paneOf(p2, "right").pathList[1]))
  ck("and the dragged-out window was never moved",
     nw.frame.x == 140 and nw.frame.y == 140, nw.frame.x .. "," .. nw.frame.y)
end

section("each side keeps the window most of its tabs are in")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  local R = ownerOf(w2, paneOf(p2, "right").tabIds[1])
  addTabs(p2, w2, L, { "/Applications", "/usr" })
  addTabs(p2, w2, R, { "/Library" })
  -- Tabs went both ways, so both windows hold tabs of both sides and both
  -- readings are self-consistent.  Only the count decides: two of left's three
  -- tabs are still in L, so L is left.
  w2.moveTabToWindow(idOfPath(p2, "left", "/usr"), R)
  w2.moveTabToWindow(idOfPath(p2, "right", "/Library"), L)
  local before = #w2.windows
  p2.reconcile()

  ck("left is the window that kept most of it",
     ownerOf(w2, paneOf(p2, "left").activeId) == L)
  ck("right is the other one", ownerOf(w2, paneOf(p2, "right").activeId) == R)
  ck("left owns the three tabs in it", #paneOf(p2, "left").tabIds == 3,
     #paneOf(p2, "left").tabIds)
  ck("in tab-bar order",
     table.concat(paneOf(p2, "left").pathList, "|")
       == HOME .. "/Downloads|/Applications|/Library",
     table.concat(paneOf(p2, "left").pathList, "|"))
  ck("right owns the two in it",
     table.concat(paneOf(p2, "right").pathList, "|") == HOME .. "|/usr",
     table.concat(paneOf(p2, "right").pathList, "|"))
  ck("nothing was created or closed", #w2.windows == before, #w2.windows)
end

section("the side whose every tab moved away is rebuilt, not left pointing at them")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  local moved = paneOf(p2, "right").tabIds[1]
  local before = #w2.windows
  w2.moveTabToWindow(moved, L)                     -- the right pane's only tab
  p2.reconcile()

  ck("the tab is left's now", p2.sideOfTab(moved) == "left",
     tostring(p2.sideOfTab(moved)))
  ck("left holds both", #paneOf(p2, "left").tabIds == 2, #paneOf(p2, "left").tabIds)
  ck("right owns no ids at all", #paneOf(p2, "right").tabIds == 0,
     #paneOf(p2, "right").tabIds)
  ck("and nothing it could resolve", paneOf(p2, "right").activeId == nil,
     tostring(paneOf(p2, "right").activeId))
  ck("but it kept the recipe", paneOf(p2, "right").pathList[1] == HOME,
     tostring(paneOf(p2, "right").pathList[1]))
  ck("one window is left", #w2.windows == before - 1, #w2.windows)

  p2.show(); w2.drain()
  ck("the next press rebuilds it", #paneOf(p2, "right").tabIds == 1,
     #paneOf(p2, "right").tabIds)
  ck("as a window of its own",
     ownerOf(w2, paneOf(p2, "right").activeId) ~= L
     and ownerOf(w2, paneOf(p2, "right").activeId) ~= nil)
  ck("and left still has the tab that came over", #paneOf(p2, "left").tabIds == 2,
     #paneOf(p2, "left").tabIds)
end

section("two sides that swapped windows while away swap their park rects too")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  local R = ownerOf(w2, paneOf(p2, "right").tabIds[1])
  addTabs(p2, w2, L, { "/Applications", "/usr" })
  addTabs(p2, w2, R, { "/Library" })
  p2.hide(); w2.drain()
  ck("both sides are parked", paneOf(p2, "left").parked ~= nil
     and paneOf(p2, "right").parked ~= nil)


  -- Enough tabs went across that each side's best window is now the other's.
  -- Both windows hold the same number of tabs as before, so only the names say so.
  w2.moveTabToWindow(idOfPath(p2, "left", "/Applications"), R)
  w2.moveTabToWindow(idOfPath(p2, "left", "/usr"), R)
  w2.moveTabToWindow(idOfPath(p2, "right", "/Library"), L)
  local before = #w2.windows
  p2.reconcile()

  ck("left is the window that has most of it now",
     ownerOf(w2, paneOf(p2, "left").activeId) == R)
  ck("right is the other one", ownerOf(w2, paneOf(p2, "right").activeId) == L)
  -- Both sides park in the same corner, so the rects themselves cannot tell the
  -- swap: what has to hold is that each side's park rect is the rect of the
  -- window it owns now, so a display change re-parks the right window.
  for _, side in ipairs({ "left", "right" }) do
    local pane = paneOf(p2, side)
    local rw = ownerOf(w2, pane.activeId)
    ck(side .. "'s park rect is the rect of the window it took",
       pane.parked ~= nil and pane.parked.x == rw.frame.x
       and pane.parked.y == rw.frame.y and pane.parked.w == rw.frame.w,
       pane.parked and (pane.parked.x .. "," .. pane.parked.y) or "nil")
  end
  ck("the panel is still away", p2.state() == "hidden", p2.state())
  ck("nothing was created or closed", #w2.windows == before, #w2.windows)

  p2.show(); w2.drain()
  local lf, rf = frameOf(p2, "left"), frameOf(p2, "right")
  ck("and it comes back one window per slot",
     lf ~= nil and rf ~= nil and rf.x == lf.x + lf.w,
     (lf and lf.x or "nil") .. " / " .. (rf and rf.x or "nil"))
end

-- The other half of that recompute.  `parked` means "we put this away and have
-- not shown it since", and a display change acts on it: a stale one on a panel
-- that is up would park a panel the user is working in.
section("a swap while the panel is up is not mistaken for a park")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  local R = ownerOf(w2, paneOf(p2, "right").tabIds[1])
  addTabs(p2, w2, L, { "/Applications", "/usr" })
  addTabs(p2, w2, R, { "/Library" })
  w2.moveTabToWindow(idOfPath(p2, "left", "/Applications"), R)
  w2.moveTabToWindow(idOfPath(p2, "left", "/usr"), R)
  w2.moveTabToWindow(idOfPath(p2, "right", "/Library"), L)
  p2.reconcile()
  ck("the sides swapped windows", ownerOf(w2, paneOf(p2, "left").activeId) == R)
  ck("neither is recorded as put away", paneOf(p2, "left").parked == nil
     and paneOf(p2, "right").parked == nil)

  p2.onScreensChanged(); w2.drain()
  ck("so a display change lays the panel out instead of parking it",
     p2.state() ~= "hidden", p2.state())
  local lf, rf = frameOf(p2, "left"), frameOf(p2, "right")
  ck("both panes on the grid", lf ~= nil and rf ~= nil and rf.x == lf.x + lf.w,
     (lf and lf.x or "nil") .. " / " .. (rf and rf.x or "nil"))
end

section("Accessibility going blind changes nothing")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  addTabs(p2, w2, L, { "/Applications" })
  local paths = table.concat(paneOf(p2, "left").pathList, "|")
  -- A locked screen, another Space, a Finder that has just come back: the AX
  -- tree answers with nothing at all, which is not the same as "your windows
  -- hold nothing".
  w2.axBlindRounds = 3
  p2.reconcile()
  ck("left kept every tab", table.concat(paneOf(p2, "left").pathList, "|") == paths,
     table.concat(paneOf(p2, "left").pathList, "|"))
  ck("right too", #paneOf(p2, "right").tabIds == 1, #paneOf(p2, "right").tabIds)
  ck("and both are still the windows they were",
     paneOf(p2, "left").tabIds[1] ~= nil and paneOf(p2, "right").tabIds[1] ~= nil)
end

-- The regroup above gives back a tab of ours that turns out to be in a window we
-- do not manage -- but only when it can read which window holds what.  Two of our
-- tabs with the same folder name and it declines, and then a window taken in
-- error stays taken: the pane resolves to it and the next press parks a window
-- the user opened.  So the two signals that decide adoption have to be right on
-- their own, with nothing to fall back on.  Both sections below set up that
-- ambiguity first: a "bin" in each pane, neither of them its window's selected
-- entry, so nothing pins which is which.
local function twoTabsCalledBin(p2, w2)
  local L = ownerOf(w2, paneOf(p2, "left").tabIds[1])
  local R = ownerOf(w2, paneOf(p2, "right").tabIds[1])
  addTabs(p2, w2, L, { "/private/tmp/bin" })
  addTabs(p2, w2, R, { "/usr/bin" })
  L.active, R.active = 1, 1
  p2.reconcile()
  return L, R
end

section("a window the user opened is left alone with no regroup to fall back on")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local L = twoTabsCalledBin(p2, w2)
  -- And the pane's own tab bar is one ahead of the model, the way it is when
  -- Finder appends a tab without selecting it.  That is the growth this signal
  -- looks for; a window of the user's arriving at the same moment must not be
  -- read as it, and the id being in the AX tree at all is the difference.
  w2.addBackgroundTab(L, "/etc/defaults")
  local pf = paneOf(p2, "left").frame
  local fl = w2.newWindow({ "/etc" }, { x = pf.x, y = pf.y, w = pf.w, h = pf.h })
  local flx, fly = fl.frame.x, fl.frame.y

  p2.onWindowCreated(w2.mkwin(fl, 1)); w2.drain()
  ck("the window the user opened is not the panel's",
     p2.sideOfTab(fl.tabs[1].id) == nil, tostring(p2.sideOfTab(fl.tabs[1].id)))
  ck("left still owns the two tabs it made", #paneOf(p2, "left").tabIds == 2,
     #paneOf(p2, "left").tabIds)
  p2.hide(); w2.drain()
  ck("and the panel went away without it",
     fl.frame.x == flx and fl.frame.y == fly, fl.frame.x .. "," .. fl.frame.y)
end

section("a tab appended to the user's window is left alone the same way")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  twoTabsCalledBin(p2, w2)
  local pf = paneOf(p2, "left").frame
  local fl = w2.newWindow({ "/etc" }, { x = pf.x, y = pf.y, w = pf.w, h = pf.h })
  -- Nothing about this one is in the AX tree, so only the count can speak for
  -- it -- and the pane's tab bar is exactly as long as the model thinks it is,
  -- which says the tab did not go into the pane.
  local bg = w2.addBackgroundTab(fl, "/private/tmp/usr")
  local flx, fly = fl.frame.x, fl.frame.y

  p2.onWindowCreated(w2.mkwin(fl, #fl.tabs)); w2.drain()
  ck("the tab in the user's window is not the panel's", p2.sideOfTab(bg) == nil,
     tostring(p2.sideOfTab(bg)))
  ck("left still owns the two tabs it made", #paneOf(p2, "left").tabIds == 2,
     #paneOf(p2, "left").tabIds)
  p2.hide(); w2.drain()
  ck("and the panel went away without it",
     fl.frame.x == flx and fl.frame.y == fly, fl.frame.x .. "," .. fl.frame.y)
end

-- Reported from the screen: with a floating Finder window up, the hotkey
-- brought only the right pane forward.  The left pane's window was showing a
-- tab the model had let go of -- a reconcile right after a Finder relaunch had
-- believed a snapshot that left four freshly restored tabs out -- so the side
-- resolved to no window, and raise() had nothing to raise.
section("a tab of ours a reconcile let go is taken back when Finder lists it again")
do
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  local b = w2.addTab(lw, HOME .. "/Pictures")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.addTab(lw, "/private/tmp")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  ck("the left pane owns three tabs", #paneOf(p2, "left").tabIds == 3,
     #paneOf(p2, "left").tabIds)
  w2.advance(10)                          -- past the grace a fresh tab gets

  w2.snapshotOmits = { [b] = true }       -- the post-relaunch lie, about one tab
  p2.reconcile()
  ck("the reconcile drops it", p2.sideOfTab(b) == nil, tostring(p2.sideOfTab(b)))
  w2.snapshotOmits = nil

  local bi
  for i, t in ipairs(lw.tabs) do if t.id == b then bi = i end end
  w2.finder.selectTab(w2.mkwin(lw, lw.active), bi)   -- the user clicks it
  p2.reconcile()
  ck("the tab is back in the left pane", p2.sideOfTab(b) == "left",
     tostring(p2.sideOfTab(b)))
  ck("in tab-bar order", paneOf(p2, "left").tabIds[2] == b,
     table.concat(paneOf(p2, "left").tabIds, ","))
  ck("at the path Finder reports", paneOf(p2, "left").pathList[2] == HOME .. "/Pictures",
     paneOf(p2, "left").pathList[2])
  local pw = p2.paneWindow("left")
  ck("and the side resolves to its window again", pw ~= nil and pw:id() == b,
     pw and pw:id())

  -- The symptom itself: a floating window the user is working in, then the
  -- hotkey.  Both panes have to come up over it.
  local rw = w2.windowOfId(paneOf(p2, "right").tabIds[1])
  local fl = w2.newWindow({ HOME .. "/Desktop" }, { x = 815, y = 175, w = 811, h = 399 })
  w2.mkwin(fl, 1):focus()
  p2.toggle(); w2.drain()
  ck("the left pane is over the floating window", w2.zIndex(lw) < w2.zIndex(fl),
     w2.zIndex(lw) .. " vs " .. w2.zIndex(fl))
  ck("and so is the right one", w2.zIndex(rw) < w2.zIndex(fl),
     w2.zIndex(rw) .. " vs " .. w2.zIndex(fl))

  -- Provenance is the whole licence: a tab we never made is not taken in.
  local foreign = fl.tabs[1].id
  p2.reconcile()
  ck("the floating window's tab stays floating", p2.sideOfTab(foreign) == nil)
end

section("a .localized folder is matched by the name the tab bar shows")
do
  -- Measured: "Virtual Machines.localized" is titled "Virtual Machines", and
  -- matching on the basename left that tab accounted for by no tab bar.
  local loc = "/tmp/dropfinder-spec/Virtual Machines.localized"
  os.execute("mkdir -p '" .. loc .. "'")
  local p2, w2 = boot()
  p2.show(); w2.drain()
  local lw = w2.windowOfId(paneOf(p2, "left").tabIds[1])
  local id = w2.addTab(lw, loc)
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  ck("the tab is adopted", p2.sideOfTab(id) == "left")
  local tmp = w2.addTab(lw, "/private/tmp")
  p2.onWindowCreated(w2.mkwin(lw, lw.active)); w2.drain()
  w2.reorderTabs(lw, { 2, 3, 1 })          -- the user drags it to the front
  p2.reconcile()
  local ids = paneOf(p2, "left").tabIds
  ck("the reorder is followed", ids[1] == id and ids[2] == tmp,
     table.concat(ids, ","))
  p2.persistNow()
  ck("and the active tab is read back by its shown name",
     paneOf(p2, "left").activePath == "/private/tmp", paneOf(p2, "left").activePath)
  os.execute("rm -rf /tmp/dropfinder-spec")
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
