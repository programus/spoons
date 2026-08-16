--- popup.lua — Quick-menu: dot → circle button → action menu
--
-- Behaviour:
--   1. After text is selected a small dot appears near the selection.
--   2. Moving the mouse over the dot expands it to a circular button.
--   3. Clicking the button opens a compact dropdown menu.
--   4. Clicking a menu item triggers the action; clicking elsewhere dismisses.
--
-- Implementation notes (all about staying cheap while resident):
--   • dot ↔ button hover is driven by a canvas element's trackMouseEnterExit,
--     handled inside AppKit.  It used to be a global mouseMoved eventtap, i.e.
--     an entry into the Lua VM for every single mouse movement on the system.
--   • dot and button live in ONE canvas as two elements whose `action` toggles
--     between "fill" and "skip", instead of destroying and rebuilding a canvas
--     on every hover crossing.
--   • canvases are built once and repositioned with :frame(); label widths are
--     measured with hs.drawing.getTextDrawingSize (native, no window) and cached.
--
---@diagnostic disable-next-line: undefined-global
local hs = hs

local log = hs.logger.new("AgentMenu.popup", "debug")
local M = {}

-- ── Visual constants ──────────────────────────────────────────────────────
local DOT_D        = 10    -- visible dot diameter
local BTN_D        = 36    -- expanded button diameter (also the hover area)
local MENU_ITEM_H  = 26    -- menu row height
local MENU_MIN_W   = 120   -- minimum menu width
local MENU_H_PAD   = 12    -- horizontal text padding
local MENU_V_PAD   = 4     -- top/bottom padding
local MENU_ROW_GAP = 2     -- gap between rows
local MENU_GAP     = 6     -- gap between button bottom and menu top
local FONT_NAME    = "Helvetica"
local FONT_SIZE    = 13
local CORNER_R     = 8

-- Element indices inside the dot/button canvas
local EL_BTN   = 1   -- expanded circular background
local EL_ICON  = 2   -- hamburger glyph
local EL_DOT   = 3   -- the small dot
local EL_TRACK = 4   -- invisible hover-tracking area (topmost)

local TRANSPARENT = { red = 0, green = 0, blue = 0, alpha = 0 }

-- ── Colors ────────────────────────────────────────────────────────────────
local function isDark()
  return hs.host.interfaceStyle and hs.host.interfaceStyle() == "Dark"
end

local function makeColors(dark)
  if dark then
    return {
      dot        = { red=0.30, green=0.55, blue=1.00, alpha=0.92 },
      btn        = { red=0.20, green=0.45, blue=0.95, alpha=0.95 },
      btn_icon   = { red=1,    green=1,    blue=1,    alpha=1    },
      menu_bg    = { red=0.16, green=0.16, blue=0.16, alpha=0.97 },
      item_hover = { red=0.30, green=0.30, blue=0.30, alpha=1    },
      item_text  = { red=1,    green=1,    blue=1,    alpha=1    },
      border     = { red=0.38, green=0.38, blue=0.38, alpha=1    },
    }
  else
    return {
      dot        = { red=0.20, green=0.42, blue=0.92, alpha=0.85 },
      btn        = { red=0.18, green=0.40, blue=0.90, alpha=0.95 },
      btn_icon   = { red=1,    green=1,    blue=1,    alpha=1    },
      menu_bg    = { red=0.97, green=0.97, blue=0.97, alpha=0.97 },
      item_hover = { red=0.86, green=0.86, blue=0.86, alpha=1    },
      item_text  = { red=0.10, green=0.10, blue=0.10, alpha=1    },
      border     = { red=0.75, green=0.75, blue=0.75, alpha=1    },
    }
  end
end

-- ── Module state ─────────────────────────────────────────────────────────
---@type string|nil
local currentState   = nil   -- "dot" | "button" | "menu"
---@type {x: number, y: number}|nil
local dotCenter      = nil   -- anchor shared by both canvases
---@type table|nil
local hitCanvas      = nil   -- dot + button, built once
---@type table|nil
local menuCanvas     = nil   -- action menu, rebuilt only when the menu changes
local menuSig        = nil   -- signature of what menuCanvas was built for
local menuSize       = { w = 0, h = 0 }
local menuRowElems   = {}    -- action name → element index of its hover background
---@type table|nil
local clickTap       = nil   -- mouseDown → button click + outside dismiss
---@type function|nil
local onActionCb     = nil
local currentActions = {}
---@type table|nil
local colors_        = nil   -- cached colour table
local colorsDark     = nil   -- interface style colors_ was built for
local menuItemRects  = {}    -- action name → absolute screen rect
local labelWidths    = {}    -- label → measured width (labels come from config)
---@type function
local transitionToMenu       -- defined below; referenced by the click tap

