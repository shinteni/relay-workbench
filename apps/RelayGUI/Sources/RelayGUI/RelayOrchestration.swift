import SwiftUI

/// Send one prompt to several agents at once and watch the answers side by
/// side (the old COMPARE mode as a floating window).
@MainActor
final class RelayCompareRun: ObservableObject, Identifiable {
    struct Member: Identifiable {
        let id: String
        let agentID: String
        let agentName: String
        var worktreePath: String?
        var baseCommit: String?
    }

    enum Phase: Equatable {
        case setup, running, completed, stopped, failed(String)
    }

    let id = UUID()
    @Published var selection: [String]
    @Published var prompt = ""
    /// Run every member in its own detached git worktree (parallel
    /// implementation without file stomping).
    @Published var isolateWorktrees = false
    @Published private(set) var setupHint: String?
    @Published private(set) var diffStats: [String: String] = [:]
    @Published private(set) var adoptMessages: [String: String] = [:]
    private var statFetched: Set<String> = []
    private var lastStatFetch: [String: Date] = [:]
    @Published private(set) var members: [Member] = []
    @Published private(set) var statuses: [String: RelayTaskStatus] = [:]
    @Published private(set) var outputs: [String: [RelayTaskOutput]] = [:]
    /// Members currently waiting in USER GATE (answered in the approvals window).
    @Published private(set) var approvalWaiting: Set<String> = []
    @Published private(set) var phase: Phase = .setup

    private weak var relay: RelayService?
    private var engine: Task<Void, Never>?
    private var relayCWD: String?
    private(set) var groupID: String?

    init(relay: RelayService?, preselected: [String]) {
        self.relay = relay
        self.selection = preselected
    }

    var isRunning: Bool { phase == .running }

    func toggle(_ agentID: String) {
        guard case .setup = phase else { return }
        if let index = selection.firstIndex(of: agentID) {
            selection.remove(at: index)
        } else if selection.count < 4 {
            selection.append(agentID)
        }
    }

    func start() {
        guard case .setup = phase, let relay else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = selection.compactMap { id in
            relay.agents.first { $0.id == id && $0.isAvailable }
        }
        guard !trimmed.isEmpty, chosen.count >= 2 else { return }
        phase = .running
        engine = Task { [weak self] in
            await self?.run(chosen: chosen, prompt: trimmed)
        }
    }

    func stop() {
        engine?.cancel()
        engine = nil
        if case .running = phase {
            let ids = members.map(\.id)
            let relay = relay
            Task {
                for id in ids {
                    await relay?.cancelBackgroundTask(id)
                }
            }
            phase = .stopped
        }
    }

    /// Called when the window closes: stop, release caches, drop worktrees.
    func close() {
        stop()
        relay?.unpinOutputs(members.map(\.id))
        if let project = relayCWD {
            let resolved = RelayTerminalLauncher.resolvedWorkingDirectory(project)
            let paths = members.compactMap(\.worktreePath)
            Task.detached {
                for path in paths {
                    await RelayWorktree.remove(project: resolved, worktree: path)
                }
            }
        }
    }

    /// Applies one member's worktree changes back onto the project.
    func adoptChanges(of memberID: String) {
        guard let relay,
              let member = members.first(where: { $0.id == memberID }),
              let worktree = member.worktreePath,
              let base = member.baseCommit,
              let project = relayCWD else { return }
        let copy = RelayCopy(language: relay.language)
        adoptMessages[memberID] = copy.text("Applying…")
        let resolved = RelayTerminalLauncher.resolvedWorkingDirectory(project)
        Task { [weak self] in
            do {
                let stat = try await RelayWorktree.adopt(
                    worktree: worktree, base: base, into: resolved
                )
                self?.adoptMessages[memberID] = stat.isEmpty
                    ? copy.text("No changes to adopt.")
                    : copy.text("Adopted into the project: ⟨STAT⟩")
                        .replacingOccurrences(of: "⟨STAT⟩", with: stat)
            } catch {
                self?.adoptMessages[memberID] =
                    "\(copy.text("Failed:")) \(error.localizedDescription)"
            }
        }
    }

