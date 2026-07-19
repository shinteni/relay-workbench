# Relay 串联器

面向 macOS 的本地多 CLI 智能体工作台。当前可直接调用 Codex CLI、Claude CLI、Grok CLI（经 generic manifest 零代码接入，含会话续聊）、本地 Ollama，以及让 Claude 与 Codex 达成最终共识的 MIX 智能体；并可通过通用 Adapter 协议继续接入其他 CLI。仓库保留 `xai-org/grok-build` 快照（grok CLI 的上游项目），作为 CLI runtime、ACP 和终端交互实现参考——产品代码不依赖它。

## 已实现

### 工作台（当前形态：自由浮动窗口，v0.33 起）

- 可双击运行的原生 SwiftUI GUI，保持 CLI 风格；右侧工作区是一块自由浮动窗口画布
- 点击左侧智能体，把它的**原生 CLI TUI**（Claude Code / Codex / Ollama / 任意 generic CLI）作为独立窗口嵌入：像普通应用窗口一样拖动、八向缩放、叠放置顶、贴顶、双击或 `⤢` 最大化/还原，最多 4 个终端
- **项目坞**：主界面始终显示当前项目，一处切换最近 6 个本地目录或选择新文件夹；`双开` 一键打开或复用该项目的 Claude + Codex，并在两者独占工作区时自动平铺；之后新开的终端、对话、同时发送与顺序串联统一使用该项目，已打开窗口保持原 cwd
- **项目上下文护栏**：每个终端的浮动标题栏和侧栏行永久显示创建时的项目名，悬停可查看完整 cwd；即使 Claude/Codex TUI 动态改写窗口标题，跨项目窗口也不会失去目录身份
- **CLI 输出雷达**：Relay 直接观察各嵌入式 PTY 是否正在产生字节，不解析或保存内容；活动终端会在标题栏与侧栏亮起波形，“窗口”区汇总数量并可一键跳到最近输出的 CLI
- **待查看输出队列**：终端在后台或非聚焦状态产生输出后会留下去重标记；`待看 N` 按最早待看顺序逐个带回对应 CLI，真正聚焦后才清除，持续刷屏不会制造虚假计数
- **跨 CLI 行动路由器**：侧栏 `下一项 N` 把待核对提示词与未读输出汇成一个用户驱动的入口；点击或按 `⌥⌘J` 时严格先带回未核对提示词，再按最早顺序查看未读输出，最后才追踪最新活跃输出，不会自动抢走焦点
- **可逆行动跳转**：行动路由跨终端后签发一张仅存在于当前进程的返回票；侧栏 `返回` 或 `⌥⌘K` 一步回到刚才的 CLI，若跳转时自动展开了提示词核对，返回会同时收起面板但完整保留进度。来源重新聚焦或关闭后返回票立即失效
- **焦点电路**：跨 CLI 跳转时，画布会从来源标题栏边缘向目标窗口短暂绘制一条 agent 强调色电路并点亮目标锚点；返回时线路反向播放，约 1.1 秒后自动消失且不拦截任何操作。系统开启减弱动效时只静态闪示目标，不播放路径
- **本地上下文分叉**：从任一终端标题栏明确截取当时的活动画面，在底部分叉轨道中编辑快照、填写继续指令并选择一个或多个其他原生 CLI；最多保留 UTF-8 安全的末尾 48 KiB，只存在于当前 GUI 内存，不进剪贴板或磁盘。Relay 仍只用 bracketed paste 填入、不按 Return，随后按实际填入顺序进入逐目标核对并可一键返回来源
- **结果汇流**：完成多目标逐窗核对后，可由用户明确点击一次，把各目标 CLI 当时的可见画面冻结为横向对照卡片；快照不会随终端继续输出而暗中变化，可逐卡返回实时 CLI，也可明确重新截取或退回原核对回路。内容只存在于当前 GUI 内存，不进剪贴板、不写磁盘，关闭全部终端即清除
- **结果裁决**：在结果汇流面板中填写裁决指令，并明确选择一个已停在输入框的真实 CLI；Relay 会把所有冻结画面按原顺序组成一个本地载荷，先完整保留较短来源并把未用预算回流给较长来源，仅在总量确实超过 64 KiB 时才为长来源公平保留 UTF-8 安全尾部，再用 bracketed paste 只填入目标、不按 Return。成功后直接进入既有单目标核对、返回票与焦点电路；目标未就绪或指令无效时冻结结果和输入都不会消失
- **裁决载荷预检**：裁决指令一旦有效，面板会在填入前显示实际载荷的精确 UTF-8 字节数，以及每个冻结来源的保留 / 原始字节和“完整 / 已截尾”状态；投递与预检共用同一个本地计划，不用不可靠的跨模型 token 估算，也不新增读取或持久化
- **裁决血缘回看**：裁决填入后，单目标核对层保留一张仅限当前内存的回执，显示冻结来源数与实际 payload 字节；可随时打开本次裁决实际使用的只读冻结画面，再原路返回裁决目标核对而不丢进度。结束核对或关闭全部终端即清除，不重新截取、不写磁盘
- **来源漂移检查**：在只读裁决来源中显式点击一次，即把每张冻结卡与对应实时 CLI 的当前可见画面做精确本地比较，标出“未变化 / 已变化 / CLI 已关闭”；检查不在后台运行、不改写冻结内容，也不保存结果，返回后可按需重新检查
- **裁决结果封存**：完成裁决目标核对后，只有用户明确点击 `封存结果` 才会冻结该 CLI 当时的可见画面，并与原冻结来源及实际 payload 计划组成一条只读的本地决策链。封存后继续出现的终端输出不会覆盖记录；可返回同一核对进度并再次打开封存结果，`新提示词`、结束核对或关闭全部终端会清除整条链。来源、精确 UTF-8 字节与裁决结果同屏展示，只存在于当前 GUI 内存，不进剪贴板、不写磁盘
- **私有决策检查点与决策库**：封存后仍默认只留内存；只有再次明确点击 `保存私有检查点` 才会把完整的冻结来源、精确 payload 和裁决结果原子写入 `Application Support/Relay/decisions`。目录权限为 `0700`、文件为 `0600`；冷启动后即使没有终端窗口，也可从侧栏决策库恢复只读链路。损坏或不兼容文件会被隔离计数，不阻断其他记录；删除前明确确认并移入 macOS 废纸篓，不直接永久删除
- **检查点重裁决与派生血缘**：任一已保存检查点都可显式重新打开其冻结证据，选择当前任意已就绪 CLI 生成新裁决；父 JSON 始终保持只读且不会被覆盖。新结果仍须手动 Return、逐窗核对、显式封存和显式保存，保存后记录父检查点 ID；决策库标出派生记录，并可从派生详情跳回仍存在的父检查点。填入前取消会原路返回父记录，旧版无父 ID 的检查点继续兼容
- **父子决策差异审阅**：派生检查点且父记录仍存在时，可在同一详情中打开只读双栏差异，按原始行号确定性标出新增、删除与未变行，并汇总变化数量；比较只读取两份已保存结果，不做语义优劣判断，也不修改 JSON。为避免超大记录拖慢界面，每侧只比较 UTF-8 安全的末尾 64 KiB / 300 行并明确提示更早内容已省略；可原位返回派生详情，父记录缺失时入口自动消失
- **多代决策血缘导航**：已保存检查点存在祖先或派生记录时，详情顶部按根节点到当前代展示只读血缘，并列出可点击的直接派生子节点；可在任意现存祖先与子节点间原位往返，不写盘、不选择“最佳分支”。缺失父节点、循环引用或超过 32 代时会明确封住边界，普通单独检查点不增加额外导航层
- **跨分支决策比较**：当前检查点可从血缘轨道选择同一连通家族中的任意现存节点作为参考，在原位只读差异中比较祖先、子孙或兄弟分支；直接父子仍保留一键入口。家族遍历不跨越缺失父记录，循环安全且最多提供 64 个候选，超限明确提示；比较不调用 CLI、不修改文件，也不判断哪个分支更优
- **私有决策库本地搜索**：决策库可用多个关键词同时搜索来源/裁决者、项目、冻结证据、最终结果与 checkpoint ID；匹配忽略大小写、全半角和重音差异，只扫描已加载内存，不建索引、不调用 CLI。标题显示“匹配数 / 总数”，无匹配与空库分开提示；打开结果再返回会保留查询，显式关闭决策库才清空
- **不可变证据旁的私有标签**：每份已保存检查点可添加标题、最多 8 个标签并置顶；标签与置顶状态单独原子写入 `decisions/annotations`，不会改写冻结证据 JSON。决策库用标题作为首要识别信息、显示紧凑标签轨道并把置顶项排在最前；多词搜索同时覆盖标题与标签。编辑、排序和收起采用可中断的轻量弹簧过渡，系统开启减弱动效时退化为静态/淡入淡出；标签文件同为 `0600`，坏文件独立隔离，删除检查点时两者一起进入废纸篓
- **决策到行动桥**：已保存检查点不必重新裁决即可继续工作；在详情中明确点击 `从此决策继续`，可填写一条可选后续指令并选择一个已停在输入框的实时 CLI。Relay 会把检查点 ID、保存时间、私有标题/标签、裁决来源和封存结果组成一次性本地决策简报，填入前显示精确 UTF-8 字节及完整/截尾状态，超限时只保留结果的 UTF-8 安全尾部。简报仅留内存、只用 bracketed paste 填入、不按 Return，随后进入单目标核对；可返回原检查点，终端中已填文字保持不动。该路径继续执行既有决策，不会重新发送冻结证据或暗中创建派生检查点
- **决策行动回执**：决策简报填入后，只有检测到用户亲自按下 Return 才会出现 `冻结行动回执`；再次明确点击时，Relay 把准确的已填简报、编辑/Return 事实与该时刻 CLI 当前可见画面冻结成内存回执，不发送按键，也不把画面解释为“任务完成”或“执行成功”。回执用“封存决策 → 用户 Return → 当前画面”因果轨展示，可原路返回 CLI 核对且保持回执与终端状态；只有再点 `保存私有回执` 才原子写入 `decisions/action-receipts`（目录 `0700`、文件 `0600`）。重启后从对应检查点读取，父决策 JSON 保持逐字节不变；损坏、孤立或超限回执独立拒绝，删除父检查点时回执一起移入废纸篓
- **行动恢复桥**：已保存行动回执不再是只读终点；可在回执内展开“冻结画面 → 精确字节 → 实时 CLI”恢复电路，填写可选后续指令并明确选择一个已停在输入框的 CLI。Relay 会把回执 ID、检查点来源、准确的原已填简报与冻结画面组成最多 64 KiB 的一次性恢复载荷；两段证据都过长时分别保留 UTF-8 安全尾部并显示准确字节。载荷只存在当前 GUI 内存，只用 bracketed paste 填入、不按 Return、不改写原回执，也不把冻结画面解释为成功；填入后进入既有单目标核对，可原路返回回执且终端文字保持不动
- **恢复变化回执**：行动恢复由用户亲自按下 Return 后，可显式截取同一 CLI 的新可见画面，并与原行动回执中的冻结画面做确定性逐行对齐；双栏接缝标出新增、消失和未变行，显示准确 UTF-8 字节，不调用模型也不判断任务是否成功。变化先留在当前 GUI 内存，可原路返回恢复核对；只有再次点击保存才写入独立的 `decisions/recovery-observations` 私有文件（目录 `0700`、文件 `0600`），并链接 checkpoint 与原 action receipt，二者均不改写。冷启动可从父回执重开全部变化；损坏、孤立或超限记录独立隔离，删除父检查点时一起移入废纸篓
- **恢复变化接力**：已私有保存的恢复变化可继续交给一个明确选择、已停在输入框的实时 CLI。Relay 确定性携带 checkpoint、action receipt、recovery observation 三段 ID、Return/编辑事实、`+ / − / =` 摘要以及冻结与恢复两份画面；双方共享最多 64 KiB 的 UTF-8 安全预算，较短一侧的未用字节会回流给较长一侧，填入前显示精确载荷与各自保留字节。该路径不写新文件、不改父证据、不调用模型，只用 bracketed paste 填入且不按 Return；随后进入独立核对，可原路返回变化回执，关闭最后一个终端也不会留下死路
- **恢复变化见证**：变化接力只在检测到用户亲自按下 Return 后允许截取第二个 CLI 的当前可见画面，并把实际填入的完整接力载荷、两份上游画面的保留 / 原始字节、三层父 ID、编辑 / Return 事实与见证画面组成独立私有记录。用户须明确标注“支持变化 / 发现问题 / 无法判断”后才能保存；Relay 只保存人的判断，不调用模型、不自动评价结果。记录写入 `decisions/recovery-witnesses`（目录 `0700`、文件 `0600`），三份父证据均保持逐字节不变；冷启动可原样重开，删除父检查点时一起移入废纸篓
- **恢复见证对照**：同一恢复变化下保存至少两份见证后，用户可显式为左右两侧各选一份记录。双端证据秤同屏显示两个真实 CLI 目标、人工标注、接力 / 画面字节，并只作确定性事实判定：准确 handoff payload 是否逐字节相同、人工标注是否分歧。两份见证画面用现有有界逐行差异并排，每侧最多 64 KiB / 300 行且明确提示截尾；对照只存在当前内存，不写新文件、不修改见证，Relay 不选“更好”的结果
- **见证对照接力**：左右见证选定后，可把两份准确 handoff payload 与两份见证画面组成一个确定性对照包，再显式选择一台已停在输入框的实时 CLI。四份来源共享 64 KiB UTF-8 安全预算，短来源未用字节会平均回流给其余长来源；填入前的四束证据汇聚视图显示每份保留 / 原始字节与最终包大小。Relay 只用 bracketed paste 填入且不按 Return；用户亲自执行后，新 CLI 的可见结果可沿原 checkpoint / action receipt / recovery observation 回收成第三份见证，再次对照时旧证据均保持不变
- **提示词暂存台与可恢复核对回路**：一次写好提示词，手动确认并选择多个停在输入框的原生 CLI，只把内容安全填入而不按 Return；投递后正文立即从 Relay 清除，底部回路按顺序聚焦每个目标，并以不保留输入内容的本地计数信号提示“已编辑 / 检测到 Return / 已重启”，仍须逐窗明确标记已检查；临时收起 HUD 后侧栏保留剩余数量，重新打开可原位续接，只有明确结束核对或关闭全部终端才清空；bracketed paste 是必要门禁，草稿与输入内容都不进剪贴板、不持久化
- **CLI 桌面记忆**：自动记住打开的终端、各自工作目录、层叠顺序和空间布局；冷启动后先显示布局缩略图，由用户一键恢复或明确忘记，不会擅自启动 CLI
- **智能体相互对话**（`⇄ 对话` 窗口）：选定两个智能体与主题，Relay 引擎驱动双方多轮交谈——各自保持独立会话记忆（无会话 CLI 自动降级为带上下文重问），转录实时滚动，可随时停止、完成后可加轮；最多 2 个对话窗
- **同时发送 / 顺序串联**：同一提示词并行交给 2–4 个智能体对照，或让 2–4 个步骤在 daemon 中按顺序接力，关闭 GUI 后串联仍会继续
- **统一工具审批**：对话、对比、串联和快速条任务的 `USER GATE` 会自动汇总至单一审批窗，处理后原流程继续
- `平铺` 一键把终端、对话、对比、串联和审批窗排成无重叠网格
- 独立设置窗口（齿轮或 `⌘,`）：简体中文/日语即时切换、默认工作目录、Codex 模式及 MIX 模型/推理强度
- `⌥Space` 全局快速输入条：不进主窗口直接给任意智能体派后台任务
- 后台任务完成/失败/等待时发送 macOS 系统通知；菜单栏常驻状态入口（daemon 状态、ACTIVE/WAITING 计数、重开主窗口）
- 声明式选项栏：manifest `options`（含 `codex_models` / `claude_models` 动态取值源，Claude 模型列表直接从本机 CLI 二进制扫描）自动渲染模型/推理强度选择器
- Adapter 管理面板：`IMPORT` 校验导入、`ADD CLI` 向导生成 manifest、简单 CLI 可 `EDIT`、用户 Adapter 可删除并同步注销 daemon 注册；侧栏实时显示每个 Adapter 的 `READY / MISSING / INVALID` 健康状态与原因

