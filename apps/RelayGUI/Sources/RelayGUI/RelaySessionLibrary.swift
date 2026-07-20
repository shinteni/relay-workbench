import SwiftUI

/// 検索可能なプロジェクト履歴。
/// daemon の自動セッションと明示保存したチェックポイントは既存の保存・再開方式を
/// 維持したまま、同じナビゲーション面に表示する。
struct RelaySessionLibraryDeck: View {
    @ObservedObject var store: RelayTerminalStore
    @EnvironmentObject private var relay: RelayService
    @State private var kindFilter: RelaySessionKind?
    @State private var renamingID: String?
    @State private var renameDraft = ""
    @State private var expandedID: String?
    @State private var expandedOutputs: [RelayTaskOutput] = []
    @State private var continueDraft = ""
    @State private var continueBusy = false
    @State private var continueError: String?
    @State private var pendingDelete: RelaySessionEntry?
    @FocusState private var searchFocused: Bool
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var allEntries: [RelayProjectHistoryEntry] {
        RelaySessionCatalog.historyEntries(
            tasks: relay.tasks,
            checkpoints: store.savedDecisionCheckpoints,
            annotations: store.decisionAnnotations
        )
    }

    private var filteredEntries: [RelayProjectHistoryEntry] {
        RelaySessionCatalog.filterHistory(
            allEntries,
            query: store.sessionLibraryQuery,
            sessionKind: kindFilter,
            annotations: store.decisionAnnotations
        )
    }

    private var isSearching: Bool {
        store.sessionLibraryQuery.contains { !$0.isWhitespace }
            || kindFilter != nil
    }