    func statusLabel(copy: RelayCopy) -> String {
        switch phase {
        case .setup:
            copy.text("Pick agents and a prompt")
        case .running:
            copy.text("Running in parallel…")
        case .completed:
            copy.text("All members finished")
        case .stopped:
            copy.text("Stopped")
        case .failed(let message):
            "\(copy.text("Failed:")) \(message)"
        }
    }


    /// Structured answers as confluence snapshots (bridge to arbitration).
    func resultSnapshots() -> [RelayResultSnapshot] {
        members.compactMap { member in
            let answer = ThreadCatalog.lastTurnAnswer(outputs[member.id] ?? [])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return nil }
            return RelayResultSnapshot(
                id: UUID(),
                agentName: member.agentName,
                projectName: RelayTerminalContext.projectName(
                    RelayTerminalLauncher.resolvedWorkingDirectory(
                        relayCWD ?? FileManager.default.homeDirectoryForCurrentUser.path
                    )
                ),
                text: answer
            )
        }
    }

    /// Re-mounts a window onto an existing daemon compare group
    /// (e.g. after a GUI restart). Watching resumes; nothing is re-sent.
    static func attached(
        relay: RelayService, group: String, tasks: [RelayTask]
    ) -> RelayCompareRun {
        let run = RelayCompareRun(relay: relay, preselected: [])
        run.groupID = group
        run.relayCWD = tasks.first?.cwd
        run.members = tasks.map { task in
            Member(
                id: task.id,
                agentID: task.adapterID,
                agentName: relay.agents.first { $0.id == task.adapterID }?.name
                    ?? task.adapterID
            )
        }
        run.phase = .running
        relay.pinOutputs(run.members.map(\.id))
        run.engine = Task { [weak run] in
            guard let run, let relay = run.relay else { return }
            await run.watch(relay: relay)
            guard !Task.isCancelled else { return }
            if case .running = run.phase { run.phase = .completed }
        }
        return run
    }

    private func run(chosen: [RelayAgent], prompt: String) async {
        guard let relay else { return }
        relayCWD = relay.defaultWorkingDirectory
        let copy = RelayCopy(language: relay.language)
        let project = RelayTerminalLauncher.resolvedWorkingDirectory(
            relay.defaultWorkingDirectory
        )
        if isolateWorktrees {
            guard await RelayWorktree.isGitRepo(project) else {
                setupHint = copy.text("The current project is not a git repository — worktree isolation is unavailable.")
                phase = .setup
                return
            }
        }
        setupHint = nil
        let group = UUID().uuidString.lowercased()
        groupID = group
        var created: [Member] = []
        var startFailure: String?
        for (index, agent) in chosen.enumerated() {
            do {
                var worktreePath: String?
                var baseCommit: String?
                var overrideCWD: String?
                if isolateWorktrees {
                    let destination = RelayWorktree.worktreeRoot
                        .appendingPathComponent(
                            String(id.uuidString.prefix(8)), isDirectory: true
                        )
                        .appendingPathComponent(
                            "\(index + 1)-\(agent.id)", isDirectory: true
                        )
                    baseCommit = try await RelayWorktree.create(
                        project: project, destination: destination
                    )
                    worktreePath = destination.path
                    overrideCWD = destination.path
                }
                let taskID = try await relay.startGroupTask(
                    agentID: agent.id, prompt: prompt, group: group,
                    cwd: overrideCWD
                )
                created.append(Member(
                    id: taskID, agentID: agent.id, agentName: agent.name,
                    worktreePath: worktreePath, baseCommit: baseCommit
                ))
                members = created
            } catch {
                startFailure = error.localizedDescription
                break
            }
        }
        guard !created.isEmpty else {
            phase = .failed(startFailure ?? "start failed")
            return
        }
        relay.pinOutputs(created.map(\.id))
        await watch(relay: relay)
        guard !Task.isCancelled else { return }
        if let startFailure {
            phase = .failed(startFailure)
        } else if case .running = phase {
            phase = .completed
        }
    }

    private func watch(relay: RelayService) async {
        while !Task.isCancelled {
            var allTerminal = true
            for member in members {
                guard let snapshot = relay.taskSnapshot(member.id) else {
                    allTerminal = false
                    continue
                }
                statuses[member.id] = snapshot.status
                if snapshot.pendingInteraction != nil {
                    approvalWaiting.insert(member.id)
                } else {
                    approvalWaiting.remove(member.id)
                }
                await relay.refreshMemberOutput(taskID: member.id)
                outputs[member.id] = relay.groupOutputs[member.id] ?? []
                if !snapshot.status.isTerminal {
                    allTerminal = false
                    // Live scoreboard: refresh the running member's diffstat
                    // every few seconds so parallel work is visible as it lands.
                    if let worktree = member.worktreePath,
                       let base = member.baseCommit,
                       lastStatFetch[member.id].map({
                           Date().timeIntervalSince($0) > 2.5
                       }) ?? true {
                        lastStatFetch[member.id] = Date()
                        diffStats[member.id] = await RelayWorktree.shortStat(
                            worktree: worktree, base: base
                        )
                    }
                } else if let worktree = member.worktreePath,
                          let base = member.baseCommit,
                          !statFetched.contains(member.id) {
                    statFetched.insert(member.id)
                    diffStats[member.id] = await RelayWorktree.shortStat(
                        worktree: worktree, base: base
                    )
                }
            }
            if allTerminal, !members.isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }
}

