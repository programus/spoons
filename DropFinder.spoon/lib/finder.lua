--- finder.lua — All Finder I/O for DropFinder.spoon
-- The only module allowed to talk to Finder, by either AppleScript or
-- Accessibility.  Every entry point returns `value, err` and never raises.
--
-- What Phase 0 measurements forced into this file:
--
--   * A Finder *tab* is an AppleScript `window` (it has id / name / target) but
--     appears in the AX tree only while it is the *active* tab of its real
--     window.  So: AppleScript is the source of truth for the set of tabs and
--     their paths; AX is the only way to move, resize or focus anything.
--   * `id of every window` and `hs.window:id()` are the same number.  Finder
--     assigns it, so it outlives hs.reload() and is a valid persistence key.
--   * `repeat with w in windows` raises -1700/-1731 when you read properties off
--     the loop variable.  Only the plural forms (`id of every window`) are
--     reliable; the zip happens in Lua.
--   * `AXIdentifier == "FinderWindow"` is the browser-window discriminator and
--     stays true while minimized.  `AXSubrole` does not — it flips to
--     AXDialog — so subrole filtering would lose the panel exactly when it is
--     hidden.
--   * `Finder:allWindows()` returns the desktop (id 0, AXScrollArea) even with
--     no windows open.  Always filter id ~= 0.
--
-- Main-loop hazards, all measured the hard way:
--   * hs.window.get(id) and hs.window.allWindows() enumerate every app and took
--     >12s.  Never used here; snapshots go through app:allWindows().
--   * Touching AX on a just-relaunched Finder blocks for tens of seconds, which
--     freezes every Hammerspoon hotkey.  ensureRunning is therefore
--     callback-based and never polls synchronously.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

local BUNDLE_ID = "com.apple.finder"
local TF_OSAX   = "/Library/ScriptingAdditions/TotalFinder.osax"
local TF_BUNDLE = "com.binaryage.totalfinder"

-- Cap AX round-trips so an unresponsive Finder degrades instead of hanging.
local AX_TIMEOUT = 2

---@type any
local log = hs.logger.new("DropFinder.finder", "info")

function M.setLogger(l) log = l end

-- ── Plumbing ───────────────────────────────────────────────────────────────

--- The Finder application object.
-- applicationsForBundleID rather than hs.application.get("Finder"), which
-- resolves by name and can pick up an impostor.
--@return table|nil  hs.application
function M.app()
  return hs.application.applicationsForBundleID(BUNDLE_ID)[1]
end

