--- result_ui.lua — AI response display: dialog (Markdown), clipboard, or replace
--
-- The dialog is a single, persistent hs.webview that is built and loaded once
-- (ideally pre-warmed at start-up) and then hidden/shown for each request.
-- Two reasons, and they are the same reason:
--
--   • Performance — a WKWebView cold start per invocation was the bulk of the
--     "feels slow" delay.
--   • Correctness — hs.webview:html() loads asynchronously.  With a fresh
--     webview per request, the first evaluateJavaScript() calls raced the page
--     load and were silently discarded by WebKit, so short/fast answers could
--     vanish entirely and leave the window stuck on "Thinking ●●●".
--
-- On top of that, every JS call goes through evalJS(), which queues anything
-- issued before didFinishNavigation, and M.show() always writes the complete
-- Lua-side text via setTurnContent() — so the result is displayed even if not
-- a single stream chunk made it to the page.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local log = hs.logger.new("AgentMenu.result", "debug")

local M = {}

-- Injected by init.lua after spoon configuration.
---@type any
local templates = nil

--- Inject the templates module (called from init.lua after configure()).
--@param t table  The templates module returned by req("templates")
function M.setTemplates(t)
  templates = t
end

-- Injected by init.lua; used for the dialog's "replace" button.
---@type any
local selection = nil

--- Inject the selection module (called from init.lua after configure()).
--@param s table  The selection module returned by req("selection")
function M.setSelection(s)
  selection = s
end

-- The element + selection range this run may write back into, captured before
-- the chooser and this dialog stole focus.  nil when the source field was not
-- writable, in which case the button stays hidden.
---@type table|nil
local replaceTarget = nil

-- ── Dialog window state ──────────────────────────────────────────────────
---@type table|nil
local webview     = nil
---@type table|nil
local usercontent = nil
local pageReady   = false   -- true once didFinishNavigation fired
local pendingJS   = {}      -- JS queued while the page was still loading
local visible     = false   -- window is on screen
local isLoading   = false   -- waiting for (more of) an AI response

-- Every request gets a token.  Late callbacks from a superseded or cancelled
-- request compare unequal and are dropped, so two overlapping invocations can
-- never paint into each other's window.
local runToken    = 0

---@type function|nil
local cbCancel    = nil     -- user closed/cancelled while loading
---@type function|nil
local cbFollowup  = nil     -- user submitted a follow-up question
---@type function|nil
local cbRetry     = nil     -- user clicked Retry on an error row

-- Streaming deltas are coalesced into one evaluateJavaScript per interval
-- instead of one per token (each call is a cross-process hop).
local FLUSH_INTERVAL = 0.05
local chunkBuf   = {}
---@type table|nil
local flushTimer = nil

-- Window geometry: position follows the mouse, size follows the user's last resize.
local DEFAULT_W, DEFAULT_H = 640, 480
local lastSize = { w = DEFAULT_W, h = DEFAULT_H }

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

-- ── JavaScript plumbing ───────────────────────────────────────────────────

-- Encode a Lua string as a JSON string literal usable as a JS argument.
-- Returns nil when the value cannot be encoded (e.g. invalid UTF-8) instead of
-- blowing up in the caller.
local function jsStr(s)
  local ok, encoded = pcall(hs.json.encode, { s or "" })
  if not ok or type(encoded) ~= "string" then
    log.w("jsStr: could not JSON-encode value (" .. type(s) .. ")")
    return nil
  end
  return encoded:match("^%[(.-)%]$")
end

