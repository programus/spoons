--- === DropFinder ===
---
--- A TotalFinder-style Visor for vanilla Finder: one hotkey drops two Finder
--- windows in from the bottom of the screen, side by side and half width each,
--- so files can be dragged between them.  Press it again to put them away.
---
--- The two windows are real Finder windows whose position DropFinder manages —
--- Hammerspoon cannot lift another app's windows into a floating layer, so the
--- panel can be covered by other windows, and losing focus does not hide it.
--- Every other Finder window is left strictly alone: never moved, resized,
--- minimized or closed.
---
--- Usage:
---   local cfg = require("dropfinder_config")   -- your config file, optional
---   spoon.DropFinder:configure(cfg):start()
---
--- See config_example.lua for the full configuration reference.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "DropFinder"
obj.version  = "0.1"
obj.author   = "programus <programus@gmail.com>"
obj.homepage = "https://github.com/programus/spoons"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

-- ── Module loading (relative to this spoon's directory) ───────────────────
local function req(name)
  return dofile(hs.spoons.resourcePath("lib/" .. name .. ".lua"))
end

local log = hs.logger.new("DropFinder", "info")

-- ── Private state ──────────────────────────────────────────────────────────
---@type any
local cfg = nil   -- normalised config
---@type table
local hotkeys = {}
---@type boolean
local started = false

-- Lazy-load lib modules after the spoon path is known
---@type any
local configLib
---@type any
local geometry
---@type any
local store
---@type any
local finder
---@type any
local panel
---@type any
local watchers

local function loadLibs()
  configLib = req("config")
  geometry  = req("geometry")
  store     = req("store")
  finder    = req("finder")
  panel     = req("panel")
  watchers  = req("watchers")
end

-- ── Public API ─────────────────────────────────────────────────────────────

--- Configure the spoon.  Must be called before start().
--@param rawConfig table|nil  See config_example.lua; every field has a default
--@return DropFinder  self (for chaining)
function obj:configure(rawConfig)
  loadLibs()
  cfg = configLib.loadConfig(rawConfig)

  store.setLogger(hs.logger.new("DropFinder.store", "info"))
  finder.setLogger(hs.logger.new("DropFinder.finder", "info"))

  panel.setDeps({ finder = finder, geometry = geometry, store = store,
                  log = hs.logger.new("DropFinder.panel", "info") })
  panel.setConfig(cfg)
  -- Synchronous and Finder-free, so the model is well formed even if the hotkey
  -- is pressed before start()'s permission probe has answered.
  panel.loadState()

  watchers.setDeps({ panel = panel, log = hs.logger.new("DropFinder.watchers", "info") })
  watchers.setConfig(cfg)

  return self
end

--- Start the spoon: check permissions, adopt any panes we still recognise, bind
--- hotkeys and subscribe to Finder's window events.
--@return DropFinder  self
function obj:start()
  if not cfg then
    error("[DropFinder] call :configure(config) before :start()")
  end
  if started then return self end

  -- ── TotalFinder ───────────────────────────────────────────────────────
  -- TotalFinder injects into Finder and replaces its tab model: every tab
  -- becomes a real AX window.  DropFinder identifies panes by which tabs belong
  -- to them, so under TotalFinder it misreads Finder completely.  The two also
  -- compete for the same screen real estate.  Warn, but start anyway — the user
  -- may be mid-migration.
  if cfg.warnOnTotalFinder then
    finder.totalFinderInjected(function(injected)
      if not injected then return end
      local msg = "[DropFinder] TotalFinder is injected into Finder. " ..
                  "DropFinder targets vanilla Finder and will misbehave — " ..
                  "quit TotalFinder and restart Finder."
      log.w(msg)
      hs.alert.show(msg, 6)
    end)
  end

  -- ── Accessibility ─────────────────────────────────────────────────────
  -- Deliberately not hs.accessibilityState(true): that pops a system dialog on
  -- every reload.  Log it, say it once, and start anyway; every AX read is
  -- behind a pcall.
  if not hs.accessibilityState() then
    local msg = "[DropFinder] needs Accessibility: System Settings > " ..
                "Privacy & Security > Accessibility > Hammerspoon"
    log.e(msg)
    hs.alert.show(msg, 6)
  end

  -- ── Automation (AppleEvents) ──────────────────────────────────────────
  -- Probed lazily and asynchronously: the first AppleScript call triggers the
  -- consent prompt, and a denial is permanent (-1743 from then on), so the
  -- message has to name the exact place to fix it.
  hs.timer.doAfter(0.1, function()
    if not cfg then return end
    local ok, err = finder.automationAvailable()
    if not ok then
      local msg = "[DropFinder] needs Automation access to Finder: System " ..
                  "Settings > Privacy & Security > Automation > Hammerspoon > Finder"
      log.e(msg .. "  (" .. tostring(err) .. ")")
      hs.alert.show(msg, 8)
      return
    end
    -- Reattach to the panes we persisted.  Safe here: Finder has answered once,
    -- so its AX server is warm.
    panel.reconcile()
    log.d("\n" .. panel.dumpState())
  end)

  watchers.start()

  -- ── Hotkeys ───────────────────────────────────────────────────────────
  local spec = {
    toggle = function() obj.toggle() end,
    adopt  = function() obj.adoptFrontmost() end,
  }
  for name, fn in pairs(spec) do
    local hk = cfg.hotkeys[name]
    if hk then
      hotkeys[name] = hs.hotkey.bind(hk.mods, hk.key, fn)
    end
  end

  started = true
  return self
end

--- Stop the spoon: unbind hotkeys, drop every watcher, and leave no pane
--- stranded off screen or in the Dock.
--@return DropFinder  self
function obj:stop()
  if not started then return self end
  if panel then
    pcall(panel.persistNow)
    pcall(panel.restoreAll)
  end
  if watchers then watchers.stop() end
  for name, hk in pairs(hotkeys) do
    hk:delete()
    hotkeys[name] = nil
  end
  started = false
  return self
end

--- Tri-state toggle: hidden → show and focus; showing but unfocused → raise and
--- focus; showing and focused → hide.
function obj.toggle()
  if not cfg then return end
  local ok, err = pcall(panel.toggle)
  if not ok then log.e("toggle: " .. tostring(err)) end
end

--- Show the panel on the policy screen and focus it.
function obj.show()
  if cfg then pcall(panel.show) end
end

--- Put the panel away and hand focus back to the app that had it.
function obj.hide()
  if cfg then pcall(panel.hide) end
end

--- Merge the frontmost floating Finder window into the panel as tab(s).
-- Order and paths are preserved; scroll position, selection and per-tab
-- back/forward history are not -- the tabs are rebuilt, not moved.
--@return boolean started, string|nil err
function obj.adoptFrontmost()
  if not cfg then return false, "DropFinder is not started" end
  -- `began` rather than `started`: the module-level `started` is the spoon's own
  -- lifecycle flag, and shadowing it here would be asking for trouble later.
  local ok, began, err = pcall(panel.adoptFrontmost)
  if not ok then
    log.e("adopt failed: " .. tostring(began))
    return false, tostring(began)
  end
  -- Every refusal is about what the user pressed it on, not a fault: say which.
  if not began then hs.alert.show("[DropFinder] " .. tostring(err)) end
  return began, err
end

--- The panel's current tri-state, for scripting and for debugging from `hs -c`.
--@return string  "hidden" | "shown_unfocused" | "shown_focused"
function obj.state()
  if not cfg then return "hidden" end
  local ok, s = pcall(panel.state)
  return ok and s or "hidden"
end

--- Print the current pane model to the Hammerspoon console.
--@return string
function obj.dumpState()
  if not cfg then return "[DropFinder] not configured" end
  local s = panel.dumpState()
  print(s)
  return s
end

--- Forget all persisted state; the next show() starts from cfg.defaultPaths.
function obj.resetState()
  if cfg then panel.resetState() end
end

--- Bind hotkeys described in a map (Hammerspoon Spoon convention).
--- Replaces whatever cfg.hotkeys bound.
--@param mapping table  e.g. { toggle = {{"ctrl","alt"}, "f"} }
function obj:bindHotkeys(mapping)
  local def = {
    toggle          = obj.toggle,
    adopt_frontmost = obj.adoptFrontmost,
  }
  for name, hk in pairs(hotkeys) do
    hk:delete()
    hotkeys[name] = nil
  end
  hs.spoons.bindHotkeysToSpec(def, mapping)
end

return obj
