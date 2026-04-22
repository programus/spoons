--- result_ui.lua — AI response display: dialog (Markdown), clipboard, or replace

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

-- ── Dialog window state ──────────────────────────────────────────────────
local dialogWebview     = nil
local dialogUserContent = nil
local dialogIsLoading   = false   -- true while waiting for AI response
local dialogCancelFn    = nil     -- called when user closes/cancels during loading
local dialogFollowupCb  = nil     -- function(userText, messages) → called when user submits follow-up
local dialogMessages    = {}      -- conversation history: {role, content}[]

-- Compute a rect near the current mouse position, clamped to screen.
local function rectNearMouse(w, h)
  local mp     = hs.mouse.absolutePosition()
  local screen = hs.screen.mainScreen():frame()
  local x = mp.x + 20
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
  if #inputText > MAX_PREVIEW then short = short .. "…" end
  return string.format(
    '<span class="input-preview" data-full="%s"><span class="input-preview-text">%s</span></span>',
    htmlEscape(inputText), htmlEscape(short)
  )
end

-- Shared toolbar CSS (embedded in both loading and result HTML).
local TOOLBAR_CSS = [[
:root {
  --bg:        #f5f5f5;
  --bg2:       #e8e8e8;
  --bg3:       #d0d0d0;
  --border:    #ccc;
  --text:      #111;
  --text-dim:  #666;
  --btn-bg:    #ddd;
  --btn-text:  #111;
  --accent:    #0a84ff;
  --shadow:    rgba(0,0,0,0.15);
  --pre-bg:    #ececec;
  --user-bg:   #e0edff;
  --ai-bg:     #f5f5f5;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg:        #1e1e1e;
    --bg2:       #252525;
    --bg3:       #2d2d2d;
    --border:    #444;
    --text:      #e0e0e0;
    --text-dim:  #888;
    --btn-bg:    #3a3a3a;
    --btn-text:  #e0e0e0;
    --accent:    #0a84ff;
    --shadow:    rgba(0,0,0,0.6);
    --pre-bg:    #2d2d2d;
    --user-bg:   #1a2a40;
    --ai-bg:     #1e1e1e;
  }
}
#toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  background: var(--bg2);
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
}
.input-preview {
  flex: 1;
  min-width: 0;
  color: var(--text-dim);
  font-size: 12px;
  cursor: default;
  position: relative;
}
.input-preview-text {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  display: block;
}
.input-preview::after {
  content: attr(data-full);
  position: absolute;
  top: calc(100% + 5px);
  left: 0;
  background: var(--bg3);
  color: var(--text);
  padding: 6px 10px;
  border-radius: 5px;
  border: 1px solid var(--border);
  box-shadow: 0 2px 8px var(--shadow);
  white-space: pre-wrap;
  word-break: break-all;
  max-width: 420px;
  font-size: 12px;
  z-index: 999;
  display: none;
  pointer-events: none;
}
.input-preview:hover::after { display: block; }
button {
  flex-shrink: 0;
  padding: 4px 14px;
  border-radius: 5px;
  border: none;
  font-size: 12px;
  cursor: pointer;
}
#btn-cancel, #btn-close { background: var(--btn-bg); color: var(--btn-text); }
#btn-copy { background: var(--accent); color: #fff; }
button:hover { opacity: 0.85; }
]]

