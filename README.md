# Relay 串联器

面向 macOS 的本地多 CLI 智能体工作台。当前可直接调用 Codex CLI、Claude CLI，以及让 Claude 与 Codex 达成最终共识的 MIX 智能体；并可通过通用 Adapter 协议继续接入其他 CLI。Grok 暂不作为智能体参与任务；仓库保留 `xai-org/grok-build` 快照，作为 CLI runtime、ACP 和终端交互实现参考。

## 已实现

- 可双击运行的原生 SwiftUI GUI，保持 CLI 风格
- 独立设置窗口（齿轮或 `⌘,`）：可即时切换简体中文/日语，并设置默认工作目录、Codex 模式及 MIX 模型/推理强度
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
- 关闭主窗口后 Relay 保留菜单栏状态入口和常驻 watcher；可查看 daemon、ACTIVE/WAITING 数量并直接重开后台任务
- App 更新或移动位置时会核对内置 daemon 版本和 LaunchAgent 可执行路径；无活动任务自动替换，有活动任务则保留旧进程避免中断
- GUI 通过单个常驻 `relayctl watch` 同步任务变化，空闲时不再每秒创建新的子进程；watcher 绑定 GUI 父进程，GUI 退出后自动回收，意外退出或断线后也会安全收敛
- 线程、输出、session 和 Adapter 配置原子持久化；daemon 或 Mac 重启后仍可恢复
- 已结束线程可在确认后删除，运行中线程必须先取消
- 与具体 CLI 无关的 versioned NDJSON Adapter 协议
- Rust daemon/Adapter 与 Swift GUI 共用同一 `protocol-version.txt`；socket、LaunchAgent、握手和界面版本均从它派生
- manifest 驱动的 Adapter 发现、能力声明和运行时注册；新增 Adapter 不需要重启 daemon
- GUI 删除用户 Adapter 时会同步撤销 daemon 注册；已运行任务不受影响，新任务立即停用
- 无代码接入：manifest 中声明 `generic` 段即可串联任意行式 CLI，无需编写 Adapter 程序；运行语义由内置 Rust validator 在导入和注册前统一判定
- Adapter 管理面板可直接 `ADD CLI`：选择可执行文件、逐行填写参数后自动生成本地 manifest 并注册；这类简单 CLI 可继续 `EDIT` 名称、路径和参数
- COMPARE 并行对比：同一任务同时发给多个智能体，输出按列并排对比，成员可聚焦为普通线程继续
- CHAIN 顺序接力：按点击顺序组合最多四个智能体；完整计划由 daemon 持久化并逐步推进，链路视图显示每一步状态与输出
- 终态线程可在输入框使用 `@agent 指令`，把对话上下文交接给另一个智能体继续处理
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

正式使用前，把构建产物放到稳定且不受 `Documents` 目录保护的位置：

```bash
mkdir -p "$HOME/Applications"
ditto dist/Relay.app "$HOME/Applications/Relay.app"
open "$HOME/Applications/Relay.app"
```

首次访问 `Documents`、桌面或下载等受保护目录时，macOS 会以 Relay 的名义弹出文件夹访问请求；请根据实际需要手动允许。若要让后台 daemon 无提示访问多个受保护位置，可自行在 `系统设置 → 隐私与安全性 → 完全磁盘访问权限` 中启用 Relay 后重启 App，但普通目录和未受保护项目不需要该权限。

1. 在左侧 `AGENTS` 中选择 Codex、Claude 或 MIX。
2. 点击齿轮或按 `⌘,` 打开设置；在 `通用` 中切换简体中文/日语与默认工作目录，在 `智能体` 中设置 Codex 和 MIX 的新线程默认值。设置即时生效并自动保存。
3. 在顶部设置 `cwd`，或点击 `CHOOSE`。
4. 选择 Codex 时，可使用 `DEFAULT` 直接执行，或使用 `PLAN` 让 Codex 在执行前向你提问。
5. 选择 MIX 时，可在紫色共识栏中设置 Codex 模型与 reasoning effort。
6. 在底部输入任务并回车。
7. 任务暂停等待审批或输入时，在输出区的 `USER GATE` 选择操作或填写答案；关闭 GUI 不会取消等待中的任务。
8. 运行中可点击 `CANCEL`；完成后底部输入框会沿同一 session 续聊。
9. 已结束线程可点击 `DELETE`，确认后删除本地历史与输出。
10. 点击 `NEW THREAD` 可从当前智能体开始新线程。
11. 点击 `COMPARE` 进入对比模式：勾选至少两个智能体后输入任务，同一提示词并行发送；对比视图中每列可 `FOCUS` 聚焦为普通线程续聊，`‹ BACK TO COMPARE` 返回对比。
12. 点击 `CHAIN`，依次点击智能体组成执行路由，可选填步骤间指令；提交后 Relay 会把每一步的最终回答传给下一步。关闭 GUI 后整个剩余链路仍由 daemon 继续执行，重新打开可查看各步结果。
13. 打开已结束线程，在输入框键入 `@claude 检查这个结果` 等 `@agent 指令`，可把当前对话交给另一个智能体。
14. 点击 `MANAGE` → `ADD CLI`，填写 ID/名称、选择 CLI 可执行文件，并按每行一个参数填写可选参数；Relay 会自动生成 manifest 并注册这个无状态行式 CLI。
15. 在 `MANAGE` 中点击简单 CLI 旁的 `EDIT`，可修改显示名、可执行路径和参数；ID 保持不变，新任务立即使用修改后的配置。
16. 高级 session/jsonl Adapter 仍可通过 `IMPORT` 导入 manifest；GUI 会重新发现并注册，不会中断其他线程。
17. 关闭主窗口后，点击 macOS 菜单栏的 Relay 终端图标，可查看 daemon 状态、活动/等待任务，并重新打开指定任务。`Quit Relay UI` 只退出界面，daemon 仍继续任务。
18. 选中线程后点击 `RENAME` 可修改显示标题；左侧搜索框可按标题、Agent 或 `cwd` 过滤。