/// A daemon-scheduled chain (the old CHAIN mode as a floating window): the
/// prompt runs through the steps in order, each step receiving the previous
/// answer; progression survives GUI restarts.
@MainActor
final class RelayChainRun: ObservableObject, Identifiable {
    struct Step: Identifiable {
        let id: String
        let index: Int
        let agentID: String
        var status: RelayTaskStatus
    }

    enum Phase: Equatable {
        case setup, running, completed, stopped, failed(String)
    }

    let id = UUID()
    @Published var sequence: [String]
    @Published var prompt = ""
    @Published var note = ""
    /// Follow-ups queued while a round is still running; sent automatically.
    @Published private(set) var queuedFollowUps: [String] = []
    @Published private(set) var steps: [Step] = []
    @Published private(set) var outputs: [String: [RelayTaskOutput]] = [:]
    /// Steps currently waiting in USER GATE (answered in the approvals window).
    @Published private(set) var approvalWaiting: Set<String> = []
    @Published private(set) var phase: Phase = .setup

    private weak var relay: RelayService?
    private var engine: Task<Void, Never>?
    private(set) var chainID: String?
    private var pinned: Set<String> = []

    init(relay: RelayService?, preselected: [String]) {
        self.relay = relay
        self.sequence = preselected
    }

    var isRunning: Bool { phase == .running }

    func append(_ agentID: String) {
        guard case .setup = phase, sequence.count < 4 else { return }
        sequence.append(agentID)
    }

    func removeLastStep() {
        guard case .setup = phase else { return }
        _ = sequence.popLast()
    }

    func clearSteps() {
        guard case .setup = phase else { return }
        sequence.removeAll()
    }

    func start() {
        guard case .setup = phase, let relay else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sequence.count >= 2 else { return }
        phase = .running
        let sequence = sequence
        let note = note
        engine = Task { [weak self] in
            guard let self else { return }
            do {
                self.chainID = try await relay.startChainRun(
                    sequence: sequence, prompt: trimmed, note: note
                )
            } catch {
                self.phase = .failed(error.localizedDescription)
                return
            }
            await self.watch(relay: relay)
        }
    }

    func stop() {
        engine?.cancel()
        engine = nil
        if case .running = phase {
            let ids = steps.filter { !$0.status.isTerminal }.map(\.id)
            let relay = relay
            Task {
                for id in ids {
                    await relay?.cancelBackgroundTask(id)
                }
            }
            phase = .stopped
        }
    }

    func close() {
        stop()
        relay?.unpinOutputs(Array(pinned))
    }

