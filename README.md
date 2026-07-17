# Relay 串联器

面向 macOS 的本地多 CLI 智能体工作台。当前可直接调用 Codex CLI、Claude CLI，以及让 Claude 与 Codex 达成最终共识的 MIX 智能体；并可通过通用 Adapter 协议继续接入其他 CLI。Grok 暂不作为智能体参与任务；仓库保留 `xai-org/grok-build` 快照，作为 CLI runtime、ACP 和终端交互实现参考。

## 已实现

- 可双击运行的原生 SwiftUI GUI，保持 CLI 风格
- Codex CLI 与 Claude CLI 自动检测、版本显示和真实任务执行
- 内置原 `/mix` 共识运行时；MIX 只展示阶段状态和最终共识，不展示内部辩论
- MIX 可在 GUI 中选择 Codex 模型与 reasoning effort，并在同一会话中续聊
- 工作目录选择、新线程、取消、状态和有界输出历史
- 线程重命名、按标题/Agent/路径搜索，以及按工作目录自动项目分组
- 左侧状态中心可按 `ALL / ACTIVE / WAITING / FAILED / DONE` 筛选线程，并在每个 Agent 旁显示实时工作数
- 同一 Codex/Claude session 的多轮续聊
- Codex 支持 `DEFAULT` / `PLAN` 模式；任务需要审批或补充输入时在 GUI 的 `USER GATE` 中直接响应
- 任务正文、续聊正文和交互回答均通过 stdin 传输，不出现在本机进程参数中
- GUI 退出后任务由用户域 LaunchAgent 托管的独立 `relayd` 继续执行；重开 GUI 后恢复线程、输出和状态
- 线程、输出、session 和 Adapter 配置原子持久化；daemon 或 Mac 重启后仍可恢复
- 已结束线程可在确认后删除，运行中线程必须先取消
- 与具体 CLI 无关的 versioned NDJSON Adapter 协议
- manifest 驱动的 Adapter 发现、能力声明和运行时注册；新增 Adapter 不需要重启 daemon
- GUI 显示每个 Adapter 的 `READY`、`MISSING` 或 `INVALID` 健康状态与具体原因
- 私有 Unix socket、进程组取消、连接/任务/输出上限和 Adapter 路径校验

```text
Relay.app / relayctl
          │ Unix socket
        relayd
          │ versioned NDJSON
              CLI Adapters
       ┌──────────┼──────────┐
   Codex CLI  Claude CLI  MIX consensus
                            │
                    Claude CLI × Codex CLI
```

`relayd` 不依赖 GUI 进程。历史和自定义线程标题保存在 `~/Library/Application Support/Relay/tasks`；重启时，已完成线程原样恢复，执行中被中断的线程会标记为失败并保留可用的 CLI session，允许继续。

## 直接使用

双击：

```text
dist/Relay.app
```

1. 在左侧 `AGENTS` 中选择 Codex、Claude 或 MIX。
2. 在顶部设置 `cwd`，或点击 `CHOOSE`。
3. 选择 Codex 时，可使用 `DEFAULT` 直接执行，或使用 `PLAN` 让 Codex 在执行前向你提问。
4. 选择 MIX 时，可在紫色共识栏中设置 Codex 模型与 reasoning effort。
5. 在底部输入任务并回车。
6. 任务暂停等待审批或输入时，在输出区的 `USER GATE` 选择操作或填写答案；关闭 GUI 不会取消等待中的任务。
7. 运行中可点击 `CANCEL`；完成后底部输入框会沿同一 session 续聊。
8. 已结束线程可点击 `DELETE`，确认后删除本地历史与输出。
9. 点击 `NEW THREAD` 可从当前智能体开始新线程。
10. 放入新的 Adapter manifest 后点击刷新，GUI 会重新发现并注册，不会中断其他线程。
11. 选中线程后点击 `RENAME` 可修改显示标题；左侧搜索框可按标题、Agent 或 `cwd` 过滤。

App 会自动使用以下本机 CLI：

- Codex：优先 `/Applications/ChatGPT.app/Contents/Resources/codex`，然后检查常见本地路径
- Claude：优先 `~/.local/bin/claude`，然后检查 Homebrew 常见路径
- MIX：同时需要本机 Codex 与 Claude；Node.js 和共识运行时已打包进 `Relay.app`

首次在 `Documents`、`Desktop` 或 `Downloads` 中运行任务时，macOS 会请求对应文件夹访问权限；授权后，后台 daemon 才能在该项目目录中继续运行 CLI。正式分发应使用稳定的 Developer ID 签名，避免本地 ad-hoc 重签名使 macOS 重新确认权限。

## 开发运行

```bash
scripts/package-macos-app.sh
open dist/Relay.app
```

命令行闭环：

```bash
export CARGO_HOME="$PWD/.tooling/cargo"
export RUSTUP_HOME="$PWD/.tooling/rustup"
export CARGO_TARGET_DIR="$PWD/.tooling/target-relay"
export PATH="$CARGO_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"

cargo build --workspace
mkdir -p -m 700 "$PWD/.tooling/run" "$PWD/.tooling/run/tasks"

"$CARGO_TARGET_DIR/debug/relayd" \
  --socket "$PWD/.tooling/run/relay.sock" \
  --state-dir "$PWD/.tooling/run/tasks" \
  --adapter "codex=$CARGO_TARGET_DIR/debug/codex-adapter" \
  --adapter "claude=$CARGO_TARGET_DIR/debug/claude-adapter"
```

