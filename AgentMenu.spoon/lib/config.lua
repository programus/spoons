--- config.lua — Configuration loading and validation for AgentMenu.spoon

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

local BUILTIN_NAMES = { selection = true, clipboard = true }

local function err(msg)
  error("[AgentMenu] config error: " .. msg, 2)
end

local function assertField(tbl, key, tblName)
  if tbl[key] == nil then
    err(string.format("'%s' is required in %s", key, tblName))
  end
end

--- Validate and normalise a raw config table.
-- Sets defaults for optional fields.  Raises an error (via error()) on bad input.
--@param raw table  Raw user config
--@return table     Normalised config
function M.loadConfig(raw)
  if type(raw) ~= "table" then
    err("config must be a table")
  end

  -- ── providers ────────────────────────────────────────────────────────────
  assertField(raw, "providers", "config")
  if #raw.providers == 0 then err("'providers' must not be empty") end
  local providerByName = {}
  for i, p in ipairs(raw.providers) do
    assertField(p, "name",    string.format("providers[%d]", i))
    assertField(p, "baseUrl", string.format("providers[%d]", i))
    assertField(p, "apiKey",  string.format("providers[%d]", i))
    -- Normalise: strip trailing slash from baseUrl
    p.baseUrl = p.baseUrl:gsub("/+$", "")
    providerByName[p.name] = p
  end

  -- ── models ───────────────────────────────────────────────────────────────
  -- Each model has:
  --   name     — the model identifier sent to the API (e.g. "gpt-4o")
  --   provider — which provider to call
  --   id       — (optional) unique reference used in modelSetProfiles/actions;
  --              defaults to `name` when omitted.  Use `id` to distinguish two
  --              models with the same API name from different providers.
  assertField(raw, "models", "config")
  if #raw.models == 0 then err("'models' must not be empty") end
  local modelById = {}
  for i, m in ipairs(raw.models) do
    assertField(m, "name",     string.format("models[%d]", i))
    assertField(m, "provider", string.format("models[%d]", i))
    -- Default id to name when not provided
    m.id = m.id or m.name
    if not providerByName[m.provider] then
      err(string.format("models[%d].provider '%s' not found in providers", i, m.provider))
    end
    if modelById[m.id] then
      err(string.format("models[%d].id '%s' is duplicated", i, m.id))
    end
    modelById[m.id] = m
  end

  -- ── modelSetProfiles ─────────────────────────────────────────────────────
  assertField(raw, "modelSetProfiles", "config")
  if #raw.modelSetProfiles == 0 then err("'modelSetProfiles' must not be empty") end
  local profileByName = {}
  for i, prof in ipairs(raw.modelSetProfiles) do
    assertField(prof, "name",         string.format("modelSetProfiles[%d]", i))
    assertField(prof, "primaryModel", string.format("modelSetProfiles[%d]", i))
    if not modelById[prof.primaryModel] then
      err(string.format("modelSetProfiles[%d].primaryModel '%s' not found in models (check id)",
        i, prof.primaryModel))
    end
    for j, fb in ipairs(prof.fallbacks or {}) do
      if not modelById[fb] then
        err(string.format("modelSetProfiles[%d].fallbacks[%d] '%s' not found in models (check id)",
          i, j, fb))
      end
    end
    prof.fallbacks = prof.fallbacks or {}
    profileByName[prof.name] = prof
  end
  local defaultProfile = raw.modelSetProfiles[1].name

  -- ── replaceFallback (global) ─────────────────────────────────────────────
  local replaceFallback = raw.replaceFallback or "dialog"
  if replaceFallback ~= "dialog" and replaceFallback ~= "clipboard" then
    err("replaceFallback must be 'dialog' or 'clipboard'")
  end

  -- ── actions ──────────────────────────────────────────────────────────────
  assertField(raw, "actions", "config")
  if #raw.actions == 0 then err("'actions' must not be empty") end
  local actionByName = {}
  for i, act in ipairs(raw.actions) do
    local ctx = string.format("actions[%d]", i)
    assertField(act, "name",   ctx)
    assertField(act, "label",  ctx)
    assertField(act, "prompt", ctx)

    -- Defaults
    act.parameters      = act.parameters or {}
    act.outputMode      = act.outputMode or "dialog"
    act.modelSetProfile = act.modelSetProfile or defaultProfile
    act.replaceFallback = act.replaceFallback or replaceFallback

    if act.outputMode ~= "dialog" and act.outputMode ~= "clipboard" and act.outputMode ~= "replace" then
      err(string.format("%s.outputMode must be 'dialog', 'clipboard', or 'replace'", ctx))
    end
    if not profileByName[act.modelSetProfile] then
      err(string.format("%s.modelSetProfile '%s' not found in modelSetProfiles",
        ctx, act.modelSetProfile))
    end

    -- Validate parameters; mark built-ins
    act._hasMultilineParam = false
    for j, param in ipairs(act.parameters) do
      assertField(param, "name", string.format("%s.parameters[%d]", ctx, j))
      param.isBuiltin = BUILTIN_NAMES[param.name] == true
      param.label     = param.label or param.name
      param.default   = param.default or ""
      -- multiline: opt in to the HTML form (a textarea) instead of the native
      -- chooser.  Hammerspoon has no native multi-line text field, so this is
      -- the only way to accept more than one line of input.
      if param.multiline ~= nil and type(param.multiline) ~= "boolean" then
        err(string.format("%s.parameters[%d].multiline must be a boolean", ctx, j))
      end
      param.multiline = param.multiline == true
      if param.multiline and not param.isBuiltin then
        act._hasMultilineParam = true
      end
      -- options: optional list of strings for combobox suggestions
      if param.options ~= nil then
        if type(param.options) ~= "table" then
          err(string.format("%s.parameters[%d].options must be a table", ctx, j))
        end
        for k, opt in ipairs(param.options) do
          if type(opt) ~= "string" then
            err(string.format("%s.parameters[%d].options[%d] must be a string", ctx, j, k))
          end
        end
      end
    end

    -- Does this action actually need the clipboard?  Reading the pasteboard on
    -- every invocation copies its whole contents for nothing when the prompt
    -- never references {{clipboard}}.
    act._usesClipboard = false
    for expr in tostring(act.prompt):gmatch("{{([^}]+)}}") do
      for segment in expr:gmatch("[^|]+") do
        if segment:match("^%s*(.-)%s*$") == "clipboard" then
          act._usesClipboard = true
        end
      end
    end
    for _, param in ipairs(act.parameters) do
      if param.name == "clipboard" then act._usesClipboard = true end
    end

    actionByName[act.name] = act
  end

  -- ── quick-menu (accepts both "quick-menu" and legacy "toolbar") ──────────
  -- "quick-menu" takes priority; "toolbar" is kept for backward compatibility.
  local quickMenu = raw["quick-menu"] or raw.toolbar or {}
  quickMenu.actions = quickMenu.actions or {}
  for i, name in ipairs(quickMenu.actions) do
    if not actionByName[name] then
      err(string.format("quick-menu.actions[%d] '%s' not found in actions", i, name))
    end
  end

  -- ── hotkey ───────────────────────────────────────────────────────────────
  local hotkey = raw.hotkey or nil
  if hotkey then
    assertField(hotkey, "mods", "hotkey")
    assertField(hotkey, "key",  "hotkey")
    hotkey.actions = hotkey.actions or {}
    for i, name in ipairs(hotkey.actions) do
      if not actionByName[name] then
        err(string.format("hotkey.actions[%d] '%s' not found in actions", i, name))
      end
    end
  end

  -- ── lang (optional) ──────────────────────────────────────────────────────
  -- ISO 639-1 language code for UI strings.  Defaults to "en".
  -- Supported: "en", "zh".  Add res/i18n/<lang>.lua to support more languages.
  local lang = raw.lang or "en"

  -- ── preloadWebview (optional) ────────────────────────────────────────────
  -- Build the result window a couple of seconds after start() instead of on
  -- first use.  Costs one resident WebContent process (~40 MB) and removes a
  -- WKWebView cold start from every invocation.
  local preloadWebview = raw.preloadWebview
  if preloadWebview == nil then preloadWebview = true end
  if type(preloadWebview) ~= "boolean" then
    err("preloadWebview must be a boolean")
  end

  -- ── axTimeout (optional) ─────────────────────────────────────────────────
  -- Accessibility messaging timeout in seconds.  The system default is 6s, and
  -- an unresponsive app blocks Hammerspoon's main thread for that whole time
  -- while we read the selection.  0 leaves the system default untouched.
  -- Note: this changes the *global* AX default, so it affects other spoons too.
  local axTimeout = raw.axTimeout
  if axTimeout == nil then axTimeout = 0.5 end
  if type(axTimeout) ~= "number" or axTimeout < 0 then
    err("axTimeout must be a non-negative number (seconds; 0 = leave system default)")
  end

  -- ── Return normalised config ─────────────────────────────────────────────
  return {
    providers       = raw.providers,
    models          = raw.models,
    modelSetProfiles = raw.modelSetProfiles,
    replaceFallback = replaceFallback,
    actions         = raw.actions,
    lang            = lang,
    preloadWebview  = preloadWebview,
    axTimeout       = axTimeout,
    toolbar         = quickMenu,  -- internal field; populated from "quick-menu" or legacy "toolbar"
    hotkey          = hotkey,
    -- Lookup tables for quick access
    _providerByName = providerByName,
    _modelById      = modelById,
    _profileByName  = profileByName,
    _actionByName   = actionByName,
  }
end

return M
