import SwiftUI

/// Builds the localized prompts that relay one agent's answer to the other.
enum RelayDialogueScript {
    /// - Parameters:
    ///   - turn: 0-based global turn index (A speaks on even turns).
    ///   - includesContext: whether the dialogue framing and topic must be
    ///     restated (first exposure of this thread, or a sessionless agent
    ///     whose thread cannot carry memory between turns).
    static func prompt(
        turn: Int,
        totalTurns: Int,
        topic: String,
        otherName: String,
        previousAnswer: String?,
        includesContext: Bool,
        copy: RelayCopy
    ) -> String {
        var lines: [String] = []
        if includesContext {
            lines.append(
                copy.text("You are in a multi-round dialogue with another AI agent (⟨OTHER⟩).")
                    .replacingOccurrences(of: "⟨OTHER⟩", with: otherName)
            )
            lines.append("\(copy.text("Topic:")) \(topic)")
        }
        if let previousAnswer {
            lines.append(
                copy.text("The other agent (⟨OTHER⟩) said:")
                    .replacingOccurrences(of: "⟨OTHER⟩", with: otherName)
            )
            lines.append(previousAnswer)
        }
        lines.append(copy.text(turn == 0
            ? "Give your opening view in plain text, concise."
            : "Reply directly and continue the dialogue in plain text."))
        if turn >= totalTurns - 2 {
            lines.append(copy.text("This is your final turn — wrap up."))
        }
        lines.append(copy.text("Do not use tools or modify files."))
        return lines.joined(separator: "\n")
    }
}

private enum RelayDialogueTurnError: Error {
    case emptyAnswer
    case taskFailed(String)

    func message(copy: RelayCopy) -> String {
        switch self {
        case .emptyAnswer:
            copy.text("The agent returned no text answer.")
        case .taskFailed(let detail):
            detail.isEmpty ? copy.text("The turn failed.") : detail
        }
    }
}

/// One agent-to-agent dialogue: two daemon-backed threads (one per agent)
/// whose answers are relayed back and forth, turn by turn.
@MainActor
final class RelayDialogueRun: ObservableObject, Identifiable {
    struct Message: Identifiable {
        let id = UUID()
        let agentID: String
        let agentName: String
        let text: String
    }

    enum Phase: Equatable {
        case setup
        case thinking(agentID: String, agentName: String)
        case awaitingApproval(agentID: String, agentName: String)
        case completed
        case stopped
        case failed(String)
    }

    let id = UUID()
    @Published var agentAID: String
    @Published var agentBID: String
    @Published var topic = ""
    @Published var rounds = 2
    @Published private(set) var messages: [Message] = []
    @Published private(set) var phase: Phase = .setup

    private weak var relay: RelayService?
    private var engine: Task<Void, Never>?
    private var threadA: String?
    private var threadB: String?
    private var activeTaskID: String?
    private var activeTopic = ""

    init(relay: RelayService?, agentAID: String, agentBID: String) {
        self.relay = relay
        self.agentAID = agentAID
        self.agentBID = agentBID
    }

    var isRunning: Bool {
        switch phase {
        case .thinking, .awaitingApproval: return true
        default: return false
        }
    }

    func start() {
        guard case .setup = phase else { return }
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, rounds >= 1 else { return }
        activeTopic = trimmed
        let total = rounds * 2
        engine = Task { [weak self] in
            await self?.runTurns(startingAt: 0, totalTurns: total)
        }
    }

    /// One more exchange (one turn per agent) after a completed dialogue.
    func continueOneRound() {
        guard case .completed = phase else { return }
        rounds += 1
        let total = rounds * 2
        engine = Task { [weak self] in
            await self?.runTurns(startingAt: total - 2, totalTurns: total)
        }
    }

    func stop() {
        engine?.cancel()
        engine = nil
        if let activeTaskID {
            let relay = relay
            Task { await relay?.cancelBackgroundTask(activeTaskID) }
        }
        if case .thinking = phase {
            phase = .stopped
        }
    }

    func statusLabel(copy: RelayCopy) -> String {
        switch phase {
        case .setup:
            copy.text("Pick two agents and a topic")
        case .thinking(_, let name):
            copy.text("⟨NAME⟩ is replying…")
                .replacingOccurrences(of: "⟨NAME⟩", with: name)
        case .awaitingApproval(_, let name):
            "\(name) · \(copy.text("Waiting for approval — respond in the approvals window."))"
        case .completed:
            copy.text("Dialogue completed")
        case .stopped:
            copy.text("Stopped")
        case .failed(let message):
            "\(copy.text("Failed:")) \(message)"
        }
    }