### daemon 与协议层

- GUI 退出后任务由用户域 LaunchAgent 托管的独立 `relayd` 继续执行；重开 GUI 后恢复状态
- 任务正文、续聊正文和交互回答均通过 stdin 传输，不出现在本机进程参数中
- App 更新或移动位置时核对内置 daemon 版本和 LaunchAgent 可执行路径；无活动任务自动替换，有活动任务保留旧进程避免中断
- GUI 通过单个常驻 `relayctl watch` 同步任务变化（绑定 GUI 父进程，退出自动回收）
- 线程、输出、session 和 Adapter 配置原子持久化；daemon 或 Mac 重启后仍可恢复
- 与具体 CLI 无关的 versioned NDJSON Adapter 协议；Rust 与 Swift 共用同一 `protocol-version.txt` 派生 socket、LaunchAgent、握手和界面版本
- manifest 驱动的 Adapter 发现、能力声明和运行时注册；新增 Adapter 不需要重启 daemon
- 无代码接入：manifest 声明 `generic` 段即可串联任意行式 CLI；运行语义由内置 Rust validator（`generic-adapter validate`）统一判定
- 内置 MIX 共识运行时（vendored，独立于外部项目构建）；同一会话可续聊
- 私有 Unix socket、进程组取消、连接/任务/输出上限和 Adapter 路径校验
- COMPARE 并行对比、CHAIN 顺序接力（daemon 持久化推进）、`USER GATE` 审批均已按浮动窗口形态重新接入 GUI；`@agent` 转交仍保留在结构化任务流代码层

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

