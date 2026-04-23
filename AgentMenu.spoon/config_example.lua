--- config_example.lua — Full configuration reference for AgentMenu.spoon
--
-- Usage (in ~/.hammerspoon/init.lua):
--
--   hs.loadSpoon("AgentMenu")
--   local cfg = require("agentmenu_config")   -- file lives in ~/.hammerspoon/
--   spoon.AgentMenu:configure(cfg):start()
--
-- Copy this file to ~/.hammerspoon/agentmenu_config.lua and edit as needed.

return {
  -- Optional. Default is "en". ISO 639-1 language code for UI labels.
  -- Supported out of the box: "en", "zh".
  -- To add a language, create res/i18n/<lang>.lua — see en.lua for the key list.
  -- Unknown codes silently fall back to "en".
  lang = "en",

  -- ────────────────────────────────────────────────────────────────────────
  -- 1. Providers
  --    Each provider entry requires:
  --      name    — any unique string; referenced by models below
  --      baseUrl — base URL of an OpenAI-compatible API (before /chat/completions)
  --      apiKey  — API key for this provider
  -- ────────────────────────────────────────────────────────────────────────
  providers = {
    {
      name    = "OpenAI",
      baseUrl = "https://api.openai.com/v1",
      apiKey  = "sk-your-openai-key-here",
    },
    -- Example: local Ollama
    -- {
    --   name    = "Ollama",
    --   baseUrl = "http://localhost:11434/v1",
    --   apiKey  = "ollama",  -- Ollama does not require a real key
    -- },
    -- Example: other OpenAI-compatible services (DeepSeek, Qwen, etc.)
    -- {
    --   name    = "DeepSeek",
    --   baseUrl = "https://api.deepseek.com/v1",
    --   apiKey  = "sk-your-deepseek-key",
    -- },
  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 2. Models
  --    name     — model identifier sent to the API (e.g. "gpt-4o")
  --    provider — references a provider name above
  --    id       — (optional) unique key used in modelSetProfiles and actions;
  --               defaults to `name` when omitted.
  --               Use `id` to distinguish two models with the same API name
  --               from different providers (e.g. both called "llama3").
  -- ────────────────────────────────────────────────────────────────────────
  models = {
    { id = "gpt-4o",        name = "gpt-4o",        provider = "OpenAI" },
    { id = "gpt-4o-mini",   name = "gpt-4o-mini",   provider = "OpenAI" },
    { id = "gpt-35-turbo",  name = "gpt-3.5-turbo", provider = "OpenAI" },
    -- Example: same model name from different providers — use id to distinguish
    -- { id = "ollama-llama3",  name = "llama3",        provider = "Ollama"   },
    -- { id = "ds-chat",        name = "deepseek-chat", provider = "DeepSeek" },
  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 3. Model Set Profiles
  --    Define a primary model and its fallback chain.
  --    When the primary model fails, each fallback is tried in order.
  --
  --    name         — any unique string
  --    primaryModel — preferred model (references a model id above)
  --    fallbacks    — ordered list of model ids tried on failure (may be {})
  -- ────────────────────────────────────────────────────────────────────────
  modelSetProfiles = {
    {
      name         = "default",
      primaryModel = "gpt-4o",
      fallbacks    = { "gpt-4o-mini", "gpt-35-turbo" },
    },
    {
      name         = "fast",
      primaryModel = "gpt-4o-mini",
      fallbacks    = { "gpt-35-turbo" },
    },
  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 4. Global replace-mode fallback (can be overridden per action)
  --    Used when outputMode = "replace" and the target field is not settable.
  --    "dialog"    — show result in a floating dialog (default)
  --    "clipboard" — copy result to clipboard
  -- ────────────────────────────────────────────────────────────────────────
  replaceFallback = "dialog",

  -- ────────────────────────────────────────────────────────────────────────
  -- 5. Actions
  --
  --  name            — internal identifier (alphanumeric + underscore)
  --  label           — text shown in the quick-menu and hotkey chooser
  --  prompt          — prompt template sent to the AI (see syntax below)
  --  parameters      — list of user-defined parameters (see below); may be {}
  --  outputMode      — how to deliver the result:
  --                      "dialog"    — floating chat window (default)
  --                      "clipboard" — copy to clipboard silently
  --                      "replace"   — replace the selected text in-place
  --  replaceFallback — per-action override of the global replaceFallback
  --  modelSetProfile — which profile to use (defaults to the first profile)
  --
  -- ── Prompt template syntax ───────────────────────────────────────────────
  --   {{name}}      — replaced with the value of parameter `name`
  --   {{a|b|c}}     — pipe fallback: uses the first non-empty value among
  --                   params a, b, c; the last segment is always a literal
  --                   fallback string if no earlier candidate resolves.
  --
  -- ── Built-in parameters (no declaration needed) ──────────────────────────
  --   {{selection}} — currently selected text (via Accessibility API)
  --   {{clipboard}} — current clipboard contents
  --
  -- ── User-defined parameters ──────────────────────────────────────────────
  --   { name, label, default, options }
  --   A dialog is shown to collect values before the action runs.
  --   `options` is an optional list of strings for a combobox dropdown.
  --   Built-in names (selection, clipboard) in parameters are silently ignored.
  -- ────────────────────────────────────────────────────────────────────────
  actions = {

    -- Example 1: translate selected text into a chosen target language
    {
      name    = "translate",
      label   = "Translate",
      prompt  = [[Translate the following text into {{language}}. Output only the translation, no explanation:

{{selection|clipboard|Please select text or copy content first}}]],
      parameters = {
        { name = "language", label = "Target language", default = "English",
          options = { "English", "Chinese", "Japanese", "Korean", "French", "German", "Spanish" } },
      },
      outputMode      = "dialog",
      modelSetProfile = "default",
    },

    -- Example 2: summarise selected text (no user parameters — runs immediately)
    {
      name    = "summarize",
      label   = "Summarise",
      prompt  = [[Summarise the following text in 3–5 concise sentences:

{{selection|clipboard}}]],
      parameters      = {},
      outputMode      = "dialog",
      modelSetProfile = "default",
    },

    -- Example 3: fix grammar and replace in-place
    {
      name    = "fix_grammar",
      label   = "Fix grammar",
      prompt  = [[Correct the grammar and spelling of the following text. Preserve the original meaning and style. Output only the corrected text:

{{selection}}]],
      parameters      = {},
      outputMode      = "replace",
      replaceFallback = "dialog",   -- fall back to dialog if replace is unavailable
      modelSetProfile = "fast",
    },

    -- Example 4: explain selected code
    {
      name    = "explain_code",
      label   = "Explain code",
      prompt  = [[Explain the purpose and key logic of the following code in {{language}}:

```
{{selection|clipboard}}
```]],
      parameters = {
        { name = "language", label = "Explanation language", default = "English" },
      },
      outputMode      = "dialog",
      modelSetProfile = "default",
    },

    -- Example 5: freeform custom instruction
    {
      name    = "custom",
      label   = "Custom prompt",
      prompt  = [[{{instruction}}

{{selection|clipboard}}]],
      parameters = {
        { name = "instruction", label = "Your instruction", default = "" },
      },
      outputMode      = "dialog",
      modelSetProfile = "default",
    },

  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 6. Quick Menu
  --    When a text selection is detected, a small dot appears near it.
  --    Hovering the dot expands it into a circular button (≡).
  --    Clicking the button opens a compact popup menu.
  --
  --    Key: "quick-menu" (legacy alias "toolbar" also accepted).
  --    actions — ordered list of action names to show in the menu
  -- ────────────────────────────────────────────────────────────────────────
  ["quick-menu"] = {
    actions = { "translate", "summarize", "fix_grammar" },
  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 7. Global hotkey chooser
  --    Pressing the hotkey opens an hs.chooser list of all configured actions.
  --    mods    — modifier keys, e.g. {"ctrl", "alt"} or {"cmd", "shift"}
  --    key     — trigger key, e.g. "a"
  --    actions — ordered list of action names shown in the chooser
  -- ────────────────────────────────────────────────────────────────────────
  hotkey = {
    mods    = { "ctrl", "alt" },
    key     = "a",
    actions = { "translate", "summarize", "fix_grammar", "explain_code", "custom" },
  },

}

