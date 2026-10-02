--- panel.lua — Pane model and state machine for DropFinder.spoon
--
-- A *pane* is one real Finder window that DropFinder positions: `left` or
-- `right`.  A *tab* is one browsing context inside it.  Everything else Finder
-- has open is a *floating* window and is never touched.
--
-- The identity rule that makes "never touch floating windows" structural rather
-- than heuristic: a tab id enters pane.tabIds through exactly three doors --
--   create    we opened it ourselves and diffed the id out of Finder
--   adopt     the user pressed the adopt hotkey on it
--   reattach  it matches an id we persisted
-- There is no frame-proximity or path-guessing door, so a window the user
-- opened can never be mistaken for part of the panel.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

local FINDER_BUNDLE = "com.apple.finder"
local SIDES = { "left", "right" }

-- ── Injected dependencies (set by init.lua; libs never require each other) ──
---@type any
local finder, geometry, store
---@type any
local log = hs.logger.new("DropFinder.panel", "info")
---@type any
local cfg = nil

-- ── Private state ──────────────────────────────────────────────────────────
---@type table
local panes = {}
---@type string
local lastSide = "left"
---@type string|nil
local prevAppBundleID = nil
---@type integer|nil
local prevWindowId = nil      -- a *floating* Finder window that had focus before show()
---@type table
local minHeight = {}          -- { withToolbar = n, withoutToolbar = n }
---@type number
local suppressUntil = 0       -- os.time-ish deadline for ignoring our own events
---@type table
local axById = {}             -- refreshed by reconcile(); id -> hs.window
---@type table
local freshIds = {}           -- id -> true for tabs we just made; see markFresh
---@type boolean
local spacesWarned = false    -- the cross-Space alert is shown once per session
---@type table
local draining = { left = false, right = false }   -- a tab restore is in flight
---@type boolean
local restoresOff = false     -- set by restoreAll(): stop() means stop, including
                              -- a drain that a show() already in flight is about
                              -- to start.  Cleared by the next show().
---@type function
local writeState              -- defined in the persistence section below; the tab
                              -- restore writes each tab down as it lands, and that
                              -- is a long way above where persisting lives

function M.setDeps(deps)
  finder   = deps.finder
  geometry = deps.geometry
  store    = deps.store
  log      = deps.log or log
end

function M.setConfig(c) cfg = c end

local function newPane(side)
  return {
    side       = side,
    tabIds     = {},   -- integer[], tab-bar order
    pathList   = {},   -- string[], index-aligned with tabIds; survives the pane
    activeId   = nil,
    activePath = nil,
    frame      = nil,
    collapsed  = false,
    origin     = nil,
    parked     = nil,  -- where parking actually landed; also used to tell our
                       -- own park apart from a user drag
    pending    = nil,  -- { paths = string[], activePath = s }: tabs still to be
                       -- recreated, drained by completeRebuilds().  Persisted:
                       -- it is the only place the undrained half of a rebuild
                       -- recipe lives, and a rebuild can be interrupted by
                       -- anything from a blind AX tree to hs.reload().
    minted     = {},   -- integer[]: ids this side created and has not seen
                       -- closed.  Not the model -- provenance.  reconcile drops
                       -- an id as soon as Finder stops listing it, and Finder
                       -- does that for reasons that have nothing to do with the
                       -- window being gone; an id dropped and forgotten is a
                       -- window left in the panel's slot that nothing may touch.
                       -- Persisted, and cleared when Finder dies with the ids.
  }
end

-- ── Helpers ────────────────────────────────────────────────────────────────

local function basename(p)
  return (tostring(p):match("([^/]+)/?$")) or p
end

--- What the tab bar calls the folder at `p`.
-- Finder titles a tab with the folder's display name, which is not always its
-- last path component: "Virtual Machines.localized" reads "Virtual Machines".
-- Measured: matching on the raw basename left such a tab accounted for by no
-- tab bar, and every regroup and reorder of its pane gave up because of it.
-- A path that no longer resolves has no display name, so it falls back.
local function tabName(p)
  local ok, n = pcall(hs.fs.displayName, tostring(p))
  if ok and type(n) == "string" and n ~= "" then return n end
  return basename(p)
end

local function indexOfId(pane, id)
  for i, v in ipairs(pane.tabIds) do
    if v == id then return i end
  end
  return nil
end

--- Which side owns this tab id, if any.
--@param id integer
--@return string|nil
-- A tab we have just created is not addressable the instant it exists.  Finder
-- publishes it to `id of every window` a moment later, and Accessibility only
-- ever exposes the *active* tab -- so between the two there is a window in which
-- a brand-new tab is in neither view.  Anything that reconciles in that window
-- used to conclude the tab had been closed and drop it.  Measured: adopting
-- three tabs one after another lost the middle one that way, leaving the pane
-- with six tabs in Finder and five in the model.  So an id we made stays in the
-- model on its own authority for a couple of seconds, which is far longer than
-- the gap and far shorter than any tab's life -- but only while the rest of its
-- pane is still answering (see reconcile).  Otherwise the same grace would
-- outlive a window that really was closed a moment after we made it.
-- Measured on the machine, which is why this is not the tidy 2s it started as:
-- one adopt round -- New Tab, two AppleScript round trips, a tab-bar press, the
-- settle delay -- takes 1.5-2s in the hand, and the reconcile that has to keep
-- the new tab is the one at the top of the *next* round.  A 2s grace expired
-- about a second before it, and the tab went.  The cost of the longer window is
-- that a tab closed within it lingers in the model until the next reconcile
-- after it, so it is kept as short as the measurement allows.
local FRESH_GRACE = 8.0        -- s; same clock as the event suppression window

local function markFresh(id)
  if id then freshIds[id] = hs.timer.secondsSinceEpoch() end
end

local function isFresh(id)
  local at = freshIds[id]
  if not at then return false end
  if hs.timer.secondsSinceEpoch() - at > FRESH_GRACE then
    freshIds[id] = nil
    return false
  end
  return true
end

function M.sideOfTab(id)
  for _, side in ipairs(SIDES) do
    if indexOfId(panes[side], id) then return side end
  end
  return nil
end

local function isLive(side)
  return #panes[side].tabIds > 0
end

