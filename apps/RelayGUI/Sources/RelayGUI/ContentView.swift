import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum RelayPalette {
    static let ink = Color(red: 0.035, green: 0.043, blue: 0.055)
    static let panel = Color(red: 0.061, green: 0.073, blue: 0.091)
    static let raised = Color(red: 0.088, green: 0.104, blue: 0.128)
    static let line = Color.white.opacity(0.09)
    static let text = Color(red: 0.89, green: 0.91, blue: 0.94)
    static let muted = Color(red: 0.50, green: 0.55, blue: 0.62)
    static let signal = Color(red: 0.35, green: 0.65, blue: 1.0)
    static let success = Color(red: 0.44, green: 0.84, blue: 0.61)
    static let warning = Color(red: 0.95, green: 0.72, blue: 0.29)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.49)
    static let claude = Color(red: 0.89, green: 0.52, blue: 0.34)
    static let mix = Color(red: 0.72, green: 0.52, blue: 1.0)
}

private extension RelayTaskStatus {
    var color: Color {
        switch self {
        case .queued, .starting:
            RelayPalette.warning
        case .running, .waitingForApproval, .waitingForInput:
            RelayPalette.signal
        case .completed:
            RelayPalette.success
        case .failed, .canceled:
            RelayPalette.danger
        }
    }

    var glyph: String {
        switch self {
        case .queued: "○"
        case .starting: "◌"
        case .running: "●"
        case .waitingForApproval, .waitingForInput: "◇"
        case .completed: "✓"
        case .failed: "×"
        case .canceled: "−"
        }
    }
}

private extension RelayOutputKind {
    var color: Color {
        switch self {
        case .user: RelayPalette.signal
        case .assistant: RelayPalette.success
        case .tool: RelayPalette.warning
        case .system: RelayPalette.muted
        case .error: RelayPalette.danger
        }
    }
}

private extension RelayAgentHealth {
    var color: Color {
        switch self {
        case .checking:
            RelayPalette.warning
        case .ready:
            RelayPalette.success
        case .missing, .invalid:
            RelayPalette.danger
        }
    }
}