--- Escape a Lua string for embedding in an AppleScript string literal.
local function asStr(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

--- Run AppleScript, returning `result, err`.
local function runAS(src)
  local ok, result, raw = hs.osascript.applescript(src)
  if not ok then
    local msg = "AppleScript failed"
    if type(raw) == "table" then
      msg = tostring(raw.NSLocalizedDescription or raw.OSAScriptErrorMessage or msg)
    elseif raw then
      msg = tostring(raw)
    end
    return nil, msg
  end
  return result, nil
end

--- Ensure Finder is running, then call `cb(app|nil)`.
-- The delay is not politeness: AX against a cold Finder blocks the main thread
-- long enough to kill every hotkey in the session.
--@param cb function
function M.ensureRunning(cb)
  local app = M.app()
  if app then return cb(app) end
  hs.application.launchOrFocusByBundleID(BUNDLE_ID)
  local tries = 0
  local function poll()
    tries = tries + 1
    local a = M.app()
    if a then return cb(a) end
    if tries >= 10 then
      log.e("Finder did not come back after 5s")
      return cb(nil)
    end
    hs.timer.doAfter(0.5, poll)
  end
  hs.timer.doAfter(0.5, poll)
end

--- Probe the Automation (AppleEvents) permission lazily.
-- A denied prompt is permanent (-1743 forever), so the caller should show the
-- exact repair path: System Settings > Privacy & Security > Automation >
-- Hammerspoon > Finder.
--@return boolean, string|nil
function M.automationAvailable()
  local _, err = runAS('tell application "Finder" to count windows')
  if err then return false, err end
  return true, nil
end

--- Is TotalFinder injected into the *running* Finder?
-- TotalFinder rewrites Finder's tab model (every tab becomes a real AX window),
-- which breaks this spoon's identification logic outright, so it is worth saying
-- so out loud.  But "the osax is installed and a TotalFinder process is alive"
-- is not the same question and answers yes far too often: quitting TotalFinder
-- leaves its process up, and a Finder restarted afterwards is perfectly clean.
-- The only authoritative answer is what is mapped into Finder's address space.
-- Reading that means vmmap, which takes seconds -- hence the callback: the cheap
-- checks gate it (no osax or no process costs nothing at all) and vmmap runs out
-- of process, so the main loop never waits on it.
--@param cb function  receives (injected: boolean)
function M.totalFinderInjected(cb)
  if not hs.fs.attributes(TF_OSAX) then return cb(false) end
  if #hs.application.applicationsForBundleID(TF_BUNDLE) == 0 then return cb(false) end
  local app = M.app()
  local pid = app and app:pid() or nil
  if not pid then return cb(false) end

  -- grep -c keeps the output to one number; its exit code is 1 for "no match",
  -- so only stdout is consulted.
  local cmd = string.format("vmmap %d 2>/dev/null | grep -ci totalfinder", pid)
  local ok, task = pcall(hs.task.new, "/bin/sh", function(_, out)
    cb((tonumber((tostring(out or ""):match("%d+"))) or 0) > 0)
  end, { "-c", cmd })
  if not ok or not task then return cb(false) end
  task:start()
end

-- ── Reading: the tab set (AppleScript) ─────────────────────────────────────

local SNAPSHOT_SRC = [[
tell application "Finder"
  set theIds to id of every window
  set theNames to name of every window
  set out to ""
  repeat with i from 1 to (count of theIds)
    set p to ""
    try
      set p to POSIX path of (target of window i as alias)
    end try
    set out to out & ((item i of theIds) as string) & tab & (item i of theNames) & tab & p & linefeed
  end repeat
  return out
end tell
]]

--- Every Finder tab, in Finder's z-order (active first).
--@return table|nil  { {id = n, name = s, path = s}, ... }
--@return string|nil err
function M.snapshot()
  local out, err = runAS(SNAPSHOT_SRC)
  if err then return nil, err end
  local list = {}
  for line in tostring(out or ""):gmatch("[^\n]+") do
    local id, name, path = line:match("^(%d+)\t([^\t]*)\t(.*)$")
    if id then
      list[#list + 1] = { id = math.floor(tonumber(id)), name = name, path = path }
    end
  end
  return list, nil
end

--- id -> {x, y, w, h} for every Finder tab.
-- Plural forms only, for the reason in the header.  A tab that is not its
-- window's active one answers with the bounds the window had when it last was
-- active, which is what makes this useful right after a relaunch: every tab of a
-- window macOS has just restored still names the frame the window was restored
-- at.  Finder's `bounds` is {left, top, right, bottom}, global and y-down.
--@return table|nil, string|nil
function M.boundsById()
  local out, err = runAS(
    'tell application "Finder" to return {id of every window, bounds of every window}')
  if err then return nil, err end
  if type(out) ~= "table" or type(out[1]) ~= "table" or type(out[2]) ~= "table" then
    return nil, "unexpected answer to bounds of every window"
  end
  local map = {}
  for i, id in ipairs(out[1]) do
    local b = out[2][i]
    if type(id) == "number" and type(b) == "table" and #b >= 4 then
      map[math.floor(id)] = { x = b[1], y = b[2], w = b[3] - b[1], h = b[4] - b[2] }
    end
  end
  return map, nil
end

--- id -> path, for the callers that only need the lookup.
--@return table|nil, string|nil
function M.pathsById()
  local list, err = M.snapshot()
  if not list then return nil, err end
  local map = {}
  for _, t in ipairs(list) do map[t.id] = t.path end
  return map, nil
end

-- ── Reading: real windows (Accessibility) ──────────────────────────────────

local function axWindow(win)
  local ok, el = pcall(hs.axuielement.windowElement, win)
  if not ok or not el then return nil end
  pcall(function() el:setTimeout(AX_TIMEOUT) end)
  return el
end

--- Is this hs.window a Finder browser window (as opposed to the desktop, an
--- Info panel, a copy-progress sheet, ...)?
--@param win table  hs.window
--@return boolean
function M.isBrowserWindow(win)
  if not win or win:id() == nil or win:id() == 0 then return false end
  local el = axWindow(win)
  if not el then return false end
  local ok, ident = pcall(function() return el:attributeValue("AXIdentifier") end)
  return ok and ident == "FinderWindow"
end

--- Finder's real browser windows: one hs.window per window, representing that
--- window's *active* tab.  Includes minimized windows.
--@return table  hs.window[]
function M.axWindows()
  local app = M.app()
  if not app then return {} end
  local out = {}
  local ok, wins = pcall(function() return app:allWindows() end)
  if not ok or not wins then return {} end
  for _, w in ipairs(wins) do
    if M.isBrowserWindow(w) then out[#out + 1] = w end
  end
  return out
end

--- Find a browser window by Finder id.
-- Deliberately not hs.window.get(id): that walks every application.
--@param id integer
--@return table|nil  hs.window
function M.axWindowById(id)
  if not id then return nil end
  for _, w in ipairs(M.axWindows()) do
    if w:id() == id then return w end
  end
  return nil
end

-- ── Reading: the tab bar ───────────────────────────────────────────────────

--- The AXTabGroup that is the tab bar.
-- Both conditions are required: the view-mode switcher in the toolbar is also a
-- group of AXRadioButtons, and it has no title.
--@param win table  hs.window
--@return table|nil  hs.axuielement
function M.tabBar(win)
  local el = axWindow(win)
  if not el then return nil end
  local ok, kids = pcall(function() return el:attributeValue("AXChildren") end)
  if not ok or not kids then return nil end
  for _, kid in ipairs(kids) do
    local r = kid:attributeValue("AXRole")
    if r == "AXTabGroup" and kid:attributeValue("AXTitle") == "tab bar" then
      return kid
    end
  end
  return nil
end

--- Tab titles (folder basenames) in tab-bar order, plus the selected index.
-- The trailing untitled AXRadioButton is the "+" button and is dropped.
--@param win table  hs.window
--@return table  string[]
--@return integer|nil  selected index
function M.tabTitles(win)
  local bar = M.tabBar(win)
  if not bar then return {}, nil end
  local ok, kids = pcall(function() return bar:attributeValue("AXChildren") end)
  if not ok or not kids then return {}, nil end
  local titles, selected = {}, nil
  for _, kid in ipairs(kids) do
    if kid:attributeValue("AXRole") == "AXRadioButton" then
      local title = kid:attributeValue("AXTitle")
      if title and title ~= "" then
        titles[#titles + 1] = title
        if kid:attributeValue("AXValue") == true then selected = #titles end
      end
    end
  end
  return titles, selected
end

--- Switch to the i-th tab.
-- AXPress on the tab bar is the only way: AX has no object for an inactive tab,
-- so it cannot be focused directly.
--@param win table  hs.window
--@param i integer  1-based, in tabTitles order
--@return boolean
function M.selectTab(win, i)
  local bar = M.tabBar(win)
  if not bar then return false end
  local ok, kids = pcall(function() return bar:attributeValue("AXChildren") end)
  if not ok or not kids then return false end
  local n = 0
  for _, kid in ipairs(kids) do
    if kid:attributeValue("AXRole") == "AXRadioButton" then
      local title = kid:attributeValue("AXTitle")
      if title and title ~= "" then
        n = n + 1
        if n == i then
          local pressed = pcall(function() kid:performAction("AXPress") end)
          return pressed
        end
      end
    end
  end
  return false
end

-- ── Writing ────────────────────────────────────────────────────────────────

--- Dig a window id out of an AppleScript object specifier.
-- Only the number is trusted: everything around it ("Can't make", "into type
-- text") is localised, while `<<class brow>> id 51900` is Finder's own raw
-- specifier and is not.  Anchored on `id ` before the digits so a path or an
-- error code elsewhere in the message cannot be mistaken for it.
--@param spec string|nil
--@return integer|nil
local function strayIdFromSpecifier(spec)
  if type(spec) ~= "string" then return nil end
  local last = nil
  for n in spec:gmatch("id (%d+)") do last = n end
  return last and math.floor(tonumber(last)) or nil
end

--- Open a new Finder window at a path.
-- The new id comes from diffing the id set rather than from `id of nw`, which is
-- the family of expression that raises -1700 on some Finder builds.
--@param path string  Absolute POSIX directory path (must exist)
--@return integer|nil, string|nil
function M.openWindowAt(path)
  if not path or hs.fs.attributes(path, "mode") ~= "directory" then
    return nil, "not a directory: " .. tostring(path)
  end
  local before, err = M.snapshot()
  if not before then return nil, err end
  local seen = {}
  for _, t in ipairs(before) do seen[t.id] = true end

  -- The targeting is wrapped because of one measured state: a Finder that has
  -- just relaunched and has never been activated accepts `make new Finder
  -- window` and will even tell you the new window's id, but its window
  -- collection is empty as far as AppleScript is concerned -- `count windows`
  -- answers 0 while the windows macOS restored are sitting there -- so
  -- `window id N` cannot be addressed and the target cannot be set (-10006 /
  -- -1728).  The id is reported back as `STRAY|id|message|specifier` so the
  -- caller can close the window once Finder is answering again; nothing here can
  -- close it, because closing addresses the window too.
  --
  -- In the worst version of that state `id of nw` raises as well, so newId stays
  -- -1 and there is seemingly nothing to report -- which is how two untargeted
  -- windows came to be left on screen after every `killall Finder`.  But the id
  -- is still there to be read: coercing the window to text fails with the raw
  -- object specifier in the message, `Can't make <<class brow>> id 51900 of
  -- application "Finder" into type text`, and that number is the window's id.
  -- Hence the deliberate `nw as text`, whose *error* is the payload.
  local src = string.format([[
tell application "Finder"
  set nw to make new Finder window
  set newId to -1
  try
    set newId to id of nw
  end try
  set spec to ""
  if newId is -1 then
    try
      set spec to (nw as text)
    on error e0
      set spec to e0
    end try
  end if
  try
    set target of window id newId to (POSIX file "%s" as alias)
  on error e
    return "STRAY|" & (newId as string) & "|" & e & "|" & spec
  end try
  set theIds to id of every window
  set out to ""
  repeat with i from 1 to (count of theIds)
    set out to out & ((item i of theIds) as string) & linefeed
  end repeat
  return out
end tell
]], asStr(path))

  local out, err2 = runAS(src)
  if err2 then return nil, err2 end
  local text = tostring(out or "")
  local strayId, strayErr, spec = text:match("^STRAY|(%-?%d+)|([^|]*)|(.*)$")
  if strayId then
    local id = math.floor(tonumber(strayId))
    if id < 0 then id = strayIdFromSpecifier(spec) end
    return nil, "Finder would not accept a target: " .. strayErr, id and id >= 0 and id or nil
  end
  for line in text:gmatch("%d+") do
    local id = math.floor(tonumber(line))
    if not seen[id] then return id, nil end
  end
  return nil, "could not identify the new window"
end

-- ── Writing: tabs ──────────────────────────────────────────────────────────

-- File > New Tab has no AppleScript equivalent (Finder's dictionary has no tab
-- object), and the two alternatives are worse: flipping the *global*
-- AppleWindowTabbingMode changes every app's behaviour, and Window > Merge All
-- Windows would swallow the user's floating windows.  So: the menu item.
--
-- The English titles are tried first and the shortcut second, because a menu
-- walk is not free.  Cmd+T survives localisation; "New Tab" does not.
local NEW_TAB_TITLES = { "File", "New Tab" }
---@type table|boolean|nil   nil = not resolved yet, false = gave up
local newTabMenuPath = nil

--- Find a menu item by its command-key equivalent, returning its title path.
local function menuPathByShortcut(items, char, mods, trail)
  for _, it in ipairs(items or {}) do
    local title = it.AXTitle
    if title and title ~= "" then
      local path = { unpack(trail) }
      path[#path + 1] = title
      if it.AXMenuItemCmdChar == char and it.AXMenuItemCmdModifiers == mods then
        return path
      end
      local kids = it.AXChildren and it.AXChildren[1]
      if kids then
        local found = menuPathByShortcut(kids, char, mods, path)
        if found then return found end
      end
    end
  end
  return nil
end

--- The menu path of File > New Tab.  Resolved once per session and cached.
--@return table|nil, string|nil
local function newTabMenu(app)
  if type(newTabMenuPath) == "table" then return newTabMenuPath, nil end
  if newTabMenuPath == false then return nil, "no New Tab menu item" end

  local found = nil
  pcall(function()
    if app:findMenuItem(NEW_TAB_TITLES) then found = NEW_TAB_TITLES end
  end)
  if not found then
    -- 0 means "Command with nothing added"; anything else is a different item
    -- (Ctrl+Cmd+T is Add to Sidebar).
    local items
    pcall(function() items = app:getMenuItems() end)
    found = items and menuPathByShortcut(items, "T", 0, {}) or nil
    if found then
      log.i("resolved New Tab by its Cmd+T shortcut: " .. table.concat(found, " > "))
    end
  end
  newTabMenuPath = found or false
  if not found then return nil, "no New Tab menu item" end
  return found, nil
end

--- Open a new tab at `path` inside the real window `win` belongs to.
-- Callback-based on purpose.  The tab does not appear in `id of every window`
-- the instant the menu press returns, and the whole sequence is a menu press
-- plus two AppleScript round trips: run synchronously in a loop it would block
-- every Hammerspoon hotkey for as long as it takes.
--@param win table  hs.window  the pane's active tab
--@param path string  absolute POSIX directory
--@param cb function  receives (id|nil, err|nil)
function M.newTabAt(win, path, cb)
  cb = cb or function() end
  if not win then return cb(nil, "no window") end
  if not path or hs.fs.attributes(path, "mode") ~= "directory" then
    return cb(nil, "not a directory: " .. tostring(path))
  end
  local app = M.app()
  if not app then return cb(nil, "Finder is not running") end

  local before, err = M.snapshot()
  if not before then return cb(nil, err) end
  local seen = {}
  for _, t in ipairs(before) do seen[t.id] = true end

  -- New Tab acts on the app's frontmost window, so the pane has to be frontmost
  -- first.  win:focus(), never app:activate(): the latter raises every floating
  -- Finder window too.
  pcall(function() win:focus() end)

  local menu, mErr = newTabMenu(app)
  if not menu then return cb(nil, mErr) end
  local ok = false
  pcall(function() ok = app:selectMenuItem(menu) end)
  if not ok then return cb(nil, "File > New Tab was not available") end

  -- One retry: Finder publishes the tab a moment after the press.
  local tries = 0
  local function finish()
    tries = tries + 1
    local after, err2 = M.snapshot()
    local id = nil
    for _, t in ipairs(after or {}) do
      if not seen[t.id] then id = t.id; break end
    end
    if not id then
      if tries < 3 then return hs.timer.doAfter(0.15, finish) end
      return cb(nil, err2 or "could not identify the new tab")
    end
    -- Set and read back in one round trip.  `set target of window id N` is
    -- per-tab and does not switch the active tab, which is what makes restoring
    -- several tabs possible at all.
    local got, err3 = runAS(string.format([[
tell application "Finder"
  set target of window id %d to (POSIX file "%s" as alias)
  return POSIX path of (target of window id %d as alias)
end tell]], id, asStr(path), id))
    if err3 then return cb(id, err3) end
    local want = path:gsub("/$", "")
    if tostring(got or ""):gsub("/$", "") ~= want then
      return cb(id, "tab opened at " .. tostring(got) .. ", not " .. path)
    end
    cb(id, nil)
  end
  hs.timer.doAfter(0.15, finish)
end

--- Minimize or restore one window by id (hideMode == "minimize").
-- `collapsed` is per-window, unlike app:hide(), which would also hide the user's
-- floating Finder windows.  Takes ~0.17s and does not steal focus.
--@param id integer
--@param collapsed boolean
--@return boolean, string|nil
function M.setCollapsed(id, collapsed)
  local _, err = runAS(string.format(
    'tell application "Finder" to set collapsed of window id %d to %s',
    id, collapsed and "true" or "false"))
  if err then return false, err end
  return true, nil
end

--- Move and resize one window by id, without Accessibility.
-- The escape hatch for a pane on another Space: measured on macOS 26, a window
-- that is not on the Space its display is currently showing is absent from
-- app:allWindows() entirely, so there is no hs.window to call setFrame on --
-- and that is exactly the pane the cross-Space hotkey has to fetch.  AppleScript
-- keeps answering by id from there, and setting bounds does the whole job at
-- once: the window arrives on the target display, joins the Space showing there,
-- and becomes visible to Accessibility again (all three measured).
--
-- Finder's `bounds` is {left, top, right, bottom} in the same global, y-down
-- coordinates as an hs.window frame.  It is clamped the same way AX is -- a top
-- above the menu bar comes back shifted down, not resized -- so the caller gets
-- the frame the window actually took, exactly as applyFrame does.
--@param id integer
--@param rect table  {x, y, w, h}
--@return table|nil  Actual frame, or nil if Finder refused or the window is gone
function M.setBounds(id, rect)
  local _, err = runAS(string.format(
    'tell application "Finder" to set bounds of window id %d to {%d, %d, %d, %d}',
    id, math.floor(rect.x), math.floor(rect.y),
    math.floor(rect.x + rect.w), math.floor(rect.y + rect.h)))
  if err then return nil end
  local b = runAS(string.format(
    'tell application "Finder" to return bounds of window id %d', id))
  if type(b) ~= "table" or #b < 4 then return nil end
  return { x = b[1], y = b[2], w = b[3] - b[1], h = b[4] - b[2] }
end

--- Close one tab by id.
--@param id integer
--@return boolean, string|nil
function M.closeTab(id)
  local _, err = runAS(string.format(
    'tell application "Finder" to close window id %d', id))
  if err then return false, err end
  return true, nil
end

--- Is Finder hidden (Cmd+H, or hideMode = "hide")?
--@return boolean
function M.isHidden()
  local app = M.app()
  if not app then return false end
  local ok, h = pcall(function() return app:isHidden() end)
  return ok and h == true
end

--- Hide or unhide Finder as a whole -- every one of its windows, the user's
--- own included.  The desktop is not a window and stays.
--@param hidden boolean
--@return boolean
function M.setHidden(hidden)
  local app = M.app()
  if not app then return false end
  local ok = pcall(function()
    if hidden then app:hide() else app:unhide() end
  end)
  return ok
end

--- Bring a whole window to the Space the user is on, by way of its tabs.
-- Measured on macOS 26: selecting an *inactive* tab by id (`set index ... to 1`)
-- from another Space carries the window, every tab with it, onto the Space
-- showing on its display, where Accessibility can see it again.  Selecting the
-- tab that is already active does nothing, which is why it takes two: `via` is
-- any other tab of the same window, and `active` is selected again afterwards
-- so the pane comes back showing what it showed.  The only thing on this system
-- that moves another app's window between Spaces -- hs.spaces claims it and
-- moves nothing -- and nothing is closed or rebuilt.
--@param via integer     an inactive tab of the window
--@param active integer  the tab to leave selected
--@return boolean, string|nil
function M.hopTabs(via, active)
  local _, err = runAS(string.format([[
tell application "Finder"
  set index of window id %d to 1
  set index of window id %d to 1
end tell]], via, active))
  if err then return false, err end
  return true, nil
end

--- Close several tabs by id in one AppleScript call.
-- One call rather than one per tab: Hammerspoon delivers the windowDestroyed of
-- each close while the next round trip is still running, so closing a pane tab
-- by tab let the model react half way through -- and it is much faster.  The
-- real window cannot be closed as a whole: AppleScript only knows tabs, and the
-- close button belongs to Accessibility, which cannot see a window on another
-- Space -- the very case this is used for.  A tab that is already gone is
-- skipped, not an error.
--@param ids integer[]
--@return integer|nil closed, string|nil err
function M.closeTabs(ids)
  if #ids == 0 then return 0, nil end
  local list = {}
  for i, id in ipairs(ids) do list[i] = string.format("%d", id) end
  local n, err = runAS(string.format([[
tell application "Finder"
  set n to 0
  repeat with i in {%s}
    try
      close window id (contents of i)
      set n to n + 1
    end try
  end repeat
  return n
end tell]], table.concat(list, ", ")))
  if err then return nil, err end
  return tonumber(n) or 0, nil
end

--- Show or hide one window's toolbar.  Buys back ~20px of minimum height.
--@param id integer
--@param visible boolean
--@return boolean, string|nil
function M.setToolbarVisible(id, visible)
  local _, err = runAS(string.format(
    'tell application "Finder" to set toolbar visible of window id %d to %s',
    id, visible and "true" or "false"))
  if err then return false, err end
  return true, nil
end

return M
