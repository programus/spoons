--- param_dialog.lua — Parameter input dialog using hs.webview

---@diagnostic disable-next-line: undefined-global
local hs = hs

local log = hs.logger.new("AgentMenu.dialog", "debug")

local M = {}

-- Injected by init.lua after spoon configuration.
local templates = nil

--- Inject the templates module (called from init.lua after configure()).
--@param t table  The templates module returned by req("templates")
function M.setTemplates(t)
  templates = t
end

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

  -- Build form rows HTML
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

  local html = templates.load("param_dialog.html", {
    FORM_ROWS   = table.concat(rows, "\n"),
    PARAM_NAMES = table.concat(nameList, ", "),
  })

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
  webview:windowTitle(templates.t("PARAM_WIN_TITLE"))
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
