--- param_dialog.lua — Parameter input dialog using hs.webview

---@diagnostic disable-next-line: undefined-global
local hs = hs

local log = hs.logger.new("AgentMenu.dialog", "debug")

local M = {}

local BUILTIN_NAMES = { selection = true, clipboard = true }

local webview    = nil
local usercontent = nil
local callback   = nil

local function closeDialog()
  if webview then
    webview:delete()
    webview = nil
  end
  if usercontent then
    usercontent = nil
  end
  callback = nil
end

--- Show a parameter input dialog for the given parameter definitions.
-- Built-in parameters (selection, clipboard) are silently skipped.
-- If no user-facing parameters remain, callback is invoked immediately
-- with an empty values table (no dialog shown).
--
--@param paramDefs table   Array of {name, label, default, isBuiltin}
--@param cb        function(err: string|nil, values: table|nil)
--                   err == "cancelled" if user dismissed; values is nil in that case.
--                   On success: err == nil, values == {name → entered string}
function M.show(paramDefs, cb)
  closeDialog()

  -- Filter out built-in params
  local userParams = {}
  for _, p in ipairs(paramDefs or {}) do
    if not (p.isBuiltin or BUILTIN_NAMES[p.name]) then
      userParams[#userParams + 1] = p
    end
  end

  -- Skip dialog if nothing to ask
  if #userParams == 0 then
    log.d("param_dialog: no user params, skipping dialog")
    cb(nil, {})
    return
  end

  log.d("param_dialog: showing dialog for " .. #userParams .. " param(s)")

  callback = cb

  -- Build HTML
  local rows = {}
  for _, p in ipairs(userParams) do
    local defVal = (p.default or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub('"', "&quot;")
    local label  = (p.label or p.name):gsub("&", "&amp;"):gsub("<", "&lt;")
    if p.options and #p.options > 0 then
      -- Custom combobox: text input + dropdown button
      local optItems = {}
      for _, opt in ipairs(p.options) do
        local esc = opt:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub('"', "&quot;"):gsub("'", "&#39;")
        optItems[#optItems + 1] = string.format(
          '<div class="cb-option" onclick="cbSelect(\'param_%s\',\'%s\')">%s</div>',
          p.name, esc, esc)
      end
      rows[#rows + 1] = string.format([[
      <div class="row">
        <label for="param_%s">%s</label>
        <div class="cb-wrap">
          <input type="text" id="param_%s" name="%s" value="%s" autocomplete="off" />
          <button type="button" class="cb-arrow" onclick="cbToggle('param_%s')">&#9660;</button>
          <div class="cb-dropdown" id="drop_param_%s">%s</div>
        </div>
      </div>]], p.name, label, p.name, p.name, defVal,
               p.name, p.name, table.concat(optItems))
    else
      rows[#rows + 1] = string.format([[
      <div class="row">
        <label for="param_%s">%s</label>
        <input type="text" id="param_%s" name="%s" value="%s" autocomplete="off" />
      </div>]], p.name, label, p.name, p.name, defVal)
    end
  end

  -- Serialise param names to JS for form collection
  local nameList = {}
  for _, p in ipairs(userParams) do
    nameList[#nameList + 1] = string.format('"%s"', p.name)
  end
  local jsNames = table.concat(nameList, ", ")

  local html = string.format([[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
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
  --shadow:    rgba(0,0,0,0.2);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg:        #1e1e1e;
    --bg2:       #2d2d2d;
    --bg3:       #3a3a3a;
    --border:    #444;
    --text:      #e0e0e0;
    --text-dim:  #aaa;
    --btn-bg:    #3a3a3a;
    --btn-text:  #e0e0e0;
    --accent:    #0a84ff;
    --shadow:    rgba(0,0,0,0.5);
  }
}
body {
  font-family: -apple-system, Helvetica, sans-serif;
  font-size: 13px;
  background: var(--bg);
  color: var(--text);
  display: flex;
  flex-direction: column;
  height: 100vh;
  overflow: hidden;
  padding: 16px;
  gap: 10px;
}
.row { display: flex; flex-direction: column; gap: 4px; }
label { font-size: 12px; color: var(--text-dim); }
input[type=text] {
  width: 100%%;
  padding: 6px 8px;
  background: var(--bg2);
  border: 1px solid var(--border);
  border-radius: 5px;
  color: var(--text);
  font-size: 13px;
  outline: none;
}
input[type=text]:focus { border-color: var(--accent); }
.buttons {
  display: flex;
  gap: 8px;
  justify-content: flex-end;
  margin-top: auto;
}
button {
  padding: 6px 18px;
  border-radius: 6px;
  border: none;
  font-size: 13px;
  cursor: pointer;
}
#btn-ok     { background: var(--accent); color: #fff; }
#btn-cancel { background: var(--btn-bg); color: var(--btn-text); }
button:hover { opacity: 0.85; }
.cb-wrap {
  position: relative;
  display: flex;
}
.cb-wrap input[type=text] {
  flex: 1;
  border-radius: 5px 0 0 5px;
  border-right: none;
}
.cb-arrow {
  padding: 0 8px;
  background: var(--btn-bg);
  border: 1px solid var(--border);
  border-left: none;
  border-radius: 0 5px 5px 0;
  color: var(--text-dim);
  cursor: pointer;
  font-size: 10px;
  flex-shrink: 0;
}
.cb-arrow:hover { background: var(--bg3); opacity: 1; }
.cb-dropdown {
  display: none;
  position: fixed;
  background: var(--bg2);
  border: 1px solid var(--border);
  border-radius: 5px;
  box-shadow: 0 4px 12px var(--shadow);
  z-index: 100;
  overflow-y: auto;
}
.cb-dropdown.open { display: block; }
.cb-option {
  padding: 6px 10px;
  cursor: pointer;
  font-size: 13px;
  color: var(--text);
}
.cb-option:hover { background: var(--bg3); }
</style>
</head>
<body>
%s
<div class="buttons">
  <button id="btn-cancel" onclick="cancel()">Cancel</button>
  <button id="btn-ok" onclick="submit()">OK</button>
</div>
<script>
var names = [%s];
function collect() {
  var vals = {};
  names.forEach(function(n) {
    var el = document.getElementById("param_" + n);
    vals[n] = el ? el.value : "";
  });
  return vals;
}
function submit() {
  webkit.messageHandlers.agentMenuParams.postMessage({ action: "submit", values: collect() });
}
function cancel() {
  webkit.messageHandlers.agentMenuParams.postMessage({ action: "cancel" });
}
document.addEventListener("keydown", function(e) {
  if (e.key === "Enter")  { submit(); }
  if (e.key === "Escape") { cancel(); }
});
// Focus first input
window.onload = function() {
  var first = document.querySelector("input[type=text]");
  if (first) first.focus();
};
// Combobox helpers
function cbToggle(inputId) {
  var drop = document.getElementById("drop_" + inputId);
  if (!drop) return;
  var wasOpen = drop.classList.contains("open");
  cbCloseAll();
  if (!wasOpen) {
    var wrap = document.getElementById(inputId).closest(".cb-wrap");
    var rect = wrap.getBoundingClientRect();
    var gap = 2;
    var maxH = Math.min(180, window.innerHeight - rect.bottom - gap - 6);
    drop.style.left   = rect.left + "px";
    drop.style.width  = rect.width + "px";
    drop.style.top    = (rect.bottom + gap) + "px";
    drop.style.maxHeight = maxH + "px";
    drop.classList.add("open");
  }
}
function cbSelect(inputId, value) {
  var el = document.getElementById(inputId);
  if (el) el.value = value;
  cbCloseAll();
}
function cbCloseAll() {
  document.querySelectorAll(".cb-dropdown.open").forEach(function(d){ d.classList.remove("open"); });
}
document.addEventListener("click", function(e) {
  if (!e.target.closest(".cb-wrap")) cbCloseAll();
});
</script>
</body>
</html>]], table.concat(rows, "\n"), jsNames)

  -- Create webview
  local rowH  = 66   -- label + input + gap
  local h     = math.max(140, 20 + #userParams * rowH + 50)
  local w     = 400
  local mp     = hs.mouse.absolutePosition()
  local screen = hs.screen.mainScreen():frame()
  local x = mp.x + 20
  local y = mp.y + 20
  if x + w > screen.x + screen.w then x = mp.x - w - 10 end
  if y + h > screen.y + screen.h then y = mp.y - h - 10 end
  x = math.max(screen.x, x)
  y = math.max(screen.y, y)
  local rect  = { x = x, y = y, w = w, h = h }

  usercontent = hs.webview.usercontent.new("agentMenuParams")
  usercontent:setCallback(function(msg)
    local data = msg.body
    if type(data) ~= "table" then return end
    if data.action == "submit" then
      local values = type(data.values) == "table" and data.values or {}
      local cb2 = callback
      closeDialog()
      if cb2 then cb2(nil, values) end
    elseif data.action == "cancel" then
      local cb2 = callback
      closeDialog()
      if cb2 then cb2("cancelled", nil) end
    end
  end)

  webview = hs.webview.new(rect, { javaScriptEnabled = true }, usercontent)
  webview:windowStyle({ "titled", "closable" })
  webview:windowTitle("Parameters")
  webview:closeOnEscape(false)  -- handled via JS
  webview:allowTextEntry(true)
  webview:html(html)
  webview:windowCallback(function(action, _wv)
    if action == "closing" then
      local cb2 = callback
      closeDialog()
      if cb2 then cb2("cancelled", nil) end
    end
  end)
  webview:show()
  webview:hswindow():focus()
end

return M
