# QuickRef.spoon

A Hammerspoon Spoon that opens an always-on-top quick reference window from the clipboard or the frontmost window.

## Features

- **Clipboard text** — show clipboard text in a floating, always-on-top, editable textarea
- **Clipboard image** — show clipboard image in a floating window with a checkerboard transparency background
- **Window snapshot** — capture the frontmost window and pin its screenshot as a floating overlay
- **Blank notepad** — open an empty editable text window as a quick scratch pad
- **Opacity slider** — adjust window transparency from 10 % to 100 % (default 85 %) via an in-window slider
- **Non-activating** — window appears without stealing keyboard focus from the active application
- **Pinch to zoom** — magnification gestures supported on image windows
- **Follows all Spaces** — the window stays visible across every virtual desktop and in fullscreen apps

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org/) 0.9.100 or later

## Installation

1. Clone or download this repository.
2. Copy (or symlink) `QuickRef.spoon` into `~/.hammerspoon/Spoons/`.
3. Add the following to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("QuickRef")
spoon.QuickRef:bindHotKeys({
  show_blank                    = { {"ctrl", "alt", "cmd"}, "n" },
  show_frontmost_window_capture = { {"ctrl", "alt", "cmd"}, "w" },
  show_pasteboard               = { {"ctrl", "alt", "cmd"}, "v" },
})
```

4. Reload Hammerspoon (`Cmd+Shift+R` in the Hammerspoon console, or click the menubar icon → *Reload Config*).

## API

### Functions

#### `QuickRef.showBlank([rect], [alpha])`

Open an empty editable text window.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rect` | table | `{x, y, w, h}` position/size of the window. Defaults to 400 × 200 centred on the mouse pointer. |
| `alpha` | number | Initial opacity (0–100). Default: `85`. |

Returns an `hs.webview` instance.

---

#### `QuickRef.showFrontmostWindowCapture([rect], [alpha])`

Take a snapshot of the current frontmost window and display it in a floating image window.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rect` | table | `{x, y, w, h}` position/size. Defaults to the native pixel size of the captured window near the mouse pointer. |
| `alpha` | number | Initial opacity (0–100). Default: `85`. |

Returns an `hs.webview` instance, or `nil` if no frontmost window exists.

---

#### `QuickRef.showPasteboard([rect], [alpha])`

Read the clipboard and open a matching window — image window for image content, text window for string content, blank window if the clipboard is empty.

| Parameter | Type | Description |
|-----------|------|-------------|
| `rect` | table | `{x, y, w, h}` position/size. Defaults near the mouse pointer. |
| `alpha` | number | Initial opacity (0–100). Default: `85`. |

Returns an `hs.webview` instance.

---

### Method

#### `QuickRef:bindHotKeys(mapping)`

Bind keyboard shortcuts to the three main functions.

`mapping` keys:

| Key | Function |
|-----|----------|
| `show_blank` | `showBlank()` |
| `show_frontmost_window_capture` | `showFrontmostWindowCapture()` |
| `show_pasteboard` | `showPasteboard()` |

Example:

```lua
spoon.QuickRef:bindHotKeys({
  show_blank                    = { {"ctrl", "alt", "cmd"}, "n" },
  show_frontmost_window_capture = { {"ctrl", "alt", "cmd"}, "w" },
  show_pasteboard               = { {"ctrl", "alt", "cmd"}, "v" },
})
```

## Window behaviour

| Property | Value |
|----------|-------|
| Window level | `popUpMenu` — floats above normal windows |
| Spaces behaviour | Visible in all Spaces and fullscreen apps |
| Focus | Non-activating — does not steal focus |
| Close | Clicking the close button destroys the window |
| Opacity slider | Visible at the top of every window; drag to adjust transparency |
| Gestures | Pinch-to-zoom and scroll gestures enabled |

## License

MIT — see [https://opensource.org/licenses/MIT](https://opensource.org/licenses/MIT)
