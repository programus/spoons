-- AgentMenu i18n 字符串 — 中文
-- Keys used by lib/templates.lua to fill {{KEY}} placeholders in HTML templates.

return {
  -- result_dialog.html
  CLOSE_LABEL          = "关闭",
  THINKING_LABEL       = "思考中",
  FOLLOWUP_PLACEHOLDER = "继续追问… (Cmd+Enter 发送)",
  SEND_LABEL           = "发送",
  COPY_TURN_TITLE      = "复制 Markdown 源码",
  COPY_CONFIRM_LABEL   = "✓ 已复制",

  RETRY_LABEL          = "重试",

  -- param_dialog.html（仅多行参数使用）
  PARAM_CANCEL_LABEL   = "取消",
  PARAM_OK_LABEL       = "确定",
  PARAM_WIN_TITLE      = "参数输入",

  -- param_chooser.lua（原生参数输入）
  -- PARAM_CHOOSER_HINT 必须包含字面量 {label} 占位符。
  PARAM_CHOOSER_HINT   = "{label}（可直接输入或选择，回车确认）",
  USE_TYPED_TEXT       = "使用输入的内容",
  CHOOSER_PLACEHOLDER  = "选择一个操作…",

  -- Lua-side alerts (used via templates.t())
  COPIED_ALERT         = "✓ 已复制到剪贴板",
  ERROR_PREFIX         = "出错了",
  INCOMPLETE_WARNING   = "响应可能不完整",
}
