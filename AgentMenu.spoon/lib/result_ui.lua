--- result_ui.lua — AI response display: dialog (Markdown), clipboard, or replace

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

-- ── Dialog window state ──────────────────────────────────────────────────
local dialogWebview     = nil
local dialogUserContent = nil
local dialogIsLoading   = false   -- true while waiting for AI response
local dialogCancelFn    = nil     -- called when user closes/cancels during loading

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
html, body { height: 100%%; }
body {
  font-family: -apple-system, Helvetica, sans-serif;
  font-size: 14px;
  background: var(--bg);
  color: var(--text);
  display: flex;
  flex-direction: column;
}
%s
#loading {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-dim);
  font-size: 15px;
  gap: 10px;
}
.dot { animation: blink 1.2s infinite; display: inline-block; }
.dot:nth-child(2) { animation-delay: 0.2s; }
.dot:nth-child(3) { animation-delay: 0.4s; }
@keyframes blink { 0%%,80%%,100%%{opacity:0.2} 40%%{opacity:1} }
</style>
</head>
<body>
<div id="toolbar">
  %s
  <button id="btn-cancel" onclick="cancelAction()">Cancel</button>
</div>
<div id="loading">
  Thinking
  <span class="dot">●</span><span class="dot">●</span><span class="dot">●</span>
</div>
<script>
function cancelAction() {
  webkit.messageHandlers.agentMenuResult.postMessage({ action: "cancel" });
}
</script>
</body>
</html>]], TOOLBAR_CSS, inputPreviewHtml(inputText))
end

