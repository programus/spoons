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

  -- param_dialog.html
  PARAM_CANCEL_LABEL   = "取消",
  PARAM_OK_LABEL       = "确定",
  PARAM_WIN_TITLE      = "参数输入",

  -- Lua-side alerts (used via templates.t())
  COPIED_ALERT         = "✓ 已复制到剪贴板",
}