-- ── Public callback setter ────────────────────────────────────────────────
--- Register the callback invoked when an action is selected.
--@param fn function(actionName: string)
function M.setOnAction(fn)
  onActionCb = fn
end

-- ── Internal helpers ──────────────────────────────────────────────────────
local function colors()
  local dark = isDark()
  if not colors_ or colorsDark ~= dark then
    colors_    = makeColors(dark)
    colorsDark = dark
  end
  return colors_
end

local function stopTaps()
  if clickTap then clickTap:stop(); clickTap = nil end
end

-- Native text measurement: no throwaway canvas, and the result is cached since
-- labels come from the config and never change at runtime.
local function measureLabel(label)
  local w = labelWidths[label]
  if w then return w end
  local sz = hs.drawing.getTextDrawingSize(label, { font = FONT_NAME, size = FONT_SIZE })
  w = (sz and sz.w and sz.w + 4) or (FONT_SIZE * #label * 0.65)
  labelWidths[label] = w
  return w
end

-- ── Dot / button canvas ───────────────────────────────────────────────────

-- Show either the dot or the expanded button by flipping element actions —
-- no allocation, no window churn.
local function applyState(state)
  if not hitCanvas then return end
  local showBtn = (state ~= "dot")
  hitCanvas:elementAttribute(EL_BTN,  "action", showBtn and "fill" or "skip")
  hitCanvas:elementAttribute(EL_ICON, "action", showBtn and "strokeAndFill" or "skip")
  hitCanvas:elementAttribute(EL_DOT,  "action", showBtn and "skip" or "fill")
  currentState = state
end

local function buildHitCanvas()
  local col = colors()
  local d   = BTN_D
  local c   = hs.canvas.new({ x = 0, y = 0, w = d, h = d })
  c:level(hs.canvas.windowLevels.floating)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  c:clickActivating(false)

  -- 1: expanded circular background (hidden in dot state)
  c:appendElements({
    type = "rectangle", action = "skip", fillColor = col.btn,
    roundedRectRadii = { xRadius = d/2, yRadius = d/2 },
    frame = { x = 0, y = 0, w = d, h = d },
  })
  -- 2: hamburger icon ≡
  c:appendElements({
    type = "text", action = "skip", text = "≡",
    textFont = FONT_NAME, textSize = 16,
    textColor = col.btn_icon, textAlignment = "center",
    frame = { x = 0, y = (d-18)/2, w = d, h = 18 },
  })
  -- 3: the dot, centred in the larger canvas
  c:appendElements({
    type = "rectangle", action = "fill", fillColor = col.dot,
    roundedRectRadii = { xRadius = DOT_D/2, yRadius = DOT_D/2 },
    frame = { x = (d-DOT_D)/2, y = (d-DOT_D)/2, w = DOT_D, h = DOT_D },
  })
  -- 4: invisible hover area covering the whole canvas
  c:appendElements({
    type = "rectangle", action = "fill", fillColor = TRANSPARENT,
    frame = { x = 0, y = 0, w = d, h = d },
    trackMouseEnterExit = true,
  })

  c:mouseCallback(function(_cnv, msg, id)
    if id ~= EL_TRACK or not dotCenter then return end
    -- While the menu is open the button stays put: leaving its circle to reach
    -- the menu must not collapse it back to a dot.
    if currentState == "menu" then return end
    if msg == "mouseEnter" then
      if currentState ~= "button" then applyState("button") end
    elseif msg == "mouseExit" then
      if currentState ~= "dot" then applyState("dot") end
    end
  end)

  hitCanvas = c
end

-- Re-apply colours to a reused canvas (the user may have switched appearance).
local function refreshHitColors()
  if not hitCanvas then return end
  local col = colors()
  hitCanvas:elementAttribute(EL_BTN,  "fillColor", col.btn)
  hitCanvas:elementAttribute(EL_ICON, "textColor", col.btn_icon)
  hitCanvas:elementAttribute(EL_DOT,  "fillColor", col.dot)
end

-- ── Menu canvas ───────────────────────────────────────────────────────────

local function menuSignature(actions, dark)
  local parts = { dark and "dark" or "light" }
  for _, act in ipairs(actions) do
    parts[#parts + 1] = act.name .. "\1" .. act.label
  end
  return table.concat(parts, "\2")
end

-- Build the menu once per (action list, appearance).  Element frames are
-- canvas-relative, so later invocations only need :frame() to reposition it.
local function buildMenuCanvas(actions)
  local col = colors()
  local maxLabelW = MENU_MIN_W - MENU_H_PAD * 2
  for _, act in ipairs(actions) do
    local w = measureLabel(act.label)
    if w > maxLabelW then maxLabelW = w end
  end
  local menuW = maxLabelW + MENU_H_PAD * 2
  local n     = #actions
  local menuH = MENU_V_PAD * 2 + n * MENU_ITEM_H + math.max(0, n-1) * MENU_ROW_GAP

  local c = hs.canvas.new({ x = 0, y = 0, w = menuW, h = menuH })
  c:level(hs.canvas.windowLevels.floating)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  c:clickActivating(false)

  -- Background
  c:appendElements({
    type = "rectangle", action = "fill", fillColor = col.menu_bg,
    roundedRectRadii = { xRadius = CORNER_R, yRadius = CORNER_R },
    frame = { x = 0, y = 0, w = menuW, h = menuH },
  })
  -- Border
  c:appendElements({
    type = "rectangle", action = "stroke",
    strokeColor = col.border, strokeWidth = 0.5,
    roundedRectRadii = { xRadius = CORNER_R, yRadius = CORNER_R },
    frame = { x = 0.5, y = 0.5, w = menuW-1, h = menuH-1 },
  })

  local rowElems = {}
  local rowByIdx = {}
  local elemIdx  = 3   -- 1=bg, 2=border, items follow

  for i, act in ipairs(actions) do
    local iy = MENU_V_PAD + (i-1) * (MENU_ITEM_H + MENU_ROW_GAP)
    rowElems[act.name] = elemIdx
    rowByIdx[elemIdx]  = act.name

    -- Row hover background (transparent by default)
    c:appendElements({
      type = "rectangle", action = "fill", fillColor = TRANSPARENT,
      roundedRectRadii = { xRadius = 4, yRadius = 4 },
      frame = { x = 2, y = iy, w = menuW-4, h = MENU_ITEM_H },
      trackMouseEnterExit = true,
    })
    elemIdx = elemIdx + 1

    -- Row label
    c:appendElements({
      type = "text", text = act.label,
      textFont = FONT_NAME, textSize = FONT_SIZE,
      textColor = col.item_text, textAlignment = "left",
      frame = { x = MENU_H_PAD, y = iy+(MENU_ITEM_H-FONT_SIZE-4)/2,
                w = menuW-MENU_H_PAD*2, h = FONT_SIZE+6 },
    })
    elemIdx = elemIdx + 1
  end

  c:mouseCallback(function(_cnv, msg, id)
    if currentState ~= "menu" then return end
    if not rowByIdx[id] then return end
    if msg == "mouseEnter" then
      c:elementAttribute(id, "fillColor", colors().item_hover)
    elseif msg == "mouseExit" then
      c:elementAttribute(id, "fillColor", TRANSPARENT)
    end
  end)

  menuCanvas   = c
  menuRowElems = rowElems
  menuSize     = { w = menuW, h = menuH }
end

-- Place the (already built) menu below the button, flipping above if needed,
-- and recompute the absolute screen rect of every row for click hit-testing.
local function positionMenu(center)
  ---@type table
  local c      = menuCanvas
  local menuW  = menuSize.w
  local menuH  = menuSize.h
  local screen = hs.screen.mainScreen():frame()

  local mx = center.x - menuW / 2
  ---@type number
  local my = center.y + BTN_D/2 + MENU_GAP
  if my + menuH > screen.y + screen.h then
    my = center.y - BTN_D/2 - MENU_GAP - menuH
  end
  if mx + menuW > screen.x + screen.w then mx = screen.x + screen.w - menuW end
  if mx < screen.x then mx = screen.x end

  c:frame({ x = mx, y = my, w = menuW, h = menuH })

  local rects = {}
  for i, act in ipairs(currentActions) do
    local iy = MENU_V_PAD + (i-1) * (MENU_ITEM_H + MENU_ROW_GAP)
    rects[act.name] = { x = mx, y = my + iy, w = menuW, h = MENU_ITEM_H }
    -- Clear any hover highlight left over from the previous time it was shown.
    local idx = menuRowElems[act.name]
    if idx then c:elementAttribute(idx, "fillColor", TRANSPARENT) end
  end
  menuItemRects = rects
end

-- Build (or reuse), place and show the menu.  Declared local above.
transitionToMenu = function()
  local dark = isDark()
  local sig  = menuSignature(currentActions, dark)
  if not menuCanvas or menuSig ~= sig then
    if menuCanvas then menuCanvas:hide(); menuCanvas:delete() end
    menuCanvas = nil
    buildMenuCanvas(currentActions)
    menuSig = sig
  end
  positionMenu(dotCenter)
  currentState = "menu"   -- set before show(): the row callbacks check it
  ---@type table
  local c = menuCanvas
  c:show()
  log.d("popup: → menu")
end

-- ── Hide / destroy ────────────────────────────────────────────────────────

--- Hide everything and reset transient state.
-- The canvases are kept (hidden) so the next selection costs no allocation.
function M.hide()
  stopTaps()
  if menuCanvas then menuCanvas:hide() end
  if hitCanvas  then hitCanvas:hide()  end
  currentState   = nil
  dotCenter      = nil
  currentActions = {}
  menuItemRects  = {}
end

--- Release every canvas (used by AgentMenu:stop()).
function M.destroy()
  M.hide()
  if menuCanvas then menuCanvas:delete(); menuCanvas = nil end
  if hitCanvas  then hitCanvas:delete();  hitCanvas  = nil  end
  menuSig      = nil
  menuRowElems = {}
  colors_      = nil
  colorsDark   = nil
end

-- ── Event taps ────────────────────────────────────────────────────────────
-- Only clicks need a tap now, and it runs only while the popup is on screen.
local function startTaps()
  clickTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDown,
      hs.eventtap.event.types.rightMouseDown },
    function(event)
      if not dotCenter then return false end
      local pos = event:location()

      if currentState == "menu" then
        local mf = menuCanvas and menuCanvas:frame()
        if mf and pos.x >= mf.x and pos.x <= mf.x+mf.w and
                  pos.y >= mf.y and pos.y <= mf.y+mf.h then
          -- Click inside menu – find the item
          for name, r in pairs(menuItemRects) do
            if pos.x >= r.x and pos.x <= r.x+r.w and
               pos.y >= r.y and pos.y <= r.y+r.h then
              log.d("popup: item clicked: " .. name)
              M.hide()
              if onActionCb then onActionCb(name) end
              return true
            end
          end
          return false   -- inside menu but between rows
        else
          M.hide()
          return false
        end

      elseif currentState == "button" then
        local bf = hitCanvas and hitCanvas:frame()
        if bf and pos.x >= bf.x and pos.x <= bf.x+bf.w and
                  pos.y >= bf.y and pos.y <= bf.y+bf.h then
          transitionToMenu()
          return true    -- consume so the click doesn't reach the app
        else
          M.hide()
          return false
        end

      else  -- "dot" state: any click elsewhere dismisses
        M.hide()
        return false
      end
    end
  )
  clickTap:start()
