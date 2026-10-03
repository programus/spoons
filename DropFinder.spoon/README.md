# DropFinder.spoon

A TotalFinder-style Visor for vanilla Finder. One hotkey drops two Finder windows in from the bottom of the screen, side by side and half width each, so you can drag files between them. Press it again to put them away.

The two windows are **real Finder windows** whose position DropFinder manages. Hammerspoon cannot lift another application's windows into a floating layer, so the panel behaves like an ordinary pair of Finder windows: other windows can cover it, and losing focus does not hide it. Every Finder window that is not one of the two is left strictly alone — never moved, resized, minimized or closed.

## Features

- **Tri-state hotkey** — hidden → show and focus; showing but unfocused → raise and focus; showing and focused → hide
- **Follows the mouse** — the panel appears on the screen the pointer is on
- **Bottom-anchored** — height is a configurable fraction of the screen, floored at Finder's own minimum
- **Exactly two managed windows** — new Finder windows are never adopted behind your back; add tabs yourself with Cmd+T
- **Tabs survive** — every tab's path and which one was active come back after hiding, after a Hammerspoon reload, and after Finder restarts
- **Focus handover** — hiding the panel returns focus to the app that had it before
- **A lone side fills the panel** — close one side and the survivor expands; it goes back to half width when the other side returns
- **Adopt** — a second hotkey merges the frontmost floating Finder window into a pane as tab(s)
- **Cross-Space** — pressing the hotkey from another Space brings the panel to the one you are on

## Requirements

