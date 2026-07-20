import SwiftUI

/// A floating window over one daemon thread — the session-library "open"
/// action for single tasks. It shows the recorded outputs and continues the
/// conversation in place; closing the window never touches the record.
@MainActor
final class RelayThreadRun: ObservableObject, Identifiable {
    let id = UUID()
    let taskID: String
    @Published private(set) var outputs: [RelayTaskOutput] = []
    @Published private(set) var sending = false
    @Published private(set) var errorMessage: String?

    private weak var relay: RelayService?
    private var watcher: Task<Void, Never>?
    private var lastSeenUpdate: UInt64 = 0

    init(relay: RelayService?, taskID: String) {
        self.relay = relay
        self.taskID = taskID
        refresh()
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard let self, let relay = self.relay else { return }
                let updated = relay.taskSnapshot(self.taskID)?
                    .updatedAtMilliseconds ?? 0
                if updated != self.lastSeenUpdate {
                    self.refresh()
                }
            }
        }
    }

    var task: RelayTask? { relay?.taskSnapshot(taskID) }

    var canContinue: Bool {
        guard let task else { return false }
        return task.status.isTerminal && task.sessionID != nil
    }

    func refresh() {
        guard let relay else { return }
        lastSeenUpdate = relay.taskSnapshot(taskID)?.updatedAtMilliseconds ?? 0
        Task { [weak self] in
            guard let self, let relay = self.relay else { return }
            let items = await relay.outputItems(taskID: self.taskID)
            self.outputs = items
        }
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending, let relay else { return }
        sending = true
        errorMessage = nil
        Task { [weak self] in
            guard let self, let relay = self.relay else { return }
            do {
                try await relay.continueDialogueTask(
                    taskID: self.taskID, prompt: trimmed
                )
                self.refresh()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.sending = false
        }
        _ = relay
    }

    func close() {
        watcher?.cancel()
        watcher = nil
    }
}

struct RelayThreadWindow: View {
    @ObservedObject var store: RelayTerminalStore
    @ObservedObject var run: RelayThreadRun
    let agents: [RelayAgent]
    let frame: CGRect
    let canvasSize: CGSize
    let focused: Bool
    @State private var draft = ""
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var accent: SwiftUI.Color {
        agents.first { $0.id == run.task?.adapterID }?.accent ?? RelayPalette.signal
    }

    var body: some View {
        RelayFloatingWindow(
            store: store,
            windowID: run.id,
            frame: frame,
            canvasSize: canvasSize,
            focused: focused,
            accent: accent,
            closeHelpKey: "Close this pane",
            onClose: { store.closeThread(run) }
        ) {
            Text("•")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
            Text(run.task?.displayTitle ?? copy.text("Thread"))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
                .lineLimit(1)
                .truncationMode(.tail)
        } controls: {
            if let task = run.task {
                Text("\(task.adapterID.uppercased()) · \(copy.taskStatus(task.status))")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        task.status == .completed
                            ? RelayPalette.success
                            : task.status.isTerminal
                                ? RelayPalette.danger : RelayPalette.signal
                    )
            }
        } content: {
            VStack(spacing: 0) {
                ScrollView {
                    RelayOutputLines(
                        items: run.outputs,
                        emptyHint: copy.text("Waiting for adapter output…")
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Rectangle()
                    .fill(RelayPalette.line)
                    .frame(height: 1)
                if let message = run.errorMessage {
                    Text("\(copy.text("Failed:")) \(message)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RelayPalette.danger)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if run.canContinue {
                    HStack(spacing: 8) {
                        Text("›")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                        TextField(
                            copy.text("Continue this thread with a new message…"),
                            text: $draft,
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1...4)
                        .onSubmit(send)
                        Button(copy.text("SEND")) { send() }
                            .buttonStyle(ConsoleButtonStyle(
                                tint: accent, prominent: true
                            ))
                            .disabled(
                                run.sending
                                    || draft.trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RelayPalette.raised.opacity(0.55))
                } else if run.task?.status.isTerminal == true {
                    Text(copy.text("This task has no resumable session."))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func send() {
        let text = draft
        draft = ""
        run.send(text)
    }
}

struct ThreadSidebarRow: View {
    @ObservedObject var run: RelayThreadRun
    let agents: [RelayAgent]
    var focused = false
    let onFocus: () -> Void
    let onClose: () -> Void
    var onZoom: (() -> Void)?
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    var body: some View {
        RelayPanelSidebarRow(
            glyph: "•",
            tint: agents.first { $0.id == run.task?.adapterID }?.accent
                ?? RelayPalette.signal,
            title: run.task?.displayTitle ?? copy.text("Thread"),
            subtitle: run.task.map { copy.taskStatus($0.status) } ?? "",
            focused: focused,
            closeHelpKey: "Close this pane",
            onFocus: onFocus,
            onClose: onClose,
            onZoom: onZoom
        )
    }
}