    private func runTurns(startingAt: Int, totalTurns: Int) async {
        guard let relay else {
            phase = .failed("relay unavailable")
            return
        }
        let copy = RelayCopy(language: relay.language)
        for turn in startingAt..<totalTurns {
            if Task.isCancelled { return }
            let isA = turn % 2 == 0
            let selfID = isA ? agentAID : agentBID
            let otherID = isA ? agentBID : agentAID
            guard let selfAgent = relay.agents.first(where: { $0.id == selfID }) else {
                phase = .failed(copy.text("This agent's CLI was not found."))
                return
            }
            let otherName = relay.agents.first { $0.id == otherID }?.name ?? otherID
            phase = .thinking(agentID: selfAgent.id, agentName: selfAgent.name)
            let threadID = isA ? threadA : threadB
            let carriesMemory = threadID
                .flatMap { relay.taskSnapshot($0)?.sessionID } != nil
            let prompt = RelayDialogueScript.prompt(
                turn: turn,
                totalTurns: totalTurns,
                topic: activeTopic,
                otherName: otherName,
                previousAnswer: messages.last?.text,
                includesContext: turn < 2 || !carriesMemory,
                copy: copy
            )
            do {
                let answer = try await performTurn(
                    relay: relay,
                    isA: isA,
                    agentID: selfAgent.id,
                    agentName: selfAgent.name,
                    canResume: carriesMemory,
                    prompt: prompt
                )
                guard !Task.isCancelled else { return }
                messages.append(Message(
                    agentID: selfAgent.id,
                    agentName: selfAgent.name,
                    text: answer
                ))
            } catch is CancellationError {
                return
            } catch let error as RelayDialogueTurnError {
                guard !Task.isCancelled else { return }
                phase = .failed(error.message(copy: copy))
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
                return
            }
        }
        phase = .completed
        engine = nil
    }

    private func performTurn(
        relay: RelayService,
        isA: Bool,
        agentID: String,
        agentName: String,
        canResume: Bool,
        prompt: String
    ) async throws -> String {
        let existing = isA ? threadA : threadB
        let taskID: String
        let minTurnCount: UInt32
        if let existing, canResume {
            minTurnCount = (relay.taskSnapshot(existing)?.turnCount ?? 0) + 1
            try await relay.continueDialogueTask(taskID: existing, prompt: prompt)
            taskID = existing
        } else {
            taskID = try await relay.startDialogueTask(agentID: agentID, prompt: prompt)
            if isA { threadA = taskID } else { threadB = taskID }
            minTurnCount = 1
        }
        activeTaskID = taskID
        defer { activeTaskID = nil }
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 600_000_000)
            guard let snapshot = relay.taskSnapshot(taskID) else { continue }
            if snapshot.pendingInteraction != nil {
                if case .awaitingApproval = phase {} else {
                    phase = .awaitingApproval(agentID: agentID, agentName: agentName)
                }
                continue
            }
            if case .awaitingApproval = phase {
                phase = .thinking(agentID: agentID, agentName: agentName)
            }
            guard snapshot.status.isTerminal else { continue }
            if snapshot.status == .completed {
                // Ignore a stale pre-continue snapshot of the previous turn.
                if snapshot.turnCount >= minTurnCount { break }
                continue
            }
            throw RelayDialogueTurnError.taskFailed(snapshot.latestMessage ?? "")
        }
        let output = await relay.outputItems(taskID: taskID)
        let answer = ThreadCatalog.lastTurnAnswer(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw RelayDialogueTurnError.emptyAnswer }
        return answer
    }
}

/// Floating window hosting an agent dialogue: setup form, then the live
/// transcript with the relay status.
struct RelayDialogueWindow: View {
    @ObservedObject var store: RelayTerminalStore
    @ObservedObject var run: RelayDialogueRun
    let agents: [RelayAgent]
    let frame: CGRect
    let canvasSize: CGSize
    let focused: Bool
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var availableAgents: [RelayAgent] {
        agents.filter(\.isAvailable)
    }

