-- Offline test runner for DropFinder's pure modules.
-- Locate ourselves so the suite runs from anywhere; DF_LIB lets the mutation
-- harness point the same tests at a patched copy of lib/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local R = os.getenv("DF_LIB") or (HERE .. "/../lib/")
local S = dofile(HERE .. "/stub.lua")

local pass, fail = 0, 0
local function ck(label, cond, extra)
  if cond then
    pass = pass + 1
  else
    fail = fail + 1
    print("  FAIL " .. label .. (extra ~= nil and ("  -> " .. tostring(extra)) or ""))
  end
end
local function section(n) print("== " .. n .. " ==") end

local function load(name, screens, opts)
  hs = select(1, S.install(screens or S.REAL_SCREENS, opts))
  return dofile(R .. name .. ".lua")
end

-- ── config ────────────────────────────────────────────────────────────────
section("config")
local configLib = load("config")
local HOME = os.getenv("HOME")

local c = configLib.loadConfig(nil)
ck("defaults: heightRatio 0.25", c.heightRatio == 0.25, c.heightRatio)
ck("defaults: hideMode park", c.hideMode == "park", c.hideMode)
ck("defaults: parkCorner bottom-right", c.parkCorner == "bottom-right")
ck("defaults: parkMaxVisible 5000", c.parkMaxVisible == 5000)
ck("defaults: toggle hotkey ctrl+alt f",
   c.hotkeys.toggle[1].key == "f" and #c.hotkeys.toggle[1].mods == 2)
ck("defaults: one toggle hotkey", #c.hotkeys.toggle == 1, #c.hotkeys.toggle)
ck("defaults: adopt hotkey present", c.hotkeys.adopt[1] ~= nil)
ck("~ expands to $HOME", c.defaultPaths.right == HOME, c.defaultPaths.right)
ck("~/Downloads resolves", c.defaultPaths.left == HOME .. "/Downloads", c.defaultPaths.left)

local c2 = configLib.loadConfig({ restoreFocusOnHide = false, persist = false, heightRatio = 0.4 })
ck("explicit false survives: restoreFocusOnHide", c2.restoreFocusOnHide == false)
ck("explicit false survives: persist", c2.persist == false)
ck("unspecified boolean keeps its default", c2.restoreTabs == true)
ck("heightRatio override", c2.heightRatio == 0.4)

local c3 = configLib.loadConfig({ hotkeys = { adopt = false } })
ck("hotkeys.adopt = false opts out", #c3.hotkeys.adopt == 0)
ck("hotkeys.toggle still defaulted", #c3.hotkeys.toggle == 1)

-- One action, several keys: the point is that nothing is dropped and the order
-- is kept, so start() can bind them all and stop() can find them all again.
local c4 = configLib.loadConfig({ hotkeys = { toggle = {
  { mods = { "alt" }, key = "`" },
  { mods = { "ctrl", "alt" }, key = "f" },
} } })
ck("a list of hotkeys is kept whole", #c4.hotkeys.toggle == 2, #c4.hotkeys.toggle)
-- Indexed defensively: a mutant that drops an entry should fail this check, not
-- crash the suite before it can print its tally.
ck("in the order given", (c4.hotkeys.toggle[1] or {}).key == "`"
   and (c4.hotkeys.toggle[2] or {}).key == "f")
ck("the other action still defaults", #c4.hotkeys.adopt == 1)
local c5 = configLib.loadConfig({ hotkeys = { toggle = { mods = { "alt" }, key = "`" } } })
ck("a single hotkey still works, as a list of one",
   #c5.hotkeys.toggle == 1 and c5.hotkeys.toggle[1].key == "`")
-- loadConfig hands back tables of its own: handing out the default spec itself
-- would let anything that edited one config's hotkeys change the next one loaded.
-- Compared between two configs that both took the default, since an opted-out
-- action has no spec to compare.
ck("the default spec is copied, not handed out",
   c.hotkeys.adopt[1] ~= c2.hotkeys.adopt[1])

ck("nonexistent defaultPath degrades to a real directory",
   configLib.loadConfig({ defaultPaths = { left = "/nope/nope" } }).defaultPaths.left == HOME)
ck("a plain file is rejected as a defaultPath",
   configLib.loadConfig({ defaultPaths = { left = "/etc/hosts" } }).defaultPaths.left == HOME)
ck("resolveDir on a directory", configLib.resolveDir("/tmp") ~= nil)
ck("resolveDir on a file", configLib.resolveDir("/etc/hosts") == nil)
ck("resolveDir on nothing", configLib.resolveDir(nil) == nil)

for _, bad in ipairs({
  { heightRatio = 0 }, { heightRatio = 1.5 }, { heightRatio = "big" },
  { hideMode = "offscreen" }, { parkCorner = "top-left" }, { screenPolicy = "cursor" },
  { crossSpaceFallback = "nope" }, { adoptTarget = "middle" }, { bottomGap = -5 },
  { restoreTabs = "yes" }, { hotkeys = { toggle = { key = "f" } } },
  { hotkeys = "ctrl-f" }, { defaultPaths = "somewhere" }, { settleDelay = -1 },
  -- An empty list reads as "bound to nothing", which is what `false` says out
  -- loud; taken quietly it looks like a hotkey that does not work.
  { hotkeys = { toggle = {} } },
  -- One bad entry in a list must not pass because its neighbours are fine.
  { hotkeys = { adopt = { { mods = { "alt" }, key = "`" }, { mods = { "alt" } } } } },
}) do
  local k = next(bad)
  ck("rejects " .. k .. " = " .. tostring(bad[k]), not pcall(configLib.loadConfig, bad))
end

-- ── geometry ──────────────────────────────────────────────────────────────
section("geometry")
local geometry = load("geometry")
local cg = configLib.loadConfig({})

local main = { frame = function() return { x = 0, y = 30, w = 2560, h = 1410 } end }
local pf = geometry.panelFrame(main, cg, nil)
ck("panelFrame hugs the bottom of the usable area", pf.y + pf.h == 1440, pf.y .. "+" .. pf.h)
ck("panelFrame applies the ratio", pf.h == math.floor(1410 * 0.25), pf.h)
ck("panelFrame spans the screen width", pf.x == 0 and pf.w == 2560)

local pf2 = geometry.panelFrame(main, cg, 400)
ck("panelFrame floors at the measured minimum", pf2.h == 400, pf2.h)
ck("panelFrame still hugs the bottom when floored", pf2.y + pf2.h == 1440)
ck("0.25 of 1410 clears the 344 floor", geometry.panelFrame(main, cg, nil).h > 344,
   geometry.panelFrame(main, cg, nil).h)

local small = { frame = function() return { x = 0, y = 25, w = 1920, h = 1005 } end }
ck("on a 1080p screen the floor takes over",
   geometry.panelFrame(small, cg, 344).h == 344, geometry.panelFrame(small, cg, nil).h)

ck("panelFrame cannot exceed the screen",
   geometry.panelFrame(main, configLib.loadConfig({ heightRatio = 1 }), nil).h == 1410)
ck("an absurd minimum is capped at the screen height",
   geometry.panelFrame(main, cg, 99999).h == 1410)
local gapped = geometry.panelFrame(main, configLib.loadConfig({ bottomGap = 20 }), 344)
ck("bottomGap lifts the panel", gapped.y + gapped.h == 1420, gapped.y + gapped.h)

local both = geometry.paneFrames(main, cg, 344, { left = true, right = true })
ck("two panes leave no seam", both.left.x + both.left.w == both.right.x)
ck("two panes cover the whole panel",
   both.left.x == 0 and both.right.x + both.right.w == 2560)
local panelH = geometry.panelFrame(main, cg, 344).h
ck("two panes match the panel height",
   both.left.h == panelH and both.right.h == panelH, both.left.h .. "/" .. panelH)
ck("two panes match in y", both.left.y == both.right.y)

local odd = { frame = function() return { x = 0, y = 0, w = 2561, h = 1410 } end }
local oddF = geometry.paneFrames(odd, cg, 344, { left = true, right = true })
ck("an odd panel width still leaves no seam and no overhang",
   oddF.left.x + oddF.left.w == oddF.right.x
   and oddF.right.x + oddF.right.w == 2561,
   oddF.left.w .. " / " .. oddF.right.w)

ck("a lone left pane takes the full panel width",
   geometry.paneFrames(main, cg, 344, { left = true }).left.w == 2560)
ck("a lone right pane takes the full panel width",
   geometry.paneFrames(main, cg, 344, { right = true }).right.w == 2560)
ck("a lone left pane starts at the panel origin",
   geometry.paneFrames(main, cg, 344, { left = true }).left.x == 0)
ck("no live sides yields nothing", next(geometry.paneFrames(main, cg, 344, {})) == nil)

local g10 = geometry.paneFrames(main, configLib.loadConfig({ paneGap = 10 }), 344,
                                { left = true, right = true })
ck("paneGap is exact", g10.right.x - (g10.left.x + g10.left.w) == 10)
ck("paneGap still covers the panel",
   g10.left.x == 0 and g10.right.x + g10.right.w == 2560)

local u = geometry.unionFrame()
ck("unionFrame spans the real layout",
   u.x == -2048 and u.y == 0 and u.x + u.w == 4480 and u.y + u.h == 1440,
   string.format("%d,%d %dx%d", u.x, u.y, u.w, u.h))

ck("isOnScreen: a whole screen", geometry.isOnScreen({ x = 0, y = 0, w = 2560, h = 1440 }))
ck("isOnScreen: far away", not geometry.isOnScreen({ x = 99999, y = 99999, w = 400, h = 300 }))
ck("isOnScreen: nil", not geometry.isOnScreen(nil))
ck("isOnScreen: zero size", not geometry.isOnScreen({ x = 0, y = 0, w = 0, h = 0 }))
local sliver = { x = 4480 - 40, y = 1341 - 52, w = 1280, h = 353 }
ck("isOnScreen: a parked 40x52 sliver counts as hidden", not geometry.isOnScreen(sliver))
ck("that sliver's visible area is at most 40*52",
   geometry.visibleArea(sliver) <= 40 * 52, geometry.visibleArea(sliver))
ck("that sliver is under the default parkMaxVisible",
   geometry.visibleArea(sliver) < cg.parkMaxVisible, geometry.visibleArea(sliver))
ck("isOnScreen: half on screen", geometry.isOnScreen({ x = 2560 - 640, y = 1000, w = 1280, h = 353 }))
ck("isOnScreen: spanning the gap between two displays",
   geometry.isOnScreen({ x = 2400, y = 400, w = 400, h = 300 }))

ck("framesEqual inside tolerance",
   geometry.framesEqual({x=0,y=0,w=100,h=100}, {x=3,y=0,w=100,h=100}, 4))
ck("framesEqual outside tolerance",
   not geometry.framesEqual({x=0,y=0,w=100,h=100}, {x=9,y=0,w=100,h=100}, 4))
ck("framesEqual notices a size change",
   not geometry.framesEqual({x=0,y=0,w=100,h=100}, {x=0,y=0,w=100,h=200}, 4))
ck("framesEqual with nil", not geometry.framesEqual(nil, {x=0,y=0,w=1,h=1}, 4))

local sz = { w = 1280, h = 353 }
local brCfg = configLib.loadConfig({ parkCorner = "bottom-right" })
local blCfg = configLib.loadConfig({ parkCorner = "bottom-left" })
local prBR, prBL = geometry.parkRequest(brCfg, sz), geometry.parkRequest(blCfg, sz)
ck("parkRequest preserves the size", prBR.w == 1280 and prBR.h == 353)
ck("parkRequest bottom-right is entirely off screen",
   geometry.visibleArea(prBR) == 0, string.format("%d,%d", prBR.x, prBR.y))
ck("parkRequest bottom-left is entirely off screen",
   geometry.visibleArea(prBL) == 0, string.format("%d,%d", prBL.x, prBL.y))
ck("parkRequest picks the rightmost display for bottom-right", prBR.x == 4480, prBR.x)
ck("parkRequest picks the leftmost display for bottom-left",
   prBL.x == -2048 - 1280, prBL.x)
ck("parkRequest corners differ", prBR.x ~= prBL.x)

geometry = load("geometry", S.ONE_SCREEN)
ck("parkRequest on a single display is off screen",
   geometry.visibleArea(geometry.parkRequest(brCfg, sz)) == 0)
ck("unionFrame on a single display", geometry.unionFrame().w == 1920)
ck("pickScreen mouse", geometry.pickScreen("mouse"):name() == "Solo")
ck("pickScreen main", geometry.pickScreen("main"):name() == "Solo")
ck("pickScreen focused falls back when nothing is focused",
   geometry.pickScreen("focused"):name() == "Solo")

-- ── finder (the replies AppleScript actually gives) ───────────────────────
-- finder.lua is the only module that talks to Finder, so almost none of it can
-- be tested offline.  What can is the part that has bitten hardest: reading a
-- new window's id out of whatever Finder says back.
section("finder")

local function finderWith(reply)
  hs = select(1, S.install(S.REAL_SCREENS, { applescript = reply }))
  return dofile(R .. "finder.lua")
end
local function onMake(text)
  -- The snapshot query comes first and must answer something; only the reply to
  -- the window-making script is what each case is about.
  return function(src)
    if src:find("make new Finder window", 1, true) then return true, text end
    return true, "77\tDownloads\t" .. HOME .. "/Downloads\n"
  end
end

local fOK = finderWith(onMake("77\n91\n"))
local newId, newErr = fOK.openWindowAt(HOME)
ck("openWindowAt returns the id that appeared", newId == 91,
   tostring(newId) .. " / " .. tostring(newErr))

-- Measured right after `killall Finder`: `make new Finder window` works, the id
-- is even readable, but the window cannot be addressed to set its target.  The id
-- has to come back regardless, because it is the only way to close the window
-- that was left behind.
local fStray = finderWith(onMake(
  "STRAY|51843|Finder got an error: Can't set window id 51843 to alias|"))
local sId, sErr, stray = fStray.openWindowAt(HOME)
ck("a window Finder would not target is not returned as an id", sId == nil, tostring(sId))
ck("the failure says so", type(sErr) == "string" and sErr:find("not accept") ~= nil, sErr)
ck("and the stray id comes back to be closed", stray == 51843, tostring(stray))

-- The worse half of the same state, and the one that left two untargeted windows
-- on screen after every Finder restart: `id of nw` raises as well, so the only
-- place the number exists is inside the error from coercing the window to text.
local fSpec = finderWith(onMake(
  "STRAY|-1|Finder got an error: Can't set Finder window id -1 to alias \"HD:x:\"|" ..
  "Finder got an error: Can't make \194\171class brow\194\187 id 51900 of application " ..
  "\"Finder\" into type text."))
local _, _, stray2 = fSpec.openWindowAt(HOME)
ck("the id is dug out of the object specifier", stray2 == 51900, tostring(stray2))

-- And the id must come from the specifier only.  "window id -1" in the message
-- is not an id, and neither is anything in the path.
local fNone = finderWith(onMake("STRAY|-1|Finder got an error: Can't set window id -1|"))
local _, _, stray3 = fNone.openWindowAt(HOME)
ck("no specifier, no invented id", stray3 == nil, tostring(stray3))

-- ── store ─────────────────────────────────────────────────────────────────
section("store")
local store = load("store")
local b = store.blank()
ck("blank shape", b.version == 1 and b.lastSide == "left"
   and #b.panes.left.tabIds == 0 and #b.panes.right.paths == 0)

local st = store.blank()
st.minHeight = { withToolbar = 344, withoutToolbar = 324 }
st.lastSide  = "right"
st.panes.left  = { tabIds = { 45681, 45746 }, paths = { "/private/tmp", "/Users" },
                   activePath = "/Users" }
st.panes.right = { tabIds = {}, paths = { "/Applications" } }
ck("save", store.save(st))
local ld = store.load()
ck("ids survive as numbers",
   ld.panes.left.tabIds[1] == 45681 and ld.panes.left.tabIds[2] == 45746)
ck("paths stay index-aligned with ids", ld.panes.left.paths[2] == "/Users")
ck("activePath survives", ld.panes.left.activePath == "/Users")
ck("lastSide survives", ld.lastSide == "right")
ck("minHeight survives",
   ld.minHeight.withToolbar == 344 and ld.minHeight.withoutToolbar == 324)
ck("a pane with no ids keeps its rebuild paths",
   #ld.panes.right.tabIds == 0 and ld.panes.right.paths[1] == "/Applications")

-- The undrained half of a rebuild recipe.  paths can only ever describe tabs
-- that exist (it is index-aligned with tabIds), so without this the recipe on
-- disk shrinks to one folder the moment a pane is rebuilt -- measured as 8
-- remembered tabs coming back as 5.
local q = store.blank()
q.panes.left = { tabIds = { 51859 }, paths = { "/private/tmp" },
                 activePath = "/private/tmp",
                 pending = { paths = { "/Applications", "/usr" }, activePath = "/usr" } }
store.save(q)
local lq = store.load()
ck("a queued rebuild survives a restart", lq.panes.left.pending ~= nil
   and #lq.panes.left.pending.paths == 2, lq.panes.left.pending)
ck("in order", lq.panes.left.pending.paths[2] == "/usr", lq.panes.left.pending.paths[2])
ck("with the tab that was meant to end up active",
   lq.panes.left.pending.activePath == "/usr")
ck("and the tabs that do exist are still aligned",
   #lq.panes.left.tabIds == 1 and lq.panes.left.paths[1] == "/private/tmp")

local emptyQ = store.blank()
emptyQ.panes.left = { tabIds = {}, paths = { "/tmp" },
                      pending = { paths = { "", 7 } } }
store.save(emptyQ)
ck("a queue of nothing usable is no queue at all",
   store.load().panes.left.pending == nil)

-- A state written before pending existed has to keep working: it is what is on
-- the user's disk right now.
hs.settings.set("DropFinder.state.v1", { version = 1, lastSide = "left", minHeight = {},
  panes = { left = { tabIds = { 5 }, paths = { "/tmp" } }, right = { tabIds = {}, paths = {} } } })
local old1 = store.load()
ck("a state from before queues were written is still valid",
   old1.panes.left.paths[1] == "/tmp" and old1.panes.left.pending == nil)

local ragged = store.blank()
ragged.panes.left = { tabIds = { 1, 2, 3 }, paths = { "/tmp" } }
store.save(ragged)
ck("a torn write truncates to aligned pairs", #store.load().panes.left.tabIds == 1)

local dirty = store.blank()
dirty.panes.left = { tabIds = { 1, "x", 3 }, paths = { "/tmp", "/etc", "" } }
store.save(dirty)
local lz = store.load()
ck("junk entries are dropped, not repaired",
   #lz.panes.left.tabIds == 1 and lz.panes.left.paths[1] == "/tmp",
   #lz.panes.left.tabIds)

hs.settings.set("DropFinder.state.v1", { version = 99, panes = {} })
ck("a future version is discarded", store.load().version == 1
   and #store.load().panes.left.tabIds == 0)
hs.settings.set("DropFinder.state.v1", "garbage")
ck("garbage is discarded", store.load().version == 1)
hs.settings.set("DropFinder.state.v1", { version = 1 })
ck("a truncated state is completed with defaults",
   store.load().panes.left ~= nil and store.load().lastSide == "left")
store.clear()
ck("clear", hs.settings.get("DropFinder.state.v1") == nil)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