private extension RelayThreadFilter {
    var color: Color {
        switch self {
        case .all, .active:
            RelayPalette.signal
        case .waiting:
            RelayPalette.warning
        case .failed:
            RelayPalette.danger
        case .done:
            RelayPalette.success
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var relay: RelayService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var prompt = ""
    @State private var threadQuery = ""
    @State private var threadFilter: RelayThreadFilter = .all
    @State private var pendingDeletionTask: RelayTask?
    @State private var renamingTaskID: String?
    @State private var renameDraft = ""
    @State private var showingAdapterManager = false
    @State private var focusedCompareMemberID: String?
    @FocusState private var promptFocused: Bool
    @FocusState private var renameFocused: Bool
    let openSettings: () -> Void

    init(openSettings: @escaping () -> Void = {}) {
        self.openSettings = openSettings
    }

    private var copy: RelayCopy { RelayCopy(language: relay.language) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 310)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(width: 1)

            workspace
        }
        .background(RelayPalette.ink)
        .foregroundStyle(RelayPalette.text)
        .font(.system(.body, design: .monospaced))
        .onAppear { promptFocused = true }
        .onChange(of: relay.selectedTaskID) { _, selectedTaskID in
            if renamingTaskID != selectedTaskID {
                cancelRename()
            }
            if focusedCompareMemberID != selectedTaskID {
                focusedCompareMemberID = nil
            }
        }
        .alert(item: $pendingDeletionTask) { task in
            Alert(
                title: Text(copy.text("Delete this thread?")),
                message: Text(copy.text("Its local history and output will be removed from Relay.")),
                primaryButton: .destructive(Text(copy.text("Delete"))) {
                    Task { await relay.deleteTask(task.id) }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $showingAdapterManager) {
            AdapterManagerView()
                .environmentObject(relay)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(">")
                        .foregroundStyle(RelayPalette.signal)
                    Text("RELAY_")
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                }
                daemonBadge
            }
            .padding(.horizontal, 18)
            .padding(.top, 38)
            .padding(.bottom, 18)

            HStack {
                sectionLabel(copy.text("AGENTS"))
                Spacer()
                Button(copy.text("MANAGE")) {
                    showingAdapterManager = true
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .help(copy.text("Manage adapter manifests"))
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .help(copy.text("Open Relay settings"))
                Button(copy.text("NEW THREAD")) {
                    relay.startNewThread()
                    promptFocused = true
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                .padding(.trailing, 12)
            }

            agentModeBar

            if relay.chainMode {
                chainRouteBuilder
            }

            VStack(spacing: 4) {
                ForEach(relay.agents) { agent in
                    AgentRow(
                        agent: agent,
                        activity: ThreadCatalog.activity(relay.tasks, agentID: agent.id),
                        selected: relay.selectedAgentID == agent.id && relay.selectedTaskID == nil
                            && !relay.compareMode && !relay.chainMode,
                        compare: relay.compareMode,
                        checked: relay.compareSelection.contains(agent.id),
                        chain: relay.chainMode,
                        chainSteps: relay.chainSequence.enumerated().compactMap { index, id in
                            id == agent.id ? index + 1 : nil
                        }
                    ) {
                        if relay.compareMode {
                            relay.toggleCompareAgent(agent.id)
                        } else if relay.chainMode {
                            relay.appendChainAgent(agent.id)
                        } else {
                            relay.selectAgent(agent.id)
                        }
                        promptFocused = true
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)
                .padding(.vertical, 8)

            HStack {
                sectionLabel(copy.text("THREADS"))
                Spacer()
                Text(hasThreadQuery
                     ? "\(filteredTaskCount)/\(relay.tasks.count)"
                     : "\(relay.tasks.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .padding(.trailing, 18)
            }

            if relay.tasks.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("┌─ \(copy.text("NO THREADS"))")
                    Text("│ \(copy.text("Pick an agent"))")
                    Text("└─ \(copy.text("and enter a task"))")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
                .padding(18)
            } else {
                threadStatusBar
                threadSearch

                if taskGroups.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(hasThreadQuery
                             ? "┌─ \(copy.text("NO MATCHES"))"
                             : "┌─ \(copy.threadFilter(threadFilter))")
                        Text(hasThreadQuery
                             ? "│ \(copy.text("Change the search"))"
                             : "│ \(copy.text("No threads with this status"))")
                        Button(hasThreadQuery
                               ? "└─ \(copy.text("CLEAR SEARCH"))"
                               : "└─ \(copy.text("SHOW ALL"))") {
                            if hasThreadQuery {
                                threadQuery = ""
                            } else {
                                threadFilter = .all
                            }
                        }
                            .buttonStyle(.plain)
                            .foregroundStyle(RelayPalette.signal)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .padding(18)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(taskGroups) { group in
                            projectHeader(group)
                            ForEach(group.tasks) { task in
                                TaskRow(
                                    task: task,
                                    selected: relay.selectedTaskID == task.id
                                ) {
                                    if reduceMotion {
                                        relay.selectTask(task.id)
                                    } else {
                                        withAnimation(.snappy(duration: 0.24)) {
                                            relay.selectTask(task.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text(copy.text("LOCAL ONLY"))
                Spacer()
                Text("PROTOCOL v\(RelayProtocol.current)")
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(RelayPalette.muted)
            .padding(18)
        }
        .background(RelayPalette.panel)
    }

    private var agentModeBar: some View {
        HStack(spacing: 6) {
            Button(copy.text("COMPARE")) {
                relay.toggleCompareMode()
                promptFocused = true
            }
            .buttonStyle(ConsoleButtonStyle(
                tint: relay.compareMode ? RelayPalette.mix : RelayPalette.muted
            ))
            .help(copy.text("Send one task to several agents in parallel"))

            Button(copy.text("CHAIN")) {
                relay.toggleChainMode()
                promptFocused = true
            }
            .buttonStyle(ConsoleButtonStyle(
                tint: relay.chainMode ? RelayPalette.warning : RelayPalette.muted
            ))
            .help(copy.text("Pass each completed answer to the next agent"))

            Spacer()

            if relay.chainMode {
                Button(copy.text("UNDO")) { relay.removeLastChainAgent() }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    .disabled(relay.chainSequence.isEmpty)
                Button(copy.text("CLEAR")) { relay.clearChainSequence() }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                    .disabled(relay.chainSequence.isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var chainRouteBuilder: some View {
        VStack(alignment: .leading, spacing: 7) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    Text(copy.text("ROUTE"))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayPalette.warning)
                    if relay.chainSequence.isEmpty {
                        Text(copy.text("click agents in execution order"))
                            .foregroundStyle(RelayPalette.muted)
                    } else {
                        ForEach(Array(relay.chainSequence.enumerated()), id: \.offset) { index, id in
                            if index > 0 {
                                Text("›")
                                    .foregroundStyle(RelayPalette.warning)
                            }
                            Text("\(index + 1) \(id.uppercased())")
                                .fixedSize()
                        }
                    }
                }
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            }

            TextField(copy.text("Instruction passed between steps (optional)"), text: $relay.chainNote)
                .textFieldStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RelayPalette.ink.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel(copy.text("Instruction passed between steps (optional)"))
        }
        .padding(9)
        .background(RelayPalette.warning.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(RelayPalette.warning.opacity(0.22), lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var taskGroups: [RelayTaskGroup] {
        ThreadCatalog.grouped(relay.tasks, query: threadQuery, filter: threadFilter)
    }

    private var hasThreadQuery: Bool {
        !threadQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredTaskCount: Int {
        taskGroups.reduce(0) { $0 + $1.tasks.count }
    }

    private var threadStatusBar: some View {
        HStack(spacing: 4) {
            ForEach(RelayThreadFilter.allCases) { filter in
                let count = ThreadCatalog.count(relay.tasks, filter: filter)
                Button {
                    threadFilter = filter
                } label: {
                    VStack(spacing: 2) {
                        Text(copy.threadFilter(filter))
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .lineLimit(1)
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ThreadFilterButtonStyle(
                    tint: filter.color,
                    selected: threadFilter == filter
                ))
                .accessibilityLabel(copy.threadFilter(filter))
                .accessibilityValue("\(count)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var threadSearch: some View {
        HStack(spacing: 8) {
            Text("⌕")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.signal)
            TextField(copy.text("Search title, agent, cwd"), text: $threadQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
            if !threadQuery.isEmpty {
                Button { threadQuery = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayPalette.muted)
                .help(copy.text("Clear thread search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RelayPalette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }

    private func projectHeader(_ group: RelayTaskGroup) -> some View {
        HStack(spacing: 5) {
            Text(copy.text("PROJECT"))
                .foregroundStyle(RelayPalette.signal)
            Text("/")
            Text(group.name.uppercased())
                .lineLimit(1)
            Spacer()
            Text("\(group.tasks.count)")
        }
        .font(.system(size: 8, weight: .bold, design: .monospaced))
        .tracking(0.7)
        .foregroundStyle(RelayPalette.muted)
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .help(group.cwd)
    }

    private var daemonBadge: some View {
        HStack(spacing: 7) {
            StatusDot(
                color: relay.daemonState == .online ? RelayPalette.success : RelayPalette.warning,
                live: relay.daemonState == .connecting
            )
            Text("DAEMON \(copy.daemonState(relay.daemonState))")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(relay.daemonState == .online ? RelayPalette.success : RelayPalette.warning)
            if let version = relay.daemonVersion {
                Text("v\(version)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            workspaceHeader

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)

            if let error = relay.errorMessage {
                errorBanner(error)
            }

            Group {
                if let task = relay.selectedTask {
                    if let group = task.compareGroup, focusedCompareMemberID != task.id {
                        groupConsole(group)
                    } else {
                        VStack(spacing: 0) {
                            if task.compareGroup != nil {
                                groupBackBar(isChain: task.chainStep != nil)
                            }
                            taskConsole(task)
                        }
                    }
                } else {
                    readyConsole
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            composer
        }
        .background(RelayPalette.ink)
    }

    private var workspaceHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(relay.selectedTask.map { "THREAD / \($0.shortID) / \($0.adapterID.uppercased())" }
                         ?? "\(copy.text("NEW THREAD")) / \(relay.selectedAgent?.name.uppercased() ?? copy.text("unavailable"))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                    if let task = relay.selectedTask, renamingTaskID == task.id {
                        TextField(copy.text("Thread title"), text: $renameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .focused($renameFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand(perform: cancelRename)
                    } else {
                        Text(relay.selectedTask?.displayTitle ?? copy.text("Local multi-CLI workspace"))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let task = relay.selectedTask {
                    StatusTag(status: task.status)
                    if renamingTaskID == task.id {
                        Button(copy.text("SAVE")) { commitRename() }
                            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success))
                            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button { cancelRename() } label: {
                            Image(systemName: "xmark")
                                .frame(width: 12, height: 12)
                        }
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                        .help(copy.text("Cancel rename"))
                    } else {
                        Button(copy.text("RENAME")) { startRename(task) }
                            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    }
                    if !task.status.isTerminal {
                        Button(copy.text("CANCEL")) {
                            Task { await relay.cancelSelectedTask() }
                        }
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                    } else {
                        Button(copy.text("DELETE")) {
                            pendingDeletionTask = task
                        }
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                        .help(copy.text("Delete this local thread"))
                    }
                }

                Button {
                    Task {
                        if relay.daemonState == .offline {
                            await relay.reconnect()
                        } else {
                            await relay.refreshAll()
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                .help(copy.text("Refresh threads"))
            }

            HStack(spacing: 8) {
                Text("cwd")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                TextField(copy.text("Working directory"), text: Binding(
                    get: { relay.workingDirectory },
                    set: { relay.setWorkingDirectory($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RelayPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .disabled(relay.selectedTask != nil)

                Button(copy.text("CHOOSE")) { chooseDirectory() }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    .disabled(relay.selectedTask != nil)
            }

            if relay.selectedAgent?.capabilities.contains("mix_model_options") == true {
                mixControls
            }

            if relay.selectedAgent?.capabilities.contains("codex_modes") == true {
                codexControls
            }
            if let agent = relay.selectedAgent, !agent.options.isEmpty {
                agentOptionControls(agent)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 18)
        .padding(.top, 28)
        .padding(.bottom, 15)
    }

    private var mixControls: some View {
        HStack(spacing: 9) {
            Text("MIX")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.mix)
            Text("CLAUDE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
            Rectangle()
                .fill(RelayPalette.mix.opacity(0.45))
                .frame(width: 28, height: 1)
            Text("CONSENSUS")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.mix)
            Rectangle()
                .fill(RelayPalette.mix.opacity(0.45))
                .frame(width: 28, height: 1)
            Text("CODEX")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.text)

            Spacer()

            Text(copy.text("MODEL"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            Menu(relay.mixModel) {
                ForEach(relay.mixModels, id: \.self) { model in
                    Button(model) { relay.setMixModel(model) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 9, design: .monospaced))
            .frame(maxWidth: 145)

            Text(copy.text("EFFORT"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            Menu(relay.mixEffort.uppercased()) {
                ForEach(relay.mixEfforts, id: \.self) { effort in
                    Button(effort.uppercased()) { relay.setMixEffort(effort) }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 9, design: .monospaced))
            .frame(width: 64)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RelayPalette.mix.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(RelayPalette.mix.opacity(0.2), lineWidth: 1)
        }
        .disabled(relay.selectedTask?.status.isTerminal == false)
    }

    private func agentOptionControls(_ agent: RelayAgent) -> some View {
        HStack(spacing: 9) {
            Text("\(agent.name.uppercased()) OPTIONS")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.signal)

            Spacer()

            ForEach(agent.options, id: \.key) { option in
                Text(option.label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Menu(relay.agentOptionValue(agentID: agent.id, option: option)) {
                    ForEach(option.values, id: \.self) { value in
                        Button(value) {
                            relay.setAgentOption(agentID: agent.id, key: option.key, value: value)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 9, design: .monospaced))
                .frame(maxWidth: 180)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RelayPalette.signal.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(RelayPalette.signal.opacity(0.18), lineWidth: 1)
        }
        .disabled(relay.selectedTask?.status.isTerminal == false)
    }

    private var codexControls: some View {
        HStack(spacing: 9) {
            Text(copy.text("CODEX MODE"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.signal)

            ForEach(RelayCodexMode.allCases, id: \.rawValue) { mode in
                Button(copy.codexMode(mode)) { relay.setCodexMode(mode) }
                    .buttonStyle(ConsoleButtonStyle(
                        tint: relay.codexMode == mode ? RelayPalette.signal : RelayPalette.muted
                    ))
                    .accessibilityLabel(copy.codexMode(mode))
            }

            Text(relay.codexMode == .plan
                 ? copy.text("Interactive questions enabled")
                 : copy.text("Direct execution"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RelayPalette.signal.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(RelayPalette.signal.opacity(0.18), lineWidth: 1)
        }
        .disabled(relay.selectedTask?.status.isTerminal == false)
    }

    private func taskConsole(_ task: RelayTask) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        ConsoleLine(prefix: "id", text: task.id, color: RelayPalette.muted)
                        Text("\(task.turnCount)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(RelayPalette.muted)
                    }

                    if relay.outputTruncated {
                        ConsoleLine(
                            prefix: "!",
                            text: copy.text("Some output was truncated after reaching the local history limit."),
                            color: RelayPalette.warning
                        )
                    }

                    ForEach(relay.output) { item in
                        OutputBlock(item: item)
                            .id(item.id)
                    }

                    if let interaction = task.pendingInteraction {
                        InteractionGate(
                            interaction: interaction,
                            isResponding: relay.respondingInteractionID == interaction.id
                        ) { action, answers in
                            Task {
                                await relay.respondToInteraction(
                                    interaction,
                                    action: action,
                                    answers: answers
                                )
                            }
                        }
                        .id(interaction.id)
                    }

                    if relay.output.isEmpty, task.pendingInteraction == nil {
                        HStack(spacing: 7) {
                            StatusDot(color: task.status.color, live: !task.status.isTerminal)
                            Text(task.latestMessage ?? copy.text("Waiting for adapter output…"))
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                    }

                    HStack(spacing: 8) {
                        Text(task.status.glyph)
                            .foregroundStyle(task.status.color)
                        Text("\(copy.taskStatus(task.status))  \(task.updatedAt.formatted(date: .omitted, time: .standard))")
                        if let message = task.latestMessage {
                            Text("— \(message)")
                                .foregroundStyle(RelayPalette.muted)
                        }
                    }
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(task.status.color)
                    .id("status")
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: relay.output.last?.sequence) { _, _ in
                guard !reduceMotion else { return }
                if let id = relay.output.last?.id {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: task.pendingInteraction?.id) { _, interactionID in
                guard let interactionID, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(interactionID, anchor: .center)
                }
            }
        }
    }

    private var readyConsole: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("┌─ \(copy.text("RELAY READY"))")
                .foregroundStyle(RelayPalette.success)
            Text("│ daemon://local/v\(RelayProtocol.current)")
                .foregroundStyle(RelayPalette.muted)
            Text("│ agent: \(relay.selectedAgent?.name ?? copy.text("unavailable"))")
                .foregroundStyle(RelayPalette.muted)
            Text("│ cwd: \(relay.workingDirectory)")
                .foregroundStyle(RelayPalette.muted)
                .lineLimit(2)
            if let agent = relay.selectedAgent, !agent.isAvailable {
                Text("│ status: \(copy.agentHealth(agent.health))")
                    .foregroundStyle(agent.health.color)
                if let reason = agent.health.reason {
                    Text("│ \(reason)")
                        .foregroundStyle(RelayPalette.muted)
                }
            }
            Text("└─ \(copy.text("Enter a task below. Relay stays active after this window closes."))")
                .foregroundStyle(RelayPalette.text)
        }
        .font(.system(size: 14, weight: .medium, design: .monospaced))
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func groupBackBar(isChain: Bool) -> some View {
        HStack(spacing: 8) {
            Button("‹ \(copy.text(isChain ? "BACK TO CHAIN" : "BACK TO COMPARE"))") {
                focusedCompareMemberID = nil
            }
            .buttonStyle(ConsoleButtonStyle(
                tint: isChain ? RelayPalette.warning : RelayPalette.mix
            ))
            Text(copy.text(isChain ? "Focused on one chain step" : "Focused on one comparison member"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background((isChain ? RelayPalette.warning : RelayPalette.mix).opacity(0.05))
    }

    private func groupConsole(_ group: String) -> some View {
        let members = ThreadCatalog.compareMembers(relay.tasks, group: group)
        let isChain = members.contains { $0.chainStep != nil }
        let chainPlan = members.first?.chainAgents ?? []
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(copy.text(isChain ? "CHAIN" : "COMPARE"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(isChain ? RelayPalette.warning : RelayPalette.mix)
                Text(isChain
                     ? "\(members.count)/\(chainPlan.count) STEPS · "
                        + chainPlan.map { $0.uppercased() }.joined(separator: " › ")
                     : "\(members.count) AGENTS · same prompt in parallel")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)

            HStack(alignment: .top, spacing: 1) {
                ForEach(members) { member in
                    compareColumn(member, isChain: isChain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func compareColumn(_ member: RelayTask, isChain: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(isChain
                     ? "\((member.chainStep ?? 0) + 1)  \(member.adapterID.uppercased())"
                     : member.adapterID.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                StatusTag(status: member.status)
                Button(copy.text("FOCUS")) {
                    relay.selectTask(member.id)
                    focusedCompareMemberID = member.id
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .help(copy.text(isChain
                                ? "Open this chain step as a normal thread"
                                : "Open this member as a normal thread"))
            }
            if member.pendingInteraction != nil {
                Text(copy.text("Waiting in USER GATE — use FOCUS to respond"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(relay.groupOutputs[member.id] ?? []) { item in
                        OutputBlock(item: item)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RelayPalette.panel.opacity(0.4))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(RelayPalette.line)
                .frame(width: 1)
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)

            HStack(alignment: .center, spacing: 10) {
                Text("›")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.signal)

                TextField(composerPlaceholder, text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1...4)
                    .focused($promptFocused)
                    .onSubmit(submit)
                    .disabled(!relay.canSubmit)

                Text(composerModeLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(composerModeColor)

                Button(action: submit) {
                    Image(systemName: relay.isSubmitting ? "ellipsis" : "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                .disabled(
                    prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || relay.isSubmitting
                    || !relay.canSubmit
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(RelayPalette.panel)
        }
    }

    private var composerPlaceholder: String {
        if relay.chainMode {
            let count = relay.chainSequence.count
            return copy.chainPlaceholder(count: count)
        }
        if relay.compareMode {
            let count = relay.compareSelection.count
            return copy.comparePlaceholder(count: count)
        }
        if relay.selectedTask?.pendingInteraction != nil {
            return copy.text("Respond in USER GATE above to continue…")
        }
        if relay.selectedTask?.status.isTerminal == false {
            return copy.text("The selected task is still running…")
        }
        if relay.selectedTask?.sessionID != nil {
            return copy.text("Continue this thread, or type @agent to hand it off…")
        }
        if relay.selectedTask != nil {
            return copy.text("Type @agent to hand off, or start a new task…")
        }
        return copy.taskPlaceholder(agentName: relay.selectedAgent?.name ?? copy.text("unavailable"))
    }

    private var composerModeLabel: String {
        if relay.chainMode {
            return "CHAIN ×\(relay.chainSequence.count)"
        }
        if relay.compareMode {
            return "COMPARE ×\(relay.compareSelection.count)"
        }
        return copy.text(relay.selectedTask?.sessionID != nil ? "CONTINUE" : "RETURN")
    }

    private var composerModeColor: Color {
        if relay.chainMode { return RelayPalette.warning }
        if relay.compareMode { return RelayPalette.mix }
        return RelayPalette.muted
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("!")
                .foregroundStyle(RelayPalette.danger)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button { relay.dismissError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .foregroundStyle(RelayPalette.text)
        .background(RelayPalette.danger.opacity(0.09))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(RelayPalette.muted)
            .padding(.horizontal, 18)
            .padding(.vertical, 5)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: relay.workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            relay.setWorkingDirectory(url.path)
        }
    }

    private func submit() {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, relay.canSubmit else { return }
        relay.dismissError()
        prompt = ""
        Task {
            if relay.chainMode {
                await relay.submitChain(prompt: value)
            } else if relay.compareMode {
                await relay.submitCompare(prompt: value)
            } else if relay.selectedTask?.status.isTerminal == true, value.hasPrefix("@") {
                if let handoff = ThreadCatalog.parseHandoff(value, agents: relay.agents) {
                    await relay.handoff(
                        to: handoff.agentID,
                        instruction: handoff.instruction
                    )
                } else {
                    let available = relay.agents.map { "@\($0.id)" }.joined(separator: ", ")
                    relay.errorMessage = "Unknown handoff agent. Available: \(available)"
                }
            } else {
                await relay.submit(prompt: value)
            }
            if relay.errorMessage != nil {
                prompt = value
            }
            promptFocused = true
        }
    }

    private func startRename(_ task: RelayTask) {
        renameDraft = task.displayTitle
        renamingTaskID = task.id
        DispatchQueue.main.async {
            renameFocused = true
        }
    }

    private func cancelRename() {
        renamingTaskID = nil
        renameDraft = ""
        renameFocused = false
    }

    private func commitRename() {
        guard let taskID = renamingTaskID else { return }
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task {
            if await relay.renameTask(taskID, title: title) {
                cancelRename()
            }
        }
    }
}

private struct AgentRow: View {
    @Environment(\.relayLanguage) private var language
    let agent: RelayAgent
    let activity: RelayAgentActivity
    let selected: Bool
    var compare = false
    var checked = false
    var chain = false
    var chainSteps: [Int] = []
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if compare {
                    Text(checked ? "▣" : "☐")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(checked ? RelayPalette.signal : RelayPalette.muted)
                } else if chain {
                    Text(chainSteps.isEmpty
                         ? "+"
                         : chainSteps.map(String.init).joined(separator: ","))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(chainSteps.isEmpty ? RelayPalette.muted : RelayPalette.warning)
                        .frame(minWidth: 16)
                }
                StatusDot(color: agent.health.color, live: agent.health == .checking)
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(agent.health.reason ?? agent.version ?? agent.detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(RelayCopy(language: language).agentHealth(agent.health))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(agent.health.color)
                    if activity.hasWork {
                        HStack(spacing: 4) {
                            if activity.active > 0 {
                                Text("\(activity.active) \(RelayCopy(language: language).text("ACTIVE"))")
                                    .foregroundStyle(RelayPalette.signal)
                            }
                            if activity.active > 0, activity.waiting > 0 {
                                Text("·")
                                    .foregroundStyle(RelayPalette.muted)
                            }
                            if activity.waiting > 0 {
                                Text("\(activity.waiting) \(RelayCopy(language: language).text("WAITING"))")
                                    .foregroundStyle(RelayPalette.warning)
                            }
                        }
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RelayPalette.signal.opacity(0.11) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

private struct ThreadFilterButtonStyle: ButtonStyle {
    let tint: Color
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? tint : RelayPalette.muted)
            .padding(.vertical, 5)
            .background(selected ? tint.opacity(0.1) : RelayPalette.raised.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? tint.opacity(0.32) : RelayPalette.line, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

private struct TaskRow: View {
    @Environment(\.relayLanguage) private var language
    let task: RelayTask
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text(task.status.glyph)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(task.status.color)
                    .frame(width: 13)

                VStack(alignment: .leading, spacing: 5) {
                    Text(task.displayTitle)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayPalette.text)
                        .lineLimit(2)
                    HStack {
                        Text(
                            (task.chainStep != nil ? "→ " : task.compareGroup != nil ? "⋈ " : "")
                                + "\(task.adapterID.uppercased()) · \(task.shortID)"
                        )
                        Spacer()
                        Text(RelayCopy(language: language).taskStatus(task.status))
                    }
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RelayPalette.signal.opacity(0.11) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(RelayPalette.signal)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

private struct OutputBlock: View {
    @Environment(\.relayLanguage) private var language
    let item: RelayTaskOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(RelayCopy(language: language).outputKind(item.kind))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(item.kind.color)
                Rectangle()
                    .fill(item.kind.color.opacity(0.25))
                    .frame(height: 1)
            }
            Text(item.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(item.kind.color.opacity(0.65))
                .frame(width: 2)
        }
    }
}

private struct InteractionGate: View {
    @Environment(\.relayLanguage) private var language
    let interaction: RelayInteraction
    let isResponding: Bool
    let respond: (_ action: String?, _ answers: [String: [String]]) -> Void

    @State private var selectedAnswers: [String: String] = [:]
    @State private var customAnswers: [String: String] = [:]

    private var copy: RelayCopy { RelayCopy(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text("◇ USER GATE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
                Rectangle()
                    .fill(RelayPalette.warning.opacity(0.35))
                    .frame(height: 1)
                Text(copy.text(interaction.kind == .approval ? "APPROVAL" : "INPUT"))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(interaction.title)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Text(interaction.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if interaction.kind == .approval {
                VStack(spacing: 8) {
                    ForEach(interaction.actions) { action in
                        Button {
                            respond(action.value, [:])
                        } label: {
                            gateButtonLabel(action)
                        }
                        .buttonStyle(GateButtonStyle(tint: tint(for: action.value)))
                        .disabled(isResponding)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(interaction.questions) { question in
                        questionView(question)
                    }

                    Button {
                        respond(nil, answers)
                    } label: {
                        HStack {
                            Text(copy.text(isResponding ? "SENDING…" : "SEND RESPONSE"))
                            Spacer()
                            Text("↵")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GateButtonStyle(tint: RelayPalette.success))
                    .disabled(!canSend || isResponding)
                }
            }
        }
        .padding(16)
        .background(RelayPalette.warning.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(RelayPalette.warning.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(interaction.title)
    }

    private func questionView(_ question: RelayInteractionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(question.prompt)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))

            ForEach(question.options) { option in
                Button {
                    selectedAnswers[question.id] = option.value
                    customAnswers[question.id] = ""
                } label: {
                    HStack(alignment: .top, spacing: 9) {
                        Text(selectedAnswers[question.id] == option.value ? "◉" : "○")
                        gateButtonLabel(option)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(GateButtonStyle(
                    tint: selectedAnswers[question.id] == option.value
                        ? RelayPalette.signal
                        : RelayPalette.muted
                ))
                .disabled(isResponding)
            }

            if question.allowCustom {
                HStack(spacing: 9) {
                    Text(">")
                        .foregroundStyle(RelayPalette.signal)
                    if question.secret {
                        SecureField(copy.text("Custom response"), text: customBinding(for: question.id))
                            .textFieldStyle(.plain)
                    } else {
                        TextField(copy.text("Custom response"), text: customBinding(for: question.id))
                            .textFieldStyle(.plain)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(RelayPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(RelayPalette.line, lineWidth: 1)
                }
                .disabled(isResponding)
            }
        }
    }

    private func customBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { customAnswers[questionID] ?? "" },
            set: { value in
                customAnswers[questionID] = value
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectedAnswers[questionID] = nil
                }
            }
        )
    }

    private var canSend: Bool {
        !interaction.questions.isEmpty && interaction.questions.allSatisfy { question in
            answer(for: question) != nil
        }
    }

    private var answers: [String: [String]] {
        Dictionary(uniqueKeysWithValues: interaction.questions.compactMap { question in
            answer(for: question).map { (question.id, [$0]) }
        })
    }

    private func answer(for question: RelayInteractionQuestion) -> String? {
        let custom = customAnswers[question.id]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty {
            return custom
        }
        return selectedAnswers[question.id]
    }

    private func gateButtonLabel(_ option: RelayInteractionOption) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(option.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
            if let description = option.description {
                Text(description)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tint(for action: String) -> Color {
        switch action {
        case "accept", "acceptForSession":
            RelayPalette.success
        case "decline":
            RelayPalette.warning
        default:
            RelayPalette.danger
        }
    }
}

private struct GateButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? RelayPalette.ink : tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? tint : tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tint.opacity(configuration.isPressed ? 0 : 0.35), lineWidth: 1)
            }
    }
}

private struct StatusTag: View {
    @Environment(\.relayLanguage) private var language
    let status: RelayTaskStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: status.color, live: !status.isTerminal)
            Text(RelayCopy(language: language).taskStatus(status))
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(status.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(status.color.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct StatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    var live = false
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.28))
                .frame(width: pulsing ? 12 : 7, height: pulsing ? 12 : 7)
                .opacity(pulsing ? 0.1 : 0.65)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.45), radius: 4)
        }
        .frame(width: 12, height: 12)
        .onAppear {
            guard live, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.15).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

private struct ConsoleLine: View {
    let prefix: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(prefix)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 22, alignment: .trailing)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
                .textSelection(.enabled)
        }
    }
}

private struct ConsoleButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(configuration.isPressed ? RelayPalette.ink : tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? tint : tint.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tint.opacity(configuration.isPressed ? 0 : 0.35), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct LineCLIEditorContext: Identifiable {
    let agent: RelayAgent
    let configuration: LineCLIConfiguration

    var id: String { agent.id }
}

private struct AdapterManagerView: View {
    @EnvironmentObject private var relay: RelayService
    @Environment(\.dismiss) private var dismiss
    @State private var showingImporter = false
    @State private var showingCreator = false
    @State private var editorContext: LineCLIEditorContext?
    @State private var pendingRemoval: RelayAgent?

    private var copy: RelayCopy { RelayCopy(language: relay.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(copy.text("ADAPTER MANIFESTS"))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Button(copy.text("ADD CLI")) {
                    relay.dismissError()
                    showingCreator = true
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success))
                .help(copy.text("Create a line-based CLI adapter"))
                Button(copy.text("IMPORT")) { showingImporter = true }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                    .help(copy.text("Copy a manifest into the user adapter directory"))
                Button {
                    Task { await relay.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .help(copy.text("Rescan manifests"))
                Button(copy.text("CLOSE")) { dismiss() }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Text(copy.text("USER DIR"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Text(relay.userAdapterDirectory.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(copy.text("REVEAL")) {
                    NSWorkspace.shared.activateFileViewerSelecting([relay.userAdapterDirectory])
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(relay.agents) { agent in
                        adapterRow(agent)
                    }
                }
                .padding(14)
            }

            if let errorMessage = relay.errorMessage {
                Rectangle()
                    .fill(RelayPalette.line)
                    .frame(height: 1)
                Text(errorMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RelayPalette.danger)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 660, height: 440)
        .background(RelayPalette.ink)
        .foregroundStyle(RelayPalette.text)
        .font(.system(.body, design: .monospaced))
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json]
        ) { result in
            if case let .success(url) = result {
                Task { await relay.importAdapter(from: url) }
            }
        }
        .sheet(isPresented: $showingCreator) {
            LineCLIAdapterCreatorView()
                .environmentObject(relay)
        }
        .sheet(item: $editorContext) { context in
            LineCLIAdapterCreatorView(
                agent: context.agent,
                configuration: context.configuration
            )
            .environmentObject(relay)
        }
        .alert(item: $pendingRemoval) { agent in
            Alert(
                title: Text("\(copy.text("Remove adapter")) \(agent.name)?"),
                message: Text(copy.text("Its manifest will be deleted from the user adapter directory.")),
                primaryButton: .destructive(Text(copy.text("Delete"))) {
                    Task { await relay.deleteUserAdapter(agent) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func adapterRow(_ agent: RelayAgent) -> some View {
        let isUser = relay.isUserAdapter(agent)
        let lineCLIConfiguration = relay.lineCLIConfiguration(for: agent)
        return HStack(spacing: 10) {
            StatusDot(color: agent.health.color, live: agent.health == .checking)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(copy.text(isUser ? "USER" : "BUILT-IN"))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(isUser ? RelayPalette.signal : RelayPalette.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background((isUser ? RelayPalette.signal : RelayPalette.muted).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(agent.health.reason ?? agent.detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .lineLimit(1)
                Text(agent.manifestURL.path)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(copy.agentHealth(agent.health))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(agent.health.color)
                HStack(spacing: 6) {
                    if let lineCLIConfiguration {
                        Button(copy.text("EDIT")) {
                            relay.dismissError()
                            editorContext = LineCLIEditorContext(
                                agent: agent,
                                configuration: lineCLIConfiguration
                            )
                        }
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                    }
                    Button(copy.text("REVEAL")) {
                        NSWorkspace.shared.activateFileViewerSelecting([agent.manifestURL])
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    if isUser {
                        Button(copy.text("DELETE")) {
                            pendingRemoval = agent
                        }
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                    }
                }
            }
        }
        .padding(10)
        .background(RelayPalette.raised.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
    }
}

private struct LineCLIAdapterCreatorView: View {
    @EnvironmentObject private var relay: RelayService
    @Environment(\.dismiss) private var dismiss
    private let agent: RelayAgent?
    @State private var id: String
    @State private var name: String
    @State private var executablePath: String
    @State private var argumentLines: String
    @State private var isSaving = false

    private var copy: RelayCopy { RelayCopy(language: relay.language) }

    init(
        agent: RelayAgent? = nil,
        configuration: LineCLIConfiguration? = nil
    ) {
        self.agent = agent
        _id = State(initialValue: configuration?.id ?? "")
        _name = State(initialValue: configuration?.name ?? "")
        _executablePath = State(initialValue: configuration?.executablePath ?? "")
        _argumentLines = State(initialValue: configuration?.arguments.joined(separator: "\n") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy.text(agent == nil ? "ADD LINE CLI" : "EDIT LINE CLI"))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                    Text(copy.text("Prompt via stdin · output from stdout"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                }
                Spacer()
                Button(copy.text("CANCEL")) { dismiss() }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            }
            .padding(16)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 14) {
                creatorField(
                    copy.text("CLI ID · start with a letter or number · then a-z, 0-9, - or _"),
                    placeholder: "gemini-local",
                    text: $id,
                    disabled: agent != nil
                )
                creatorField(
                    copy.text("DISPLAY NAME"),
                    placeholder: "Gemini Local",
                    text: $name
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(copy.text("EXECUTABLE"))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                    HStack(spacing: 8) {
                        TextField("/absolute/path/to/cli", text: $executablePath)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .background(RelayPalette.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Button(copy.text("CHOOSE")) { chooseExecutable() }
                            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(copy.text("ARGUMENTS · ONE ARGUMENT PER LINE · OPTIONAL"))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                    TextEditor(text: $argumentLines)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 96)
                        .background(RelayPalette.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(RelayPalette.line, lineWidth: 1)
                        }
                }

                Text(copy.text(agent == nil
                    ? "Relay creates a local manifest and registers it immediately. This simple adapter does not resume CLI-native sessions; import a custom manifest for session or JSONL support."
                    : "Relay keeps the CLI ID and updates this local manifest immediately. Running tasks keep their existing process; new tasks use the saved executable and arguments."
                ))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorMessage = relay.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RelayPalette.danger)
                        .lineLimit(2)
                }
            }
            .padding(16)

            Spacer(minLength: 0)

            HStack {
                Text(copy.text("LOCAL MANIFEST"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Button(copy.text(isSaving ? "SAVING…" : (agent == nil ? "CREATE ADAPTER" : "SAVE ADAPTER"))) {
                    saveAdapter()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success))
                .disabled(!canSave || isSaving)
            }
            .padding(16)
            .background(RelayPalette.panel)
        }
        .frame(width: 590, height: 540)
        .background(RelayPalette.ink)
        .foregroundStyle(RelayPalette.text)
        .preferredColorScheme(.dark)
    }

    private func creatorField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        disabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(RelayPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .disabled(disabled)
                .opacity(disabled ? 0.6 : 1)
        }
    }

    private var arguments: [String] {
        argumentLines.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if panel.runModal() == .OK, let url = panel.url {
            executablePath = url.path
        }
    }

    private func saveAdapter() {
        relay.dismissError()
        isSaving = true
        Task {
            let saved: Bool
            if let agent {
                saved = await relay.updateLineCLIAdapter(
                    agent,
                    name: name,
                    executablePath: executablePath,
                    arguments: arguments
                )
            } else {
                saved = await relay.createLineCLIAdapter(
                    id: id,
                    name: name,
                    executablePath: executablePath,
                    arguments: arguments
                )
            }
            isSaving = false
            if saved {
                dismiss()
            }
        }
    }
}
