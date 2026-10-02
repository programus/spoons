-- Minimal `hs` stub so DropFinder's pure modules can run under plain Lua.
-- Filesystem answers are real (via os.rename / io.open); screens are synthetic.
local S = {}

-- Memoised because every answer costs a fork: the mutation gate runs the panel
-- suite dozens of times and path lookups dominated it.  Safe because no suite
-- creates, moves or deletes a file -- the filesystem cannot change under us
-- within one process.
local shCache = {}

local function shTest(flag, p)
  local key = flag .. tostring(p)
  local hit = shCache[key]
  if hit ~= nil then return hit end
  local q = "'" .. tostring(p):gsub("'", "'\\''") .. "'"
  local rc = os.execute("test " .. flag .. " " .. q)
  local ans = rc == 0 or rc == true
  shCache[key] = ans
  return ans
end

local function exists(p) return shTest("-e", p) end
local function isDir(p)  return shTest("-d", p) end

local function normalise(p)
  p = p:gsub("//+", "/")
  if #p > 1 then p = p:gsub("/$", "") end
  return p
end

--- Build the stub.  `screens` is a list of {name, fullFrame, frame}.
function S.install(screens, opts)
  opts = opts or {}
  local settings = {}

  local screenObjs = {}
  for i, s in ipairs(screens) do
    local o = {}
    function o:frame() return { x = s.frame.x, y = s.frame.y, w = s.frame.w, h = s.frame.h } end
    function o:fullFrame() return { x = s.fullFrame.x, y = s.fullFrame.y,
                                    w = s.fullFrame.w, h = s.fullFrame.h } end
    function o:name() return s.name end
    -- Real screens have a numeric id, and it is the only safe way to ask "same
    -- display?": hs hands out a fresh Lua object per call.
    function o:id() return i end
    screenObjs[i] = o
  end

  local hs = {
    fs = {
      pathToAbsolute = function(p)
        if not p or p == "" then return nil end
        p = normalise(p)
        if not exists(p) then return nil end
        return p
      end,
      -- Real hs.fs.displayName answers nil for a path that does not resolve,
      -- and drops `.localized` the way Finder's tab bar does.
      displayName = function(p)
        if not p or not exists(p) then return nil end
        local b = normalise(p):match("([^/]+)$") or p
        return (b:gsub("%.localized$", ""))
      end,
      attributes = function(p, key)
        if not p or not exists(p) then return nil end
        local mode = isDir(p) and "directory" or "file"
        if key == "mode" then return mode end
        return { mode = mode }
      end,
    },
    logger = {
      new = function()
        local noop = function() end
        -- The `*f` variants are real hs.logger methods; a stub without them
        -- turns a log line into a crash on whichever branch reaches for one.
        return { d = noop, i = noop, w = noop, e = noop, v = noop,
                 df = noop, f = noop, wf = noop, ef = noop, vf = noop }
      end,
    },
    settings = {
      set = function(k, v) settings[k] = S.plistRoundTrip(v); return true end,
      get = function(k) return settings[k] end,
      clear = function(k) settings[k] = nil; return true end,
    },
    screen = {
      allScreens = function() return screenObjs end,
      mainScreen = function() return screenObjs[opts.mainIndex or 1] end,
    },
    mouse = {
      getCurrentScreen = function() return screenObjs[opts.mouseIndex or 1] end,
      -- Set by world.setMousePos(); adopt uses it to pick the nearer pane.
      absolutePosition = function() return opts.mousePos end,
    },
    window = {
      focusedWindow = function() return opts.focusedWindow end,
    },
    -- Left empty on purpose: the world simulator fills these in, and a pure
    -- module that reaches for one should fail loudly rather than get a stub.
    application = {},
    alert = { show = function() end },
    -- AppleScript is a hook rather than a stub: the specs that need it pass
    -- opts.applescript and answer whatever their own case is about.  The default
    -- refuses, so a module reaching for Finder in a test that did not arrange it
    -- fails there instead of somewhere later.
    osascript = {
      applescript = function(src)
        if opts.applescript then return opts.applescript(src) end
        return false, nil, { NSLocalizedDescription = "no AppleScript in this test" }
      end,
    },
    timer = {
      secondsSinceEpoch = function() return os.time() end,
      doAfter = function(_, fn) return { stop = function() end, _fn = fn } end,
    },
    inspect = setmetatable({}, { __call = function(_, v) return tostring(v) end }),
  }
  return hs, settings
end

--- Model what NSUserDefaults does to a Lua table: deep copy, and surface the one
--- transformation that would silently break us — a table with integer keys comes
--- back with string keys, because a plist dictionary can only be keyed by string.
function S.plistRoundTrip(v)
  if type(v) ~= "table" then return v end
  local isArray = true
  local n = 0
  for k in pairs(v) do
    n = n + 1
    if type(k) ~= "number" then isArray = false end
  end
  if isArray and n == #v then
    local out = {}
    for i, x in ipairs(v) do out[i] = S.plistRoundTrip(x) end
    return out
  end
  local out = {}
  for k, x in pairs(v) do
    out[type(k) == "number" and tostring(k) or k] = S.plistRoundTrip(x)
  end
  return out
end

--- The user's real three-display layout, from the Phase 0 measurements.
S.REAL_SCREENS = {
  { name = "J584T05", fullFrame = { x = 0, y = 0, w = 2560, h = 1440 },
                      frame     = { x = 0, y = 30, w = 2560, h = 1410 } },
  { name = "HS133PS", fullFrame = { x = 2560, y = 261, w = 1920, h = 1080 },
                      frame     = { x = 2560, y = 261, w = 1920, h = 1080 } },
  { name = "ARZOPA",  fullFrame = { x = -2048, y = 114, w = 2048, h = 1280 },
                      frame     = { x = -2048, y = 114, w = 2048, h = 1280 } },
}

S.ONE_SCREEN = {
  { name = "Solo", fullFrame = { x = 0, y = 0, w = 1920, h = 1080 },
                   frame     = { x = 0, y = 25, w = 1920, h = 1005 } },
}

return S
