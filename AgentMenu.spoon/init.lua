--- === AgentMenu ===
---
--- AI Agent quick-menu and hotkey chooser for Hammerspoon.
--- Supports OpenAI-compatible APIs, configurable actions,
--- floating quick-menu on text selection, and hotkey-triggered chooser.
---
--- When text is selected a small dot appears near the selection.
--- Hovering the dot expands it to a circular button; clicking opens a menu.
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
---@type any
local cfg          = nil   -- normalised config
---@type table|nil
local selectionWatcher = nil
---@type table|nil
local hotkey       = nil
---@type table|nil
local chooser      = nil
---@type string|nil
local capturedSelection = nil   -- selection captured before the chooser took focus

-- Lazy-load lib modules after spoon path is known
---@type any
local configLib
---@type any
local utils
---@type any
local ai
---@type any
local selection
---@type any
local popup
---@type any
local paramDialog
---@type any
local paramChooser
---@type any
local resultUI
---@type any
local templates

local function loadLibs()
  configLib    = req("config")
  utils        = req("utils")
  ai           = req("ai")
  selection    = req("selection")
  popup        = req("popup")
  paramDialog  = req("param_dialog")
  paramChooser = req("param_chooser")
  resultUI     = req("result_ui")
  templates    = req("templates")
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

  -- 1. Resolve built-in params.  The clipboard is only read when this action's
  --    prompt actually references it — reading it copies the whole pasteboard.
  local sel  = (selectedText and selectedText ~= "") and selectedText or nil
  local clip = act._usesClipboard and hs.pasteboard.getContents() or nil
  local builtins = { selection = sel, clipboard = clip }

  -- 2. Ask for the user-defined parameters.  Native chooser by default; the
  --    HTML form only for actions that declare a multiline parameter, since
  --    Hammerspoon has no native multi-line text input.
  local paramUI     = act._hasMultilineParam and paramDialog or paramChooser
  local paramUIName = act._hasMultilineParam and "param_dialog" or "param_chooser"
  log.d("runAction: collecting params via " .. paramUIName)

  paramUI.show(act.parameters, function(dialogErr, userValues)
    if dialogErr == "cancelled" then
      log.d("runAction: param input cancelled")
      return
    end

    -- 3. Merge: builtins + user-entered values (user wins on conflict)
    local allParams = utils.merge(builtins, userValues or {})

    -- Text shown in the result window's toolbar
    local inputText = sel or clip or ""

    -- 4. Fill template
    local prompt = utils.fillTemplate(act.prompt, allParams)
    log.d("runAction: filled prompt (" .. #prompt .. " chars): " .. prompt:sub(1, 200))

    -- Conversation history accumulates across follow-ups
    local messages = { { role = "user", content = prompt } }

    -- 5. Claim the result window for this request.  Every later call carries
    --    the token, so a superseded or cancelled request can never paint into
    --    the window that now belongs to a newer one.
    local token = resultUI.newRun()

    -- Cancellation: `activeFlag` always points at the in-flight attempt's flag,
    -- while each attempt's callbacks close over their own copy.
    local activeFlag   = { false }
    ---@type function|nil
    local activeCancel = nil

    local function onCancel()
      log.d("runAction: cancelled by user")
      activeFlag[1] = true
      if activeCancel then activeCancel() end
    end

    -- ── Streaming AI call (used for the initial call, follow-ups and retries) ──
    local function callAI()
      log.d("runAction: calling AI (stream), profile='" .. tostring(act.modelSetProfile) .. "'")
      local flag = { false }
      activeFlag = flag
      activeCancel = ai.callStream(cfg, act.modelSetProfile, messages,
        function(chunkText)
          if not flag[1] then
            resultUI.appendChunk(token, chunkText)
          end
        end,
        function(aiErr, result, modelName, providerName, warning)
          if flag[1] then return end
          if aiErr then
            -- Keep the window and the conversation; offer a retry.  Destroying
            -- the window here (as this used to) looked exactly like "the result
            -- never showed up".
            log.e("runAction: AI error: " .. tostring(aiErr))
            resultUI.showError(token,
              templates.t("ERROR_PREFIX") .. ": " .. tostring(aiErr), true)
            return
          end
          log.d("runAction: AI success, result " .. tostring(result and #result .. " chars" or "nil"))
          -- Append assistant turn to conversation history
          messages[#messages + 1] = { role = "assistant", content = result }
          resultUI.show(
            token,
            result,
            act.outputMode,
            act.replaceFallback or cfg.replaceFallback,
            selectedText,
            inputText,
            modelName,
            providerName
          )
          if warning and warning.kind == "incomplete" then
            resultUI.showError(token,
              templates.t("INCOMPLETE_WARNING") .. " (" .. tostring(warning.detail) .. ")", false)
          end
        end
      )
    end

    local function onFollowup(userText)
      if not userText or userText == "" then return end
      log.d("runAction: follow-up: " .. userText)
      messages[#messages + 1] = { role = "user", content = userText }
      -- The JS side already added the loading row when Send was clicked.
      resultUI.startFollowupLoading(token, onCancel, false)
      callAI()
    end

    local function onRetry()
      -- Nothing was appended to `messages` on failure, so the same request can
      -- simply be sent again.
      log.d("runAction: retry requested")
      resultUI.startFollowupLoading(token, onCancel, true)
      callAI()
    end

    -- 6. Open the dialog in loading state near the mouse
    resultUI.showLoading(token, inputText, {
      onCancel   = onCancel,
      onFollowup = onFollowup,
      onRetry    = onRetry,
    })

    -- 7. Initial AI call
    callAI()
  end)
end

-- ── Public API ─────────────────────────────────────────────────────────────

--- Configure the spoon.  Must be called before start().
--@param rawConfig table  See config_example.lua for schema
--@return AgentMenu  self (for chaining)
function obj:configure(rawConfig)
  loadLibs()
  cfg = configLib.loadConfig(rawConfig)
  templates.setLang(cfg.lang)
  resultUI.setTemplates(templates)
  paramDialog.setTemplates(templates)
  paramChooser.setTemplates(templates)
  return self
end

--- Start the spoon: register selection watcher and hotkey.
--@return AgentMenu  self
function obj:start()
  if not cfg then
    error("[AgentMenu] call :configure(config) before :start()")
  end

  -- ── Accessibility messaging timeout ───────────────────────────────────
  -- Default is 6s; an unresponsive app would block the main thread for that
  -- long on every selection read.
  selection.setAxTimeout(cfg.axTimeout)

  -- ── Pre-warm the result window ────────────────────────────────────────
  -- Deferred so it never slows down Hammerspoon's config load.  This is both a
  -- speed-up (no WKWebView cold start per invocation) and the reason streamed
  -- output can no longer race the page load.
  if cfg.preloadWebview then
    hs.timer.doAfter(2, function()
      if cfg then resultUI.preload() end
    end)
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
      function(_text, _getRect)
        -- text is non-empty; show quick-menu dot near current mouse position.
        -- _getRect resolves the selection bounds on demand — deliberately not
        -- called: it is the most expensive Accessibility query available.
        popup.show(toolbarActions, nil)
      end,
      function()
        popup.hide()
      end,
      function()
        -- yield mouseDown to popup whenever it is active
        return popup.isActive()
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
      -- One instance, built once.  The selection is captured by the hotkey
      -- handler (before the chooser takes focus) and read back here.
      chooser = hs.chooser.new(function(choice)
        local text = capturedSelection
        capturedSelection = nil
        if not choice then return end
        runAction(choice.subText, text)
      end)
      chooser:choices(hotkeyActions)
      chooser:placeholderText(templates.t("CHOOSER_PLACEHOLDER"))

      hotkey = hs.hotkey.bind(hkCfg.mods, hkCfg.key, function()
        capturedSelection = selection.getSelectedText()
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
  capturedSelection = nil
  if popup then popup.destroy() end
  if paramChooser then paramChooser.destroy() end
  if resultUI then resultUI.destroy() end
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
      -- Build the chooser once.  Creating one inside the hotkey handler leaked a
      -- panel per keypress and left stop() only able to release the last one.
      local acts = {}
      for _, name in ipairs(hkCfg.actions or {}) do
        local act = cfg._actionByName[name]
        if act then acts[#acts + 1] = { text = act.label, subText = act.name } end
      end
      if chooser then chooser:delete() end
      chooser = hs.chooser.new(function(choice)
        local text = capturedSelection
        capturedSelection = nil
        if not choice then return end
        runAction(choice.subText, text)
      end)
      chooser:choices(acts)
      chooser:placeholderText(templates.t("CHOOSER_PLACEHOLDER"))

      hotkey = hs.hotkey.bind(mods, key, function()
        capturedSelection = selection.getSelectedText()
        chooser:show()
      end)
    end
  end
end

return obj
