-- AgentMenu i18n strings — Japanese
-- Keys used by lib/templates.lua to fill {{KEY}} placeholders in HTML templates.

return {
  -- result_dialog.html
  CLOSE_LABEL          = "閉じる",
  THINKING_LABEL       = "考え中",
  FOLLOWUP_PLACEHOLDER = "追加の質問… (Cmd+Enter で送信)",
  SEND_LABEL           = "送信",
  COPY_TURN_TITLE      = "Markdown ソースをコピー",
  COPY_CONFIRM_LABEL   = "✓ コピーしました",

  -- param_dialog.html
  PARAM_CANCEL_LABEL   = "キャンセル",
  PARAM_OK_LABEL       = "OK",
  PARAM_WIN_TITLE      = "パラメーター",

  -- Lua-side alerts (used via templates.t())
  COPIED_ALERT         = "✓ クリップボードにコピーしました",
}
