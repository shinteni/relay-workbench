import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum RelayPalette {
    static let ink = Color(red: 0.051, green: 0.051, blue: 0.055)
    static let panel = Color(red: 0.082, green: 0.082, blue: 0.086)
    static let raised = Color(red: 0.114, green: 0.114, blue: 0.120)
    static let hover = Color.white.opacity(0.05)
    static let line = Color.white.opacity(0.07)
    static let text = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let muted = Color(red: 0.60, green: 0.60, blue: 0.63)
    static let signal = Color(red: 0.35, green: 0.65, blue: 1.0)
    static let success = Color(red: 0.44, green: 0.84, blue: 0.61)
    static let warning = Color(red: 0.95, green: 0.72, blue: 0.29)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.49)
    static let claude = Color(red: 0.89, green: 0.52, blue: 0.34)
    static let mix = Color(red: 0.72, green: 0.52, blue: 1.0)

    static let pressSpring = Animation.spring(response: 0.25, dampingFraction: 1.0)
    static let selectSpring = Animation.spring(response: 0.3, dampingFraction: 1.0)
}

struct RelayMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension RelayAgent {
    var accent: Color {
        switch id {
        case "claude": RelayPalette.claude
        case "codex": RelayPalette.signal
        case "mix": RelayPalette.mix
        case "ollama": RelayPalette.success
        default:
            [
                RelayPalette.signal, RelayPalette.mix,
                RelayPalette.claude, RelayPalette.success,
            ][abs(id.hashValue) % 4]
        }
    }

