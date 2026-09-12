--- geometry.lua — Frame math for DropFinder.spoon
-- Pure rect arithmetic plus applyFrame, the one operation that has to talk to a
-- window: set, read back, retry once.
--
-- Nothing in here hardcodes Finder's minimum window height (measured: 344 with
-- a toolbar, 324 without) or AppKit's off-screen clamp (measured: ~40px
-- horizontally, ~52px vertically).  Both are discovered at runtime from what
-- applyFrame reads back, because neither is a documented API and both move with
-- the OS version and screen layout.  That read-back is also why there is no
-- measureMinHeight here: squeezing a window to 1px to learn its minimum is
-- visible as a flicker, and the first real layout reveals the same number.

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

-- ── Rect helpers ───────────────────────────────────────────────────────────

--- Compare two rects within a pixel tolerance.
--@param a table|nil
--@param b table|nil
--@param tol number
--@return boolean
function M.framesEqual(a, b, tol)
  if not a or not b then return false end
  tol = tol or 4
  return math.abs(a.x - b.x) <= tol
     and math.abs(a.y - b.y) <= tol
     and math.abs(a.w - b.w) <= tol
     and math.abs(a.h - b.h) <= tol
end

local function intersectArea(a, b)
  local x1 = math.max(a.x, b.x)
  local y1 = math.max(a.y, b.y)
  local x2 = math.min(a.x + a.w, b.x + b.w)
  local y2 = math.min(a.y + a.h, b.y + b.h)
  if x2 <= x1 or y2 <= y1 then return 0 end
  return (x2 - x1) * (y2 - y1)
end

--- Union rect of every screen's fullFrame (the "desktop" AppKit clamps against).
--@return table {x, y, w, h}
function M.unionFrame()
  local screens = hs.screen.allScreens()
  if #screens == 0 then return { x = 0, y = 0, w = 0, h = 0 } end
  local u = screens[1]:fullFrame()
  local x1, y1 = u.x, u.y
  local x2, y2 = u.x + u.w, u.y + u.h
  for i = 2, #screens do
    local f = screens[i]:fullFrame()
    x1 = math.min(x1, f.x)
    y1 = math.min(y1, f.y)
    x2 = math.max(x2, f.x + f.w)
    y2 = math.max(y2, f.y + f.h)
  end
  return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

--- Total area of `frame` that overlaps any screen.
--@param frame table
--@return number  px^2
function M.visibleArea(frame)
  local total = 0
  for _, s in ipairs(hs.screen.allScreens()) do
    total = total + intersectArea(frame, s:fullFrame())
  end
  return total
end

--- Is a frame meaningfully on screen?  Used for the hidden/shown decision, so
-- it deliberately asks about live geometry rather than comparing against a
-- remembered park rect: a reload or a display change stales the remembered
-- value, whereas this stays true.
--@param frame table|nil
--@return boolean
function M.isOnScreen(frame)
  if not frame or frame.w <= 0 or frame.h <= 0 then return false end
  return M.visibleArea(frame) > 0.25 * frame.w * frame.h
end

--- The screen a rect mostly sits on, the way Hammerspoon defines
-- `hs.window:screen()` -- largest intersection, not the screen under the centre.
-- Used when a pane has no window object to ask: standing on another Space,
-- Finder hands over no window at all (measured on macOS 26 -- `allWindows()`
-- answers with the desktop and nothing else), and the frame the pane was last
-- seen at is then the only thing left that says which display it is on.
--@param frame table|nil
--@return table|nil  hs.screen
function M.screenOf(frame)
  if not frame then return nil end
  local best, bestArea = nil, 0
  for _, s in ipairs(hs.screen.allScreens()) do
    local a = intersectArea(frame, s:fullFrame())
    if a > bestArea then best, bestArea = s, a end
  end
  return best
end

-- ── Screen selection ───────────────────────────────────────────────────────

--- Resolve cfg.screenPolicy to a screen.
--@param policy string  "mouse" | "focused" | "main"
--@return table  hs.screen
function M.pickScreen(policy)
  local s
  if policy == "mouse" then
    s = hs.mouse.getCurrentScreen()
  elseif policy == "focused" then
    local w = hs.window.focusedWindow()
    s = w and w:screen() or nil
  end
  return s or hs.screen.mainScreen() or hs.screen.allScreens()[1]
end

-- ── Panel layout ───────────────────────────────────────────────────────────

