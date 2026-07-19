import SwiftUI

/// Marker object for the (single) approvals window: the window itself reads
/// pending interactions live from RelayService.
@MainActor
final class RelayApprovalPanel: ObservableObject, Identifiable {
    let id = UUID()
}

/// Floating window aggregating every daemon task that waits in USER GATE —
/// tool approvals and input questions from any source (dialogue, compare,
/// chain, quick bar) are answered here.
struct RelayApprovalWindow: View {
    @ObservedObject var store: RelayTerminalStore
    @ObservedObject var panel: RelayApprovalPanel
    let frame: CGRect
    let canvasSize: CGSize
    let focused: Bool
    @EnvironmentObject private var relay: RelayService
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var pendingTasks: [RelayTask] {
        relay.tasks.filter { $0.pendingInteraction != nil }
    }

    private func accent(_ adapterID: String) -> SwiftUI.Color {
        relay.agents.first { $0.id == adapterID }?.accent ?? RelayPalette.warning
    }

    private var headerTitle: String {
        let count = pendingTasks.count
        return count > 0
            ? "\(copy.text("Approvals")) · \(count)"
            : copy.text("Approvals")
    }

    var body: some View {
        RelayFloatingWindow(
            store: store,
            windowID: panel.id,
            frame: frame,
            canvasSize: canvasSize,
            focused: focused,
            accent: RelayPalette.warning,
            closeHelpKey: "Close approvals",
            onClose: { store.closeApprovals() }
        ) {
            Text("◇")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.warning)
            Text(headerTitle)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
                .lineLimit(1)
        } controls: {
        } content: {
            VStack(spacing: 0) {
                if pendingTasks.isEmpty {
                    emptyState
                } else {
                    gateList
                }
                if !relay.approvalRules.isEmpty {
                    Rectangle()
                        .fill(RelayPalette.line)
                        .frame(height: 1)
                    rulesSection
                }
            }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(copy.text("AUTO RULES"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(RelayPalette.muted)
            ForEach(relay.approvalRules) { rule in
                HStack(spacing: 7) {
                    Text(rule.adapterID.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent(rule.adapterID))
                    Text("\(rule.commandPrefix) → \(rule.actionLabel)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.text)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        relay.removeApprovalRule(rule.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .frame(width: 13, height: 13)
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    .help(copy.text("Remove this rule"))
                }
            }
            Text(copy.text("Rules apply per agent to matching tool approvals — remove anytime."))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("┌─ \(copy.text("No pending approvals."))")
            Text("└─ \(copy.text("Tasks that ask for tool approval or extra input show up here."))")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(RelayPalette.muted)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var gateList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(pendingTasks) { task in
                    gateCard(task)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func gateCard(_ task: RelayTask) -> some View {
        if let interaction = task.pendingInteraction {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(accent(task.adapterID))
                        .frame(width: 5, height: 5)
                    Text(task.adapterID.uppercased())
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(accent(task.adapterID))
                    Text(task.displayTitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
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
                if interaction.kind == .approval,
                   interaction.questions.isEmpty,
                   !interaction.actions.isEmpty,
                   let line = RelayApprovalRules.commandLine(from: interaction) {
                    Menu {
                        ForEach(interaction.actions) { option in
                            Button(copy.text("Auto-⟨ACTION⟩ when the command starts with '⟨PREFIX⟩'")
                                .replacingOccurrences(of: "⟨ACTION⟩", with: option.label)
                                .replacingOccurrences(
                                    of: "⟨PREFIX⟩",
                                    with: RelayApprovalRules.prefix(of: line)
                                )) {
                                Task {
                                    await relay.addApprovalRule(
                                        taskID: task.id,
                                        interaction: interaction,
                                        action: option
                                    )
                                }
                            }
                        }
                    } label: {
                        Text("☑ \(copy.text("ALWAYS"))")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(RelayPalette.muted)
                    .help(copy.text("Save a rule so matching approvals are answered automatically."))
                }
            }
            .padding(10)
            .background(RelayPalette.warning.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(RelayPalette.warning.opacity(0.18), lineWidth: 1)
            }
        }
    }
}
