--- popup.lua — Floating action toolbar using hs.canvas

---@diagnostic disable-next-line: undefined-global
local hs = hs

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local utils = dofile(_dir .. "utils.lua")
local log = hs.logger.new("AgentMenu.popup", "debug")
local M = {}

-- ── Visual constants ──────────────────────────────────────────────────────
local BTN_H        = 22    -- button height
local BTN_PADDING  = 10    -- horizontal padding inside each button
local BTN_GAP      = 4     -- gap between buttons
local TOOLBAR_PAD  = 6     -- inner padding of the toolbar background
local CORNER_R     = 6     -- corner radius
local FONT_SIZE    = 12

-- Pick colours based on current system appearance
local function makeColors()
  local dark = hs.host.interfaceStyle and hs.host.interfaceStyle() == "Dark"
  if dark then
    return {
      bg        = { red = 0.18, green = 0.18, blue = 0.18, alpha = 0.96 },
      btn       = { red = 0.30, green = 0.30, blue = 0.30, alpha = 1 },
      btn_hover = { red = 0.45, green = 0.45, blue = 0.45, alpha = 1 },
      text      = { red = 1,    green = 1,    blue = 1,    alpha = 1 },
    }
  else
    return {
      bg        = { red = 0.96, green = 0.96, blue = 0.96, alpha = 0.96 },
      btn       = { red = 0.84, green = 0.84, blue = 0.84, alpha = 1 },
      btn_hover = { red = 0.65, green = 0.65, blue = 0.65, alpha = 1 },
      text      = { red = 0.10, green = 0.10, blue = 0.10, alpha = 1 },
    }
  end
end

-- ── Module state ─────────────────────────────────────────────────────────
local canvas         = nil
local outsideTap     = nil
local onActionCb     = nil
local currentActions = {}   -- list of {name, label}

--- Register the callback invoked when an action button is clicked.
--@param fn function(actionName: string)
function M.setOnAction(fn)
  onActionCb = fn
end

--- Hide and destroy the toolbar canvas + outside-click tap.
function M.hide()
  if outsideTap then
    outsideTap:stop()
    outsideTap = nil
  end
  if canvas then
    canvas:hide()
    canvas:delete()
    canvas = nil
  end
  currentActions = {}
end