local function buildLoadingHtml(inputText)
  return string.format([[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { height: 100%%; display: flex; flex-direction: column; }
body {
  font-family: -apple-system, Helvetica, sans-serif;
  font-size: 14px;
  background: var(--bg);
  color: var(--text);
}
%s
#chat {
  flex: 1;
  overflow-y: auto;
  padding: 12px 16px;
  display: flex;
  flex-direction: column;
  gap: 0;
}
.turn {
  padding: 10px 14px;
  line-height: 1.6;
  white-space: pre-wrap;
  word-break: break-word;
}
.turn-ai   { background: var(--ai-bg); }
.turn-user { background: var(--user-bg); font-size: 13px; }
#loading-row {
  padding: 10px 14px;
  background: var(--ai-bg);
  color: var(--text-dim);
  font-size: 15px;
  display: flex;
  align-items: center;
  gap: 8px;
}
.dot { animation: blink 1.2s infinite; display: inline-block; }
.dot:nth-child(2) { animation-delay: 0.2s; }
.dot:nth-child(3) { animation-delay: 0.4s; }
@keyframes blink { 0%%,80%%,100%%{opacity:0.2} 40%%{opacity:1} }
#followup-area {
  display: none;
  flex-shrink: 0;
  border-top: 1px solid var(--border);
  padding: 8px 12px;
  background: var(--bg2);
  gap: 6px;
  align-items: flex-end;
}
#followup-input {
  flex: 1;
  resize: none;
  background: var(--bg);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 5px;
  padding: 6px 8px;
  font-family: inherit;
  font-size: 13px;
  line-height: 1.5;
  min-height: 32px;
  max-height: 120px;
  overflow-y: auto;
}
#followup-input:focus { outline: none; border-color: var(--accent); }
#btn-send {
  flex-shrink: 0;
  background: var(--accent);
  color: #fff;
  border: none;
  border-radius: 5px;
  padding: 5px 12px;
  font-size: 12px;
  cursor: pointer;
  align-self: flex-end;
}
#btn-send:hover { opacity: 0.85; }
#btn-send:disabled { opacity: 0.4; cursor: default; }
</style>
</head>
<body>
<div id="toolbar">
  %s
  <button id="btn-cancel" onclick="cancelAction()">Cancel</button>
</div>
<div id="chat">
  <div id="loading-row">
    Thinking
    <span class="dot">●</span><span class="dot">●</span><span class="dot">●</span>
  </div>
</div>
<div id="followup-area">
  <textarea id="followup-input" rows="1" placeholder="继续追问… (Cmd+Enter 发送)"></textarea>
  <button id="btn-send" onclick="sendFollowup()">发送</button>
</div>
<script>
var streamDiv = null;

function cancelAction() {
  webkit.messageHandlers.agentMenuResult.postMessage({ action: "cancel" });
}

function appendStreamChunk(text) {
  var chat = document.getElementById("chat");
  var loading = document.getElementById("loading-row");
  if (loading) {
    loading.remove();
    streamDiv = document.createElement("div");
    streamDiv.className = "turn turn-ai";
    chat.appendChild(streamDiv);
  }
  if (streamDiv) {
    streamDiv.textContent += text;
  }
  chat.scrollTop = chat.scrollHeight;
}

function showFollowup() {
  var area = document.getElementById("followup-area");
  area.style.display = "flex";
  document.getElementById("followup-input").focus();
}

function sendFollowup() {
  var ta = document.getElementById("followup-input");
  var text = ta.value.trim();
  if (!text) return;
  ta.value = "";
  ta.style.height = "";
  document.getElementById("btn-send").disabled = true;

  // Append user turn
  var chat = document.getElementById("chat");
  var userDiv = document.createElement("div");
  userDiv.className = "turn turn-user";
  userDiv.textContent = text;
  chat.appendChild(userDiv);

  // Append new AI loading row
  var loadDiv = document.createElement("div");
  loadDiv.id = "loading-row";
  loadDiv.className = "";
  loadDiv.style.cssText = "padding:10px 14px;background:var(--ai-bg);color:var(--text-dim);font-size:15px;display:flex;align-items:center;gap:8px;";
  loadDiv.innerHTML = 'Thinking <span class="dot">●</span><span class="dot">●</span><span class="dot">●</span>';
  chat.appendChild(loadDiv);
  streamDiv = null;
  chat.scrollTop = chat.scrollHeight;

  webkit.messageHandlers.agentMenuResult.postMessage({ action: "followup", text: text });
}

// Auto-grow textarea
document.addEventListener("DOMContentLoaded", function() {
  var ta = document.getElementById("followup-input");
  ta.addEventListener("input", function() {
    ta.style.height = "";
    ta.style.height = Math.min(ta.scrollHeight, 120) + "px";
  });
  ta.addEventListener("keydown", function(e) {
    if (e.key === "Enter" && e.metaKey) {
      e.preventDefault();
      sendFollowup();
    }
  });
});
</script>
</body>
</html>]], TOOLBAR_CSS, inputPreviewHtml(inputText))
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
      hs.alert.show("✓ Copied to clipboard")
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
  dialogWebview:bringToFront(true)
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
    hs.alert.show("✓ Copied to clipboard")

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
          hs.alert.show("✓ Copied to clipboard")
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
      dialogWebview:bringToFront(true)
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