1. 在侧栏顶部的项目坞核对当前项目；用右侧切换按钮选择最近项目或新文件夹，或点 `双开` 一次打开当前项目的 Claude + Codex。项目切换只影响之后新开的窗口。
2. 点击齿轮或按 `⌘,` 打开设置；在 `通用` 中选择界面语言和默认工作目录，在 `智能体` 中设置模型与推理强度。
3. 点击左侧智能体行，右侧会打开它的原生 CLI；拖动标题栏移动，拖动边缘缩放，双击标题栏最大化/还原。
4. Relay 会随窗口打开、移动、缩放与平铺自动更新 CLI 桌面记忆。重新启动后，在空工作区核对缩略图，再选择 `恢复桌面` 或 `忘记`。
5. 使用左侧 `串联` 区的 `对话 / 对比 / 接力` 打开对应编排窗口；窗口内选择智能体、输入主题或任务后开始。
6. 任务请求工具权限或补充输入时，`审批` 窗会自动打开；也可从左侧手动打开查看。
7. 工作区有多个窗口时，点击 `平铺` 一键整理；终端实时输出时标题栏和侧栏会亮起波形，离开该终端后产生的输出会沉淀为 `◆`。侧栏 `下一项 N` 或 `⌥⌘J` 会先返回未核对提示词，再按最早顺序逐个返回有未读输出的 CLI；没有待办时才跳到最新活跃输出。跨终端跳转后可点 `返回` 或按 `⌥⌘K` 回到来源 CLI。左侧窗口行可单击聚焦、双击最大化，关闭按钮在悬停时显示。
8. 要把一个 CLI 的当前画面交给其他 CLI 继续，点击来源终端标题栏的分叉图标；在底部面板编辑画面快照、填写下一步指令，逐个确认目标 CLI 已停在输入框后选择一个或多个目标，再点击 `填入 N 个目标 · 不执行`。快照只在打开面板时截取并停留于内存，关闭面板立即清除；填入后会自动按窗口顺序逐个核对，并先点亮来源 → 第一个目标的焦点电路。
9. 有运行中的原生终端时，点击“窗口”旁的投递图标打开提示词暂存台；先逐窗确认 CLI 已停在输入框，再手动勾选目标并点击 `填入 N`。Relay 会清除暂存正文并自动聚焦第一个目标；目标芯片会以铅笔或 Return 标记反馈填入后的本地输入动作，但 Relay 不读取或保存输入内容，也不会代你按 Return。检查终端输入行后点击 `已检查 · 下一窗`；中途可收起 HUD，侧栏投递入口会显示剩余数，点击后从同一目标继续。全部核对后可点 `汇流当前画面`，把至少两个仍打开的目标画面冻结在同一横向面板中；之后可逐卡查看实时 CLI、明确 `重新截取`，或 `返回核对`。要让另一个 CLI 综合这些结果，点 `裁决这些结果`，填写裁决指令并选择一个安全粘贴已就绪的目标，再点 `填入裁决目标 · 不执行`；所有冻结结果会一次性填入并进入新的单目标核对。确认裁决 CLI 的可见结果已经完成后，可点 `封存结果` 查看“冻结来源 → 精确载荷 → 裁决结果”决策链；返回核对后可用 `查看封存结果` 原样重开。若要跨重启保留，在决策面板明确点击 `保存私有检查点`；之后可在侧栏 `决策` 打开只读记录、为检查点添加独立的标题/标签并置顶、用搜索栏按标题/标签/智能体/项目/证据/结果/ID 过滤、从检查点重新裁决，或经确认移入废纸篓。要把已确认结果带回日常实现，点 `从此决策继续`，核对精确简报字节、选择一个输入就绪 CLI，再点 `填入目标 · 不执行`；完成核对前可用 `返回决策` 原路回到检查点，已填内容不会被撤回。派生检查点会显示重裁决血缘，并在父记录仍存在时提供 `对比结果` 与 `查看父检查点`；存在多代或分支时，可直接点击详情顶部血缘中的祖先或子节点原位切换，也可用 `比较血缘节点` 选择同一家族的其他分支作为参考。每一代仍须独立显式保存。`结束核对` 只清除核对元数据，终端中已经填入的正文不会被改动。
10. 在任意应用中按 `⌥Space` 呼出全局快速条，可不切换窗口直接给后台 daemon 派任务。
11. 通过 `MANAGE` 导入 manifest，或使用 `ADD CLI` 向导把其他行式 CLI 接入 Relay；简单 CLI 可继续 `EDIT`。
12. 关闭主窗口不会退出 GUI；菜单栏仍显示 daemon 与后台任务状态。`Quit Relay UI` 只退出界面，daemon 任务继续运行。

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