    var body: some View {
        let entries = filteredEntries
        return VStack(alignment: .leading, spacing: 12) {
            header(matchedCount: entries.count)
            if !allEntries.isEmpty {
                searchBar
                kindChips
            }
            if allEntries.isEmpty {
                emptyState
            } else if entries.isEmpty {
                noMatchesState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 7) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }
            footer
        }
        .padding(14)
        .background {
            ZStack {
                RelayMaterial(material: .hudWindow)
                RelayPalette.raised.opacity(0.86)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(RelayPalette.signal.opacity(0.46), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.46), radius: 26, y: 12)
        .confirmationDialog(
            copy.text("DELETE SESSION"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(copy.text("DELETE SESSION"), role: .destructive) {
                guard let entry = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    for task in entry.tasks {
                        await relay.deleteTask(task.id)
                    }
                }
            }
            Button(copy.text("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(copy.text("Removes the daemon record permanently; running tasks are not deleted."))
        }
    }

    private func header(matchedCount: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RelayPalette.signal)
                .frame(width: 34, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text("PROJECT HISTORY"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                Text(copy.text("All work saved under each project"))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
            Spacer()
            Text(isSearching
                ? "\(matchedCount) / \(allEntries.count)"
                : "\(allEntries.count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(RelayPalette.signal)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RelayPalette.signal.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button {
                store.closeSessionLibrary()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text("Close session library"))
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(searchFocused ? RelayPalette.signal : RelayPalette.muted)
            TextField(
                copy.text("Search project history"),
                text: $store.sessionLibraryQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(RelayPalette.text)
            .focused($searchFocused)
            if isSearching {
                Button {
                    store.sessionLibraryQuery = ""
                    kindFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayPalette.muted)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RelayPalette.ink.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    searchFocused
                        ? RelayPalette.signal.opacity(0.5) : RelayPalette.line,
                    lineWidth: 1
                )
        }
    }

    private var kindChips: some View {
        HStack(spacing: 6) {
            kindChip(nil, label: copy.text("ALL"))
            kindChip(.compare, label: "⋈ \(copy.text("COMPARE"))")
            kindChip(.chain, label: "› \(copy.text("CHAIN"))")
            kindChip(.single, label: "• \(copy.text("SINGLE TASKS"))")
            Spacer()
        }
    }

    private func kindChip(_ kind: RelaySessionKind?, label: String) -> some View {
        let selected = kindFilter == kind
        return Button(label) {
            kindFilter = kind
        }
        .buttonStyle(ConsoleButtonStyle(
            tint: selected ? RelayPalette.signal : RelayPalette.muted,
            prominent: selected
        ))
    }

    @ViewBuilder
    private func row(_ item: RelayProjectHistoryEntry) -> some View {
        switch item.source {
        case .session(let entry):
            row(entry)
        case .decision(let checkpoint):
            decisionRow(item, checkpoint: checkpoint)
        }
    }

    private func decisionRow(
        _ item: RelayProjectHistoryEntry,
        checkpoint: RelayDecisionCheckpoint
    ) -> some View {
        let decision = checkpoint.decision
        let route = (
            decision.receipt.plan.sources.map(\.agentName)
                + [decision.result.agentName]
        ).joined(separator: " → ")
        return HStack(spacing: 10) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RelayPalette.mix)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(RelayPalette.text)
                    .lineLimit(1)
                HStack(spacing: 7) {
                    Text(route)
                    Text("·")
                    Text(item.projectName)
                    Text("·")
                    Text(checkpoint.savedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.system(size: 8.5))
                .foregroundStyle(RelayPalette.muted)
                .lineLimit(1)
            }
            Spacer()
            Button(copy.text("VIEW")) {
                store.openDecisionCheckpoint(checkpoint)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
        }
        .padding(9)
        .background(RelayPalette.panel.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
    }

    private func row(_ entry: RelaySessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.kind.glyph)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(kindTint(entry.kind))
                    .frame(width: 14)
                if renamingID == entry.id {
                    TextField(copy.text("Session title"), text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RelayPalette.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onSubmit { commitRename(entry) }
                    Button(copy.text("SAVE")) { commitRename(entry) }
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success))
                    Button(copy.text("CANCEL")) { renamingID = nil }
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                } else {
                    Text(entry.title)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RelayPalette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if entry.hasActiveTask {
                    Circle()
                        .fill(RelayPalette.signal)
                        .frame(width: 5, height: 5)
                }
                Spacer()
                Text(Self.timestamp(entry.updatedAtMilliseconds))
                    .font(.system(size: 8.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(RelayPalette.muted)
            }
            HStack(spacing: 8) {
                Text(entry.agentsLabel)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(kindTint(entry.kind))
                    .lineLimit(1)
                Text("\(entry.projectName) · \(copy.text("⟨N⟩ turn(s)").replacingOccurrences(of: "⟨N⟩", with: "\(entry.turnCount)"))")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .lineLimit(1)
                Spacer()
                if entry.kind != .single {
                    Button(copy.text("OPEN AS WINDOW")) {
                        openGroup(entry)
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: kindTint(entry.kind)))
                    .help(copy.text("Re-mount this daemon group as a floating window"))
                } else {
                    Button(copy.text("OPEN AS WINDOW")) {
                        openGroup(entry)
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                    .help(copy.text("Open this thread as a floating window"))
                    Button(expandedID == entry.id
                        ? copy.text("HIDE") : copy.text("VIEW")) {
                        toggleExpanded(entry)
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                }
                Button(copy.text("RENAME")) {
                    renamingID = entry.id
                    renameDraft = entry.leadTask?.title ?? ""
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                Button(copy.text("DELETE")) {
                    pendingDelete = entry
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                .disabled(entry.hasActiveTask)
                .help(entry.hasActiveTask
                    ? copy.text("Stop or wait for the running task first")
                    : copy.text("Removes the daemon record permanently; running tasks are not deleted."))
            }
            if expandedID == entry.id, entry.kind == .single,
               let task = entry.leadTask {
                singleDetail(entry: entry, task: task)
            }
        }
        .padding(9)
        .background(RelayPalette.panel.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
    }

    private func singleDetail(entry: RelaySessionEntry, task: RelayTask) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ScrollView {
                RelayOutputLines(
                    items: expandedOutputs,
                    emptyHint: copy.text("Waiting for adapter output…")
                )
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .background(RelayPalette.ink.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                Text(copy.taskStatus(task.status))
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        task.status == .completed
                            ? RelayPalette.success
                            : task.status.isTerminal
                                ? RelayPalette.danger : RelayPalette.signal
                    )
                if let continueError {
                    Text(continueError)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.danger)
                        .lineLimit(1)
                }
                Spacer()
                Button(copy.text("REFRESH")) {
                    refreshOutputs(task.id)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            }
            if task.status.isTerminal, task.sessionID != nil {
                HStack(spacing: 8) {
                    TextField(
                        copy.text("Continue this thread with a new message…"),
                        text: $continueDraft,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1...3)
                    .padding(7)
                    .background(RelayPalette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button(copy.text("SEND")) {
                        continueThread(task)
                    }
                    .buttonStyle(ConsoleButtonStyle(
                        tint: RelayPalette.signal, prominent: true
                    ))
                    .disabled(
                        continueBusy
                            || continueDraft.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                }
            } else if task.sessionID == nil, task.status.isTerminal {
                Text(copy.text("This task has no resumable session."))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
        }
        .onChange(of: task.updatedAtMilliseconds) { _, _ in
            refreshOutputs(task.id)
        }
    }

    private var emptyState: some View {
        Text(copy.text("No project history yet."))
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(RelayPalette.muted)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
    }

    private var noMatchesState: some View {
        Text(copy.text("No history matches this search."))
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(RelayPalette.muted)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        Text(copy.text("History stays on this Mac · open any item to continue"))
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(RelayPalette.muted)
    }

    private func kindTint(_ kind: RelaySessionKind) -> SwiftUI.Color {
        switch kind {
        case .compare: RelayPalette.signal
        case .chain: RelayPalette.warning
        case .single: RelayPalette.mix
        }
    }

    private func toggleExpanded(_ entry: RelaySessionEntry) {
        if expandedID == entry.id {
            expandedID = nil
            expandedOutputs = []
        } else {
            expandedID = entry.id
            expandedOutputs = []
            continueDraft = ""
            continueError = nil
            if let task = entry.leadTask {
                refreshOutputs(task.id)
            }
        }
    }

    private func refreshOutputs(_ taskID: String) {
        Task {
            let outputs = await relay.outputItems(taskID: taskID)
            if expandedID != nil {
                expandedOutputs = outputs
            }
        }
    }

    private func continueThread(_ task: RelayTask) {
        let text = continueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        continueBusy = true
        continueError = nil
        Task {
            do {
                try await relay.continueDialogueTask(taskID: task.id, prompt: text)
                continueDraft = ""
                refreshOutputs(task.id)
            } catch {
                continueError = error.localizedDescription
            }
            continueBusy = false
        }
    }

    private func commitRename(_ entry: RelaySessionEntry) {
        let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lead = entry.leadTask else {
            renamingID = nil
            return
        }
        renamingID = nil
        guard !title.isEmpty else { return }
        Task { _ = await relay.renameTask(lead.id, title: title) }
    }

    private func openGroup(_ entry: RelaySessionEntry) {
        store.openSessionEntry(entry, relay: relay)
    }

    private static func timestamp(_ milliseconds: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
