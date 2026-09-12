# The manual pass

The offline suites run `lib/` against a simulator; these seventeen steps are the
ones that need a real Finder, real windows and a real screen.  The first sixteen
come from the end of the implementation plan; the seventeenth was added by
ordinary use.  This file records the last time each was walked and, more
usefully, **what walking them found that the simulator could not** — seven
defects, every one of them now fixed, covered offline and mutation-gated.

Before running anything against the live machine, ask one question first:

```lua
hs.caffeinate.sessionProperties().CGSSessionScreenIsLocked
```

With the screen locked, Finder resolves no windows through Accessibility
(`app:allWindows()` returns only the desktop, `id = 0`) while AppleScript keeps
answering correctly, so every observation is a lie in one direction or the other,
and `hs.spaces.addSpaceToScreen` returns `true` without creating a Space.  Two
passes were thrown away to that before the check became routine.

| # | Step | Outcome |
|---|---|---|
| 1 | Empty state, hotkey | Both sides open at the default paths on the mouse's screen, half width each |
| 2 | Hotkey again, Finder focused | Both parked in the corner; the app that was in front before gets focus back |
| 3 | Hotkey again | Same windows, same paths, scroll position and selection intact |
| 4 | Panel up, focus elsewhere, hotkey | Panel is raised and focused; floating Finder windows keep their place in the stack |
| 5 | Cmd+T in the left pane and navigate | The tab is tracked; switching tabs re-lays out nothing |
| 6 | Cmd+W that tab | Its path leaves the model; the pane does not move |
| 7 | Close the right pane entirely | The left one takes the whole panel width immediately |
| 8 | Hide, show | The right side is rebuilt at the path it was last at; both back to half width |
| 9 | `hs.reload()`, hotkey | Both sides reattach by id — no new windows, no flicker |
| 10 | `killall Finder`, hotkey | Both sides rebuilt from the persisted paths, all tabs, and no extra windows beyond the ones macOS itself restores |
| 10b | `killall Finder` again while a rebuild is still running, then hotkey | The queued tabs are still on disk and come back on the next press |
| 10c | Quit Hammerspoon, `killall Finder`, start Hammerspoon again, hotkey | Both sides rebuilt from the paths; the two windows from before are left floating, never moved — the log says Finder is a different process now |
| 10d | With the panel up, hide it, then make Finder stop listing one side (another Space on its display, or a fresh relaunch), then hotkey twice | The side is taken back rather than opened again — no third window in that slot; the log says `reclaimed N ... window(s)` |
| 11 | Open a Finder window by double-clicking a folder | It stays floating: never moved, resized or closed, and it stays put when the panel hides |
| 12 | Cmd+M a pane by hand, then the hotkey; then the same walk under `hideMode = "minimize"` | Both verified — see below |
| 13 | Press the hotkey from another Space | **Verified**, after fixing what it exposed. See below |
| 14 | Second display, then unplug it while shown | **Verified by hand.** Both panes survive and are re-laid out on a remaining display. Plugging it back in leaves them where they are — see below |
| 15 | Focus a floating window, adopt hotkey | Its tabs merge in order into the side nearer the mouse and the source window closes.  Live three-tab merge ended with model and Finder in exact agreement (`49085, 49087, 49089, 49090, 49092, 49103, 49104, 49105`) and no `is gone` line in the log |
| 16 | `spoon.DropFinder:stop()` | Both sides come back on screen, nothing left in the Dock, hotkeys dead |
| 17 | Drag a tab from one pane's tab bar into the other, then the hotkey | The sides swap over with the tabs: both windows still go to their own half, nothing is created or closed.  **Found here**, and re-walked after the fix — the press used to move one window twice and leave the other behind.  See below |

## Step 12 under `hideMode = "minimize"`, measured

Mouse screen `ARZOPA` (`-2048,144 2048x1250`), a floating window at
`300,200 800x440` kept for the whole run:

```
STEP1 after show   state=shown_focused   left -2048,1082 1024x312   right -1024,1082 1024x312
STEP2 after hide   state=hidden          both min=true              front = the app from before
STEP3 after show   state=shown_focused   same frames, same paths
STEP3b focus away  state=shown_unfocused
STEP4 after raise  state=shown_focused
```

The floating window read `300,200 800x440 min=false` at every one of those five
snapshots, and Finder's own z-order (`id of every window`) was the same before
the show and after the raise — the raise lifted the two panes without lifting it.

## What the live pass found

