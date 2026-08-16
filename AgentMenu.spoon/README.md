# AgentMenu.spoon

[中文说明](README.zh.md) | [日本語](README.ja.md)

An AI-powered quick-menu and hotkey chooser for macOS, built on Hammerspoon.  
Select any text on screen and an action button appears instantly — click it to run AI on the selection.  
Works with any OpenAI-compatible API (OpenAI, Ollama, DeepSeek, Qwen, etc.).

## Features

- **Quick menu** — a floating dot appears near your text selection; hover to expand, click to pick an action
- **Hotkey chooser** — press a global hotkey to open a searchable list of all actions
- **Streaming responses** — results stream into a floating chat window with Markdown rendering
- **Follow-up questions** — continue the conversation in the same window
- **Model fallback chain** — if the primary model fails, the next one in the chain is tried automatically
- **Flexible output modes** — show in dialog, copy to clipboard, or replace selected text in-place
- **Localised UI** — built-in English and Chinese; add more languages with a single `.lua` file
- **Fully configurable** — providers, models, profiles, actions, prompts, parameters all defined in one config file

## Requirements

- macOS (tested on Sonoma and later)
- [Hammerspoon](https://www.hammerspoon.org/) 0.9.100 or later
- An OpenAI-compatible API key (or a local Ollama instance)

## Installation

1. Clone or download this repository.
2. Copy (or symlink) `AgentMenu.spoon` into `~/.hammerspoon/Spoons/`.
3. Copy `AgentMenu.spoon/config_example.lua` to `~/.hammerspoon/agentmenu_config.lua` and fill in your API key(s).
4. Add the following to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("AgentMenu")
local cfg = require("agentmenu_config")
spoon.AgentMenu:configure(cfg):start()
```

5. Reload Hammerspoon (`Cmd+Shift+R` in the Hammerspoon console, or click the menubar icon → *Reload Config*).

## Configuration

All configuration lives in your `agentmenu_config.lua` file (copied from `config_example.lua`).  
See [config_example.lua](config_example.lua) for the full annotated reference.

The config table has these top-level keys:

| Key | Description |
|-----|-------------|
| `lang` | UI language — `"en"` (default), `"zh"` or `"ja"`; see [Localisation](#localisation) |
| `preloadWebview` | Optional, default `true`. Build the result window ~2 s after `start()` instead of on first use — removes a WebView cold start from every invocation, at the cost of ~40 MB resident |
| `axTimeout` | Optional, default `0.5` (seconds). Accessibility messaging timeout for reading the selection; the system default of 6 s means an unresponsive app can stall Hammerspoon for that long. `0` leaves the system default alone. Note: this changes the *global* AX default, affecting other spoons |
| `providers` | AI provider list — name, base URL, API key |
| `models` | Model list — name, provider, optional id |
| `modelSetProfiles` | Named profiles with a primary model and fallback chain |
| `replaceFallback` | Global fallback when replace mode is unavailable (`"dialog"` or `"clipboard"`) |
| `actions` | Your custom AI actions (see below) |
| `quick-menu` | Which actions appear in the floating selection menu |
| `hotkey` | Global hotkey and which actions appear in the chooser |

### Defining an action

```lua
{
  name    = "translate",          -- internal identifier
  label   = "Translate",          -- shown in menus
  prompt  = [[Translate the following into {{language}}:

{{selection|clipboard|No text selected}}]],
  parameters = {
    { name = "language", label = "Target language", default = "English",
      options = { "English", "Chinese", "Japanese" } },
  },
  outputMode      = "dialog",     -- "dialog" | "clipboard" | "replace"
  replaceFallback = "dialog",     -- used when replace is unavailable
  modelSetProfile = "default",    -- which profile to use
},
```

### Parameter input

Parameters are collected with a native `hs.chooser`: it opens instantly, filters
as you type, and any typed text can be submitted — a *"use what you typed"* row
is offered even when `options` is set. It is single-line only.

Enter always takes the highlighted first row, and that row is whatever you
typed — so a value that is not in `options` needs no mouse. Type a declared
option in full and the first row becomes that option instead, matched
case-insensitively (typing `chinese` submits `Chinese`). Options that merely
contain what you typed are listed underneath; press ↓ to pick one.

Set `multiline = true` on a parameter when it genuinely needs more than one line:

```lua
parameters = {
  { name = "instruction", label = "Your instruction", default = "", multiline = true },
},
```

An action with any `multiline` parameter switches to the HTML form (a WebView
with textareas) for *all* of its parameters, because Hammerspoon has no native
multi-line text field. That form is noticeably slower to open, so use the flag
only where it is needed.

### Prompt template syntax

| Syntax | Meaning |
|--------|---------|
| `{{name}}` | Replaced with the value of parameter `name` |
| `{{a\|b\|c}}` | Pipe fallback: uses the first non-empty value among `a`, `b`, `c`; the last segment is a literal fallback string |
| `{{selection}}` | Built-in: currently selected text |
| `{{clipboard}}` | Built-in: current clipboard contents |

## Localisation

The UI language is set via `lang` in your config file:

```lua
lang = "zh",  -- switch to Chinese
```

Built-in languages: `"en"`, `"zh"`, `"ja"`.

To add a new language, create `res/i18n/<lang>.lua` modelled on
[`res/i18n/en.lua`](res/i18n/en.lua).

## Directory structure

```
init.lua                 — spoon entry point
config_example.lua       — annotated configuration reference
lib/
  ai.lua                 — async AI client with streaming + fallback
  config.lua             — config validation and normalisation
  param_chooser.lua      — native parameter input (hs.chooser); the default
  param_dialog.lua       — parameter input form (hs.webview); multiline only
  popup.lua              — floating dot → button → quick menu
  result_ui.lua          — streaming result dialog
  selection.lua          — Accessibility API text selection watcher
  templates.lua          — HTML template loader + i18n engine
  utils.lua              — shared helpers
res/
  templates/
    result_dialog.html   — chat/result window template
    param_dialog.html    — parameter input dialog template
  i18n/
    en.lua               — English UI strings
    zh.lua               — Chinese UI strings
    ja.lua               — Japanese UI strings
```

## License

MIT — see [LICENSE](../LICENSE).