    var monogram: String {
        String(name.prefix(2)).uppercased()
    }
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
    @State private var hasAutoFocusedComposer = false
    @State private var showingSaveTemplate = false
    @State private var expandedSessionProjects: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "expandedSessionProjects") ?? []
    )
    @State private var chainTemplateName = ""
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @StateObject private var terminals = RelayTerminalStore()
    @FocusState private var promptFocused: Bool
    @FocusState private var renameFocused: Bool
    let openSettings: () -> Void

    init(openSettings: @escaping () -> Void = {}) {
        self.openSettings = openSettings
    }

    private var copy: RelayCopy { RelayCopy(language: relay.language) }

    private var pendingInteractionIDs: [String] {
        relay.tasks.compactMap { $0.pendingInteraction?.id }
    }

    private func toggleSidebar() {
        if reduceMotion {
            sidebarCollapsed.toggle()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                sidebarCollapsed.toggle()
            }
        }
    }

    /// Slim rail shown while the sidebar is collapsed: expand control plus
    /// the approvals alert so urgent items never hide with the sidebar.
    private var collapsedRail: some View {
        VStack(spacing: 12) {
            Button {
                toggleSidebar()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RelayPalette.muted)
            .keyboardShortcut("\\", modifiers: .command)
            .help(copy.text("Expand sidebar"))
            if !pendingInteractionIDs.isEmpty {
                Button {
                    terminals.openApprovals()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Text("◇")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(RelayPalette.warning)
                        Circle()
                            .fill(RelayPalette.danger)
                            .frame(width: 5, height: 5)
                            .offset(x: 4, y: -3)
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(copy.text("Tasks that ask for tool approval or extra input show up here."))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 42)
        .padding(.bottom, 12)
        .frame(width: 30)
        .frame(maxHeight: .infinity)
        .background(RelayMaterial(material: .sidebar))
    }

    private var workspaceAccent: Color {
        let agentID = relay.selectedTask?.adapterID ?? relay.selectedAgentID
        return relay.agents.first { $0.id == agentID }?.accent ?? RelayPalette.signal
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarCollapsed {
                collapsedRail
            } else {
                sidebar
                    .frame(width: 310)
                    .background(RelayMaterial(material: .sidebar))
            }

            Rectangle()
                .fill(RelayPalette.line)
                .frame(width: 1)

            RelayTerminalWorkspace(
                store: terminals,
                agents: relay.agents,
                personas: relay.personas,
                onRestoreDesk: restoreDesk
            )
        }
        .background {
            ZStack {
                RelayMaterial(material: .underWindowBackground)
                Color.black.opacity(0.38)
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(RelayPalette.text)
        .font(.system(.body, design: .monospaced))
        .onAppear {
            DispatchQueue.main.async { promptFocused = true }
        }
        .onChange(of: relay.canSubmit) { _, canSubmit in
            if canSubmit, !hasAutoFocusedComposer {
                hasAutoFocusedComposer = true
                promptFocused = true
            }
        }
        .onChange(of: relay.selectedTaskID) { _, selectedTaskID in
            if renamingTaskID != selectedTaskID {
                cancelRename()
            }
            if focusedCompareMemberID != selectedTaskID {
                focusedCompareMemberID = nil
            }
        }
        .onChange(of: pendingInteractionIDs) { _, ids in
            if !ids.isEmpty {
                terminals.openApprovals()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            terminals.markFocusedOutputReviewed()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didBecomeKeyNotification
        )) { _ in
            terminals.markFocusedOutputReviewed()
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
        .alert(copy.text("Save this route as a template"), isPresented: $showingSaveTemplate) {
            TextField(copy.text("Template name"), text: $chainTemplateName)
            Button(copy.text("SAVE")) {
                relay.saveChainTemplate(named: chainTemplateName)
            }
            Button(copy.text("Cancel"), role: .cancel) {}
        }
    }

    private var sidebar: some View {
        GeometryReader { proxy in
            sidebarContent(
                compact: proxy.size.height < 800,
                minimal: proxy.size.height < 700
            )
        }
    }

    private func openTerminal(agent: RelayAgent) {
        terminals.open(agent: agent, cwd: relay.defaultWorkingDirectory) { key in
            agent.options.first { $0.key == key }.map {
                relay.agentOptionValue(agentID: agent.id, option: $0)
            }
        }
    }

    private func restoreDesk() {
        animateWorkspaceChange {
            terminals.restoreDesk(agents: relay.agents) { agent, key in
                agent.options.first { $0.key == key }.map {
                    relay.agentOptionValue(agentID: agent.id, option: $0)
                }
            }
        }
    }

    private func animateWorkspaceChange(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 1.0), changes)
        }
    }

    private var promptStagingControlHelp: String {
        if terminals.contextRelayDraft != nil {
            return copy.text("Close context fork before opening prompt stage")
        }
        if terminals.resultConfluence != nil {
            return copy.text("Close result confluence before opening prompt stage")
        }
        guard terminals.promptReviewPlan != nil else {
            return copy.text("Fill one prompt into several terminals without running it")
        }
        if terminals.promptStagingVisible {
            return copy.text("Hide prompt review; progress is kept")
        }
        if terminals.promptReviewPendingCount == 0 {
            return copy.text("Open completed prompt review")
        }
        return copy.text("Resume prompt review · ⟨N⟩ left")
            .replacingOccurrences(of: "⟨N⟩", with: "\(terminals.promptReviewPendingCount)")
    }

    /// Default agent pairing for orchestration windows: Claude then Codex
    /// when available, otherwise the first two available agents.
    private var defaultAgentPair: [String] {
        let available = relay.agents.filter(\.isAvailable)
        guard let fallback = available.first else { return [] }
        let first = available.first { $0.id == "claude" } ?? fallback
        let second = available.first { $0.id == "codex" && $0.id != first.id }
            ?? available.first { $0.id != first.id }
            ?? first
        return first.id == second.id ? [first.id] : [first.id, second.id]
    }

    private func openDialogue(preferredA: String? = nil) {
        var pair = defaultAgentPair
        if let preferredA {
            pair.removeAll { $0 == preferredA }
            pair.insert(preferredA, at: 0)
        }
        guard let first = pair.first else { return }
        terminals.openDialogue(RelayDialogueRun(
            relay: relay,
            participants: pair.count > 1 ? pair : [first, first]
        ))
    }


    /// Daemon compare/chain groups not currently mounted as windows.
    private var unmountedGroups: [(id: String, isChain: Bool, tasks: [RelayTask])] {
        let mountedChains = Set(terminals.chains.compactMap(\.chainID))
        let mountedCompares = Set(terminals.compares.compactMap(\.groupID))
        let grouped = Dictionary(
            grouping: relay.tasks.filter { $0.compareGroup != nil }
        ) { $0.compareGroup ?? "" }
        return grouped.compactMap { key, tasks in
            guard !key.isEmpty,
                  !mountedChains.contains(key),
                  !mountedCompares.contains(key) else { return nil }
            let isChain = tasks.contains { $0.chainStep != nil }
            let ordered = tasks.sorted { ($0.chainStep ?? 0) < ($1.chainStep ?? 0) }
            return (key, isChain, ordered)
        }
        .sorted {
            ($0.tasks.map(\.updatedAtMilliseconds).max() ?? 0)
                > ($1.tasks.map(\.updatedAtMilliseconds).max() ?? 0)
        }
    }

    private func remountGroup(_ group: (id: String, isChain: Bool, tasks: [RelayTask])) {
        if group.isChain {
            terminals.openChain(RelayChainRun.attached(
                relay: relay, chain: group.id, tasks: group.tasks
            ))
        } else {
            terminals.openCompare(RelayCompareRun.attached(
                relay: relay, group: group.id, tasks: group.tasks
            ))
        }
    }

    private func groupLabel(_ group: (id: String, isChain: Bool, tasks: [RelayTask])) -> String {
        let glyph = group.isChain ? "›" : "⋈"
        let agents = group.tasks
            .map { $0.adapterID.uppercased() }
            .joined(separator: group.isChain ? " › " : " · ")
        let active = group.tasks.contains { !$0.status.isTerminal }
        return "\(glyph) \(agents)\(active ? " ●" : "")"
    }

    /// First-class entry points for the app's namesake linking features.
    private var linkActions: some View {
        HStack(spacing: 6) {
            linkButton(
                glyph: "⇄", label: copy.text("Dialogue"), tint: RelayPalette.mix,
                helpKey: "Open a dialogue between two agents"
            ) { openDialogue() }
            linkButton(
                glyph: "⋈", label: copy.text("COMPARE"), tint: RelayPalette.signal,
                helpKey: "Send one prompt to several agents"
            ) { openCompare() }
            linkButton(
                glyph: "›", label: copy.text("CHAIN"), tint: RelayPalette.warning,
                helpKey: "Relay the answer through steps"
            ) { openChain() }
        }
    }

    /// Codex と同様に、履歴の最上位をプロジェクトへ統一する。
    /// daemon セッションと明示的に保存したチェックポイントは保存先を変えず、
    /// 作業したプロジェクト配下にまとめて表示する。
    private var projectHistorySection: some View {
        let allEntries = RelaySessionCatalog.historyEntries(
            tasks: relay.tasks,
            checkpoints: terminals.savedDecisionCheckpoints,
            annotations: terminals.decisionAnnotations
        )
        let projects = RelaySessionCatalog.historyProjects(
            allEntries,
            knownProjectPaths: relay.recentWorkingDirectories
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(copy.text("PROJECTS"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Button {
                    animateWorkspaceChange {
                        terminals.showSessionLibrary()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayPalette.muted)
                .help(copy.text("Search project history"))
            }
            .padding(.horizontal, 7)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(projects) { project in
                        historyProjectRow(project)
                        if expandedSessionProjects.contains(project.id) {
                            ForEach(project.entries) { entry in
                                projectHistoryRow(entry)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 250)
            .onAppear {
                seedExpandedSessionProjectsIfNeeded(projects)
            }
        }
        .padding(.horizontal, 6)
    }

    /// First launch: expand the folder of the current project, like Codex.
    private func seedExpandedSessionProjectsIfNeeded(
        _ projects: [RelayProjectHistoryGroup]
    ) {
        guard expandedSessionProjects.isEmpty else { return }
        let current = RelaySessionCatalog.normalizedProjectPath(
            RelayTerminalLauncher.resolvedWorkingDirectory(relay.workingDirectory)
        )
        let seeded = projects.contains { $0.id == current }
            ? current : projects.first?.id
        guard let seeded else { return }
        expandedSessionProjects = [seeded]
        UserDefaults.standard.set(
            Array(expandedSessionProjects), forKey: "expandedSessionProjects"
        )
    }

    private func historyProjectRow(_ project: RelayProjectHistoryGroup) -> some View {
        return Button {
            if expandedSessionProjects.contains(project.id) {
                expandedSessionProjects.remove(project.id)
            } else {
                expandedSessionProjects.insert(project.id)
            }
            UserDefaults.standard.set(
                Array(expandedSessionProjects), forKey: "expandedSessionProjects"
            )
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(RelayPalette.muted)
                    .frame(width: 16)
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RelayPalette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if project.entries.contains(where: \.hasActiveTask) {
                    Circle()
                        .fill(RelayPalette.signal)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func projectHistoryRow(_ item: RelayProjectHistoryEntry) -> some View {
        let selected: Bool = switch item.source {
        case .session(let entry): terminals.isSessionEntryFocused(entry)
        case .decision(let checkpoint): terminals.selectedDecisionCheckpoint?.id == checkpoint.id
        }
        return Button {
            animateWorkspaceChange {
                switch item.source {
                case .session(let entry):
                    terminals.openSessionEntry(entry, relay: relay)
                case .decision(let checkpoint):
                    terminals.openDecisionCheckpoint(checkpoint)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(RelayPalette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if item.hasActiveTask {
                    Circle()
                        .fill(RelayPalette.signal)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.leading, 29)
            .padding(.trailing, 9)
            .frame(height: 30)
            .background(selected ? RelayPalette.text.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    /// Amber banner that exists only while tasks wait in USER GATE —
    /// approvals are a to-do, not a feature, so they only appear when due.
    @ViewBuilder private var approvalsBanner: some View {
        if !pendingInteractionIDs.isEmpty {
            Button {
                terminals.openApprovals()
            } label: {
                HStack(spacing: 7) {
                    Text("◇")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text(copy.text("⟨N⟩ approvals waiting — click to respond")
                        .replacingOccurrences(
                            of: "⟨N⟩", with: "\(pendingInteractionIDs.count)"
                        ))
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    Spacer()
                    Text("→")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(RelayPalette.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RelayPalette.warning.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(RelayPalette.warning.opacity(0.35), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(copy.text("Tasks that ask for tool approval or extra input show up here."))
        }
    }

    private func linkButtonLabel(
        glyph: String, label: String, glyphTint: Color
    ) -> some View {
        VStack(spacing: 4) {
            Text(glyph)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(glyphTint)
            Text(label)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func linkButton(
        glyph: String,
        label: String,
        tint: Color,
        helpKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            linkButtonLabel(glyph: glyph, label: label, glyphTint: tint)
        }
        .buttonStyle(LinkActionButtonStyle(tint: RelayPalette.muted))
        .help(copy.text(helpKey))
        .disabled(relay.agents.allSatisfy { !$0.isAvailable })
    }

    private func openCompare() {
        guard !defaultAgentPair.isEmpty else { return }
        terminals.openCompare(RelayCompareRun(
            relay: relay,
            preselected: defaultAgentPair
        ))
    }

    private func openChain() {
        guard !defaultAgentPair.isEmpty else { return }
        terminals.openChain(RelayChainRun(
            relay: relay,
            preselected: defaultAgentPair
        ))
    }

    private func agentRail(compact: Bool) -> some View {
        let anyActive = relay.tasks.contains { !$0.status.isTerminal }
        return RoundedRectangle(cornerRadius: 1)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.03),
                        Color.white.opacity(anyActive ? 0.26 : 0.20),
                        Color.white.opacity(anyActive ? 0.26 : 0.20),
                        Color.white.opacity(0.03),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 2)
            .overlay {
                if anyActive, !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 2.2) / 2.2
                        GeometryReader { proxy in
                            Capsule()
                                .fill(workspaceAccent.opacity(0.9))
                                .frame(width: 2, height: 24)
                                .offset(y: (proxy.size.height + 24) * phase - 24)
                        }
                    }
                    .clipped()
                }
            }
            .padding(.leading, 33)
            .padding(.vertical, compact ? 14 : 22)
            .allowsHitTesting(false)
    }

    private func sidebarContent(compact: Bool, minimal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(">")
                            .font(.system(size: 19, weight: .bold, design: .monospaced))
                            .foregroundStyle(RelayPalette.signal)
                        Text("RELAY_")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .tracking(-0.2)
                    }
                    daemonBadge
                }
                Spacer()
                Button {
                    toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .keyboardShortcut("\\", modifiers: .command)
                .help(copy.text("Collapse sidebar"))
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .help(copy.text("Open Relay settings"))
            }
            .padding(.horizontal, 18)
            .padding(.top, compact ? 22 : 38)
            .padding(.bottom, compact ? 10 : 18)

            sectionLabel(copy.text("PROJECT"))
            projectDock(compact: compact, minimal: minimal)
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, compact ? 8 : 12)

            HStack {
                sectionLabel(copy.text("AGENTS"))
                Spacer()
                Button(copy.text("MANAGE")) {
                    showingAdapterManager = true
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .help(copy.text("Manage adapter manifests"))
                Spacer()
                    .frame(width: 12)
            }

            ZStack(alignment: .topLeading) {
                agentRail(compact: compact)
                VStack(spacing: compact ? 2 : 4) {
                    ForEach(relay.agents) { agent in
                        AgentRow(
                            agent: agent,
                            activity: ThreadCatalog.activity(relay.tasks, agentID: agent.id),
                            selected: terminals.sessions.contains { $0.agentID == agent.id },
                            terminalCount: terminals.sessions.filter { $0.agentID == agent.id }.count,
                            compact: compact,
                            onStartDialogue: { openDialogue(preferredA: agent.id) }
                        ) {
                            openTerminal(agent: agent)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 8)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)
                .padding(.vertical, 8)

            sectionLabel(copy.text("LINK"))
            linkActions
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 6)
            approvalsBanner
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)
                .padding(.vertical, 8)

            HStack {
                sectionLabel(copy.text("WINDOWS"))
                if terminals.sessions.contains(where: { !$0.exited }) {
                    Button {
                        animateWorkspaceChange { terminals.togglePromptStaging() }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: terminals.promptReviewPlan == nil
                                ? "tray.and.arrow.down"
                                : "tray.full.fill")
                            if terminals.promptReviewPlan != nil {
                                if terminals.promptReviewPendingCount > 0 {
                                    Text("\(terminals.promptReviewPendingCount)")
                                        .monospacedDigit()
                                } else {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .frame(minWidth: 16)
                        .frame(height: 16)
                    }
                    .buttonStyle(ConsoleButtonStyle(
                        tint: terminals.promptStagingVisible
                            ? RelayPalette.mix
                            : terminals.promptReviewPlan == nil
                                ? RelayPalette.muted : RelayPalette.warning
                    ))
                    .disabled(
                        terminals.contextRelayDraft != nil
                            || terminals.resultConfluence != nil
                    )
                    .help(promptStagingControlHelp)
                    .accessibilityLabel(promptStagingControlHelp)
                }
                terminalAttentionRouter
                terminalAttentionReturn
                Spacer()
                if terminals.sessions.isEmpty, terminals.restorableDesk != nil {
                    Button(copy.text("RESTORE")) {
                        restoreDesk()
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                    .help(copy.text("Restore the previous CLI desk"))
                }
                if !unmountedGroups.isEmpty {
                    Menu {
                        ForEach(unmountedGroups, id: \.id) { group in
                            Button(groupLabel(group)) {
                                remountGroup(group)
                            }
                        }
                    } label: {
                        Text("↺")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
                    .help(copy.text("Remount daemon compare/chain groups as windows"))
                }
                if terminals.zOrder.count > 1 {
                    Button(copy.text("TILE")) {
                        animateWorkspaceChange { terminals.arrangeAll() }
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    .help(copy.text("Arrange all windows in a grid"))
                }
                Text("\(terminals.zOrder.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .padding(.trailing, 18)
            }

            projectHistorySection

            if let noticeKey = terminals.noticeKey {
                Text(copy.text(noticeKey))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
            }

            if terminals.zOrder.isEmpty {
                if minimal {
                    Text("└─ \(copy.text("NO WINDOWS"))")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("┌─ \(copy.text("NO WINDOWS"))")
                        Text("│ \(copy.text("Click an agent on the left"))")
                        Text("│ \(copy.text("to open its real CLI here"))")
                        Text("└─ \(copy.text("or use the LINK buttons above"))")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .padding(18)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(terminals.sessions) { session in
                            RelayTerminalSidebarRow(
                                session: session,
                                focused: terminals.focusedID == session.id,
                                needsReview: terminals.needsOutputReview(session.id),
                                onClose: { terminals.close(session) },
                                onZoom: {
                                    animateWorkspaceChange { terminals.toggleZoom(session.id) }
                                }
                            )
                        }
                        ForEach(terminals.dialogues) { run in
                            RelayDialogueSidebarRow(
                                run: run,
                                agents: relay.agents,
                                focused: terminals.focusedID == run.id,
                                onFocus: { terminals.activate(run.id) },
                                onClose: { terminals.closeDialogue(run) },
                                onZoom: {
                                    animateWorkspaceChange { terminals.toggleZoom(run.id) }
                                }
                            )
                        }
                        ForEach(terminals.compares) { run in
                            CompareSidebarRow(
                                run: run,
                                agents: relay.agents,
                                focused: terminals.focusedID == run.id,
                                onFocus: { terminals.activate(run.id) },
                                onClose: { terminals.closeCompare(run) },
                                onZoom: {
                                    animateWorkspaceChange { terminals.toggleZoom(run.id) }
                                }
                            )
                        }
                        ForEach(terminals.chains) { run in
                            ChainSidebarRow(
                                run: run,
                                agents: relay.agents,
                                focused: terminals.focusedID == run.id,
                                onFocus: { terminals.activate(run.id) },
                                onClose: { terminals.closeChain(run) },
                                onZoom: {
                                    animateWorkspaceChange { terminals.toggleZoom(run.id) }
                                }
                            )
                        }
                        ForEach(terminals.threads) { run in
                            ThreadSidebarRow(
                                run: run,
                                agents: relay.agents,
                                focused: terminals.focusedID == run.id,
                                onFocus: { terminals.activate(run.id) },
                                onClose: { terminals.closeThread(run) },
                                onZoom: {
                                    animateWorkspaceChange { terminals.toggleZoom(run.id) }
                                }
                            )
                        }
                        if let panel = terminals.approvalPanel {
                            RelayPanelSidebarRow(
                                glyph: "◇",
                                tint: RelayPalette.warning,
                                title: copy.text("Approvals"),
                                subtitle: pendingInteractionIDs.isEmpty
                                    ? copy.text("No pending approvals.")
                                    : copy.text("⟨N⟩ pending").replacingOccurrences(
                                        of: "⟨N⟩",
                                        with: "\(pendingInteractionIDs.count)"
                                    ),
                                focused: terminals.focusedID == panel.id,
                                closeHelpKey: "Close approvals",
                                onFocus: { terminals.activate(panel.id) },
                                onClose: { terminals.closeApprovals() },
                                onZoom: {
                                    animateWorkspaceChange { terminals.toggleZoom(panel.id) }
                                }
                            )
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

    private func projectDock(compact: Bool, minimal: Bool) -> some View {
        HStack(spacing: 0) {
            Menu {
                Section(copy.text("RECENT PROJECTS")) {
                    ForEach(relay.recentWorkingDirectories, id: \.self) { path in
                        Button {
                            activateProjectDirectory(path)
                        } label: {
                            if path == relay.defaultWorkingDirectory {
                                Label(projectMenuLabel(path), systemImage: "checkmark")
                            } else {
                                Text(projectMenuLabel(path))
                            }
                        }
                    }
                }
                Divider()
                Button(copy.text("Choose project folder…")) {
                    chooseDirectory()
                }
            } label: {
                HStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        Circle()
                            .stroke(RelayPalette.signal.opacity(0.32), lineWidth: 5)
                            .frame(width: 18, height: 18)
                        Circle()
                            .fill(RelayPalette.signal)
                            .frame(width: 6, height: 6)
                        Rectangle()
                            .fill(RelayPalette.signal.opacity(0.38))
                            .frame(width: 2, height: 15)
                            .offset(y: 18)
                    }
                    .frame(width: 46, height: 38)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(projectName(relay.defaultWorkingDirectory))
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(RelayPalette.text)
                            .lineLimit(1)
                        Text(abbreviatedProjectPath(relay.defaultWorkingDirectory))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(RelayPalette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !minimal {
                            Text(copy.text("New windows use this project"))
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .tracking(0.45)
                                .foregroundStyle(RelayPalette.signal.opacity(0.9))
                        }
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(RelayPalette.signal)
                        .padding(.trailing, 7)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(copy.text("Switch project"))
            .accessibilityLabel(copy.text("Switch project"))

            Button {
                openProjectPair()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.split.2x1")
                    Text(copy.text("PAIR"))
                }
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
            .help(copy.text("Open Claude and Codex for this project"))
            .accessibilityLabel(copy.text("Open Claude and Codex for this project"))
        }
        .padding(.vertical, compact ? 5 : 9)
        .padding(.trailing, 9)
        .background(RelayPalette.signal.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.signal.opacity(0.18), lineWidth: 1)
        }
    }

    private func projectName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    private func abbreviatedProjectPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func projectMenuLabel(_ path: String) -> String {
        "\(projectName(path))  ·  \(abbreviatedProjectPath(path))"
    }

    private func activateProjectDirectory(_ path: String) {
        if reduceMotion {
            relay.activateProjectDirectory(path)
        } else {
            withAnimation(RelayPalette.selectSpring) {
                relay.activateProjectDirectory(path)
            }
        }
    }

    private func openProjectPair() {
        let shouldTile = terminals.openProjectPair(
            agents: relay.agents,
            cwd: relay.defaultWorkingDirectory
        ) { agent, key in
            agent.options.first { $0.key == key }.map {
                relay.agentOptionValue(agentID: agent.id, option: $0)
            }
        }
        if shouldTile {
            animateWorkspaceChange { terminals.arrangeAll() }
        }
    }

    private func terminalAttentionHelp(_ attention: RelayTerminalAttention) -> String {
        let key = switch attention.kind {
        case .promptReview:
            "Next action: review a staged prompt · ⟨N⟩ pending · ⌥⌘J"
        case .pendingOutput:
            "Next action: review unseen output · ⟨N⟩ pending · ⌥⌘J"
        case .activeOutput:
            "Focus latest terminal output · ⌥⌘J"
        }
        return copy.text(key)
            .replacingOccurrences(of: "⟨N⟩", with: "\(attention.count)")
    }

    private var terminalAttentionRouter: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            if let attention = terminals.nextAttention(at: context.date) {
                let icon = switch attention.kind {
                case .promptReview: "checkmark.circle.fill"
                case .pendingOutput: "eye.fill"
                case .activeOutput: "waveform.path"
                }
                let tint = switch attention.kind {
                case .promptReview: RelayPalette.mix
                case .pendingOutput: RelayPalette.warning
                case .activeOutput: RelayPalette.signal
                }
                Button {
                    animateWorkspaceChange {
                        terminals.focusNextAttention(at: context.date)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                        Text(attention.kind == .activeOutput
                            ? "\(copy.text("OUTPUT")) \(attention.count)"
                            : "\(copy.text("NEXT")) \(attention.count)")
                    }
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                }
                .buttonStyle(ConsoleButtonStyle(tint: tint))
                .keyboardShortcut("j", modifiers: [.command, .option])
                .help(terminalAttentionHelp(attention))
                .accessibilityLabel(terminalAttentionHelp(attention))
                .accessibilityValue("\(attention.count)")
            }
        }
        .frame(width: 62)
        .animation(
            reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1),
            value: terminals.attentionPendingCount
        )
    }

    @ViewBuilder
    private var terminalAttentionReturn: some View {
        if let session = terminals.attentionReturnSession {
            Button {
                animateWorkspaceChange {
                    terminals.returnFromAttention()
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                    Text(copy.text("BACK"))
                }
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            }
            .buttonStyle(ConsoleButtonStyle(tint: session.accent))
            .keyboardShortcut("k", modifiers: [.command, .option])
            .help(copy.text("Return to ⟨CLI⟩ · ⌥⌘K")
                .replacingOccurrences(of: "⟨CLI⟩", with: session.agentName))
            .accessibilityLabel(copy.text("Return to ⟨CLI⟩ · ⌥⌘K")
                .replacingOccurrences(of: "⟨CLI⟩", with: session.agentName))
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
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

            HStack(spacing: 6) {
                if !relay.chainTemplates.isEmpty {
                    Menu("▾ \(copy.text("TEMPLATES"))") {
                        ForEach(relay.chainTemplates) { template in
                            Button("\(template.name)  ·  \(template.agents.map(\.localizedUppercase).joined(separator: " › "))") {
                                relay.applyChainTemplate(template)
                            }
                        }
                        Divider()
                        Menu(copy.text("Delete template")) {
                            ForEach(relay.chainTemplates) { template in
                                Button(template.name, role: .destructive) {
                                    relay.deleteChainTemplate(template)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
                    .fixedSize()
                }
                Spacer()
                if relay.chainSequence.count >= 2 {
                    Button(copy.text("SAVE AS TEMPLATE")) {
                        chainTemplateName = ""
                        showingSaveTemplate = true
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.warning))
                }
            }
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(workspaceAccent)
                            .frame(width: 5, height: 5)
                        Text(relay.selectedTask.map { "THREAD ── \($0.shortID) ──▶ \($0.adapterID.uppercased())" }
                             ?? "\(copy.text("NEW THREAD")) ──▶ \(relay.selectedAgent?.name.uppercased() ?? copy.text("unavailable"))")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(RelayPalette.muted.opacity(0.85))
                    }
                    if let task = relay.selectedTask, renamingTaskID == task.id {
                        TextField(copy.text("Thread title"), text: $renameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .focused($renameFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand(perform: cancelRename)
                    } else {
                        Text(relay.selectedTask?.displayTitle ?? copy.text("Local multi-CLI workspace"))
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .tracking(-0.1)
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
                    Button("⫿ \(copy.text("SPLIT"))") {
                        relay.pinSelectedThreadAsPane()
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    .disabled(relay.paneTaskIDs.contains(task.id) || relay.paneTaskIDs.count >= 3)
                    .help(copy.text("Pin this thread as a side pane"))
                    if !task.status.isTerminal {
                        Button(copy.text("CANCEL")) {
                            Task { await relay.cancelSelectedTask() }
                        }
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                    } else {
                        Button(copy.text("EXPORT")) { exportThread(task) }
                            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                            .help(copy.text("Export this thread as Markdown"))
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
                if !isChain, member.status == .completed {
                    Menu("★ PICK") {
                        ForEach(relay.agents.filter(\.isAvailable)) { agent in
                            Button("→ \(agent.name)") {
                                Task {
                                    await relay.promoteCompareMember(member.id, to: agent.id)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
                    .fixedSize()
                    .help(copy.text("Continue from this answer with another agent"))
                }
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

            HStack(alignment: .center, spacing: 11) {
                Text("›")
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        promptFocused ? workspaceAccent : RelayPalette.muted
                    )

                TextField(composerPlaceholder, text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .lineLimit(1...5)
                    .focused($promptFocused)
                    .onSubmit(submit)
                    .disabled(!relay.canSubmit)

                Text(composerModeLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(composerModeColor.opacity(0.9))

                Button(action: submit) {
                    Image(systemName: relay.isSubmitting ? "ellipsis" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(sendEnabled ? RelayPalette.ink : RelayPalette.muted)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(
                                sendEnabled
                                    ? workspaceAccent
                                    : RelayPalette.raised
                            )
                        )
                }
                .buttonStyle(.plain)
                .animation(RelayPalette.pressSpring, value: sendEnabled)
                .disabled(!sendEnabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(RelayPalette.raised.opacity(promptFocused ? 1 : 0.75))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        promptFocused
                            ? workspaceAccent.opacity(0.5)
                            : RelayPalette.line,
                        lineWidth: 1
                    )
            }
            .animation(
                reduceMotion ? nil : RelayPalette.selectSpring,
                value: promptFocused
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(RelayPalette.panel.opacity(0.6))
        }
    }

    private var sendEnabled: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !relay.isSubmitting
            && relay.canSubmit
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
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .tracking(1.7)
            .foregroundStyle(RelayPalette.muted.opacity(0.85))
            .padding(.horizontal, 18)
            .padding(.vertical, 5)
    }

    private func exportThread(_ task: RelayTask) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(task.displayTitle.prefix(40)).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = RelayMarkdown.exportMarkdown(
            task: task,
            output: relay.output,
            copy: copy
        )
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
        } catch {
            relay.errorMessage = error.localizedDescription
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: relay.defaultWorkingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            activateProjectDirectory(url.path)
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

/// First-class link-action button: glyph + label chip used in the sidebar.
struct LinkActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(configuration.isPressed ? RelayPalette.ink : tint)
                .padding(.vertical, 8)
                .background(
                    configuration.isPressed
                        ? tint
                        : tint.opacity(hovering ? 0.18 : 0.08)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(tint.opacity(hovering ? 0.5 : 0.22), lineWidth: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(RelayPalette.pressSpring, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

private struct AgentRow: View {
    @Environment(\.relayLanguage) private var language
    let agent: RelayAgent
    let activity: RelayAgentActivity
    let selected: Bool
    var terminalCount = 0
    var compact = false
    var onStartDialogue: (() -> Void)?
    @State private var hovering = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    if selected {
                        Circle()
                            .fill(agent.accent.opacity(0.4))
                            .frame(width: 30, height: 30)
                            .blur(radius: 12)
                    }
                    RoundedRectangle(cornerRadius: 7)
                        .fill(agent.accent.opacity(0.15))
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(RelayPalette.ink.opacity(0.85))
                        )
                        .frame(width: 28, height: 28)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(agent.accent.opacity(0.45), lineWidth: 1)
                        }
                        .overlay {
                            Text(agent.monogram)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(0.5)
                                .foregroundStyle(agent.accent)
                        }
                    Circle()
                        .fill(agent.health.color)
                        .frame(width: 7, height: 7)
                        .overlay {
                            Circle().stroke(RelayPalette.ink, lineWidth: 1.5)
                        }
                        .offset(x: 2, y: 2)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(agent.health.reason ?? agent.version ?? agent.detail)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                        .lineLimit(1)
                }
                Spacer()
                if hovering, let onStartDialogue, agent.isAvailable {
                    HStack(spacing: 4) {
                        Button {
                            onStartDialogue()
                        } label: {
                            Text("⇄")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                        .help(RelayCopy(language: language).text("Start a dialogue with this agent"))
                        Text("▣")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(agent.accent.opacity(0.8))
                            .help(RelayCopy(language: language).text("Open its CLI terminal"))
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            if terminalCount > 0 {
                                Text("▣\(terminalCount > 1 ? "×\(terminalCount)" : "")")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(agent.accent.opacity(0.85))
                            }
                            Text(RelayCopy(language: language).agentHealth(agent.health))
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(agent.health.color)
                        }
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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 3 : 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected
                    ? agent.accent.opacity(0.13)
                    : hovering ? RelayPalette.hover : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(agent.accent)
                        .frame(width: 2)
                        .padding(.vertical, 9)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(RelayPalette.selectSpring, value: selected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
    @State private var hovering = false

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
                        Text(ThreadCatalog.elapsedLabel(
                            createdAtMilliseconds: task.createdAtMilliseconds,
                            updatedAtMilliseconds: task.updatedAtMilliseconds,
                            isTerminal: task.status.isTerminal,
                            nowMilliseconds: UInt64(Date().timeIntervalSince1970 * 1000)
                        ))
                        .foregroundStyle(RelayPalette.muted.opacity(0.75))
                        Text(RelayCopy(language: language).taskStatus(task.status))
                    }
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected
                    ? RelayPalette.signal.opacity(0.12)
                    : hovering ? RelayPalette.hover : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(RelayPalette.signal)
                        .frame(width: 2)
                        .padding(.vertical, 8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct OutputBlock: View {
    @Environment(\.relayLanguage) private var language
    let item: RelayTaskOutput
    @State private var expanded = false

    private var collapsible: Bool {
        (item.kind == .tool || item.kind == .system)
            && item.text.components(separatedBy: "\n").count > 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if collapsible {
                    Button {
                        expanded.toggle()
                    } label: {
                        Text("\(expanded ? "▾" : "▸") \(RelayCopy(language: language).outputKind(item.kind)) · \(item.text.components(separatedBy: "\n").count)L")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(item.kind.color)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(RelayCopy(language: language).outputKind(item.kind))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(item.kind.color)
                }
                Rectangle()
                    .fill(item.kind.color.opacity(0.25))
                    .frame(height: 1)
                if item.kind == .assistant {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RelayPalette.muted)
                    .help(RelayCopy(language: language).text("Copy this reply"))
                }
            }
            if collapsible, !expanded {
                EmptyView()
            } else if item.kind == .assistant {
                MarkdownBody(text: item.text)
            } else {
                Text(item.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(item.kind.color.opacity(0.65))
                .frame(width: 2)
        }
    }
}

private struct MarkdownBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(RelayMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(paragraph):
                    Text(styled(paragraph))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(RelayPalette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case let .code(language, code):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text(language?.uppercased() ?? "CODE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(RelayPalette.muted)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(code, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(RelayPalette.muted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RelayPalette.raised.opacity(0.7))
                        Text(code)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(RelayPalette.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RelayPalette.panel)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(RelayPalette.line, lineWidth: 1)
                    }
                }
            }
        }
    }

    private func styled(_ paragraph: String) -> AttributedString {
        var lines = AttributedString()
        for (index, line) in paragraph.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                lines += AttributedString("\n")
            }
            if line.hasPrefix("#") {
                var heading = AttributedString(
                    line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                )
                heading.font = .system(size: 13, weight: .bold, design: .monospaced)
                lines += heading
                continue
            }
            if let inline = try? AttributedString(
                markdown: line,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                lines += inline
            } else {
                lines += AttributedString(line)
            }
        }
        return lines
    }
}

struct InteractionGate: View {
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

struct ConsoleButtonStyle: ButtonStyle {
    let tint: Color
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @State private var hovering = false

        private var fillOpacity: Double {
            if configuration.isPressed { return 1 }
            if prominent { return hovering ? 0.28 : 0.18 }
            return hovering ? 0.16 : 0.07
        }

        var body: some View {
            configuration.label
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .tracking(0.4)
                .foregroundStyle(configuration.isPressed ? RelayPalette.ink : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6.5)
                .background(configuration.isPressed ? tint : tint.opacity(fillOpacity))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            tint.opacity(
                                configuration.isPressed
                                    ? 0
                                    : prominent || hovering ? 0.55 : 0.3
                            ),
                            lineWidth: 1
                        )
                }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(RelayPalette.pressSpring, value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

private struct LineCLIEditorContext: Identifiable {
    let agent: RelayAgent
    let configuration: LineCLIConfiguration

    var id: String { agent.id }
}

private struct SecondaryPane: View {
    @EnvironmentObject private var relay: RelayService
    @Environment(\.relayLanguage) private var language
    let task: RelayTask
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var accent: Color {
        relay.agents.first { $0.id == task.adapterID }?.accent ?? RelayPalette.signal
    }

    private var canContinue: Bool {
        task.status.isTerminal && task.sessionID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                Text(task.adapterID.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(accent)
                Text(task.displayTitle)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                StatusTag(status: task.status)
                Button {
                    relay.closePane(task.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .help(copy.text("Close this pane"))
            }
            .padding(.horizontal, 14)
            .padding(.top, 44)
            .padding(.bottom, 10)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(relay.groupOutputs[task.id] ?? []) { item in
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
                                        taskID: task.id,
                                        interaction: interaction,
                                        action: action,
                                        answers: answers
                                    )
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("pane-bottom")
                    }
                    .padding(14)
                }
                .onChange(of: (relay.groupOutputs[task.id] ?? []).count) { _, _ in
                    proxy.scrollTo("pane-bottom", anchor: .bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)

            HStack(spacing: 9) {
                Text("›")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(focused ? accent : RelayPalette.muted)
                TextField(
                    canContinue
                        ? copy.text("Continue this thread…")
                        : task.status.isTerminal
                            ? copy.text("This thread has no resumable session.")
                            : copy.text("The selected task is still running…"),
                    text: $draft
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($focused)
                .disabled(!canContinue)
                .onSubmit {
                    let value = draft
                    draft = ""
                    Task { await relay.continueThread(taskID: task.id, prompt: value) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RelayPalette.panel.opacity(0.6))
        }
        .background(RelayPalette.ink.opacity(0.35))
    }
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
