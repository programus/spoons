--- === AgentMenu ===
---
--- AI Agent toolbar and hotkey menu for Hammerspoon.
--- Supports OpenAI-compatible APIs, configurable actions,
--- floating selection toolbar, and hotkey-triggered chooser.
---
--- Usage:
---   local cfg = require("agentmenu_config")   -- your config file
---   spoon.AgentMenu:configure(cfg):start()
---
--- See config_example.lua for full configuration reference.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "AgentMenu"
obj.version  = "0.1"
obj.author   = "programus <programus@gmail.com>"
obj.homepage = "https://github.com/programus/spoons"
obj.license  = "MIT - https://opensource.org/licenses/MIT"

-- ── Module loading (relative to this spoon's directory) ───────────────────
local function req(name)
  return dofile(hs.spoons.resourcePath("lib/" .. name .. ".lua"))
end

-- ── Private state ──────────────────────────────────────────────────────────
local cfg          = nil   -- normalised config
local selectionWatcher = nil
local hotkey       = nil
local chooser      = nil

-- Lazy-load lib modules after spoon path is known
local configLib
local utils
local ai
local selection
local popup
local paramDialog
local resultUI

local function loadLibs()
  configLib   = req("config")
  utils       = req("utils")
  ai          = req("ai")
  selection   = req("selection")
  popup       = req("popup")
  paramDialog = req("param_dialog")
  resultUI    = req("result_ui")
end

-- ── Core action runner ─────────────────────────────────────────────────────
local log = hs.logger.new("AgentMenu", "debug")

--- Execute a named action with the given pre-resolved selected text.
--@param actionName  string
--@param selectedText string|nil
local function runAction(actionName, selectedText)
  log.d("runAction: '" .. tostring(actionName) .. "'  selectedText=" .. tostring(selectedText and #selectedText .. " chars" or "nil"))
  local act = cfg._actionByName[actionName]
  if not act then
    hs.alert.show("[AgentMenu] unknown action: " .. tostring(actionName))
    log.e("unknown action: " .. tostring(actionName))
    return
  end

  -- 1. Resolve built-in params
  local builtins = {
    selection = selectedText and selectedText ~= "" and selectedText or nil,
    clipboard = hs.pasteboard.getContents(),
  }

  -- 2. Filter out built-in params from user-defined parameters (they need dialog)
  local userParams = {}
  for _, p in ipairs(act.parameters) do
    if not (p.isBuiltin or utils.BUILTINS[p.name]) then
      userParams[#userParams + 1] = p
    end
  end

  -- 3. Show param dialog (skipped when userParams is empty)
  log.d("runAction: showing param dialog, userParams count=" .. #userParams)
  paramDialog.show(userParams, function(dialogErr, userValues)
    if dialogErr == "cancelled" then
      log.d("runAction: param dialog cancelled")
      return
    end

    -- 4. Merge: builtins + user-entered values (user wins on conflict)
    local allParams = utils.merge(builtins, userValues or {})

    -- Resolve the display text shown in the toolbar (selection > clipboard > "")
    local inputText = builtins.selection or builtins.clipboard or ""

    -- 5. Fill template
    local prompt = utils.fillTemplate(act.prompt, allParams)
    log.d("runAction: filled prompt (" .. #prompt .. " chars): " .. prompt:sub(1, 200))

    -- 6. Open dialog in loading state near mouse; Cancel button aborts the response
    local cancelled = false
    resultUI.showLoading(inputText, function()
      log.d("runAction: cancelled by user")
      cancelled = true
    end)

    -- 7. Call AI
    log.d("runAction: calling AI, profile='" .. tostring(act.modelSetProfile) .. "'")
    local messages = { { role = "user", content = prompt } }
    ai.call(cfg, act.modelSetProfile, messages, function(aiErr, result, modelName, providerName)
      if cancelled then return end
      -- 8. Handle result
      if aiErr then
        log.e("runAction: AI error: " .. tostring(aiErr))
        resultUI.hideLoading()
        hs.alert.show("[AgentMenu] " .. aiErr)
        return
      end
      log.d("runAction: AI success, result " .. tostring(result and #result .. " chars" or "nil"))
      resultUI.show(
        result,
        act.outputMode,
        act.replaceFallback or cfg.replaceFallback,
        selectedText,
        inputText,
        modelName,
        providerName
      )
    end)
  end)
end

-- ── Public API ─────────────────────────────────────────────────────────────

--- Configure the spoon.  Must be called before start().
--@param rawConfig table  See config_example.lua for schema
--@return AgentMenu  self (for chaining)
function obj:configure(rawConfig)
  loadLibs()
  cfg = configLib.loadConfig(rawConfig)
  return self
end

--- Start the spoon: register selection watcher and hotkey.
--@return AgentMenu  self
function obj:start()
  if not cfg then
    error("[AgentMenu] call :configure(config) before :start()")
  end

  -- ── Floating toolbar (selection watcher) ──────────────────────────────
  local toolbarActionNames = cfg.toolbar.actions or {}
  if #toolbarActionNames > 0 then
    local toolbarActions = {}
    for _, name in ipairs(toolbarActionNames) do
      local act = cfg._actionByName[name]
      if act then
        toolbarActions[#toolbarActions + 1] = { name = act.name, label = act.label }
      end
    end

    popup.setOnAction(function(actionName)
      local text = selection.getSelectedText()
      runAction(actionName, text)
    end)

    selectionWatcher = selection.watchSelection(
      function(text, rect)
        -- text is non-empty, show toolbar
        popup.show(toolbarActions, nil)
      end,
      function()
        popup.hide()
      end
    )
    selectionWatcher.start()
  end

  -- ── Hotkey chooser ────────────────────────────────────────────────────
  local hkCfg = cfg.hotkey
  if hkCfg then
    local hotkeyActionNames = hkCfg.actions or {}
    local hotkeyActions = {}
    for _, name in ipairs(hotkeyActionNames) do
      local act = cfg._actionByName[name]
      if act then
        hotkeyActions[#hotkeyActions + 1] = { text = act.label, subText = act.name }
      end
    end

    if #hotkeyActions > 0 then
      chooser = hs.chooser.new(function(choice)
        if not choice then return end
        local text = selection.getSelectedText()
        runAction(choice.subText, text)
      end)
      chooser:choices(hotkeyActions)
      chooser:placeholderText("Select an action…")

      hotkey = hs.hotkey.bind(hkCfg.mods, hkCfg.key, function()
        -- Capture selection before chooser steals focus
        local text = selection.getSelectedText()
        chooser:choices(hotkeyActions)
        -- Override callback to close with captured selection
        chooser = hs.chooser.new(function(choice)
          if not choice then return end
          runAction(choice.subText, text)
        end)
        chooser:choices(hotkeyActions)
        chooser:placeholderText("Select an action…")
        chooser:show()
      end)
    end
  end

  return self
end

--- Stop the spoon: remove all watchers and hotkeys.
--@return AgentMenu  self
function obj:stop()
  if selectionWatcher then
    selectionWatcher.stop()
    selectionWatcher = nil
  end
  if hotkey then
    hotkey:delete()
    hotkey = nil
  end
  if chooser then
    chooser:delete()
    chooser = nil
  end
  if popup then popup.hide() end
  if resultUI then
    resultUI.hideLoading()
  end
  return self
end

--- Bind hotkeys described in a map (Hammerspoon convention).
--@param mapping table  e.g. { showChooser = {{"ctrl","alt"}, "a"} }
function obj:bindHotkeys(mapping)
  -- Currently the hotkey is configured declaratively in the config table.
  -- This method is provided for Hammerspoon Spoon API compatibility.
  if mapping.showChooser then
    local mods, key = table.unpack(mapping.showChooser)
    if hotkey then hotkey:delete() end
    local hkCfg = cfg and cfg.hotkey
    if hkCfg then
      local captured = nil
      hotkey = hs.hotkey.bind(mods, key, function()
        captured = selection.getSelectedText()
        local acts = {}
        for _, name in ipairs(hkCfg.actions or {}) do
          local act = cfg._actionByName[name]
          if act then acts[#acts + 1] = { text = act.label, subText = act.name } end
        end
        local c = hs.chooser.new(function(choice)
          if choice then runAction(choice.subText, captured) end
        end)
        c:choices(acts)
        c:placeholderText("Select an action…")
        c:show()
      end)
    end
  end
end

return obj
