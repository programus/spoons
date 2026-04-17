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
--@param onShow  function(text: string, rect: table|nil)
--@param onHide  function()
--@return table  { start=fn, stop=fn }  — call :start() and :stop() to manage lifecycle
function M.watchSelection(onShow, onHide)
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

  -- After mouse release, wait briefly then check selection
  local mouseUpTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseUp },
    function(_event)
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

  -- Left mouse down (new click) clears the toolbar
  local mouseDownTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDown },
    function(_event)
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
