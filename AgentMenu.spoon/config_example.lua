--- config_example.lua — AgentMenu.spoon 完整配置示例
--
-- 使用方法（在 ~/.hammerspoon/init.lua 中）：
--
--   hs.loadSpoon("AgentMenu")
--   local cfg = require("agentmenu_config")   -- 放在 ~/.hammerspoon/ 下
--   spoon.AgentMenu:configure(cfg):start()
--
-- 将本文件复制为 ~/.hammerspoon/agentmenu_config.lua 并按需修改。

return {
  lang = "en",  -- 可选，默认为 "en"；支持 "en"、"zh" 等 ISO 639-1 语言代码，但需要res目录下有对应的i18n文件（如zh.lua）才能生效；不支持的语言代码会回退到英文。
  -- ────────────────────────────────────────────────────────────────────────
  -- 1. AI 提供商列表
  --    每个提供商需要：
  --      name    — 任意唯一字符串，用于下方 models 中引用
  --      baseUrl — OpenAI Compatible API 的基础 URL（/chat/completions 之前的部分）
  --      apiKey  — API 密钥
  -- ────────────────────────────────────────────────────────────────────────
  providers = {
    {
      name    = "OpenAI",
      baseUrl = "https://api.openai.com/v1",
      apiKey  = "sk-your-openai-key-here",
    },
    -- 示例：本地 Ollama
    -- {
    --   name    = "Ollama",
    --   baseUrl = "http://localhost:11434/v1",
    --   apiKey  = "ollama",  -- Ollama 不需要真实密钥，填任意字符串
    -- },
    -- 示例：其他 OpenAI 兼容服务（如 DeepSeek、通义千问等）
    -- {
    --   name    = "DeepSeek",
    --   baseUrl = "https://api.deepseek.com/v1",
    --   apiKey  = "sk-your-deepseek-key",
    -- },
  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 2. 模型列表
  --    name     — 实际发送给 API 的模型名称
  --    provider — 对应上面 providers 中的 name
  --    id       — （可选）在 modelSetProfiles 和 actions 中引用此模型的唯一标识符；
  --               省略时默认等于 name。
  --               当不同 provider 提供同名模型时（如都叫 "llama3"），
  --               用不同 id 加以区分。
  -- ────────────────────────────────────────────────────────────────────────
  models = {
    { id = "gpt-4o",        name = "gpt-4o",        provider = "OpenAI" },
    { id = "gpt-4o-mini",   name = "gpt-4o-mini",   provider = "OpenAI" },
    { id = "gpt-35-turbo",  name = "gpt-3.5-turbo", provider = "OpenAI" },
    -- 示例：不同 provider 提供同名模型，用 id 区分
    -- { id = "ollama-llama3",  name = "llama3",  provider = "Ollama"   },
    -- { id = "ds-chat",        name = "deepseek-chat", provider = "DeepSeek" },
  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 3. 模型集合配置（Model Set Profile）
  --    定义主模型及其 fallback 链：当主模型调用失败时，依次尝试 fallbacks。
  --    name         — 任意唯一字符串
  --    primaryModel — 首选模型（对应 models 中的 name）
  --    fallbacks    — 失败时依次尝试的模型列表（可为空 {}）
  -- ────────────────────────────────────────────────────────────────────────
  modelSetProfiles = {
    {
      name         = "default",
      primaryModel = "gpt-4o",        -- 引用 models 中的 id
      fallbacks    = { "gpt-4o-mini", "gpt-35-turbo" },
    },
    {
      name         = "fast",
      primaryModel = "gpt-4o-mini",   -- 引用 models 中的 id
      fallbacks    = { "gpt-35-turbo" },
    },
  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 4. replace 模式失败时的全局默认 fallback（可被 action 级别覆盖）
  --    "dialog"    — 弹窗显示（默认）
  --    "clipboard" — 复制到剪贴板
  -- ────────────────────────────────────────────────────────────────────────
  replaceFallback = "dialog",

  -- ────────────────────────────────────────────────────────────────────────
  -- 5. Actions（用户自定义操作）
  --
  --  name            — 内部标识符（字母数字下划线）
  --  label           — 工具栏/菜单中显示的名称
  --  prompt          — 发送给 AI 的 prompt 模板
  --  parameters      — 用户自定义参数列表（见下方说明，可为空 {}）
  --  outputMode      — 输出方式："dialog"（默认）| "clipboard" | "replace"
  --  replaceFallback — replace 失败时的 fallback（覆盖全局设置）
  --  modelSetProfile — 使用的模型集合（默认为第一个 modelSetProfiles）
  --
  -- ── Prompt 模板语法 ──────────────────────────────────────────────────
  --   {{name}}              — 替换为参数 name 的值
  --   {{a|b|c}}             — Pipe fallback：依次取第一个非空值
  --   最后一段如不是参数名，则作为字面量兜底
  --
  -- ── 内置参数（无需在 parameters 中声明）──────────────────────────────
  --   {{selection}}  — 当前选中的文字（Accessibility API 读取）
  --   {{clipboard}}  — 当前剪贴板内容
  --
  -- ── 用户自定义参数 ────────────────────────────────────────────────────
  --   { name, label, default }
  --   只要 action 有用户参数，就会弹出输入对话框（预填 default 值）。
  --   内置参数名（selection、clipboard）即使写在 parameters 中也会被忽略。
  -- ────────────────────────────────────────────────────────────────────────
  actions = {

    -- 示例 1：将选中文字翻译为指定语言
    {
      name    = "translate",
      label   = "翻译",
      prompt  = [[将以下内容翻译成{{language}}，只输出翻译结果，不要解释：

{{selection|clipboard|请先选中文字或复制内容}}]],
      parameters = {
        { name = "language", label = "目标语言", default = "中文",
          options = { "中文", "英文", "日文", "韩文", "法文", "德文", "西班牙文" } },
      },
      outputMode      = "dialog",
      modelSetProfile = "default",
    },

    -- 示例 2：对选中文字进行总结（无用户参数，直接调用不弹窗）
    {
      name    = "summarize",
      label   = "总结",
      prompt  = [[用简洁的中文总结以下内容（3～5 句话）：

{{selection|clipboard}}]],
      parameters      = {},   -- 无用户参数，选中即可直接执行
      outputMode      = "dialog",
      modelSetProfile = "default",
    },

    -- 示例 3：语法纠错并直接替换（replace 模式）
    {
      name    = "fix_grammar",
      label   = "纠正语法",
      prompt  = [[修正以下文字的语法和拼写错误，保持原意和风格，只输出修正后的文字：

{{selection}}]],
      parameters      = {},
      outputMode      = "replace",
      replaceFallback = "dialog",   -- 不支持 replace 时弹窗显示
      modelSetProfile = "fast",
    },

    -- 示例 4：将选中代码解释清楚
    {
      name    = "explain_code",
      label   = "解释代码",
      prompt  = [[请用{{language}}解释以下代码的功能和关键逻辑：

```
{{selection|clipboard}}
```]],
      parameters = {
        { name = "language", label = "解释语言", default = "中文" },
      },
      outputMode      = "dialog",
      modelSetProfile = "default",
    },

    -- 示例 5：自定义 prompt（每次弹窗询问指令）
    {
      name    = "custom",
      label   = "自定义指令",
      prompt  = [[{{instruction}}

{{selection|clipboard}}]],
      parameters = {
        { name = "instruction", label = "你的指令", default = "" },
      },
      outputMode      = "dialog",
      modelSetProfile = "default",
    },

  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 6. 快速菜单（Quick Menu）
  --    鼠标松开并检测到文字选中时，在选中区域旁边显示一个小圆点。
  --    鼠标移到小圆点上时，它会扩大为一个圆形按钮（≡）；
  --    点击按钮后弹出菜单，从中选择操作。
  --
  --    配置键为 "quick-menu"；同时兼容旧版 "toolbar" 关键字。
  --    actions — 显示在菜单中的 action name 列表（顺序即菜单项顺序）
  -- ────────────────────────────────────────────────────────────────────────
  ["quick-menu"] = {
    actions = { "translate", "summarize", "fix_grammar" },
  },

  -- ────────────────────────────────────────────────────────────────────────
  -- 7. 全局快捷键菜单
  --    按下快捷键时弹出 hs.chooser 列表，从中选择 action。
  --    mods    — 修饰键列表，如 {"ctrl", "alt"}、{"cmd", "shift"}
  --    key     — 触发键，如 "a"
  --    actions — 显示在快捷键菜单中的 action name 列表
  -- ────────────────────────────────────────────────────────────────────────
  hotkey = {
    mods    = { "ctrl", "alt" },
    key     = "a",
    actions = { "translate", "summarize", "fix_grammar", "explain_code", "custom" },
  },

}
