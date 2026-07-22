import AppKit
import SwiftUI

/// Builds the localized prompts that relay the table's recent messages to
/// the next speaker.
enum RelayDialogueScript {
    /// - Parameters:
    ///   - speakerHasSpoken: whether this participant already made a statement.
    ///   - isFinalRound: the table's last round — ask for a wrap-up.
    ///   - includesContext: restate framing and topic (first exposure of this
    ///     thread, or a sessionless agent that cannot carry memory).
    static func roundtablePrompt(
        speakerHasSpoken: Bool,
        isFinalRound: Bool,
        topic: String,
        otherNames: [String],
        recent: [(name: String, text: String)],
        includesContext: Bool,
        copy: RelayCopy
    ) -> String {
        var lines: [String] = []
        if includesContext {
            if otherNames.count == 1 {
                lines.append(
                    copy.text("You are in a multi-round dialogue with another AI agent (⟨OTHER⟩).")
                        .replacingOccurrences(of: "⟨OTHER⟩", with: otherNames[0])
                )
            } else {
                lines.append(
                    copy.text("You are in a multi-round roundtable with other AI agents (⟨OTHERS⟩).")
                        .replacingOccurrences(
                            of: "⟨OTHERS⟩",
                            with: otherNames.joined(separator: " / ")
                        )
                )
            }
            lines.append("\(copy.text("Topic:")) \(topic)")
        }
        if !recent.isEmpty {
            lines.append(copy.text("Since your last turn, the others said:"))
            lines.append(
                recent.map { "【\($0.name)】\n\($0.text)" }.joined(separator: "\n\n")
            )
        }
        lines.append(copy.text(speakerHasSpoken
            ? "Reply directly and continue the dialogue in plain text."
            : "Give your opening view in plain text, concise."))
        if isFinalRound {
            lines.append(copy.text("This is your final turn — wrap up."))
        }
        lines.append(copy.text(
            "You may use tools, including web search. Treat local files and content as read-only; do not modify them."
        ))
        return lines.joined(separator: "\n")
    }
}

