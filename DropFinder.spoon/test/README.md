# DropFinder tests

Offline suites: no Hammerspoon, no Finder, no windows on screen.  `lib/` is
loaded against a stub `hs` and a simulated macOS/Finder, so the whole thing runs
in well under a second and can be run while the user is working.

Requires **luajit** (`/opt/homebrew/bin/luajit`; this machine has no `lua`).
`mutate.sh` additionally needs `perl` and `md5`, both stock on macOS.

```sh
test/run.sh          # every suite
test/mutate.sh       # the mutation gate
```

## The suites

| File | What it covers |
|---|---|
| `pure_spec.lua` | `config.lua`, `geometry.lua`, `store.lua` — no windows involved at all |
| `static_spec.lua` | Cross-reference check: every `M.x` / injected dep a lib calls actually exists, so a rename cannot rot a rarely-taken branch |
| `hotkey_spec.lua` | `init.lua`: `configure` → `start` → `bindHotkeys` → `stop`, with a fake `hs.hotkey` that hands back deletable handles. The only suite that loads `init.lua`, so the only one where `start()` and `stop()` run at all |
| `panel_spec.lua` | `panel.lua` against the simulator: show / hide / raise, the tri-state, tab tracking, multi-tab rebuilds, display changes, cross-Space, adopt, persistence, requirement 9, both `hideMode`s |

`static_spec.lua` also checks `config_example.lua`: it must survive
`loadConfig`, and every key it documents must be one the validator knows — an
example that errors, or that advertises a field nothing reads, is worse than no
example.

## The support files

- **`stub.lua`** — the minimum `hs` surface the libs touch.  Real answers where
  they are cheap and honest (`hs.fs` hits the actual filesystem, memoised — no
  suite writes to disk, and one `test -d` per fork was most of the gate's
  runtime), synthetic where they are not: `S.REAL_SCREENS` is this machine's three-display layout,
  `S.ONE_SCREEN` a laptop.  `S.plistRoundTrip` models what NSUserDefaults does
  to a Lua table, which is why `store.lua` cannot use integer keys.
- **`world.lua`** — the simulator.  Every behaviour in it is a Phase 0
  measurement against *vanilla* Finder, and the comments say which:  AX exposes
  only the active tab (all of them while minimized); AppleScript sees every tab
  and its window ids are the same numbers `hs.window:id()` returns; AppKit keeps
  ≥40×52px of any window inside the screen union; Finder refuses to be shorter
  than 344px; `setFrame` emits `windowMoved` for our own moves too; a move that
  crosses displays reads back stale for a moment (`opts.staleFrameReads`).
  Timers are drained explicitly (`world.drain()`), so tests never sleep;
  `world.step()` runs a single round instead, which is how a test interrupts an
  async sequence half way (a pane closed mid-rebuild, adopt pressed while a
  rebuild is still queued).  `world.failNewTabAt = n` makes the n-th New Tab
  fail, and `world.reorderTabs` drags a tab along the bar.  `hs.spaces` is
  modelled only as far as `panel.lua` uses it, plus the three ways it can let us
  down: absent (`opts.noSpaces`), throwing (`world.moveSpaceFails`,
  `world.windowSpacesFails`), and claiming a move it did not make
  (`world.moveSpaceNoop`).  `world.setBoundsFails` takes away the last way to
  reach a pane Accessibility cannot see, which is how the tests pin down that a
  pane that could not be placed is still reported as parked rather than assumed
  laid out.

One asymmetry in `world.lua` is worth naming because a live defect hid in it:
`world.finderAsleep` makes the AppleScript view of a just-relaunched Finder
return an **empty list rather than an error**, while `F.axWindows` keeps handing
the same windows over.  Nothing distinguishes that lie from "the user closed the
last window" except the second opinion, which is why `reconcile` asks
Accessibility before believing an empty snapshot, and why `world.snapshotOmits`
exists to tell the same lie about a single window.

Two more knobs model the same kind of gap in time rather than in coverage.
`world.lagNextNewTab` makes Finder take one round longer to publish the next new
tab: it is missing from the AppleScript snapshot *and* the AX tree still hands
over the tab that was active before it.  That is what a brand-new tab looks like
from outside for a moment, and a reconcile that believes both views deletes the
tab it just made -- measured, adopting three tabs in a row lost the middle one
that way.  The test clears `world.newTabLagged` when it wants Finder to catch up,
so how long the gap lasts is the test's to decide.  `world.addBackgroundTab`
models the other, permanent, half of the same surprise: measured on a pane
holding fourteen tabs, `File > New Tab` appended the tab **without selecting
it**, so it never entered the AX tree at all and the handle `windowCreated` hands
over is detached -- it answers with its id and its window's frame, but has no tab
bar (`F.tabTitles` returns nothing for a handle whose tab is not the active one).
Both original adopt signals are blind to that, and thirteen tabs in a row were
filed as floating; the pane's own tab bar, which Accessibility still reads
happily, is what tells the truth.  And `world.zorder` plus
`world.activateOther` model the one global window order, including the part that
turned requirement 12 into a defect: activating an app brings its window forward
over anything in front of it, a Finder window the user was working in included.

