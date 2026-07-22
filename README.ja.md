<div align="center">

# `>` RELAY_ 串联器

**macOS 向けのローカル・マルチ CLI エージェントワークベンチ**

Claude Code・Codex・Grok・Ollama の本物の TUI を 1 枚のキャンバスに並べて埋め込み、<br>
同時回答 · 順次リレー · 円卓対話 · 構造化された判定 · プライベートな決定チェーン——すべて Mac の中だけで。

**[简体中文](README.md)** · **[English](README.en.md)** · **日本語**

**[ランディングページ ↗](https://shinteni.github.io/relay-workbench/)**

UI は 简体中文 / 日本語 / English · SwiftUI GUI + Rust daemon · テスト基線：Rust 113 + Swift 151

</div>

---

## ハイライト

| | |
|---|---|
| **本物のターミナル** | 各 CLI の**ネイティブ TUI** をそのまま埋め込み：ドラッグ、8 方向リサイズ、端スナップ、ワンクリック整列、ペアで Claude + Codex を同時起動。出力レーダー、未読キュー、CLI 横断のアクションルーターも |
| **5 つのつなぎ方** | ⇄ 会議（円卓）· ⋈ 並列 · › 分業（順次リレー）· ⚡ 判定 · ⑂ コンテキストフォーク |
| **決定チェーン** | 画面フリーズ → 判定（return は人が押す）→ 封印 → プライベートチェックポイント（git ベースライン付き）→ 系譜ナビゲーションとドリフト検査。すべて明示操作、証拠は読み取り専用 |
| **ローカルファースト** | アカウント・テレメトリ・クラウドなし。画面スナップはプロセスメモリのみ、チェックポイントは `0700/0600` で保存、端末 PTY の内容は一切記録しない |
| **オープンな接続** | 行出力の CLI は `generic` manifest、ACP 対応 CLI は `acp` で接続——どちらもノーコード |

## はじめる

必要環境：macOS 14+ · Swift 5.9+ · Rust · Node.js

```bash
git clone https://github.com/shinteni/relay-workbench.git
cd relay-workbench
./scripts/package-macos-app.sh        # dist/Relay.app をビルド
ditto dist/Relay.app ~/Applications/  # インストールして起動
```

## これは何か

Relay は Codex CLI、Claude CLI、Grok CLI（generic manifest によるノーコード接続、セッション再開対応）、ローカルの Ollama、そして Claude と Codex に最終合意を出させる MIX エージェントを扱えます。ほかの CLI もアダプタープロトコルで接続可能：行出力の CLI は `generic` セクション、ACP（Agent Client Protocol）対応 CLI は `acp` セクション——いずれもコード不要です。リポジトリには [`xai-org/grok-build`](https://github.com/xai-org/grok-build)（grok CLI の上流、Apache-2.0）のスナップショットを CLI ランタイム・ACP・端末操作の実装参照として保持していますが、プロダクトコードはこれに依存しません。

> 機能の全カタログとバージョンごとの記録は[中国語 README](README.md) と [WORKLOG](WORKLOG.md) にあります。
