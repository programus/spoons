-- AgentMenu i18n strings — English
-- Keys used by lib/templates.lua to fill {{KEY}} placeholders in HTML templates.

return {
  -- result_dialog.html
  CLOSE_LABEL          = "Close",
  THINKING_LABEL       = "Thinking",
  FOLLOWUP_PLACEHOLDER = "Follow up\226\128\166 (Cmd+Enter to send)",
  SEND_LABEL           = "Send",
  COPY_TURN_TITLE      = "Copy Markdown source",
  COPY_CONFIRM_LABEL   = "\226\156\147 Copied",

  RETRY_LABEL          = "Retry",

  -- param_dialog.html (multiline parameters only)
  PARAM_CANCEL_LABEL   = "Cancel",
  PARAM_OK_LABEL       = "OK",
  PARAM_WIN_TITLE      = "Parameters",

  -- param_chooser.lua (native parameter input)
  -- PARAM_CHOOSER_HINT must contain the literal {label} token.
  PARAM_CHOOSER_HINT   = "{label} (type or pick, Enter to confirm)",
  USE_TYPED_TEXT       = "Use what you typed",
  CHOOSER_PLACEHOLDER  = "Select an action\226\128\166",

  -- Lua-side alerts (used via templates.t())
  COPIED_ALERT         = "\226\156\147 Copied to clipboard",
  ERROR_PREFIX         = "Error",
  INCOMPLETE_WARNING   = "The response may be incomplete",
}
