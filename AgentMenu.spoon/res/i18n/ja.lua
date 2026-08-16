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

  RETRY_LABEL          = "再試行",

  -- param_dialog.html（複数行パラメーターのみ）
  PARAM_CANCEL_LABEL   = "キャンセル",
  PARAM_OK_LABEL       = "OK",
  PARAM_WIN_TITLE      = "パラメーター",

  -- param_chooser.lua（ネイティブのパラメーター入力）
  -- PARAM_CHOOSER_HINT には {label} というトークンをそのまま含めてください。
  PARAM_CHOOSER_HINT   = "{label}（入力または選択、Enter で決定）",
  USE_TYPED_TEXT       = "入力した内容を使う",
  CHOOSER_PLACEHOLDER  = "アクションを選択…",

  -- Lua-side alerts (used via templates.t())
  COPIED_ALERT         = "✓ クリップボードにコピーしました",
  ERROR_PREFIX         = "エラー",
  INCOMPLETE_WARNING   = "応答が不完全な可能性があります",
}
