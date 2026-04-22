--- popup.lua — Quick-menu: dot → circle button → action menu
--
-- Behaviour:
--   1. After text is selected a small dot appears near the selection.
--   2. Moving the mouse over the dot expands it to a circular button.
--   3. Clicking the button opens a compact dropdown menu.
--   4. Clicking a menu item triggers the action; clicking elsewhere dismisses.
--
---@diagnostic disable-next-line: undefined-global
local hs = hs

local log = hs.logger.new("AgentMenu.popup", "debug")
local M = {}

-- ── Visual constants ──────────────────────────────────────────────────────
local DOT_D        = 10    -- visible dot diameter
local DOT_AREA_D   = 30    -- hover-sensitive area diameter (centred on dot)
local BTN_D        = 36    -- expanded button diameter
local BTN_MARGIN   = 6     -- extra px beyond BTN_D/2 before reverting → dot
local MENU_ITEM_H  = 26    -- menu row height
local MENU_MIN_W   = 120   -- minimum menu width
local MENU_H_PAD   = 12    -- horizontal text padding
local MENU_V_PAD   = 4     -- top/bottom padding
local MENU_ROW_GAP = 2     -- gap between rows
local MENU_GAP     = 6     -- gap between button bottom and menu top
local FONT_SIZE    = 13
local CORNER_R     = 8

-- ── Colors ────────────────────────────────────────────────────────────────
local function makeColors()
  local dark = hs.host.interfaceStyle and hs.host.interfaceStyle() == "Dark"
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
local currentState   = nil   -- "dot" | "button" | "menu"
local dotCenter      = nil   -- {x, y} anchor shared by all canvases
local dotCanvas      = nil
local btnCanvas      = nil
local menuCanvas     = nil
local hoverTap       = nil   -- mouseMoved → dot ↔ button transitions
local clickTap       = nil   -- mouseDown  → button click + outside dismiss
local onActionCb     = nil
local currentActions = {}
local colors_        = nil   -- cached colour table
local menuItemRects  = {}    -- action name → absolute screen rect

-- ── Public callback setter ────────────────────────────────────────────────
--- Register the callback invoked when an action is selected.
--@param fn function(actionName: string)
function M.setOnAction(fn)
  onActionCb = fn
end

-- ── Internal helpers ──────────────────────────────────────────────────────
local function stopTaps()
  if hoverTap then hoverTap:stop(); hoverTap = nil end
  if clickTap  then clickTap:stop();  clickTap  = nil end
end

local function destroyCanvas(c)
  if c then c:hide(); c:delete() end
end

--- Hide everything and reset all state.
function M.hide()
  stopTaps()
  destroyCanvas(menuCanvas); menuCanvas = nil
  destroyCanvas(btnCanvas);  btnCanvas  = nil
  destroyCanvas(dotCanvas);  dotCanvas  = nil
  currentState   = nil
  dotCenter      = nil
  currentActions = {}
  menuItemRects  = {}
  colors_        = nil
end

