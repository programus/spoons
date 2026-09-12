--- config_example.lua — Full configuration reference for DropFinder.spoon
--
-- Usage (in ~/.hammerspoon/init.lua):
--
--   hs.loadSpoon("DropFinder")
--   local cfg = require("dropfinder_config")   -- file lives in ~/.hammerspoon/
--   spoon.DropFinder:configure(cfg):start()
--
-- Copy this file to ~/.hammerspoon/dropfinder_config.lua and edit as needed.
-- Every field is optional; `spoon.DropFinder:configure({}):start()` is valid.

return {
  -- ────────────────────────────────────────────────────────────────────────
  -- 1. Size and position
  -- ────────────────────────────────────────────────────────────────────────

  -- Optional. Default 0.25. Panel height as a fraction of screen:frame().h
  -- (the area above the Dock and below the menu bar).
  -- Finder refuses to make a window shorter than 344px (324px without a
  -- toolbar), so on a 1080p display anything below ~0.33 is silently raised to
  -- that floor.  0.35–0.4 is a more useful panel on most displays.
  heightRatio = 0.4,

  -- Optional. Default 0. Gap in px between the panel and the bottom of the
  -- usable area.
  bottomGap = 0,

  -- Optional. Default 0. Gap in px between the two panes.  0 means their edges
  -- touch, which is what makes the pair read as one panel.
  paneGap = 0,

  -- Optional. Defaults { left = "~/Downloads", right = "~" }.
  -- Where a side is opened when there is nothing remembered for it — first run,
  -- or every remembered path has been deleted.  A side that was closed and is
  -- being rebuilt goes back to the path it was last showing, not to this.
  -- `~` is expanded; a path that is not a directory is rejected at configure().
  defaultPaths = { left = "~/Downloads", right = "~" },

  -- Optional. Default "mouse". Which screen the panel appears on.
  --   "mouse"   — the screen the pointer is on (requirement 8)
  --   "focused" — the screen of the focused window
  --   "main"    — the screen with the menu bar
  screenPolicy = "mouse",

  -- ────────────────────────────────────────────────────────────────────────
  -- 2. Hiding
  -- ────────────────────────────────────────────────────────────────────────

  -- Optional. Default "park".
  --   "park"     — move both panes to a screen corner.  macOS will not let a
  --                window leave the desktop entirely (AppKit keeps ~40px
  --                horizontally and ~52px vertically on screen), so a small
  --                sliver stays visible.  Nothing is destroyed, so showing the
  --                panel again is a single move: scroll position, selection and
  --                per-tab history all survive.
  --   "minimize" — minimize both panes instead.  No sliver, but two thumbnails
  --                appear in the Dock and Cmd+Tab to Finder will not bring them
  --                back — only the hotkey does.
  hideMode = "park",

  -- Optional. Default "bottom-right". Which corner "park" parks in.
  --   "bottom-right" | "bottom-left"
  parkCorner = "bottom-right",

  -- Optional. Default 5000 (px²). If a parked pane still shows more than this,
  -- DropFinder logs a warning suggesting hideMode = "minimize".  The 40×52px
  -- clamp is measured behaviour, not documented API, so a future macOS or an
  -- unusual display arrangement may leave more of the window visible.
  parkMaxVisible = 5000,

  -- ────────────────────────────────────────────────────────────────────────
  -- 3. Behaviour
  -- ────────────────────────────────────────────────────────────────────────

  -- Optional. Default true. On hide, return focus to whatever had it before the
  -- panel came out (requirement 12) -- the app, or, if the panel came up over one
  -- of your own floating Finder windows, that window itself.  Handing focus to
  -- the app in that case would push the window you were working in behind it.
  restoreFocusOnHide = true,

  -- Optional. Default true. Restore every tab of both sides after Finder is
  -- restarted or a side is closed (requirement 3).  With false, only the tab
  -- that was active comes back.
  -- The tabs arrive over the following few hundred ms, after the panel is
  -- already on screen — so the active tab visibly flickers through them during
  -- a rebuild.  This never happens on an ordinary show/hide, only on a rebuild.
  restoreTabs = true,

  -- Optional. Default false. Hide the toolbar of the panel's windows.  Buys
  -- about 20px of minimum height (324 instead of 344) at the cost of the
  -- toolbar's search field and view switcher.
  hideToolbar = false,

  -- Optional. Default false. Immediately pull a pane back into place if the user
  -- drags it somewhere else.  With false, a dragged pane is left where the user
  -- put it until the next time the panel is shown.
  snapBack = false,

  -- Optional. Default true. Persist the pane model (tab ids, tab paths, which
  -- tab was active, the measured minimum height) through hs.settings.
  persist = true,

  -- ────────────────────────────────────────────────────────────────────────
  -- 4. Spaces
  -- ────────────────────────────────────────────────────────────────────────

  -- Optional. Default true. When the hotkey is pressed from another Space, move
  -- the panel to the current one (requirement 10).  This uses hs.spaces, which
  -- is a private API: every call is guarded, and if a macOS update removes it
  -- DropFinder falls back below and says so once.
  crossSpace = true,

  -- Optional. Default "activate". What to do when a pane is on another Space and
  -- cannot be moved.
  --   "activate" — leave it there and show it anyway; macOS switches you to its
  --                Space when it takes focus.  Nothing is lost.
  --   "recreate" — close that side and rebuild it from its remembered paths in
  --                the current Space.  Always works, costs ~300ms per tab, and
  --                loses scroll position and selection.
  crossSpaceFallback = "activate",

  -- ────────────────────────────────────────────────────────────────────────
  -- 5. Adopt
  -- ────────────────────────────────────────────────────────────────────────

  -- Optional. Default "mouse". Which side the adopt hotkey merges the frontmost
  -- floating Finder window into.
  --   "mouse"       — the pane whose centre is nearer the pointer
  --   "lastFocused" — the side you last worked in
  --   "left" | "right"
  adoptTarget = "mouse",

  -- ────────────────────────────────────────────────────────────────────────
  -- 6. Diagnostics and tuning
  -- ────────────────────────────────────────────────────────────────────────

  -- Optional. Default true. Alert when TotalFinder is injected into Finder.
  -- TotalFinder replaces Finder's tab model (every tab becomes a real window),
  -- which DropFinder misreads completely.  The two should not run together.
  warnOnTotalFinder = true,

  -- Optional. Default 4 (px). Tolerance when comparing window frames.  Finder
  -- quantises some geometry, so exact comparison produces phantom differences.
  frameTolerance = 4,

  -- Optional. Default 0.15 (s). How long to wait for Finder to finish creating a
  -- window or tab before reading it.  Raise it if the log shows tabs being
  -- created but not recognised.
  settleDelay = 0.15,

  -- Optional. Default false, and currently unread: requirement 6 says the panel
  -- stays put when focus moves elsewhere.  The key exists so that changing one's
  -- mind later is a config edit rather than a schema change.
  hideOnFocusLoss = false,

  -- ────────────────────────────────────────────────────────────────────────
  -- 7. Hotkeys
  --    Either declare them here, or leave this out and call
  --    spoon.DropFinder:bindHotkeys({ toggle = {...}, adopt_frontmost = {...} }),
  --    which overrides whatever is set here.
  -- ────────────────────────────────────────────────────────────────────────
  hotkeys = {
    -- Tri-state: hidden → show and focus; showing but unfocused → raise and
    -- focus; showing and focused → hide.
    toggle = { mods = { "ctrl", "alt" }, key = "f" },

    -- Merge the frontmost floating Finder window into the panel as tab(s).
    adopt = { mods = { "ctrl", "alt", "shift" }, key = "f" },

    -- Any action also takes a list, and answers to every key in it:
    --   toggle = {
    --     { mods = { "alt" },  key = "`" },   -- TotalFinder's Visor key
    --     { mods = { "ctrl" }, key = "pad0" },
    --   },
    -- and `false` binds nothing at all:
    --   adopt = false,
  },
}
