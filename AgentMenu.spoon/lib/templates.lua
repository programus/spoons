--- templates.lua — HTML template loader + i18n string lookup
--
-- Templates live in   AgentMenu.spoon/res/templates/<name>
-- i18n files live in  AgentMenu.spoon/res/i18n/<lang>.lua
--
-- Template syntax: {{KEY}}
--   i18n strings are automatically substituted first; caller-supplied vars
--   override them.  Unresolved placeholders are left as-is ({{KEY}}) so
--   they are easy to spot during development.
--
-- Usage (after init.lua calls M.setLang):
--   local templates = req("templates")
--   templates.setLang("zh")
--   local html = templates.load("result_dialog.html", { TOOLBAR_CONTENT = "..." })
--   local s    = templates.t("SEND_LABEL")   -- → "发送"

---@diagnostic disable-next-line: undefined-global
local hs = hs

local M = {}

-- Derive the spoon root from this file's own path (lib/ → parent).
local _srcFile   = (debug.getinfo(1, "S") or {}).source or ""
_srcFile         = _srcFile:match("^@(.+)$") or ""
local _srcDir    = _srcFile:match("^(.+)/[^/]+$") or "."
local _spoonPath = _srcDir:match("^(.+)/lib$") or _srcDir   -- strip trailing /lib

local _strings = {}   -- loaded i18n table
local _cache   = {}   -- raw template file cache

--- Load i18n strings for the given language.
-- Falls back to "en" if the file for the requested language is missing.
-- Safe to call multiple times; clears template cache on language change.
--@param lang string  ISO 639-1 code, e.g. "en", "zh", "ja"  (default "en")
function M.setLang(lang)
  lang = lang or "en"
  _cache = {}   -- invalidate rendered-template cache on language change

  local candidates = {
    _spoonPath .. "/res/i18n/" .. lang .. ".lua",
    _spoonPath .. "/res/i18n/en.lua",
  }

  for _, path in ipairs(candidates) do
    local f = io.open(path, "r")
    if f then
      f:close()
      local ok, t = pcall(dofile, path)
      if ok and type(t) == "table" then
        _strings = t
        return
      end
    end
  end

  _strings = {}
  hs.logger.new("AgentMenu.templates", "warning").w(
    "No i18n file found for lang='" .. lang .. "'; labels will show raw keys.")
end

--- Get a single localised string by key.
-- Returns the key itself (as a visible fallback) when the key is absent.
--@param key string
--@return string
function M.t(key)
  return _strings[key] or key
end

--- Load a template file and substitute {{KEY}} placeholders.
-- i18n strings are used as base substitutions; vars override them.
-- Template files are cached after first read; call clearCache() to reload.
--@param name string     Filename under res/templates/, e.g. "result_dialog.html"
--@param vars table|nil  Extra key→value substitutions (override i18n values)
--@return string         Rendered HTML
function M.load(name, vars)
  if not _cache[name] then
    local path = _spoonPath .. "/res/templates/" .. name
    local f = io.open(path, "r")
    if not f then
      error("[AgentMenu] template not found: " .. path)
    end
    _cache[name] = f:read("*a")
    f:close()
  end

  -- Merge: i18n strings as base, caller vars override
  local subs = {}
  for k, v in pairs(_strings) do subs[k] = v end
  if vars then
    for k, v in pairs(vars) do subs[k] = tostring(v) end
  end

  return (_cache[name]:gsub("{{([%w_]+)}}", function(key)
    local v = subs[key]
    return v ~= nil and v or ("{{" .. key .. "}}")
  end))
end

--- Clear the in-memory template cache.
-- The next load() call will re-read files from disk.
-- Useful during development or after a spoon hot-reload.
function M.clearCache()
  _cache = {}
end

return M