end

-- ── Public API ────────────────────────────────────────────────────────────
--- Return true when the quick-menu is currently visible (any state).
-- Used by selection.lua to yield mouse-down handling to the popup.
function M.isActive()
  return currentState ~= nil
end

--- Show the quick-menu dot near the selection rect or current mouse position.
--@param actions   table  List of {name=string, label=string}
--@param position  table  {x,y,w,h} selection rect, or nil → near mouse
function M.show(actions, position)
  M.hide()
  if not actions or #actions == 0 then return end

  currentActions = actions

  -- Anchor point: right edge of selection or near the mouse cursor
  local cx, cy
  if position then
    cx = position.x + position.w + 16
    cy = position.y + position.h / 2
  else
    local mp = hs.mouse.absolutePosition()
    cx = mp.x + 20
    cy = mp.y
  end

  -- Clamp so the button/menu always fits on screen
  local screen = hs.screen.mainScreen():frame()
  cx = math.max(screen.x + BTN_D, math.min(cx, screen.x + screen.w - BTN_D))
  cy = math.max(screen.y + BTN_D, math.min(cy, screen.y + screen.h - BTN_D))

  dotCenter = { x = cx, y = cy }

  if not hitCanvas then
    buildHitCanvas()
  else
    refreshHitColors()
  end
  ---@type table
  local c = hitCanvas
  c:frame({ x = cx - BTN_D/2, y = cy - BTN_D/2, w = BTN_D, h = BTN_D })

  -- The tracking area only reports crossings, so decide the initial state from
  -- where the pointer already is (it is normally just outside the dot).
  local mp = hs.mouse.absolutePosition()
  local inside = mp.x >= cx - BTN_D/2 and mp.x <= cx + BTN_D/2
             and mp.y >= cy - BTN_D/2 and mp.y <= cy + BTN_D/2
  applyState(inside and "button" or "dot")
  c:show()

  log.d("popup: showing " .. currentState .. " at " .. cx .. "," .. cy)
  startTaps()
end

return M
