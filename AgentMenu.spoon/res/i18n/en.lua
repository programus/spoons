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

  -- param_dialog.html
  PARAM_CANCEL_LABEL   = "Cancel",
  PARAM_OK_LABEL       = "OK",
  PARAM_WIN_TITLE      = "Parameters",

  -- Lua-side alerts (used via templates.t())
  COPIED_ALERT         = "\226\156\147 Copied to clipboard",
}