App 会自动使用以下本机 CLI：

- Codex：优先 `/Applications/ChatGPT.app/Contents/Resources/codex`，然后检查常见本地路径
- Claude：优先 `~/.local/bin/claude`，然后检查 Homebrew 常见路径
- MIX：同时需要本机 Codex 与 Claude；Node.js 和共识运行时已打包进 `Relay.app`

正式分发应使用稳定的 Developer ID 签名，避免本地 ad-hoc 重签名使 macOS 重新确认权限。不要把日常运行的 App 留在 `Documents` 内；`dist/Relay.app` 只作为构建产物。

## 开发运行

```bash
scripts/package-macos-app.sh
ditto dist/Relay.app "$HOME/Applications/Relay.app"
open "$HOME/Applications/Relay.app"
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

MIX 一方源码、锁文件和 64 项测试位于 `adapters/mix-runtime/vendor`。组装脚本按锁文件安装依赖，并从最终 App 排除 Codex SDK 自带的平台 CLI；MIX 包装层测试需要指向组装后的运行时目录：

```bash
scripts/prepare-mix-runtime.sh "$PWD/.tooling/mix-runtime"
npm test --prefix adapters/mix-runtime/vendor
RELAY_MIX_RUNTIME_ROOT="$PWD/.tooling/mix-runtime" \
  node --test adapters/mix-runtime/relay-mix.test.mjs
```

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

### 无代码接入行式 CLI

省略 `adapter_executable`，改为声明 `generic` 段，即可用内置 `generic-adapter` 直接串联任意按行输出的 CLI：

```json
{
  "schema_version": 1,
  "id": "example",
  "name": "Example",
  "detail": "Example CLI",
  "capabilities": ["session_resume"],
  "generic": {
    "command": "RELAY_EXAMPLE_PATH",
    "arguments": ["--quiet"],
    "new_session_arguments": ["--session-id", "{session}"],
    "resume_arguments": ["--resume", "{session}"]
  },
  "requirements": [
    {
      "name": "Example CLI",
      "environment": "RELAY_EXAMPLE_PATH",
      "candidates": ["~/.local/bin/example"],
      "version_arguments": ["--version"]
    }
  ]
}
```

约定：

- `command` 必须等于某个 requirement 的 `environment`，该 requirement 解析出的路径就是要执行的 CLI
- 任务正文始终通过 stdin 传给 CLI；stdout 每行成为 assistant 输出，stderr 每行成为 system 输出，退出码 0 记为完成，否则记为失败并摘录 stderr
- 参数支持 `{session}` 与 `{cwd}` 占位符；首轮附加 `new_session_arguments`，续聊附加 `resume_arguments`
- 输出 JSON 流的 CLI 可声明 `"output": "jsonl"` 并给出 `text_paths`（1–8 个点路径，支持数组下标，如 `message.content.0.text`）；每行 JSON 按路径顺序取第一个字符串作为 assistant 输出，其余行记为 system
- manifest 顶层可声明 `options`（`key`/`label`/`values`/`default`，至多 8 个）：GUI 自动渲染下拉选择器并随任务以 `--option key=value` 传递，选择按 Adapter 持久化；generic 参数模板用 `{option:key}` 引用（示例 `examples/ollama.json` 由此获得模型选择器）
- 声明了 `resume_arguments` 时，session ID 采用任务 ID 并跨轮传递（capabilities 应包含 `session_resume`）；未声明时续聊按无状态方式重新执行
- GUI 注册时自动注入 `RELAY_GENERIC_SPEC`（指向该 manifest 的绝对路径）；开发时也可手动注册：

```bash
"$CARGO_TARGET_DIR/debug/relayctl" --socket "$PWD/.tooling/run/relay.sock" \
  register-adapter --id echo \
  --executable "$CARGO_TARGET_DIR/debug/generic-adapter" \
  --environment "RELAY_GENERIC_SPEC=$PWD/adapters/manifests/examples/echo.json"