- macOS (developed on macOS 26 / Darwin 25.6)
- [Hammerspoon](https://www.hammerspoon.org/) 0.9.100 or later
- **Accessibility** permission for Hammerspoon — System Settings ▸ Privacy & Security ▸ Accessibility
- **Automation** permission for Hammerspoon → Finder — System Settings ▸ Privacy & Security ▸ Automation. This one is requested the first time DropFinder talks to Finder, and a denial is permanent until you flip it back on by hand.
- **TotalFinder must not be running.** See [Known limitations](#known-limitations).

## Installation

1. Clone or download this repository.
2. Copy (or symlink) `DropFinder.spoon` into `~/.hammerspoon/Spoons/`.
3. Add the following to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("DropFinder")
spoon.DropFinder:configure({
  heightRatio  = 0.4,
  defaultPaths = { left = "~/Downloads", right = "~" },
}):start()
```

4. Reload Hammerspoon (`Cmd+Shift+R` in the console, or menubar icon → *Reload Config*).

With no arguments (`:configure({}):start()`) every field takes its default, and the hotkeys are `Ctrl+Alt+F` to toggle and `Ctrl+Alt+Shift+F` to adopt.

## Configuration

Copy [`config_example.lua`](config_example.lua) to `~/.hammerspoon/dropfinder_config.lua`, edit it, and pass it in:

```lua
hs.loadSpoon("DropFinder")
local cfg = require("dropfinder_config")
spoon.DropFinder:configure(cfg):start()
```

Every field is optional. The ones worth knowing about:

| Key | Default | What it does |
|---|---|---|
| `heightRatio` | `0.25` | Panel height as a fraction of `screen:frame().h`. See the note below — `0.35`–`0.4` is usually better. |
| `defaultPaths` | `{ left = "~/Downloads", right = "~" }` | Used on first run, or when every remembered path for a side has been deleted. |
| `hideMode` | `"park"` | `"park"` moves the panes to a screen corner; `"minimize"` minimizes them into the Dock; `"lower"` leaves them where they are and gives focus back; `"hide"` hides Finder as a whole, like Cmd+H. |
| `parkCorner` | `"bottom-right"` | Which corner `"park"` uses. |
| `screenPolicy` | `"mouse"` | `"mouse"`, `"focused"` or `"main"`. |
| `restoreTabs` | `true` | Rebuild every tab of a side, not just the active one. |
| `snapBack` | `false` | Pull a pane back into place immediately if you drag it away. |
| `adoptTarget` | `"mouse"` | Which side adopt merges into: `"mouse"`, `"lastFocused"`, `"left"`, `"right"`. |
| `crossSpace` | `true` | Move the panel to the current Space when the hotkey is pressed elsewhere. |
| `crossSpaceFallback` | `"recreate"` | What to do if that move is refused: `"recreate"` (rebuild the side here) or `"activate"` (leave it). |
| `hotkeys` | `Ctrl+Alt+F` / `Ctrl+Alt+Shift+F` | `toggle` and `adopt`. |

Either action takes one key, a list of keys, or `false` for none:

```lua
hotkeys = {
  toggle = {
    { mods = { "alt" },          key = "`" },      -- TotalFinder's Visor key
    { mods = { "ctrl", "alt" },  key = "f" },      -- and one for the other hand
  },
  adopt = false,                                   -- bind nothing
}
```

Hotkeys can also be bound the `hs.spoons` way, which replaces whatever `cfg.hotkeys` set. Here too an action takes one spec or a list of them:

```lua
spoon.DropFinder:bindHotkeys({
  toggle          = { { "ctrl", "alt" },          "f" },
  adopt_frontmost = { { "ctrl", "alt", "shift" }, "f" },
})

spoon.DropFinder:bindHotkeys({
  toggle = { { { "alt" }, "`" }, { { "ctrl", "alt" }, "f" } },
})
```

### About `heightRatio`

Finder refuses to make a window shorter than **344px** (324px with `hideToolbar = true`). On a 1440px-tall display the default `0.25` gives 353px, just above the floor; on a 1080p display the floor is about a third of the screen and any smaller ratio is silently raised to it. If the panel looks taller than you asked for, this is why.

## Usage

| Action | What happens |
|---|---|
| **Toggle hotkey**, panel away | Both sides appear at the bottom of the screen the pointer is on, half width each, with the tabs they had. |
| **Toggle hotkey**, panel visible but not focused | The two panes are raised and focused, and brought to the Space you are on if they are not already there. Floating Finder windows keep their stacking order. |
| **Toggle hotkey**, panel focused | The panel is put away and focus goes back where it came from: the app you were in, or — if you brought the panel up over one of your own floating Finder windows — that window, which keeps its place in front. |
| **Cmd+T** inside a pane | An ordinary Finder tab, tracked by DropFinder from then on. |
| **Cmd+W** on a tab | The tab and its path are dropped from the model; the pane stays where it is. |
| **Close a whole side** | The survivor expands to the full panel width immediately. The next show recreates the missing side and both go back to half width. |
| **Adopt hotkey** | The frontmost floating Finder window is merged into a pane as tab(s), in order, and the source window closes. |
| **Cmd+M** on a pane | DropFinder notices; the hotkey brings it back rather than hiding it again. |

A side that was closed and is being rebuilt goes back to **the paths it was last showing**, not to `defaultPaths` — those are only the first-run fallback.

## API

| Function | Description |
|---|---|
| `spoon.DropFinder:configure(cfg)` | Validate and store config. Must be called before `start()`. Returns self. |
| `spoon.DropFinder:start()` | Check permissions, reattach to remembered panes, bind hotkeys, subscribe to Finder's window events. Returns self. |
| `spoon.DropFinder:stop()` | Persist, unbind, unsubscribe, and bring both panes back on screen (nothing is left parked in a corner or stranded in the Dock). Returns self. |
| `spoon.DropFinder:bindHotkeys(mapping)` | `hs.spoons` style binding; keys are `toggle` and `adopt_frontmost`. |
| `spoon.DropFinder.toggle()` | The tri-state hotkey action. |
| `spoon.DropFinder.show()` / `.hide()` | The two halves of it, individually. |
| `spoon.DropFinder.adoptFrontmost()` | Merge the frontmost floating Finder window in. Returns `started, err`. |
| `spoon.DropFinder.state()` | `"hidden"`, `"shown_unfocused"` or `"shown_focused"`. |
| `spoon.DropFinder.dumpState()` | The pane model as readable text — the first thing to look at when something is off. |
| `spoon.DropFinder.resetState()` | Forget everything persisted. The panes on screen are left alone; they simply stop being managed — if the panel was put away, drag the two slivers out of the corner or close them. |

Useful from a terminal:

```sh
hs -c 'spoon.DropFinder.state()'
hs -c 'spoon.DropFinder.dumpState()'
```

## How it works

Finder's tab model is only partly visible to automation, and the two halves disagree:

- **AppleScript** sees every tab as a `window`, with an `id`, a `name` and a `target` (its full path). That is where paths come from.
- **Accessibility** exposes only the **active** tab of each real window as an `AXWindow`. That is where geometry and focus come from.
- The ids in both are the same numbers, and they are assigned by Finder — which is why they stay valid across a Hammerspoon reload, and why reattaching after one is exact rather than a guess.

So a *pane* is simply a set of tab ids. An id gets into that set in exactly three ways: DropFinder created it, you pressed adopt on it, or it matches an id that was persisted. Nothing else is ever managed — that is the whole mechanism behind "floating windows are never touched".

Every id DropFinder *makes* is also written down separately, together with the pid of the Finder that issued it. That record is what keeps the guarantee from turning into a trap. Finder sometimes stops listing a live window — for minutes after a relaunch, or while its display is showing another Space — and a pane whose ids all vanish that way would otherwise be dropped from the model while the windows are still sitting in the panel's own slots, where nothing is entitled to move or close them any more. Before a side is rebuilt, DropFinder looks for exactly those windows and takes them back instead of opening new ones. The pid is the other half: ids are handed out per Finder process, so if the pid has changed since the ids were written — Finder restarted while Hammerspoon was not running — every remembered number is discarded and the sides are rebuilt from their paths, because a window in the new process could be wearing one of those numbers.

Tab **order** is read from the window's tab bar (`AXTabGroup`, titled `"tab bar"`), since AppleScript enumerates tabs by recency rather than position. Which tab is **active** is read from the same place, on demand: switching tabs emits no usable event, so there is nothing to track it with.

Because a pane is a set of ids and nothing more, there is one move that the model cannot see happen: **dragging a tab out of one window's tab bar and into another** keeps the tab's id and changes only which real window holds it, and neither API announces that. So the ids alone would go on pointing at the window the tab used to be in — which is how a single drag could once make one side follow the other side's window around and leave the other side with nothing to move.

Every reconcile therefore also checks the answer, once per side: the tabs the side thinks it has, against the folder names actually in the tab bar of the window that side resolves to. A different bag of names — in any order — means a tab has come or gone, and a drag always shows up twice, in the bag of the window the tab left as well as the one it arrived in, so a side that has become unresolvable altogether is still noticed through the window that took its tab. When that happens, DropFinder re-reads which windows hold which of its tabs, hands each side the window holding most of its tabs (a side that would be handed a window holding none of them is left empty and rebuilt instead), and moves its record of paths, active tab, park position and provenance across with them. No window is moved, created or closed to do this; only the model changes, so the very next press acts on the right two windows.


## Known limitations

Some of these are macOS refusing, not DropFinder giving up.

- **TotalFinder cannot run at the same time.** It injects into Finder and turns every tab into a real window, which DropFinder misreads completely; the two also compete for the same screen area. DropFinder detects the injection and alerts, but still starts. Quit TotalFinder and restart Finder.
- **The panel cannot float above other windows.** No API lets Hammerspoon raise another app's window into a floating level. Other windows can cover the panel; that is why losing focus does not hide it.
- **Hiding leaves a sliver.** AppKit's `constrainFrameRect:toScreen:` keeps roughly 40px horizontally and 52px vertically of every window on the desktop, through both Accessibility and AppleScript. `hideMode = "park"` therefore leaves an approximately 40×52px corner visible. It is clickable and draggable; if you drag it, the next show puts it right. `hideMode = "minimize"` removes the sliver at the price of two Dock thumbnails and panes that only the hotkey can bring back. `hideMode = "lower"` moves nothing at all: hiding only gives focus back to the app you were in, so its windows cover the panel. macOS cannot send another app's window to the back, so the panel stays visible above everything else — the desktop and the windows of any other app. The hotkey then works on focus alone: in front, it lowers; anywhere else, it brings the panel forward. `hideMode = "hide"` hides Finder itself, as Cmd+H does: the panel is gone without a trace and nothing is moved, but every other Finder window you have open goes with it and comes back with the panel. The desktop stays. Pressing Cmd+H by hand is the same thing, whatever the mode: the next hotkey press unhides Finder and brings the panel back whole.
- **A rebuild that is interrupted is resumed, not lost.** Restoring eight tabs takes several seconds, one New Tab at a time, and the tabs that have not been made yet live in a queue that is written to disk along with the rest of the recipe — so a reload, a crash or a second `killall` in the middle of a rebuild costs you nothing but the wait. One case degrades rather than resuming: if Hammerspoon reloads while a New Tab is in flight, the pane's active tab can be one the reloaded model has never seen, and there is then no window it is *certain* belongs to the pane. Rather than guess (and risk pouring tabs into one of your floating windows) DropFinder stops that drain and keeps the queue — the next hotkey press rebuilds the side and every path comes back.
- **Per-tab back/forward history is not restorable.** Neither API exposes it, so a rebuilt tab starts with empty history. Ordinary hiding keeps it, because nothing is closed.
- **Dragging tabs between the two panes changes which side they belong to.** That is deliberate: the windows are real Finder windows and the tab bars are real tab bars, so DropFinder follows what you did rather than undoing it. The side each window belongs to can therefore swap over, and if you drag *every* tab of one side into the other, that side is empty and the next press rebuilds it from its saved paths.
- **Dragging a tab out into a window of its own removes it from the panel.** A tab dropped on the desktop becomes a window DropFinder did not create, and requirement 2 forbids taking that over, so the tab leaves the model and that window is never moved, resized or closed again. The same is true of a tab dragged into a window you opened yourself. Use the adopt hotkey to bring either one back.
- **A drag can be unreadable when folder names repeat.** Working out where tabs went is done by folder name, because that is all a tab bar reports. If two tabs involved share a name and cannot be told apart, DropFinder declines to guess and leaves the model exactly as it was, rather than risk pairing a side with the wrong window. Press the hotkey after renaming, or move the tab back, or adopt.
- **Two tabs with the same folder name in one pane can be listed in the wrong order.** The tab bar only reports basenames, so identical names cannot be told apart. No path is ever lost or duplicated — paths come from ids — only the order of those two entries may be wrong.
- **Right after `killall Finder`** macOS restores Finder's pre-crash windows with fresh ids. The ids cannot name them, so the first rebuild after a relaunch looks for them by what they hold instead: a window whose tabs are exactly the folders a side had, all reporting one frame, is that side, and is taken back rather than opened again. One-tab sides must also be standing where a pane of that side would stand, because one folder is too easy to match by accident; and when two windows qualify for the same side, neither is taken. Only that first rebuild looks — after it, a window with the pane's folders is yours. Before this, a relaunch left four panel-sized windows on screen: the two restored ones under two new ones. (Two *further* stray windows used to appear here, one per side, titled with your machine name: a just-relaunched Finder accepts `make new Finder window` but cannot say which id it made, so the window could be neither used nor closed. The id is now recovered from the error's own object specifier and the window is closed.)
- **A Finder restart nobody saw costs the windows' identity, not their contents.** If Finder is restarted while Hammerspoon is not running, the panes' ids belong to a process that no longer exists and the numbers may have been handed out again. DropFinder compares Finder's pid with the one it saved and throws the numbers away. The next show then looks for the windows macOS restored, as above — that look is persisted, so a reload in between does not lose it — and rebuilds only a side it cannot find.
- **The first press after Finder restarts is slow.** A Finder that has just relaunched and has never been activated accepts new windows but cannot address them, and answers `id of every window` with nothing at all. DropFinder notices, activates Finder once — the same thing `open -a Finder` does — takes back the windows it could not use, and tries again, which takes a few seconds. During those seconds the panel may briefly come up one side at a time.
- **Adopt rebuilds, it does not move.** Merged tabs keep their paths and order, but lose scroll position, selection and history. To read a tab's path the tab has to be the active one, so during a merge you will see the source window flick through its tabs left to right. `Window ▸ Merge All Windows` is deliberately not used: it is a global action that would swallow the other pane and every floating window too. If a tab cannot be recreated, adopt stops there — the tabs already moved stay in the pane, the rest stay in the source window, and nothing is lost.
- **Cross-Space works, but not through `hs.spaces`.** Measured on macOS 26 with Spaces created for the purpose: `hs.spaces.moveWindowToSpace` returns `true` and moves nothing, and `windowSpaces` keeps reporting the Space the window was already on. Minimizing and restoring a window does not move it either, nor does sending it to another display and back (displays sharing Spaces). What does move it is Finder itself: selecting an *inactive* tab by id from another Space carries its whole window onto your Space. So a side with two or more tabs is fetched that way — DropFinder selects another tab, then the one that was showing — and keeps every tab, scroll position and selection. A one-tab side has no other tab to go through, and neither does a side the hop failed to move; those go to `crossSpaceFallback`. Two things it cannot help with. A *minimized* pane cannot be fetched at all: macOS restores it on the Space it was minimized on and switches you there, whichever way it is touched — so with `hideMode = "minimize"` the hotkey on another Space takes you to the panel instead of bringing it. Use `"park"` or `"lower"` with Spaces. And with displays sharing their Spaces, a pane parked on another display is just as far away as one in the middle of the screen, so it is fetched the same way. The default `"recreate"` closes the side and reopens it at the same paths on your Space, at the cost of scroll position and selection, with an alert when its tabs are all back. `"activate"` leaves it where it is and tells you once.
  What made this invisible for a while is worth knowing, because it shapes what the panel can do at all: a window on a Space its display is not currently showing is **absent from Accessibility entirely** — `Finder:allWindows()` answers with the desktop and nothing else — while AppleScript keeps listing every tab, its path and its bounds. So the panes are still tracked from another Space, but there is no `hs.window` to act on. Everything DropFinder does from there goes by window id: reading the Space, closing a tab, and `set bounds`, which is how a pane on another *display* is fetched without any Space call at all (a window that arrives on a display joins the Space showing there).
- **A reattached display does not reclaim the panel.** There is no notion of a home display: the panel goes where the mouse is when you show it. Unplugging the display it is on is handled — both panes survive and are re-laid out on a remaining display, at that display's panel size, with nothing closed. Plugging the display back in leaves them where they are; move the mouse across and put the panel away and back out to bring it over. A single press while the panel is already up raises and focuses it without moving it.
- **The sidebars stay where Finder puts them.** TotalFinder mirrors the right-hand window so that the two sidebars sit on the outer edges and the drop targets face each other across a narrow gap. That is not a Finder setting — TotalFinder achieves it by injecting code into Finder. From outside, the only vanilla lever is each window's AppleScript `sidebar width`, and collapsing the right pane's sidebar to 0 hides its places list rather than moving it, so DropFinder leaves the sidebars alone.
- **A rebuild flickers.** When a side is rebuilt with several tabs, they are created after the panel is already on screen, so the active tab flicks through them for a few hundred ms. Ordinary show/hide does not do this.

## Directory structure

```
DropFinder.spoon/
  init.lua              lifecycle, hotkeys, dependency injection, public API
  config_example.lua    annotated configuration reference
  docs.json             spoon metadata
  lib/config.lua        validation and default merging
  lib/geometry.lua      frame maths, applyFrame, minimum-height measurement
  lib/finder.lua        every Finder read and write (AppleScript + AX)
  lib/panel.lua         the pane model, rebuilding, show/hide/raise/adopt
  lib/store.lua         hs.settings persistence
  lib/watchers.lua      window filter, application and screen watchers, shutdown hook
  test/                 offline test suite — see test/README.md
```

`lib` modules never require each other; `init.lua` injects their dependencies. The tests run under plain `luajit` against a simulator of Finder and AppKit, so they need neither Hammerspoon nor a real Finder: `test/run.sh`. What has to be checked against a real Finder instead is in `test/manual.md`, which also records what the last live pass measured and the five defects it found.

## License

MIT