-- ── Provenance: the ids we minted ──────────────────────────────────────────
--
-- reconcile() drops an id the moment Finder stops listing it, which is right for
-- the model and wrong for the window: Finder omits windows for reasons that have
-- nothing to do with them being closed (measured for minutes on end after a
-- relaunch, and again while a display's Space was elsewhere).  A dropped id was
-- also a forgotten id, and a forgotten id is a window *we made*, sitting in the
-- panel's own slot, that requirement 4 then forbids anyone from moving or
-- closing.  Two of those were left on screen for an hour.
--
-- So every id that enters a pane is written down here as well, and a rebuild
-- checks the list before it makes anything new.  This does not weaken
-- requirement 4: the guarantee there is about windows DropFinder did not create,
-- and membership in this list is exactly the proof that it did.
local MINTED_CAP = 32
-- Finder hands ids out per process, so the list is only meaningful for the
-- process that issued them.  Termination clears it -- but Finder can also be
-- restarted while Hammerspoon is not running, and then a fresh window could wear
-- a remembered number.  The pid is the check that costs nothing.
local mintedPid = nil

local function finderPid()
  local app = finder.app()
  if not app or type(app.pid) ~= "function" then return nil end
  local ok, pid = pcall(app.pid, app)
  return ok and pid or nil
end

local function mint(side, id)
  if not id then return end
  local list = panes[side].minted
  for _, v in ipairs(list) do
    if v == id then return end
  end
  list[#list + 1] = id
  while #list > MINTED_CAP do table.remove(list, 1) end
  mintedPid = finderPid()
end

--- Drop everything one Finder process told us about its windows.  The numbers
--- mean nothing outside the process that issued them; the paths are half of the
--- rebuild recipe and stay, which is what lets the next show() put the side back.
---@param pane table
---@param side string
local function forgetPaneIds(pane, side)
  pane.tabIds    = {}
  pane.activeId  = nil
  pane.frame     = nil
  pane.collapsed = false
  pane.origin    = nil
  -- The queue was aimed at ids that no longer exist, but the paths in it are
  -- still wanted.  With tabIds now empty there is no index alignment left to
  -- keep, so they can go back into pathList -- and pathList without ids is
  -- exactly what the store keeps whole.
  if pane.pending then
    for _, path in ipairs(pane.pending.paths) do
      pane.pathList[#pane.pathList + 1] = path
    end
    pane.activePath = pane.pending.activePath or pane.activePath
    pane.pending = nil
  end
  -- The ids died with the process, so the provenance record dies with them:
  -- keeping it would let a fresh window that happens to reuse a number be taken
  -- for one of ours.
  pane.minted = {}
  draining[side] = false
end

--- Notice a Finder restart nobody told us about.  onFinderTerminated() covers the
--- one we watched happen; this is the other one -- the pid moved while
--- Hammerspoon was down, or the launch/terminate pair never reached us.  Ids are
--- per process, so every number we have written down now belongs to a dead one,
--- and a window in the new process (one macOS restored, or one the user opened)
--- can be wearing it.  Reattaching to that number would move a window
--- DropFinder did not create, so the numbers go and the paths stay: the panes
--- rebuild, and whatever wears the number now stays floating (requirement 4).
---@return boolean  false when a restart was just detected
local function forgetIdsIfFinderChanged()
  local pid = finderPid()
  if not pid then return true end          -- cannot tell; leave the model alone
  if not mintedPid then mintedPid = pid; return true end
  if mintedPid == pid then return true end
  log.i(string.format(
    "Finder is a different process now (%d, was %d); its window numbers are not ours",
    pid, mintedPid))
  for _, side in ipairs(SIDES) do forgetPaneIds(panes[side], side) end
  mintedPid = pid
  return false
end

--- Drop minted ids Finder no longer lists, and the whole list if the ids came
--- from a Finder that is no longer running.
---@param pathOf table<integer,string>  id -> path, from finder.pathsById()
---@return boolean  false when the list cannot be trusted at all
local function pruneMinted(pathOf)
  if not forgetIdsIfFinderChanged() then return false end
  for _, side in ipairs(SIDES) do
    local keep = {}
    for _, id in ipairs(panes[side].minted) do
      if pathOf[id] then keep[#keep + 1] = id end
    end
    panes[side].minted = keep
  end
  return true
end

--- { left = true|nil, right = true|nil } for the sides that currently exist.
--@return table
function M.liveSides()
  local out = {}
  for _, side in ipairs(SIDES) do
    if isLive(side) then out[side] = true end
  end
  return out
end

--- The hs.window handle for a pane: AX only ever exposes the active tab, so this
--- is the pane's active tab and it changes whenever the user switches tabs.
--- Always re-resolve; never cache across an await.
--@param side string
--@return table|nil  hs.window
local function paneWindow(side)
  local pane = panes[side]
  if pane.activeId and axById[pane.activeId] then return axById[pane.activeId] end
  for _, id in ipairs(pane.tabIds) do
    if axById[id] then return axById[id] end
  end
  return nil
end
M.paneWindow = paneWindow

local function minHeightKey()
  return cfg.hideToolbar and "withoutToolbar" or "withToolbar"
end

--- Ignore window-filter events caused by our own writes.
--@param seconds number
function M.suppress(seconds)
  suppressUntil = hs.timer.secondsSinceEpoch() + (seconds or 0.4)
end

--@return boolean
function M.isSuppressed()
  return hs.timer.secondsSinceEpoch() < suppressUntil
end

--- Put one pane's tabs into tab-bar order.
-- Our own order is the order tabs were created or adopted in, which only equals
-- the real order if Cmd+T always appends at the right end -- an assumption, and
-- one the user can break at any time by dragging a tab along the bar.  The tab
-- bar knows the answer, so ask it.
--
-- Only when the answer is unambiguous, though: a tab bar shows folder names, so the
-- mapping back to full paths is by folder name.  Two tabs whose folders share a
-- name make it a guess, and a guess here would mis-order the paths that get
-- persisted, so the existing order stays instead.  (The paths themselves are
-- never at risk: they come from ids.)
local function reorderByTabBar(side)
  local pane = panes[side]
  if #pane.tabIds < 2 then return end
  local w = paneWindow(side)
  if not w then return end
  local titles = finder.tabTitles(w)
  if #titles ~= #pane.tabIds then return end

  local indexOf = {}
  for i, p in ipairs(pane.pathList) do indexOf[tabName(p)] = i end

  local ids, paths, used = {}, {}, {}
  for _, t in ipairs(titles) do
    local i = indexOf[t]
    -- Bail on anything that is not a clean permutation.  `used` is what catches
    -- the duplicate-folder-name case: two tabs named "bin" put the same index
    -- twice, and continuing would duplicate one path and drop the other.
    if not i or used[i] then return end
    used[i] = true
    ids[#ids + 1]     = pane.tabIds[i]
    paths[#paths + 1] = pane.pathList[i]
  end
  pane.tabIds, pane.pathList = ids, paths
end

-- ── One side, one real window ──────────────────────────────────────────────
-- A pane is a set of tab ids, and an id enters it through exactly three doors:
-- create, adopt, reattach.  What that model has no door for is the tab the
-- *user* drags out of one window and drops into another: the id does not change,
-- the real window that owns it does, and nothing in either view says so.
--
-- Measured on the machine, after a drag that moved six of the left pane's tabs
-- into the right pane's window: both windows then carried ids filed under
-- "left", so paneWindow("left") resolved to whichever of them Accessibility
-- offered -- the *right* pane's window, because the tab dragged into it had
-- become its active one -- and every show()/hide() moved that window into the
-- left slot while the real left window sat untouched in it.  The right side
-- meanwhile had a live id (its own old tab, now a background tab of that same
-- window) and no resolvable window at all, so it was never laid out and never
-- rebuilt either.  Which window the hotkey grabbed even flipped from press to
-- press, since switching tabs changes what the AX tree exposes.
--
-- The repair is to derive the sides from the windows rather than the other way
-- round: group the managed ids by the real window that holds them, pair the two
-- fullest windows with the sides they mostly came from, and take each side's tab
-- list from its window's tab bar.  Nothing is moved, created or closed here.  A
-- window that ends up with neither side is simply forgotten, which leaves it
-- floating and therefore untouchable (requirement 4), and a side left with
-- nothing is rebuilt from its remembered paths on the next show() the way any
-- closed side is (requirement 5).

--- Every id the model owns, with the side it is filed under and its known path.
local function managedTabs()
  local m = {}
  for _, side in ipairs(SIDES) do
    local pane = panes[side]
    for i, id in ipairs(pane.tabIds) do
      m[id] = { side = side, path = pane.pathList[i] or "" }
    end
  end
  return m
end

--- Is the model's idea of which window holds what still true?
-- One question per side, asked of the window that side resolves to: are the tabs
-- in it the tabs this side thinks it has?  Folder names are all the tab bar
-- states, but a different bag of names is a different set of tabs whichever order
-- they are in -- and any drag shows up in the bag of the window the tab left as
-- well as the one it arrived in, so a side that has become unresolvable
-- altogether (the way the right one had on the machine) is still noticed through
-- the window that took its tab.
--
-- Cheap, and quiet in the normal case: one tab bar read per side off the AX
-- snapshot the reconcile just took.
--@return boolean
local function needsRegroup()
  -- Nothing to learn from a blind AX tree (locked screen, another Space, a
  -- Finder that has just relaunched) -- and everything to lose by acting on it.
  if not next(axById) then return false end
  for _, side in ipairs(SIDES) do
    local pane = panes[side]
    -- A minimized window puts every tab in the AX tree, so its handles cannot be
    -- told apart from separate windows; and a rebuild in flight is mid-way
    -- through changing the very thing being checked.
    if pane.collapsed or pane.pending or draining[side] then return false end
    for _, id in ipairs(pane.tabIds) do
      if isFresh(id) then return false end
    end
  end

  for _, side in ipairs(SIDES) do
    local pane = panes[side]
    local w = #pane.tabIds > 0 and paneWindow(side) or nil
    if w then
      local titles = finder.tabTitles(w)
      if #titles == 0 then
        -- Measured: a single-tab window has no tab bar at all.
        if #pane.tabIds ~= 1 then return true end
      elseif #titles ~= #pane.tabIds then
        return true
      else
        local bag = {}
        for _, t in ipairs(titles) do bag[t] = (bag[t] or 0) + 1 end
        for _, path in ipairs(pane.pathList) do
          local b = tabName(path)
          if not bag[b] or bag[b] == 0 then return true end
          bag[b] = bag[b] - 1
        end
      end
    end
  end
  return false
end

--- Which managed ids does each real window actually hold?
-- The tab bar is the only witness.  Its selected entry is pinned by the window's
-- own id -- that is the one thing Accessibility states rather than implies -- and
-- the rest are matched by folder name, the same way reorderByTabBar does it.
--
-- Only a window whose *own* active tab is one of ours can become a pane.  That is
-- the discipline paneWindow has always followed, and it is what keeps
-- requirement 2 across a drag: a window the user opened that a tab of ours was
-- dropped into is showing its own tab, so it is not a candidate, the tab leaves
-- the model instead, and the window is never moved, resized or closed.  (What is
-- deliberately not defended against is the user dragging a whole pane into a
-- window of their own and leaving one of our tabs selected in it: that is not
-- DropFinder adopting anything, it is the user moving the pane.)
--
-- Being managed is the whole test, without a look at provenance: every id in the
-- model was minted by us on the way in, and asking for the mint as well would
-- only make a side unregroupable once Finder had stopped listing one of its tabs
-- long enough for pruneMinted to forget it.
--
-- A non-candidate's tab bar is still read, though: that is the difference between
-- "that tab of mine is over there now" and "I cannot see where that tab of mine
-- is", and only the second one has to stop everything.
--@return table[]|nil  groups, or nil when the answer would be a guess
local function groupManagedByWindow(managed)
  local wins, taken = {}, {}
  for _, w in ipairs(finder.axWindows()) do
    local titles, sel = finder.tabTitles(w)
    wins[#wins + 1] = {
      w = w, titles = titles or {}, sel = sel, slot = {},
      -- A minimized window puts every one of its tabs in the AX tree, so its
      -- handles cannot be told apart from separate windows.  It can still
      -- account for tabs; it just cannot be handed a side.
      candidate = (managed[w:id()] ~= nil) and not w:isMinimized(),
    }
  end

  for _, g in ipairs(wins) do
    if g.candidate then
      local id = g.w:id()
      -- Measured: a single-tab window has no tab bar at all.  A handle to a tab
      -- that is not its window's active one has none either, which is the same
      -- reading for a very different situation -- hence the accounting below.
      if g.sel and g.titles[g.sel] then g.slot[g.sel] = id else g.single = id end
      taken[id] = true
    end
  end

  for _, g in ipairs(wins) do
    for i, t in ipairs(g.titles) do
      if not g.slot[i] then
        local found, several = nil, false
        for id, m in pairs(managed) do
          if not taken[id] and tabName(m.path) == t then
            if found then several = true; break end
            found = id
          end
        end
        -- Two of our tabs whose folders share a name: which window holds which
        -- cannot be told, and a guess here would move the wrong window and
        -- persist the wrong paths.
        if several then
          log.w(string.format(
            "regroup: more than one managed tab is called %q; " ..
            "cannot tell which window holds which, leaving the model alone", t))
          return nil
        end
        -- No candidate at all is not ambiguity: that entry is a tab of someone
        -- else's making, sitting in one of our windows.  It stays out of the model.
        if found then g.slot[i] = found; taken[found] = true end
      end
    end
  end

  -- Every tab the model owns has to turn up somewhere before any of them may be
  -- moved between sides or dropped.  This is what separates a tab the user
  -- dragged into a window we do not manage -- accounted for, so it can leave the
  -- model -- from a tab bar that simply could not be read, which is what a
  -- handle to a non-active tab looks like: a window claiming to hold one tab
  -- while it holds three.  Acting on that reading throws away real tabs, so an
  -- incomplete picture means no regroup at all.
  local accounted = {}
  for _, g in ipairs(wins) do
    if g.single then accounted[g.single] = true end
    for _, id in pairs(g.slot) do accounted[id] = true end
  end
  for id in pairs(managed) do
    if not accounted[id] then
      log.i(string.format(
        "regroup: no tab bar accounts for tab %d (%s); leaving the model alone",
        id, tostring(managed[id].path)))
      return nil
    end
  end

  local out = {}
  for _, g in ipairs(wins) do
    if g.candidate then
      local ids, paths, score = {}, {}, { left = 0, right = 0 }
      local function add(id)
        ids[#ids + 1]     = id
        paths[#paths + 1] = managed[id].path
        score[managed[id].side] = score[managed[id].side] + 1
      end
      if g.single then
        add(g.single)
      else
        for i = 1, #g.titles do
          if g.slot[i] then add(g.slot[i]) end
        end
      end
      out[#out + 1] = { w = g.w, active = g.w:id(), ids = ids, paths = paths, score = score }
    end
  end
  -- Deepest first, and by id when two are the same size, so the pairing below
  -- does not depend on the order Accessibility happened to answer in.
  table.sort(out, function(a, b)
    if #a.ids ~= #b.ids then return #a.ids > #b.ids end
    return a.active < b.active
  end)
  return out
end

--- Hand each side the window its tabs mostly came from.
-- Every ordered pair of candidates is scored by how many of their tabs are
-- already filed under the side they would take, and the best pair wins; ties go
-- to the pair holding more tabs and then to the lower window ids, so the answer
-- does not depend on the order Accessibility answered in.
--
-- A window may only take a side it has at least one tab of.  Without that, a tab
-- dragged out into a window of its own would be handed the side whose own window
-- was closed -- DropFinder adopting a window off the back of a drag, which is
-- requirement 2 the long way round.  The tab leaves the model instead, the window
-- is left exactly where the user dropped it, and the empty side is rebuilt from
-- its remembered paths on the next show() like any closed side.
--@return table  side -> group (either side may be absent)
local function pairWithSides(groups)
  local best, bestKey = {}, nil
  local function better(key)
    if not bestKey then return true end
    for i = 1, #key do
      if key[i] ~= bestKey[i] then return key[i] > bestKey[i] end
    end
    return false
  end
  for i, a in ipairs(groups) do
    for j, b in ipairs(groups) do
      if i ~= j and a.score.left > 0 and b.score.right > 0 then
        local key = { a.score.left + b.score.right, #a.ids + #b.ids, -a.active, -b.active }
        if better(key) then best, bestKey = { left = a, right = b }, key end
      end
    end
  end
  if bestKey then return best end
  -- No pair works, so at most one side has a window at all.
  for _, side in ipairs(SIDES) do
    for _, g in ipairs(groups) do
      if g.score[side] > 0 then
        local key = { g.score[side], #g.ids, -g.active }
        if better(key) then best, bestKey = { [side] = g }, key end
      end
    end
  end
  return best
end

--- Rewrite the panes from the windows.  Model only: nothing here touches Finder.
local function regroupPanes()
  local managed = managedTabs()
  local groups  = groupManagedByWindow(managed)
  if not groups then return end
  local assign  = pairWithSides(groups)
  if not (assign.left or assign.right) then
    log.w("regroup: none of the panel's windows is showing one of its own tabs; leaving the model alone")
    return
  end

  -- Provenance follows the tab: an id we minted is still one of ours whichever
  -- side it ended up on, so the two lists are pooled and dealt out again.
  -- An id we minted that is not in the model at all is not part of this deal:
  -- it is a tab a reconcile let go of a moment ago on a snapshot's word, and the
  -- next reconcile takes it back if Finder lists it again.  Dropping its
  -- provenance here, in the same pass as that drop, would make the loss final.
  local wasMinted, stranded = {}, {}
  for _, side in ipairs(SIDES) do
    stranded[side] = {}
    for _, id in ipairs(panes[side].minted) do
      wasMinted[id] = true
      if not managed[id] then stranded[side][#stranded[side] + 1] = id end
    end
  end
  local kept = {}

  for _, side in ipairs(SIDES) do
    local pane, g = panes[side], assign[side]
    if g then
      pane.tabIds, pane.pathList = g.ids, g.paths
      pane.activeId = g.active
      local idx = indexOfId(pane, pane.activeId)
      if idx then pane.activePath = pane.pathList[idx] end
      pane.frame = g.w:frame()
      -- The window may not be the one this side was parked as, so the remembered
      -- park rect is worthless; geometry answers the only question it was asked.
      pane.parked = (not geometry.isOnScreen(pane.frame)) and pane.frame or nil
      local minted = {}
      for _, id in ipairs(pane.tabIds) do
        kept[id] = true
        if wasMinted[id] then minted[#minted + 1] = id end
      end
      for _, id in ipairs(stranded[side]) do minted[#minted + 1] = id end
      pane.minted = minted
      log.i(string.format("regroup: %s is window %d now, %d tab(s), active %s",
                          side, g.active, #pane.tabIds, tostring(pane.activePath)))
    else
      -- Every tab this side had is in the other side's window now.  pathList and
      -- activePath stay: they are the recipe the next show() rebuilds from.
      pane.tabIds, pane.activeId, pane.frame, pane.parked = {}, nil, nil, nil
      pane.minted = {}
      log.i(string.format("regroup: %s has no window of its own any more; " ..
                          "it will be rebuilt from %s", side, tostring(pane.activePath)))
    end
  end

  for id, m in pairs(managed) do
    if not kept[id] then
      log.i(string.format("regroup: tab %d (%s) left the panel", id, tostring(m.path)))
    end
  end
end

-- ── Reconcile: read-only sync with reality ─────────────────────────────────

--- Bring the pane model back in line with Finder.  Reads only; never moves,
--- resizes, creates or closes anything.  Called at start(), at the top of every
--- toggle, and after Finder or the display layout changes.
--@return boolean  false when Finder could not be read
function M.reconcile()
  local snap, err = finder.snapshot()
  if not snap then
    log.w("reconcile: snapshot failed: " .. tostring(err))
    return false
  end

  local pathOf = {}
  for _, t in ipairs(snap) do pathOf[t.id] = t.path end

  axById = {}
  local minimizedById = {}
  for _, w in ipairs(finder.axWindows()) do
    local id = w:id()
    axById[id] = w
    minimizedById[id] = w:isMinimized()
  end

  -- Measured: a Finder that has just relaunched answers `id of every window`
  -- with nothing while the windows it restored -- and the ones we just made --
  -- are sitting there in the AX tree.  That is not an error, so it arrives here
  -- as an empty snapshot, and taking it at face value silently throws away two
  -- perfectly good panes with nothing in the log to say why.  Accessibility is
  -- the second opinion: if it can see browser windows, the AppleScript view is
  -- lying, and the model is better left alone until it recovers.  When the user
  -- really has closed the last window, neither side sees anything and this does
  -- not trigger.
  if #snap == 0 and next(axById) then
    log.w("reconcile: Finder reports no windows while Accessibility sees some; leaving the model alone")
    return false
  end

  -- Both views agree there is a Finder to look at, so its pid is readable and
  -- worth checking before a single id is believed.
  forgetIdsIfFinderChanged()

  -- Take back the tabs of ours a previous reconcile wrongly let go.  The drop
  -- below believes a snapshot that leaves an id out, and right after a Finder
  -- relaunch that snapshot lies about single tabs as well: measured, four of the
  -- left pane's freshly restored tabs were dropped in one pass while their window
  -- stood there holding them.  Nothing ever took them back, and once the user
  -- selected one of them the pane's window was showing a tab the model did not
  -- know -- so the side resolved to no window at all, and every later show()
  -- left it where it was, unraised and behind the user's own Finder windows.
  -- `minted` still lists such an id, because the drop below leaves provenance
  -- alone (a tab that left the panel by a drag loses it in regroupPanes), and
  -- Finder listing the id again is the proof it was never closed.  Only for a
  -- side that is still live: an empty one is reclaimMinted's.
  for _, side in ipairs(SIDES) do
    local pane = panes[side]
    if #pane.tabIds > 0 then
      for _, id in ipairs(pane.minted) do
        if pathOf[id] and not M.sideOfTab(id) then
          pane.tabIds[#pane.tabIds + 1]     = id
          pane.pathList[#pane.pathList + 1] = pathOf[id]
          log.i(string.format("reconcile: %s tab %d (%s) is back",
                              side, id, tostring(pathOf[id])))
        end
      end
    end
  end

  for _, side in ipairs(SIDES) do
    local pane = panes[side]
    local ids, paths = {}, {}
    -- Is anything of this pane answering at all?  A tab we just made and neither
    -- view has caught up with is only believable while the window it went into is
    -- demonstrably still there; if the whole pane has gone quiet, the new tab
    -- went with it (a pane closed mid-restore does exactly that).
    local anySeen = false
    for _, id in ipairs(pane.tabIds) do
      if pathOf[id] or axById[id] then anySeen = true; break end
    end
    for i, id in ipairs(pane.tabIds) do
      -- Same asymmetry, one tab at a time: a window Accessibility can hand us is
      -- alive whatever the AppleScript snapshot left out, so keep the id and let
      -- its path stand at the last value we read.
      if pathOf[id] then freshIds[id] = nil end
      if pathOf[id] or axById[id] or (anySeen and isFresh(id)) then
        ids[#ids + 1] = id
        -- Finder's live target wins; the persisted path is only a fallback for
        -- a tab whose target we could not read (network volume, search window).
        local live = pathOf[id]
        paths[#paths + 1] = (live and live ~= "" and live) or pane.pathList[i] or ""
      else
        -- Normally the close that did this also arrived as windowDestroyed, so
        -- this is only the other order.  It is logged because the one time a tab
        -- went missing for a *bad* reason, nothing said so.
        log.i(string.format("reconcile: %s tab %d (%s) is gone",
                            side, id, tostring(pane.pathList[i])))
      end
    end

    if #ids > 0 then
      pane.tabIds, pane.pathList = ids, paths
      -- Normally exactly one of a pane's tabs is in the AX tree and that is the
      -- active one.  While minimized, Finder exposes them all, so prefer a
      -- non-minimized match and only then fall back.
      local active, anyMin = nil, false
      for _, id in ipairs(ids) do
        if axById[id] then
          if minimizedById[id] then
            anyMin = true
          elseif not active then
            active = id
          end
        end
      end
      -- Decide "minimized" before falling back, because the fallback below
      -- cannot tell the two apart: while minimized every tab is in the AX tree,
      -- the remembered active one included, so a fallback that looked at
      -- axById alone concluded the pane was up and reset collapsed to false.
      -- Measured after a hand-pressed Cmd+M: the pane was in the Dock and
      -- dumpState said collapsed=false, which also left stop() with nothing to
      -- restore.
      pane.collapsed = (active == nil) and anyMin or false
      if not active and pane.activeId and axById[pane.activeId] then
        -- Keep the remembered active tab rather than guessing ids[1]: while
        -- minimized nothing says which tab is active, and the answer is still
        -- whatever it was before.
        active = pane.activeId
      end
      pane.activeId  = active or ids[1]
      reorderByTabBar(side)
      local idx = indexOfId(pane, pane.activeId)
      if idx then pane.activePath = pane.pathList[idx] end
      local w = paneWindow(side)
      if w then pane.frame = w:frame() end
    else
      -- The pane is gone.  Keep pathList and activePath: they are the recipe
      -- for rebuilding it on the next show().
      pane.tabIds    = {}
      pane.activeId  = nil
      pane.collapsed = false
      pane.frame     = nil
    end
  end

  -- Last, because it needs the pruned model and the AX snapshot above, and
  -- because what it repairs is the one thing the model cannot express: a tab the
  -- user dragged from one of the panel's windows into the other.
  if needsRegroup() then regroupPanes() end

  return true
end

-- ── Tri-state ──────────────────────────────────────────────────────────────

--- "hidden" | "shown_unfocused" | "shown_focused"
--
-- Hidden is decided from live geometry (is each pane meaningfully on a screen?)
-- rather than by comparing against the remembered park rect, which goes stale on
-- reload or when a display is unplugged.
--
-- "Shown" requires *every* live pane to be visible, not merely one of them.  A
-- half-shown panel -- one side minimized with Cmd+M, or dragged off the desktop
-- by hand -- is a panel the user wants completed, so the hotkey should finish
-- showing it; treating that as "shown" made the hotkey put the surviving half
-- away instead.  A side that is not live at all is not missing, it is absent:
-- requirement 9 says the survivor legitimately fills the panel on its own.
--@return string
function M.state()
  local known, visible = 0, 0
  for _, side in ipairs(SIDES) do
    local w = isLive(side) and paneWindow(side) or nil
    -- A live pane whose window AX cannot resolve is unknown, not hidden, and must
    -- not veto: that is the state a pane passes through for a moment after Cmd+T,
    -- when its new active tab is in the AX tree but not yet in our tabIds.
    if w then
      known = known + 1
      -- isMinimized() covers both hideModes: our own collapse and the user's
      -- Cmd+M are the same state as far as "can this pane be seen" goes.
      if not w:isMinimized() and geometry.isOnScreen(w:frame()) then
        visible = visible + 1
      end
    end
  end
  if known == 0 or visible < known then return "hidden" end

  -- focusedWindow() lags when apps switch, so gate on the frontmost bundle id
  -- first and only then ask which window has focus.
  local front = hs.application.frontmostApplication()
  if front and front:bundleID() == FINDER_BUNDLE then
    local fw = front:focusedWindow()
    if fw and M.sideOfTab(fw:id()) then return "shown_focused" end
  end
  return "shown_unfocused"
end

-- ── Layout ─────────────────────────────────────────────────────────────────

--- Position the live panes on `screen`.
-- Finder vetoes heights below its minimum, so the requested height is read back:
-- if it was raised, that becomes the cached minimum and both panes are re-laid
-- out at the new height so they still match.  This is why no 344 appears
-- anywhere in the code.
--@param screen table|nil  hs.screen; defaults to cfg.screenPolicy
-- Lay one pane out whether or not Accessibility will hand over a window for it.
-- A pane on a Space its display is not showing is missing from app:allWindows()
-- altogether (measured, macOS 26), and that is precisely the pane the
-- cross-Space hotkey exists to fetch: with no window object there is nothing for
-- setFrame to act on, and the panel used to come up a side short with no
-- complaint.  AppleScript still takes the window's id from there, and one
-- `set bounds` both moves the pane here and hands it back to Accessibility.
--@return table|nil  The frame the pane actually took
local function applyPaneFrame(side, rect, retry)
  local w = paneWindow(side)
  if w then return geometry.applyFrame(w, rect, cfg.frameTolerance, retry) end
  local pane = panes[side]
  local id = isLive(side) and (pane.activeId or pane.tabIds[1]) or nil
  if not id then return nil end
  log.d(string.format("%s pane is not visible to Accessibility; setting bounds by id", side))
  return finder.setBounds(id, rect)
end

local function layout(screen)
  screen = screen or geometry.pickScreen(cfg.screenPolicy)
  local live = M.liveSides()
  if not (live.left or live.right) then return end

  local key = minHeightKey()
  M.suppress(0.5)

  local function pass()
    local frames = geometry.paneFrames(screen, cfg, minHeight[key], live)
    local raised = nil
    for _, side in ipairs(SIDES) do
      local rect = frames[side]
      local got = rect and applyPaneFrame(side, rect) or nil
      do
        if got then
          panes[side].frame  = got
          panes[side].parked = nil
          if got.h > rect.h + cfg.frameTolerance then
            raised = math.max(raised or 0, got.h)
          end
        end
      end
    end
    return raised
  end

  local raised = pass()
  if raised then
    log.i(string.format("Finder refused h=%s, minimum is %d (%s) — relaying out",
      tostring(minHeight[key]), raised, key))
    minHeight[key] = raised
    pass()
  end

  -- The read-back inside pass() happens the instant after setFrame, and for a
  -- move that crosses displays that is too early: AX still answers with the
  -- geometry the window had on the old screen, clamped to *its* bottom edge.
  -- Measured: a panel moved from the 1050px-tall display to the 1410px one
  -- modelled itself as 99px shorter than the window really was.  pane.frame
  -- drives tab adoption and drag detection, so a wrong one is not cosmetic.
  -- Look again once the move has settled and believe the window.
  hs.timer.doAfter(cfg.settleDelay, function()
    local frames = geometry.paneFrames(screen, cfg, minHeight[key], live)
    M.suppress(0.4)
    for _, side in ipairs(SIDES) do
      local rect = frames[side]
      local w = rect and paneWindow(side) or nil
      -- Only a pane with a window is re-read here.  This pass exists for one
      -- thing: AX answers a cross-display move with the old screen's clamp still
      -- applied, and that stale read has to be replaced by the settled one.  A
      -- pane still invisible to Accessibility has no read to correct -- the first
      -- pass either fetched it by id, and recorded the frame that write read
      -- back, or could not place it at all, in which case it is still parked and
      -- saying otherwise here would lose that.
      if w then
        local now = w:frame()
        if not geometry.framesEqual(now, rect, cfg.frameTolerance) then
          log.d(string.format("%s pane settled at a different frame; re-applying", side))
          now = applyPaneFrame(side, rect) or now
        end
        panes[side].frame  = now
        panes[side].parked = nil
      end
    end
  end)
end
M.layout = layout

--- Re-run layout for the current screen.  Requirement 9's other half: when a
--- side disappears the survivor is re-laid out and takes the whole panel width.
function M.relayout()
  local w = paneWindow(lastSide) or paneWindow(lastSide == "left" and "right" or "left")
  layout(w and w:screen() or nil)
end

-- ── Creating a missing pane ────────────────────────────────────────────────

--- The directories a rebuilt pane should open, in tab-bar order, plus which of
--- them should end up active.
-- Requirement 3: every tab that side had comes back, in order, with the tab the
-- user was last on selected.  A path that no longer resolves to a directory is
-- dropped rather than handed to Finder: `make new Finder window to` a missing
-- path raises.
--
-- Requirement 5 as written says "that side's configured default directory", but
-- the persisted paths win whenever there are any.  Parking does not destroy
-- windows, so a side that came back somewhere else would read as a reset rather
-- than a restore.  cfg.defaultPaths is the fallback for a first run, and for a
-- side whose every saved folder has since been deleted or unmounted.
--@param side string
--@return table  string[]  at least one path
--@return integer  index into that list of the tab to activate
local function rebuildPlan(side)
  local pane = panes[side]
  local function isDir(p)
    return type(p) == "string" and p ~= "" and hs.fs.attributes(p, "mode") == "directory"
  end

  -- pathList holds the tabs that exist and pending.paths the rest of the same
  -- recipe, in order, so the two concatenated are the plan -- and a rebuild that
  -- was interrupted halfway restarts from the whole thing instead of from the
  -- one tab that made it.
  local recipe = {}
  for _, p in ipairs(pane.pathList) do recipe[#recipe + 1] = p end
  if pane.pending then
    for _, p in ipairs(pane.pending.paths) do recipe[#recipe + 1] = p end
  end
  -- The remembered active tab is in the queue while a rebuild is unfinished:
  -- pane.activePath tracks whatever tab is live right now, which during a drain
  -- is whichever one Finder happened to make last.
  local want = (pane.pending and pane.pending.activePath) or pane.activePath

  local paths, active = {}, nil
  if cfg.restoreTabs then
    for _, p in ipairs(recipe) do
      if isDir(p) then
        paths[#paths + 1] = p
        if not active and p == want then active = #paths end
      end
    end
  else
    -- Tab restore off: one tab per side, the one that was active.
    if isDir(want) then
      paths[1] = want
    else
      for _, p in ipairs(recipe) do
        if isDir(p) then paths[1] = p; break end
      end
    end
  end
  if #paths == 0 then paths = { cfg.defaultPaths[side] } end
  return paths, active or 1
end

--- Take back windows this side minted that Finder is still listing.
-- Cheaper than rebuilding and, more to the point, the only thing that ever
-- clears a stranded pane: a window whose id reconcile dropped while Finder was
-- being unhelpful is otherwise left in the panel's slot for good, and the
-- rebuild puts a second pane on top of it.  Only ids in this side's own minted
-- list are considered, and only while no side already claims them, so nothing
-- the user opened can be caught by this.
---@return boolean  true when the side is live again
local function reclaimMinted(side)
  local pane = panes[side]
  if #pane.minted == 0 then return false end
  local pathOf = finder.pathsById()
  if not pathOf then return false end
  if not pruneMinted(pathOf) then return false end

  local ids, paths = {}, {}
  for _, id in ipairs(pane.minted) do
    if not M.sideOfTab(id) then
      ids[#ids + 1]     = id
      paths[#paths + 1] = pathOf[id]
    end
  end
  if #ids == 0 then return false end

  pane.tabIds, pane.pathList = ids, paths
  pane.activeId   = ids[1]
  pane.activePath = paths[1]
  pane.origin     = "reattach"
  pane.collapsed  = false
  reorderByTabBar(side)
  log.i(string.format("reclaimed %d stranded %s window(s) (%s)", #ids, side,
                      table.concat(ids, ", ")))
  return true
end

--- Create whichever sides are missing, then call `cb()`.
-- Phase 1 restores one tab per side; the remaining tabs are Phase 2.
local function ensurePanes(cb, retried)
  local created = false
  local failed, strays = 0, {}
  for _, side in ipairs(SIDES) do
    if not isLive(side) then reclaimMinted(side) end
    if not isLive(side) then
      local plan, activeIdx = rebuildPlan(side)
      local path = plan[1]
      local id, err, stray = finder.openWindowAt(path)
      if id then
        local pane = panes[side]
        pane.tabIds   = { id }
        pane.pathList = { path }
        pane.activeId = id
        markFresh(id)
        mint(side, id)
        pane.origin   = "create"
        -- The pane goes on screen with its first tab only; the rest are queued
        -- for completeRebuilds() so that a cold show() is not held up by one
        -- menu press and two AppleScript round trips per tab.
        if #plan > 1 then
          local rest = {}
          for i = 2, #plan do rest[#rest + 1] = plan[i] end
          pane.pending = { paths = rest, activePath = plan[activeIdx] }
        else
          pane.pending    = nil
          pane.activePath = path
        end
        created = true
        if cfg.hideToolbar then finder.setToolbarVisible(id, false) end
        log.i(string.format("created %s pane at %s (id %d)%s", side, path, id,
          #plan > 1 and string.format(" + %d tab(s) to follow", #plan - 1) or ""))
      else
        failed = failed + 1
        if stray then strays[#strays + 1] = stray end
        log.e(string.format("could not create %s pane at %s: %s",
          side, tostring(path), tostring(err)))
      end
    end
  end

  -- A Finder that has just relaunched and has not been activated yet hands out
  -- windows nobody can address (see finder.openWindowAt), so the first attempt
  -- after `killall Finder` fails for both sides and leaves two untargeted
  -- windows behind.  Waking Finder -- the same thing the shell's `open -a
  -- Finder` does -- makes its whole window collection addressable at once, and
  -- then the second attempt behaves normally.  Focus is not a cost here: this
  -- runs inside show(), which is about to focus the panel anyway.  Once only,
  -- so a genuinely broken Finder cannot turn the hotkey into a loop.
  if failed > 0 and not retried then
    log.w("Finder is not answering for its windows yet; waking it and retrying")
    hs.application.launchOrFocusByBundleID(FINDER_BUNDLE)
    return hs.timer.doAfter(0.5, function()
      -- Now that windows can be addressed, take back the ones we could not use.
      for _, id in ipairs(strays) do finder.closeTab(id) end
      M.reconcile()
      ensurePanes(cb, true)
    end)
  end

  if created then
    -- Give Finder time to publish the new window to the AX tree before we try to
    -- position or focus it.
    hs.timer.doAfter(cfg.settleDelay, function()
      M.reconcile()
      cb()
    end)
  else
    cb()
  end
end

-- ── Multi-tab restore (requirement 3) ──────────────────────────────────────

-- How many times restoreNextTab will wait for a pane's window to reappear
-- before it stops, and how many times one path may fail New Tab before it is
-- given up on.  Both exist to keep a wedged Finder from turning the drain into
-- an endless timer chain.
local AX_BLIND_TRIES = 8
local NEW_TAB_TRIES  = 2

--- Add one queued tab to `side`, then come back for the next one.
local function restoreNextTab(side, done, attempt)
  local pane  = panes[side]
  local queue = pane.pending
  if not queue or #queue.paths == 0 then
    pane.pending = nil
    return done()
  end
  -- stop() calls the drain off by clearing these rather than by dropping the
  -- queue, so the paths are still there to be persisted and rebuilt from.
  if restoresOff or not draining[side] then return done() end

  -- Re-resolve the handle before every tab.  The previous New Tab changed which
  -- tab is active, and AX only has an object for the active one, so last round's
  -- handle is stale -- and handing a stale handle to New Tab could put the tab in
  -- the wrong window entirely.
  M.reconcile()
  local w = paneWindow(side)
  if not w then
    -- One symptom, two very different worlds, and only one of them is fatal.
    -- Right after Finder relaunches its AX tree can answer "no windows" for
    -- minutes while the windows are on screen -- measured, and confirmed through
    -- System Events, so it is Finder's AX server and not Hammerspoon.  Treating
    -- that as "the window is gone" and dropping the queue is what lost the
    -- user's tabs: 8 remembered tabs came back as 5, and the other 3 were gone
    -- from memory and from disk.  So wait while Finder still owns ids of ours,
    -- and when it stops, keep the queue for the next show() to rebuild from.
    attempt = (attempt or 0) + 1
    if #pane.tabIds > 0 and attempt <= AX_BLIND_TRIES then
      log.d(string.format("the %s pane's window is not in the AX tree yet; retry %d/%d",
                          side, attempt, AX_BLIND_TRIES))
      hs.timer.doAfter(0.2 * attempt, function() restoreNextTab(side, done, attempt) end)
      return
    end
    log.w(string.format(
      "stopped restoring tabs for the %s pane: no window answering; keeping %d path(s) for the next rebuild",
      side, #queue.paths))
    return done()
  end

  local path = table.remove(queue.paths, 1)
  finder.newTabAt(w, path, function(id, err)
    if id then
      -- The window-filter may have adopted this id already (it is a real tab of
      -- ours, so onWindowCreated is right to), possibly with the placeholder
      -- path Finder opened it at.  Do not double-add; the reconcile above the
      -- next tab refreshes the path from Finder either way.
      if not indexOfId(pane, id) then
        pane.tabIds[#pane.tabIds + 1]     = id
        pane.pathList[#pane.pathList + 1] = path
      end
      markFresh(id)
      mint(side, id)
      pane.activeId = id
      queue.tries   = nil
      -- Written down per tab, and without a reconcile because the top of this
      -- function just did one.  The point is that the queue on disk always names
      -- the tabs that do *not* exist yet: a reload halfway through a rebuild then
      -- carries on from here instead of making a second copy of everything it had
      -- already made.
      writeState(false)
      log.i(string.format("restored tab %d (%s) in the %s pane", id, path, side))
    else
      -- The path was taken off the queue to be used; a failure has to put it
      -- back or it is lost, which is the second half of the 8-tabs-became-5
      -- measurement.  New Tab misses transiently (the menu is not there yet
      -- while Finder is still waking), so retry it -- but bounded, because a
      -- path Finder will never accept must not stall the tabs behind it.
      queue.tries = (queue.tries or 0) + 1
      if queue.tries <= NEW_TAB_TRIES then
        table.insert(queue.paths, 1, path)
        log.w(string.format("could not restore tab %s in the %s pane (%s); retry %d/%d",
                            path, side, tostring(err), queue.tries, NEW_TAB_TRIES))
      else
        queue.tries = nil
        log.w(string.format("gave up on tab %s in the %s pane: %s",
                            path, side, tostring(err)))
      end
    end
    restoreNextTab(side, done)
  end)
end

--- Select the tab whose folder is `want`.
-- Goes through the tab bar by folder name rather than through our own index: the
-- tab bar is the only thing that knows the real order, and AX has no object for
-- an inactive tab, so AXPress is the only way to switch.  Two tabs with the same
-- folder name in one pane pick the first -- the degradation noted in README.
local function selectActiveTab(side, want)
  if not want then return end
  local w = paneWindow(side)
  if not w then return end
  local titles, selected = finder.tabTitles(w)
  if #titles == 0 then return end
  for i, t in ipairs(titles) do
    if t == tabName(want) then
      if i ~= selected and finder.selectTab(w, i) then
        log.d(string.format("selected the %s pane's remembered tab (%s)", side, want))
      end
      return
    end
  end
  log.d(string.format("the %s pane has no tab for %s any more", side, want))
end

--- Finish any pane that came back with only its first tab.
-- Deliberately after the panel is on screen and focused: the tabs arrive over
-- the next few hundred ms instead of delaying the panel.  The cost is that the
-- active tab flickers through the ones being created, and it is only paid on a
-- rebuild -- Finder restarted, or that side was closed.
local function completeRebuilds()
  if restoresOff then return end
  for _, side in ipairs(SIDES) do
    local pending = panes[side].pending
    -- The guard matters because every show() calls this, and a queue left over
    -- from an interrupted rebuild is picked up by the next press: two chains on
    -- one queue would interleave their New Tab presses in the same window.
    if pending and not draining[side] then
      local s, want = side, pending.activePath
      draining[s] = true
      restoreNextTab(s, function()
        draining[s] = false
        M.reconcile()
        selectActiveTab(s, want)
        M.persistNow()    -- reconciles first; writes whatever queue is left
      end)
    end
  end
end

-- ── Cross-Space (requirement 10) ───────────────────────────────────────────
-- Every hs.spaces call is a private API, so every one of them sits behind a
-- pcall: this is the part of the spoon a macOS update can remove outright, and
-- when it does the panel still has to open -- just on whichever Space it is
-- already on.
--
-- Measured on macOS 26, with a Space added for the purpose: moveWindowToSpace
-- returns true and moves nothing.  windowSpaces keeps answering with the Space
-- the pane was already on, whether it is asked with a window object or a window
-- id, so the claim is caught rather than believed -- and there is no other way
-- to carry another app's window between Spaces.  What decides what the user
-- actually sees is therefore the fallback: "activate" leaves the panel where it
-- is and says so once, while "recreate" closes the panes by id and rebuilds them
-- here, which does work -- a window made from another Space lands on the Space
-- you are standing on and Accessibility can see it straight away.

--- Which Space is showing on `screen` right now?
-- activeSpaceOnScreen, not focusedSpace(): with separate Spaces per display the
-- focused Space belongs to the focused display, which is not necessarily the one
-- the mouse -- and therefore the panel -- is on.
local function currentSpaceOf(screen)
  if not hs.spaces or not screen then return nil end
  local ok, id = pcall(hs.spaces.activeSpaceOnScreen, screen)
  if ok and type(id) == "number" then return id end
  return nil
end

--- true / false / nil, where nil means the API would not say.
local function isOnSpace(w, space)
  if not hs.spaces then return nil end
  local ok, list = pcall(hs.spaces.windowSpaces, w)
  if not ok or type(list) ~= "table" then return nil end
  for _, s in ipairs(list) do
    if s == space then return true end
  end
  return false
end

--- Close `sides` and rebuild them here: the "recreate" fallback.
local function recreateOnCurrentSpace(sides, cb)
  for _, side in ipairs(sides) do
    local pane = panes[side]
    log.i("recreating the " .. side .. " pane on the current Space")
    for _, id in ipairs(pane.tabIds) do finder.closeTab(id) end
    -- pathList and activePath survive on purpose: they are the recipe that
    -- ensurePanes and completeRebuilds rebuild from.
    pane.tabIds, pane.activeId, pane.frame, pane.parked = {}, nil, nil, nil
  end
  ensurePanes(cb)
end

--- Bring the panes to the Space showing on `screen`, then call `cb()`.
-- Must run after unhide(): a minimized window has no meaningful Space.
local function moveToCurrentSpace(screen, cb)
  if not cfg.crossSpace then return cb() end
  local target = currentSpaceOf(screen)
  if not target then
    if not spacesWarned then
      spacesWarned = true
      log.w("hs.spaces is unavailable here; the panel will open on its own Space")
      hs.alert.show("[DropFinder] this system will not let the panel change Spaces")
    end
    return cb()
  end

  local moved, stuck = false, {}
  for _, side in ipairs(SIDES) do
    local pane = panes[side]
    local w = isLive(side) and paneWindow(side) or nil
    -- Standing on a Space the panes are not on, Finder hands over no window at
    -- all: measured on macOS 26, app:allWindows() from there answers with the
    -- desktop and nothing else, while AppleScript keeps listing every tab.  So a
    -- side that is live but unresolvable is not a side to skip -- it is exactly
    -- the side this function exists to fetch, and skipping it is what made the
    -- hotkey look dead from another Space.  Both APIs that are still willing to
    -- talk about it take a window id: hs.spaces answered windowSpaces(49085) = 3
    -- from the next Space over, and AppleScript closes by id, which is what the
    -- recreate fallback needs.
    local handle = w or (isLive(side) and (pane.activeId or pane.tabIds[1]) or nil)
    -- A pane sitting on another *display* needs no Space move: layout() is about
    -- to move its frame onto `screen`, and a window that arrives on a display
    -- joins whatever Space is active there.  Measured on a three-display Mac: a
    -- pane parked in the corner of the second display reports the target
    -- screen's Space as soon as layout has moved it.  Asking hs.spaces to do it
    -- as well fails every time -- which used to read to the user as "the panel
    -- is stuck on another Space", and with crossSpaceFallback = "recreate" tore
    -- both panes down and rebuilt them on *every* show, because the park corner
    -- normally is on another display.
    -- Without a window object the remembered frame is the only thing left that
    -- says which display the pane is on -- and it is a fair witness, because a
    -- pane on another Space has not moved.
    local ws = w and w:screen() or geometry.screenOf(pane.frame)
    local sameScreen = ws and screen and ws:id() == screen:id()
    -- Only a definite "no" is acted on: an unanswerable windowSpaces must not
    -- turn into a move, let alone into a recreate.
    if handle and sameScreen and isOnSpace(handle, target) == false then
      -- One move per pane: its tabs share one real window, so moving the active
      -- tab takes the whole pane along.
      local ok = pcall(hs.spaces.moveWindowToSpace, handle, target)
      if ok and isOnSpace(handle, target) ~= false then
        moved = true
        log.i(string.format("moved the %s pane to Space %s", side, tostring(target)))
      else
        stuck[#stuck + 1] = side
        log.w(string.format("could not move the %s pane to Space %s", side, tostring(target)))
      end
    end
  end

  if #stuck > 0 then
    if cfg.crossSpaceFallback == "recreate" then
      return recreateOnCurrentSpace(stuck, cb)
    end
    if not spacesWarned then
      spacesWarned = true
      hs.alert.show("[DropFinder] the panel is on another Space and could not be moved")
    end
  end
  if moved then
    return hs.timer.doAfter(cfg.settleDelay, function()
      M.reconcile()
      cb()
    end)
  end
  cb()
end

-- ── Un-hiding ──────────────────────────────────────────────────────────────

--- Undo whatever hide() did, plus any full-screening the user applied, then
--- call `cb()`.  Restoring from minimize returns the window to its exact
--- pre-minimize bounds, so layout() still runs afterwards to move it to the
--- screen the mouse is on now.
local function unhide(cb)
  local wait = 0

  -- Deliberately not gated on `hideMode == "minimize"`: a pane can also be
  -- minimized because the user pressed Cmd+M on it, and then the hotkey has to
  -- bring it back whatever our own hide mechanism is.
  for _, side in ipairs(SIDES) do
    local pane = panes[side]
    if isLive(side) then
      local w = paneWindow(side)
      if pane.collapsed or (w and w:isMinimized()) then
        finder.setCollapsed(pane.activeId or pane.tabIds[1], false)
        pane.collapsed = false
        wait = math.max(wait, 0.3)
      end
    end
  end

  for _, side in ipairs(SIDES) do
    local w = paneWindow(side)
    if w and w:isFullScreen() then
      w:setFullScreen(false)
      -- The full-screen transition is an animation that cannot be cancelled.
      wait = math.max(wait, 0.6)
    end
  end

  if wait > 0 then
    hs.timer.doAfter(wait, function()
      M.reconcile()
      cb()
    end)
  else
    cb()
  end
end

-- ── show / hide / raise / toggle ───────────────────────────────────────────

--- Move `side` to the park corner and record where it really ended up.
local function parkSide(side)
  local w = paneWindow(side)
  if not w then return end
  local pane = panes[side]
  local f = w:frame()
  -- Parking only moves; keeping the size avoids a second Finder reflow and
  -- sidesteps the clamp behaviour when position and size change together.  Both
  -- sides go to the same corner on purpose: overlapping leaves one sliver on
  -- screen instead of two.
  local got = geometry.applyFrame(w, geometry.parkRequest(cfg, f),
                                  cfg.frameTolerance, false)
  pane.parked = got
  -- This is where the window is now, so it is also the frame every later
  -- comparison should be made against.  Leaving pane.frame at the shown position
  -- made onWindowCreated compare new tabs against a panel that is no longer
  -- there.
  pane.frame  = got or pane.frame
  if got then
    local vis = geometry.visibleArea(got)
    if vis > cfg.parkMaxVisible then
      log.w(string.format(
        "%s pane parked with %d px^2 still visible (limit %d); " ..
        "this screen layout clamps more than expected — consider hideMode = \"minimize\"",
        side, vis, cfg.parkMaxVisible))
    end
  end
end

-- Remember where focus should go when the panel is put away again (requirement
-- 12).  Two cases, and the second one is the whole reason this is not a one
-- liner: the user can press the hotkey from *inside Finder*, with one of their
-- own floating windows focused.  Never remembering Finder (the obvious rule --
-- otherwise hiding the panel hands focus straight back to the panel) then left
-- prevAppBundleID pointing at whatever app they were in before Finder, and
-- hiding pushed their floating window behind that app.  Reported from the
-- screen.  So remember the *window* in that case, and still never Finder as an
-- app.
local function capturePrevApp()
  local front = hs.application.frontmostApplication()
  local bid = front and front:bundleID() or nil
  prevWindowId = nil
  if bid == FINDER_BUNDLE then
    local fw = front:focusedWindow()
    local id = fw and fw:id() or nil
    -- A pane of our own is not somewhere to give focus back to: it is about to
    -- be parked.
    if id and not M.sideOfTab(id) then prevWindowId = id end
    return
  end
  if bid then prevAppBundleID = bid end
end

--- Raise the panel and focus it, without disturbing floating windows.
--
-- Deliberately not app:activate(): that raises *every* Finder window, including
-- the user's floating ones, which is exactly what requirement 4 forbids.
-- Per-window raise + focus is the only correct tool here -- but the order is
-- load-bearing, and getting it wrong is visible.  macOS keeps one global window
-- order, and AXRaise on a window of a *background* app only reorders that app's
-- own stack.  So raising both panes and then focusing one left the sibling
-- exactly where it was in the global order: the focused pane came to the front,
-- the other one stayed behind whatever the user had been working in.  Focus
-- first, so Finder is the active app, and only then raise -- at which point a
-- raise really does lift the window to the top of the screen.
function M.raise()
  local other  = lastSide == "left" and "right" or "left"
  local target = paneWindow(lastSide) or paneWindow(other)
  if not target then return end
  pcall(function() target:focus() end)

  local sibling = paneWindow(paneWindow(lastSide) and other or lastSide)
  if not sibling or sibling:id() == target:id() then return end
  -- Activation is asynchronous, so the second pass has to wait for it; raising
  -- the sibling can take main-ness with it, so the target is focused again last
  -- and ends up both on top and focused.
  hs.timer.doAfter(cfg.settleDelay, function()
    pcall(function() sibling:raise() end)
    pcall(function() target:focus() end)
  end)
end

--- Bring the panel out at the bottom of the policy screen and focus it.
-- `done` is optional and fires once the panel is up; adopt uses it to wait for a
-- pane to exist.  It is called before completeRebuilds(), which deliberately
-- runs on its own for the next few hundred ms.
function M.show(done)
  restoresOff = false     -- asking for the panel asks for its tabs too
  capturePrevApp()
  M.reconcile()
  local screen = geometry.pickScreen(cfg.screenPolicy)
  ensurePanes(function()
    unhide(function()
      -- After unhide, before layout: a minimized window has no Space to speak
      -- of, and a recreate fallback would undo a layout done first.
      moveToCurrentSpace(screen, function()
        layout(screen)
        M.raise()
        -- Before completeRebuilds() on purpose: the panel should be usable now,
        -- not once every remembered tab exists.  Safe to write here only because
        -- persistNow() writes pane.pending as well, so what lands on disk is the
        -- whole recipe -- one tab plus the queue -- rather than the one tab.
        M.persistNow()
        if done then done() end
        completeRebuilds()
      end)
    end)
  end)
end

--- Park (or minimize) the panel and hand focus back.
function M.hide()
  M.persistNow()          -- reconciles first, so the parking below sees a fresh model
  M.suppress(0.6)

  for _, side in ipairs(SIDES) do
    if isLive(side) then
      if cfg.hideMode == "minimize" then
        local pane = panes[side]
        local ok, err = finder.setCollapsed(pane.activeId or pane.tabIds[1], true)
        pane.collapsed = ok and true or false
        if not ok then log.w("minimize failed for " .. side .. ": " .. tostring(err)) end
      else
        parkSide(side)
      end
    end
  end

  if cfg.restoreFocusOnHide then
    -- A floating Finder window the panel came up over gets focus back directly.
    -- Handing it to prevAppBundleID instead would activate that app *over* the
    -- window the user was working in, which is the opposite of what requirement
    -- 12 is for.  Focus is the one thing requirement 4 does allow: the window is
    -- not moved, resized, minimized or closed.
    local w = nil
    if prevWindowId and not M.sideOfTab(prevWindowId) then
      w = finder.axWindowById(prevWindowId)
    end
    if w then
      pcall(function() w:focus() end)
    elseif prevAppBundleID then
      -- launchOrFocusByBundleID, not app:hide(): hiding Finder would also hide the
      -- user's floating windows.
      hs.application.launchOrFocusByBundleID(prevAppBundleID)
    end
  end
end

--- The hotkey: hidden -> show, shown but unfocused -> raise, focused -> hide.
function M.toggle()
  -- state() answers from the AX window table the last reconcile filled in, so a
  -- reconcile that could not see anything leaves it answering "hidden" for as
  -- long as nothing refreshes it.  Measured: the spoon started while the screen
  -- was locked, Accessibility handed over nothing, and the first press afterwards
  -- showed a panel that was already up instead of putting it away.  100ms on the
  -- hotkey is worth not acting on a stale verdict.
  M.reconcile()
  local s = M.state()
  log.d("toggle from state: " .. s)
  if s == "hidden" then
    M.show()
  elseif s == "shown_unfocused" then
    -- Not just raise(): "shown" is a geometric verdict, and a pane sitting on
    -- another Space of the same display is on screen by that test while being
    -- invisible to the user.  Raising it there would leave the screen unchanged
    -- and the hotkey looking dead, so the Space move show() does has to happen
    -- on this path too.
    moveToCurrentSpace(geometry.pickScreen(cfg.screenPolicy), function()
      M.raise()
    end)
  else
    M.hide()
  end
end

-- ── Adopt: merge a floating window in as tab(s) (requirement 11) ───────────
-- `Window > Merge All Windows` is refused on purpose: it is a global action that
-- would swallow the other pane and every floating window with it, which is
-- exactly what requirement 4 forbids.  The source is rebuilt tab by tab instead.

--- Which side should receive an adopted window?
local function adoptTargetSide()
  local want = cfg.adoptTarget
  if want == "left" or want == "right" then
    return isLive(want) and want or (want == "left" and "right" or "left")
  end
  if want == "mouse" then
    local ok, pos = pcall(hs.mouse.absolutePosition)
    if ok and type(pos) == "table" and pos.x then
      local best, bestDist
      for _, side in ipairs(SIDES) do
        local w = isLive(side) and paneWindow(side) or nil
        if w then
          local f = w:frame()
          local dx, dy = (f.x + f.w / 2) - pos.x, (f.y + f.h / 2) - pos.y
          local d = dx * dx + dy * dy
          if not best or d < bestDist then best, bestDist = side, d end
        end
      end
      if best then return best end
    end
  end
  return lastSide
end

--- The unmanaged Finder window sitting at `rect`, if there still is one.
local function floatingWindowAt(rect)
  for _, w in ipairs(finder.axWindows()) do
    local id = w:id()
    if id and not M.sideOfTab(id)
       and geometry.framesEqual(w:frame(), rect, cfg.frameTolerance) then
      return w, id
    end
  end
  return nil
end

--- Merge the frontmost floating Finder window into a pane as tab(s).
--@return boolean started, string|nil err
function M.adoptFrontmost()
  M.reconcile()
  -- Every refusal goes to the log as well as to the caller's alert.  An alert is
  -- gone in two seconds and leaves nothing behind: a user reported adopt "doing
  -- nothing" and all the console had to say about it was that hs.alert had been
  -- loaded.
  local function refuse(why)
    log.w("not adopting: " .. why)
    return false, why
  end

  local front = hs.application.frontmostApplication()
  if not front or front:bundleID() ~= FINDER_BUNDLE then
    return refuse("the frontmost app is not Finder (it is "
                  .. tostring(front and front:bundleID()) .. ")")
  end
  local win = front:focusedWindow()
  if not win or not finder.isBrowserWindow(win) then
    return refuse("no Finder window is focused")
  end
  if M.sideOfTab(win:id()) then
    return refuse("window " .. win:id() .. " is already part of the panel")
  end

  -- Whatever the source has to say has to be read now: from the first New Tab
  -- on, focus and the source's own active tab move around under us.
  local srcFrame = win:frame()
  local titles   = finder.tabTitles(win)
  -- A cap, so that a mistaken frame match can never eat more tabs than the
  -- source actually had.  A single-tab window has no tab bar, hence the max().
  local budget   = math.max(#titles, 1)

  local function ready(cb)
    -- Adopting into a parked panel would make the window appear to vanish, so a
    -- hidden panel comes out first; a shown one only needs its panes to exist.
    if M.state() == "hidden" then M.show(cb) else ensurePanes(cb) end
  end

  ready(function()
    local side = adoptTargetSide()
    if panes[side].pending then
      -- Both would be pouring tabs into the same window through the same
      -- one-menu-press-at-a-time channel; the queue wins, the user can press
      -- adopt again in a moment.
      log.w("not adopting: the " .. side .. " pane is still restoring its tabs")
      hs.alert.show("[DropFinder] the " .. side .. " pane is still restoring; try again")
      return
    end

    local moved, presses = 0, 0
    local function finish(err)
      M.persistNow()      -- reconciles first
      -- Focus belongs in the pane that just received the tabs, whichever side
      -- the user was in before.
      if moved > 0 then M.setLastSide(side); M.raise() end
      if err then
        log.w(string.format("adopt stopped after %d tab(s): %s", moved, err))
        hs.alert.show("[DropFinder] adopt stopped: " .. err)
      else
        log.i(string.format("adopted %d tab(s) into the %s pane", moved, side))
      end
    end

    local function step()
      if moved >= budget then return finish(nil) end
      M.reconcile()
      -- The source is re-found every round rather than held across the await:
      -- closing a tab takes its AX object with it, and only the *active* tab of
      -- a window has one at all.  That is also why this is a loop and not a
      -- batch -- AX gives neither id nor path for an inactive tab, so each one
      -- has to be read while it is the active one.
      local src, sid = floatingWindowAt(srcFrame)
      if not src then return finish(nil) end          -- nothing left: done
      -- Leftmost tab first, so they arrive in the source's tab-bar order.  AX has
      -- no object for an inactive tab, so the only way to read the leftmost one
      -- is to press it active first and come back.  Measured without this: the
      -- tabs arrive in *activation* order, which for a window whose newest tab is
      -- active means back to front.  `presses` caps the retries -- if pressing
      -- will not take, order is a nicety and moving the tabs is not.
      local titles, selected = finder.tabTitles(src)
      if #titles > 1 and selected and selected ~= 1 and presses < budget then
        presses = presses + 1
        if finder.selectTab(src, 1) then
          return hs.timer.doAfter(cfg.settleDelay, step)
        end
      end
      local path = (finder.pathsById() or {})[sid]
      if not path or path == "" then
        return finish("could not read the path of window " .. tostring(sid))
      end
      local pane = panes[side]
      local w    = paneWindow(side)
      if not w then return finish("the " .. side .. " pane went away") end

      finder.newTabAt(w, path, function(newId, err)
        if not newId then return finish(tostring(err)) end
        if not indexOfId(pane, newId) then
          pane.tabIds[#pane.tabIds + 1]     = newId
          pane.pathList[#pane.pathList + 1] = path
        end
        markFresh(newId)
        mint(side, newId)
        pane.activeId = newId
        -- Only now, with the tab safely recreated, may it disappear from the
        -- source.  Nothing is closed before its replacement exists, so a
        -- failure half way through still leaves every unmoved tab in place --
        -- which is why this is per-tab rather than the plan's all-or-nothing.
        finder.closeTab(sid)
        moved = moved + 1
        hs.timer.doAfter(cfg.settleDelay, step)
      end)
    end
    step()
  end)
  return true, nil
end

-- ── Bookkeeping used by watchers ───────────────────────────────────────────

--- Record which side the user last worked in (drives show()'s focus target).
--@param side string
function M.setLastSide(side)
  if side == "left" or side == "right" then lastSide = side end
end

--@return string
function M.getLastSide() return lastSide end

--@return table  the live pane table (read-only by convention)
function M.panes() return panes end

-- ── Event handlers (wired up by watchers.lua) ──────────────────────────────

--- A Finder window appeared.  Requirement 2 lives here: a new window is
--- floating unless it is demonstrably a *tab* inside a pane we already own.
---
--- The test cannot use frames alone, because an inactive tab reports stale
--- bounds.  It does not have to: the new window sits exactly where the pane
--- sits, and one of three things corroborates that it is a tab of it --
---   1. its tab bar still lists one of the pane's known folders, or
---   2. the pane's own tab bar now lists more tabs than the pane owns while the
---      new id is nowhere in the AX tree (a tab Finder added without selecting
---      it), or
---   3. it has no tab bar to read and the pane's active tab just left the AX
---      tree, which is what being replaced as the active tab looks like.
--- Anything else -- including every window the user opens by double-clicking a
--- folder -- is left completely alone.
--@param win table  hs.window
function M.onWindowCreated(win)
  if not win then return end
  local id = win:id()
  if not id or id == 0 then return end
  if M.sideOfTab(id) then return end
  if not finder.isBrowserWindow(win) then return end

  M.reconcile()
  if M.state() == "hidden" then return end

  local frame = win:frame()
  local titles = finder.tabTitles(win)
  local titleSet = {}
  for _, t in ipairs(titles) do titleSet[t] = true end

  for _, side in ipairs(SIDES) do
    local pane = panes[side]
    if #pane.tabIds > 0 and pane.frame
       and geometry.framesEqual(frame, pane.frame, cfg.frameTolerance) then
      local sharesTabBar = false
      for _, p in ipairs(pane.pathList) do
        if titleSet[tabName(p)] then
          sharesTabBar = true
          break
        end
      end
      -- With no tab bar at all there is nothing to corroborate, so require
      -- instead that this pane's active tab really did just leave the AX tree --
      -- which is what happens when one of its tabs is replaced as the active one.
      local paneWentInactive = pane.activeId ~= nil and axById[pane.activeId] == nil
      -- Both signals above assume the new tab is the active one, which is what a
      -- Cmd+T into a focused pane does.  Measured on a pane holding fourteen
      -- tabs: File > New Tab put the tab in the tab bar *without selecting it*,
      -- so the new id never entered the AX tree, its detached handle answered
      -- with no tab bar at all, and the pane's own active tab never went
      -- anywhere -- thirteen tabs in a row were filed as floating.
      -- The pane's window is the witness in that case, and Accessibility can
      -- still read it: its tab bar now lists more tabs than the pane owns.  A
      -- window the user opened by double-clicking a folder cannot look like
      -- this -- it leaves that count alone and arrives as an AX window of its
      -- own -- so requiring both keeps requirement 2 intact.
      local paneGrew = false
      if axById[id] == nil then
        local pw = paneWindow(side)
        if pw then paneGrew = #finder.tabTitles(pw) > #pane.tabIds end
      end
      if sharesTabBar or paneGrew or (#titles == 0 and paneWentInactive) then
        local pathOf = finder.pathsById() or {}
        local path = pathOf[id] or ""
        pane.tabIds[#pane.tabIds + 1]     = id
        pane.pathList[#pane.pathList + 1] = path
        markFresh(id)
        mint(side, id)
        pane.activeId   = id
        pane.activePath = path ~= "" and path or pane.activePath
        lastSide = side
        log.i(string.format("adopted new tab %d (%s) into %s pane", id, path, side))
        M.persistNow()
        return
      end
    end
  end
  log.d(string.format("window %d left floating", id))
end

--- A Finder window went away.  The window object is already dead, so nothing is
--- read from it: reconcile() diffs our ids against a fresh Finder snapshot and
--- the before/after tab counts say what actually happened.
function M.onWindowDestroyed()
  local before = {}
  for _, side in ipairs(SIDES) do before[side] = #panes[side].tabIds end
  if not M.reconcile() then return end

  local lost, emptied = false, false
  for _, side in ipairs(SIDES) do
    local now = #panes[side].tabIds
    if now < before[side] then
      lost = true
      if now == 0 then
        emptied = true
        log.i(side .. " pane closed; it will be rebuilt on the next show()")
      else
        log.d(string.format("%s pane lost a tab (%d -> %d)", side, before[side], now))
      end
    end
  end
  if not lost then return end

  M.persistNow()
  -- Requirement 9: the survivor takes the whole panel width immediately.
  if emptied and M.state() ~= "hidden" then
    local live = M.liveSides()
    if live.left or live.right then M.relayout() end
  end
end

--- A managed window moved.  Switching tabs also emits windowMoved with an
--- unchanged frame, so the frame comparison is load-bearing, not an
--- optimisation: without it every tab switch would look like a user drag.
--@param win table  hs.window
function M.onWindowMoved(win)
  if not win or M.isSuppressed() then return end
  local side = M.sideOfTab(win:id())
  if not side then return end
  local pane = panes[side]
  local frame = win:frame()
  if geometry.framesEqual(frame, pane.frame, cfg.frameTolerance) then return end

  -- Our own park is not a user drag.  The suppression window above is a timing
  -- guard, and Finder can deliver the move for the second pane after it has
  -- lapsed -- measured, not hypothetical.  Comparing against the park position
  -- of record is content-based, so it does not depend on the timing at all.
  if pane.parked and geometry.framesEqual(frame, pane.parked, cfg.frameTolerance) then
    pane.frame = frame
    return
  end

  pane.frame = frame
  if cfg.snapBack then
    log.d("snapping " .. side .. " pane back")
    M.relayout()
  else
    -- Do not fight the user.  The next show() puts it back.
    log.d(side .. " pane was moved by hand; leaving it")
  end
end

--- A managed window was minimized or restored, possibly by the user pressing
--- Cmd+M.  The event can carry an *inactive* tab's id, so it is only used to
--- find the side; the state itself is re-read.
--@param win table  hs.window
--@param minimized boolean
function M.onMinimizeChanged(win, minimized)
  if not win then return end
  local side = M.sideOfTab(win:id())
  if not side then return end
  panes[side].collapsed = minimized
  log.d(string.format("%s pane %s", side, minimized and "minimized" or "restored"))
end

--- Focus landed on a managed window; remember the side so show() and adopt know
--- where the user was working.  Not used to track the active *tab*: switching
--- tabs does not emit this event.
--@param win table  hs.window
function M.onWindowFocused(win)
  if not win then return end
  local side = M.sideOfTab(win:id())
  if side then
    lastSide = side
    panes[side].activeId = win:id()
  end
end

--- Finder quit or crashed.  The ids are gone for good, but the paths are the
--- rebuild recipe, so they are kept.
function M.onFinderTerminated()
  log.i("Finder terminated; keeping saved paths for rebuild")
  for _, side in ipairs(SIDES) do forgetPaneIds(panes[side], side) end
  mintedPid = nil
  axById = {}
  M.persistNow()
end

--- Finder came back.  Callers must have already waited: AX against a cold Finder
--- blocks the main thread for tens of seconds.
function M.onFinderLaunched()
  M.reconcile()
end

--- Displays changed.  If the panel is out and the screen it was on is gone, put
--- it back on the policy screen.
function M.onScreensChanged()
  M.reconcile()
  -- A pane with `parked` set was put away by us and has not been shown since.
  -- The corner it was parked in may not exist any more, and macOS will have
  -- dragged the window somewhere visible — which then reads as a shown panel, so
  -- the next hotkey press would raise a wrongly-sized window instead of opening
  -- the panel.  Park it again against the layout we have now.  Intent, not
  -- geometry, is the right test here: geometry is exactly what the display
  -- change invalidated.
  local putAway = false
  for _, side in ipairs(SIDES) do
    if isLive(side) and panes[side].parked then putAway = true end
  end
  if putAway then
    M.suppress(0.6)
    for _, side in ipairs(SIDES) do
      -- A minimized pane has no park frame, and un-minimizing it here would put
      -- it on screen unasked.
      local w = isLive(side) and panes[side].parked and paneWindow(side) or nil
      if w and not w:isMinimized() then parkSide(side) end
    end
    return
  end
  if M.state() == "hidden" then return end
  for _, side in ipairs(SIDES) do
    local w = paneWindow(side)
    if w and not geometry.isOnScreen(w:frame()) then
      log.i("panel was left off screen by a display change; re-laying out")
      layout(geometry.pickScreen(cfg.screenPolicy))
      return
    end
  end
  layout()
end

-- ── Persistence ────────────────────────────────────────────────────────────

--- Read the active tab out of the tab bar.
-- Not tracked from events: switching tabs emits only windowMoved, never
-- windowFocused, so there is nothing to track.  Read lazily, right before a
-- write, and matched by folder name because that is all the tab bar knows.
local function refreshActivePath(side)
  local pane = panes[side]
  local w = paneWindow(side)
  if not w then return end
  local titles, selected = finder.tabTitles(w)
  if not selected or #titles == 0 then
    -- Single-tab windows have no tab bar at all; the sole path is the active one.
    if #pane.pathList == 1 then pane.activePath = pane.pathList[1] end
    return
  end
  local want = titles[selected]
  for _, p in ipairs(pane.pathList) do
    if tabName(p) == want then
      pane.activePath = p
      return
    end
  end
end

--- Write the model down as it stands, with no Finder I/O of its own.
-- `refreshActive` asks the tab bar which tab is showing; the tab restore passes
-- false, because mid-rebuild the active tab is whichever one Finder made last and
-- the one that matters is remembered in pane.pending.activePath.
--@param refreshActive boolean
function writeState(refreshActive)
  if not cfg or not cfg.persist then return end
  local st = store.blank()
  st.minHeight = minHeight
  st.lastSide  = lastSide
  for _, side in ipairs(SIDES) do
    if refreshActive then refreshActivePath(side) end
    local pane = panes[side]
    st.panes[side] = {
      tabIds     = pane.tabIds,
      paths      = pane.pathList,
      activePath = pane.activePath,
      -- Written, not derived: pathList is index-aligned with tabIds, so it can
      -- only ever hold the tabs that exist.  Without this the recipe on disk is
      -- truncated to the pane's first tab the moment show() lays the panel out
      -- -- before a single queued tab has been made -- and anything that then
      -- interrupts the drain loses the rest for good.
      pending    = pane.pending and #pane.pending.paths > 0 and {
        paths      = pane.pending.paths,
        activePath = pane.pending.activePath,
      } or nil,
      -- Written for the same reason as pending, one step further out: this is
      -- what lets a *later* run take back a window an earlier one stranded.
      minted     = pane.minted,
    }
  end
  st.finderPid = mintedPid
  store.save(st)
end

--- Read the world, then write the current model to hs.settings.
function M.persistNow()
  if not cfg or not cfg.persist then return end
  -- The model's paths are only as fresh as the last reconcile(), and persisting
  -- can happen a long way from one: the shutdown hook and stop() are entered from
  -- outside, so a tab the user navigated in between would be written down at the
  -- folder it used to show -- and a later rebuild would reopen it there.
  -- Measured against the real Finder: navigate a tab, hs.reload(), and the
  -- persisted path is the old one.  Safe everywhere, including just after Finder
  -- died: reconcile() leaves the model alone when it cannot read a snapshot.
  -- The callers that used to reconcile immediately before this no longer do.
  M.reconcile()
  writeState(true)
end

--- Load persisted state.  No Finder I/O: this has to be safe to call the moment
--- configure() returns, so a hotkey pressed before the async permission probe
--- finishes finds a well-formed model rather than an empty table.
---
--- The ids are Finder-assigned, so as long as Finder has not restarted they
--- still name the same tabs and the first reconcile() reattaches exactly; when
--- they are all gone, pathList rebuilds the pane instead.
function M.loadState()
  panes = { left = newPane("left"), right = newPane("right") }
  local st = cfg and cfg.persist and store.load() or store.blank()
  minHeight = st.minHeight or {}
  lastSide  = st.lastSide or "left"
  for _, side in ipairs(SIDES) do
    local sp   = st.panes[side]
    local pane = panes[side]
    pane.tabIds     = sp.tabIds
    pane.pathList   = sp.paths
    pane.activePath = sp.activePath
    -- A rebuild interrupted by hs.reload() (or by a Finder that stopped
    -- answering) resumes on the next show(): completeRebuilds() drains whatever
    -- is here, and rebuildPlan() counts it in if the pane has to be made again.
    pane.pending    = sp.pending
    pane.minted     = sp.minted or {}
    pane.origin     = #sp.tabIds > 0 and "reattach" or nil
  end
  -- Trusted only against the Finder that issued them; reclaimMinted() checks.
  mintedPid = st.finderPid
end

-- ── Diagnostics and teardown ───────────────────────────────────────────────

--@return string
function M.dumpState()
  -- Read the world first.  Paths are refreshed by reconcile(), so without this a
  -- dump taken between two hotkey presses shows where a tab *was* when the panel
  -- last opened -- which is exactly the moment someone reaches for a dump.  It is
  -- read-only and no more expensive than the three plural AppleScript queries
  -- every other entry point already makes.
  M.reconcile()
  local lines = { "[DropFinder] state = " .. M.state(),
                  "  lastSide = " .. lastSide,
                  string.format("  minHeight = withToolbar %s / withoutToolbar %s",
                    tostring(minHeight.withToolbar), tostring(minHeight.withoutToolbar)),
                  "  prevApp = " .. tostring(prevAppBundleID) ..
                    (prevWindowId and (" (floating window " .. prevWindowId .. ")") or "") }
  for _, side in ipairs(SIDES) do
    local pane = panes[side]
    lines[#lines + 1] = string.format("  %s: live=%s collapsed=%s activeId=%s active=%s",
      side, tostring(isLive(side)), tostring(pane.collapsed),
      tostring(pane.activeId), tostring(pane.activePath))
    for i, id in ipairs(pane.tabIds) do
      lines[#lines + 1] = string.format("    [%d] %d  %s", i, id, tostring(pane.pathList[i]))
    end
    if #pane.tabIds == 0 and #pane.pathList > 0 then
      lines[#lines + 1] = "    (missing; will rebuild from " .. #pane.pathList .. " saved path(s))"
    end
    if pane.pending then
      lines[#lines + 1] = string.format("    queued: %d tab(s) still to restore%s (want %s)",
        #pane.pending.paths, draining[side] and ", in flight" or "",
        tostring(pane.pending.activePath))
      for i, path in ipairs(pane.pending.paths) do
        lines[#lines + 1] = string.format("      (%d) %s", i, path)
      end
    end
    if pane.frame then
      lines[#lines + 1] = string.format("    frame = %d,%d %dx%d onScreen=%s",
        pane.frame.x, pane.frame.y, pane.frame.w, pane.frame.h,
        tostring(geometry.isOnScreen(pane.frame)))
    end
  end
  return table.concat(lines, "\n")
end

--- Forget everything and start over from cfg.defaultPaths on the next show().
function M.resetState()
  store.clear()
  panes = { left = newPane("left"), right = newPane("right") }
  draining, restoresOff = { left = false, right = false }, false
  minHeight, lastSide, prevAppBundleID, prevWindowId = {}, "left", nil, nil
end

--- Called from stop(): leave no pane stranded off screen or in the Dock.
function M.restoreAll()
  -- Call off any tab restore, in flight or about to start: stop() means stop.
  -- The queue itself stays -- it has been written down at every step, and
  -- dropping it here would mean stopping the spoon silently forgot the tabs it
  -- had not made yet.
  restoresOff = true
  for _, side in ipairs(SIDES) do draining[side] = false end
  M.reconcile()
  -- Get whatever is in the Dock out of it, whichever way it got there: our own
  -- collapse under hideMode = "minimize", or the user pressing Cmd+M on a pane
  -- while the panel was up -- which happens under either hideMode, and used to
  -- leave that pane in the Dock with nothing left to explain it.
  local woke = false
  for _, side in ipairs(SIDES) do
    if isLive(side) and panes[side].collapsed then
      finder.setCollapsed(panes[side].activeId or panes[side].tabIds[1], false)
      woke = true
    end
  end
  if woke then
    -- Restoring returns the window to its pre-minimize bounds, which may be the
    -- park corner, so re-read and lay out once it is back.
    hs.timer.doAfter(0.3, function()
      M.reconcile()
      layout()
    end)
    return
  end
  for _, side in ipairs(SIDES) do
    local w = paneWindow(side)
    if w and not geometry.isOnScreen(w:frame()) then
      layout()
      break
    end
  end
end

return M
