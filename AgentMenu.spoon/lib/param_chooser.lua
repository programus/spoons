--- param_chooser.lua — Native parameter input via hs.chooser
--
-- Drop-in alternative to param_dialog.lua with the same contract:
--   M.show(paramDefs, cb)  →  cb("cancelled", nil) | cb(nil, {name = value})
--
-- Why: param_dialog spins up a WKWebView per invocation just to ask for
-- something like a target language.  hs.chooser is a native NSPanel — it
-- appears instantly, supports type-to-filter and is fully keyboard driven.
--
-- Each parameter is asked in its own panel, in declaration order.
--
-- Free text is supported even though a chooser only ever "picks a row": the
-- query-changed callback offers a row whose text IS the current query, so any
-- typed value can be submitted.
--
-- Verified on Hammerspoon 6936: choices assigned from inside
-- queryChangedCallback are displayed verbatim — the chooser does not apply its
-- own filtering to them — so both the narrowing and the ordering are done here.
-- Row 1 is what Enter picks, so it is always what the user meant: the option
-- they typed in full, or else the literal text they typed.
--
-- Parameters that need more than one line (param.multiline = true) are not
-- handled here — init.lua routes those actions to param_dialog instead, since
-- Hammerspoon has no native multi-line text input.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local log = hs.logger.new("AgentMenu.chooser", "debug")

local M = {}

-- Injected by init.lua after spoon configuration.
---@type any
local templates = nil

--- Inject the templates module (called from init.lua after configure()).
--@param t table  The templates module returned by req("templates")
function M.setTemplates(t)
  templates = t
end

local BUILTIN_NAMES = { selection = true, clipboard = true }
local MAX_ROWS      = 8

---@type table|nil
local chooser     = nil   -- single reused instance
---@type function|nil
local stepHandler = nil   -- handler for the panel currently on screen

local function ensureChooser()
  if chooser then return chooser end
  chooser = hs.chooser.new(function(choice)
    -- Clear before dispatching: the panel is already gone, and a handler must
    -- never be able to fire twice.
    local h = stepHandler
    stepHandler = nil
    if h then h(choice) end
  end)
  chooser:searchSubText(false)   -- only match the row text, never the hint
  return chooser
end

local function label(p)
  return p.label or p.name
end

local function hintFor(p)
  local t = templates and templates.t("PARAM_CHOOSER_HINT") or "{label}"
  return (t:gsub("{label}", label(p)))
end

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$")
end

-- Build the row list for a parameter given the current query.  Row order is the
-- whole point: the chooser highlights row 1, so row 1 has to be the value Enter
-- should submit.
--
--   * query matches a declared option in full (ignoring case and surrounding
--     whitespace)  → that option is row 1, and its canonical spelling is what
--     gets submitted;
--   * anything else → the "use what you typed" row is row 1.
--
-- Options that merely contain the query follow row 1; options that do not match
-- at all are dropped, which is the narrowing the chooser would normally do.
local function rowsFor(p, query)
  local q    = trim(query)
  local rows = {}

  if q == "" then
    for _, opt in ipairs(p.options or {}) do
      rows[#rows + 1] = { text = opt, subText = label(p), value = opt }
    end
    return rows
  end

  local lowered        = q:lower()
  local exact, partial = nil, {}
  for _, opt in ipairs(p.options or {}) do
    local lo = opt:lower()
    if lo == lowered then
      exact = exact or opt
    elseif lo:find(lowered, 1, true) then
      partial[#partial + 1] = opt
    end
  end

  if exact then
    rows[#rows + 1] = { text = exact, subText = label(p), value = exact }
  else
    rows[#rows + 1] = {
      text    = query,
      subText = templates and templates.t("USE_TYPED_TEXT") or "",
      value   = q,
    }
  end
  for _, opt in ipairs(partial) do
    rows[#rows + 1] = { text = opt, subText = label(p), value = opt }
  end
  return rows
end

-- Ask for one parameter.  done("cancelled") on dismissal, done(nil, value) otherwise.
local function ask(p, done)
  local ch      = ensureChooser()
  local initial = p.default or ""

  stepHandler = function(choice)
    if not choice then
      done("cancelled", nil)
    else
      done(nil, choice.value or choice.text or "")
    end
  end

  -- Populate before setting the query so the list is correct whether or not a
  -- programmatic query() change fires queryChangedCallback.
  ch:choices(rowsFor(p, initial))
  ch:queryChangedCallback(function(q)
    ch:choices(rowsFor(p, q))
    -- Assigning choices already drops the highlight back to the first row; say
    -- so explicitly, because Enter picking row 1 is the whole contract here.
    ch:selectedRow(1)
  end)
  ch:placeholderText(hintFor(p))
  local n = #(p.options or {})
  ch:rows(math.max(1, math.min(MAX_ROWS, n + 1)))
  ch:query(initial)
  ch:show()
end

--- Ask the user for each non-built-in parameter, in order.
-- Built-in parameters (selection, clipboard) are silently skipped; when nothing
-- is left to ask, cb is invoked immediately with an empty table.
--
--@param paramDefs table  Array of {name, label, default, options}
--@param cb        function(err: string|nil, values: table|nil)
--                   err == "cancelled" if the user dismissed any panel.
function M.show(paramDefs, cb)
  local userParams = {}
  for _, p in ipairs(paramDefs or {}) do
    if not (p.isBuiltin or BUILTIN_NAMES[p.name]) then
      userParams[#userParams + 1] = p
    end
  end

  if #userParams == 0 then
    log.d("param_chooser: no user params, skipping")
    cb(nil, {})
    return
  end

  log.d("param_chooser: asking for " .. #userParams .. " param(s)")

  local values = {}
  local idx    = 1

  local function step()
    if idx > #userParams then
      cb(nil, values)
      return
    end
    local p = userParams[idx]
    ask(p, function(err, value)
      if err then
        log.d("param_chooser: cancelled at '" .. p.name .. "'")
        cb(err, nil)
        return
      end
      values[p.name] = value
      idx = idx + 1
      -- Let the current panel finish closing before opening the next one.
      hs.timer.doAfter(0, step)
    end)
  end

  step()
end

--- Dismiss any visible panel and drop the pending handler.
function M.hide()
  stepHandler = nil
  if chooser then chooser:hide() end
end

--- Release the chooser instance (used by AgentMenu:stop()).
function M.destroy()
  stepHandler = nil
  if chooser then
    chooser:delete()
    chooser = nil
  end
end

return M
