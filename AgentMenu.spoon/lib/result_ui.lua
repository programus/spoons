--- result_ui.lua — AI response display: dialog (Markdown), clipboard, or replace

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

-- Injected by init.lua after spoon configuration.
---@type any
local templates = nil

--- Inject the templates module (called from init.lua after configure()).
--@param t table  The templates module returned by req("templates")
function M.setTemplates(t)
  templates = t
end

-- ── Dialog window state ──────────────────────────────────────────────────
---@type table|nil
local dialogWebview     = nil
local dialogUserContent = nil
local dialogIsLoading   = false   -- true while waiting for AI response
---@type function|nil
local dialogCancelFn    = nil     -- called when user closes/cancels during loading
---@type function|nil
local dialogFollowupCb  = nil     -- function(userText, messages) → called when user submits follow-up
local dialogMessages    = {}      -- conversation history: {role, content}[]

-- Compute a rect near the current mouse position, clamped to screen.
local function rectNearMouse(w, h)
  local mp     = hs.mouse.absolutePosition()
  local screen = hs.screen.mainScreen():frame()
  ---@type number
  local x = mp.x + 20
  ---@type number
  local y = mp.y + 20
  if x + w > screen.x + screen.w then x = mp.x - w - 10 end
  if y + h > screen.y + screen.h then y = mp.y - h - 10 end
  x = math.max(screen.x, x)
  y = math.max(screen.y, y)
  return { x = x, y = y, w = w, h = h }
end

local function closeDialog()
  if dialogWebview then
    dialogWebview:delete()
    dialogWebview = nil
  end
  dialogUserContent = nil
  dialogIsLoading   = false
  dialogCancelFn    = nil
  dialogFollowupCb  = nil
  dialogMessages    = {}
end