--- The full-width strip along the bottom of a screen's usable area.
-- Uses frame() rather than fullFrame() so a pinned Dock does not push the panel
-- underneath itself and straight into the vertical clamp.
--@param screen table     hs.screen
--@param cfg table
--@param minHeight number|nil  Measured Finder minimum; 0 when not yet known
--@return table {x, y, w, h}
function M.panelFrame(screen, cfg, minHeight)
  local sf = screen:frame()
  local h = math.floor(sf.h * cfg.heightRatio)
  h = math.max(h, minHeight or 0)
  h = math.min(h, sf.h)
  local y = sf.y + sf.h - h - cfg.bottomGap
  -- A bottomGap large enough to push the panel off the top is the user's
  -- problem, but silently inverting the panel is ours.
  y = math.max(y, sf.y)
  return { x = sf.x, y = y, w = sf.w, h = h }
end

--- Split the panel between the sides that currently exist.
-- One live side takes the whole panel width (requirement 9); two split it, with
-- the rounding remainder going to the right so there is never a 1px seam.
--@param screen table
--@param cfg table
--@param minHeight number|nil
--@param liveSides table  { left = true|nil, right = true|nil }
--@return table  { left = rect|nil, right = rect|nil }
function M.paneFrames(screen, cfg, minHeight, liveSides)
  local pf = M.panelFrame(screen, cfg, minHeight)
  local out = {}
  if liveSides.left and liveSides.right then
    local half = math.floor((pf.w - cfg.paneGap) / 2)
    out.left  = { x = pf.x, y = pf.y, w = half, h = pf.h }
    out.right = { x = pf.x + half + cfg.paneGap, y = pf.y,
                  w = pf.w - half - cfg.paneGap, h = pf.h }
  else
    for _, side in ipairs({ "left", "right" }) do
      if liveSides[side] then
        out[side] = { x = pf.x, y = pf.y, w = pf.w, h = pf.h }
      end
    end
  end
  return out
end

-- ── Parking (hideMode == "park") ───────────────────────────────────────────

--- The screen holding the requested union corner.
-- Scored rather than looked up by point, because an L-shaped multi-monitor
-- layout can leave the union corner over empty space.
local function cornerScreen(corner)
  local best, bestScore
  for _, s in ipairs(hs.screen.allScreens()) do
    local f = s:fullFrame()
    -- Primary term is the horizontal extreme in the requested direction,
    -- secondary term the bottom edge; scaled so primary always dominates.
    local primary = (corner == "bottom-left") and -f.x or (f.x + f.w)
    local score = primary * 1e6 + (f.y + f.h)
    if not bestScore or score > bestScore then best, bestScore = s, score end
  end
  return best
end

--- The rect to *request* when parking a window of the given size.
-- Deliberately fully off the corner screen: AppKit's constrainFrameRect: will
-- pull it back to the smallest legal sliver, which is exactly what we want and
-- is more accurate than any constant we could write down.  The caller must use
-- applyFrame's return value, not this rect, as the park position of record.
--@param cfg table
--@param size table  {w, h} — parking never resizes, so pass the live size
--@return table {x, y, w, h}
function M.parkRequest(cfg, size)
  local s = cornerScreen(cfg.parkCorner)
  if not s then return { x = 0, y = 0, w = size.w, h = size.h } end
  local f = s:fullFrame()
  local x = (cfg.parkCorner == "bottom-left") and (f.x - size.w) or (f.x + f.w)
  return { x = x, y = f.y + f.h, w = size.w, h = size.h }
end

-- ── Window operations ──────────────────────────────────────────────────────

--- Set a window's frame, read it back, and retry once on a mismatch.
-- Finder vetoes heights below its minimum and AppKit vetoes off-screen
-- positions, so the read-back is not paranoia — it is how both limits are
-- discovered.  Returns the frame the window actually took.
--@param win table  hs.window
--@param rect table
--@param tol number|nil
--@param retry boolean|nil  Default true.  Pass false when a mismatch is the
--                          expected outcome, as it is when parking: a second
--                          attempt would only cost another Finder reflow.
--@return table|nil  Actual frame, or nil if the window went away
function M.applyFrame(win, rect, tol, retry)
  if not win then return nil end
  local ok = pcall(function() win:setFrame(rect, 0) end)
  if not ok then return nil end
  local got = win:frame()
  if retry ~= false and got and not M.framesEqual(got, rect, tol or 4) then
    pcall(function() win:setFrame(rect, 0) end)
    got = win:frame()
  end
  return got
end

return M