    private func agentName(_ id: String) -> String {
        agents.first { $0.id == id }?.name ?? id
    }

    private func agentAccent(_ id: String) -> SwiftUI.Color {
        agents.first { $0.id == id }?.accent ?? RelayPalette.signal
    }

    private var headerTitle: String {
        if case .setup = run.phase {
            return copy.text("Dialogue")
        }
        return "\(agentName(run.agentAID)) ⇄ \(agentName(run.agentBID))"
    }

    var body: some View {
        RelayFloatingWindow(
            store: store,
            windowID: run.id,
            frame: frame,
            canvasSize: canvasSize,
            focused: focused,
            accent: RelayPalette.mix,
            closeHelpKey: "Close dialogue",
            onClose: { store.closeDialogue(run) }
        ) {
            Text("⇄")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.mix)
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
                Button(copy.text("+1 ROUND")) {
                    run.continueOneRound()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.warning))
            }
        } content: {
            if case .setup = run.phase {
                setupForm
            } else {
                transcript
            }
        }
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(copy.text("AGENT DIALOGUE"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(RelayPalette.mix)

            agentPicker(label: "A", selection: $run.agentAID)
            agentPicker(label: "B", selection: $run.agentBID)

            Text(copy.text("Dialogue topic"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            TextField(copy.text("What should they discuss?"), text: $run.topic, axis: .vertical)
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

            HStack(spacing: 10) {
                Text(copy.text("Rounds per agent"))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Text("\(run.rounds)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                Stepper("", value: $run.rounds, in: 1...6)
                    .labelsHidden()
                Spacer()
                Button(copy.text("START")) {
                    run.start()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success))
                .disabled(
                    run.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            Text(copy.text("Each side keeps its own session; replies relay automatically."))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func agentPicker(label: String, selection: Binding<String>) -> some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
                .frame(width: 12, alignment: .leading)
            Circle()
                .fill(agentAccent(selection.wrappedValue))
                .frame(width: 5, height: 5)
            Menu(agentName(selection.wrappedValue)) {
                ForEach(availableAgents) { agent in
                    Button(agent.name) {
                        selection.wrappedValue = agent.id
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: 220)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(run.messages) { message in
                        messageRow(message)
                    }
                    statusRow
                        .id("dialogue-status")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: run.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("dialogue-status", anchor: .bottom)
                }
            }
            .onChange(of: run.phase) { _, _ in
                proxy.scrollTo("dialogue-status", anchor: .bottom)
            }
        }
    }

    private func messageRow(_ message: RelayDialogueRun.Message) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(agentAccent(message.agentID))
                    .frame(width: 5, height: 5)
                Text(message.agentName.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(agentAccent(message.agentID))
            }
            Text(message.text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(agentAccent(message.agentID).opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch run.phase {
        case .setup:
            EmptyView()
        case .thinking(let agentID, _):
            HStack(spacing: 7) {
                Circle()
                    .fill(agentAccent(agentID))
                    .frame(width: 5, height: 5)
                Text(run.statusLabel(copy: copy))
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(RelayPalette.muted)
        case .awaitingApproval:
            Text(run.statusLabel(copy: copy))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.warning)
        case .completed:
            Text(run.statusLabel(copy: copy))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.success)
        case .stopped:
            Text(run.statusLabel(copy: copy))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
        case .failed:
            Text(run.statusLabel(copy: copy))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.danger)
                .textSelection(.enabled)
        }
    }
}

struct RelayDialogueSidebarRow: View {
    @ObservedObject var run: RelayDialogueRun
    let agents: [RelayAgent]
    var focused = false
    let onFocus: () -> Void
    let onClose: () -> Void
    var onZoom: (() -> Void)?
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    private func agentName(_ id: String) -> String {
        agents.first { $0.id == id }?.name ?? id
    }

    private var title: String {
        if case .setup = run.phase {
            return copy.text("Dialogue")
        }
        return "\(agentName(run.agentAID)) ⇄ \(agentName(run.agentBID))"
    }

    var body: some View {
        RelayPanelSidebarRow(
            glyph: "⇄",
            tint: RelayPalette.mix,
            title: title,
            subtitle: run.statusLabel(copy: copy),
            focused: focused,
            closeHelpKey: "Close dialogue",
            onFocus: onFocus,
            onClose: onClose,
            onZoom: onZoom
        )
    }
}
