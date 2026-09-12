--- store.lua — Persistent state for DropFinder.spoon
-- Backed by hs.settings (NSUserDefaults): atomic writes for free, ~25 lines
-- instead of ~70 for a JSON file under hs.configdir.  Readability is bought
-- back by the public DropFinder:dumpState() / :resetState().
--
-- Note on shape: each pane stores `tabIds` and `paths` as two arrays aligned by
-- index rather than an id -> path map.  A plist dictionary can only have string
-- keys, so integer keys would come back as strings and silently stop matching
-- the ids read from Finder.  Aligned arrays also carry the tab-bar order that
-- would otherwise need a third field.
--
-- Because of that alignment, `paths` can only ever describe tabs that already
-- exist.  A pane rebuilt from a recipe of 8 folders is on screen with 1 tab and
-- 7 still to make, so the other 7 live in `pending` -- and they have to be
-- written down too, or an interrupted rebuild (Finder still waking, hs.reload(),
-- a crash) loses them.  Added after v1 shipped, so it is read defensively and a
-- state without it stays valid rather than being thrown away.
--
-- `minted` is the third list and the odd one out: not part of the model, but a
-- record of which window ids DropFinder itself created.  It exists because
-- forgetting one is not a harmless loss of bookkeeping -- the window stays on
-- screen, in the panel's own slot, and nothing is then entitled to move or close
-- it.  Read defensively for the same reason as `pending`.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

local KEY     = "DropFinder.state.v1"
local VERSION = 1

---@type any
local log = hs.logger.new("DropFinder.store", "info")

function M.setLogger(l) log = l end

local function emptyPane()
  return { tabIds = {}, paths = {}, activePath = nil, pending = nil, minted = {} }
end

--- A fresh state table.  Also the shape every other module may assume.
--@return table
function M.blank()
  return {
    version   = VERSION,
    minHeight = {},          -- { withToolbar = n, withoutToolbar = n } once measured
    lastSide  = "left",
    finderPid = nil,         -- pid the panes' minted ids were issued by
    panes     = { left = emptyPane(), right = emptyPane() },
  }
end

--- Coerce whatever came out of NSUserDefaults into the documented shape.
-- Anything unexpected is dropped rather than repaired: a stale field that half
-- survives is harder to debug than a clean rebuild from cfg.defaultPaths.
local function normalise(raw)
  local st = M.blank()
  if type(raw) ~= "table" or raw.version ~= VERSION then return st end

  if type(raw.minHeight) == "table" then
    for _, k in ipairs({ "withToolbar", "withoutToolbar" }) do
      if type(raw.minHeight[k]) == "number" then st.minHeight[k] = raw.minHeight[k] end
    end
  end
  if raw.lastSide == "left" or raw.lastSide == "right" then st.lastSide = raw.lastSide end
  -- The pid the minted ids belong to.  Without it a Finder restarted while
  -- Hammerspoon was not running could hand a fresh window a remembered number.
  if type(raw.finderPid) == "number" then st.finderPid = math.floor(raw.finderPid) end

  local rawPanes = type(raw.panes) == "table" and raw.panes or {}
  for _, side in ipairs({ "left", "right" }) do
    local rp = type(rawPanes[side]) == "table" and rawPanes[side] or {}
    local ids   = type(rp.tabIds) == "table" and rp.tabIds or {}
    local paths = type(rp.paths)  == "table" and rp.paths  or {}
    local pane  = st.panes[side]
    if #ids == 0 then
      -- A pane whose window was closed (or whose ids died with Finder) keeps its
      -- paths with no ids at all: that list is the recipe show() rebuilds it
      -- from, so dropping it here would lose requirement 5.
      for _, p in ipairs(paths) do
        if type(p) == "string" and p ~= "" then pane.paths[#pane.paths + 1] = p end
      end
    else
      -- Otherwise keep only index-aligned pairs; a ragged tail means a torn write.
      for i = 1, math.min(#ids, #paths) do
        local id, p = tonumber(ids[i]), paths[i]
        if id and type(p) == "string" and p ~= "" then
          pane.tabIds[#pane.tabIds + 1] = math.floor(id)
          pane.paths[#pane.paths + 1]   = p
        end
      end
    end
    if type(rp.activePath) == "string" and rp.activePath ~= "" then
      pane.activePath = rp.activePath
    end

    -- Every id DropFinder has ever minted for this side and not seen closed.
    -- Kept apart from tabIds because it is a *provenance* record, not a model:
    -- reconcile drops an id the moment Finder stops listing it, and a window we
    -- made that Finder merely failed to mention is then stranded on screen
    -- forever, in the panel's own slot, with nothing entitled to touch it.
    -- Requirement 4 is about the user's floating windows; a window whose id is
    -- in this list is demonstrably not one of those.
    local minted = type(rp.minted) == "table" and rp.minted or {}
    for _, id in ipairs(minted) do
      local n = tonumber(id)
      if n then pane.minted[#pane.minted + 1] = math.floor(n) end
    end

    local pend = type(rp.pending) == "table" and rp.pending or nil
    if pend then
      local queued = {}
      local raw = type(pend.paths) == "table" and pend.paths or {}
      for _, p in ipairs(raw) do
        if type(p) == "string" and p ~= "" then queued[#queued + 1] = p end
      end
      if #queued > 0 then
        local want = type(pend.activePath) == "string" and pend.activePath ~= ""
        pane.pending = { paths = queued, activePath = want and pend.activePath or nil }
      end
    end
  end
  return st
end

--- Read persisted state, or a blank state when absent/stale/corrupt.
--@return table
function M.load()
  local ok, raw = pcall(hs.settings.get, KEY)
  if not ok then
    log.w("settings read failed, starting from blank state")
    return M.blank()
  end
  return normalise(raw)
end

--- Write state.  Silently no-ops when persistence is disabled by the caller.
--@param st table
--@return boolean
function M.save(st)
  local ok, e = pcall(hs.settings.set, KEY, st)
  if not ok then
    log.e("settings write failed: " .. tostring(e))
    return false
  end
  return true
end

--- Forget everything.
function M.clear()
  pcall(hs.settings.clear, KEY)
end

return M