Six things the simulator agreed with and the machine did not:

1. **`raise()` lifted both panes over the floating window** the user was working
   in.  Raising the sibling first and focusing the target last fixes the order.
2. **`hide()` handed focus back by activating the previous *app***, which lifted
   that app's key window over the floating Finder window.  It now focuses the
   remembered *window* and only falls back to the app.
3. **A brand-new tab is briefly invisible to both views** — not yet in
   `id of every window`, and Accessibility only ever shows the active one — so a
   reconcile in that gap deleted the tab that had just been made.  Adopting three
   tabs in a row lost the middle one.  Hence the fresh-id grace, and hence its
   length: one adopt round takes 1.5–2s in the hand and the reconcile that has to
   keep the tab is at the top of the *next* round.
4. **A hand-pressed Cmd+M did not survive a reconcile.** While minimized Finder
   puts every tab in the Accessibility tree, the remembered active one included,
   so the "keep the remembered active tab" fallback concluded the pane was awake
   and reset `collapsed` — which also left `stop()` with nothing to restore.
5. **The hotkey decided from a stale answer.** `state()` reads the window table
   the last reconcile filled in, so a reconcile that ran while nothing was
   resolvable left it saying "hidden" about a panel sitting on the grid, and the
   next press showed a panel that was already up.  `toggle()` now reconciles
   first, which costs about 100ms.
6. **`File > New Tab` does not always select the tab it makes.** Measured while
   refilling a pane with the thirteen tabs TotalFinder had saved: on a window that
   already held fourteen, every new tab was appended to the tab bar *without*
   becoming active, so it never entered the Accessibility tree, the handle
   `windowCreated` delivered was detached (its id and frame answer, its tab bar
   does not), and the pane's own active tab never moved.  Both of
   `onWindowCreated`'s signals assume the new tab is the active one, so all
   thirteen were filed as floating — the tabs were on screen and a hide()/show()
   would have thrown them away.  The pane's own window is readable throughout and
   is the honest witness: its tab bar now lists more tabs than the pane owns,
   while a window the user double-clicked open leaves that count alone and arrives
   with an AX window of its own.  Requiring both is what keeps requirement 2.

## Step 13, cross-Space

**Verified, and it found the biggest defect of the live pass.**  This machine has
exactly one Space per display, so the step needs one adding first:

```lua
local sp, S = hs.spaces, hs.mouse.getCurrentScreen()
local before = sp.spacesForScreen(S)          -- remember, so the new id can be diffed out
sp.addSpaceToScreen(S, true)                  -- private API
sp.gotoSpace(<the new id>)                    -- then press the toggle hotkey
sp.gotoSpace(<the original>) ; sp.removeSpace(<the new id>)
```

Two earlier attempts ran into a locked screen, where `addSpaceToScreen` reports
success and creates nothing — hence the lock check at the top of this file.  What
the successful run measured, on macOS 26:

| Question | Answer |
|---|---|
| `moveWindowToSpace(pane, target)` | returns `true` and **moves nothing** — `windowSpaces` still reports the old Space, asked by window object or by id |
| `app:allWindows()` from another Space | the **desktop and nothing else**; every pane handle comes back nil |
| AppleScript from another Space | keeps answering: `id`/`target`/`bounds of every window`, `close window id N` |
| `set bounds of window id N` from another Space | **works** — the window arrives on the display the rect names, joins the Space showing there, and is visible to Accessibility again |
| a window arriving on another display | joins that display's active Space, no `hs.spaces` call involved.  Only a move that *changes display* does this |

The defect: every branch of the cross-Space code was gated on having an
`hs.window`, which is exactly what another Space does not hand over.  So the panes
were skipped, `layout()` had nothing to lay out, and **the hotkey silently did
nothing** — it could not even reach its own fallback.  The fix works from a window
id, which both `hs.spaces` and AppleScript still accept, and `layout()` falls back
to `finder.setBounds` when Accessibility has no window for a live pane.

Re-verified afterwards with the fix in place, one Space added for the purpose:

| Fallback | From the new Space, pressing the hotkey |
|---|---|
| `"activate"` (default) | both panes read `ax=false`, state reads `hidden`, the move is attempted, the lie is caught, and **one** alert appears: "the panel is on another Space and could not be moved".  Ids unchanged, nothing moved, no stray windows |
| `"recreate"` | the panel **arrives**.  Measured: ids `49085/49087` → `50188/50190`, `windowSpaces` = the new Space for both, visible to Accessibility again, at exactly the panel frames (`{0,1017,1280,1440}` and `{1280,1017,2560,1440}` — bottom strip, half width each), paths back at `~/Downloads` and `~`, **no alert**, and exactly two Finder windows afterwards: the old pair was closed, nothing stray left behind |