    func statusLabel(copy: RelayCopy) -> String {
        switch phase {
        case .setup:
            copy.text("Order the steps and enter a prompt")
        case .running:
            copy.text("Relaying step by step…")
        case .completed:
            copy.text("Chain completed")
        case .stopped:
            copy.text("Stopped")
        case .failed(let message):
            "\(copy.text("Failed:")) \(message)"
        }
    }

    /// Whether every step keeps a resumable session (follow-up rounds need it).
    var canFollowUp: Bool {
        guard let relay, let chainID else { return false }
        let members = relay.tasks.filter { $0.compareGroup == chainID }
        return !members.isEmpty && members.allSatisfy { $0.sessionID != nil }
    }

    /// Queues or sends a follow-up: immediate when the chain is idle,
    /// queued (FIFO) while a round is still running.
    func submitFollowUp(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .completed = phase, queuedFollowUps.isEmpty {
            continueRound(prompt: trimmed)
        } else if isRunning || phase == .completed {
            queuedFollowUps.append(trimmed)
        }
    }

    func clearQueuedFollowUps() {
        queuedFollowUps.removeAll()
    }

    private func drainQueueIfNeeded() {
        guard case .completed = phase, !queuedFollowUps.isEmpty else { return }
        let next = queuedFollowUps.removeFirst()
        continueRound(prompt: next)
    }

    /// Runs one more relay round through the same sequence: your new message
    /// goes to step 1, each later step receives the previous step's answer.
    /// Sessions are continued, so every step keeps its own memory.
    func continueRound(prompt: String) {
        guard case .completed = phase, let relay, let chainID else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canFollowUp else { return }
        let ordered = relay.tasks
            .filter { $0.compareGroup == chainID }
            .sorted { ($0.chainStep ?? 0) < ($1.chainStep ?? 0) }
            .map(\.id)
        phase = .running
        engine = Task { [weak self] in
            await self?.relayRound(memberIDs: ordered, userPrompt: trimmed)
        }
    }

