-- Static cross-reference check: every `panel.x` / `finder.x` / `geometry.x` /
-- `store.x` / `cfg.x` mentioned anywhere in the spoon must actually exist.
-- Catches the class of typo that only shows up when a rare branch runs.
-- Locate ourselves so the suite runs from anywhere; DF_LIB lets the mutation
-- harness point the same tests at a patched copy of lib/.
local HERE = debug.getinfo(1, "S").source:match("^@(.*)/") or "."
local ROOT = HERE .. "/../"
local R = os.getenv("DF_LIB") or (ROOT .. "lib/")
local W = dofile(HERE .. "/world.lua")
hs = (W.new())

local mods = {
  config   = dofile(R .. "config.lua"),
  geometry = dofile(R .. "geometry.lua"),
  store    = dofile(R .. "store.lua"),
  finder   = dofile(R .. "finder.lua"),
  panel    = dofile(R .. "panel.lua"),
  watchers = dofile(R .. "watchers.lua"),
}
local cfg = mods.config.loadConfig()

local pass, fail = 0, 0
local function ck(what, ok)
  if ok then pass = pass + 1 else fail = fail + 1; print("  MISSING " .. what) end
end

local files = { "init.lua", "lib/panel.lua", "lib/watchers.lua", "lib/geometry.lua",
                "lib/store.lua", "lib/finder.lua" }
-- `configLib` is init.lua's local name for the config module.
local aliases = { panel = "panel", finder = "finder", geometry = "geometry",
                  store = "store", watchers = "watchers", configLib = "config" }

for _, rel in ipairs(files) do
  local src = assert(io.open(ROOT .. rel)):read("*a")
  for alias, mod in pairs(aliases) do
    for name in src:gmatch(alias .. "%.([%a_][%w_]*)") do
      -- skip prose mentions of a file ("see panel.lua")
      if name ~= "lua" then
        ck(rel .. ": " .. alias .. "." .. name, mods[mod][name] ~= nil)
      end
    end
  end
  for name in src:gmatch("cfg%.([%a_][%w_]*)") do
    -- `cfg.hotkeys.<name>` and the `_`-prefixed internals are not top-level keys
    if name ~= "hotkeys" then
      ck(rel .. ": cfg." .. name, cfg[name] ~= nil)
    end
  end
end

-- The example config has to survive the validator, and must not advertise a key
-- the validator does not know: a config_example.lua that errors out, or that
-- documents a field nothing reads, is worse than not shipping one.
local example = dofile(ROOT .. "config_example.lua")
local okEx, errEx = pcall(mods.config.loadConfig, example)
ck("config_example.lua passes loadConfig", okEx, errEx)
for key in pairs(example) do
  ck("config_example.lua: " .. key .. " is a real config key", cfg[key] ~= nil)
end

print(string.format("%d references resolved, %d missing", pass, fail))
os.exit(fail == 0 and 0 or 1)