A test that needs Finder or real windows does not belong here — it goes in
`manual.md`, which lists the sixteen live steps, what the last pass measured,
the five defects that pass found, and the two steps still waiting on hands.
One thing is deliberately unmodelled because the simulator would only be
asserting my own guess: the AppleScript and AX text plumbing inside
`finder.lua`, which is exercised by hand.

The `hs.spaces` model used to be the one place where the simulator asserted
behaviour that was never measured.  It has since been measured, by creating
Spaces on this machine for the purpose, and the model was rewritten around what
came back (macOS 26):

- `moveWindowToSpace` **returns `true` and moves nothing**; `windowSpaces` keeps
  answering with the Space the window was already on, whether it is asked with a
  window object or a window id.  `world.moveSpaceNoop` is therefore the machine's
  real behaviour rather than a hypothetical, and `"recreate"` is the only fallback
  that puts the panel in front of the user.
- A window on a Space its display is not showing is **absent from
  `app:allWindows()` entirely** — the desktop is all that comes back — while
  AppleScript still lists every tab, its path and its bounds.  `world.axCanSee`
  models this per window, from the Space its own display is showing, and
  `world.axSeesOtherSpaces` turns it off for tests written for the other possible
  system, where Accessibility hands over everything.  This is what made the
  cross-Space code unreachable: it was gated on having a window object.
- What still answers from there is the window **id**: `hs.spaces` reads the Space
  from it, AppleScript closes by it, and `set bounds of window id N` moves the
  window — which is why `F.setBounds` exists in the simulator and shares
  `o:setFrame`'s clamp and event exactly.
- A window that **arrives on a display** joins the Space showing there, with no
  `hs.spaces` call involved.  Only a move that *changes display* does this: a
  Space belongs to one display, so sliding a window around inside its own display
  cannot carry it elsewhere, and modelling every `setFrame` as a Space change
  quietly excused the `"activate"` fallback from ever admitting it was stuck.

Their premise matters, and got this wrong once.  Requirement 10 is *same display,
stale Space*: the panes keep the frames they had, and the display they are on is
now showing someone else's Space.  Setting the scene by hiding the panel first
tests something different — a parked pane sits in a corner of **another display**,
and one of those needs no `hs.spaces` call at all.  So `world.lua` models
`hs.window:screen()` the way Hammerspoon defines it, as the display a window has
the largest intersection with (its centre is off in the void while the visible
40×52px sliver is on exactly one display, and that display owns the Space), and
the sections split: the move happens without hiding, while a separate section
asserts that a parked pane is left alone.

## The mutation gate

`mutate.sh` copies `lib/` to a temp dir, breaks exactly one thing with `perl`,
and points a suite at the copy via `DF_LIB` — the panel suite by default, or
whichever one a fourth argument to `run_mut` names (`config.lua`'s own rules are
checked by `pure_spec`, and running the integration suite against them would
report `SURVIVED` for want of a test rather than for want of code).  `killed` is
the good outcome.  Two other verdicts matter:

- **`SURVIVED`** — the tests are weaker than they look.  Add an assertion; do
  not delete the mutant.
- **`NO-OP`** — the mutant's pattern no longer matches the source, so nothing
  was broken and the pass is meaningless.  The mutant needs updating, not the
  code.  Without the md5 check this reported as `SURVIVED`.

- **`BROKEN`** — the mutation left a file that does not parse.  Every test
  "fails", so the line looks like a kill but proves nothing about the tests.
  Two of these sat in the gate for a whole phase before the compile check went
  in.

Mutants are only worth having where they are *observable*.  Two guards here
protect the same comparison — `hide()` recording the park as `pane.frame`, and
`onWindowMoved` comparing against `pane.parked` — so removing either alone
changes nothing and the mutant would survive for an honest reason.  They are
mutated together (`hide() and windowMoved both forget the park`).  Same reason
the layout mutant deletes the whole deferred re-read instead of changing what it
assigns: assigning the requested rect happens to be right.

`init.lua` is out of the gate's reach: `mutate.sh` copies `lib/` only, and
`init.lua` finds its modules through `hs.spoons.resourcePath`, not `DF_LIB`.
`hotkey_spec.lua` covers it by assertion instead — including the two things the
old one-handle-per-action code got wrong, a second key for the same action and
handles that outlived `stop()`.
