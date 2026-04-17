--- utils.lua — Shared helpers for AgentMenu.spoon
-- Template substitution, geometry utilities, logging

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

-- Built-in parameter names that are auto-resolved and never shown in dialogs
M.BUILTINS = { selection = true, clipboard = true }

--- Fill a prompt template with parameter values.
-- Template syntax:
--   {{name}}         — replaced with params["name"] (empty string if nil)
--   {{a|b|c}}        — pipe fallback: uses first non-nil, non-empty value among
--                      params["a"], params["b"], params["c"]; if a candidate is
--                      not a key in params, it is treated as a string literal.
--   The last segment of a pipe chain is always treated as a literal fallback if
--   no earlier candidate resolves (e.g. {{selection|clipboard|No text selected}}).
--@param tpl string   Template string
--@param params table  Map of name → value (all values should be strings or nil)
--@return string       Filled template
function M.fillTemplate(tpl, params)
  params = params or {}
  return (tpl:gsub("{{([^}]+)}}", function(expr)
    local candidates = {}
    for segment in expr:gmatch("[^|]+") do
      candidates[#candidates + 1] = segment:match("^%s*(.-)%s*$") -- trim
    end

    for i, candidate in ipairs(candidates) do
      local val = params[candidate]
      if val ~= nil and val ~= "" then
        return val
      end
      -- Last segment: treat as literal fallback regardless of whether it's a key
      if i == #candidates then
        -- If it was found as a key with empty/nil value, return literal text
        -- (the key itself IS the literal when not found in params)
        if params[candidate] == nil then
          return candidate  -- literal string fallback
        end
        return ""  -- key existed but was empty
      end
    end
    return ""
  end))
end

--- Return a rect positioned above a reference rect with a given height.
--@param refRect table  {x, y, w, h} — reference rectangle (e.g. selection bounds)
--@param w      number  Width of the new rect
--@param h      number  Height of the new rect
--@param gap    number  Vertical gap between refRect top and new rect bottom (default 6)
--@return table  {x, y, w, h}
function M.rectAbove(refRect, w, h, gap)
  gap = gap or 6
  return {
    x = refRect.x,
    y = refRect.y - h - gap,
    w = w,
    h = h,
  }
end

--- Clamp a rect so it stays fully within the screen that contains its center.
--@param rect table  {x, y, w, h}
--@return table      Clamped {x, y, w, h}
function M.clampToScreen(rect)
  local screen = hs.screen.mainScreen()
  local sf = screen:frame()
  local x = math.max(sf.x, math.min(rect.x, sf.x + sf.w - rect.w))
  local y = math.max(sf.y, math.min(rect.y, sf.y + sf.h - rect.h))
  return { x = x, y = y, w = rect.w, h = rect.h }
end

--- Merge table b into table a (shallow, b wins on conflict).
--@param a table
--@param b table
--@return table  New merged table
function M.merge(a, b)
  local result = {}
  for k, v in pairs(a or {}) do result[k] = v end
  for k, v in pairs(b or {}) do result[k] = v end
  return result
end

--- Safe logger wrapper.  Prefixes all messages with "[AgentMenu]".
local logger = hs.logger.new("AgentMenu", "info")

function M.log(...)
  logger.i(...)
end

function M.logError(...)
  logger.e(...)
end

function M.logDebug(...)
  logger.d(...)
end

return M