--- Open the result dialog in "loading" state near the mouse.
-- Closing the window or clicking Cancel will invoke onCancel().
--@param inputText string|nil  The source text to display in the toolbar
--@param onCancel  function    Called when the user dismisses during loading
function M.showLoading(inputText, onCancel)
  closeDialog()
  dialogIsLoading = true
  dialogCancelFn  = onCancel

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
    end
  end)

  dialogWebview = hs.webview.new(rect, { javaScriptEnabled = true }, dialogUserContent)
  dialogWebview:windowStyle({ "titled", "closable", "resizable" })
  dialogWebview:windowTitle("AgentMenu")
  dialogWebview:closeOnEscape(true)
  dialogWebview:allowTextEntry(true)
  dialogWebview:windowCallback(function(action, _wv)
    if action == "closing" then
      local fn = dialogCancelFn  -- capture before closeDialog clears it
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

-- ── Inline marked.js (minified subset) ───────────────────────────────────
-- A compact self-contained marked.js is bundled here as a fallback when the
-- CDN is unreachable.  The real CDN copy is tried first via the <script> tag's
-- src attribute; the inline version is only activated via the onerror handler.
-- We store it in a separate variable to keep the HTML template readable.
local MARKED_INLINE = [=[
/* marked.js inline fallback — minified */
!function(e,t){"object"==typeof exports&&"object"==typeof module?module.exports=t():"function"==typeof define&&define.amd?define([],t):"object"==typeof exports?exports.marked=t():e.marked=t()}(this,function(){
"use strict";
// Minimal synchronous renderer: converts a small subset of Markdown to HTML.
// Supports: headings, bold, italic, code blocks, inline code, links, lists, paragraphs.
function escHtml(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}
function inlineRender(s){
  s=s.replace(/`([^`]+)`/g,function(_,c){return"<code>"+escHtml(c)+"</code>";});
  s=s.replace(/\*\*\*(.+?)\*\*\*/g,"<strong><em>$1</em></strong>");
  s=s.replace(/\*\*(.+?)\*\*/g,"<strong>$1</strong>");
  s=s.replace(/\*(.+?)\*/g,"<em>$1</em>");
  s=s.replace(/\[([^\]]+)\]\(([^)]+)\)/g,'<a href="$2">$1</a>');
  return s;
}
function marked(src){
  var lines=src.split("\n"),out="",i=0,inCode=false,codeBuf="",codeLang="";
  while(i<lines.length){
    var l=lines[i];
    if(!inCode&&/^```/.test(l)){inCode=true;codeLang=l.slice(3).trim();codeBuf="";i++;continue;}
    if(inCode){if(/^```/.test(l)){out+='<pre><code class="language-'+escHtml(codeLang)+'">'+escHtml(codeBuf.replace(/\n$/,""))+"</code></pre>";inCode=false;codeLang="";codeBuf="";}else{codeBuf+=l+"\n";}i++;continue;}
    var h=l.match(/^(#{1,6})\s+(.*)/);
    if(h){out+="<h"+h[1].length+">"+inlineRender(h[2])+"</h"+h[1].length+">";i++;continue;}
    if(/^[-*+]\s/.test(l)){out+="<ul>";while(i<lines.length&&/^[-*+]\s/.test(lines[i])){out+="<li>"+inlineRender(lines[i].slice(2))+"</li>";i++;}out+="</ul>";continue;}
    if(/^\d+\.\s/.test(l)){out+="<ol>";while(i<lines.length&&/^\d+\.\s/.test(lines[i])){out+="<li>"+inlineRender(lines[i].replace(/^\d+\.\s/,""))+"</li>";i++;}out+="</ol>";continue;}
    if(l.trim()===""){out+="<br/>";i++;continue;}
    out+="<p>"+inlineRender(l)+"</p>";i++;
  }
  return out;
}
marked.parse=marked;
return marked;
});
]=]

-- ── Dialog window ──────────────────────────────────────────────────────────
-- ── Result HTML ──────────────────────────────────────────────────────────
local function buildDialogHtml(content, inputText)
  -- JSON-encode the content string so it is safe to embed in JS.
  -- hs.json.encode only accepts tables, so wrap in an array and extract the element.
  local encoded = hs.json.encode({ content })  -- produces ["<escaped string>"]
  -- Extract the inner JSON string (strip the surrounding [ ])
  local jsonContent = encoded:match("^%[(.-)%]$") or encoded

  return string.format([[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { height: 100%%; }
body {
  font-family: -apple-system, Helvetica, sans-serif;
  font-size: 14px;
  background: var(--bg);
  color: var(--text);
  display: flex;
  flex-direction: column;
}
%s
#content {
  flex: 1;
  overflow-y: auto;
  padding: 16px 20px;
  line-height: 1.6;
}
#content h1,#content h2,#content h3 { margin: 1em 0 0.4em; }
#content p  { margin: 0.5em 0; }
#content ul,#content ol { margin: 0.5em 0 0.5em 1.5em; }
#content li { margin: 0.2em 0; }
#content pre {
  background: var(--pre-bg);
  border-radius: 6px;
  padding: 10px 14px;
  overflow-x: auto;
  margin: 0.8em 0;
}
#content code { font-family: "SF Mono", Menlo, monospace; font-size: 12px; }
#content p > code {
  background: var(--pre-bg);
  padding: 1px 5px;
  border-radius: 3px;
}
a { color: var(--accent); }
</style>
</head>
<body>
<div id="toolbar">
  %s
  <button id="btn-copy" onclick="copyContent()">Copy</button>
  <button id="btn-close" onclick="closeWindow()">Close</button>
</div>
<div id="content"><em>Rendering…</em></div>

<!-- Try CDN first; fall back to inline if CDN fails -->
<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"
  onerror="loadInline()"></script>
<script id="inline-marked" type="text/plain">%s</script>
<script>
var rawContent = %s;

function loadInline() {
  var src = document.getElementById("inline-marked").textContent;
  var s = document.createElement("script");
  s.textContent = src;
  document.head.appendChild(s);
  render();
}

function render() {
  var el = document.getElementById("content");
  if (typeof marked !== "undefined") {
    marked.setOptions && marked.setOptions({ breaks: true });
    el.innerHTML = (marked.parse || marked)(rawContent);
  } else {
    // Plain text fallback
    el.textContent = rawContent;
  }
}

function copyContent() {
  webkit.messageHandlers.agentMenuResult.postMessage({ action: "copy", text: rawContent });
}

function closeWindow() {
  webkit.messageHandlers.agentMenuResult.postMessage({ action: "close" });
}

window.addEventListener("DOMContentLoaded", function() {
  if (typeof marked !== "undefined") { render(); }
});
var _origOnload = window.onload;
window.onload = function() {
  if (_origOnload) _origOnload();
  if (typeof marked !== "undefined") { render(); }
};
</script>
</body>
</html>]], TOOLBAR_CSS, inputPreviewHtml(inputText), MARKED_INLINE, jsonContent)
end

--- Display the AI result according to the specified output mode.
--@param text           string   The AI-generated text
--@param mode           string   "dialog" | "clipboard" | "replace"
--@param replaceFallback string  "dialog" | "clipboard" — used when replace fails
--@param selectedText   string|nil  Original selected text (for replace mode)
--@param inputText      string|nil  Source text shown in toolbar
function M.show(text, mode, replaceFallback, selectedText, inputText, modelName, providerName)
  replaceFallback = replaceFallback or "dialog"
  local titleSuffix = modelName and (" — " .. modelName .. (providerName and (" (" .. providerName .. ")") or "")) or ""

  if mode == "clipboard" then
    closeDialog()  -- close any loading dialog
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
      closeDialog()  -- close loading dialog on success
    else
      M.show(text, replaceFallback, "dialog", selectedText, inputText)  -- fallback
    end

  else  -- "dialog" (default)
    if dialogWebview and dialogIsLoading then
      -- Reuse the existing loading window: just swap the HTML
      dialogIsLoading = false
      dialogCancelFn  = nil
      -- Update usercontent callback to handle result actions
      dialogUserContent:setCallback(function(msg)
        local data = msg.body
        if type(data) ~= "table" then return end
        if data.action == "copy" then
          hs.pasteboard.setContents(data.text or text)
          hs.alert.show("✓ Copied to clipboard")
        elseif data.action == "close" or data.action == "cancel" then
          closeDialog()
        end
      end)
      dialogWebview:windowTitle("AgentMenu Result" .. titleSuffix)
      dialogWebview:html(buildDialogHtml(text, inputText))
    else
      -- No loading window open; open a fresh dialog near mouse
      closeDialog()
      local rect = rectNearMouse(640, 480)

      dialogUserContent = hs.webview.usercontent.new("agentMenuResult")
      dialogUserContent:setCallback(function(msg)
        local data = msg.body
        if type(data) ~= "table" then return end
        if data.action == "copy" then
          hs.pasteboard.setContents(data.text or text)
          hs.alert.show("✓ Copied to clipboard")
        elseif data.action == "close" or data.action == "cancel" then
          closeDialog()
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
      dialogWebview:html(buildDialogHtml(text, inputText))
      dialogWebview:show()
      dialogWebview:bringToFront(true)
    end   -- closes inner if/else (reuse vs fresh dialog)
  end     -- closes outer if/elseif/else (mode)
end       -- closes M.show

return M
