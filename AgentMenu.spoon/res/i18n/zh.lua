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

  -- result_dialog.html — 把回答写回原来的选区
  REPLACE_LABEL        = "替换原文",
  REPLACE_TITLE        = "用这段回答替换选中的文字",
  REPLACE_BUSY_LABEL   = "替换中…",
  REPLACE_CONFIRM_LABEL = "\226\156\147 \229\183\178\230\155\191\230\141\162",
  REPLACED_ALERT       = "✓ 已替换选中的文字",
  REPLACE_STALE_ALERT  = "原文已改动，未做替换（请改用复制）",
  REPLACE_FAILED_ALERT = "无法替换选中的文字",
}
