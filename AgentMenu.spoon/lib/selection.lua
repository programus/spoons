--- selection.lua — Text selection detection via macOS Accessibility API

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

-- Delay in seconds after mouseUp before checking selection
local DEBOUNCE_DELAY = 0.15

--- Get the currently selected text via the Accessibility API.
-- Returns nil (not empty string) on failure or no selection, to let
-- callers distinguish between "empty" and "unavailable".
--@return string|nil
function M.getSelectedText()
  local ok, result = pcall(function()
    local sysEl = hs.axuielement.systemWideElement()
    local focused = sysEl:attributeValue("AXFocusedUIElement")
    if not focused then return nil end
    local text = focused:attributeValue("AXSelectedText")
    if type(text) == "string" and text ~= "" then
      return text
    end
    return nil
  end)
  if ok then return result end
  return nil
end

--- Get the screen rectangle of the current text selection.
-- Returns nil when the application does not support AXBoundsForRange
-- (Electron apps, terminals, etc.).
--@return table|nil  {x, y, w, h} in screen coordinates
function M.getSelectionRect()
  local ok, result = pcall(function()
    local sysEl  = hs.axuielement.systemWideElement()
    local focused = sysEl:attributeValue("AXFocusedUIElement")
    if not focused then return nil end

    local range = focused:attributeValue("AXSelectedTextRange")
    if not range then return nil end

    local bounds = focused:parameterizedAttributeValue("AXBoundsForRange", range)
    if not bounds then return nil end

    -- bounds is an hs.geometry rect
    return { x = bounds.x, y = bounds.y, w = bounds.w, h = bounds.h }
  end)
  if ok then return result end
  return nil
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
-- Calls onShow(text, rect|nil) when a non-empty selection is detected.
-- Calls onHide() when the selection is cleared or the user clicks/types.
--
--@param onShow       function(text: string, rect: table|nil)
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
  local mouseUpTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseUp },
    function(_event)
      if suppressHide and suppressHide() then
        return false  -- popup owns this interaction; leave it alone
      end
      cancelDebounce()
      debounceTimer = hs.timer.doAfter(DEBOUNCE_DELAY, function()
        debounceTimer = nil
        local text = M.getSelectedText()
        if text and text ~= "" then
          selectionVisible = true
          local rect = M.getSelectionRect()
          onShow(text, rect)
        else
          if selectionVisible then
            selectionVisible = false
            onHide()
          end
        end
      end)
      return false  -- don't consume the event
    end
  )

  -- Any key press clears the toolbar
  local keyTap = hs.eventtap.new(
    { hs.eventtap.event.types.keyDown },
    function(_event)
      hideIfVisible()
      return false
    end
  )

  -- Left mouse down (new click) clears the quick-menu / toolbar.
  -- When the popup is active (suppressHide returns true), yield to popup's own
  -- click handler and only reset our internal state — do NOT call onHide().
  local mouseDownTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDown },
    function(_event)
      if suppressHide and suppressHide() then
        -- popup is handling this click; quietly reset our state so we don't
        -- try to hide it again on the next unrelated click.
        cancelDebounce()
        selectionVisible = false
        return false
      end
      hideIfVisible()
      return false
    end
  )

  return {
    start = function()
      mouseUpTap:start()
      keyTap:start()
      mouseDownTap:start()
    end,
    stop = function()
      cancelDebounce()
      mouseUpTap:stop()
      keyTap:stop()
      mouseDownTap:stop()
    end,
  }
end

return M