另开终端：

```bash
"$CARGO_TARGET_DIR/debug/relayctl" \
  --socket "$PWD/.tooling/run/relay.sock" ping

printf '%s' 'inspect this project' | \
  "$CARGO_TARGET_DIR/debug/relayctl" \
    --socket "$PWD/.tooling/run/relay.sock" \
    start --adapter codex --stdin --cwd "$PWD"

"$CARGO_TARGET_DIR/debug/relayctl" \
  --socket "$PWD/.tooling/run/relay.sock" list
```

Adapter 是受信任的本地插件。新 Adapter 只需从 stdin 读取 `AdapterRunRequest`，并在 stdout 按行输出 `AdapterEvent`。开发时仍可用 `--adapter ID=EXECUTABLE` 启动；GUI 则从 manifest 动态发现和注册。

## 接入其他 CLI

把 manifest 和实现 Relay NDJSON 协议的 Adapter 可执行文件放入：

```text
~/Library/Application Support/Relay/adapters/
```

manifest schema v1 示例：

```json
{
  "schema_version": 1,
  "id": "example",
  "name": "Example",
  "detail": "Example CLI",
  "adapter_executable": "example-adapter",
  "capabilities": ["session_resume"],
  "requirements": [
    {
      "name": "Example CLI",
      "environment": "RELAY_EXAMPLE_PATH",
      "candidates": ["~/.local/bin/example", "/opt/homebrew/bin/example"],
      "version_arguments": ["--version"]
    }
  ]
}
```

`adapter_executable` 和相对的 CLI candidate 以 manifest 所在目录为基准；`~/` 会展开到当前用户目录。所有 requirements 必须找到可执行文件，Adapter 才会显示为 `READY`。环境变量只注入对应 Adapter 进程，名称必须以 `RELAY_` 开头。当前能力名包括 `session_resume` 和 `interactive_input`；内置 Codex 还声明 `codex_modes`，内置 MIX 还声明 `mix_model_options`。

GUI 启动时和点击刷新时扫描内置 manifest 与用户目录。重复 ID、未知 schema、缺失文件和 daemon 安全校验失败都会在左侧显示原因，不会执行该 Adapter。

## 目录

- `crates/relay-protocol`：通用协议、任务快照和输出事件
- `crates/relayd`：常驻 daemon 和开发用 `relayctl`
- `adapters/cli-adapters`：Codex、Claude 和 MIX 真实 Adapter
- `adapters/manifests`：内置 Adapter manifest 与能力声明
- `adapters/mix-runtime`：把原 `/mix` 共识流程接入 Relay 会话的运行器
- `adapters/mock-adapter`：无模型生命周期测试 Adapter
- `apps/RelayGUI`：macOS SwiftUI GUI
- `scripts/package-macos-app.sh`：构建并组装 ad-hoc 签名的 `Relay.app`
- `upstream/grok-build`：固定上游快照

## 已验证基线

2026-07-18，Apple Silicon macOS：

- Rust workspace 的 55 项协议/daemon/Adapter 测试全部通过
- Swift 的 8 项 manifest、交互解码、搜索、状态筛选和项目分组测试全部通过
- MIX 包装层 3 项测试、原 `/mix` 运行时 64 项测试全部通过
- Swift release 构建通过
- `Relay.app` ad-hoc 签名和 `codesign --verify --deep --strict` 通过
- Codex CLI 真实首轮与 resume 通过
- Claude CLI 真实首轮与 resume 通过
- MIX 真实首轮与 resume 通过，任务输出只包含用户输入和最终共识
- GUI 发起 Codex 任务后立即退出，daemon 继续到 `completed`；重开后成功恢复线程和输出
- Codex Plan 提问在 GUI 显示 `USER GATE`；退出 GUI 后保持等待，重开选择答案并完成
- Codex 命令审批在 GUI 显示命令、理由和 `cwd`；拒绝后未执行命令并中止任务
- GUI `CANCEL` 可停止运行中的 Codex 命令，线程最终状态为 `canceled`
- GUI 首轮和续聊的多行输入均保留原始换行，`relayctl` 进程参数中不包含任务正文
- 完成线程跨 daemon 重启恢复通过；运行中断线程恢复为可续接状态并成功完成下一轮

## Grok Build 基线

- 上游：<https://github.com/xai-org/grok-build>
- 快照提交：`8adf9013a0929e5c7f1d4e849492d2387837a28d`
- 位置：`upstream/grok-build`

Grok Build 的 leader 与 Grok 认证、模型和升级逻辑耦合较深，因此本项目使用独立的通用 daemon，而不把 Grok 专用 shell 作为 Codex/Claude 的运行时依赖。后续接入 ACP-native CLI 时，可按 Adapter 评估复用 `xai-acp-lib`。
