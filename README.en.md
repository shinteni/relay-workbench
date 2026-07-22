<div align="center">

# `>` RELAY_ 串联器

**Local multi-CLI agent workbench for macOS**

Embed the real TUIs of Claude Code, Codex, Grok and Ollama side by side on one canvas —<br>
parallel answers · sequential relay chains · roundtable dialogues · structured verdicts · a private decision chain, all on your Mac.

**[简体中文](README.md)** · **English** · **[日本語](README.ja.md)**

**[Landing page ↗](https://shinteni.github.io/relay-workbench/)**

UI in 简体中文 / 日本語 / English · SwiftUI GUI + Rust daemon · Test baseline: Rust 113 + Swift 151

</div>

---

## Highlights

| | |
|---|---|
| **Real terminals** | Each CLI's **native TUI** is embedded, not imitated: drag, eight-way resize, edge snapping, one-click tiling, PAIR to open Claude + Codex together; output radar, review queue and a cross-CLI attention router |
| **Five ways to link** | ⇄ meeting (roundtable) · ⋈ parallel · › teamwork (sequential relay) · ⚡ verdict · ⑂ context fork |
| **Decision chain** | Freeze screens → judge (you press return) → seal → private checkpoint (with git baseline) → lineage navigation and drift checks; every step explicit, all evidence read-only |
| **Local first** | No account, no telemetry, no cloud; screen snapshots live in process memory only, checkpoints land on disk as `0700/0600`, embedded terminal PTY content is never recorded |
| **Open adapters** | Line-based CLIs plug in through a `generic` manifest, ACP speakers through `acp` — zero code either way |

## Quick start

Requirements: macOS 14+ · Swift 5.9+ · Rust · Node.js

```bash
git clone https://github.com/shinteni/relay-workbench.git
cd relay-workbench
./scripts/package-macos-app.sh        # build & package dist/Relay.app
ditto dist/Relay.app ~/Applications/  # install, then double-click
```

## What it is

Relay drives Codex CLI, Claude CLI, Grok CLI (attached zero-code via a generic manifest, resumable sessions included), local Ollama, and the MIX agent that pushes Claude and Codex to a final consensus. Any other CLI can join through the adapter protocol: line-output CLIs use the `generic` manifest section, ACP (Agent Client Protocol) speakers use `acp` — no code in either case. The repository keeps a snapshot of [`xai-org/grok-build`](https://github.com/xai-org/grok-build) (upstream of the grok CLI, Apache-2.0) as an implementation reference for CLI runtimes, ACP and terminal interaction — the product code does not depend on it.

> The full feature catalog and version-by-version log are maintained in the [Chinese README](README.md) and [WORKLOG](WORKLOG.md).