2026-07-19，Apple Silicon macOS：

- Rust workspace 的 85 项协议/daemon/Adapter 测试全部通过（含 daemon CHAIN 调度、单调更新时间、watcher 父进程守卫与 generic-adapter 20 项）
- Swift 的 107 项测试（12 套件）全部通过：manifest 与自定义 CLI 生成/编辑、共享协议版本派生、LaunchAgent 路径漂移判定、交互解码、命令管道、语言持久化、通知计划、Markdown 渲染、Claude 模型二进制扫描、项目历史、双开、输出雷达、待查看队列、跨 CLI 行动路由、可逆返回票与焦点电路、本地上下文分叉的截取/载荷/就绪目标过滤/多目标核对、结果汇流的显式冻结/聚焦/重新截取/返回核对与生命周期清理、结果裁决的多来源公平截尾/短来源预算回流/精确载荷预检/内存回执/只读来源回看与核对往返/显式来源漂移检查/裁决结果显式封存与不可变快照/私有原子检查点/重启恢复/坏文件隔离/可恢复移入废纸篓/派生血缘/父子差异/多代血缘导航/缺失父节点与循环边界/连通家族遍历/跨分支参考比较/私有内容多词搜索/查询往返生命周期/独立标题标签/置顶排序/证据字节不变/标签跨重启恢复与联动清理/决策到行动/行动回执/行动恢复/变化回执/变化接力/见证保存/见证对照/对照接力/单目标投递/失败保留、提示词安全暂存、可恢复逐窗核对回路与隐私化输入信号、终端命令构造、浮动窗口几何（移动钳制/八向缩放/级联/平铺）、对话提示词脚本与窗口注册
- 浮动终端窗口与智能体对话为 v0.33–v0.38 新形态：对话引擎依赖的 daemon 原语链路（start → completed → 输出提取 → 清理）已用本地 Ollama gemma4 真实任务端到端验证
- 以下部分条目验证于 v0.32 及更早的线程工作台 GUI 形态（该形态入口已移除、能力保留在 daemon/代码层），保留作历史验证记录：
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