local function measureLabel(label)
  local tmp = hs.canvas.new({ x=0, y=0, w=500, h=40 })
  tmp:appendElements({
    type="text", text=label, textFont="Helvetica", textSize=FONT_SIZE,
    frame={x=0, y=0, w="100%", h="100%"},
  })
  local sz = tmp:minimumTextSize(1, label)
  tmp:delete()
  return sz and sz.w or (FONT_SIZE * #label * 0.65)
end

-- ── Canvas builders ───────────────────────────────────────────────────────
local function buildDotCanvas(center)
  local hd = DOT_AREA_D   -- canvas size (hover area)
  local d  = DOT_D        -- visible dot size
  local c  = hs.canvas.new({ x=center.x-hd/2, y=center.y-hd/2, w=hd, h=hd })
  c:level(hs.canvas.windowLevels.floating)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  c:clickActivating(false)
  -- Visible dot (centred within the larger canvas)
  c:appendElements({
    type="rectangle", action="fill", fillColor=colors_.dot,
    roundedRectRadii={xRadius=d/2, yRadius=d/2},
    frame={x=(hd-d)/2, y=(hd-d)/2, w=d, h=d},
  })
  return c
end

local function buildButtonCanvas(center)
  local d = BTN_D
  local c = hs.canvas.new({ x=center.x-d/2, y=center.y-d/2, w=d, h=d })
  c:level(hs.canvas.windowLevels.floating)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  c:clickActivating(false)
  -- Circular background
  c:appendElements({
    type="rectangle", action="fill", fillColor=colors_.btn,
    roundedRectRadii={xRadius=d/2, yRadius=d/2},
    frame={x=0, y=0, w=d, h=d},
  })
  -- Hamburger icon ≡
  c:appendElements({
    type="text", text="≡",
    textFont="Helvetica", textSize=16,
    textColor=colors_.btn_icon, textAlignment="center",
    frame={x=0, y=(d-18)/2, w=d, h=18},
  })
  return c
end

local function buildMenuCanvas(center, actions)
  local maxLabelW = MENU_MIN_W - MENU_H_PAD * 2
  for _, act in ipairs(actions) do
    local w = measureLabel(act.label)
    if w > maxLabelW then maxLabelW = w end
  end
  local menuW = maxLabelW + MENU_H_PAD * 2
  local n     = #actions
  local menuH = MENU_V_PAD * 2 + n * MENU_ITEM_H + math.max(0, n-1) * MENU_ROW_GAP

  -- Position below button by default; flip above if no room
  local screen = hs.screen.mainScreen():frame()
  local mx = center.x - menuW / 2
  local my = center.y + BTN_D/2 + MENU_GAP
  if my + menuH > screen.y + screen.h then
    my = center.y - BTN_D/2 - MENU_GAP - menuH
  end
  if mx + menuW > screen.x + screen.w then mx = screen.x + screen.w - menuW end
  if mx < screen.x then mx = screen.x end

  local c = hs.canvas.new({ x=mx, y=my, w=menuW, h=menuH })
  c:level(hs.canvas.windowLevels.floating)
  c:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  c:clickActivating(false)

  -- Background
  c:appendElements({
    type="rectangle", action="fill", fillColor=colors_.menu_bg,
    roundedRectRadii={xRadius=CORNER_R, yRadius=CORNER_R},
    frame={x=0, y=0, w=menuW, h=menuH},
  })
  -- Border
  c:appendElements({
    type="rectangle", action="stroke",
    strokeColor=colors_.border, strokeWidth=0.5,
    roundedRectRadii={xRadius=CORNER_R, yRadius=CORNER_R},
    frame={x=0.5, y=0.5, w=menuW-1, h=menuH-1},
  })

  local bgIdxByName  = {}
  local newItemRects = {}
  local elemIdx = 3   -- 1=bg, 2=border, items follow

  for i, act in ipairs(actions) do
    local iy = MENU_V_PAD + (i-1) * (MENU_ITEM_H + MENU_ROW_GAP)
    bgIdxByName[act.name]  = elemIdx
    newItemRects[act.name] = { x=mx, y=my+iy, w=menuW, h=MENU_ITEM_H }

    -- Row hover background (transparent by default)
    c:appendElements({
      type="rectangle", action="fill",
      fillColor={red=0, green=0, blue=0, alpha=0},
      roundedRectRadii={xRadius=4, yRadius=4},
      frame={x=2, y=iy, w=menuW-4, h=MENU_ITEM_H},
      trackMouseEnterExit=true,
    })
    elemIdx = elemIdx + 1

    -- Row label
    c:appendElements({
      type="text", text=act.label,
      textFont="Helvetica", textSize=FONT_SIZE,
      textColor=colors_.item_text, textAlignment="left",
      frame={x=MENU_H_PAD, y=iy+(MENU_ITEM_H-FONT_SIZE-4)/2,
             w=menuW-MENU_H_PAD*2, h=FONT_SIZE+6},
    })
    elemIdx = elemIdx + 1
  end

  c:mouseCallback(function(_cnv, msg, id, _, _)
    if not menuCanvas then return end
    for name, idx in pairs(bgIdxByName) do
      if idx == id then
        if msg == "mouseEnter" then
          c:elementAttribute(id, "fillColor", colors_.item_hover)
        elseif msg == "mouseExit" then
          c:elementAttribute(id, "fillColor", {red=0, green=0, blue=0, alpha=0})
        end
        break
      end
    end
  end)

  menuItemRects = newItemRects
  return c
end

-- ── State transitions ─────────────────────────────────────────────────────
local function transitionToDot()
  destroyCanvas(btnCanvas);  btnCanvas  = nil
  destroyCanvas(dotCanvas)
  dotCanvas = buildDotCanvas(dotCenter)
  dotCanvas:show()
  currentState = "dot"
  log.d("popup: → dot")
end

local function transitionToButton()
  destroyCanvas(dotCanvas);  dotCanvas  = nil
  destroyCanvas(btnCanvas)
  btnCanvas = buildButtonCanvas(dotCenter)
  btnCanvas:show()
  currentState = "button"
  log.d("popup: → button")
end

local function transitionToMenu()
  -- Leave the button visible; slide the menu in alongside it
  destroyCanvas(menuCanvas)
  menuCanvas = buildMenuCanvas(dotCenter, currentActions)
  menuCanvas:show()
  currentState = "menu"
  log.d("popup: → menu")
end

-- ── Event taps ────────────────────────────────────────────────────────────
local function startTaps()
  -- mouseMoved: drive dot ↔ button transitions by distance from anchor
  hoverTap = hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, function(event)
    if not dotCenter or currentState == "menu" then return false end
    local pos = event:location()
    local dx  = pos.x - dotCenter.x
    local dy  = pos.y - dotCenter.y
    local d2  = dx*dx + dy*dy
    if currentState == "dot" then
      local r = DOT_AREA_D / 2
      if d2 <= r*r then transitionToButton() end
    elseif currentState == "button" then
      local r = BTN_D/2 + BTN_MARGIN
      if d2 > r*r then transitionToDot() end
    end
    return false
  end)
  hoverTap:start()

  -- mouseDown: button click → open menu; outside click → dismiss
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
        local bf = btnCanvas and btnCanvas:frame()
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
  colors_ = makeColors()

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

  dotCenter = { x=cx, y=cy }
  dotCanvas = buildDotCanvas(dotCenter)
  dotCanvas:show()
  currentState = "dot"
  log.d("popup: showing dot at " .. cx .. "," .. cy)
  startTaps()
end

return M