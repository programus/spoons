#!/bin/zsh
# Mutation gate: break one thing in lib/ on purpose and check that the suite
# notices.  A SURVIVED line means the tests are weaker than they look; a NO-OP
# line means the mutant's pattern no longer matches the source, so the mutant
# needs updating rather than the code.
#
# Usage: test/mutate.sh          (needs luajit and perl, both stock on macOS)
set -u
HERE=${0:a:h}
LIB=$HERE/../lib
# A per-run directory: two gates running at once used to rm -rf each other's
# mutants half way through, which reads as a mess of md5 errors and a bogus
# SURVIVED line.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dropfinder-mutants.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

# A fourth argument names the suite to run instead of panel_spec: the config
# module's own rules are checked by pure_spec, and running the big integration
# suite against them would report SURVIVED for want of a test rather than for
# want of code.
run_mut() {
  local label=$1 target=$2 subst=$3 spec=${4:-panel_spec}
  rm -rf "$WORK" && mkdir -p "$WORK"   # safe: $WORK is unique to this run
  cp "$LIB"/*.lua "$WORK/"
  local before after
  before=$(md5 -q "$WORK/$target")
  perl -0pi -e "$subst" "$WORK/$target"
  after=$(md5 -q "$WORK/$target")
  # Without this check an obsolete pattern silently reports SURVIVED: the tests
  # pass because nothing was actually broken.
  if [[ "$before" == "$after" ]]; then
    print "NO-OP     $label   (pattern did not match $target)"
    return
  fi
  # A mutant that does not parse "kills" every test for the wrong reason and
  # proves nothing.  Two of these hid in the gate for a whole phase.
  if ! luajit -e "assert(loadfile('$WORK/$target'))" 2>/dev/null; then
    print "BROKEN    $label   (mutated $target does not compile)"
    return
  fi
  local out
  out=$(DF_LIB=$WORK/ luajit "$HERE/$spec.lua" 2>&1 | tail -1)
  # Compare the whole "N failed" tail, not a suffix: *"0 failed" also matches
  # "10 failed", which labelled a killed mutant SURVIVED.
  if [[ "${out##*, }" == "0 failed" ]]; then
    print "SURVIVED  $label   ($out)"
  else
    print "killed    $label   ($out)"
  fi
}

run_mut "adopt any new Finder window" panel.lua \
  's/if sharesTabBar or paneGrew or \(#titles == 0 and paneWentInactive\) then/if true then/'
run_mut "adopt on frame match alone" panel.lua \
  's/local sharesTabBar = false/local sharesTabBar = true/'
run_mut "lone side keeps half width" geometry.lua \
  's/if liveSides\.left and liveSides\.right then/if true then/'
run_mut "no min-height relayout" panel.lua \
  's/if got\.h > rect\.h \+ cfg\.frameTolerance then/if false then/'
run_mut "persist drops tabIds" panel.lua \
  's/tabIds     = pane\.tabIds,/tabIds     = {},/'
run_mut "persist drops paths" panel.lua \
  's/paths      = pane\.pathList,/paths      = {},/'
run_mut "reconcile does not refresh paths" panel.lua \
  's/pane\.tabIds, pane\.pathList = ids, paths/pane.tabIds = ids/'
run_mut "windowMoved skips the frame test" panel.lua \
  's/if geometry\.framesEqual\(frame, pane\.frame, cfg\.frameTolerance\) then return end/if false then return end/'
run_mut "hide() skips the suppress window" panel.lua \
  's/M\.suppress\(0\.6\)//'
run_mut "hide() and windowMoved both forget the park" panel.lua \
  's/pane\.frame  = got or pane\.frame//; s/if pane\.parked and geometry\.framesEqual\(frame, pane\.parked, cfg\.frameTolerance\) then/if false then/'
run_mut "state() ignores geometry" panel.lua \
  's/if not w:isMinimized\(\) and geometry\.isOnScreen\(w:frame\(\)\) then/if true then/'
run_mut "state() ignores minimization" panel.lua \
  's/if not w:isMinimized\(\) and geometry\.isOnScreen\(w:frame\(\)\) then/if geometry.isOnScreen(w:frame()) then/'
run_mut "state() settles for one visible pane" panel.lua \
  's/if known == 0 or visible < known then return "hidden" end/if known == 0 or visible == 0 then return "hidden" end/'
run_mut "state() calls an unresolvable pane hidden" panel.lua \
  's/local w = isLive\(side\) and paneWindow\(side\) or nil/local w = isLive(side) and (paneWindow(side) or {isMinimized = function() return true end, frame = function() return {x=0,y=0,w=0,h=0} end}) or nil/'
run_mut "unhide() only un-minimizes in minimize mode" panel.lua \
  's/if pane\.collapsed or \(w and w:isMinimized\(\)\) then/if pane.collapsed and cfg.hideMode == "minimize" then/'
run_mut "layout() never re-reads the settled frame" panel.lua \
  's/  hs\.timer\.doAfter\(cfg\.settleDelay, function\(\)\n    local frames = geometry\.paneFrames.*?\n  end\)\n/  /s'
# The reflex fix for the z-order defect below, and the one requirement 4 forbids:
# app:activate() lifts every Finder window, the user's floating ones included.
run_mut "raise() uses app:activate()" panel.lua \
  's/pcall\(function\(\) target:focus\(\) end\)/pcall(function() finder.app():activate() end)/g'
run_mut "rebuild prefers the default over the last path" panel.lua \
  's/local function rebuildPlan\(side\)/local function rebuildPlan(side) do return { cfg.defaultPaths[side] }, 1 end/'
run_mut "ensurePanes ignores the remembered path" panel.lua \
  's/local path = plan\[1\]/local path = "\/"/'
run_mut "rebuild drops every tab but the first" panel.lua \
  's/        if #plan > 1 then/        if false then/'
run_mut "rebuild ignores the persisted tab list" panel.lua \
  's/  if cfg\.restoreTabs then/  if false then/'
run_mut "rebuild restores every tab even with restoreTabs off" panel.lua \
  's/  if cfg\.restoreTabs then/  if true then/'
run_mut "rebuild forgets which tab was active" panel.lua \
  's/        if not active and p == want then active = #paths end//'
run_mut "tab order is taken from our own bookkeeping" panel.lua \
  's/  local titles = finder\.tabTitles\(w\)\n  if #titles ~= #pane\.tabIds then return end/  local titles = {}\n  if true then return end/'
run_mut "duplicate folder names are re-ordered anyway" panel.lua \
  's/    if not i or used\[i\] then return end/    if not i then return end/'
run_mut "the remembered tab is never selected" panel.lua \
  's/      if i ~= selected and finder\.selectTab\(w, i\) then/      if false then/'
run_mut "show() forgets the previous app" panel.lua \
  's/  capturePrevApp\(\)\n  M\.reconcile\(\)/  M.reconcile()/'

# ── Phase 3: cross-Space and adopt ──────────────────────────────────────────
run_mut "crossSpace = false is ignored" panel.lua \
  's/  if not cfg\.crossSpace then return cb\(\) end//'
run_mut "a pane already on this Space is moved anyway" panel.lua \
  's/    if handle and sameScreen and isOnSpace\(handle, target\) == false then/    if handle and sameScreen then/'
run_mut "an unreadable Space counts as the wrong one" panel.lua \
  's/  if not ok or type\(list\) ~= "table" then return nil end/  if not ok or type(list) ~= "table" then return false end/'
run_mut "a failed move is treated as done" panel.lua \
  's/      if ok and isOnSpace\(handle, target\) ~= false then/      if true then/'
run_mut "the activate fallback recreates too" panel.lua \
  's/    if cfg\.crossSpaceFallback == "recreate" then/    if true then/'
run_mut "recreate throws away the remembered paths" panel.lua \
  's/    pane\.tabIds, pane\.activeId, pane\.frame, pane\.parked = \{\}, nil, nil, nil/    pane.tabIds, pane.activeId, pane.frame, pane.parked = {}, nil, nil, nil\n    pane.pathList = {}/'
run_mut "recreate never reopens the pane" panel.lua \
  's/  ensurePanes\(cb\)\nend\n\n--- Bring the panes/  cb()\nend\n\n--- Bring the panes/s'
run_mut "adopt swallows a pane of its own" panel.lua \
  's/  if M\.sideOfTab\(win:id\(\)\) then\n    return refuse\(.*\)\n  end//s'
run_mut "adopt does not check the front app" panel.lua \
  's/  if not front or front:bundleID\(\) ~= FINDER_BUNDLE then/  if false then/'
run_mut "adopt matches any floating window, not the source" panel.lua \
  's/       and geometry\.framesEqual\(w:frame\(\), rect, cfg\.frameTolerance\) then/       then/'
run_mut "adopt closes the source tab even when the new one failed" panel.lua \
  's/        if not newId then return finish\(tostring\(err\)\) end/        if false then end/'
run_mut "adopt leaves a hidden panel hidden" panel.lua \
  's/    if M\.state\(\) == "hidden" then M\.show\(cb\) else ensurePanes\(cb\) end/    ensurePanes(cb)/'
run_mut "adopt races a queued rebuild" panel.lua \
  's/    if panes\[side\]\.pending then/    if false then/'
run_mut "adopt ignores the mouse and always uses lastSide" panel.lua \
  's/  if want == "mouse" then/  if false then/'

# ── Phase 3b: display changes while the panel is away, adopt focus ──────────
run_mut "a display change ignores a put-away panel" panel.lua \
  's/  if putAway then/  if false then/'
run_mut "a display change trusts geometry over intent" panel.lua \
  's/    if isLive\(side\) and panes\[side\]\.parked then putAway = true end/    if isLive(side) and panes[side].parked and M.state() == "hidden" then putAway = true end/'
run_mut "a display change re-parks a minimized pane" panel.lua \
  's/      if w and not w:isMinimized\(\) then parkSide\(side\) end/      if w then parkSide(side) end/'
run_mut "adopt leaves focus on the side the user came from" panel.lua \
  's/      if moved > 0 then M\.setLastSide\(side\); M\.raise\(\) end/      if moved > 0 then M.raise() end/'

# ── Phase 3c: the same-display rule for Space moves, adopt tab order ────────
run_mut "a pane on another display is moved between Spaces anyway" panel.lua \
  's/    if handle and sameScreen and isOnSpace\(handle, target\) == false then/    if handle and isOnSpace(handle, target) == false then/'
run_mut "the raise branch of the hotkey skips the Space move" panel.lua \
  's/    moveToCurrentSpace\(geometry\.pickScreen\(cfg\.screenPolicy\), function\(\)\n      M\.raise\(\)\n    end\)/    M.raise()/s'
run_mut "adopt takes tabs in activation order" panel.lua \
  's/      if #titles > 1 and selected and selected ~= 1 and presses < budget then/      if false then/'
run_mut "dumpState reports a stale model" panel.lua \
  's/  M\.reconcile\(\)\n  local lines = \{ "\[DropFinder\] state = "/  local lines = { "[DropFinder] state = "/s'
run_mut "persistNow writes the model as it stands" panel.lua \
  's/  -- The callers that used to reconcile immediately before this no longer do\.\n  M\.reconcile\(\)/  -- (mutant)/s'

# ── Phase 3d: a Finder that has just relaunched ─────────────────────────────
run_mut "the hotkey gives up on a Finder that has just restarted" panel.lua \
  's/  if failed > 0 and not retried then/  if false then/'
run_mut "the retry does not wake Finder first" panel.lua \
  's/    hs\.application\.launchOrFocusByBundleID\(FINDER_BUNDLE\)//'
run_mut "the untargeted windows are left behind" panel.lua \
  's/      for _, id in ipairs\(strays\) do finder\.closeTab\(id\) end//'
run_mut "the retry can retry forever" panel.lua \
  's/      ensurePanes\(cb, true\)/      ensurePanes(cb)/'

# ── Phase 3e: an empty AppleScript snapshot is a claim, not a fact ───────────
run_mut "an empty snapshot is taken at face value" panel.lua \
  's/  if #snap == 0 and next\(axById\) then/  if false then/'
run_mut "a tab only Accessibility can see counts as closed" panel.lua \
  's/or axById\[id\] or \(anySeen and isFresh\(id\)\) then/or (anySeen and isFresh(id)) then/'

# ── Phase 3f: the raise order (reported from the screen) ─────────────────────
run_mut "raise lifts both panes before Finder is active" panel.lua \
  's/  pcall\(function\(\) target:focus\(\) end\)\n\n  local sibling/  pcall(function() local w = paneWindow("left") if w then w:raise() end end)\n  pcall(function() local w = paneWindow("right") if w then w:raise() end end)\n  pcall(function() target:focus() end)\n  do return end\n\n  local sibling/s'
run_mut "the sibling is raised but the focus is left with it" panel.lua \
  's/    pcall\(function\(\) sibling:raise\(\) end\)\n    pcall\(function\(\) target:focus\(\) end\)/    pcall(function() sibling:raise() end)/s'

# ── Phase 3g: focus back to a floating window, not over it (from the screen) ──
run_mut "hide() forgets which floating window the panel came up over" panel.lua \
  's/    if id and not M\.sideOfTab\(id\) then prevWindowId = id end//'
run_mut "hide() activates the previous app on top of it anyway" panel.lua \
  's/    elseif prevAppBundleID then/    end\n    if prevAppBundleID then/'
run_mut "the remembered window is focused without checking it is still there" panel.lua \
  's/    if prevWindowId and not M\.sideOfTab\(prevWindowId\) then\n      w = finder\.axWindowById\(prevWindowId\)\n    end/    w = prevWindowId and { focus = function() end } or nil/s'

# ── Phase 3h: a tab neither view has published yet (from the screen) ──────────
run_mut "a tab neither view has published yet counts as closed" panel.lua \
  's/      if pathOf\[id\] or axById\[id\] or \(anySeen and isFresh\(id\)\) then/      if pathOf[id] or axById[id] then/'
run_mut "the grace for a new tab never expires" panel.lua \
  's/  if hs\.timer\.secondsSinceEpoch\(\) - at > FRESH_GRACE then/  if false then/'
run_mut "the grace is shorter than one adopt round" panel.lua \
  's/local FRESH_GRACE = 8\.0/local FRESH_GRACE = 2.0/'
run_mut "a pane that has gone quiet keeps its new tab anyway" panel.lua \
  's/\(anySeen and isFresh\(id\)\)/isFresh(id)/'
run_mut "adopt does not mark the tab it just made" panel.lua \
  's/        markFresh\(newId\)//'
run_mut "the tab restore does not mark the tab it just made" panel.lua \
  's/      markFresh\(id\)\n      mint\(side, id\)\n      pane\.activeId = id/      mint(side, id)\n      pane.activeId = id/s'

# ── Phase 3i: a hand-pressed Cmd+M survives a reconcile (from the screen) ─────
run_mut "reconcile decides collapsed after the fallback has hidden it" panel.lua \
  's/      pane\.collapsed = \(active == nil\) and anyMin or false\n      if not active and pane\.activeId and axById\[pane\.activeId\] then\n/      if not active and pane.activeId and axById[pane.activeId] then\n/s; s/      pane\.activeId  = active or ids\[1\]/      pane.activeId  = active or ids[1]\n      pane.collapsed = (active == nil) and anyMin or false/'
run_mut "restoreAll only gets its own minimize out of the Dock" panel.lua \
  's/    if isLive\(side\) and panes\[side\]\.collapsed then/    if isLive(side) and panes[side].collapsed and cfg.hideMode == "minimize" then/'
run_mut "restoreAll wakes a pane and leaves it where minimize left it" panel.lua \
  's/  if woke then\n    -- Restoring.*?\n    -- park corner.*?\n    hs\.timer\.doAfter\(0\.3, function\(\)\n      M\.reconcile\(\)\n      layout\(\)\n    end\)\n    return\n  end/  if woke then return end/s'
run_mut "the hotkey decides from the last reconcile's answer" panel.lua \
  's/  M\.reconcile\(\)\n  local s = M\.state\(\)/  local s = M.state()/s'

# ── Phase 3j: another Space hands over no window at all (from the screen) ─────
run_mut "the Space move gives up without a window object" panel.lua \
  's/    local handle = w or \(isLive\(side\) and \(pane\.activeId or pane\.tabIds\[1\]\) or nil\)/    local handle = w/'
run_mut "the display test gives up without a window object" panel.lua \
  's/    local ws = w and w:screen\(\) or geometry\.screenOf\(pane\.frame\)/    local ws = w and w:screen()/'
run_mut "screenOf answers with the main screen whatever the frame" geometry.lua \
  's/function M\.screenOf\(frame\)\n  if not frame then return nil end/function M.screenOf(frame)\n  if not frame then return nil end\n  do return hs.screen.mainScreen() end/s'
run_mut "layout gives up on a pane Accessibility cannot see" panel.lua \
  's/  local w = paneWindow\(side\)\n  if w then return geometry\.applyFrame/  local w = paneWindow(side)\n  if true then return geometry.applyFrame/s'
run_mut "the settled frame is recorded for a pane that was never placed" panel.lua \
  's/      if w then\n        local now = w:frame\(\)\n/      do\n        local now = (w and w:frame()) or panes[side].frame\n/s'

# ── Phase 4: one action, several hotkeys (config rules, so pure_spec) ─────────
run_mut "a list of hotkeys keeps only the first" config.lua \
  's/  for i, one in ipairs\(hk\) do out\[i\] = hotkeySpec\(name, i, one\) end/  for i, one in ipairs(hk) do out[i] = hotkeySpec(name, i, one) break end/' \
  pure_spec
run_mut "an empty hotkey list is taken quietly" config.lua \
  's/  if #out == 0 then/  if false then/' pure_spec
run_mut "the default hotkey spec is handed out rather than copied" config.lua \
  's/  return \{ mods = hk\.mods, key = hk\.key \}/  return hk/' pure_spec

# ── A tab Finder appended without selecting it ───────────────────────────────
run_mut "a tab the pane's own tab bar reveals is left floating" panel.lua \
  's/      local paneGrew = false\n      if axById\[id\] == nil then/      local paneGrew = false\n      if false then/s'
run_mut "the growth signal skips the check that the tab is not a window" panel.lua \
  's/      if axById\[id\] == nil then\n        local pw = paneWindow\(side\)/      if true then\n        local pw = paneWindow(side)/s'
run_mut "a tab bar as long as the model counts as growth" panel.lua \
  's/paneGrew = #finder\.tabTitles\(pw\) > #pane\.tabIds/paneGrew = #finder.tabTitles(pw) >= #pane.tabIds/'

# ── Fix E: an id DropFinder minted is never silently forgotten ────────────────
run_mut "a stranded window is left stranded" panel.lua \
  's/    if not isLive\(side\) then reclaimMinted\(side\) end\n//s'
run_mut "any window at hand is reclaimed, not only one of ours" panel.lua \
  's/  for _, id in ipairs\(pane\.minted\) do\n    if not M\.sideOfTab\(id\) then/  for id in pairs(pathOf) do\n    if not M.sideOfTab(id) then/s'
run_mut "minted ids Finder no longer lists are kept" panel.lua \
  's/      if pathOf\[id\] then keep\[#keep \+ 1\] = id end/      keep[#keep + 1] = id/'
run_mut "provenance is not written down" panel.lua \
  's/      minted     = pane\.minted,/      minted     = {},/'
run_mut "the Finder that issued the ids is not written down" panel.lua \
  's/  st\.finderPid = mintedPid/  st.finderPid = nil/'
run_mut "a different Finder process is trusted anyway" panel.lua \
  's/  if mintedPid == pid then return true end/  if true then return true end/'

# ── Fix F: a tab dragged from one of the panel's windows into the other ───────
# Not every line here has a mutant.  The blind-AX, minimized, mid-rebuild and
# fresh-tab guards at the top of needsRegroup() are belt and braces: with any of
# them removed the regroup still declines, because a blind tree resolves no
# window to check, a minimized one cannot be handed a side, and an unpublished
# tab is a tab no tab bar accounts for.  Their behaviour is covered by sections
# of its own in panel_spec.lua; there is nothing a mutant of them can change.
run_mut "a drag between the panel's windows is never noticed" panel.lua \
  's/  if needsRegroup\(\) then regroupPanes\(\) end/  if false then regroupPanes() end/'
run_mut "a window holding a different number of our tabs is not detected" panel.lua \
  's/      elseif #titles ~= #pane\.tabIds then\n        return true/      elseif false then\n        return true/s'
run_mut "a window holding a different set of our tabs is not detected" panel.lua \
  's/          if not bag\[b\] or bag\[b\] == 0 then return true end/          if false then return true end/'
run_mut "a side resolving to a single-tab window is believed" panel.lua \
  's/        if #pane\.tabIds ~= 1 then return true end/        if false then return true end/'
run_mut "a window the user opened becomes a pane by having a tab dropped in it" panel.lua \
  's/      candidate = \(managed\[w:id\(\)\] ~= nil\) and not w:isMinimized\(\),/      candidate = not w:isMinimized(),/'
run_mut "two tabs with the same folder name are guessed at" panel.lua \
  's/        if several then\n          log\.w\(string\.format\(/        if false then\n          log.w(string.format(/s'
run_mut "tabs no tab bar accounts for are dropped anyway" panel.lua \
  's/    if not accounted\[id\] then\n      log\.i\(string\.format\(/    if false then\n      log.i(string.format(/s'
run_mut "a side is handed a window holding none of its tabs" panel.lua \
  's/      if i ~= j and a\.score\.left > 0 and b\.score\.right > 0 then/      if i ~= j then/'
run_mut "the window with the most of a side's tabs is not preferred" panel.lua \
  's/        local key = \{ a\.score\.left \+ b\.score\.right, #a\.ids \+ #b\.ids, -a\.active, -b\.active \}/        local key = { 0, 0, -a.active, -b.active }/'
run_mut "the side that lost its window keeps its ids" panel.lua \
  's/      pane\.tabIds, pane\.activeId, pane\.frame, pane\.parked = \{\}, nil, nil, nil\n      pane\.minted = \{\}\n      log\.i\(string\.format\("regroup/      log.i(string.format("regroup/s'
run_mut "provenance does not follow the tab to its new side" panel.lua \
  's/    for _, id in ipairs\(panes\[side\]\.minted\) do wasMinted\[id\] = true end/    for _, id in ipairs({}) do wasMinted[id] = true end/'
run_mut "a regrouped side that is on screen is recorded as put away" panel.lua \
  's/      pane\.parked = \(not geometry\.isOnScreen\(pane\.frame\)\) and pane\.frame or nil/      pane.parked = pane.frame/'
