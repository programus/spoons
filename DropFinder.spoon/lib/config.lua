--- config.lua — Validation and default merging for DropFinder.spoon
-- Every field has a default, so an empty table is a valid config.
-- See config_example.lua for the annotated reference.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

local function err(msg)
  error("[DropFinder] config error: " .. msg, 2)
end

--- Fill in `key` from `defaults` when absent, then type-check it.
-- Booleans are tested against nil rather than truthiness so that an explicit
-- `false` survives the merge.
local function pick(raw, defaults, key, expected)
  local v = raw[key]
  if v == nil then v = defaults[key] end
  if type(v) ~= expected then
    err(string.format("'%s' must be a %s, got %s", key, expected, type(v)))
  end
  return v
end

local function oneOf(key, value, allowed)
  for _, a in ipairs(allowed) do
    if value == a then return value end
  end
  err(string.format("'%s' must be one of %s, got %q",
    key, '"' .. table.concat(allowed, '", "') .. '"', tostring(value)))
end

--- Expand a leading `~` and resolve to an absolute path.
-- Returns nil when the path does not resolve to a directory: Finder errors out
-- on `make new Finder window to` a nonexistent path, so we never pass one on.
--@param p string
--@return string|nil
function M.resolveDir(p)
  if type(p) ~= "string" or p == "" then return nil end
  local home = os.getenv("HOME") or ""
  local expanded = p:gsub("^~", home)
  local abs = hs.fs.pathToAbsolute(expanded)
  if not abs then return nil end
  if hs.fs.attributes(abs, "mode") ~= "directory" then return nil end
  return abs
end

local DEFAULTS = {
  heightRatio        = 0.25,
  bottomGap          = 0,
  paneGap            = 0,
  hideMode           = "park",
  parkCorner         = "bottom-right",
  parkMaxVisible     = 5000,
  hideToolbar        = false,
  screenPolicy       = "mouse",
  restoreFocusOnHide = true,
  restoreTabs        = true,
  crossSpace         = true,
  crossSpaceFallback = "recreate",
  snapBack           = false,
  adoptTarget        = "mouse",
  persist            = true,
  frameTolerance     = 4,
  settleDelay        = 0.15,
  -- Requirement 6 says the panel stays put when focus moves away, so nothing
  -- reads this yet; the key exists so that changing one's mind later is a
  -- config edit rather than a config schema change.
  hideOnFocusLoss    = false,
  warnOnTotalFinder  = true,
}

local HOTKEY_DEFAULTS = {
  toggle = { { mods = { "ctrl", "alt" },          key = "f" } },
  adopt  = { { mods = { "ctrl", "alt", "shift" }, key = "f" } },
}

--- Type-check one { mods = {...}, key = "x" } spec and copy it.
local function hotkeySpec(name, i, hk)
  if type(hk) ~= "table" or type(hk.mods) ~= "table" or type(hk.key) ~= "string" then
    err(string.format('\'hotkeys.%s\'%s must be { mods = {...}, key = "x" }',
      name, i and string.format(" entry %d", i) or ""))
  end
  return { mods = hk.mods, key = hk.key }
end

--- Normalise one action's hotkeys to a list of specs.
-- An action answers to any number of keys: the TotalFinder key one hand already
-- knows and a laptop-friendly one do not have to fight over a single binding.
-- Accepts one spec, a list of specs, or `false` to bind nothing.
--@return table  list of { mods = {...}, key = "x" }, possibly empty
local function hotkeyList(name, hk)
  if hk == nil then hk = HOTKEY_DEFAULTS[name] end
  if hk == false then return {} end
  if type(hk) ~= "table" then
    err(string.format('\'hotkeys.%s\' must be { mods = {...}, key = "x" }, ' ..
      "a list of those, or false", name))
  end
  -- A single spec names its fields, a list numbers them; `mods` or `key` present
  -- at the top level is the one shape a list can never have.
  if hk.mods ~= nil or hk.key ~= nil then return { hotkeySpec(name, nil, hk) } end
  local out = {}
  for i, one in ipairs(hk) do out[i] = hotkeySpec(name, i, one) end
  -- Silently binding nothing would look like a broken hotkey rather than a
  -- choice; `false` is how one asks for that.
  if #out == 0 then
    err(string.format("'hotkeys.%s' is an empty list; use false to bind nothing", name))
  end
  return out
end

--- Validate a raw config table and return a normalised copy.
--@param raw table|nil
--@return table
function M.loadConfig(raw)
  raw = raw or {}
  if type(raw) ~= "table" then err("config must be a table") end

  local cfg = {}

  cfg.heightRatio = pick(raw, DEFAULTS, "heightRatio", "number")
  if cfg.heightRatio <= 0 or cfg.heightRatio > 1 then
    err("'heightRatio' must be in (0, 1]")
  end

  for _, key in ipairs({ "bottomGap", "paneGap", "parkMaxVisible", "frameTolerance", "settleDelay" }) do
    cfg[key] = pick(raw, DEFAULTS, key, "number")
    if cfg[key] < 0 then err(string.format("'%s' must be >= 0", key)) end
  end

  for _, key in ipairs({ "hideToolbar", "restoreFocusOnHide", "restoreTabs", "crossSpace",
                         "snapBack", "persist", "hideOnFocusLoss", "warnOnTotalFinder" }) do
    cfg[key] = pick(raw, DEFAULTS, key, "boolean")
  end

  cfg.hideMode = oneOf("hideMode",
    pick(raw, DEFAULTS, "hideMode", "string"), { "park", "minimize", "lower", "hide" })
  cfg.parkCorner = oneOf("parkCorner",
    pick(raw, DEFAULTS, "parkCorner", "string"), { "bottom-right", "bottom-left" })
  cfg.screenPolicy = oneOf("screenPolicy",
    pick(raw, DEFAULTS, "screenPolicy", "string"), { "mouse", "focused", "main" })
  cfg.crossSpaceFallback = oneOf("crossSpaceFallback",
    pick(raw, DEFAULTS, "crossSpaceFallback", "string"), { "activate", "recreate" })
  cfg.adoptTarget = oneOf("adoptTarget",
    pick(raw, DEFAULTS, "adoptTarget", "string"), { "mouse", "left", "right", "lastFocused" })

  -- ── Default directories ───────────────────────────────────────────────
  -- Resolved once here so panel.lua never has to think about `~` or about a
  -- path that vanished between reloads.  A side whose default is unusable
  -- falls back to $HOME rather than failing the whole config: the spoon is
  -- still useful, and the log line says which side degraded.
  local rawPaths = raw.defaultPaths or {}
  if type(rawPaths) ~= "table" then err("'defaultPaths' must be a table") end
  local fallbackDefaults = { left = "~/Downloads", right = "~" }
  cfg.defaultPaths = {}
  for _, side in ipairs({ "left", "right" }) do
    local want = rawPaths[side] or fallbackDefaults[side]
    if type(want) ~= "string" then
      err(string.format("'defaultPaths.%s' must be a string", side))
    end
    cfg.defaultPaths[side] = M.resolveDir(want)
      or M.resolveDir("~")
      or "/"
  end

  -- ── Hotkeys ───────────────────────────────────────────────────────────
  local rawHotkeys = raw.hotkeys or {}
  if type(rawHotkeys) ~= "table" then err("'hotkeys' must be a table") end
  cfg.hotkeys = {}
  for _, name in ipairs({ "toggle", "adopt" }) do
    cfg.hotkeys[name] = hotkeyList(name, rawHotkeys[name])
  end

  return cfg
end

return M
