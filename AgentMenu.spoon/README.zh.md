# AgentMenu.spoon

[English](README.md)

一个基于 Hammerspoon 的 macOS AI 快捷菜单与热键选择器。  
在屏幕上选中任意文字，旁边会立即出现一个操作按钮 — 点击即可对选中内容执行 AI 操作。  
支持任何 OpenAI 兼容的 API（OpenAI、Ollama、DeepSeek、通义千问等）。

## 功能特性

- **快速菜单** — 选中文字后，附近出现一个悬浮小圆点；鼠标悬停可展开为按钮，点击选择操作
- **热键选择器** — 按下全局热键，弹出可搜索的操作列表
- **流式响应** — 结果以流式方式输出到悬浮聊天窗口，支持 Markdown 渲染
- **追问对话** — 在同一窗口内继续与 AI 对话
- **模型备用链** — 主模型失败时自动依次尝试后备模型
- **灵活输出模式** — 弹窗显示、复制到剪贴板，或直接替换选中文字
- **界面本地化** — 内置英文和中文；只需一个 `.lua` 文件即可添加更多语言
- **完全可配置** — 提供商、模型、配置组合、操作、Prompt、参数均在一个配置文件中定义

## 系统要求

- macOS（在 Sonoma 及更新版本上测试通过）
- [Hammerspoon](https://www.hammerspoon.org/) 0.9.100 或更新版本
- OpenAI 兼容的 API Key（或本地 Ollama 实例）

## 安装方法

1. 克隆或下载本仓库。
2. 将 `AgentMenu.spoon` 复制（或创建符号链接）到 `~/.hammerspoon/Spoons/` 目录。
3. 将 `AgentMenu.spoon/config_example.lua` 复制到 `~/.hammerspoon/agentmenu_config.lua`，并填入你的 API Key。
4. 在 `~/.hammerspoon/init.lua` 中添加以下内容：

```lua
hs.loadSpoon("AgentMenu")
local cfg = require("agentmenu_config")
spoon.AgentMenu:configure(cfg):start()
```

5. 重新加载 Hammerspoon（在 Hammerspoon 控制台按 `Cmd+Shift+R`，或点击菜单栏图标 → *Reload Config*）。

## 配置说明

所有配置均在你的 `agentmenu_config.lua` 文件中（从 `config_example.lua` 复制而来）。  
完整的注释参考请查看 [config_example.lua](config_example.lua)。

配置表有七个顶级字段：

| 字段 | 说明 |
|------|------|
| `lang` | 界面语言 — `"en"`（默认）或 `"zh"`；详见[本地化](#本地化) |
| `providers` | AI 提供商列表 — 名称、基础 URL、API Key |
| `models` | 模型列表 — 名称、提供商、可选 id |
| `modelSetProfiles` | 命名配置组合，含主模型和备用链 |
| `replaceFallback` | replace 模式不可用时的全局回退（`"dialog"` 或 `"clipboard"`） |
| `actions` | 你自定义的 AI 操作（见下方） |
| `quick-menu` | 哪些操作出现在悬浮选中菜单中 |
| `hotkey` | 全局热键及在选择器中显示的操作 |

### 定义一个操作（Action）

```lua
{
  name    = "translate",        -- 内部标识符
  label   = "翻译",              -- 菜单中显示的名称
  prompt  = [[将以下内容翻译成{{language}}：

{{selection|clipboard|请先选中文字或复制内容}}]],
  parameters = {
    { name = "language", label = "目标语言", default = "中文",
      options = { "中文", "英文", "日文" } },
  },
  outputMode      = "dialog",   -- "dialog" | "clipboard" | "replace"
  replaceFallback = "dialog",   -- replace 不可用时的回退
  modelSetProfile = "default",  -- 使用哪个模型配置组合
},
```

### Prompt 模板语法

| 语法 | 含义 |
|------|------|
| `{{name}}` | 替换为参数 `name` 的值 |
| `{{a\|b\|c}}` | Pipe 回退：依次取 `a`、`b`、`c` 中第一个非空值；最后一段作为字面量兜底 |
| `{{selection}}` | 内置：当前选中文字 |
| `{{clipboard}}` | 内置：当前剪贴板内容 |

## 本地化

在配置文件中通过 `lang` 字段设置界面语言：

```lua
lang = "zh",  -- 切换为中文
```

内置语言：`"en"`、`"zh"`。

如需添加新语言，在 `res/i18n/` 目录下创建 `<lang>.lua` 文件，参照
[`res/i18n/en.lua`](res/i18n/en.lua) 的格式填写翻译即可。

## 目录结构

```
init.lua                 — Spoon 入口文件
config_example.lua       — 完整注释配置参考
lib/
  ai.lua                 — 异步 AI 客户端，支持流式传输与备用链
  config.lua             — 配置验证与规范化
  param_dialog.lua       — 参数输入对话框（hs.webview）
  popup.lua              — 悬浮小圆点 → 按钮 → 快速菜单
  result_ui.lua          — 流式结果对话框
  selection.lua          — Accessibility API 文字选中监听
  templates.lua          — HTML 模板加载器 + i18n 引擎
  utils.lua              — 公共工具函数
res/
  templates/
    result_dialog.html   — 聊天/结果窗口模板
    param_dialog.html    — 参数输入对话框模板
  i18n/
    en.lua               — 英文界面字符串
    zh.lua               — 中文界面字符串
```

## 许可证

MIT — 详见 [LICENSE](../LICENSE)。