/// Pure Markdown builder for roundtable minutes.
enum RelayDialogueTranscript {
    static func markdown(
        topic: String,
        participantNames: [String],
        rounds: Int,
        statusLine: String,
        messages: [(speaker: String, isModerator: Bool, text: String)],
        generatedAt: Date,
        copy: RelayCopy
    ) -> String {
        var lines: [String] = []
        lines.append("# \(copy.text("Roundtable minutes")): \(topic)")
        lines.append("")
        lines.append("- \(copy.text("PARTICIPANT")): \(participantNames.joined(separator: " ⇄ "))")
        lines.append("- \(copy.text("Rounds per agent")): \(rounds) · \(statusLine)")
        lines.append("- \(generatedAt.formatted(date: .abbreviated, time: .shortened))")
        lines.append("")
        lines.append("## \(copy.text("Transcript"))")
        for (index, message) in messages.enumerated() {
            lines.append("")
            if message.isModerator {
                lines.append("> **\(message.speaker)**：\(message.text)")
            } else {
                lines.append("### \(index + 1) · \(message.speaker)")
                lines.append("")
                lines.append(message.text)
            }
        }
        lines.append("")
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

/// A roundtable of 2–4 agents: each participant keeps its own daemon-backed
/// thread; speakers take turns in seat order and receive everything said
/// since their previous turn.
@MainActor
final class RelayDialogueRun: ObservableObject, Identifiable {
    struct Message: Identifiable {
        let id = UUID()
        let participantIndex: Int
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

    static let maxParticipants = 4
    /// Seat index used for the human moderator's interjections.
    static let moderatorIndex = -1

    let id = UUID()
    @Published var participants: [String]
    @Published var topic = ""
    @Published var rounds = 2
    @Published private(set) var messages: [Message] = []
    @Published private(set) var phase: Phase = .setup
    /// Moderator messages queued while a round is running; sent in order.
    @Published private(set) var queuedModeratorMessages: [String] = []
    private var queuedModeratorName = ""

    private weak var relay: RelayService?
    private var engine: Task<Void, Never>?
    /// Participant seat index → daemon task ID.
    private var threads: [Int: String] = [:]
    private var activeTaskID: String?
    private var activeTopic = ""

    init(relay: RelayService?, participants: [String]) {
        self.relay = relay
        self.participants = participants
    }

    var isRunning: Bool {
        switch phase {
        case .thinking, .awaitingApproval: return true
        default: return false
        }
    }

    func addParticipant(_ agentID: String) {
        guard case .setup = phase,
              participants.count < Self.maxParticipants else { return }
        participants.append(agentID)
    }

    func removeLastParticipant() {
        guard case .setup = phase, participants.count > 0 else { return }
        _ = participants.popLast()
    }

    func start() {
        guard case .setup = phase else { return }
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, rounds >= 1, participants.count >= 2 else { return }
        activeTopic = trimmed
        let total = rounds * participants.count
        engine = Task { [weak self] in
            await self?.runTurns(startingAt: 0, totalTurns: total)
        }
    }

    /// Queues or sends a moderator message: immediate when the table is
    /// idle, queued (FIFO) while a round is still running.
    func submitModerator(message: String, moderatorName: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .completed = phase, queuedModeratorMessages.isEmpty {
            continueRound(moderatorMessage: trimmed, moderatorName: moderatorName)
        } else if isRunning || phase == .completed {
            queuedModeratorMessages.append(trimmed)
            queuedModeratorName = moderatorName
        }
    }

    func clearQueuedModeratorMessages() {
        queuedModeratorMessages.removeAll()
    }

    private func drainModeratorQueueIfNeeded() {
        guard case .completed = phase, !queuedModeratorMessages.isEmpty else { return }
        let next = queuedModeratorMessages.removeFirst()
        continueRound(moderatorMessage: next, moderatorName: queuedModeratorName)
    }

    /// The moderator (you) speaks into the table; every participant sees the
    /// message in their next-turn digest, then one more round runs.
    func continueRound(moderatorMessage: String, moderatorName: String) {
        guard case .completed = phase else { return }
        let trimmed = moderatorMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(Message(
            participantIndex: Self.moderatorIndex,
            agentID: "moderator",
            agentName: moderatorName,
            text: trimmed
        ))
        continueOneRound()
    }

    /// One more full round (one turn per participant) after completion.
    func continueOneRound() {
        guard case .completed = phase else { return }
        rounds += 1
        let total = rounds * participants.count
        let count = participants.count
        engine = Task { [weak self] in
            await self?.runTurns(startingAt: total - count, totalTurns: total)
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
            copy.text("Pick 2–4 agents and a topic")
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

    /// Each seat's final message as a confluence snapshot (bridge to arbitration).
    func resultSnapshots() -> [RelayResultSnapshot] {
        participants.indices.compactMap { index in
            guard let last = messages.last(where: { $0.participantIndex == index }) else {
                return nil
            }
            let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RelayResultSnapshot(
                id: UUID(),
                agentName: last.agentName,
                projectName: RelayTerminalContext.projectName(
                    RelayTerminalLauncher.resolvedWorkingDirectory(
                        relay?.workingDirectory
                            ?? FileManager.default.homeDirectoryForCurrentUser.path
                    )
                ),
                text: text
            )
        }
    }

    private func runTurns(startingAt: Int, totalTurns: Int) async {
        guard let relay else {
            phase = .failed("relay unavailable")
            return
        }
        let copy = RelayCopy(language: relay.language)
        let seats = participants
        let count = seats.count
        guard count >= 2 else { return }
        for turn in startingAt..<totalTurns {
            if Task.isCancelled { return }
            let seat = turn % count
            let selfID = seats[seat]
            guard let member = relay.resolveMember(selfID) else {
                phase = .failed(copy.text("This agent's CLI was not found."))
                return
            }
            let otherNames = seats.indices
                .filter { $0 != seat }
                .map { index in
                    relay.resolveMember(seats[index])?.displayName ?? seats[index]
                }
            phase = .thinking(agentID: member.agentID, agentName: member.displayName)
            let threadID = threads[seat]
            let carriesMemory = threadID
                .flatMap { relay.taskSnapshot($0)?.sessionID } != nil
            let lastOwnMessage = messages.lastIndex { $0.participantIndex == seat }
            let recentStart = lastOwnMessage.map { $0 + 1 } ?? 0
            let recent = messages[recentStart...].map { ($0.agentName, $0.text) }
            let prompt = RelayPersonaStore.applyRules(
                member.rules,
                to: RelayDialogueScript.roundtablePrompt(
                    speakerHasSpoken: lastOwnMessage != nil,
                    isFinalRound: turn >= totalTurns - count,
                    topic: activeTopic,
                    otherNames: otherNames,
                    recent: Array(recent),
                    includesContext: threadID == nil || !carriesMemory,
                    copy: copy
                )
            )
            do {
                let answer = try await performTurn(
                    relay: relay,
                    seat: seat,
                    agentID: member.agentID,
                    agentName: member.displayName,
                    canResume: carriesMemory,
                    prompt: prompt,
                    optionOverrides: member.optionOverrides
                )
                guard !Task.isCancelled else { return }
                messages.append(Message(
                    participantIndex: seat,
                    agentID: member.agentID,
                    agentName: member.displayName,
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
        drainModeratorQueueIfNeeded()
    }

    private func performTurn(
        relay: RelayService,
        seat: Int,
        agentID: String,
        agentName: String,
        canResume: Bool,
        prompt: String,
        optionOverrides: [String: String] = [:]
    ) async throws -> String {
        let existing = threads[seat]
        let taskID: String
        let minTurnCount: UInt32
        if let existing, canResume {
            minTurnCount = (relay.taskSnapshot(existing)?.turnCount ?? 0) + 1
            try await relay.continueDialogueTask(
                taskID: existing, prompt: prompt, optionOverrides: optionOverrides
            )
            taskID = existing
        } else {
            taskID = try await relay.startDialogueTask(
                agentID: agentID, prompt: prompt, optionOverrides: optionOverrides
            )
            threads[seat] = taskID
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

/// Floating window hosting an agent roundtable: setup form, then the live
/// transcript with the relay status.
struct RelayDialogueWindow: View {
    @ObservedObject var store: RelayTerminalStore
    @ObservedObject var run: RelayDialogueRun
    let agents: [RelayAgent]
    var personas: [RelayPersona] = []
    let frame: CGRect
    let canvasSize: CGSize
    let focused: Bool
    @State private var moderatorDraft = ""
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var availableAgents: [RelayAgent] {
        agents.filter(\.isAvailable)
    }

    /// Personas whose underlying agent is currently available.
    private var availablePersonas: [RelayPersona] {
        personas.filter { persona in
            agents.first { $0.id == persona.agentID }?.isAvailable == true
        }
    }

    private func agentName(_ id: String) -> String {
        if let personaID = RelayPersonaStore.personaID(fromMember: id) {
            return personas.first { $0.id == personaID }?.name ?? id
        }
        return agents.first { $0.id == id }?.name ?? id
    }

    private func agentAccent(_ id: String) -> SwiftUI.Color {
        let agentID = RelayPersonaStore.personaID(fromMember: id)
            .flatMap { personaID in
                personas.first { $0.id == personaID }?.agentID
            } ?? id
        return agents.first { $0.id == agentID }?.accent ?? RelayPalette.signal
    }

    private var headerTitle: String {
        if case .setup = run.phase {
            return copy.text("Meeting")
        }
        return run.participants.map { agentName($0) }.joined(separator: " ⇄ ")
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
                Button(copy.text("ARBITRATE RESULTS")) {
                    store.presentResultConfluence(snapshots: run.resultSnapshots())
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                .disabled(run.resultSnapshots().count < 2)
                .help(copy.text("Freeze these answers and pick one CLI to arbitrate them"))
                Button(copy.text("FORK TO TERMINALS")) {
                    store.beginContextRelay(
                        results: run.resultSnapshots(),
                        sourceName: copy.text("Meeting"),
                        sourceWindowID: run.id
                    )
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                .disabled(run.resultSnapshots().isEmpty)
                .help(copy.text("Fill these answers into live CLI terminals"))
                Button(copy.text("EXPORT")) {
                    exportTranscript()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .disabled(run.messages.isEmpty)
                .help(copy.text("Save the transcript as a Markdown file"))
            }
        } content: {
            if case .setup = run.phase {
                setupForm
            } else {
                VStack(spacing: 0) {
                    transcript
                    if run.isRunning || run.phase == .completed {
                        moderatorBar
                    }
                }
            }
        }
    }

    private var moderatorBar: some View {
        HStack(spacing: 8) {
            Text("›")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.signal)
            TextField(
                copy.text(run.isRunning
                    ? "Queue the next message — sent automatically when this round finishes…"
                    : "Speak as the moderator — starts one more round…"),
                text: $moderatorDraft,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, design: .monospaced))
            .lineLimit(1...4)
            .onSubmit(sendModeratorMessage)
            if !run.queuedModeratorMessages.isEmpty {
                Button(copy.text("⟨N⟩ queued")
                    .replacingOccurrences(
                        of: "⟨N⟩", with: "\(run.queuedModeratorMessages.count)"
                    )) {
                    run.clearQueuedModeratorMessages()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .help(copy.text("Clear queue"))
            }
            Button(copy.text("SEND")) {
                sendModeratorMessage()
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            .disabled(
                moderatorDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RelayPalette.raised.opacity(0.55))
    }

    private func exportTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        let topic = run.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.nameFieldStringValue =
            "\(copy.text("Roundtable minutes"))-\(topic.prefix(24)).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let markdown = RelayDialogueTranscript.markdown(
            topic: topic,
            participantNames: run.participants.map { agentName($0) },
            rounds: run.rounds,
            statusLine: run.statusLabel(copy: copy),
            messages: run.messages.map {
                ($0.agentName, $0.participantIndex == RelayDialogueRun.moderatorIndex, $0.text)
            },
            generatedAt: Date(),
            copy: copy
        )
        try? Data(markdown.utf8).write(to: url, options: .atomic)
    }

    private func sendModeratorMessage() {
        let text = moderatorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        moderatorDraft = ""
        run.submitModerator(
            message: text,
            moderatorName: copy.text("Moderator")
        )
    }

    private var setupForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(copy.text("AGENT DIALOGUE"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(RelayPalette.mix)

            HStack(spacing: 6) {
                if run.participants.isEmpty {
                    Text(copy.text("Add 2–4 participants in speaking order"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(
                                Array(run.participants.enumerated()), id: \.offset
                            ) { index, id in
                                if index > 0 {
                                    Text("⇄")
                                        .foregroundStyle(RelayPalette.mix)
                                }
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(agentAccent(id))
                                        .frame(width: 4, height: 4)
                                    Text("\(index + 1) \(agentName(id).uppercased())")
                                        .fixedSize()
                                }
                            }
                        }
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    }
                }
            }

            HStack(spacing: 6) {
                Menu("+ \(copy.text("PARTICIPANT"))") {
                    ForEach(availableAgents) { agent in
                        Button(agent.name) {
                            run.addParticipant(agent.id)
                        }
                    }
                    if !availablePersonas.isEmpty {
                        Divider()
                        ForEach(availablePersonas) { persona in
                            Button("☰ \(persona.name)") {
                                run.addParticipant(
                                    RelayPersonaStore.memberID(for: persona)
                                )
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.mix)
                .fixedSize()
                .disabled(run.participants.count >= RelayDialogueRun.maxParticipants)
                Button(copy.text("UNDO")) {
                    run.removeLastParticipant()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                .disabled(run.participants.isEmpty)
                Spacer()
            }

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
                    run.participants.count < 2
                        || run.topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            Text(copy.text("Everyone keeps their own session; turns go around the table."))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            return copy.text("Meeting")
        }
        return run.participants.map { agentName($0) }.joined(separator: " ⇄ ")
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