local function evalJS(js)
  if not webview then return end
  if not pageReady then
    pendingJS[#pendingJS + 1] = js
    return
  end
  webview:evaluateJavaScript(js, function(_result, jsErr)
    if jsErr then
      -- Used to fail silently; a JS-side ReferenceError is exactly how the
      -- "result never appears" bug hid itself.
      log.e("evalJS failed: " .. tostring(jsErr.localizedDescription or jsErr.description or "?")
        .. " — while running: " .. js:sub(1, 120))
    end
  end)
end

-- Call a JS function with a single string argument, skipping the call when the
-- argument cannot be encoded.
local function callJS(fn, arg, extraArg)
  local a = jsStr(arg)
  if not a then return end
  if extraArg ~= nil then
    local b = jsStr(extraArg)
    if not b then return end
    evalJS(fn .. "(" .. a .. ", " .. b .. ");")
  else
    evalJS(fn .. "(" .. a .. ");")
  end
end

-- ── Stream chunk batching ─────────────────────────────────────────────────
local function cancelFlushTimer()
  if flushTimer then
    flushTimer:stop()
    flushTimer = nil
  end
end

local function flushChunks()
  cancelFlushTimer()
  if #chunkBuf == 0 then return end
  local text = table.concat(chunkBuf)
  chunkBuf = {}
  callJS("appendStreamChunk", text)
end

local function scheduleFlush()
  if flushTimer then return end
  flushTimer = hs.timer.doAfter(FLUSH_INTERVAL, flushChunks)
end

local function discardChunks()
  cancelFlushTimer()
  chunkBuf = {}
end

-- ── Replace ───────────────────────────────────────────────────────────────

--- Write `text` over the original selection.
-- Prefers the target captured before focus moved (that is the only thing that
-- still works once this dialog is up).  Apps that quietly ignore the write get
-- a paste instead.  Asynchronous, because that fallback has to wait for the
-- other app to come forward.
--@param text  string
--@param cb    function(ok, reason)
--@param allowFocusFallback boolean  Write into whatever has focus when no target
--       was captured.  Only safe with no dialog in between (outputMode =
--       "replace"); from the dialog the focused element is this window.
local function doReplace(text, cb, allowFocusFallback)
  cb = cb or function() end
  if replaceTarget then
    local target = replaceTarget
    local ok, reason = selection.applyReplace(target, text)
    if ok then
      replaceTarget = nil                -- one-shot: the selection is gone now
      return cb(true)
    end
    if reason == "ignored" then
      -- The app accepted the write and dropped it (Slack's message box, and
      -- Electron editors generally).  Paste it in instead.
      return selection.pasteReplace(target, text, function(pok, preason)
        if pok then replaceTarget = nil end
        cb(pok, preason)
      end)
    end
    return cb(false, reason)
  end
  if not allowFocusFallback then return cb(false, "no-target") end
  local ok = false
  pcall(function()
    local focused = hs.axuielement.systemWideElement():attributeValue("AXFocusedUIElement")
    if focused and focused:isAttributeSettable("AXSelectedText") then
      focused:setAttributeValue("AXSelectedText", text)
      ok = true
    end
  end)
  return cb(ok, ok and nil or "no-target")
end

-- ── Webview construction ──────────────────────────────────────────────────

local function handleMessage(msg)
  local data = msg.body
  if type(data) ~= "table" then return end

  if data.action == "cancel" then
    -- Close button / Escape.  While loading this aborts the request; otherwise
    -- it is just "close the window".
    local fn = isLoading and cbCancel or nil
    M.hide()
    runToken = runToken + 1   -- invalidate: a late result must not re-open this
    if fn then fn() end

  elseif data.action == "copy" then
    hs.pasteboard.setContents(data.text or "")
    hs.alert.show(templates.t("COPIED_ALERT"))

  elseif data.action == "replace" then
    -- Deliberately left open on success.  Replacing does not always land where
    -- the user expects, and closing here would take the answer with it; the
    -- button just marks itself done so it cannot fire twice.
    doReplace(data.text or "", function(ok, reason)
      if ok then
        evalJS("replaceDone();")
        hs.alert.show(templates.t("REPLACED_ALERT"))
      else
        hs.alert.show(templates.t(reason == "stale" and "REPLACE_STALE_ALERT" or "REPLACE_FAILED_ALERT"))
        evalJS("resetReplaceBtn();")
      end
    end)

  elseif data.action == "close" then
    M.hide()

  elseif data.action == "followup" then
    if cbFollowup then cbFollowup(data.text or "") end

  elseif data.action == "retry" then
    if cbRetry then cbRetry() end
  end
end

local function buildWebview()
  pageReady = false
  pendingJS = {}

  usercontent = hs.webview.usercontent.new("agentMenuResult")
  usercontent:setCallback(handleMessage)

  local wv = hs.webview.new(
    { x = 0, y = 0, w = lastSize.w, h = lastSize.h },
    { javaScriptEnabled = true },
    usercontent)
  wv:windowStyle({ "titled", "closable", "resizable" })
  wv:windowTitle("AgentMenu")
  -- Escape is handled in JS (see result_dialog.html); letting the webview close
  -- itself would tear down the window while Lua still thinks it owns it.
  wv:closeOnEscape(false)
  wv:allowTextEntry(true)

  wv:navigationCallback(function(action, _wv, _navID, navErr)
    if action == "didFinishNavigation" then
      pageReady = true
      local queued = pendingJS
      pendingJS = {}
      log.d("result dialog: page ready, flushing " .. #queued .. " queued JS call(s)")
      for _, js in ipairs(queued) do
        wv:evaluateJavaScript(js)
      end
    elseif action == "didFailNavigation" or action == "didFailProvisionalNavigation" then
      log.e("result dialog: page load failed: " ..
        tostring(navErr and (navErr.localizedDescription or navErr.description) or "?"))
      pendingJS = {}
    end
  end)

  wv:windowCallback(function(action, _wv, arg)
    if action == "closing" then
      -- The user hit the red button.  Keep the object (we re-show it later),
      -- but treat it as a cancel for the in-flight request.
      local fn = isLoading and cbCancel or nil
      visible   = false
      isLoading = false
      discardChunks()
      runToken  = runToken + 1   -- invalidate: late chunks must not resurrect it
      cbCancel, cbFollowup, cbRetry = nil, nil, nil
      if fn then fn() end
    elseif action == "frameChange" and type(arg) == "table" then
      if arg.w and arg.h and arg.w > 100 and arg.h > 100 then
        lastSize = { w = arg.w, h = arg.h }
      end
    end
  end)

  webview = wv

  local i18nJson = hs.json.encode({
    THINKING     = templates.t("THINKING_LABEL"),
    COPY_TURN    = templates.t("COPY_TURN_TITLE"),
    COPY_CONFIRM = templates.t("COPY_CONFIRM_LABEL"),
    REPLACE      = templates.t("REPLACE_LABEL"),
    REPLACE_BUSY = templates.t("REPLACE_BUSY_LABEL"),
    REPLACE_DONE = templates.t("REPLACE_CONFIRM_LABEL"),
  })
  wv:html(templates.load("result_dialog.html", { I18N_JSON = i18nJson }))
end

--- Build the dialog and load its page ahead of first use.
-- Safe to call repeatedly; only the first call does work.
function M.preload()
  if webview then return end
  if not templates then
    log.w("preload: called before setTemplates(); skipping")
    return
  end
  log.d("result dialog: pre-warming webview")
  buildWebview()
end

-- Make sure a usable webview exists and is on screen.
local function ensureShown()
  if not webview then buildWebview() end

  local rect = rectNearMouse(lastSize.w, lastSize.h)
  ---@type table
  local wv = webview
  wv:frame(rect)
  wv:show()
  wv:bringToFront(false)

  local win = wv:hswindow()
  if not win then
    -- The window was destroyed under us (previous close released it).  Rebuild
    -- from scratch; queued JS is replayed once the fresh page finishes loading.
    log.w("result dialog: window gone after show(); rebuilding webview")
    local queued = pendingJS
    webview     = nil
    usercontent = nil
    buildWebview()
    pendingJS = queued
    ---@type table
    local wv2 = webview
    wv2:frame(rect)
    wv2:show()
    wv2:bringToFront(false)
    win = wv2:hswindow()
  end

  visible = true
  if win then
    win:focus()
  else
    -- Focus may not be grantable on the very first show; try once more shortly.
    hs.timer.doAfter(0.1, function()
      if webview and visible then
        local w2 = webview:hswindow()
        if w2 then w2:focus() end
      end
    end)
  end
end

-- ── Run lifecycle ─────────────────────────────────────────────────────────

--- Begin a new request.  Invalidates any previous one and returns the token
--- that must be passed to every subsequent call for this request.
--@return number token
function M.newRun()
  runToken = runToken + 1
  discardChunks()
  isLoading = false
  cbCancel, cbFollowup, cbRetry = nil, nil, nil
  replaceTarget = nil
  return runToken
end

--- Register the write-back target for `token` (see selection.captureReplaceTarget).
--@param token  number
--@param target table|nil
function M.setReplaceTarget(token, target)
  if token ~= runToken then return end
  replaceTarget = target
end

--- Return true when `token` still refers to the current request.
--@param token number
function M.isCurrent(token)
  return token == runToken
end

--- Show the result dialog in "loading" state near the mouse.
--@param token      number    Token from newRun()
--@param inputText  string|nil Source text shown in the toolbar
--@param handlers   table     { onCancel, onFollowup, onRetry } — all optional
function M.showLoading(token, inputText, handlers)
  if token ~= runToken then return end
  handlers   = handlers or {}
  isLoading  = true
  cbCancel   = handlers.onCancel
  cbFollowup = handlers.onFollowup
  cbRetry    = handlers.onRetry
  discardChunks()

  ensureShown()
  webview:windowTitle("AgentMenu")
  callJS("resetDialog", inputText or "")
  -- Booleans do not survive callJS()'s string quoting; emit the literal.
  evalJS("setReplaceAvailable(" .. tostring(replaceTarget ~= nil) .. ");")
end

--- Append a streaming text delta.  Buffered and flushed on a short timer.
--@param token     number
--@param chunkText string
function M.appendChunk(token, chunkText)
  if token ~= runToken or not isLoading then return end
  if type(chunkText) ~= "string" or chunkText == "" then return end
  chunkBuf[#chunkBuf + 1] = chunkText
  scheduleFlush()
end

--- Prepare the dialog for another AI response within the same conversation.
--@param token         number
--@param onCancel      function|nil  Re-arms cancellation for the new request
--@param addLoadingRow boolean|nil   True when JS has not already added one
--                                   (i.e. the retry path, not the Send button)
function M.startFollowupLoading(token, onCancel, addLoadingRow)
  if token ~= runToken then return end
  isLoading = true
  cbCancel  = onCancel          -- was dropped when the previous turn finished
  discardChunks()
  if addLoadingRow then
    evalJS("appendLoadingRow();")
  end
end

--- Show an error (or warning) without destroying the window or its history.
--@param token     number
--@param msg       string        Human-readable error detail
--@param retryable boolean|nil   Offer a Retry button
function M.showError(token, msg, retryable)
  if token ~= runToken then return end
  isLoading = false
  flushChunks()
  if not visible then ensureShown() end
  local retryLabel = retryable and templates.t("RETRY_LABEL") or ""
  callJS("showError", tostring(msg or ""), retryLabel)
end

--- Hide the dialog without invoking the cancel callback.
-- The page stays loaded, ready for the next request.
function M.hide()
  discardChunks()
  isLoading = false
  cbCancel, cbFollowup, cbRetry = nil, nil, nil
  if webview and visible then
    webview:hide()
  end
  visible = false
end

--- Backwards-compatible alias: previously destroyed the loading window.
function M.hideLoading()
  M.hide()
end

--- Tear the dialog down completely (used by AgentMenu:stop()).
function M.destroy()
  discardChunks()
  if webview then
    webview:delete()
    webview = nil
  end
  usercontent = nil
  pageReady   = false
  pendingJS   = {}
  visible     = false
  isLoading   = false
  cbCancel, cbFollowup, cbRetry = nil, nil, nil
end

--- True when the dialog window is currently on screen.
function M.isVisible()
  return visible
end

-- ── Result presentation ───────────────────────────────────────────────────

--- Display the AI result according to the specified output mode.
--@param token          number   Token from newRun()
--@param text           string   The AI-generated text
--@param mode           string   "dialog" | "clipboard" | "replace"
--@param replaceFallback string  "dialog" | "clipboard" — used when replace fails
--@param selectedText   string|nil  Original selected text (for replace mode)
--@param inputText      string|nil  Source text shown in toolbar
function M.show(token, text, mode, replaceFallback, selectedText, inputText, modelName, providerName)
  if token ~= runToken then
    log.d("show: dropping stale result (token " .. tostring(token) .. " ≠ " .. runToken .. ")")
    return
  end
  replaceFallback = replaceFallback or "dialog"
  text = text or ""
  local titleSuffix = modelName
    and (" — " .. modelName .. (providerName and (" (" .. providerName .. ")") or ""))
    or ""

  if mode == "clipboard" then
    M.hide()
    hs.pasteboard.setContents(text)
    hs.alert.show(templates.t("COPIED_ALERT"))
    return
  end

  if mode == "replace" then
    doReplace(text, function(replaced)
      if replaced then
        M.hide()
      else
        M.show(token, text, replaceFallback, "dialog", selectedText, inputText, modelName, providerName)
      end
    end, true)
    return
  end

  -- "dialog" (default)
  isLoading = false
  if not visible then
    -- Only reachable for a non-streaming path or after outputMode fallback.
    ensureShown()
    callJS("resetDialog", inputText or "")
  end
  flushChunks()                     -- drain anything still buffered
  callJS("setTurnContent", text)    -- authoritative: independent of the stream
  evalJS("showFollowup();")
  if webview then
    webview:windowTitle("AgentMenu Result" .. titleSuffix)
  end
end

return M