Both rounds left the Spaces as they were: `allSpaces()` back to one per display.
After the extra Space was removed the panes migrated to the surviving Space with
their layout intact.

So requirement 10 is met, but only through `"recreate"`.  Anyone using several
Spaces should set it; the README says so under limitations.

## Step 14, a display going away and coming back

Verified by hand, with the cable.  Unplugging the display the panel is on: both
panes survive and end up laid out on a remaining display.  That is the whole
expectation — `onScreensChanged` reconciles, sees a panel that is not put away,
and re-runs `layout()` on the policy screen, so the panes are re-sized to that
display's panel frame rather than left at whatever size macOS dropped them at.
Nothing is closed, so paths, tabs, scroll positions and selections all survive.

Plugging the display back in does **not** send the panel back to it, and that is
by design rather than an oversight: DropFinder has no notion of a home display.
Requirement 8 is "wherever the mouse is", and the persisted screen UUID exists
only for the log.  On the replug the screen watcher runs the same `layout()` on
the policy screen — which is normally still the one the mouse is on — so the
panel stays put.  To bring it across, move the mouse to the reattached display
and put the panel away and back out again.

One rough edge worth knowing: a single press while the panel is already up takes
the `shown_unfocused` branch, which raises and focuses without laying out, so it
does not move the panel to the mouse's display either.  Hide-then-show is what
moves it.

The fallback path is what actually matters if `hs.spaces` is ever withdrawn, and
that part *is* covered offline: absent, throwing, and claiming a move it did not
make are three separate sections in `panel_spec.lua`.

## Step 17, a tab dragged from one pane into the other

Not from the plan — this one came out of using the panel.  After dragging a tab
across, one press made the right window look like it had vanished: it had been
moved to the *left* window's place, on top of it, and focus went back to the
previous app as though nothing were on screen.

What the machine actually held at that point, read with the panel put away:
window A parked in the corner with 7 tabs, window B sitting in the left slot with
7 tabs, and a model that had 13 ids on the left and 1 on the right.  The drag had
taken six of the left side's tabs into the right side's window, so
`paneWindow("left")` resolved through a tab that now lived in the right pane's
window — both sides resolved to the *same* window, one moved it and the other
moved it again, and the window nobody resolved to was never touched.  Nothing was
lost; the model was simply pointing at the wrong window.

The fix is in `reconcile()`, and it repairs the model without moving anything:
each side's tabs are compared with the folder names in the tab bar of the window
it resolves to, and a mismatch triggers a re-read of which window holds which of
our tabs, after which each side is handed the window holding most of its own tabs
and its paths, active tab, park rect and provenance move with it.  A drag shows
up in both windows' tab bars, so the side that has lost its window entirely is
noticed through the window that took its tab.  Covered offline by nine sections
of `panel_spec.lua` and twelve mutants; what needed the machine was the
observation itself, since the simulator was quite happy to model a drag nobody
had thought to ask it about.

Re-walked on the machine that was still in the broken state, without touching a
window first.  A reload was enough:

```
regroup: left is window 53639 now, 7 tab(s), active /Users/wangyuan/
regroup: right is window 53635 now, 7 tab(s), active .../data/new_patients/
```

13 + 1 became 7 + 7, in tab-bar order, with the model's `right` now holding the
six tabs that had been dragged into that window — the drag was followed, not
undone.  Then hide and show, measured:

| | left | right | the floating window |
|---|---|---|---|
| before | `0,876` | `4440,1289` (parked) | `3200,777` |
| after hide | `4440,1289` | `4440,1289` | `3200,777` |
| after show | `0,876` | `1280,876` | `3200,777` |

Both halves, one window each, 15 tabs in Finder throughout (14 in the panel, one
floating), nothing created and nothing closed.  Both sides park in the same
corner, which is why the two parked rects are identical — `parkRequest` has no
per-side stagger, contrary to the plan's sketch of it.

One thing seen only when driving this from the IPC client rather than the
keyboard: after `show()` returned, `state()` said `shown_unfocused`.  The hotkey
path is what steps 1--4 walked and it focuses correctly; a `show()` typed into
`hs -c` while another app is frontmost is not the same race.