-- ── Loading HTML ──────────────────────────────────────────────────────────
local function htmlEscape(s)
  return (s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

local MAX_PREVIEW = 60

-- Returns the toolbar HTML snippet showing a truncated input text with CSS tooltip.
local function inputPreviewHtml(inputText)
  if not inputText or inputText == "" then return "" end
  local short = inputText:sub(1, MAX_PREVIEW)
  if #inputText > MAX_PREVIEW then short = short .. "\226\128\166" end
  return string.format(
    '<span class="input-preview" data-full="%s"><span class="input-preview-text">%s</span></span>',
    htmlEscape(inputText), htmlEscape(short)
  )
end

local function buildLoadingHtml(inputText)
  return templates.load("result_dialog.html", { TOOLBAR_CONTENT = inputPreviewHtml(inputText) })
end

--- Open the result dialog in "loading" state near the mouse.
-- Closing the window or clicking Cancel will invoke onCancel().
--@param inputText  string|nil  The source text to display in the toolbar
--@param onCancel   function    Called when the user dismisses during loading
--@param onFollowup function(userText: string)  Called when user submits follow-up
function M.showLoading(inputText, onCancel, onFollowup)
  closeDialog()
  dialogIsLoading  = true
  dialogCancelFn   = onCancel
  dialogFollowupCb = onFollowup
  dialogMessages   = {}

  local rect = rectNearMouse(640, 480)

  dialogUserContent = hs.webview.usercontent.new("agentMenuResult")
  dialogUserContent:setCallback(function(msg)
    local data = msg.body
    if type(data) ~= "table" then return end
    if data.action == "cancel" then
      local fn = dialogCancelFn
      closeDialog()
      if fn then fn() end
    elseif data.action == "copy" then
      hs.pasteboard.setContents(data.text or "")
      hs.alert.show(templates.t("COPIED_ALERT"))
    elseif data.action == "close" then
      closeDialog()
    elseif data.action == "followup" then
      if dialogFollowupCb then
        dialogFollowupCb(data.text or "")
      end
    end
  end)

  dialogWebview = hs.webview.new(rect, { javaScriptEnabled = true }, dialogUserContent)
  dialogWebview:windowStyle({ "titled", "closable", "resizable" })
  dialogWebview:windowTitle("AgentMenu")
  dialogWebview:closeOnEscape(true)
  dialogWebview:allowTextEntry(true)
  dialogWebview:windowCallback(function(action, _wv)
    if action == "closing" then
      local fn = dialogCancelFn
      local wasLoading = dialogIsLoading
      closeDialog()
      if wasLoading and fn then fn() end
    end
  end)
  dialogWebview:html(buildLoadingHtml(inputText))
  dialogWebview:show()
  dialogWebview:bringToFront(false)
  hs.timer.doAfter(0.1, function()
    if dialogWebview then
      local win = dialogWebview:hswindow()
      if win then win:focus() end
    end
  end)
end

--- Close the loading dialog without triggering the cancel callback.
-- Call this when the AI returns an error so the spinner disappears.
function M.hideLoading()
  if dialogIsLoading then
    closeDialog()
  end
end

--- Append a streaming text chunk to the loading dialog.
-- Hides the spinner on first call and appends text to the current AI turn.
--@param chunkText string  The new text delta to append
function M.appendChunk(chunkText)
  if not dialogWebview or not dialogIsLoading then return end
  local encoded   = hs.json.encode({ chunkText })
  local jsonChunk = encoded:match("^%[(.-)%]$") or encoded
  dialogWebview:evaluateJavaScript("appendStreamChunk(" .. jsonChunk .. ");")
end

--- Signal that streaming is complete: hide spinner, show follow-up input, enable send button.
function M.streamDone()
  if not dialogWebview then return end
  dialogWebview:evaluateJavaScript("showFollowup(); document.getElementById('btn-send') && (document.getElementById('btn-send').disabled = false);")
end


-- ── Dialog window ─────────────────────────────────────────────────────────

--- Display the AI result according to the specified output mode.
-- For "dialog" mode when a loading window is open, streaming is already complete:
-- we just reveal the follow-up input area.
--@param text           string   The AI-generated text
--@param mode           string   "dialog" | "clipboard" | "replace"
--@param replaceFallback string  "dialog" | "clipboard" — used when replace fails
--@param selectedText   string|nil  Original selected text (for replace mode)
--@param inputText      string|nil  Source text shown in toolbar
function M.show(text, mode, replaceFallback, selectedText, inputText, modelName, providerName)
  replaceFallback = replaceFallback or "dialog"
  local titleSuffix = modelName and (" — " .. modelName .. (providerName and (" (" .. providerName .. ")") or "")) or ""

  if mode == "clipboard" then
    closeDialog()
    hs.pasteboard.setContents(text)
    hs.alert.show(templates.t("COPIED_ALERT"))

  elseif mode == "replace" then
    local replaced = false
    pcall(function()
      local sysEl  = hs.axuielement.systemWideElement()
      local focused = sysEl:attributeValue("AXFocusedUIElement")
      if focused then
        local settable = focused:isAttributeSettable("AXSelectedText")
        if settable then
          focused:setAttributeValue("AXSelectedText", text)
          replaced = true
        end
      end
    end)
    if replaced then
      closeDialog()
    else
      M.show(text, replaceFallback, "dialog", selectedText, inputText, modelName, providerName)
    end

  else  -- "dialog" (default)
    if dialogWebview and dialogIsLoading then
      -- Streaming already painted the text into the chat area.
      -- Just finalize: update title, show follow-up box.
      dialogIsLoading = false
      dialogCancelFn  = nil
      dialogWebview:windowTitle("AgentMenu Result" .. titleSuffix)
      M.streamDone()
    else
      -- No loading window open (non-streaming fallback): open a fresh dialog
      -- that uses the same chat layout, pre-populated with one AI turn.
      closeDialog()
      local rect = rectNearMouse(640, 480)

      -- We reuse the loading HTML but pre-inject the content immediately.
      local encoded   = hs.json.encode({ text })
      local jsonText  = encoded:match("^%[(.-)%]$") or encoded

      dialogUserContent = hs.webview.usercontent.new("agentMenuResult")
      dialogUserContent:setCallback(function(msg)
        local data = msg.body
        if type(data) ~= "table" then return end
        if data.action == "copy" then
          hs.pasteboard.setContents(data.text or text)
          hs.alert.show(templates.t("COPIED_ALERT"))
        elseif data.action == "close" or data.action == "cancel" then
          closeDialog()
        elseif data.action == "followup" then
          if dialogFollowupCb then dialogFollowupCb(data.text or "") end
        end
      end)

      dialogWebview = hs.webview.new(rect, { javaScriptEnabled = true }, dialogUserContent)
      dialogWebview:windowStyle({ "titled", "closable", "resizable" })
      dialogWebview:windowTitle("AgentMenu Result" .. titleSuffix)
      dialogWebview:closeOnEscape(true)
      dialogWebview:allowTextEntry(true)
      dialogWebview:windowCallback(function(action, _wv)
        if action == "closing" then closeDialog() end
      end)
      -- Load the standard loading HTML then immediately inject the AI turn
      dialogWebview:html(buildLoadingHtml(inputText))
      dialogWebview:show()
      dialogWebview:bringToFront(false)
      hs.timer.doAfter(0.05, function()
        if dialogWebview then
          local win = dialogWebview:hswindow()
          if win then win:focus() end
        end
      end)
      -- Inject text after a short delay so the page has initialised
      hs.timer.doAfter(0.15, function()
        if not dialogWebview then return end
        dialogIsLoading = true  -- needed so appendChunk works
        M.appendChunk(text)
        dialogIsLoading = false
        M.streamDone()
      end)
    end
  end
end

--- Prepare the dialog for a new follow-up AI response.
-- Call this just before starting the streaming call for a follow-up.
function M.startFollowupLoading()
  if not dialogWebview then return end
  dialogIsLoading = true
  -- The JS side already appended the loading-row when the user clicked Send.
  -- Re-enable streaming by making sure dialogIsLoading=true (done above).
end

return M
