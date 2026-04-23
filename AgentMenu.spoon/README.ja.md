# AgentMenu.spoon

[English](README.md) | [中文说明](README.zh.md)

Hammerspoon 上に構築された、macOS 向け AI クイックメニュー＆ホットキーランチャーです。  
画面上でテキストを選択すると、すぐそばにアクションボタンが現れます — クリックするだけで AI を実行できます。  
OpenAI 互換の API であればどれでも動作します（OpenAI・Ollama・DeepSeek・Qwen など）。

## 機能

- **クイックメニュー** — テキストを選択すると近くに小さな点が現れ、ホバーするとボタンに展開、クリックでアクションを選択
- **ホットキーランチャー** — グローバルホットキーを押すと、全アクションの検索可能なリストが表示
- **ストリーミング応答** — 結果が Markdown レンダリング対応のフローティングチャットウィンドウにストリーミング表示
- **追加質問** — 同じウィンドウで AI との会話を継続
- **モデルフォールバックチェーン** — プライマリモデルが失敗した場合、自動的に次のモデルを試行
- **柔軟な出力モード** — ダイアログ表示・クリップボードコピー・選択テキストのインプレース置換
- **ローカライズ対応** — 英語・中国語・日本語を内蔵；`.lua` ファイル 1 つで任意の言語を追加可能
- **完全設定可能** — プロバイダー・モデル・プロファイル・アクション・プロンプト・パラメーターをすべて 1 つの設定ファイルで管理

## 必要環境

- macOS（Sonoma 以降でテスト済み）
- [Hammerspoon](https://www.hammerspoon.org/) 0.9.100 以降
- OpenAI 互換の API キー（またはローカルの Ollama インスタンス）

## インストール方法

1. このリポジトリをクローンまたはダウンロードします。
2. `AgentMenu.spoon` を `~/.hammerspoon/Spoons/` にコピー（またはシンボリックリンクを作成）します。
3. `AgentMenu.spoon/config_example.lua` を `~/.hammerspoon/agentmenu_config.lua` にコピーし、API キーを設定します。
4. `~/.hammerspoon/init.lua` に以下を追記します：

```lua
hs.loadSpoon("AgentMenu")
local cfg = require("agentmenu_config")
spoon.AgentMenu:configure(cfg):start()
```

5. Hammerspoon をリロードします（Hammerspoon コンソールで `Cmd+Shift+R`、またはメニューバーアイコン → *Reload Config*）。

## 設定

設定はすべて `agentmenu_config.lua` ファイルに記述します（`config_example.lua` からコピー）。  
完全な注釈付きリファレンスは [config_example.lua](config_example.lua) を参照してください。

設定テーブルには 7 つのトップレベルキーがあります：

| キー | 説明 |
|------|------|
| `lang` | UI 言語 — `"en"`（デフォルト）・`"zh"`・`"ja"` など；[ローカライズ](#ローカライズ) を参照 |
| `providers` | AI プロバイダーリスト — 名前・ベース URL・API キー |
| `models` | モデルリスト — 名前・プロバイダー・省略可能な id |
| `modelSetProfiles` | プライマリモデルとフォールバックチェーンを持つ名前付きプロファイル |
| `replaceFallback` | replace モードが使用できない場合のグローバルフォールバック（`"dialog"` または `"clipboard"`） |
| `actions` | カスタム AI アクション（下記参照） |
| `quick-menu` | フローティング選択メニューに表示するアクション |
| `hotkey` | グローバルホットキーとランチャーに表示するアクション |

### アクションの定義

```lua
{
  name    = "translate",          -- 内部識別子
  label   = "翻訳",               -- メニューに表示する名前
  prompt  = [[以下の内容を{{language}}に翻訳してください。翻訳結果のみ出力してください：

{{selection|clipboard|テキストを選択するかコンテンツをコピーしてください}}]],
  parameters = {
    { name = "language", label = "翻訳先言語", default = "日本語",
      options = { "日本語", "英語", "中国語", "韓国語", "フランス語" } },
  },
  outputMode      = "dialog",     -- "dialog" | "clipboard" | "replace"
  replaceFallback = "dialog",     -- replace が使用できない場合のフォールバック
  modelSetProfile = "default",    -- 使用するプロファイル
},
```

### プロンプトテンプレートの構文

| 構文 | 意味 |
|------|------|
| `{{name}}` | パラメーター `name` の値に置換 |
| `{{a\|b\|c}}` | パイプフォールバック：`a`・`b`・`c` の中で最初の空でない値を使用；最後のセグメントはリテラルのフォールバック文字列 |
| `{{selection}}` | 組み込み：現在の選択テキスト |
| `{{clipboard}}` | 組み込み：現在のクリップボードの内容 |

## ローカライズ

設定ファイルの `lang` フィールドで UI 言語を設定します：

```lua
lang = "ja",  -- 日本語に切り替え
```

内蔵言語：`"en"`・`"zh"`・`"ja"`。

新しい言語を追加するには、[`res/i18n/en.lua`](res/i18n/en.lua) を参考に `res/i18n/<lang>.lua` を作成してください。

## ディレクトリ構造

```
init.lua                 — Spoon エントリーポイント
config_example.lua       — 注釈付き設定リファレンス
lib/
  ai.lua                 — ストリーミングとフォールバック対応の非同期 AI クライアント
  config.lua             — 設定の検証と正規化
  param_dialog.lua       — パラメーター入力ダイアログ（hs.webview）
  popup.lua              — フローティングドット → ボタン → クイックメニュー
  result_ui.lua          — ストリーミング結果ダイアログ
  selection.lua          — Accessibility API テキスト選択監視
  templates.lua          — HTML テンプレートローダー + i18n エンジン
  utils.lua              — 共通ヘルパー
res/
  templates/
    result_dialog.html   — チャット/結果ウィンドウテンプレート
    param_dialog.html    — パラメーター入力ダイアログテンプレート
  i18n/
    en.lua               — 英語 UI 文字列
    zh.lua               — 中国語 UI 文字列
    ja.lua               — 日本語 UI 文字列
```

## ライセンス

MIT — [LICENSE](../LICENSE) を参照。