```

`adapters/manifests/examples/echo.json` 是可直接使用的最小示例。

generic manifest 的运行时规则只有一个权威实现：

```bash
"$CARGO_TARGET_DIR/debug/generic-adapter" validate \
  --spec "$PWD/adapters/manifests/examples/echo.json"
```

GUI 在 `IMPORT`、`ADD CLI`、`EDIT` 和 daemon 注册前调用同一入口；Swift 只处理界面字段、文件路径和本机 requirement 解析。validator 只读取 manifest，不会启动目标 CLI。

GUI 启动时和点击刷新时扫描内置 manifest 与用户目录。重复 ID、未知 schema、缺失文件和 daemon 安全校验失败都会在左侧显示原因，不会执行该 Adapter。

## 目录

- `crates/relay-protocol`：通用协议、任务快照和输出事件
- `crates/relayd`：常驻 daemon 和开发用 `relayctl`
- `adapters/cli-adapters`：Codex、Claude 和 MIX 真实 Adapter
- `adapters/manifests`：内置 Adapter manifest 与能力声明
- `adapters/mix-runtime`：把原 `/mix` 共识流程接入 Relay 会话的运行器，以及可独立构建的 vendored 运行时
- `adapters/mock-adapter`：无模型生命周期测试 Adapter
- `apps/RelayGUI`：macOS SwiftUI GUI
- `scripts/package-macos-app.sh`：构建并组装 ad-hoc 签名的 `Relay.app`
- `upstream/grok-build`：固定上游快照

## 已验证基线

2026-07-18，Apple Silicon macOS：

- Rust workspace 的 85 项协议/daemon/Adapter 测试全部通过（含 daemon CHAIN 调度、单调更新时间、watcher 父进程守卫与 generic-adapter 20 项）
- Swift 的 30 项 manifest、自定义 CLI 生成/编辑识别、共享协议版本派生、LaunchAgent 路径漂移判定、generic validator 边界、交互解码、HANDOFF、命令管道、设置语言持久化、搜索、状态筛选和项目分组测试全部通过
- generic-adapter 端到端通过：echo 示例完成多行输出；session 示例首轮注入 `--session-id`、续聊注入 `--resume` 与 `{cwd}`；失败示例记录 stderr 摘要并标记 `failed`
- 打包版 GUI 导入缺少 jsonl `text_paths` 的 manifest 时直接显示 Rust validator 错误且不复制文件；同一文件手工放入用户目录后显示 `INVALID`，daemon 不注册该 Adapter
- MIX 包装层 3 项测试、vendored `/mix` 运行时 64 项测试全部通过；在系统沙箱明确禁止读取原同级连接器目录时仍可独立组装并通过 64+3 项
- Swift release 构建通过
- `Relay.app` ad-hoc 签名和 `codesign --verify --deep --strict` 通过
- Codex CLI 真实首轮与 resume 通过
- Claude CLI 真实首轮与 resume 通过
- 安装包内 MIX 运行时和 GUI daemon 链路均真实完成 Claude → Codex → 辩论 → finalize 首轮闭环，分别返回精确最终共识；首次允许 `Documents` 文件夹访问后，GUI 在项目目录中返回 `MIX_GUI_DOCUMENTS_OK`
- GUI 发起 Codex 任务后立即退出，daemon 继续到 `completed`；重开后成功恢复线程和输出
- GUI 发起 Echo A → Echo B CHAIN 后在第一步运行时退出；无 GUI 进程期间 daemon 自动完成两步，重开后恢复 `2/2` 链路视图
- GUI 空闲时仅保持一个 `relayctl watch` 子进程；关闭主窗口后 watcher 继续运行，真正退出 GUI 后 watcher 被回收且 daemon 继续在线
- 打包版 GUI 运行 12 秒 `/bin/sleep` 任务后关闭主窗口；GUI 进程和同一 watcher 均存活，无窗口时任务自动转为 `completed`，重开后恢复完成状态
- 共享协议资源装入打包 App 后从全新 PID 冷启通过；GUI 显示/`ping` 均为 v8，关窗后同一 GUI/watcher 存活，重开复用唯一 AppKit 主窗口
- 打包版 GUI 从 `ADD CLI` 创建 `/bin/cat` Adapter，daemon 立即注册为 READY，提示词原样成为 assistant 输出；线程与 Adapter 删除后注册和文件均清理
- 打包版 GUI 将同一测试 Adapter 从 `/bin/cat` 编辑为 `/usr/bin/tr a-z A-Z`，新任务返回 `RELAY_EDIT_E2E`；高级 generic manifest 不会暴露简化编辑入口
- 同版本 App 临时搬移实测：有运行任务时 daemon 保留原路径与 PID；任务终态后重开才切换至新 bundle，再打开正式 App 后成功切回
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