    private func relayRound(memberIDs: [String], userPrompt: String) async {
        guard let relay else { return }
        let copy = RelayCopy(language: relay.language)
        var previousAnswer: String?
        for (index, taskID) in memberIDs.enumerated() {
            if Task.isCancelled { return }
            let stepPrompt: String
            if index == 0 {
                stepPrompt = userPrompt
            } else {
                let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                stepPrompt = (note.isEmpty ? "" : note + "\n")
                    + "基于上一步的输出继续处理：\n\n" + (previousAnswer ?? "")
            }
            do {
                let previousTurns = relay.taskSnapshot(taskID)?.turnCount ?? 0
                try await relay.continueDialogueTask(taskID: taskID, prompt: stepPrompt)
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 700_000_000)
                    guard let snapshot = relay.taskSnapshot(taskID) else { continue }
                    if snapshot.pendingInteraction != nil {
                        approvalWaiting.insert(taskID)
                    } else {
                        approvalWaiting.remove(taskID)
                    }
                    steps = steps.map { step in
                        var step = step
                        if step.id == taskID { step.status = snapshot.status }
                        return step
                    }
                    await relay.refreshMemberOutput(taskID: taskID)
                    outputs[taskID] = relay.groupOutputs[taskID] ?? []
                    guard snapshot.status.isTerminal else { continue }
                    if snapshot.status == .completed {
                        if snapshot.turnCount > previousTurns { break }
                        continue
                    }
                    phase = .failed(
                        snapshot.latestMessage ?? copy.text("The turn failed.")
                    )
                    return
                }
                let answer = ThreadCatalog.lastTurnAnswer(
                    relay.groupOutputs[taskID] ?? []
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else {
                    phase = .failed(copy.text("The agent returned no text answer."))
                    return
                }
                previousAnswer = answer
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
                return
            }
        }
        phase = .completed
        drainQueueIfNeeded()
    }

    /// Re-mounts a window onto an existing daemon chain
    /// (daemon keeps scheduling it; the window is an observer).
    static func attached(
        relay: RelayService, chain: String, tasks: [RelayTask]
    ) -> RelayChainRun {
        let sequence = tasks.first?.chainAgents
            ?? tasks.sorted { ($0.chainStep ?? 0) < ($1.chainStep ?? 0) }
                .map(\.adapterID)
        let run = RelayChainRun(relay: relay, preselected: sequence)
        run.chainID = chain
        run.phase = .running
        run.engine = Task { [weak run] in
            guard let run, let relay = run.relay else { return }
            await run.watch(relay: relay)
        }
        return run
    }

    private func watch(relay: RelayService) async {
        let copy = RelayCopy(language: relay.language)
        while !Task.isCancelled {
            guard let chainID else { return }
            let members = relay.tasks
                .filter { $0.compareGroup == chainID }
                .sorted { ($0.chainStep ?? 0) < ($1.chainStep ?? 0) }
            let fresh = members.map(\.id).filter { !pinned.contains($0) }
            if !fresh.isEmpty {
                pinned.formUnion(fresh)
                relay.pinOutputs(fresh)
            }
            steps = members.map { member in
                Step(
                    id: member.id,
                    index: (member.chainStep ?? 0) + 1,
                    agentID: member.adapterID,
                    status: member.status
                )
            }
            for member in members {
                if member.pendingInteraction != nil {
                    approvalWaiting.insert(member.id)
                } else {
                    approvalWaiting.remove(member.id)
                }
                await relay.refreshMemberOutput(taskID: member.id)
                outputs[member.id] = relay.groupOutputs[member.id] ?? []
            }
            if members.count == sequence.count,
               members.allSatisfy({ $0.status.isTerminal }) {
                if members.allSatisfy({ $0.status == .completed }) {
                    phase = .completed
                    drainQueueIfNeeded()
                } else {
                    let detail = members.first { $0.status != .completed }?
                        .latestMessage ?? ""
                    phase = .failed(
                        detail.isEmpty ? copy.text("The turn failed.") : detail
                    )
                }
                return
            }
            if let halted = members.first(where: {
                $0.status == .failed || $0.status == .canceled
            }) {
                phase = .failed(
                    halted.latestMessage ?? copy.text("The turn failed.")
                )
                return
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }
}

/// Shared plain-text rendering of task output items for orchestration windows.
private struct RelayOutputLines: View {
    let items: [RelayTaskOutput]
    let emptyHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            let visible = items.filter { $0.kind != .user }
            if visible.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
            ForEach(visible) { item in
                if item.kind == .assistant {
                    Text(item.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(RelayPalette.text)
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("· \(item.text)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(
                            item.kind == .error ? RelayPalette.danger : RelayPalette.muted
                        )
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct RelayCompareWindow: View {
    @ObservedObject var store: RelayTerminalStore
    @ObservedObject var run: RelayCompareRun
    let agents: [RelayAgent]
    let frame: CGRect
    let canvasSize: CGSize
    let focused: Bool
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    private func agent(_ id: String) -> RelayAgent? {
        agents.first { $0.id == id }
    }

    private var headerTitle: String {
        if case .setup = run.phase {
            return copy.text("COMPARE")
        }
        return run.members.map(\.agentName).joined(separator: " · ")
    }

    var body: some View {
        RelayFloatingWindow(
            store: store,
            windowID: run.id,
            frame: frame,
            canvasSize: canvasSize,
            focused: focused,
            accent: RelayPalette.signal,
            closeHelpKey: "Close this pane",
            onClose: { store.closeCompare(run) }
        ) {
            Text("⋈")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.signal)
            Text(headerTitle)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
                .lineLimit(1)
        } controls: {
            if run.isRunning {
                Button(copy.text("STOP")) {
                    run.stop()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
            } else if case .completed = run.phase {
                Button(copy.text("ARBITRATE RESULTS")) {
                    store.presentResultConfluence(snapshots: run.resultSnapshots())
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix, prominent: true))
                .disabled(run.resultSnapshots().count < 2)
                .help(copy.text("Freeze these answers and pick one CLI to arbitrate them"))
                Button(copy.text("FORK TO TERMINALS")) {
                    store.beginContextRelay(
                        results: run.resultSnapshots(),
                        sourceName: copy.text("COMPARE"),
                        sourceWindowID: run.id
                    )
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                .disabled(run.resultSnapshots().isEmpty)
                .help(copy.text("Fill these answers into live CLI terminals"))
            }
        } content: {
            if case .setup = run.phase {
                setupForm
            } else {
                columns
            }
        }
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(copy.text("SEND TO SEVERAL AGENTS AT ONCE"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(RelayPalette.signal)

            ForEach(agents.filter(\.isAvailable)) { agent in
                Button {
                    run.toggle(agent.id)
                } label: {
                    HStack(spacing: 8) {
                        Text(run.selection.contains(agent.id) ? "▣" : "☐")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(
                                run.selection.contains(agent.id)
                                    ? RelayPalette.signal : RelayPalette.muted
                            )
                        Circle()
                            .fill(agent.accent)
                            .frame(width: 5, height: 5)
                        Text(agent.name)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(RelayPalette.text)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                run.isolateWorktrees.toggle()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text(run.isolateWorktrees ? "▣" : "☐")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            run.isolateWorktrees ? RelayPalette.success : RelayPalette.muted
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("⎇ \(copy.text("Isolated worktrees (git)"))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(RelayPalette.text)
                        Text(copy.text("Each agent codes in its own copy of the repo; adopt the winning diff afterwards."))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(RelayPalette.muted)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let hint = run.setupHint {
                Text(hint)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
            }

            TextField(copy.text("Prompt sent to every selected agent"), text: $run.prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(2...5)
                .padding(9)
                .background(RelayPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(RelayPalette.line, lineWidth: 1)
                }

            HStack {
                Text(copy.text("Pick 2–4 agents"))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Button(copy.text("START")) {
                    run.start()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success))
                .disabled(
                    run.selection.count < 2
                        || run.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var columns: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 1) {
                ForEach(run.members) { member in
                    memberColumn(member)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)
            Text(run.statusLabel(copy: copy))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
    }

    private var statusColor: SwiftUI.Color {
        switch run.phase {
        case .completed: RelayPalette.success
        case .failed: RelayPalette.danger
        default: RelayPalette.muted
        }
    }

    private func memberColumn(_ member: RelayCompareRun.Member) -> some View {
        let accent = agent(member.agentID)?.accent ?? RelayPalette.signal
        let status = run.statuses[member.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                Text(member.agentName.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(accent)
                Spacer()
                if let status {
                    Text(copy.taskStatus(status))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            status == .completed
                                ? RelayPalette.success
                                : status.isTerminal ? RelayPalette.danger : RelayPalette.signal
                        )
                }
            }
            if run.approvalWaiting.contains(member.id) {
                Text(copy.text("Waiting for approval — respond in the approvals window."))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
            }
            if let worktree = member.worktreePath {
                HStack(spacing: 6) {
                    Text("⎇")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayPalette.success)
                        .help(copy.text("Isolated worktree: ⟨PATH⟩")
                            .replacingOccurrences(of: "⟨PATH⟩", with: worktree))
                    if let stat = run.diffStats[member.id] {
                        Text(stat.isEmpty
                             ? (status?.isTerminal == true
                                ? copy.text("No changes to adopt.")
                                : copy.text("no changes yet"))
                             : stat)
                            .font(.system(size: 8.5, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(
                                stat.isEmpty
                                    ? RelayPalette.muted
                                    : status?.isTerminal == true
                                        ? RelayPalette.success
                                        : RelayPalette.signal
                            )
                            .lineLimit(1)
                    }
                    Spacer()
                    if status?.isTerminal == true,
                       run.diffStats[member.id]?.isEmpty == false,
                       run.adoptMessages[member.id] == nil {
                        Button(copy.text("ADOPT THIS VERSION")) {
                            run.adoptChanges(of: member.id)
                        }
                        .buttonStyle(ConsoleButtonStyle(
                            tint: RelayPalette.success, prominent: true
                        ))
                        .help(copy.text("Apply this worktree's diff onto the project"))
                    }
                }
                if let adopt = run.adoptMessages[member.id] {
                    Text(adopt)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(
                            adopt.hasPrefix(copy.text("Failed:"))
                                ? RelayPalette.danger : RelayPalette.success
                        )
                        .textSelection(.enabled)
                }
            }
            ScrollView {
                RelayOutputLines(
                    items: run.outputs[member.id] ?? [],
                    emptyHint: copy.text("Waiting for adapter output…")
                )
                .padding(.bottom, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RelayPalette.panel.opacity(0.35))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(RelayPalette.line)
                .frame(width: 1)
        }
    }
}

struct RelayChainWindow: View {
    @ObservedObject var store: RelayTerminalStore
    @ObservedObject var run: RelayChainRun
    let agents: [RelayAgent]
    let frame: CGRect
    let canvasSize: CGSize
    let focused: Bool
    @State private var followUpDraft = ""
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    private func agentName(_ id: String) -> String {
        agents.first { $0.id == id }?.name ?? id
    }

    private func agentAccent(_ id: String) -> SwiftUI.Color {
        agents.first { $0.id == id }?.accent ?? RelayPalette.warning
    }

    private var headerTitle: String {
        if case .setup = run.phase {
            return copy.text("CHAIN")
        }
        return run.sequence.map { agentName($0) }.joined(separator: " › ")
    }

    var body: some View {
        RelayFloatingWindow(
            store: store,
            windowID: run.id,
            frame: frame,
            canvasSize: canvasSize,
            focused: focused,
            accent: RelayPalette.warning,
            closeHelpKey: "Close this pane",
            onClose: { store.closeChain(run) }
        ) {
            Text("›")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.warning)
            Text(headerTitle)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
                .lineLimit(1)
        } controls: {
            if run.isRunning {
                Button(copy.text("STOP")) {
                    run.stop()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
            }
        } content: {
            if case .setup = run.phase {
                setupForm
            } else {
                timeline
            }
        }
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(copy.text("RELAY THE ANSWER THROUGH STEPS"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(RelayPalette.warning)

            HStack(spacing: 6) {
                if run.sequence.isEmpty {
                    Text(copy.text("Add steps in execution order"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(Array(run.sequence.enumerated()), id: \.offset) { index, id in
                                if index > 0 {
                                    Text("›")
                                        .foregroundStyle(RelayPalette.warning)
                                }
                                Text("\(index + 1) \(agentName(id).uppercased())")
                                    .fixedSize()
                            }
                        }
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    }
                }
            }

            HStack(spacing: 6) {
                Menu("+ \(copy.text("STEP"))") {
                    ForEach(agents.filter(\.isAvailable)) { agent in
                        Button(agent.name) {
                            run.append(agent.id)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.warning)
                .fixedSize()
                .disabled(run.sequence.count >= 4)
                Button(copy.text("UNDO")) {
                    run.removeLastStep()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .disabled(run.sequence.isEmpty)
                Button(copy.text("CLEAR")) {
                    run.clearSteps()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                .disabled(run.sequence.isEmpty)
                Spacer()
            }

            TextField(copy.text("Prompt for the first step"), text: $run.prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(2...5)
                .padding(9)
                .background(RelayPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(RelayPalette.line, lineWidth: 1)
                }

            TextField(copy.text("Instruction passed between steps (optional)"), text: $run.note)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .padding(8)
                .background(RelayPalette.raised.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Text(copy.text("2–4 steps; runs in the daemon, survives closing the GUI"))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Button(copy.text("START")) {
                    run.start()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success))
                .disabled(
                    run.sequence.count < 2
                        || run.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(run.steps) { step in
                        stepSection(step)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)
            Text(run.statusLabel(copy: copy))
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            if run.isRunning || run.phase == .completed {
                followUpBar
            }
        }
    }

    @ViewBuilder private var followUpBar: some View {
        if run.canFollowUp {
            HStack(spacing: 8) {
                Text("›")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
                TextField(
                    copy.text(run.isRunning
                        ? "Queue the next message — sent automatically when this round finishes…"
                        : "Continue the relay with a new message…"),
                    text: $followUpDraft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1...4)
                .onSubmit(sendFollowUp)
                if !run.queuedFollowUps.isEmpty {
                    Button(copy.text("⟨N⟩ queued")
                        .replacingOccurrences(
                            of: "⟨N⟩", with: "\(run.queuedFollowUps.count)"
                        )) {
                        run.clearQueuedFollowUps()
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    .help(copy.text("Clear queue"))
                }
                Button(copy.text("SEND")) {
                    sendFollowUp()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.warning, prominent: true))
                .disabled(
                    followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RelayPalette.raised.opacity(0.55))
        } else {
            Text(copy.text("A step has no resumable session — follow-up rounds are unavailable."))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
    }

    private func sendFollowUp() {
        let text = followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpDraft = ""
        run.submitFollowUp(text)
    }

    private var statusColor: SwiftUI.Color {
        switch run.phase {
        case .completed: RelayPalette.success
        case .failed: RelayPalette.danger
        default: RelayPalette.muted
        }
    }

    private func stepSection(_ step: RelayChainRun.Step) -> some View {
        let accent = agentAccent(step.agentID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("\(step.index)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                Text(agentName(step.agentID).uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(accent)
                Spacer()
                Text(copy.taskStatus(step.status))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        step.status == .completed
                            ? RelayPalette.success
                            : step.status.isTerminal ? RelayPalette.danger : RelayPalette.signal
                    )
            }
            if run.approvalWaiting.contains(step.id) {
                Text(copy.text("Waiting for approval — respond in the approvals window."))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
            }
            RelayOutputLines(
                items: run.outputs[step.id] ?? [],
                emptyHint: copy.text("Waiting for adapter output…")
            )
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

struct CompareSidebarRow: View {
    @ObservedObject var run: RelayCompareRun
    let agents: [RelayAgent]
    var focused = false
    let onFocus: () -> Void
    let onClose: () -> Void
    var onZoom: (() -> Void)?
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    var body: some View {
        RelayPanelSidebarRow(
            glyph: "⋈",
            tint: RelayPalette.signal,
            title: run.members.isEmpty
                ? copy.text("COMPARE")
                : run.members.map(\.agentName).joined(separator: " · "),
            subtitle: run.statusLabel(copy: copy),
            focused: focused,
            closeHelpKey: "Close this pane",
            onFocus: onFocus,
            onClose: onClose,
            onZoom: onZoom
        )
    }
}

struct ChainSidebarRow: View {
    @ObservedObject var run: RelayChainRun
    let agents: [RelayAgent]
    var focused = false
    let onFocus: () -> Void
    let onClose: () -> Void
    var onZoom: (() -> Void)?
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    var body: some View {
        RelayPanelSidebarRow(
            glyph: "›",
            tint: RelayPalette.warning,
            title: run.sequence.isEmpty
                ? copy.text("CHAIN")
                : run.sequence
                    .map { id in agents.first { $0.id == id }?.name ?? id }
                    .joined(separator: " › "),
            subtitle: run.statusLabel(copy: copy),
            focused: focused,
            closeHelpKey: "Close this pane",
            onFocus: onFocus,
            onClose: onClose,
            onZoom: onZoom
        )
    }
}

/// Sidebar row shared by workspace windows: click focuses/raises,
/// double-click maximizes, the close control appears on hover, and the
/// focused window is tinted with its accent.
struct RelayPanelSidebarRow: View {
    let glyph: String
    let tint: SwiftUI.Color
    let title: String
    let subtitle: String
    var focused = false
    let closeHelpKey: String
    let onFocus: () -> Void
    let onClose: () -> Void
    var onZoom: (() -> Void)?
    @Environment(\.relayLanguage) private var language
    @State private var hovering = false

    private var copy: RelayCopy { RelayCopy(language: language) }

    var body: some View {
        Button(action: onFocus) {
            HStack(spacing: 8) {
                Text(glyph)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RelayPalette.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .help(copy.text(closeHelpKey))
                .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                focused
                    ? tint.opacity(0.10)
                    : hovering ? RelayPalette.hover : SwiftUI.Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) {
                if focused {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tint)
                        .frame(width: 2)
                        .padding(.vertical, 6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onZoom?() }
        )
        .onHover { hovering = $0 }
    }
}