-- Measure label widths to size buttons
local function measureText(label)
  local styledText = hs.styledtext.new(label, {
    font = { name = "Helvetica", size = FONT_SIZE },
  })
  -- Approximate: use canvas minimumTextSize
  local tmpCanvas = hs.canvas.new({ x = 0, y = 0, w = 600, h = 40 })
  tmpCanvas:appendElements({
    type     = "text",
    text     = styledText,
    frame    = { x = 0, y = 0, w = "100%", h = "100%" },
  })
  local sz = tmpCanvas:minimumTextSize(1, label)
  tmpCanvas:delete()
  return sz and sz.w or (FONT_SIZE * #label * 0.65)
end

--- Show the floating toolbar with the given action list at the specified position.
--@param actions  table   List of {name=string, label=string}
--@param position table   {x, y, w, h} — reference rect (e.g. selection bounds);
--                        if nil, positions near current mouse location
function M.show(actions, position)
  M.hide()

  if not actions or #actions == 0 then return end
  currentActions = actions

  -- Measure button widths
  local btnWidths = {}
  local totalW = TOOLBAR_PAD * 2 - BTN_GAP  -- start accounting for gaps
  for _, act in ipairs(actions) do
    local textW = measureText(act.label)
    local bw = textW + BTN_PADDING * 2
    btnWidths[#btnWidths + 1] = bw
    totalW = totalW + bw + BTN_GAP
  end
  local toolbarW = totalW
  local toolbarH = BTN_H + TOOLBAR_PAD * 2

  -- Position above the reference rect (or mouse)
  local refRect
  if position then
    refRect = position
  else
    local mp = hs.mouse.absolutePosition()
    refRect = { x = mp.x, y = mp.y, w = 0, h = 0 }
  end
  local rawRect = utils.rectAbove(refRect, toolbarW, toolbarH, 6)
  local rect    = utils.clampToScreen(rawRect)

  -- Build canvas
  local colors = makeColors()
  canvas = hs.canvas.new(rect)
  canvas:level(hs.canvas.windowLevels.floating)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  canvas:clickActivating(false)

  -- Background rounded rect
  canvas:appendElements({
    type             = "rectangle",
    action           = "fill",
    fillColor        = colors.bg,
    roundedRectRadii = { xRadius = CORNER_R, yRadius = CORNER_R },
    frame            = { x = 0, y = 0, w = toolbarW, h = toolbarH },
  })

  -- Buttons
  -- btnIndexByName: action name → canvas element index (for hover colour changes)
  -- btnScreenRects: action name → screen-coordinate rect (for click hit-testing)
  local btnIndexByName = {}
  local btnScreenRects = {}
  local x = TOOLBAR_PAD
  -- element index 1 is the toolbar background; buttons start at index 2 (bg) and 3 (text)
  local elemIndex = 2
  for i, act in ipairs(actions) do
    local bw = btnWidths[i]

    btnIndexByName[act.name] = elemIndex
    -- Store absolute screen rect for this button
    btnScreenRects[act.name] = {
      x = rect.x + x,
      y = rect.y + TOOLBAR_PAD,
      w = bw,
      h = BTN_H,
    }

    -- Button background (only hover tracking, no click tracking)
    canvas:appendElements({
      type             = "rectangle",
      action           = "fill",
      fillColor        = colors.btn,
      roundedRectRadii = { xRadius = 5, yRadius = 5 },
      frame            = { x = x, y = TOOLBAR_PAD, w = bw, h = BTN_H },
      trackMouseEnterExit = true,
    })
    elemIndex = elemIndex + 1

    -- Button label
    canvas:appendElements({
      type          = "text",
      text          = act.label,
      textFont      = "Helvetica",
      textSize      = FONT_SIZE,
      textColor     = colors.text,
      textAlignment = "center",
      frame         = { x = x, y = TOOLBAR_PAD + (BTN_H - FONT_SIZE - 4) / 2,
                        w = bw, h = FONT_SIZE + 6 },
    })
    elemIndex = elemIndex + 1

    x = x + bw + BTN_GAP
  end

  -- Mouse callback — only used for hover colour changes now
  canvas:mouseCallback(function(_cnv, msg, id, _mx, _my)
    if not canvas then return end
    local actName
    for name, idx in pairs(btnIndexByName) do
      if idx == id then actName = name; break end
    end
    if not actName then return end
    if msg == "mouseEnter" then
      canvas:elementAttribute(id, "fillColor", colors.btn_hover)
    elseif msg == "mouseExit" then
      canvas:elementAttribute(id, "fillColor", colors.btn)
    end
  end)

  canvas:show()

  -- Single eventtap handles both button clicks and outside-dismiss
  outsideTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDown,
      hs.eventtap.event.types.rightMouseDown },
    function(event)
      if not canvas then return false end
      local pos   = event:location()
      local frame = canvas:frame()
      -- Click is outside toolbar → dismiss
      if pos.x < frame.x or pos.x > frame.x + frame.w or
         pos.y < frame.y or pos.y > frame.y + frame.h then
        M.hide()
        return false
      end
      -- Click is inside toolbar → check which button
      for name, r in pairs(btnScreenRects) do
        if pos.x >= r.x and pos.x <= r.x + r.w and
           pos.y >= r.y and pos.y <= r.y + r.h then
          log.d("popup: button clicked (eventtap): " .. name)
          M.hide()
          if onActionCb then onActionCb(name) end
          return true  -- consume event so it doesn't reach the app below
        end
      end
      return false
    end
  )
  outsideTap:start()
end

return M