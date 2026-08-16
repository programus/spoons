--- selection.lua — Text selection detection via macOS Accessibility API

---@diagnostic disable-next-line: undefined-global
local hs = hs

local log = hs.logger.new("AgentMenu.selection", "debug")

local M = {}

-- Delay in seconds after mouseUp before checking selection
local DEBOUNCE_DELAY = 0.15

-- ── Accessibility plumbing ────────────────────────────────────────────────
-- The system-wide element is a singleton wrapper; fetching it once avoids a
-- round trip on every selection read.
---@type table|nil
local sysEl = nil

local function systemElement()
  if not sysEl then
    sysEl = hs.axuielement.systemWideElement()
  end
  return sysEl
end

--- Set the Accessibility messaging timeout.
-- The system default is 6 seconds: an unresponsive app (Electron, some
-- terminals) blocks Hammerspoon's main thread for that whole time on every
-- selection read, which is a large part of the "everything feels laggy" effect.
--
-- Note: applied to the system-wide element this changes the *global* AX default,
-- so it affects other spoons too.  Pass 0 to leave the system default alone.
--@param seconds number|nil  Timeout in seconds; 0 or nil = leave untouched
function M.setAxTimeout(seconds)
  if not seconds or seconds <= 0 then return end
  local ok, err = pcall(function()
    return systemElement():setTimeout(seconds)
  end)
  if ok then
    log.d("selection: AX messaging timeout set to " .. seconds .. "s")
  else
    log.w("selection: could not set AX timeout: " .. tostring(err))
  end
end

-- Currently focused UI element, or nil.  Never cached across calls: focus moves.
local function focusedElement()
  local ok, el = pcall(function()
    return systemElement():attributeValue("AXFocusedUIElement")
  end)
  if not ok then return nil end
  return el
end

-- Read the selected text off an already-resolved focused element.
local function selectedTextOf(focused)
  if not focused then return nil end
  local ok, text = pcall(function()
    return focused:attributeValue("AXSelectedText")
  end)
  if ok and type(text) == "string" and text ~= "" then return text end
  return nil
end

-- Read the selection bounds off an already-resolved focused element.
-- AXBoundsForRange is the most expensive call in this file, so it is only ever
-- made when a caller actually wants the rect.
local function selectionRectOf(focused)
  if not focused then return nil end
  local ok, rect = pcall(function()
    local range = focused:attributeValue("AXSelectedTextRange")
    if not range then return nil end
    local bounds = focused:parameterizedAttributeValue("AXBoundsForRange", range)
    if not bounds then return nil end
    -- bounds is an hs.geometry rect
    return { x = bounds.x, y = bounds.y, w = bounds.w, h = bounds.h }
  end)
  if ok then return rect end
  return nil
end

--- Get the currently selected text via the Accessibility API.
-- Returns nil (not empty string) on failure or no selection, to let
-- callers distinguish between "empty" and "unavailable".
--@return string|nil
function M.getSelectedText()
  return selectedTextOf(focusedElement())
end

--- Get the screen rectangle of the current text selection.
-- Returns nil when the application does not support AXBoundsForRange
-- (Electron apps, terminals, etc.).
--@return table|nil  {x, y, w, h} in screen coordinates
function M.getSelectionRect()
  return selectionRectOf(focusedElement())
end

--- Get text and rect from a single focused-element lookup.
-- Prefer this over calling both getters when both values are needed.
--@return string|nil text, table|nil rect
function M.getSelection()
  local focused = focusedElement()
  return selectedTextOf(focused), selectionRectOf(focused)
end

--- Resolve the built-in parameter table.
-- Always call this just before running an action so values are fresh.
--@return table  { selection = string|nil, clipboard = string|nil }
function M.resolveBuiltins()
  return {
    selection = M.getSelectedText(),
    clipboard = hs.pasteboard.getContents(),
  }
end

--- Watch for text selection changes.
-- Calls onShow(text, getRect) when a non-empty selection is detected.
-- Calls onHide() when the selection is cleared or the user clicks/types.
--
-- `getRect` is a function, not a rect: resolving the selection bounds is the
-- most expensive Accessibility call available and most callers never use it,
-- so it is computed on demand.
--
--@param onShow       function(text: string, getRect: function(): table|nil)
--@param onHide       function()
--@param suppressHide function()|nil  optional; when it returns true, mouseDown is
--                    delegated to the popup and selection resets its own state silently.
--@return table  { start=fn, stop=fn }  — call :start() and :stop() to manage lifecycle
function M.watchSelection(onShow, onHide, suppressHide)
  ---@type table|nil
  local debounceTimer = nil
  local selectionVisible = false

  local function cancelDebounce()
    if debounceTimer then
      debounceTimer:stop()
      debounceTimer = nil
    end
  end

  local function hideIfVisible()
    cancelDebounce()
    if selectionVisible then
      selectionVisible = false
      onHide()
    end
  end

  -- After mouse release, wait briefly then check selection.
  -- When the popup is active (suppressHide returns true), the mouse-up belongs
  -- to a click inside the popup UI — skip the debounce entirely so we don't
  -- re-check selection and accidentally dismiss the popup.
  local function onMouseUp()
    if suppressHide and suppressHide() then
      return  -- popup owns this interaction; leave it alone
    end
    cancelDebounce()
    debounceTimer = hs.timer.doAfter(DEBOUNCE_DELAY, function()
      debounceTimer = nil
      local text = M.getSelectedText()
      if text and text ~= "" then
        selectionVisible = true
        onShow(text, M.getSelectionRect)
      elseif selectionVisible then
        selectionVisible = false
        onHide()
      end
    end)
  end

  -- Left mouse down (new click) clears the quick-menu / toolbar.
  -- When the popup is active (suppressHide returns true), yield to popup's own
  -- click handler and only reset our internal state — do NOT call onHide().
  local function onMouseDown()
    if suppressHide and suppressHide() then
      -- popup is handling this click; quietly reset our state so we don't
      -- try to hide it again on the next unrelated click.
      cancelDebounce()
      selectionVisible = false
      return
    end
    hideIfVisible()
  end

  -- One tap for all three event types.  Every CGEventTap in the chain adds
  -- latency to system-wide input, so three taps that never consume an event
  -- were three times the cost of one dispatching on the event type.
  local types = hs.eventtap.event.types
  local tap = hs.eventtap.new(
    { types.leftMouseUp, types.leftMouseDown, types.keyDown },
    function(event)
      local t = event:getType()
      if t == types.leftMouseUp then
        onMouseUp()
      elseif t == types.leftMouseDown then
        onMouseDown()
      else
        -- Any key press clears the toolbar
        hideIfVisible()
      end
      return false  -- never consume the event
    end
  )

  return {
    start = function() tap:start() end,
    stop  = function()
      cancelDebounce()
      tap:stop()
    end,
  }
end

return M
