import SwiftUI

enum RelayLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh-Hans"
    case japanese = "ja"

    static let defaultsKey = "interfaceLanguage"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .chinese: "简体中文"
        case .japanese: "日本語"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> RelayLanguage {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let language = RelayLanguage(rawValue: rawValue) else {
            return .chinese
        }
        return language
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

struct RelayCopy {
    let language: RelayLanguage

    func text(_ key: String) -> String {
        let table = language == .chinese ? Self.chinese : Self.japanese
        return table[key] ?? key
    }

    func taskStatus(_ status: RelayTaskStatus) -> String {
        switch (language, status) {
        case (.chinese, .queued): "排队中"
        case (.chinese, .starting): "启动中"
        case (.chinese, .running): "运行中"
        case (.chinese, .waitingForApproval): "等待审批"
        case (.chinese, .waitingForInput): "等待输入"
        case (.chinese, .completed): "已完成"
        case (.chinese, .failed): "失败"
        case (.chinese, .canceled): "已取消"
        case (.japanese, .queued): "待機中"
        case (.japanese, .starting): "起動中"
        case (.japanese, .running): "実行中"
        case (.japanese, .waitingForApproval): "承認待ち"
        case (.japanese, .waitingForInput): "入力待ち"
        case (.japanese, .completed): "完了"
        case (.japanese, .failed): "失敗"
        case (.japanese, .canceled): "キャンセル済み"
        }
    }

    func daemonState(_ state: DaemonState) -> String {
        switch (language, state) {
        case (.chinese, .connecting): "连接中"
        case (.chinese, .online): "在线"
        case (.chinese, .offline): "离线"
        case (.japanese, .connecting): "接続中"
        case (.japanese, .online): "オンライン"
        case (.japanese, .offline): "オフライン"
        }
    }

    func agentHealth(_ health: RelayAgentHealth) -> String {
        switch (language, health) {
        case (.chinese, .checking): "检查中"
        case (.chinese, .ready): "可用"
        case (.chinese, .missing): "未找到"
        case (.chinese, .invalid): "无效"
        case (.japanese, .checking): "確認中"
        case (.japanese, .ready): "使用可能"
        case (.japanese, .missing): "未検出"
        case (.japanese, .invalid): "無効"
        }
    }

    func threadFilter(_ filter: RelayThreadFilter) -> String {
        switch (language, filter) {
        case (.chinese, .all): "全部"
        case (.chinese, .active): "进行中"
        case (.chinese, .waiting): "等待中"
        case (.chinese, .failed): "失败"
        case (.chinese, .done): "已结束"
        case (.japanese, .all): "すべて"
        case (.japanese, .active): "実行中"
        case (.japanese, .waiting): "待機中"
        case (.japanese, .failed): "失敗"
        case (.japanese, .done): "終了"
        }
    }

    func outputKind(_ kind: RelayOutputKind) -> String {
        switch (language, kind) {
        case (.chinese, .user): "你"
        case (.chinese, .assistant): "智能体"
        case (.chinese, .tool): "工具"
        case (.chinese, .system): "系统"
        case (.chinese, .error): "错误"
        case (.japanese, .user): "あなた"
        case (.japanese, .assistant): "エージェント"
        case (.japanese, .tool): "ツール"
        case (.japanese, .system): "システム"
        case (.japanese, .error): "エラー"
        }
    }

    func codexMode(_ mode: RelayCodexMode) -> String {
        switch (language, mode) {
        case (.chinese, .defaultMode): "默认"
        case (.chinese, .plan): "计划"
        case (.japanese, .defaultMode): "デフォルト"
        case (.japanese, .plan): "計画"
        }
    }

    func chainPlaceholder(count: Int) -> String {
        if count >= 2 {
            return language == .chinese
                ? "发送给 \(count) 个接力步骤的任务…"
                : "\(count) ステップのチェーンに送るタスク…"
        }
        return text("Click at least two agents to build a chain…")
    }

    func comparePlaceholder(count: Int) -> String {
        if count >= 2 {
            return language == .chinese
                ? "并行发送给 \(count) 个智能体的任务…"
                : "\(count) 個のエージェントへ並列送信するタスク…"
        }
        return text("Check at least two agents to compare…")
    }

    func taskPlaceholder(agentName: String) -> String {
        language == .chinese
            ? "描述一个交给 \(agentName) 的任务…"
            : "\(agentName) に依頼するタスクを入力…"
    }

    private static let chinese: [String: String] = [
        "Settings": "设置",
        "General": "通用",
        "Agents": "智能体",
        "Interface language": "界面语言",
        "Changes the language used by Relay. CLI output and agent replies stay unchanged.": "切换 Relay 自身界面的语言。CLI 输出和智能体回答保持原文。",
        "Default working directory": "默认工作目录",
        "Used when creating a new thread. Existing threads keep their own working directory.": "创建新线程时使用。已有线程保留各自的工作目录。",
        "Choose…": "选择…",
        "Codex default mode": "Codex 默认模式",
        "Default runs directly. Plan allows Codex to ask questions before execution.": "“默认”直接执行；“计划”允许 Codex 在执行前提问。",
        "MIX default model": "MIX 默认模型",
        "The Codex model used when MIX combines Claude and Codex.": "MIX 组合 Claude 与 Codex 时使用的 Codex 模型。",
        "Reasoning effort": "推理强度",
        "Used by the selected Codex model inside MIX.": "应用于 MIX 内所选的 Codex 模型。",
        "Settings are saved automatically": "设置会自动保存",
        "Open Settings…": "打开设置…",
        "Open Relay": "打开 Relay",
        "Refresh Status": "刷新状态",
        "No active or waiting tasks": "没有运行中或等待中的任务",
        "Daemon continues after the UI quits": "退出界面后，后台任务仍会继续",
        "Quit Relay UI": "退出 Relay 界面",
        "background tasks": "后台任务",
        "ACTIVE": "进行中",
        "WAITING": "等待中",
        "AGENTS": "智能体",
        "MANAGE": "管理",
        "SETTINGS": "设置",
        "NEW THREAD": "新线程",
        "THREADS": "线程",
        "NO THREADS": "暂无线程",
        "Pick an agent": "选择智能体",
        "and enter a task": "并输入任务",
        "LOCAL ONLY": "仅限本机",
        "COMPARE": "对比",
        "CHAIN": "接力",
        "UNDO": "撤销",
        "CLEAR": "清除",
        "ROUTE": "执行顺序",
        "click agents in execution order": "按执行顺序点击智能体",
        "Instruction passed between steps (optional)": "步骤间传递的指令（可选）",
        "Search title, agent, cwd": "搜索标题、智能体或工作目录",
        "PROJECT": "项目",
        "Delete this thread?": "删除这个线程？",
        "Its local history and output will be removed from Relay.": "Relay 中保存的本地历史与输出将被删除。",
        "Delete": "删除",
        "SAVE": "保存",
        "RENAME": "重命名",
        "CANCEL": "取消",
        "DELETE": "删除",
        "CHOOSE": "选择",
        "Working directory": "工作目录",
        "MODEL": "模型",
        "EFFORT": "强度",
        "CODEX MODE": "CODEX 模式",
        "Interactive questions enabled": "允许交互提问",
        "Direct execution": "直接执行",
        "Local multi-CLI workspace": "本地多 CLI 工作台",
        "Thread title": "线程标题",
        "Waiting for adapter output…": "正在等待 Adapter 输出…",
        "RELAY READY": "RELAY 已就绪",
        "unavailable": "不可用",
        "Enter a task below. Relay stays active after this window closes.": "在下方输入任务。关闭窗口后 Relay 仍会继续运行。",
        "FOCUS": "聚焦",
        "Waiting in USER GATE — use FOCUS to respond": "正在等待用户操作，请聚焦后回答",
        "RETURN": "提交",
        "CONTINUE": "继续",
        "Custom response": "自定义回答",
        "SENDING…": "发送中…",
        "SEND RESPONSE": "发送回答",
        "APPROVAL": "审批",
        "INPUT": "输入",
        "ADAPTER MANIFESTS": "ADAPTER 配置",
        "ADD CLI": "添加 CLI",
        "IMPORT": "导入",
        "CLOSE": "关闭",
        "USER DIR": "用户目录",
        "REVEAL": "显示位置",
        "USER": "用户",
        "BUILT-IN": "内置",
        "EDIT": "编辑",
        "ADD LINE CLI": "添加行式 CLI",
        "EDIT LINE CLI": "编辑行式 CLI",
        "Prompt via stdin · output from stdout": "通过 stdin 输入 · 从 stdout 输出",
        "EXECUTABLE": "可执行文件",
        "ARGUMENTS · ONE ARGUMENT PER LINE · OPTIONAL": "参数 · 每行一个 · 可选",
        "LOCAL MANIFEST": "本地配置",
        "SAVING…": "保存中…",
        "CREATE ADAPTER": "创建 ADAPTER",
        "SAVE ADAPTER": "保存 ADAPTER",
        "Chinese": "简体中文",
        "Japanese": "日本語",
        "Manage adapter manifests": "管理 Adapter 配置",
        "Open Relay settings": "打开 Relay 设置",
        "Send one task to several agents in parallel": "将同一任务并行发送给多个智能体",
        "Pass each completed answer to the next agent": "将每一步完成的回答交给下一个智能体",
        "Clear thread search": "清除线程搜索",
        "Refresh threads": "刷新线程",
        "Cancel rename": "取消重命名",
        "Delete this local thread": "删除这个本地线程",
        "NO MATCHES": "没有匹配项",
        "Change the search": "请修改搜索条件",
        "No threads with this status": "没有此状态的线程",
        "CLEAR SEARCH": "清除搜索",
        "SHOW ALL": "显示全部",
        "Some output was truncated after reaching the local history limit.": "部分输出因达到本地历史上限而被截断。",
        "BACK TO CHAIN": "返回接力",
        "BACK TO COMPARE": "返回对比",
        "Focused on one chain step": "正在查看一个接力步骤",
        "Focused on one comparison member": "正在查看一个对比成员",
        "Open this chain step as a normal thread": "将这个接力步骤作为普通线程打开",
        "Open this member as a normal thread": "将这个成员作为普通线程打开",
        "Click at least two agents to build a chain…": "请至少点击两个智能体来创建接力…",
        "Check at least two agents to compare…": "请至少选择两个智能体进行对比…",
        "Respond in USER GATE above to continue…": "请在上方的用户操作区回答后继续…",
        "The selected task is still running…": "所选任务仍在运行…",
        "Continue this thread, or type @agent to hand it off…": "继续此线程，或输入 @agent 进行交接…",
        "Type @agent to hand off, or start a new task…": "输入 @agent 进行交接，或开始新任务…",
        "Remove adapter": "移除 Adapter",
        "Its manifest will be deleted from the user adapter directory.": "它的配置文件将从用户 Adapter 目录中删除。",
        "Create a line-based CLI adapter": "创建行式 CLI Adapter",
        "Copy a manifest into the user adapter directory": "将配置文件复制到用户 Adapter 目录",
        "Rescan manifests": "重新扫描配置文件",
        "CLI ID · start with a letter or number · then a-z, 0-9, - or _": "CLI ID · 以字母或数字开头 · 后续可用 a-z、0-9、- 或 _",
        "DISPLAY NAME": "显示名称",
        "Relay creates a local manifest and registers it immediately. This simple adapter does not resume CLI-native sessions; import a custom manifest for session or JSONL support.": "Relay 会创建本地配置并立即注册。这个简单 Adapter 不会恢复 CLI 原生会话；如需 session 或 JSONL 支持，请导入自定义配置。",
        "Relay keeps the CLI ID and updates this local manifest immediately. Running tasks keep their existing process; new tasks use the saved executable and arguments.": "Relay 会保留 CLI ID 并立即更新本地配置。运行中的任务保持现有进程；新任务使用保存后的可执行文件与参数。"
    ]

    private static let japanese: [String: String] = [
        "Settings": "設定",
        "General": "一般",
        "Agents": "エージェント",
        "Interface language": "表示言語",
        "Changes the language used by Relay. CLI output and agent replies stay unchanged.": "Relay の画面表示を切り替えます。CLI 出力とエージェントの回答は原文のままです。",
        "Default working directory": "デフォルトの作業フォルダ",
        "Used when creating a new thread. Existing threads keep their own working directory.": "新しいスレッドの作成時に使用します。既存のスレッドは元の作業フォルダを保持します。",
        "Choose…": "選択…",
        "Codex default mode": "Codex のデフォルトモード",
        "Default runs directly. Plan allows Codex to ask questions before execution.": "「デフォルト」は直接実行し、「計画」は実行前の質問を許可します。",
        "MIX default model": "MIX のデフォルトモデル",
        "The Codex model used when MIX combines Claude and Codex.": "MIX が Claude と Codex を組み合わせる際に使用する Codex モデルです。",
        "Reasoning effort": "推論強度",
        "Used by the selected Codex model inside MIX.": "MIX 内で選択した Codex モデルに適用します。",
        "Settings are saved automatically": "設定は自動的に保存されます",
        "Open Settings…": "設定を開く…",
        "Open Relay": "Relay を開く",
        "Refresh Status": "状態を更新",
        "No active or waiting tasks": "実行中または待機中のタスクはありません",
        "Daemon continues after the UI quits": "画面を終了してもバックグラウンド処理は継続します",
        "Quit Relay UI": "Relay の画面を終了",
        "background tasks": "バックグラウンドタスク",
        "ACTIVE": "実行中",
        "WAITING": "待機中",
        "AGENTS": "エージェント",
        "MANAGE": "管理",
        "SETTINGS": "設定",
        "NEW THREAD": "新規スレッド",
        "THREADS": "スレッド",
        "NO THREADS": "スレッドなし",
        "Pick an agent": "エージェントを選び",
        "and enter a task": "タスクを入力してください",
        "LOCAL ONLY": "ローカルのみ",
        "COMPARE": "比較",
        "CHAIN": "チェーン",
        "UNDO": "元に戻す",
        "CLEAR": "クリア",
        "ROUTE": "実行順序",
        "click agents in execution order": "実行順にエージェントをクリック",
        "Instruction passed between steps (optional)": "ステップ間で渡す指示（任意）",
        "Search title, agent, cwd": "タイトル・エージェント・作業フォルダを検索",
        "PROJECT": "プロジェクト",
        "Delete this thread?": "このスレッドを削除しますか？",
        "Its local history and output will be removed from Relay.": "Relay に保存されたローカル履歴と出力が削除されます。",
        "Delete": "削除",
        "SAVE": "保存",
        "RENAME": "名前変更",
        "CANCEL": "キャンセル",
        "DELETE": "削除",
        "CHOOSE": "選択",
        "Working directory": "作業フォルダ",
        "MODEL": "モデル",
        "EFFORT": "強度",
        "CODEX MODE": "CODEX モード",
        "Interactive questions enabled": "対話形式の質問を許可",
        "Direct execution": "直接実行",
        "Local multi-CLI workspace": "ローカル マルチ CLI ワークスペース",
        "Thread title": "スレッド名",
        "Waiting for adapter output…": "Adapter の出力を待っています…",
        "RELAY READY": "RELAY 準備完了",
        "unavailable": "利用不可",
        "Enter a task below. Relay stays active after this window closes.": "下にタスクを入力してください。ウインドウを閉じても Relay は動作を続けます。",
        "FOCUS": "フォーカス",
        "Waiting in USER GATE — use FOCUS to respond": "ユーザー操作を待っています。フォーカスして回答してください",
        "RETURN": "実行",
        "CONTINUE": "続ける",
        "Custom response": "自由入力",
        "SENDING…": "送信中…",
        "SEND RESPONSE": "回答を送信",
        "APPROVAL": "承認",
        "INPUT": "入力",
        "ADAPTER MANIFESTS": "ADAPTER 設定",
        "ADD CLI": "CLI を追加",
        "IMPORT": "読み込む",
        "CLOSE": "閉じる",
        "USER DIR": "ユーザーフォルダ",
        "REVEAL": "Finder で表示",
        "USER": "ユーザー",
        "BUILT-IN": "内蔵",
        "EDIT": "編集",
        "ADD LINE CLI": "行形式 CLI を追加",
        "EDIT LINE CLI": "行形式 CLI を編集",
        "Prompt via stdin · output from stdout": "stdin から入力 · stdout へ出力",
        "EXECUTABLE": "実行ファイル",
        "ARGUMENTS · ONE ARGUMENT PER LINE · OPTIONAL": "引数 · 1 行につき 1 個 · 任意",
        "LOCAL MANIFEST": "ローカル設定",
        "SAVING…": "保存中…",
        "CREATE ADAPTER": "ADAPTER を作成",
        "SAVE ADAPTER": "ADAPTER を保存",
        "Chinese": "简体中文",
        "Japanese": "日本語",
        "Manage adapter manifests": "Adapter 設定を管理",
        "Open Relay settings": "Relay の設定を開く",
        "Send one task to several agents in parallel": "同じタスクを複数のエージェントへ並列送信",
        "Pass each completed answer to the next agent": "完了した回答を次のエージェントへ渡す",
        "Clear thread search": "スレッド検索をクリア",
        "Refresh threads": "スレッドを更新",
        "Cancel rename": "名前変更をキャンセル",
        "Delete this local thread": "このローカルスレッドを削除",
        "NO MATCHES": "一致する項目なし",
        "Change the search": "検索条件を変更してください",
        "No threads with this status": "この状態のスレッドはありません",
        "CLEAR SEARCH": "検索をクリア",
        "SHOW ALL": "すべて表示",
        "Some output was truncated after reaching the local history limit.": "ローカル履歴の上限に達したため、一部の出力を省略しました。",
        "BACK TO CHAIN": "チェーンに戻る",
        "BACK TO COMPARE": "比較に戻る",
        "Focused on one chain step": "1 つのチェーンステップを表示中",
        "Focused on one comparison member": "1 つの比較メンバーを表示中",
        "Open this chain step as a normal thread": "このチェーンステップを通常のスレッドとして開く",
        "Open this member as a normal thread": "このメンバーを通常のスレッドとして開く",
        "Click at least two agents to build a chain…": "2 個以上のエージェントをクリックしてチェーンを作成…",
        "Check at least two agents to compare…": "比較するエージェントを 2 個以上選択…",
        "Respond in USER GATE above to continue…": "上のユーザー操作欄で回答して続行…",
        "The selected task is still running…": "選択したタスクは実行中です…",
        "Continue this thread, or type @agent to hand it off…": "このスレッドを続けるか、@agent で引き継ぎ…",
        "Type @agent to hand off, or start a new task…": "@agent で引き継ぐか、新しいタスクを開始…",
        "Remove adapter": "Adapter を削除",
        "Its manifest will be deleted from the user adapter directory.": "設定ファイルがユーザー Adapter フォルダから削除されます。",
        "Create a line-based CLI adapter": "行形式 CLI Adapter を作成",
        "Copy a manifest into the user adapter directory": "設定ファイルをユーザー Adapter フォルダへコピー",
        "Rescan manifests": "設定ファイルを再読み込み",
        "CLI ID · start with a letter or number · then a-z, 0-9, - or _": "CLI ID · 英数字で開始 · 以降は a-z、0-9、-、_ を使用",
        "DISPLAY NAME": "表示名",
        "Relay creates a local manifest and registers it immediately. This simple adapter does not resume CLI-native sessions; import a custom manifest for session or JSONL support.": "Relay はローカル設定を作成してすぐに登録します。この簡易 Adapter は CLI 本来のセッションを再開しません。session または JSONL 対応にはカスタム設定を読み込んでください。",
        "Relay keeps the CLI ID and updates this local manifest immediately. Running tasks keep their existing process; new tasks use the saved executable and arguments.": "Relay は CLI ID を維持したままローカル設定をすぐに更新します。実行中のタスクは既存プロセスを維持し、新しいタスクから保存後の実行ファイルと引数を使用します。"
    ]
}

private struct RelayLanguageKey: EnvironmentKey {
    static let defaultValue = RelayLanguage.chinese
}

extension EnvironmentValues {
    var relayLanguage: RelayLanguage {
        get { self[RelayLanguageKey.self] }
        set { self[RelayLanguageKey.self] = newValue }
    }
}
