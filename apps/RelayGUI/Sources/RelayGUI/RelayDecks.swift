import AppKit
import SwiftUI

struct RelayContextRelayDeck: View {
    @ObservedObject var store: RelayTerminalStore
    let draft: RelayContextRelayDraft
    @State private var instruction = ""
    @State private var context: String
    @State private var selectedIDs = Set<UUID>()
    @FocusState private var instructionFocused: Bool
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: RelayTerminalStore, draft: RelayContextRelayDraft) {
        self.store = store
        self.draft = draft
        _context = State(initialValue: draft.context)
    }

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var sourceAccent: SwiftUI.Color {
        store.session(draft.sourceID)?.accent ?? RelayPalette.mix
    }

    private var targets: [RelayTerminalSession] {
        store.sessions.filter { $0.id != draft.sourceID && !$0.exited }
    }

    private var selectedTargets: [RelayTerminalSession] {
        targets.filter { selectedIDs.contains($0.id) }
    }

    private var deckTint: SwiftUI.Color {
        switch selectedTargets.count {
        case 0:
            sourceAccent
        case 1:
            selectedTargets[0].accent
        default:
            RelayPalette.mix
        }
    }

    private var byteCountText: String {
        "\(context.utf8.count) / \(RelayTerminalContextRelay.maxCaptureBytes) B"
    }

    private var canFill: Bool {
        guard !selectedTargets.isEmpty,
              selectedTargets.count == selectedIDs.count,
              selectedTargets.allSatisfy(\.isPromptStagingReady),
              context.utf8.count <= RelayTerminalContextRelay.maxCaptureBytes else {
            return false
        }
        return RelayTerminalContextRelay.payload(
            instruction: instruction,
            context: context,
            sourceAgent: draft.sourceAgentName,
            projectName: draft.projectName
        ) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            routeRail
            instructionField
            contextEditor
            footer
        }
        .padding(14)
        .background {
            ZStack {
                RelayMaterial(material: .hudWindow)
                RelayPalette.raised.opacity(0.78)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(deckTint.opacity(0.46), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.44), radius: 24, y: 11)
        .onAppear {
            DispatchQueue.main.async { instructionFocused = true }
        }
        .onChange(of: targets.map(\.id)) { _, availableIDs in
            selectedIDs.formIntersection(availableIDs)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(deckTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text("CONTEXT FORK"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                Text(copy.text("Carry this screen into one or more native CLIs"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
            Spacer()
            Text(copy.text("LOCAL MEMORY · 48 KB MAX"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(RelayPalette.success)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RelayPalette.success.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text("Close and clear captured context"))
        }
    }

    private var routeRail: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(copy.text("FROM"))
                    .foregroundStyle(RelayPalette.muted)
                Circle()
                    .fill(sourceAccent)
                    .frame(width: 5, height: 5)
                Text(draft.sourceAgentName)
                    .fontWeight(.bold)
                Text("· \(draft.projectName)")
                    .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(sourceAccent.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(sourceAccent.opacity(0.48), lineWidth: 1)
            }

            RelayContextForkRail(
                sourceAccent: sourceAccent,
                targetAccents: selectedTargets.map(\.accent)
            )

            Text(copy.text("TO"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(targets) { target in
                        targetChip(target)
                    }
                }
            }
        }
        .frame(height: 28)
    }

    private func targetChip(_ target: RelayTerminalSession) -> some View {
        let selected = selectedIDs.contains(target.id)
        let ready = target.isPromptStagingReady
        return Button {
            if selected {
                selectedIDs.remove(target.id)
            } else {
                selectedIDs.insert(target.id)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ready ? target.accent : RelayPalette.muted)
                Text(target.agentName)
                    .fontWeight(.bold)
                Text("· \(RelayTerminalContext.projectName(target.cwd))")
                    .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(selected ? target.accent.opacity(0.14) : RelayPalette.ink.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? target.accent.opacity(0.72) : RelayPalette.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .opacity(ready ? 1 : 0.48)
        .help(copy.text(
            ready
                ? "Confirm this target is at an input prompt, then select it"
                : "This CLI has not enabled safe paste yet"
        ))
        .accessibilityLabel(
            "\(copy.text("TO")): \(target.agentName), \(RelayTerminalContext.projectName(target.cwd))"
        )
        .accessibilityValue(copy.text(
            !ready ? "SAFE PASTE UNAVAILABLE" : selected ? "SELECTED" : "CONFIRM PROMPT"
        ))
    }

    private var instructionField: some View {
        TextField(
            copy.text("What should the next CLI do with this context?"),
            text: $instruction
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(RelayPalette.text)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RelayPalette.ink.opacity(0.84))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(instruction.isEmpty ? RelayPalette.line : deckTint.opacity(0.48), lineWidth: 1)
        }
        .focused($instructionFocused)
    }

    private var contextEditor: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(copy.text("CURRENT SCREEN SNAPSHOT · EDIT BEFORE FILLING"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.45)
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Text(byteCountText)
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(
                        context.utf8.count > RelayTerminalContextRelay.maxCaptureBytes
                            ? RelayPalette.danger : RelayPalette.muted
                    )
                    .monospacedDigit()
            }
            TextEditor(text: $context)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(height: 112)
                .background(RelayPalette.ink.opacity(0.84))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(RelayPalette.line, lineWidth: 1)
                }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(RelayPalette.success)
            Text(copy.text("Captured only when you opened this panel · no clipboard or disk"))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            Spacer()
            Button(
                copy.text("FILL ⟨N⟩ TARGETS · DOES NOT RUN")
                    .replacingOccurrences(of: "⟨N⟩", with: "\(selectedTargets.count)"),
                action: fillTargets
            )
                .buttonStyle(ConsoleButtonStyle(tint: deckTint))
                .disabled(!canFill)
        }
    }

    private func close() {
        let changes = { store.cancelContextRelay() }
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 1.0), changes)
        }
    }

    private func fillTargets() {
        let changes = {
            store.completeContextRelay(
                instruction: instruction,
                context: context,
                targetIDs: selectedIDs
            )
        }
        if reduceMotion {
            _ = changes()
        } else {
            withAnimation(.spring(response: 0.36, dampingFraction: 1.0)) {
                _ = changes()
            }
        }
    }
}

struct RelayConfluenceMark: View {
    let accents: [SwiftUI.Color]

    var body: some View {
        Canvas { context, size in
            let colors = accents.isEmpty ? [RelayPalette.muted] : accents
            let merge = CGPoint(x: size.width * 0.62, y: size.height / 2)
            let destination = CGPoint(x: size.width - 5, y: size.height / 2)
            for (index, color) in colors.enumerated() {
                let source = CGPoint(
                    x: 4,
                    y: size.height * CGFloat(index + 1) / CGFloat(colors.count + 1)
                )
                var path = Path()
                path.move(to: source)
                path.addLine(to: CGPoint(x: size.width * 0.32, y: source.y))
                path.addLine(to: merge)
                context.stroke(
                    path,
                    with: .color(color.opacity(accents.isEmpty ? 0.42 : 0.92)),
                    style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: source.x - 2.4, y: source.y - 2.4, width: 4.8, height: 4.8)),
                    with: .color(color.opacity(accents.isEmpty ? 0.42 : 1))
                )
            }
            var exit = Path()
            exit.move(to: merge)
            exit.addLine(to: destination)
            context.stroke(exit, with: .color(RelayPalette.mix), lineWidth: 1.3)
            var diamond = Path()
            diamond.move(to: CGPoint(x: destination.x, y: destination.y - 4))
            diamond.addLine(to: CGPoint(x: destination.x + 4, y: destination.y))
            diamond.addLine(to: CGPoint(x: destination.x, y: destination.y + 4))
            diamond.addLine(to: CGPoint(x: destination.x - 4, y: destination.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(RelayPalette.mix))
        }
        .frame(width: 54, height: 26)
        .accessibilityHidden(true)
    }
}

struct RelayDecisionReplayMark: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(RelayPalette.mix.opacity(0.72))
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RelayPalette.mix)
            Image(systemName: "diamond.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(RelayPalette.mix)
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 54, height: 26)
        .accessibilityHidden(true)
    }
}

struct RelayDecisionRecoveryWitnessDeck: View {
    @ObservedObject var store: RelayTerminalStore
    let receipt: RelayDecisionActionReceipt
    let observation: RelayDecisionRecoveryObservation
    let draft: RelayDecisionRecoveryWitnessDraft?
    let witness: RelayDecisionRecoveryWitness?
    @State private var showingPayload = false
    @State private var confirmDiscard = false
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }
    private var isSaved: Bool { witness != nil }
    private var assessment: RelayDecisionRecoveryWitnessAssessment? {
        witness?.assessment ?? store.decisionRecoveryWitnessAssessment
    }
    private var capturedAt: Date { witness?.capturedAt ?? draft!.capturedAt }
    private var targetID: UUID { witness?.targetID ?? draft!.targetID }
    private var targetAgentName: String {
        witness?.targetAgentName ?? draft!.targetAgentName
    }
    private var targetProjectName: String {
        witness?.targetProjectName ?? draft!.targetProjectName
    }
    private var visibleScreen: String { witness?.visibleScreen ?? draft!.visibleScreen }
    private var visibleScreenBytes: Int {
        witness?.visibleScreenBytes ?? draft!.visibleScreenBytes
    }
    private var handoffPayload: String { witness?.handoffPayload ?? draft!.handoffPayload }
    private var handoffPayloadBytes: Int {
        witness?.handoffPayloadBytes ?? draft!.handoffPayloadBytes
    }
    private var addedCount: Int { witness?.addedCount ?? draft!.addedCount }
    private var removedCount: Int { witness?.removedCount ?? draft!.removedCount }
    private var unchangedCount: Int { witness?.unchangedCount ?? draft!.unchangedCount }
    private var screensTruncated: Bool {
        (witness?.frozenScreenTruncated ?? draft!.frozenScreenTruncated)
            || (witness?.recoveryScreenTruncated ?? draft!.recoveryScreenTruncated)
    }
    private var canReturnToReview: Bool {
        !isSaved
            && store.promptReviewPlan != nil
            && store.session(targetID)?.exited == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            evidenceRail
            evidenceBody
            if !isSaved {
                assessmentPicker
            }
            footer
        }
        .padding(14)
        .background {
            ZStack {
                RelayMaterial(material: .hudWindow)
                RelayPalette.raised.opacity(0.92)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke((assessment?.tint ?? RelayPalette.signal).opacity(0.54), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.48), radius: 26, y: 12)
        .confirmationDialog(
            copy.text("DISCARD UNSAVED RECOVERY WITNESS"),
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button(copy.text("DISCARD TO RECOVERY CHANGE"), role: .destructive) {
                updateState {
                    store.returnFromDecisionRecoveryWitness(discardingDraft: true)
                }
            }
            Button(copy.text("Cancel"), role: .cancel) {}
        } message: {
            Text(copy.text("The unsaved witness screen and assessment will be discarded."))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(assessment?.tint ?? RelayPalette.signal)
                .frame(width: 34, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text("RECOVERY CHANGE WITNESS"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                Text("\(targetAgentName) · \(targetProjectName) · \(capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(copy.text(isSaved ? "SAVED PRIVATE · 0600" : "UNSAVED · LOCAL MEMORY"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(isSaved ? RelayPalette.success : RelayPalette.warning)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background((isSaved ? RelayPalette.success : RelayPalette.warning).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text(canReturnToReview
                ? "BACK TO WITNESS REVIEW" : "BACK TO RECOVERY CHANGE"))
        }
    }

    private var evidenceRail: some View {
        HStack(spacing: 6) {
            evidenceNode(
                icon: "arrow.left.arrow.right.square.fill",
                title: "RECOVERY CHANGE",
                detail: "+\(addedCount) · −\(removedCount) · =\(unchangedCount)",
                tint: RelayPalette.signal
            )
            railArrow
            evidenceNode(
                icon: "tray.and.arrow.down.fill",
                title: "EXACT HANDOFF",
                detail: "\(handoffPayloadBytes) UTF-8 B",
                tint: RelayPalette.mix
            )
            railArrow
            evidenceNode(
                icon: "arrow.turn.down.left",
                title: "USER RETURN DETECTED",
                detail: "RELAY DID NOT SEND IT",
                tint: RelayPalette.signal
            )
            railArrow
            evidenceNode(
                icon: "checkmark.seal.fill",
                title: "WITNESS SCREEN",
                detail: "\(visibleScreenBytes) UTF-8 B",
                tint: assessment?.tint ?? RelayPalette.warning
            )
        }
    }

    private func evidenceNode(
        icon: String,
        title: String,
        detail: String,
        tint: SwiftUI.Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text(title)).fontWeight(.bold).foregroundStyle(tint)
                Text(copy.text(detail))
                    .foregroundStyle(RelayPalette.muted)
                    .monospacedDigit()
            }
            .font(.system(size: 7, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(tint.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        }
    }

    private var railArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(RelayPalette.muted)
            .accessibilityHidden(true)
    }

    private var evidenceBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(showingPayload ? RelayPalette.mix : assessment?.tint ?? RelayPalette.signal)
                    .frame(width: 5, height: 5)
                Text(copy.text(showingPayload ? "EXACT HANDOFF PAYLOAD" : "WITNESS VISIBLE SCREEN"))
                    .fontWeight(.bold)
                Text(showingPayload ? "\(handoffPayloadBytes) B" : "\(visibleScreenBytes) B")
                    .foregroundStyle(RelayPalette.muted)
                    .monospacedDigit()
                Text(
                    "CHK \(observation.checkpointID.uuidString.prefix(8))"
                        + " · ACT \(receipt.id.uuidString.prefix(8))"
                        + " · REC \(observation.id.uuidString.prefix(8))"
                )
                .foregroundStyle(RelayPalette.muted.opacity(0.78))
                Spacer()
                Text(copy.text(screensTruncated ? "SCREEN TAIL KEPT" : "BOTH SCREENS FULL"))
                    .foregroundStyle(screensTruncated ? RelayPalette.warning : RelayPalette.success)
                Button(copy.text(showingPayload ? "VIEW WITNESS SCREEN" : "VIEW EXACT HANDOFF")) {
                    updateState { showingPayload.toggle() }
                }
                .buttonStyle(ConsoleButtonStyle(
                    tint: showingPayload ? RelayPalette.signal : RelayPalette.mix
                ))
            }
            .font(.system(size: 8, design: .monospaced))
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background((showingPayload ? RelayPalette.mix : RelayPalette.signal).opacity(0.09))

            ScrollView(.vertical, showsIndicators: true) {
                Text(showingPayload ? handoffPayload : visibleScreen)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(9)
            }
            .frame(height: 155)
        }
        .background(RelayPalette.ink.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke((showingPayload ? RelayPalette.mix : RelayPalette.signal).opacity(0.34))
        }
    }

    private var assessmentPicker: some View {
        HStack(spacing: 8) {
            Text(copy.text("YOUR WITNESS ASSESSMENT"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(RelayPalette.muted)
            ForEach(RelayDecisionRecoveryWitnessAssessment.allCases, id: \.rawValue) { option in
                Button {
                    updateState { store.setDecisionRecoveryWitnessAssessment(option) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: option.icon)
                            .accessibilityHidden(true)
                        Text(copy.text(option.labelKey))
                    }
                }
                .buttonStyle(ConsoleButtonStyle(
                    tint: option.tint,
                    prominent: assessment == option
                ))
                .accessibilityLabel(copy.text(option.labelKey))
                .accessibilityValue(copy.text(assessment == option ? "SELECTED" : "SELECT"))
            }
            Spacer()
            Text(copy.text("USER-LABELED · RELAY DOES NOT JUDGE"))
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(RelayPalette.signal)
            Text(copy.text(
                "This witness records the exact handoff and visible review; it does not prove completion or correctness."
            ))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            Spacer()
            if isSaved {
                if let assessment {
                    HStack(spacing: 5) {
                        Image(systemName: assessment.icon)
                        Text(copy.text(assessment.labelKey))
                    }
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(assessment.tint)
                }
                Button(copy.text("BACK TO RECOVERY CHANGE"), action: close)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            } else {
                if canReturnToReview {
                    Button(copy.text("BACK TO WITNESS REVIEW"), action: close)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                }
                Button(copy.text("DISCARD TO RECOVERY CHANGE")) {
                    confirmDiscard = true
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                Button(copy.text("SAVE PRIVATE WITNESS"), action: save)
                    .buttonStyle(ConsoleButtonStyle(
                        tint: assessment?.tint ?? RelayPalette.muted,
                        prominent: assessment != nil
                    ))
                    .disabled(assessment == nil)
            }
        }
    }

    private func save() {
        guard let assessment else { return }
        updateState { _ = store.saveDecisionRecoveryWitness(assessment: assessment) }
    }

    private func close() {
        if !isSaved, !canReturnToReview {
            confirmDiscard = true
            return
        }
        updateState { store.returnFromDecisionRecoveryWitness() }
    }

    private func updateState(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 1.0), changes)
        }
    }
}

struct RelayDecisionRecoveryObservationDeck: View {
    @ObservedObject var store: RelayTerminalStore
    let receipt: RelayDecisionActionReceipt
    let observation: RelayDecisionRecoveryObservation
    let isSaved: Bool
    @State private var confirmDiscard = false
    @State private var handoffVisible = false
    @State private var handoffInstruction = ""
    @State private var handoffTargetID: UUID?
    @State private var witnessComparisonVisible = false
    @State private var leftWitnessID: UUID?
    @State private var rightWitnessID: UUID?
    @FocusState private var handoffInstructionFocused: Bool
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }
    private var delta: RelayDecisionDelta {
        RelayDecisionDelta(parent: receipt.visibleScreen, derived: observation.visibleScreen)
    }
    private var canReturnToReview: Bool {
        !isSaved
            && store.promptReviewPlan != nil
            && store.session(observation.targetID)?.exited == false
    }
    private var liveHandoffTargets: [RelayTerminalSession] {
        store.sessions.filter { !$0.exited }
    }
    private var selectedHandoffTarget: RelayTerminalSession? {
        guard let handoffTargetID else { return nil }
        return store.session(handoffTargetID)
    }
    private var handoffPlan: RelayDecisionRecoveryHandoffPlan? {
        RelayDecisionRecoveryHandoff.plan(
            receipt: receipt,
            observation: observation,
            instruction: handoffInstruction
        )
    }
    private var witnesses: [RelayDecisionRecoveryWitness] {
        store.decisionRecoveryWitnesses(for: observation)
    }
    private var leftWitness: RelayDecisionRecoveryWitness? {
        guard let leftWitnessID else { return nil }
        return witnesses.first { $0.id == leftWitnessID }
    }
    private var rightWitness: RelayDecisionRecoveryWitness? {
        guard let rightWitnessID else { return nil }
        return witnesses.first { $0.id == rightWitnessID }
    }
    private var witnessComparison: RelayDecisionRecoveryWitnessComparison? {
        guard let leftWitness, let rightWitness else { return nil }
        return RelayDecisionRecoveryWitnessComparison(left: leftWitness, right: rightWitness)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            evidenceRail
            if witnessComparisonVisible {
                witnessComparisonDeck
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
            } else if handoffVisible {
                handoffComposer
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
            } else {
                deltaDeck
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .leading).combined(with: .opacity)
                    )
            }
            if !handoffVisible, !witnessComparisonVisible, !witnesses.isEmpty {
                witnessStrip
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            footer
        }
        .padding(14)
        .background {
            ZStack {
                RelayMaterial(material: .hudWindow)
                RelayPalette.raised.opacity(0.90)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(RelayPalette.signal.opacity(0.54), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.48), radius: 26, y: 12)
        .confirmationDialog(
            copy.text("DISCARD UNSAVED RECOVERY CHANGE"),
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button(copy.text("DISCARD TO ACTION RECEIPT"), role: .destructive) {
                updateState {
                    store.returnFromDecisionRecoveryObservation(discardingDraft: true)
                }
            }
            Button(copy.text("Cancel"), role: .cancel) {}
        } message: {
            Text(copy.text("The unsaved recovery screen will be discarded."))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.left.arrow.right.square.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RelayPalette.signal)
                .frame(width: 34, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text("RECOVERY CHANGE RECEIPT"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                Text("\(observation.targetAgentName) · \(observation.targetProjectName) · \(observation.capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(copy.text(isSaved ? "SAVED PRIVATE · 0600" : "UNSAVED · LOCAL MEMORY"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(isSaved ? RelayPalette.success : RelayPalette.warning)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background((isSaved ? RelayPalette.success : RelayPalette.warning).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text(
                canReturnToReview ? "BACK TO RECOVERY REVIEW" : "BACK TO ACTION RECEIPT"
            ))
        }
    }

    private var evidenceRail: some View {
        HStack(spacing: 8) {
            evidenceNode(
                icon: "snowflake",
                title: "FROZEN RECEIPT SCREEN",
                detail: "\(receipt.visibleScreenBytes) UTF-8 B",
                tint: RelayPalette.mix
            )
            railArrow
            evidenceNode(
                icon: "arrow.turn.down.left",
                title: "USER RETURN DETECTED",
                detail: "RELAY DID NOT SEND IT",
                tint: RelayPalette.signal
            )
            railArrow
            evidenceNode(
                icon: "rectangle.inset.filled.and.person.filled",
                title: "RECOVERY SCREEN",
                detail: "\(observation.visibleScreenBytes) UTF-8 B",
                tint: RelayPalette.success
            )
        }
    }

    private func evidenceNode(
        icon: String,
        title: String,
        detail: String,
        tint: SwiftUI.Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text(title))
                    .fontWeight(.bold)
                    .foregroundStyle(tint)
                Text(copy.text(detail))
                    .foregroundStyle(RelayPalette.muted)
                    .monospacedDigit()
            }
            .font(.system(size: 7.5, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(tint.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        }
    }

    private var railArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(RelayPalette.signal)
            .accessibilityHidden(true)
    }

    private var deltaDeck: some View {
        let delta = delta
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(copy.text("VISIBLE SCREEN CHANGE"))
                    .fontWeight(.bold)
                    .foregroundStyle(RelayPalette.signal)
                Text(copy.text("+⟨ADDED⟩ added · −⟨REMOVED⟩ removed · =⟨UNCHANGED⟩ unchanged")
                    .replacingOccurrences(of: "⟨ADDED⟩", with: "\(delta.addedCount)")
                    .replacingOccurrences(of: "⟨REMOVED⟩", with: "\(delta.removedCount)")
                    .replacingOccurrences(of: "⟨UNCHANGED⟩", with: "\(delta.unchangedCount)"))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                if delta.parentTruncated || delta.derivedTruncated {
                    Text(copy.text("EARLIER LINES OMITTED"))
                        .foregroundStyle(RelayPalette.warning)
                }
                Text(copy.text("SCREEN EVIDENCE · NOT SUCCESS PROOF"))
                    .foregroundStyle(RelayPalette.signal)
            }
            .font(.system(size: 7.5, weight: .bold, design: .monospaced))

            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    deltaHeader(
                        title: "FROZEN RECEIPT SCREEN",
                        detail: "\(delta.parentBytes) B",
                        tint: RelayPalette.danger
                    )
                    deltaHeader(
                        title: "RECOVERY SCREEN",
                        detail: "\(delta.derivedBytes) B",
                        tint: RelayPalette.success
                    )
                }
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(delta.rows) { row in
                            HStack(spacing: 1) {
                                deltaCell(
                                    text: row.kind == .added ? nil : row.text,
                                    lineNumber: row.parentLineNumber,
                                    marker: row.kind == .removed ? "−" : " ",
                                    tint: row.kind == .removed ? RelayPalette.danger : nil
                                )
                                deltaCell(
                                    text: row.kind == .removed ? nil : row.text,
                                    lineNumber: row.derivedLineNumber,
                                    marker: row.kind == .added ? "+" : " ",
                                    tint: row.kind == .added ? RelayPalette.success : nil
                                )
                            }
                        }
                    }
                }
            }
            .background(RelayPalette.ink.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(RelayPalette.signal.opacity(0.34), lineWidth: 1)
            }
        }
        .frame(height: 230)
    }

    private var witnessStrip: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(RelayPalette.signal)
            Text(copy.text("RECOVERY WITNESSES · ⟨N⟩")
                .replacingOccurrences(of: "⟨N⟩", with: "\(witnesses.count)"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(RelayPalette.signal)
            if witnesses.count >= 2 {
                Button(copy.text("COMPARE WITNESSES"), action: openWitnessComparison)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix, prominent: true))
                    .help(copy.text("Compare two saved recovery witnesses without judging them"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(witnesses) { witness in
                        Button {
                            updateState { store.openDecisionRecoveryWitness(witness) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: witness.assessment.icon)
                                    .font(.system(size: 7, weight: .black))
                                Text(copy.text(witness.assessment.labelKey))
                                    .fontWeight(.bold)
                                Text("· \(witness.targetAgentName)")
                                    .foregroundStyle(RelayPalette.muted)
                                Text("· \(witness.visibleScreenBytes) B")
                                    .foregroundStyle(RelayPalette.muted)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 7.5, design: .monospaced))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(witness.assessment.tint.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(witness.assessment.tint.opacity(0.34), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(witness.assessment.tint)
                        .help(copy.text("Open this private recovery witness"))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(RelayPalette.signal.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.signal.opacity(0.22), lineWidth: 1)
        }
    }

    private var witnessComparisonDeck: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RelayPalette.mix)
                Text(copy.text("WITNESS COMPARISON"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.55)
                    .foregroundStyle(RelayPalette.mix)
                Spacer()
                if let comparison = witnessComparison {
                    Text(copy.text(
                        comparison.handoffPayloadsMatch
                            ? "SAME EXACT HANDOFF" : "DIFFERENT EXACT HANDOFF"
                    ))
                    .foregroundStyle(
                        comparison.handoffPayloadsMatch
                            ? RelayPalette.success : RelayPalette.warning
                    )
                    Text(copy.text(
                        comparison.assessmentsMatch
                            ? "USER LABELS MATCH" : "USER LABELS DIFFER"
                    ))
                    .foregroundStyle(
                        comparison.assessmentsMatch
                            ? RelayPalette.muted : RelayPalette.warning
                    )
                } else {
                    Text(copy.text("SELECT TWO WITNESSES"))
                        .foregroundStyle(RelayPalette.warning)
                }
            }
            .font(.system(size: 7.5, weight: .bold, design: .monospaced))

            witnessPickerRow(
                title: "LEFT WITNESS",
                selectedID: leftWitnessID,
                excludedID: rightWitnessID
            ) { selectedID in
                leftWitnessID = selectedID
            }
            witnessPickerRow(
                title: "RIGHT WITNESS",
                selectedID: rightWitnessID,
                excludedID: leftWitnessID
            ) { selectedID in
                rightWitnessID = selectedID
            }

            if let comparison = witnessComparison {
                witnessBalance(comparison)
                witnessScreenDelta(comparison)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "cursorarrow.click.2")
                        .foregroundStyle(RelayPalette.mix)
                    Text(copy.text(
                        "Choose one saved witness for each side; the same record cannot occupy both sides."
                    ))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RelayPalette.ink.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(RelayPalette.mix.opacity(0.28), lineWidth: 1)
                }
            }
        }
        .padding(9)
        .frame(height: 282)
        .background(RelayPalette.mix.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(RelayPalette.mix.opacity(0.32), lineWidth: 1)
        }
    }

    private func witnessPickerRow(
        title: String,
        selectedID: UUID?,
        excludedID: UUID?,
        onSelect: @escaping (UUID) -> Void
    ) -> some View {
        HStack(spacing: 7) {
            Text(copy.text(title))
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
                .frame(width: 92, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(witnesses) { witness in
                        let selected = selectedID == witness.id
                        let excluded = excludedID == witness.id
                        Button {
                            updateState { onSelect(witness.id) }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 7.5, weight: .bold))
                                Text(witness.targetAgentName)
                                    .fontWeight(.bold)
                                Text(copy.text(witness.assessment.labelKey))
                                    .foregroundStyle(witness.assessment.tint)
                                Text(witness.capturedAt.formatted(
                                    date: .omitted,
                                    time: .shortened
                                ))
                                .foregroundStyle(RelayPalette.muted)
                            }
                            .font(.system(size: 7.5, design: .monospaced))
                            .padding(.horizontal, 8)
                            .frame(height: 27)
                            .background(
                                selected
                                    ? RelayPalette.mix.opacity(0.16)
                                    : RelayPalette.ink.opacity(0.58)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay {
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(
                                        selected
                                            ? RelayPalette.mix.opacity(0.74)
                                            : RelayPalette.line,
                                        lineWidth: 1
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? RelayPalette.mix : RelayPalette.text)
                        .disabled(excluded)
                        .opacity(excluded ? 0.34 : 1)
                        .accessibilityLabel(
                            "\(copy.text(title)), \(witness.targetAgentName), "
                                + copy.text(witness.assessment.labelKey)
                        )
                        .accessibilityValue(copy.text(selected ? "SELECTED" : "SELECT"))
                    }
                }
            }
        }
        .frame(height: 29)
    }

    private func witnessBalance(
        _ comparison: RelayDecisionRecoveryWitnessComparison
    ) -> some View {
        HStack(spacing: 7) {
            witnessEndpoint(
                title: "LEFT WITNESS",
                witness: comparison.left,
                tint: RelayPalette.signal
            )
            Rectangle()
                .fill(RelayPalette.mix.opacity(0.42))
                .frame(width: 14, height: 1)
            VStack(spacing: 3) {
                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(RelayPalette.mix)
                Text(copy.text(
                    comparison.handoffPayloadsMatch
                        ? "SAME EXACT HANDOFF" : "DIFFERENT EXACT HANDOFF"
                ))
                .fontWeight(.bold)
                .foregroundStyle(
                    comparison.handoffPayloadsMatch
                        ? RelayPalette.success : RelayPalette.warning
                )
                Text(copy.text(
                    comparison.assessmentsMatch
                        ? "USER LABELS MATCH" : "USER LABELS DIFFER"
                ))
                .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 6.8, design: .monospaced))
            .frame(width: 132, height: 50)
            .background(RelayPalette.mix.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(RelayPalette.mix.opacity(0.34), lineWidth: 1)
            }
            Rectangle()
                .fill(RelayPalette.mix.opacity(0.42))
                .frame(width: 14, height: 1)
            witnessEndpoint(
                title: "RIGHT WITNESS",
                witness: comparison.right,
                tint: RelayPalette.mix
            )
        }
    }

    private func witnessEndpoint(
        title: String,
        witness: RelayDecisionRecoveryWitness,
        tint: SwiftUI.Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: witness.assessment.icon)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(witness.assessment.tint)
                .frame(width: 17, height: 17)
                .background(witness.assessment.tint.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(copy.text(title)).fontWeight(.bold).foregroundStyle(tint)
                    Text(witness.targetAgentName).foregroundStyle(RelayPalette.text)
                }
                Text(copy.text("⟨PAYLOAD⟩ B HANDOFF · ⟨SCREEN⟩ B SCREEN")
                    .replacingOccurrences(of: "⟨PAYLOAD⟩", with: "\(witness.handoffPayloadBytes)")
                    .replacingOccurrences(of: "⟨SCREEN⟩", with: "\(witness.visibleScreenBytes)"))
                    .foregroundStyle(RelayPalette.muted)
                    .monospacedDigit()
                Text(copy.text(witness.assessment.labelKey))
                    .fontWeight(.bold)
                    .foregroundStyle(witness.assessment.tint)
            }
            .font(.system(size: 7, design: .monospaced))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(tint.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        }
    }

    private func witnessScreenDelta(
        _ comparison: RelayDecisionRecoveryWitnessComparison
    ) -> some View {
        let delta = comparison.screenDelta
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(copy.text("WITNESS SCREEN DIFFERENCE"))
                    .fontWeight(.bold)
                    .foregroundStyle(RelayPalette.mix)
                Text("+‎\(delta.addedCount) · −\(delta.removedCount) · =\(delta.unchangedCount)")
                    .foregroundStyle(RelayPalette.muted)
                    .monospacedDigit()
                Spacer()
                if delta.parentTruncated || delta.derivedTruncated {
                    Text(copy.text("EARLIER LINES OMITTED"))
                        .foregroundStyle(RelayPalette.warning)
                }
            }
            .font(.system(size: 7.2, weight: .bold, design: .monospaced))

            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    deltaHeader(
                        title: "LEFT WITNESS SCREEN",
                        detail: "\(delta.parentBytes) B",
                        tint: RelayPalette.signal
                    )
                    deltaHeader(
                        title: "RIGHT WITNESS SCREEN",
                        detail: "\(delta.derivedBytes) B",
                        tint: RelayPalette.mix
                    )
                }
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(delta.rows) { row in
                            HStack(spacing: 1) {
                                deltaCell(
                                    text: row.kind == .added ? nil : row.text,
                                    lineNumber: row.parentLineNumber,
                                    marker: row.kind == .removed ? "−" : " ",
                                    tint: row.kind == .removed ? RelayPalette.danger : nil
                                )
                                deltaCell(
                                    text: row.kind == .removed ? nil : row.text,
                                    lineNumber: row.derivedLineNumber,
                                    marker: row.kind == .added ? "+" : " ",
                                    tint: row.kind == .added ? RelayPalette.success : nil
                                )
                            }
                        }
                    }
                }
            }
            .background(RelayPalette.ink.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(RelayPalette.mix.opacity(0.32), lineWidth: 1)
            }
        }
        .frame(height: 122)
    }

    private func deltaHeader(
        title: String,
        detail: String,
        tint: SwiftUI.Color
    ) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(copy.text(title)).fontWeight(.bold).foregroundStyle(tint)
            Spacer()
            Text(detail).foregroundStyle(RelayPalette.muted).monospacedDigit()
        }
        .font(.system(size: 8, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(tint.opacity(0.09))
    }

    @ViewBuilder
    private func deltaCell(
        text: String?,
        lineNumber: Int?,
        marker: String,
        tint: SwiftUI.Color?
    ) -> some View {
        if let text, let lineNumber {
            HStack(spacing: 5) {
                Text("\(lineNumber)")
                    .foregroundStyle(RelayPalette.muted.opacity(0.72))
                    .frame(width: 24, alignment: .trailing)
                Text(marker)
                    .fontWeight(.bold)
                    .foregroundStyle(tint ?? RelayPalette.muted)
                    .frame(width: 8)
                Text(text.isEmpty ? " " : text)
                    .foregroundStyle(RelayPalette.text)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(.system(size: 8.5, design: .monospaced))
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
            .background((tint ?? RelayPalette.raised).opacity(tint == nil ? 0.28 : 0.12))
        } else {
            RelayPalette.ink.opacity(0.46)
                .frame(maxWidth: .infinity, minHeight: 21)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(RelayPalette.signal)
            Text(copy.text(
                witnessComparisonVisible
                    ? "Both saved witnesses stay unchanged; Relay does not judge them."
                    : handoffVisible
                        ? "Saved change stays unchanged · no clipboard or disk"
                        : "This receipt records a visible change only; it does not prove completion or success."
            ))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            Spacer()
            if witnessComparisonVisible {
                Button(copy.text("BACK TO RECOVERY CHANGE"), action: closeWitnessComparison)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            } else if handoffVisible {
                Button(copy.text("CANCEL"), action: closeHandoff)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                Button(copy.text("FILL TARGET · DOES NOT RUN"), action: handoff)
                    .buttonStyle(ConsoleButtonStyle(
                        tint: selectedHandoffTarget?.accent ?? RelayPalette.signal,
                        prominent: true
                    ))
                    .disabled(
                        handoffPlan == nil
                            || selectedHandoffTarget?.isPromptStagingReady != true
                    )
            } else if isSaved {
                Button(copy.text("BACK TO ACTION RECEIPT"), action: close)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                Button(copy.text("CONTINUE CHANGE IN LIVE CLI"), action: openHandoff)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            } else {
                if canReturnToReview {
                    Button(copy.text("BACK TO RECOVERY REVIEW"), action: close)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                }
                Button(copy.text("DISCARD TO ACTION RECEIPT")) {
                    confirmDiscard = true
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                Button(copy.text("SAVE PRIVATE RECOVERY CHANGE")) {
                    updateState { _ = store.saveDecisionRecoveryObservation() }
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            }
        }
    }

    private var handoffComposer: some View {
        let plan = handoffPlan
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RelayPalette.signal)
                Text(copy.text("RECOVERY CHANGE → LIVE CLI"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.65)
                    .foregroundStyle(RelayPalette.signal)
                Spacer()
                Text(copy.text("PRIVATE LINEAGE · FILL ONLY"))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.signal)
            }

            HStack(spacing: 8) {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Text("+\(delta.addedCount)").foregroundStyle(RelayPalette.success)
                        Text("−\(delta.removedCount)").foregroundStyle(RelayPalette.danger)
                        Text("=\(delta.unchangedCount)").foregroundStyle(RelayPalette.muted)
                    }
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    Text(copy.text("VISIBLE SCREEN CHANGE"))
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                }
                .frame(width: 172, height: 48)
                .background(RelayPalette.signal.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(RelayPalette.signal.opacity(0.32), lineWidth: 1)
                }
                railArrow
                VStack(spacing: 2) {
                    Text("\(plan?.payloadBytes ?? 0)")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(plan == nil ? RelayPalette.danger : RelayPalette.signal)
                        .monospacedDigit()
                    Text(copy.text("UTF-8 B"))
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                    Text(copy.text(
                        plan?.frozenScreenTruncated == true
                            || plan?.recoveryScreenTruncated == true
                            ? "SCREEN TAIL KEPT" : "BOTH SCREENS FULL"
                    ))
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        plan?.frozenScreenTruncated == true
                            || plan?.recoveryScreenTruncated == true
                            ? RelayPalette.warning : RelayPalette.success
                    )
                }
                .frame(width: 88, height: 48)
                .background(RelayPalette.signal.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(RelayPalette.signal.opacity(0.32), lineWidth: 1)
                }
                railArrow
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if liveHandoffTargets.isEmpty {
                            Text(copy.text("OPEN A TERMINAL TO CHOOSE A TARGET"))
                                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(RelayPalette.warning)
                                .padding(.horizontal, 8)
                        } else {
                            ForEach(liveHandoffTargets) { session in
                                handoffTargetChip(session)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $handoffInstruction)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .focused($handoffInstructionFocused)
                if handoffInstruction.isEmpty {
                    Text(copy.text("Optional instruction for the next CLI…"))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 48)
            .background(RelayPalette.ink.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(plan == nil ? RelayPalette.danger.opacity(0.55) : RelayPalette.line)
            }

            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                Text(copy.text(
                    "Relay carries both recorded screens into one prompt-ready CLI and leaves Return to you."
                ))
                Spacer()
                if let plan {
                    Text(copy.text(
                        "⟨FROZEN⟩ / ⟨FROZEN_TOTAL⟩ B FROZEN · ⟨RECOVERY⟩ / ⟨RECOVERY_TOTAL⟩ B RECOVERY"
                    )
                    .replacingOccurrences(
                        of: "⟨FROZEN⟩", with: "\(plan.frozenScreenRetainedBytes)"
                    )
                    .replacingOccurrences(
                        of: "⟨FROZEN_TOTAL⟩", with: "\(plan.frozenScreenOriginalBytes)"
                    )
                    .replacingOccurrences(
                        of: "⟨RECOVERY⟩", with: "\(plan.recoveryScreenRetainedBytes)"
                    )
                    .replacingOccurrences(
                        of: "⟨RECOVERY_TOTAL⟩", with: "\(plan.recoveryScreenOriginalBytes)"
                    ))
                    .foregroundStyle(
                        plan.frozenScreenTruncated || plan.recoveryScreenTruncated
                            ? RelayPalette.warning : RelayPalette.success
                    )
                }
            }
            .font(.system(size: 7.5, design: .monospaced))
            .foregroundStyle(RelayPalette.muted)
        }
        .padding(9)
        .background(RelayPalette.signal.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.signal.opacity(0.30), lineWidth: 1)
        }
        .frame(height: 230)
    }

    private func handoffTargetChip(_ session: RelayTerminalSession) -> some View {
        let ready = session.isPromptStagingReady
        let selected = handoffTargetID == session.id
        return Button {
            handoffTargetID = session.id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ready ? session.accent : RelayPalette.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.agentName).fontWeight(.bold)
                    Text(RelayTerminalContext.projectName(session.cwd))
                        .foregroundStyle(RelayPalette.muted)
                }
            }
            .font(.system(size: 8.5, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(selected ? session.accent.opacity(0.14) : RelayPalette.ink.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        selected ? session.accent.opacity(0.72) : RelayPalette.line,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .opacity(ready ? 1 : 0.46)
        .help(copy.text(
            ready
                ? "Confirm this target is at an input prompt, then select it"
                : "This CLI has not enabled safe paste yet"
        ))
        .accessibilityValue(copy.text(
            !ready ? "SAFE PASTE UNAVAILABLE" : selected ? "SELECTED" : "CONFIRM PROMPT"
        ))
    }

    private func openHandoff() {
        updateState {
            witnessComparisonVisible = false
            leftWitnessID = nil
            rightWitnessID = nil
            handoffVisible = true
        }
        DispatchQueue.main.async { handoffInstructionFocused = true }
    }

    private func closeHandoff() {
        updateState {
            handoffVisible = false
            handoffInstruction = ""
            handoffTargetID = nil
        }
    }

    private func openWitnessComparison() {
        guard witnesses.count >= 2 else { return }
        updateState {
            handoffVisible = false
            handoffInstruction = ""
            handoffTargetID = nil
            leftWitnessID = nil
            rightWitnessID = nil
            witnessComparisonVisible = true
        }
    }

    private func closeWitnessComparison() {
        updateState {
            witnessComparisonVisible = false
            handoffInstruction = ""
            handoffTargetID = nil
            leftWitnessID = nil
            rightWitnessID = nil
        }
    }

    private func handoff() {
        guard let handoffTargetID else { return }
        let completed = store.completeDecisionRecoveryHandoff(
            receipt: receipt,
            observation: observation,
            instruction: handoffInstruction,
            targetID: handoffTargetID
        )
        if completed {
            handoffInstruction = ""
            self.handoffTargetID = nil
            handoffVisible = false
        }
    }

    private func close() {
        if witnessComparisonVisible {
            closeWitnessComparison()
            return
        }
        if handoffVisible {
            closeHandoff()
            return
        }
        if !isSaved, !canReturnToReview {
            confirmDiscard = true
            return
        }
        updateState { store.returnFromDecisionRecoveryObservation() }
    }

    private func updateState(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 1.0), changes)
        }
    }
}

struct RelayDecisionActionReceiptDeck: View {
    @ObservedObject var store: RelayTerminalStore
    let receipt: RelayDecisionActionReceipt
    let isSaved: Bool
    @State private var confirmDiscard = false
    @State private var recoveryVisible = false
    @State private var recoveryInstruction = ""
    @State private var recoveryTargetID: UUID?
    @FocusState private var recoveryInstructionFocused: Bool
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var canReturnToReview: Bool {
        !isSaved
            && store.promptReviewPlan != nil
            && store.session(receipt.targetID)?.exited == false
    }

    private var liveRecoveryTargets: [RelayTerminalSession] {
        store.sessions.filter { !$0.exited }
    }

    private var selectedRecoveryTarget: RelayTerminalSession? {
        guard let recoveryTargetID else { return nil }
        return store.session(recoveryTargetID)
    }

    private var recoveryPlan: RelayDecisionActionRecoveryPlan? {
        RelayDecisionActionRecovery.plan(
            receipt: receipt,
            instruction: recoveryInstruction
        )
    }

    private var recoveryObservations: [RelayDecisionRecoveryObservation] {
        store.decisionRecoveryObservations(for: receipt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            causalityRail
            if recoveryVisible {
                recoveryComposer
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else {
                evidence
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
            if !recoveryVisible, !recoveryObservations.isEmpty {
                recoveryObservationRail
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
            footer
        }
        .padding(14)
        .background {
            ZStack {
                RelayMaterial(material: .hudWindow)
                RelayPalette.raised.opacity(0.88)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(RelayPalette.signal.opacity(0.48), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.46), radius: 26, y: 12)
        .confirmationDialog(
            copy.text("DISCARD UNSAVED RECEIPT"),
            isPresented: $confirmDiscard,
            titleVisibility: .visible
        ) {
            Button(copy.text("DISCARD TO DECISION"), role: .destructive) {
                updateState { store.returnFromDecisionActionReceipt(discardingDraft: true) }
            }
            Button(copy.text("Cancel"), role: .cancel) {}
        } message: {
            Text(copy.text("The unsaved in-memory receipt will be discarded."))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RelayPalette.signal)
                .frame(width: 34, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text("DECISION ACTION RECEIPT"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                Text("\(receipt.targetAgentName) · \(receipt.targetProjectName) · \(receipt.capturedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(copy.text(isSaved ? "SAVED PRIVATE · 0600" : "UNSAVED · LOCAL MEMORY"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(isSaved ? RelayPalette.success : RelayPalette.warning)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background((isSaved ? RelayPalette.success : RelayPalette.warning).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text(
                recoveryVisible
                    ? "BACK TO ACTION RECEIPT"
                    : canReturnToReview ? "BACK TO CLI REVIEW" : "BACK TO DECISION"
            ))
        }
    }

    private var causalityRail: some View {
        HStack(spacing: 8) {
            receiptNode(
                icon: "seal.fill",
                title: "SEALED DECISION",
                detail: "\(receipt.briefPayloadBytes) UTF-8 B",
                tint: RelayPalette.success
            )
            receiptArrow
            receiptNode(
                icon: "arrow.turn.down.left",
                title: "USER RETURN DETECTED",
                detail: "RELAY DID NOT SEND IT",
                tint: RelayPalette.signal
            )
            receiptArrow
            receiptNode(
                icon: "rectangle.on.rectangle",
                title: "CURRENT SCREEN",
                detail: "\(receipt.visibleScreenBytes) UTF-8 B",
                tint: RelayPalette.mix
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func receiptNode(
        icon: String,
        title: String,
        detail: String,
        tint: SwiftUI.Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text(title))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                Text(copy.text(detail))
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(tint.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        }
    }

    private var receiptArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(RelayPalette.mix)
            .accessibilityHidden(true)
    }

    private var evidence: some View {
        HStack(alignment: .top, spacing: 9) {
            evidenceCard(
                title: "EXACT FILLED DECISION BRIEF",
                detail: receipt.decisionTruncated
                    ? copy.text("TAIL KEPT · ⟨KEPT⟩ / ⟨TOTAL⟩ B")
                        .replacingOccurrences(of: "⟨KEPT⟩", with: "\(receipt.decisionRetainedBytes)")
                        .replacingOccurrences(of: "⟨TOTAL⟩", with: "\(receipt.decisionOriginalBytes)")
                    : "FULL SEALED RESULT",
                text: receipt.briefPayload,
                tint: RelayPalette.success
            )
            evidenceCard(
                title: "CAPTURED CURRENT SCREEN",
                detail: "VISIBLE AT CAPTURE TIME · NOT A SUCCESS CLAIM",
                text: receipt.visibleScreen,
                tint: RelayPalette.mix
            )
        }
        .frame(height: 220)
    }

    private func evidenceCard(
        title: String,
        detail: String,
        text: String,
        tint: SwiftUI.Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(copy.text(title))
                    .fontWeight(.bold)
                    .foregroundStyle(tint)
                Spacer()
                Text(copy.text(detail))
                    .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 7.5, design: .monospaced))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(tint.opacity(0.09))

            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(text)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(9)
            }
            .background(RelayPalette.ink.opacity(0.84))
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        }
    }

    private var recoveryComposer: some View {
        let plan = recoveryPlan
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RelayPalette.signal)
                Text(copy.text("RECEIPT → LIVE CLI RECOVERY"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.65)
                    .foregroundStyle(RelayPalette.signal)
                Spacer()
                Text(copy.text("FROZEN EVIDENCE · FILL ONLY"))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.signal)
            }

            HStack(spacing: 8) {
                receiptNode(
                    icon: "snowflake",
                    title: "FROZEN SCREEN",
                    detail: "\(receipt.visibleScreenBytes) UTF-8 B",
                    tint: RelayPalette.mix
                )
                .frame(width: 172)
                receiptArrow
                VStack(spacing: 2) {
                    Text("\(plan?.payloadBytes ?? 0)")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(plan == nil ? RelayPalette.danger : RelayPalette.signal)
                        .monospacedDigit()
                    Text(copy.text("UTF-8 B"))
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                    Text(copy.text(
                        plan?.decisionBriefTruncated == true
                            || plan?.visibleScreenTruncated == true
                            ? "TAIL KEPT" : "FULL"
                    ))
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        plan?.decisionBriefTruncated == true
                            || plan?.visibleScreenTruncated == true
                            ? RelayPalette.warning : RelayPalette.success
                    )
                }
                .frame(width: 76, height: 48)
                .background(RelayPalette.signal.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(RelayPalette.signal.opacity(0.32), lineWidth: 1)
                }
                receiptArrow
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if liveRecoveryTargets.isEmpty {
                            Text(copy.text("OPEN A TERMINAL TO CHOOSE A TARGET"))
                                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(RelayPalette.warning)
                                .padding(.horizontal, 8)
                        } else {
                            ForEach(liveRecoveryTargets) { session in
                                recoveryTargetChip(session)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $recoveryInstruction)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .focused($recoveryInstructionFocused)
                if recoveryInstruction.isEmpty {
                    Text(copy.text("Optional next instruction for the recovered CLI…"))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 48)
            .background(RelayPalette.ink.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(plan == nil ? RelayPalette.danger.opacity(0.55) : RelayPalette.line)
            }

            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                Text(copy.text(
                    "Relay carries the exact receipt into one prompt-ready CLI and leaves Return to you."
                ))
                Spacer()
                if let plan {
                    Text(copy.text("⟨KEPT⟩ / ⟨TOTAL⟩ B SCREEN")
                        .replacingOccurrences(
                            of: "⟨KEPT⟩", with: "\(plan.visibleScreenRetainedBytes)"
                        )
                        .replacingOccurrences(
                            of: "⟨TOTAL⟩", with: "\(plan.visibleScreenOriginalBytes)"
                        ))
                    .foregroundStyle(
                        plan.visibleScreenTruncated
                            ? RelayPalette.warning : RelayPalette.success
                    )
                }
            }
            .font(.system(size: 7.5, design: .monospaced))
            .foregroundStyle(RelayPalette.muted)
        }
        .padding(9)
        .background(RelayPalette.signal.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.signal.opacity(0.30), lineWidth: 1)
        }
    }

    private var recoveryObservationRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .foregroundStyle(RelayPalette.signal)
                Text(copy.text("RECOVERY CHANGES · ⟨N⟩")
                    .replacingOccurrences(of: "⟨N⟩", with: "\(recoveryObservations.count)"))
                    .fontWeight(.bold)
                    .foregroundStyle(RelayPalette.signal)
                Spacer()
                Text(copy.text("VISIBLE SCREEN EVIDENCE · NOT SUCCESS PROOF"))
                    .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 7.5, design: .monospaced))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(recoveryObservations) { observation in
                        let delta = RelayDecisionDelta(
                            parent: receipt.visibleScreen,
                            derived: observation.visibleScreen
                        )
                        Button {
                            updateState {
                                store.openDecisionRecoveryObservation(observation)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(observation.targetAgentName)
                                        .fontWeight(.bold)
                                        .foregroundStyle(RelayPalette.text)
                                    Text(observation.capturedAt.formatted(
                                        date: .abbreviated, time: .shortened
                                    ))
                                        .foregroundStyle(RelayPalette.muted)
                                }
                                Spacer(minLength: 8)
                                Text("+\(delta.addedCount)")
                                    .foregroundStyle(RelayPalette.success)
                                Text("−\(delta.removedCount)")
                                    .foregroundStyle(RelayPalette.danger)
                                Text("\(observation.visibleScreenBytes) B")
                                    .foregroundStyle(RelayPalette.muted)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 8, design: .monospaced))
                            .padding(.horizontal, 9)
                            .frame(width: 244, height: 38)
                            .background(RelayPalette.ink.opacity(0.62))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(RelayPalette.signal.opacity(0.28), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(copy.text("Open this private recovery change"))
                    }
                }
            }
        }
        .padding(9)
        .background(RelayPalette.signal.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.signal.opacity(0.24), lineWidth: 1)
        }
    }

    private func recoveryTargetChip(_ session: RelayTerminalSession) -> some View {
        let ready = session.isPromptStagingReady
        let selected = recoveryTargetID == session.id
        return Button {
            recoveryTargetID = session.id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ready ? session.accent : RelayPalette.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.agentName)
                        .fontWeight(.bold)
                    Text(RelayTerminalContext.projectName(session.cwd))
                        .foregroundStyle(RelayPalette.muted)
                }
            }
            .font(.system(size: 8.5, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(selected ? session.accent.opacity(0.14) : RelayPalette.ink.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        selected ? session.accent.opacity(0.72) : RelayPalette.line,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .opacity(ready ? 1 : 0.46)
        .help(copy.text(
            ready
                ? "Confirm this target is at an input prompt, then select it"
                : "This CLI has not enabled safe paste yet"
        ))
        .accessibilityValue(copy.text(
            !ready ? "SAFE PASTE UNAVAILABLE" : selected ? "SELECTED" : "CONFIRM PROMPT"
        ))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if recoveryVisible {
                Image(systemName: "lock.fill")
                    .foregroundStyle(RelayPalette.signal)
                Text(copy.text("Frozen receipt stays unchanged · no clipboard or disk"))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Button(copy.text("CANCEL"), action: closeRecovery)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                Button(copy.text("FILL TARGET · DOES NOT RUN"), action: recover)
                    .buttonStyle(ConsoleButtonStyle(
                        tint: selectedRecoveryTarget?.accent ?? RelayPalette.signal,
                        prominent: true
                    ))
                    .disabled(
                        recoveryPlan == nil
                            || selectedRecoveryTarget?.isPromptStagingReady != true
                    )
            } else {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(RelayPalette.signal)
                Text(copy.text(
                    "This receipt proves the captured chain only; it does not prove task completion or success."
                ))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                if isSaved {
                    Button(copy.text("BACK TO DECISION"), action: close)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                    Button(copy.text("RECOVER IN LIVE CLI"), action: openRecovery)
                        .buttonStyle(ConsoleButtonStyle(
                            tint: RelayPalette.signal,
                            prominent: true
                        ))
                } else {
                    if canReturnToReview {
                        Button(copy.text("BACK TO CLI REVIEW"), action: close)
                            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                    }
                    Button(copy.text("DISCARD TO DECISION")) {
                        confirmDiscard = true
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                    Button(copy.text("SAVE PRIVATE RECEIPT")) {
                        updateState { _ = store.saveDecisionActionReceipt() }
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
                }
            }
        }
    }

    private func openRecovery() {
        updateState { recoveryVisible = true }
        DispatchQueue.main.async { recoveryInstructionFocused = true }
    }

    private func closeRecovery() {
        updateState {
            recoveryVisible = false
            recoveryInstruction = ""
            recoveryTargetID = nil
        }
    }

    private func recover() {
        guard let recoveryTargetID else { return }
        let completed = store.completeDecisionActionRecovery(
            receipt: receipt,
            instruction: recoveryInstruction,
            targetID: recoveryTargetID
        )
        if completed {
            recoveryInstruction = ""
            self.recoveryTargetID = nil
            recoveryVisible = false
        }
    }

    private func close() {
        if recoveryVisible {
            closeRecovery()
            return
        }
        if !isSaved, !canReturnToReview {
            confirmDiscard = true
            return
        }
        updateState { store.returnFromDecisionActionReceipt() }
    }

    private func updateState(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 1.0), changes)
        }
    }
}

struct RelayDecisionLibraryDeck: View {
    @ObservedObject var store: RelayTerminalStore
    @State private var pendingTrash: RelayDecisionCheckpoint?
    @FocusState private var searchFocused: Bool
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var filteredCheckpoints: [RelayDecisionCheckpoint] {
        RelayDecisionSearch.filter(
            store.savedDecisionCheckpoints,
            query: store.decisionLibraryQuery,
            annotations: store.decisionAnnotations
        )
    }

    private var isSearching: Bool {
        store.decisionLibraryQuery.contains { !$0.isWhitespace }
    }

    var body: some View {
        let checkpoints = filteredCheckpoints
        return VStack(alignment: .leading, spacing: 12) {
            header(matchedCount: checkpoints.count)
            if !store.savedDecisionCheckpoints.isEmpty {
                searchBar
            }
            if store.savedDecisionCheckpoints.isEmpty {
                emptyState
            } else if checkpoints.isEmpty {
                noMatchesState
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 7) {
                        ForEach(checkpoints) { checkpoint in
                            row(checkpoint)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 1.0),
                        value: checkpoints.map(\.id)
                    )
                }
                .frame(maxHeight: 260)
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
                .stroke(RelayPalette.mix.opacity(0.46), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.46), radius: 26, y: 12)
        .confirmationDialog(
            copy.text("MOVE TO TRASH"),
            isPresented: Binding(
                get: { pendingTrash != nil },
                set: { if !$0 { pendingTrash = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(copy.text("MOVE TO TRASH"), role: .destructive) {
                guard let checkpoint = pendingTrash else { return }
                updateState { _ = store.moveDecisionCheckpointToTrash(checkpoint) }
                pendingTrash = nil
            }
            Button(copy.text("Cancel"), role: .cancel) {
                pendingTrash = nil
            }
        } message: {
            Text(copy.text("The checkpoint file can be recovered from Trash."))
        }
    }

    private func header(matchedCount: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "archivebox.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(RelayPalette.mix)
                .frame(width: 34, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text("DECISION LIBRARY"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                Text(copy.text("PRIVATE LOCAL FILES"))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
            Spacer()
            Text(isSearching
                ? "\(matchedCount) / \(store.savedDecisionCheckpoints.count)"
                : "\(store.savedDecisionCheckpoints.count)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(RelayPalette.mix)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RelayPalette.mix.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text("Close decision library"))
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(searchFocused ? RelayPalette.mix : RelayPalette.muted)
            TextField(
                copy.text("Search title, tag, agent, project, evidence, result or ID"),
                text: $store.decisionLibraryQuery
            )
            .textFieldStyle(.plain)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(RelayPalette.text)
            .focused($searchFocused)
            .accessibilityLabel(copy.text("SEARCH DECISIONS"))
            Spacer(minLength: 6)
            if isSearching {
                Button {
                    updateState { store.decisionLibraryQuery = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(RelayPalette.muted)
                .help(copy.text("Clear decision search"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RelayPalette.ink.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    searchFocused ? RelayPalette.mix.opacity(0.54) : RelayPalette.line,
                    lineWidth: 1
                )
        }
    }

    private func row(_ checkpoint: RelayDecisionCheckpoint) -> some View {
        let decision = checkpoint.decision
        let annotation = store.decisionAnnotation(for: checkpoint)
        let receiptCount = store.decisionActionReceipts(for: checkpoint).count
        let route = "\(decision.receipt.plan.sources.map(\.agentName).joined(separator: " + ")) → \(decision.result.agentName)"
        return HStack(spacing: 11) {
            RelayConfluenceMark(accents: decision.receipt.plan.sources.map {
                accent(for: $0.agentName)
            })
            VStack(alignment: .leading, spacing: 4) {
                Text(annotation?.title.isEmpty == false ? annotation!.title : route)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .lineLimit(1)
                if annotation?.title.isEmpty == false {
                    Text(route)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if decision.receipt.parentCheckpointID != nil {
                        Label(copy.text("REPLAY"), systemImage: "arrow.uturn.backward")
                            .fontWeight(.bold)
                            .foregroundStyle(RelayPalette.mix)
                    }
                    Text(checkpoint.savedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("·")
                    Text(decision.result.projectName)
                    Text("·")
                    Text("\(decision.receipt.plan.sources.count) → \(decision.receipt.plan.payloadBytes) B")
                        .monospacedDigit()
                    if receiptCount > 0 {
                        Text("·")
                        Label("\(receiptCount)", systemImage: "doc.text.magnifyingglass")
                            .foregroundStyle(RelayPalette.signal)
                    }
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
                .lineLimit(1)
                if let annotation, !annotation.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(annotation.tags.prefix(3)), id: \.self) { tag in
                            Text("#\(tag)")
                                .padding(.horizontal, 5)
                                .frame(height: 17)
                                .background(RelayPalette.mix.opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if annotation.tags.count > 3 {
                            Text("+\(annotation.tags.count - 3)")
                        }
                    }
                    .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayPalette.mix)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button {
                updateState { _ = store.toggleDecisionPin(checkpoint) }
            } label: {
                Image(systemName: annotation?.isPinned == true ? "pin.fill" : "pin")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(
                tint: annotation?.isPinned == true ? RelayPalette.warning : RelayPalette.muted
            ))
            .help(copy.text(annotation?.isPinned == true ? "UNPIN DECISION" : "PIN DECISION"))
            Button(copy.text("OPEN")) {
                updateState { store.openDecisionCheckpoint(checkpoint) }
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix, prominent: true))
            Button {
                pendingTrash = checkpoint
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
            .help(copy.text("MOVE TO TRASH"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 62)
        .background(RelayPalette.ink.opacity(0.64))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 9) {
            Image(systemName: "archivebox")
                .foregroundStyle(RelayPalette.muted)
            Text(copy.text("No saved decisions"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(RelayPalette.ink.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var noMatchesState: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(RelayPalette.muted)
            Text(copy.text("No matching decisions"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 92)
        .background(RelayPalette.ink.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .transition(.opacity)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(RelayPalette.success)
            Text(copy.text("Explicit saves only · private files 0600 · deletion moves to Trash"))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            let rejectedCount = store.decisionArchiveRejectedCount
                + store.decisionAnnotationRejectedCount
                + store.decisionActionReceiptRejectedCount
                + store.decisionRecoveryObservationRejectedCount
                + store.decisionRecoveryWitnessRejectedCount
            if rejectedCount > 0 {
                Spacer()
                Text("\(rejectedCount) \(copy.text("private decision files were ignored"))")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayPalette.warning)
            }
        }
    }

    private func accent(for agentName: String) -> SwiftUI.Color {
        switch agentName.lowercased() {
        case "claude": RelayPalette.claude
        case "codex": RelayPalette.signal
        case "ollama": RelayPalette.success
        default: RelayPalette.mix
        }
    }

    private func close() {
        updateState { store.closeDecisionLibrary() }
    }

    private func updateState(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 1.0), changes)
        }
    }
}

struct RelayResultArbitrationDecisionDeck: View {
    @ObservedObject var store: RelayTerminalStore
    let decision: RelayResultArbitrationDecision
    let checkpoint: RelayDecisionCheckpoint?
    @State private var confirmTrash = false
    @State private var deltaVisible = false
    @State private var comparisonCheckpointID: UUID?
    @State private var annotationEditorVisible = false
    @State private var annotationTitle = ""
    @State private var annotationTags = ""
    @State private var decisionBriefVisible = false
    @State private var decisionBriefInstruction = ""
    @State private var decisionBriefTargetID: UUID?
    @FocusState private var decisionBriefInstructionFocused: Bool
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }


    /// One-glance summary of the whole evidence chain under a checkpoint:
    /// actions -> recoveries -> witnesses with human-verdict tallies.
    private func evidenceTimeline(_ checkpoint: RelayDecisionCheckpoint) -> some View {
        let receipts = store.decisionActionReceipts(for: checkpoint)
        let observations = receipts.flatMap { store.decisionRecoveryObservations(for: $0) }
        let witnesses = observations.flatMap { store.decisionRecoveryWitnesses(for: $0) }
        let supports = witnesses.filter { $0.assessment == .supportsChange }.count
        let concerns = witnesses.filter { $0.assessment == .raisesConcern }.count
        let unclear = witnesses.filter { $0.assessment == .inconclusive }.count
        return HStack(spacing: 8) {
            Text(copy.text("EVIDENCE TIMELINE"))
                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(RelayPalette.muted)
            timelineNode("◆", copy.text("CHECKPOINT"), count: 1, tint: RelayPalette.mix)
            timelineArrow
            timelineNode("▶", copy.text("ACTIONS"), count: receipts.count, tint: RelayPalette.signal)
            timelineArrow
            timelineNode("↻", copy.text("RECOVERIES"), count: observations.count, tint: RelayPalette.warning)
            timelineArrow
            timelineNode("◎", copy.text("WITNESSES"), count: witnesses.count, tint: RelayPalette.success)
            if !witnesses.isEmpty {
                HStack(spacing: 4) {
                    if supports > 0 { verdictTally("✓\(supports)", tint: RelayPalette.success) }
                    if concerns > 0 { verdictTally("!\(concerns)", tint: RelayPalette.warning) }
                    if unclear > 0 { verdictTally("?\(unclear)", tint: RelayPalette.muted) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RelayPalette.raised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
    }

    private func timelineNode(
        _ glyph: String, _ label: String, count: Int, tint: SwiftUI.Color
    ) -> some View {
        HStack(spacing: 4) {
            Text(glyph)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
            Text(count > 1 ? "\(label) \(count)" : label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
        }
        .foregroundStyle(count > 0 ? tint : RelayPalette.muted.opacity(0.55))
    }

    private var timelineArrow: some View {
        Text("→")
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(RelayPalette.muted.opacity(0.6))
    }

    private func verdictTally(_ text: String, tint: SwiftUI.Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(tint.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var targetAccent: SwiftUI.Color {
        store.session(decision.result.id)?.accent ?? RelayPalette.mix
    }

    private var parentCheckpoint: RelayDecisionCheckpoint? {
        guard let parentID = decision.receipt.parentCheckpointID else { return nil }
        return store.savedDecisionCheckpoints.first { $0.id == parentID }
    }

    private var comparisonCheckpoint: RelayDecisionCheckpoint? {
        guard let comparisonCheckpointID else { return nil }
        return store.savedDecisionCheckpoints.first { $0.id == comparisonCheckpointID }
    }

    private var comparisonIsParent: Bool {
        comparisonCheckpointID == decision.receipt.parentCheckpointID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if let checkpoint, !deltaVisible {
                evidenceTimeline(checkpoint)
            }
            if let checkpoint, annotationEditorVisible, !deltaVisible {
                annotationEditor(checkpoint)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
            }
            if let checkpoint,
               !deltaVisible,
               let decisionLineage = store.decisionLineage(for: checkpoint),
               showsLineageNavigator(decisionLineage) {
                lineageNavigator(
                    checkpoint: checkpoint,
                    lineage: decisionLineage,
                    family: store.decisionFamily(for: checkpoint)
                )
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if deltaVisible, let comparisonCheckpoint {
                decisionDelta(comparisonCheckpoint)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
            } else {
                lineage
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .leading).combined(with: .opacity)
                    )
            }
            if let checkpoint, !deltaVisible, !decisionBriefVisible,
               !store.decisionActionReceipts(for: checkpoint).isEmpty {
                actionReceiptRail(checkpoint)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
            if let checkpoint, decisionBriefVisible, !deltaVisible {
                decisionBriefComposer(checkpoint)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
            footer
        }
        .padding(14)
        .background {
            ZStack {
                RelayMaterial(material: .hudWindow)
                RelayPalette.raised.opacity(0.84)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(RelayPalette.success.opacity(0.52), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.46), radius: 26, y: 12)
        .confirmationDialog(
            copy.text("MOVE TO TRASH"),
            isPresented: $confirmTrash,
            titleVisibility: .visible
        ) {
            Button(copy.text("MOVE TO TRASH"), role: .destructive, action: moveToTrash)
            Button(copy.text("Cancel"), role: .cancel) {}
        } message: {
            Text(copy.text("The checkpoint file can be recovered from Trash."))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: deltaVisible
                ? "arrow.left.arrow.right"
                : checkpoint == nil ? "seal.fill" : "archivebox.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(RelayPalette.success)
                .frame(width: 34, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text(
                    deltaVisible
                        ? "DECISION DELTA"
                        : checkpoint == nil && decision.receipt.parentCheckpointID != nil
                        ? "REPLAY DECISION"
                        : checkpoint == nil ? "DECISION SEAL" : "DECISION CHECKPOINT"
                ))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                Text(deltaVisible
                    ? copy.text(
                        comparisonIsParent
                            ? "Parent result ↔ derived result"
                            : "Reference result ↔ current result"
                    )
                    : checkpointSubtitle)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
            Spacer()
            if let checkpoint, !deltaVisible, !decisionBriefVisible {
                Button {
                    updateState { _ = store.toggleDecisionPin(checkpoint) }
                } label: {
                    Image(systemName: store.decisionAnnotation(for: checkpoint)?.isPinned == true
                        ? "pin.fill"
                        : "pin")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(ConsoleButtonStyle(
                    tint: store.decisionAnnotation(for: checkpoint)?.isPinned == true
                        ? RelayPalette.warning
                        : RelayPalette.muted
                ))
                .help(copy.text(
                    store.decisionAnnotation(for: checkpoint)?.isPinned == true
                        ? "UNPIN DECISION"
                        : "PIN DECISION"
                ))
                Button(copy.text(annotationEditorVisible ? "CLOSE LABEL" : "EDIT LABEL")) {
                    toggleAnnotationEditor(checkpoint)
                }
                .buttonStyle(ConsoleButtonStyle(
                    tint: RelayPalette.mix,
                    prominent: annotationEditorVisible
                ))
            }
            if let parentCheckpoint, !deltaVisible, !decisionBriefVisible {
                Button(copy.text("COMPARE RESULTS")) {
                    showDelta(against: parentCheckpoint)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix, prominent: true))
                Button(copy.text("VIEW PARENT")) {
                    viewParent(parentCheckpoint)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
            }
            Text(copy.text(
                deltaVisible
                    ? "READ-ONLY FILES · LOCAL DIFF"
                    : checkpoint != nil && decision.receipt.parentCheckpointID != nil
                    ? "DERIVED CHECKPOINT · 0600"
                    : checkpoint == nil
                        ? "EXPLICIT · LOCAL MEMORY · READ ONLY"
                        : "EVIDENCE READ ONLY · PRIVATE 0600"
            ))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(RelayPalette.success)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RelayPalette.success.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text(
                deltaVisible
                    ? comparisonIsParent ? "BACK TO DERIVED" : "BACK TO CHECKPOINT"
                    : checkpoint == nil ? "BACK TO ARBITER REVIEW" : "BACK TO LIBRARY"
            ))
        }
    }

    private func annotationEditor(_ checkpoint: RelayDecisionCheckpoint) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(RelayPalette.mix)
                Text(copy.text("PRIVATE DECISION LABEL"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                Spacer()
                Text("\(annotationTitle.count) / \(RelayDecisionAnnotation.maxTitleCharacters)")
                    .font(.system(size: 7.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(
                        annotationTitle.count > RelayDecisionAnnotation.maxTitleCharacters
                            ? RelayPalette.danger
                            : RelayPalette.muted
                    )
            }
            HStack(spacing: 8) {
                TextField(copy.text("Decision title"), text: $annotationTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9.5, design: .monospaced))
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(RelayPalette.ink.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(RelayPalette.line, lineWidth: 1)
                    }
                TextField(copy.text("Tags separated by commas"), text: $annotationTags)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9.5, design: .monospaced))
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(RelayPalette.ink.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(RelayPalette.line, lineWidth: 1)
                    }
                Button(copy.text("SAVE LABEL")) {
                    saveAnnotation(checkpoint)
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success, prominent: true))
                Button(copy.text("Cancel")) {
                    updateState { annotationEditorVisible = false }
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            }
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                Text(copy.text("Title and tags are stored separately; frozen evidence stays unchanged"))
                Spacer()
                Text(copy.text("8 TAGS MAX · 24 CHARACTERS EACH"))
            }
            .font(.system(size: 7.5, design: .monospaced))
            .foregroundStyle(RelayPalette.muted)
        }
        .padding(9)
        .background(RelayPalette.mix.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.mix.opacity(0.28), lineWidth: 1)
        }
    }

    private func decisionDelta(_ reference: RelayDecisionCheckpoint) -> some View {
        let delta = RelayDecisionDelta(
            parent: reference.decision.result.text,
            derived: decision.result.text
        )
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(copy.text(
                    "+⟨ADDED⟩ added · −⟨REMOVED⟩ removed · =⟨UNCHANGED⟩ unchanged"
                )
                    .replacingOccurrences(of: "⟨ADDED⟩", with: "\(delta.addedCount)")
                    .replacingOccurrences(of: "⟨REMOVED⟩", with: "\(delta.removedCount)")
                    .replacingOccurrences(of: "⟨UNCHANGED⟩", with: "\(delta.unchangedCount)"))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                if delta.parentTruncated || delta.derivedTruncated {
                    Text(copy.text("EARLIER LINES OMITTED"))
                        .foregroundStyle(RelayPalette.warning)
                }
                Text(copy.text("LAST 64 KB · 300 LINES MAX"))
                    .foregroundStyle(RelayPalette.mix)
            }
            .font(.system(size: 7.5, weight: .bold, design: .monospaced))

            VStack(spacing: 0) {
                HStack(spacing: 1) {
                    deltaColumnHeader(
                        title: comparisonIsParent ? "PARENT RESULT" : "REFERENCE RESULT",
                        agent: reference.decision.result.agentName,
                        tint: RelayPalette.danger
                    )
                    deltaColumnHeader(
                        title: comparisonIsParent ? "DERIVED RESULT" : "CURRENT RESULT",
                        agent: decision.result.agentName,
                        tint: RelayPalette.success
                    )
                }
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 1) {
                        ForEach(delta.rows) { row in
                            HStack(spacing: 1) {
                                deltaCell(
                                    text: row.kind == .added ? nil : row.text,
                                    lineNumber: row.parentLineNumber,
                                    marker: row.kind == .removed ? "−" : " ",
                                    tint: row.kind == .removed ? RelayPalette.danger : nil
                                )
                                deltaCell(
                                    text: row.kind == .removed ? nil : row.text,
                                    lineNumber: row.derivedLineNumber,
                                    marker: row.kind == .added ? "+" : " ",
                                    tint: row.kind == .added ? RelayPalette.success : nil
                                )
                            }
                        }
                    }
                }
            }
            .background(RelayPalette.ink.opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(RelayPalette.mix.opacity(0.34), lineWidth: 1)
            }
        }
        .frame(height: 182)
    }

    private func deltaColumnHeader(
        title: String,
        agent: String,
        tint: SwiftUI.Color
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(copy.text(title))
                .fontWeight(.bold)
                .foregroundStyle(tint)
            Text("· \(agent)")
                .foregroundStyle(RelayPalette.muted)
                .lineLimit(1)
            Spacer()
        }
        .font(.system(size: 8, design: .monospaced))
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 28)
        .background(tint.opacity(0.09))
    }

    @ViewBuilder
    private func deltaCell(
        text: String?,
        lineNumber: Int?,
        marker: String,
        tint: SwiftUI.Color?
    ) -> some View {
        if let text, let lineNumber {
            HStack(spacing: 5) {
                Text("\(lineNumber)")
                    .foregroundStyle(RelayPalette.muted.opacity(0.72))
                    .frame(width: 24, alignment: .trailing)
                Text(marker)
                    .fontWeight(.bold)
                    .foregroundStyle(tint ?? RelayPalette.muted)
                    .frame(width: 8)
                Text(text.isEmpty ? " " : text)
                    .foregroundStyle(RelayPalette.text)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(.system(size: 8.5, design: .monospaced))
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
            .background((tint ?? RelayPalette.raised).opacity(tint == nil ? 0.28 : 0.12))
        } else {
            RelayPalette.ink.opacity(0.46)
                .frame(maxWidth: .infinity, minHeight: 21)
        }
    }

    private var lineage: some View {
        HStack(spacing: 10) {
            sourceCard
                .frame(width: 226)
            lineageArrow
            payloadCard
                .frame(width: 142)
            lineageArrow
            resultCard
                .frame(maxWidth: .infinity)
        }
        .frame(height: 182)
    }

    private func showsLineageNavigator(_ lineage: RelayDecisionLineage) -> Bool {
        !lineage.ancestors.isEmpty
            || !lineage.children.isEmpty
            || lineage.missingParentID != nil
            || lineage.cycleDetected
            || lineage.depthLimited
    }

    private func lineageNavigator(
        checkpoint: RelayDecisionCheckpoint,
        lineage: RelayDecisionLineage,
        family: RelayDecisionFamily?
    ) -> some View {
        let comparisonCandidates = lineageComparisonCandidates(family)
        return HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(RelayPalette.mix)
            Text(copy.text("LINEAGE"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.55)
                .foregroundStyle(RelayPalette.mix)
            if lineage.missingParentID != nil {
                lineageStatus("PARENT MISSING", tint: RelayPalette.warning)
            }
            if lineage.cycleDetected {
                lineageStatus("CYCLE BLOCKED", tint: RelayPalette.danger)
            }
            if lineage.depthLimited {
                lineageStatus("DEPTH LIMIT", tint: RelayPalette.warning)
            }
            if family?.limited == true {
                lineageStatus("FAMILY LIMIT", tint: RelayPalette.warning)
            }
            if !comparisonCandidates.isEmpty {
                lineageComparisonMenu(comparisonCandidates)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(lineage.ancestors.enumerated()), id: \.element.id) {
                        index, ancestor in
                        lineageNode(
                            ancestor,
                            label: ancestorLabel(index: index, lineage: lineage),
                            tint: RelayPalette.muted
                        )
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(RelayPalette.muted)
                    }
                    HStack(spacing: 4) {
                        Circle()
                            .fill(RelayPalette.mix)
                            .frame(width: 4, height: 4)
                        Text("\(currentGenerationLabel(lineage)) · \(copy.text("CURRENT NODE"))")
                            .fontWeight(.bold)
                        Text("· \(checkpoint.decision.result.agentName)")
                            .foregroundStyle(RelayPalette.muted)
                    }
                    .font(.system(size: 7.5, design: .monospaced))
                    .padding(.horizontal, 7)
                    .frame(height: 23)
                    .background(RelayPalette.mix.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(RelayPalette.mix.opacity(0.42), lineWidth: 1)
                    }
                    ForEach(lineage.children) { child in
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(RelayPalette.success)
                        lineageNode(
                            child,
                            label: "\(childGenerationLabel(lineage)) · \(copy.text("CHILD"))",
                            tint: RelayPalette.success
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 31)
        .background(RelayPalette.ink.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.mix.opacity(0.24), lineWidth: 1)
        }
    }

    private func lineageComparisonCandidates(
        _ family: RelayDecisionFamily?
    ) -> [RelayDecisionCheckpoint] {
        family?.members.filter { $0.id != decision.receipt.parentCheckpointID } ?? []
    }

    private func lineageComparisonMenu(
        _ candidates: [RelayDecisionCheckpoint]
    ) -> some View {
        Menu {
            ForEach(candidates) { candidate in
                Button {
                    showDelta(against: candidate)
                } label: {
                    Text(
                        "\(candidate.decision.result.agentName) · "
                            + candidate.savedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.left.arrow.right")
                Text(copy.text("COMPARE LINEAGE"))
            }
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundStyle(RelayPalette.mix)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RelayPalette.mix.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(copy.text("Compare any connected checkpoint"))
    }

    private func ancestorLabel(index: Int, lineage: RelayDecisionLineage) -> String {
        guard reachesLineageRoot(lineage) else { return "G?" }
        return index == 0 ? copy.text("ROOT") : "G\(index)"
    }

    private func currentGenerationLabel(_ lineage: RelayDecisionLineage) -> String {
        reachesLineageRoot(lineage) ? "G\(lineage.ancestors.count)" : "G?"
    }

    private func childGenerationLabel(_ lineage: RelayDecisionLineage) -> String {
        reachesLineageRoot(lineage) ? "G\(lineage.ancestors.count + 1)" : "G?"
    }

    private func reachesLineageRoot(_ lineage: RelayDecisionLineage) -> Bool {
        !lineage.cycleDetected
            && !lineage.depthLimited
            && lineage.missingParentID == nil
    }

    private func lineageNode(
        _ node: RelayDecisionCheckpoint,
        label: String,
        tint: SwiftUI.Color
    ) -> some View {
        Button {
            updateState { store.openDecisionCheckpoint(node) }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .fontWeight(.bold)
                Text("· \(node.decision.result.agentName)")
                    .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 7.5, design: .monospaced))
            .padding(.horizontal, 7)
            .frame(height: 23)
            .background(tint.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(tint.opacity(0.30), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(copy.text("Open checkpoint in lineage"))
    }

    private func lineageStatus(_ key: String, tint: SwiftUI.Color) -> some View {
        Text(copy.text(key))
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(tint.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("FROZEN SOURCES", value: "\(decision.receipt.plan.sources.count)")
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(decision.receipt.plan.sources) { source in
                        let accent = store.session(source.id)?.accent ?? RelayPalette.muted
                        HStack(spacing: 6) {
                            Circle()
                                .fill(accent)
                                .frame(width: 5, height: 5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.agentName)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .lineLimit(1)
                                Text("\(source.retainedBytes) / \(source.originalBytes) B")
                                    .font(.system(size: 7.5, design: .monospaced))
                                    .foregroundStyle(RelayPalette.muted)
                            }
                            Spacer(minLength: 2)
                            Text(copy.text(source.truncated ? "TAIL KEPT" : "FULL"))
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(source.truncated ? RelayPalette.warning : RelayPalette.success)
                        }
                    }
                }
                .padding(9)
            }
        }
        .decisionCard(tint: RelayPalette.mix)
    }

    private var payloadCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader("EXACT PAYLOAD", value: nil)
            VStack(spacing: 6) {
                Text("\(decision.receipt.plan.payloadBytes)")
                    .font(.system(size: 25, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayPalette.mix)
                    .monospacedDigit()
                Text(copy.text("UTF-8 BYTES"))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(RelayPalette.muted)
                Divider().overlay(RelayPalette.mix.opacity(0.22))
                Text(copy.text("⟨N⟩ frozen sources")
                    .replacingOccurrences(
                        of: "⟨N⟩",
                        with: "\(decision.receipt.plan.sources.count)"
                    ))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(9)
        }
        .decisionCard(tint: RelayPalette.mix)
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(targetAccent)
                    .frame(width: 5, height: 5)
                Text(copy.text("ARBITER RESULT"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(targetAccent)
                Text("· \(decision.result.agentName) · \(decision.result.projectName)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .lineLimit(1)
                Spacer()
                Text(copy.text("SEALED"))
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.success)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(targetAccent.opacity(0.10))

            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(decision.result.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(9)
            }
            .background(RelayPalette.ink.opacity(0.86))
        }
        .decisionCard(tint: targetAccent)
    }

    private var lineageArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(RelayPalette.mix)
            .accessibilityHidden(true)
    }

    private func actionReceiptRail(_ checkpoint: RelayDecisionCheckpoint) -> some View {
        let receipts = store.decisionActionReceipts(for: checkpoint)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(RelayPalette.signal)
                Text(copy.text("ACTION RECEIPTS · ⟨N⟩")
                    .replacingOccurrences(of: "⟨N⟩", with: "\(receipts.count)"))
                    .fontWeight(.bold)
                    .foregroundStyle(RelayPalette.signal)
                Spacer()
                Text(copy.text("CURRENT SCREENS · NOT SUCCESS PROOF"))
                    .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 7.5, design: .monospaced))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(receipts) { receipt in
                        let recoveryCount = store.decisionRecoveryObservations(for: receipt).count
                        Button {
                            updateState { store.openDecisionActionReceipt(receipt) }
                        } label: {
                            HStack(spacing: 7) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(receipt.targetAgentName)
                                        .fontWeight(.bold)
                                        .foregroundStyle(RelayPalette.text)
                                    Text(receipt.capturedAt.formatted(
                                        date: .abbreviated, time: .shortened
                                    ))
                                        .foregroundStyle(RelayPalette.muted)
                                }
                                Spacer(minLength: 8)
                                Text("⏎")
                                    .fontWeight(.bold)
                                    .foregroundStyle(RelayPalette.signal)
                                if recoveryCount > 0 {
                                    Text("Δ \(recoveryCount)")
                                        .fontWeight(.bold)
                                        .foregroundStyle(RelayPalette.success)
                                }
                                Text("\(receipt.visibleScreenBytes) B")
                                    .foregroundStyle(RelayPalette.muted)
                                    .monospacedDigit()
                            }
                            .font(.system(size: 8, design: .monospaced))
                            .padding(.horizontal, 9)
                            .frame(width: 220, height: 38)
                            .background(RelayPalette.ink.opacity(0.62))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(RelayPalette.signal.opacity(0.28), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(copy.text("Open this private action receipt"))
                    }
                }
            }
        }
        .padding(9)
        .background(RelayPalette.signal.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.signal.opacity(0.24), lineWidth: 1)
        }
    }

    private var liveDecisionBriefTargets: [RelayTerminalSession] {
        store.sessions.filter { !$0.exited }
    }

    private var selectedDecisionBriefTarget: RelayTerminalSession? {
        guard let decisionBriefTargetID else { return nil }
        return store.session(decisionBriefTargetID)
    }

    private func decisionBriefPlan(
        _ checkpoint: RelayDecisionCheckpoint
    ) -> RelayDecisionBriefPlan? {
        RelayDecisionBrief.plan(
            checkpoint: checkpoint,
            annotation: store.decisionAnnotation(for: checkpoint),
            instruction: decisionBriefInstruction
        )
    }

    private func decisionBriefComposer(_ checkpoint: RelayDecisionCheckpoint) -> some View {
        let plan = decisionBriefPlan(checkpoint)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(RelayPalette.success)
                Text(copy.text("DECISION → ACTION BRIDGE"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.65)
                    .foregroundStyle(RelayPalette.success)
                Spacer()
                Text(copy.text("LOCAL · FILL ONLY · DOES NOT RUN"))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.success)
            }

            HStack(spacing: 8) {
                decisionBriefEndpoint(
                    icon: "seal.fill",
                    title: "SEALED RESULT",
                    detail: "\(plan?.decisionOriginalBytes ?? decision.result.text.utf8.count) B",
                    tint: RelayPalette.success
                )
                decisionBriefArrow
                VStack(spacing: 2) {
                    Text("\(plan?.payloadBytes ?? 0)")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(plan == nil ? RelayPalette.danger : RelayPalette.mix)
                        .monospacedDigit()
                    Text(copy.text("UTF-8 B"))
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                    Text(copy.text(plan?.decisionTruncated == true ? "TAIL KEPT" : "FULL"))
                        .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            plan?.decisionTruncated == true
                                ? RelayPalette.warning : RelayPalette.success
                        )
                }
                .frame(width: 74, height: 48)
                .background(RelayPalette.mix.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(RelayPalette.mix.opacity(0.32), lineWidth: 1)
                }
                decisionBriefArrow
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if liveDecisionBriefTargets.isEmpty {
                            Text(copy.text("OPEN A TERMINAL TO CHOOSE A TARGET"))
                                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(RelayPalette.warning)
                                .padding(.horizontal, 8)
                        } else {
                            ForEach(liveDecisionBriefTargets) { session in
                                decisionBriefTargetChip(session)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $decisionBriefInstruction)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .focused($decisionBriefInstructionFocused)
                if decisionBriefInstruction.isEmpty {
                    Text(copy.text("Optional next instruction for the target CLI…"))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted.opacity(0.72))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 48)
            .background(RelayPalette.ink.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(plan == nil ? RelayPalette.danger.opacity(0.55) : RelayPalette.line)
            }

            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill")
                Text(copy.text(
                    "Relay adds checkpoint provenance, fills one prompt-ready CLI, and leaves Return to you."
                ))
                Spacer()
                if let plan {
                    Text(copy.text("⟨KEPT⟩ / ⟨TOTAL⟩ B RESULT")
                        .replacingOccurrences(of: "⟨KEPT⟩", with: "\(plan.decisionRetainedBytes)")
                        .replacingOccurrences(of: "⟨TOTAL⟩", with: "\(plan.decisionOriginalBytes)"))
                        .foregroundStyle(
                            plan.decisionTruncated ? RelayPalette.warning : RelayPalette.success
                        )
                }
            }
            .font(.system(size: 7.5, design: .monospaced))
            .foregroundStyle(RelayPalette.muted)
        }
        .padding(9)
        .background(RelayPalette.success.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.success.opacity(0.30), lineWidth: 1)
        }
    }

    private func decisionBriefEndpoint(
        icon: String,
        title: String,
        detail: String,
        tint: SwiftUI.Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text(title))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                Text(detail)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 132, height: 48, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        }
    }

    private var decisionBriefArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(RelayPalette.mix)
            .accessibilityHidden(true)
    }

    private func decisionBriefTargetChip(_ session: RelayTerminalSession) -> some View {
        let ready = session.isPromptStagingReady
        let selected = decisionBriefTargetID == session.id
        return Button {
            decisionBriefTargetID = session.id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ready ? session.accent : RelayPalette.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.agentName)
                        .fontWeight(.bold)
                    Text(RelayTerminalContext.projectName(session.cwd))
                        .foregroundStyle(RelayPalette.muted)
                }
            }
            .font(.system(size: 8, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(selected ? session.accent.opacity(0.14) : RelayPalette.ink.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? session.accent.opacity(0.72) : RelayPalette.line)
            }
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .opacity(ready ? 1 : 0.48)
        .help(copy.text(
            ready
                ? "Select this prompt-ready CLI"
                : "This CLI has not enabled safe paste yet"
        ))
    }

    private func cardHeader(_ key: String, value: String?) -> some View {
        HStack {
            Text(copy.text(key))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.mix)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(RelayPalette.mix.opacity(0.10))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: deltaVisible ? "lock.fill" : checkpoint == nil ? "hand.tap" : "lock.fill")
                .foregroundStyle(RelayPalette.success)
            Text(deltaVisible
                ? copy.text(
                    comparisonIsParent
                        ? "Parent and derived checkpoints stay unchanged"
                        : "Compared checkpoints stay unchanged"
                )
                : footerCopy)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            Spacer()
            if deltaVisible {
                Button(copy.text(
                    comparisonIsParent ? "BACK TO DERIVED" : "BACK TO CHECKPOINT"
                ), action: closeDelta)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix, prominent: true))
            } else if let checkpoint {
                if decisionBriefVisible {
                    Button(copy.text("Cancel"), action: closeDecisionBrief)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    Button(copy.text("FILL TARGET · DOES NOT RUN")) {
                        fillDecisionBrief(checkpoint)
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success, prominent: true))
                    .disabled(
                        decisionBriefPlan(checkpoint) == nil
                            || selectedDecisionBriefTarget?.isPromptStagingReady != true
                    )
                } else {
                    Button(copy.text("CONTINUE FROM DECISION")) {
                        openDecisionBrief(checkpoint)
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success, prominent: true))
                    .disabled(!store.canBeginDecisionCheckpointReplay)
                    .help(copy.text("Carry this sealed result into one live CLI without running it"))
                    Button(copy.text("RE-ARBITRATE FROM CHECKPOINT")) {
                        replay(checkpoint)
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                    .disabled(!store.canBeginDecisionCheckpointReplay)
                    .help(copy.text("Re-evaluate this frozen evidence with any live CLI"))
                    Button(copy.text("MOVE TO TRASH")) {
                        confirmTrash = true
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.danger))
                    Button(copy.text("BACK TO LIBRARY"), action: close)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                }
            } else {
                Button(copy.text(
                    store.liveDecisionCheckpointID == nil
                        ? "SAVE PRIVATE CHECKPOINT"
                        : "OPEN DECISION LIBRARY"
                ), action: saveOrOpenLibrary)
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success, prominent: true))
                Button(copy.text("BACK TO ARBITER REVIEW"), action: returnToReview)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
            }
        }
    }

    private var checkpointSubtitle: String {
        guard let checkpoint else {
            return copy.text("Frozen sources → exact payload → arbiter result")
        }
        let date = checkpoint.savedAt.formatted(date: .abbreviated, time: .shortened)
        guard let title = store.decisionAnnotation(for: checkpoint)?.title,
              !title.isEmpty else { return date }
        return "\(title) · \(date)"
    }

    private var footerCopy: String {
        checkpoint == nil
            ? copy.text(
                store.liveDecisionCheckpointID == nil
                    ? "Writes this frozen chain to Relay Application Support"
                    : "CHECKPOINT SAVED"
            )
            : copy.text("Explicit saves only · private files 0600 · deletion moves to Trash")
    }

    private func saveOrOpenLibrary() {
        if store.liveDecisionCheckpointID == nil {
            _ = store.saveResultArbitrationDecision()
        } else {
            updateState { store.showDecisionLibrary(returningToLiveDecision: true) }
        }
    }

    private func toggleAnnotationEditor(_ checkpoint: RelayDecisionCheckpoint) {
        updateState {
            if annotationEditorVisible {
                annotationEditorVisible = false
            } else {
                let annotation = store.decisionAnnotation(for: checkpoint)
                annotationTitle = annotation?.title ?? ""
                annotationTags = annotation?.tags.joined(separator: ", ") ?? ""
                annotationEditorVisible = true
            }
        }
    }

    private func saveAnnotation(_ checkpoint: RelayDecisionCheckpoint) {
        let isPinned = store.decisionAnnotation(for: checkpoint)?.isPinned ?? false
        guard store.updateDecisionAnnotation(
            for: checkpoint,
            title: annotationTitle,
            tagsText: annotationTags,
            isPinned: isPinned
        ) else { return }
        updateState { annotationEditorVisible = false }
    }

    private func moveToTrash() {
        guard let checkpoint else { return }
        updateState { _ = store.moveDecisionCheckpointToTrash(checkpoint) }
    }

    private func replay(_ checkpoint: RelayDecisionCheckpoint) {
        updateState { _ = store.beginDecisionCheckpointReplay(checkpoint) }
    }

    private func openDecisionBrief(_ checkpoint: RelayDecisionCheckpoint) {
        updateState {
            annotationEditorVisible = false
            deltaVisible = false
            comparisonCheckpointID = nil
            decisionBriefInstruction = ""
            decisionBriefTargetID = store.focusedID.flatMap { id in
                store.session(id)?.isPromptStagingReady == true ? id : nil
            } ?? liveDecisionBriefTargets.first(where: \.isPromptStagingReady)?.id
            decisionBriefVisible = true
        }
        DispatchQueue.main.async { decisionBriefInstructionFocused = true }
    }

    private func closeDecisionBrief() {
        updateState {
            decisionBriefVisible = false
            decisionBriefInstruction = ""
            decisionBriefTargetID = nil
        }
    }

    private func fillDecisionBrief(_ checkpoint: RelayDecisionCheckpoint) {
        guard let decisionBriefTargetID else { return }
        _ = store.completeDecisionBrief(
            checkpoint: checkpoint,
            instruction: decisionBriefInstruction,
            targetID: decisionBriefTargetID
        )
    }

    private func viewParent(_ parent: RelayDecisionCheckpoint) {
        updateState {
            store.showDecisionLibrary(returningToLiveDecision: checkpoint == nil)
            store.openDecisionCheckpoint(parent)
        }
    }

    private func showDelta(against reference: RelayDecisionCheckpoint) {
        updateState {
            comparisonCheckpointID = reference.id
            deltaVisible = true
        }
    }

    private func close() {
        if deltaVisible {
            closeDelta()
            return
        }
        if checkpoint == nil {
            returnToReview()
        } else {
            updateState { store.returnFromDecisionCheckpoint() }
        }
    }

    private func closeDelta() {
        updateState {
            deltaVisible = false
            comparisonCheckpointID = nil
        }
    }

    private func returnToReview() {
        updateState { store.returnFromResultArbitrationDecision() }
    }

    private func updateState(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 1.0)) {
                changes()
            }
        }
    }
}

struct RelayResultConfluenceDeck: View {
    @ObservedObject var store: RelayTerminalStore
    let confluence: RelayResultConfluence
    @State private var arbitrationOpen: Bool
    @State private var arbitrationInstruction = ""
    @State private var selectedTargetID: UUID?
    @State private var sourceDrift: [UUID: RelayResultSnapshotDrift] = [:]
    @FocusState private var arbitrationFocused: Bool
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }

    init(store: RelayTerminalStore, confluence: RelayResultConfluence) {
        self.store = store
        self.confluence = confluence
        _arbitrationOpen = State(
            initialValue: store.resultConfluenceReplayCheckpointID != nil
        )
    }

    private var isCheckpointReplay: Bool {
        store.resultConfluenceReplayCheckpointID != nil
    }

    private var arbitrationReceipt: RelayResultArbitrationReceipt? {
        guard let receipt = store.resultArbitrationReceipt,
              receipt.confluence.id == confluence.id else { return nil }
        return receipt
    }

    private var accents: [SwiftUI.Color] {
        confluence.snapshots.map { snapshot in
            store.session(snapshot.id)?.accent ?? RelayPalette.muted
        }
    }

    private var snapshotWidth: CGFloat {
        confluence.snapshots.count == 2 ? 360 : 264
    }

    private var runningSessions: [RelayTerminalSession] {
        store.zOrder.compactMap { id in
            guard let session = store.session(id), !session.exited else { return nil }
            return session
        }
    }

    private var selectedTarget: RelayTerminalSession? {
        selectedTargetID.flatMap(store.session)
    }

    private var arbitrationPlan: RelayResultArbitrationPlan? {
        RelayResultArbitration.plan(
            instruction: arbitrationInstruction,
            snapshots: confluence.snapshots
        )
    }

    private var canArbitrate: Bool {
        selectedTarget?.isPromptStagingReady == true && arbitrationPlan != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            snapshotRail
            if arbitrationOpen {
                arbitrationComposer
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
            footer
        }
        .padding(14)
        .background {
            ZStack {
                RelayMaterial(material: .hudWindow)
                RelayPalette.raised.opacity(0.80)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(RelayPalette.mix.opacity(0.46), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.46), radius: 26, y: 12)
        .onChange(of: runningSessions.map(\.id)) { _, availableIDs in
            if let selectedTargetID, !availableIDs.contains(selectedTargetID) {
                self.selectedTargetID = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            if isCheckpointReplay {
                RelayDecisionReplayMark()
            } else {
                RelayConfluenceMark(accents: accents)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text(
                    isCheckpointReplay
                        ? "CHECKPOINT REPLAY"
                        : arbitrationReceipt == nil ? "RESULT CONFLUENCE" : "ARBITRATION SOURCES"
                ))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                Text(copy.text(
                    isCheckpointReplay
                        ? "Frozen evidence reopened · parent stays unchanged"
                        : arbitrationReceipt == nil
                            ? "⟨N⟩ CLI screens frozen at one explicit moment"
                            : "⟨N⟩ frozen screens behind this arbitration"
                )
                    .replacingOccurrences(of: "⟨N⟩", with: "\(confluence.snapshots.count)"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
            Spacer()
            Text(copy.text(
                isCheckpointReplay
                    ? "PARENT CHECKPOINT · READ ONLY"
                    : arbitrationReceipt == nil
                        ? "LOCAL MEMORY · EXPLICIT SNAPSHOT"
                        : "LOCAL MEMORY · READ ONLY"
            ))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.45)
                .foregroundStyle(RelayPalette.success)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RelayPalette.success.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text(
                isCheckpointReplay
                    ? "BACK TO CHECKPOINT"
                    : arbitrationReceipt == nil
                        ? "Close and clear collected screens"
                        : "BACK TO ARBITER REVIEW"
            ))
        }
    }

    private var snapshotRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 9) {
                ForEach(confluence.snapshots) { snapshot in
                    snapshotCard(snapshot)
                        .frame(width: snapshotWidth)
                }
            }
        }
    }

    private func snapshotCard(_ snapshot: RelayResultSnapshot) -> some View {
        let session = store.session(snapshot.id)
        let live = session?.exited == false
        let accent = session?.accent ?? RelayPalette.muted
        let drift = arbitrationReceipt == nil ? nil : sourceDrift[snapshot.id]
        let statusKey: String = if isCheckpointReplay {
            "ARCHIVED SOURCE"
        } else {
            switch drift {
            case .unchanged: "UNCHANGED"
            case .changed: "CHANGED"
            case .closed: "CLI CLOSED"
            case nil: live ? "LIVE CLI" : "CLI CLOSED"
            }
        }
        let statusTint: SwiftUI.Color = if isCheckpointReplay {
            RelayPalette.mix
        } else {
            switch drift {
            case .unchanged: RelayPalette.success
            case .changed: RelayPalette.warning
            case .closed: RelayPalette.muted
            case nil: live ? RelayPalette.success : RelayPalette.muted
            }
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 5, height: 5)
                Text(snapshot.agentName)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                Text("· \(snapshot.projectName)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Text(copy.text(statusKey))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusTint)
                Button {
                    _ = store.focusResultSnapshot(snapshot.id)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(ConsoleButtonStyle(tint: accent))
                .disabled(!live)
                .help(copy.text("Focus live CLI"))
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(accent.opacity(0.10))

            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(snapshot.text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(9)
            }
            .frame(height: 142)
            .background(RelayPalette.ink.opacity(0.86))
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(accent.opacity(0.34), lineWidth: 1)
        }
    }

    private var arbitrationComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RelayPalette.mix)
                VStack(alignment: .leading, spacing: 1) {
                    Text(copy.text("RESULT ARBITRATION"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                    Text(copy.text("Give one CLI every frozen screen"))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                }
                Spacer()
                Text(copy.text("FROZEN RESULTS · FILL ONLY"))
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .tracking(0.35)
                    .foregroundStyle(RelayPalette.success)
            }

            TextField(
                copy.text("What should the deciding CLI do with these results?"),
                text: $arbitrationInstruction
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(RelayPalette.text)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RelayPalette.ink.opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        arbitrationInstruction.isEmpty
                            ? RelayPalette.line : RelayPalette.mix.opacity(0.48),
                        lineWidth: 1
                    )
            }
            .focused($arbitrationFocused)

            HStack(spacing: 7) {
                Text(copy.text("ARBITER"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if runningSessions.isEmpty {
                            Text(copy.text("No arbiter yet — open an agent's CLI terminal from the left sidebar and let it reach its input prompt."))
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(RelayPalette.warning)
                                .fixedSize()
                        }
                        ForEach(runningSessions) { session in
                            arbitrationTargetChip(session)
                        }
                    }
                }
                Text(copy.text("⟨N⟩ frozen sources · 64 KB max")
                    .replacingOccurrences(of: "⟨N⟩", with: "\(confluence.snapshots.count)"))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .fixedSize()
            }
            .frame(height: 26)

            arbitrationPreflight
        }
        .padding(9)
        .background(RelayPalette.ink.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke((selectedTarget?.accent ?? RelayPalette.mix).opacity(0.34), lineWidth: 1)
        }
    }

    private var arbitrationPreflight: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "ruler")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(RelayPalette.mix)
                Text(copy.text("PAYLOAD PREFLIGHT"))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.45)
                Text(copy.text("UTF-8 BYTES · NO TOKEN GUESS"))
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                if let arbitrationPlan {
                    Text("\(arbitrationPlan.payloadBytes) / \(RelayPromptStaging.maxBytes) B")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(RelayPalette.success)
                }
            }

            if let arbitrationPlan {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(arbitrationPlan.sources) { source in
                            arbitrationSourceBudget(source)
                        }
                    }
                }
            } else {
                Text(copy.text("Enter an instruction to preview exact local bytes"))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RelayPalette.raised.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
    }

    private func arbitrationSourceBudget(
        _ source: RelayResultArbitrationSourcePlan
    ) -> some View {
        let accent = store.session(source.id)?.accent ?? RelayPalette.muted
        let status = source.truncated ? "TAIL KEPT" : "FULL"
        let statusColor = source.truncated ? RelayPalette.warning : RelayPalette.success
        return HStack(spacing: 5) {
            Circle()
                .fill(accent)
                .frame(width: 4, height: 4)
            Text(source.agentName)
                .fontWeight(.bold)
                .foregroundStyle(accent)
            Text("\(source.retainedBytes) / \(source.originalBytes) B")
                .foregroundStyle(RelayPalette.muted)
            Text(copy.text(status))
                .fontWeight(.bold)
                .foregroundStyle(statusColor)
        }
        .font(.system(size: 7.5, design: .monospaced))
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(statusColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(statusColor.opacity(0.28), lineWidth: 1)
        }
        .accessibilityLabel("\(source.agentName), \(copy.text(status))")
        .accessibilityValue("\(source.retainedBytes) / \(source.originalBytes) B")
    }

    private func arbitrationTargetChip(_ session: RelayTerminalSession) -> some View {
        let selected = selectedTargetID == session.id
        let ready = session.isPromptStagingReady
        return Button {
            selectedTargetID = selected ? nil : session.id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ready ? session.accent : RelayPalette.muted)
                Text(session.agentName)
                    .fontWeight(.bold)
                Text("· \(RelayTerminalContext.projectName(session.cwd))")
                    .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 8.5, design: .monospaced))
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(
                selected ? session.accent.opacity(0.14) : RelayPalette.raised.opacity(0.72)
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        selected ? session.accent.opacity(0.72) : RelayPalette.line,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .opacity(ready ? 1 : 0.46)
        .help(copy.text(
            ready
                ? "Confirm this target is at an input prompt, then select it"
                : "This CLI has not enabled safe paste yet"
        ))
        .accessibilityValue(copy.text(
            !ready ? "SAFE PASTE UNAVAILABLE" : selected ? "SELECTED" : "CONFIRM PROMPT"
        ))
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(RelayPalette.success)
            Text(copy.text(
                isCheckpointReplay
                    ? "Parent checkpoint stays unchanged · no clipboard or disk"
                    : "Captured together only when you clicked · no clipboard or disk"
            ))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            Spacer()
            if let arbitrationReceipt {
                Button(copy.text("CHECK LIVE DRIFT"), action: checkSourceDrift)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                    .help(copy.text(
                        "Compare each frozen source with its live visible screen once"
                    ))
                Text(copy.text("⟨N⟩ SOURCES · ⟨BYTES⟩ B STAGED")
                    .replacingOccurrences(
                        of: "⟨N⟩", with: "\(arbitrationReceipt.plan.sources.count)"
                    )
                    .replacingOccurrences(
                        of: "⟨BYTES⟩", with: "\(arbitrationReceipt.plan.payloadBytes)"
                    ))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayPalette.mix)
                Button(copy.text("BACK TO ARBITER REVIEW"), action: returnToReview)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix, prominent: true))
            } else if arbitrationOpen {
                Button(copy.text("CANCEL"), action: cancelArbitration)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                Button(copy.text("FILL ARBITER · DOES NOT RUN"), action: arbitrate)
                    .buttonStyle(ConsoleButtonStyle(
                        tint: selectedTarget?.accent ?? RelayPalette.mix,
                        prominent: true
                    ))
                    .disabled(!canArbitrate)
            } else {
                if !isCheckpointReplay {
                    Button(copy.text("RECAPTURE"), action: recapture)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                }
                Button(copy.text(
                    isCheckpointReplay ? "REOPEN ARBITRATION" : "ARBITRATE RESULTS"
                ), action: openArbitration)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix, prominent: true))
                    .help(copy.text("Give frozen results to one CLI without running them"))
                Button(copy.text(
                    isCheckpointReplay ? "BACK TO CHECKPOINT" : "BACK TO REVIEW"
                ), action: returnToReview)
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
            }
        }
    }

    private func updateState(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 1.0), changes)
        }
    }

    private func close() {
        if arbitrationReceipt == nil {
            updateState { store.clearResultConfluence() }
        } else {
            returnToReview()
        }
    }

    private func recapture() {
        updateState { _ = store.refreshResultConfluence() }
    }

    private func checkSourceDrift() {
        updateState { sourceDrift = store.resultArbitrationSourceDrift() }
    }

    private func returnToReview() {
        updateState { store.returnFromResultConfluence() }
    }

    private func openArbitration() {
        updateState { arbitrationOpen = true }
        DispatchQueue.main.async { arbitrationFocused = true }
    }

    private func cancelArbitration() {
        updateState {
            arbitrationOpen = false
            arbitrationInstruction = ""
            selectedTargetID = nil
        }
    }

    private func arbitrate() {
        guard let selectedTargetID else { return }
        let completed = store.completeResultArbitration(
            instruction: arbitrationInstruction,
            targetID: selectedTargetID
        )
        if completed {
            arbitrationInstruction = ""
            self.selectedTargetID = nil
        }
    }
}

struct RelayPromptStagingDeck: View {
    @ObservedObject var store: RelayTerminalStore
    @State private var draft = ""
    @State private var selectedIDs = Set<UUID>()
    @FocusState private var editorFocused: Bool
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var reviewPlan: RelayPromptReviewPlan? {
        store.promptReviewPlan
    }

    private var isDecisionBriefReview: Bool {
        reviewPlan != nil && store.decisionBriefCheckpoint != nil
    }

    private var isActionRecoveryReview: Bool {
        reviewPlan != nil && store.decisionActionRecoveryReceipt != nil
    }

    private var isRecoveryHandoffReview: Bool {
        reviewPlan != nil && store.decisionRecoveryHandoffObservation != nil
    }

    private var arbitrationSourcesTitle: String? {
        guard let receipt = store.resultArbitrationReceipt else { return nil }
        return copy.text("VIEW ⟨N⟩ FROZEN SOURCES · ⟨BYTES⟩ B")
            .replacingOccurrences(of: "⟨N⟩", with: "\(receipt.plan.sources.count)")
            .replacingOccurrences(of: "⟨BYTES⟩", with: "\(receipt.plan.payloadBytes)")
    }

    private var runningSessions: [RelayTerminalSession] {
        store.sessions.filter { !$0.exited }
    }

    private var availableIDs: Set<UUID> {
        Set(runningSessions.map(\.id))
    }

    private var currentReviewSession: RelayTerminalSession? {
        guard let id = reviewPlan?.currentID else { return nil }
        return store.session(id)
    }

    private var returnDetectedCount: Int {
        guard let reviewPlan else { return 0 }
        return reviewPlan.targets.count { targetSignal($0) == .returnDetected }
    }

    private var editedCount: Int {
        guard let reviewPlan else { return 0 }
        return reviewPlan.targets.count { targetWasEdited($0) }
    }

    private var disruptedCount: Int {
        guard let reviewPlan else { return 0 }
        return reviewPlan.targets.count {
            let signal = targetSignal($0)
            return signal == .closed || signal == .restarted
        }
    }

    private var deckTint: SwiftUI.Color {
        if let plan = reviewPlan, plan.isFinished(availableIDs: availableIDs) {
            return plan.isComplete() && disruptedCount == 0
                ? RelayPalette.success : RelayPalette.warning
        }
        return currentReviewSession?.accent ?? RelayPalette.mix
    }

    private var headerBadgeText: String {
        guard let reviewPlan else { return copy.text("FILL ONLY · DOES NOT RUN") }
        return returnDetectedCount == 0
            ? copy.text("RETURN NOT DETECTED")
            : copy.text("RETURN ⏎ ⟨COUNT⟩ / ⟨TOTAL⟩")
                .replacingOccurrences(of: "⟨COUNT⟩", with: "\(returnDetectedCount)")
                .replacingOccurrences(of: "⟨TOTAL⟩", with: "\(reviewPlan.targets.count)")
    }

    private var headerBadgeTint: SwiftUI.Color {
        returnDetectedCount == 0 ? RelayPalette.success : RelayPalette.signal
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                header
                targetRail
                content
                footer
            }
            .padding(14)
        }
        .background {
            ZStack {
                RelayMaterial(material: .hudWindow)
                RelayPalette.raised.opacity(0.74)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(deckTint.opacity(0.42), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.42), radius: 22, y: 10)
        .onAppear {
            DispatchQueue.main.async {
                if reviewPlan == nil {
                    editorFocused = true
                } else {
                    reconcileReview(availableIDs: availableIDs)
                    if let id = reviewPlan?.currentID {
                        store.session(id)?.focus()
                    }
                }
            }
        }
        .onChange(of: runningSessions.map(\.id)) { _, ids in
            reconcileReview(availableIDs: Set(ids))
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(deckTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.text(
                    reviewPlan == nil
                        ? "PROMPT STAGE"
                        : isDecisionBriefReview
                            ? "DECISION BRIEF REVIEW"
                            : isActionRecoveryReview
                                ? "ACTION RECOVERY REVIEW"
                                : isRecoveryHandoffReview
                                    ? "RECOVERY CHANGE HANDOFF REVIEW"
                                    : "PROMPT REVIEW"
                ))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                Text(copy.text(
                    reviewPlan == nil
                        ? "Prepare once, fill several native CLIs"
                        : isDecisionBriefReview
                            ? "Check the filled CLI before you run it"
                            : isActionRecoveryReview
                                ? "Check the recovered CLI before you run it"
                                : isRecoveryHandoffReview
                                    ? "Check the relayed recovery change before you run it"
                                    : "Check each native CLI in order"
                ))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
            Spacer()
            Text(headerBadgeText)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(headerBadgeTint)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(headerBadgeTint.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text(
                reviewPlan == nil
                    ? "Close prompt stage"
                    : "Hide review; progress and filled text stay in place"
            ))
        }
    }

    @ViewBuilder
    private var targetRail: some View {
        if let reviewPlan {
            reviewTargetRail(reviewPlan)
        } else {
            selectionTargetRail
        }
    }

    private var selectionTargetRail: some View {
        HStack(spacing: 8) {
            Text("→")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(RelayPalette.mix)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(runningSessions) { session in
                        targetChip(session)
                    }
                }
            }
        }
        .frame(height: 28)
    }

    private func reviewTargetRail(_ plan: RelayPromptReviewPlan) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(plan.targets.enumerated()), id: \.element.id) { index, target in
                    if index > 0 {
                        Text("→")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(RelayPalette.muted.opacity(0.52))
                    }
                    reviewTargetChip(target, index: index, plan: plan)
                }
            }
        }
        .frame(height: 30)
    }

    private func targetSignal(_ target: RelayPromptReviewTarget) -> RelayPromptTargetSignal {
        guard let session = store.session(target.id), !session.exited else {
            return .closed
        }
        return RelayPromptTargetSignal.resolve(
            baseline: target.inputBaseline,
            current: session.inputSnapshot
        )
    }

    private func targetWasEdited(_ target: RelayPromptReviewTarget) -> Bool {
        guard let session = store.session(target.id), !session.exited else {
            return false
        }
        let current = session.inputSnapshot
        return current.generation == target.inputBaseline.generation
            && current.editRevision > target.inputBaseline.editRevision
    }

    private func signalTint(_ signal: RelayPromptTargetSignal) -> SwiftUI.Color {
        switch signal {
        case .none:
            RelayPalette.muted
        case .edited:
            RelayPalette.warning
        case .returnDetected:
            RelayPalette.signal
        case .restarted:
            RelayPalette.danger
        case .closed:
            RelayPalette.muted
        }
    }

    private func signalIcon(_ signal: RelayPromptTargetSignal) -> String? {
        switch signal {
        case .none, .closed:
            nil
        case .edited:
            "pencil"
        case .returnDetected:
            "arrow.turn.down.left"
        case .restarted:
            "arrow.clockwise"
        }
    }

    private func signalDescriptionKey(_ signal: RelayPromptTargetSignal) -> String {
        switch signal {
        case .none:
            "No edit key or Return detected"
        case .edited:
            "Edit input detected; Return not detected"
        case .returnDetected:
            "Return detected; Relay did not send it"
        case .restarted:
            "Terminal restarted after the prompt was filled"
        case .closed:
            "Terminal closed after the prompt was filled"
        }
    }

    private func reviewTargetChip(
        _ target: RelayPromptReviewTarget,
        index: Int,
        plan: RelayPromptReviewPlan
    ) -> some View {
        let available = availableIDs.contains(target.id)
        let reviewed = plan.reviewedIDs.contains(target.id)
        let current = plan.currentID == target.id
        let signal = targetSignal(target)
        let accent = store.session(target.id)?.accent ?? RelayPalette.muted
        let tint = !available
            ? RelayPalette.muted
            : reviewed ? RelayPalette.success : current ? accent : RelayPalette.muted
        let reviewStateKey = !available
            ? "CLOSED" : reviewed ? "CHECKED" : current ? "CURRENT" : "PENDING"
        let reviewHelpKey = !available
            ? "This terminal closed before review"
            : reviewed
                ? "Reviewed; select to revisit this terminal"
                : current
                    ? "Currently reviewing this terminal"
                    : "Select this terminal to review it"
        let signalDescription = copy.text(signalDescriptionKey(signal))
        return Button {
            selectReviewTarget(target.id)
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(current && available ? tint.opacity(0.22) : RelayPalette.ink.opacity(0.62))
                    Circle()
                        .stroke(tint.opacity(current || reviewed ? 0.85 : 0.42), lineWidth: 1)
                    if reviewed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 6.5, weight: .black))
                    } else if !available {
                        Image(systemName: "xmark")
                            .font(.system(size: 6.5, weight: .black))
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                    }
                }
                .foregroundStyle(tint)
                .frame(width: 15, height: 15)
                Text(target.agentName)
                    .fontWeight(.bold)
                Text("· \(target.projectName)")
                    .foregroundStyle(RelayPalette.muted)
                if let icon = signalIcon(signal) {
                    Image(systemName: icon)
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(signalTint(signal))
                        .frame(width: 14, height: 14)
                        .background(signalTint(signal).opacity(0.12))
                        .clipShape(Circle())
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(current ? tint.opacity(0.13) : RelayPalette.ink.opacity(0.48))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(current ? tint.opacity(0.68) : RelayPalette.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.48)
        .help("\(copy.text(reviewHelpKey)) · \(signalDescription)")
        .accessibilityLabel("\(index + 1), \(target.agentName), \(target.projectName)")
        .accessibilityValue("\(copy.text(reviewStateKey)), \(signalDescription)")
    }

    private func targetChip(_ session: RelayTerminalSession) -> some View {
        let ready = session.isPromptStagingReady
        let selected = selectedIDs.contains(session.id)
        return Button {
            if selected {
                selectedIDs.remove(session.id)
            } else {
                selectedIDs.insert(session.id)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ready ? session.accent : RelayPalette.muted)
                Text(session.agentName)
                    .fontWeight(.bold)
                Text("· \(RelayTerminalContext.projectName(session.cwd))")
                    .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 9, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(selected ? session.accent.opacity(0.14) : RelayPalette.ink.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        selected ? session.accent.opacity(0.72) : RelayPalette.line,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .opacity(ready ? 1 : 0.48)
        .help(copy.text(
            !ready
                ? "This CLI has not enabled safe paste yet"
                : selected
                    ? "Fill this terminal without running"
                    : "Confirm this CLI is at an input prompt, then select it"
        ))
        .accessibilityLabel("\(session.agentName), \(RelayTerminalContext.projectName(session.cwd))")
        .accessibilityValue(copy.text(
            !ready ? "SAFE PASTE UNAVAILABLE" : selected ? "SELECTED" : "CONFIRM PROMPT"
        ))
    }

    @ViewBuilder
    private var content: some View {
        if let reviewPlan {
            reviewContent(reviewPlan)
        } else {
            draftEditor
        }
    }

    private var draftEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(RelayPalette.text)
                .scrollContentBackground(.hidden)
                .padding(7)
                .focused($editorFocused)
            if draft.isEmpty {
                Text(copy.text("Write once, then fill every selected CLI…"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted.opacity(0.72))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 15)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 72)
        .background(RelayPalette.ink.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
    }

    private func reviewContent(_ plan: RelayPromptReviewPlan) -> some View {
        let finished = plan.isFinished(availableIDs: availableIDs)
        let complete = plan.isComplete() && disruptedCount == 0
        let currentTarget = plan.targets.first { $0.id == plan.currentID }
        let currentIndex = plan.targets.firstIndex { $0.id == plan.currentID }
        let currentSignal = currentTarget.map(targetSignal) ?? .none
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(deckTint.opacity(0.13))
                Image(systemName: finished
                    ? (complete ? "checkmark" : "exclamationmark")
                    : signalIcon(currentSignal) ?? "eye.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(
                        currentSignal == .none ? deckTint : signalTint(currentSignal)
                    )
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                if let brief = store.decisionBriefPlan {
                    HStack(spacing: 5) {
                        Image(systemName: "seal.fill")
                        Text(copy.text("DECISION BRIEF · ⟨BYTES⟩ UTF-8 B · ⟨RESULT⟩")
                            .replacingOccurrences(of: "⟨BYTES⟩", with: "\(brief.payloadBytes)")
                            .replacingOccurrences(
                                of: "⟨RESULT⟩",
                                with: copy.text(
                                    brief.decisionTruncated ? "TAIL KEPT" : "FULL RESULT"
                                )
                            ))
                    }
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        brief.decisionTruncated ? RelayPalette.warning : RelayPalette.success
                    )
                }
                if let recovery = store.decisionActionRecoveryPlan {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(copy.text("ACTION RECOVERY · ⟨BYTES⟩ UTF-8 B · ⟨SCREEN⟩")
                            .replacingOccurrences(
                                of: "⟨BYTES⟩", with: "\(recovery.payloadBytes)"
                            )
                            .replacingOccurrences(
                                of: "⟨SCREEN⟩",
                                with: copy.text(
                                    recovery.visibleScreenTruncated ? "TAIL KEPT" : "FULL"
                                )
                            ))
                    }
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        recovery.visibleScreenTruncated
                            ? RelayPalette.warning : RelayPalette.signal
                    )
                }
                if let handoff = store.decisionRecoveryHandoffPlan {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.left.arrow.right.square.fill")
                        Text(copy.text("RECOVERY HANDOFF · ⟨BYTES⟩ UTF-8 B · ⟨SCREENS⟩")
                            .replacingOccurrences(
                                of: "⟨BYTES⟩", with: "\(handoff.payloadBytes)"
                            )
                            .replacingOccurrences(
                                of: "⟨SCREENS⟩",
                                with: copy.text(
                                    handoff.frozenScreenTruncated
                                        || handoff.recoveryScreenTruncated
                                        ? "SCREEN TAIL KEPT" : "BOTH SCREENS FULL"
                                )
                            ))
                    }
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        handoff.frozenScreenTruncated || handoff.recoveryScreenTruncated
                            ? RelayPalette.warning : RelayPalette.signal
                    )
                }
                if finished {
                    Text(copy.text(complete ? "ALL TARGETS CHECKED" : "REVIEW ENDED"))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                    Text(finishedSummary(plan))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                } else if let currentTarget, let currentIndex {
                    Text(copy.text("REVIEWING ⟨CURRENT⟩ OF ⟨TOTAL⟩")
                        .replacingOccurrences(of: "⟨CURRENT⟩", with: "\(currentIndex + 1)")
                        .replacingOccurrences(of: "⟨TOTAL⟩", with: "\(plan.targets.count)"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(deckTint)
                    Text("\(currentTarget.agentName) · \(currentTarget.projectName)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text(copy.text(signalDescriptionKey(currentSignal)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(
                            currentSignal == .none ? RelayPalette.muted : signalTint(currentSignal)
                        )
                }
            }
            Spacer()
            Text("\(plan.reviewedCount()) / \(plan.targets.count)")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(deckTint)
                .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .frame(height: 62)
        .background(RelayPalette.ink.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(deckTint.opacity(0.22), lineWidth: 1)
        }
    }

    private func finishedSummary(_ plan: RelayPromptReviewPlan) -> String {
        if disruptedCount > 0 {
            return copy.text("⟨COUNT⟩ targets closed or restarted after filling · ⏎ ⟨RETURN⟩")
                .replacingOccurrences(of: "⟨COUNT⟩", with: "\(disruptedCount)")
                .replacingOccurrences(of: "⟨RETURN⟩", with: "\(returnDetectedCount)")
        }
        if returnDetectedCount > 0 {
            return copy.text("Return detected in ⟨COUNT⟩ of ⟨TOTAL⟩ terminals. Relay did not send it.")
                .replacingOccurrences(of: "⟨COUNT⟩", with: "\(returnDetectedCount)")
                .replacingOccurrences(of: "⟨TOTAL⟩", with: "\(plan.targets.count)")
        }
        return copy.text("No Return detected. Run each CLI when you decide.")
    }

    @ViewBuilder
    private var footer: some View {
        if let reviewPlan {
            reviewFooter(reviewPlan)
        } else {
            HStack(spacing: 8) {
                Text("\(draft.utf8.count) / \(RelayPromptStaging.maxBytes) B")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(
                        draft.utf8.count > RelayPromptStaging.maxBytes
                            ? RelayPalette.danger : RelayPalette.muted
                    )
                Text(copy.text("Confirm each CLI is at an input prompt before selecting it."))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Button("\(copy.text("FILL")) \(selectedReadyCount)", action: stage)
                    .buttonStyle(ConsoleButtonStyle(
                        tint: RelayPalette.mix, prominent: true
                    ))
                    .disabled(!canStage)
            }
        }
    }

    @ViewBuilder
    private func reviewFooter(_ plan: RelayPromptReviewPlan) -> some View {
        if plan.isFinished(availableIDs: availableIDs) {
            HStack(spacing: 8) {
                Image(systemName: disruptedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(disruptedCount == 0 ? RelayPalette.success : RelayPalette.warning)
                Text(copy.text("⟨CHECKED⟩ checked · ⏎ ⟨RETURN⟩ · ⟨ISSUES⟩ interrupted")
                    .replacingOccurrences(of: "⟨CHECKED⟩", with: "\(plan.reviewedCount())")
                    .replacingOccurrences(of: "⟨RETURN⟩", with: "\(returnDetectedCount)")
                    .replacingOccurrences(of: "⟨ISSUES⟩", with: "\(disruptedCount)"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(disruptedCount == 0 ? RelayPalette.success : RelayPalette.warning)
                Spacer()
                if plan.targets.count >= 2 {
                    Button(copy.text("CAPTURE CURRENT SCREENS")) {
                        captureResults(plan)
                    }
                    .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix, prominent: true))
                    .disabled(collectableTargetCount(plan) < 2)
                        .help(copy.text("Freeze reviewed CLI screens together for local comparison"))
                }
                if let arbitrationSourcesTitle {
                    Button(arbitrationSourcesTitle, action: showArbitrationSources)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                        .help(copy.text(
                            "View the exact frozen screens staged for this arbitration"
                        ))
                }
                if store.resultArbitrationReceipt != nil {
                    if store.resultArbitrationDecision != nil {
                        Button(copy.text("VIEW SEALED RESULT"), action: showArbitrationDecision)
                            .buttonStyle(ConsoleButtonStyle(
                                tint: RelayPalette.success,
                                prominent: true
                            ))
                            .help(copy.text("Open the frozen arbiter result"))
                    } else {
                        Button(copy.text("SEAL RESULT"), action: sealArbitrationDecision)
                            .buttonStyle(ConsoleButtonStyle(
                                tint: RelayPalette.success,
                                prominent: true
                            ))
                            .disabled(!plan.isComplete() || disruptedCount > 0)
                            .help(copy.text(
                                "Freeze the arbiter's current visible screen into this decision chain"
                            ))
                    }
                }
                if isDecisionBriefReview {
                    decisionActionReceiptButton
                }
                if store.decisionBriefCheckpoint != nil {
                    Button(copy.text("BACK TO DECISION"), action: returnToDecision)
                        .buttonStyle(ConsoleButtonStyle(
                            tint: RelayPalette.success,
                            prominent: returnDetectedCount == 0
                                && store.decisionActionReceiptDraft == nil
                        ))
                        .help(copy.text("Return to the checkpoint; filled text stays in the CLI"))
                }
                if isActionRecoveryReview {
                    decisionRecoveryObservationButton
                    Button(copy.text("BACK TO ACTION RECEIPT"), action: returnToActionReceipt)
                        .buttonStyle(ConsoleButtonStyle(
                            tint: RelayPalette.signal,
                            prominent: returnDetectedCount == 0
                        ))
                        .help(copy.text("Return to the frozen receipt; filled text stays in the CLI"))
                }
                if isRecoveryHandoffReview {
                    decisionRecoveryWitnessButton
                    if store.decisionRecoveryWitnessDraft == nil {
                        Button(copy.text("BACK TO RECOVERY CHANGE"), action: returnToRecoveryChange)
                            .buttonStyle(ConsoleButtonStyle(
                                tint: RelayPalette.signal,
                                prominent: returnDetectedCount == 0
                            ))
                            .help(copy.text(
                                "Return to the saved recovery change; filled text stays in the CLI"
                            ))
                    }
                }
                if store.decisionRecoveryWitnessDraft == nil {
                    Button(copy.text("NEW PROMPT"), action: reset)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                }
                Button(copy.text("CLOSE"), action: close)
                    .buttonStyle(ConsoleButtonStyle(
                        tint: deckTint,
                        prominent: store.decisionBriefCheckpoint == nil
                            && !isActionRecoveryReview
                            && !isRecoveryHandoffReview
                    ))
            }
        } else {
            HStack(spacing: 8) {
                Text(copy.text("Prompt text cleared · Return remains yours"))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Text("✎ \(editedCount) · ⏎ \(returnDetectedCount)")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(returnDetectedCount > 0 ? RelayPalette.signal : RelayPalette.muted)
                Text(copy.text("⟨N⟩ left")
                    .replacingOccurrences(
                        of: "⟨N⟩",
                        with: "\(plan.pendingCount(availableIDs: availableIDs))"
                    ))
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(deckTint)
                Spacer()
                if let arbitrationSourcesTitle {
                    Button(arbitrationSourcesTitle, action: showArbitrationSources)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.mix))
                        .help(copy.text(
                            "View the exact frozen screens staged for this arbitration"
                        ))
                }
                if isDecisionBriefReview {
                    decisionActionReceiptButton
                }
                if store.decisionBriefCheckpoint != nil {
                    Button(copy.text("BACK TO DECISION"), action: returnToDecision)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.success))
                        .help(copy.text("Return to the checkpoint; filled text stays in the CLI"))
                }
                if isActionRecoveryReview {
                    decisionRecoveryObservationButton
                    Button(copy.text("BACK TO ACTION RECEIPT"), action: returnToActionReceipt)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                        .help(copy.text("Return to the frozen receipt; filled text stays in the CLI"))
                }
                if isRecoveryHandoffReview {
                    decisionRecoveryWitnessButton
                    if store.decisionRecoveryWitnessDraft == nil {
                        Button(copy.text("BACK TO RECOVERY CHANGE"), action: returnToRecoveryChange)
                            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
                            .help(copy.text(
                                "Return to the saved recovery change; filled text stays in the CLI"
                            ))
                    }
                }
                if store.decisionRecoveryWitnessDraft == nil {
                    Button(copy.text("END REVIEW"), action: discardReview)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                        .help(copy.text("End review; filled text stays in the terminals"))
                }
                Button(
                    copy.text(
                        plan.pendingCount(availableIDs: availableIDs) == 1
                            ? "CHECKED"
                            : "CHECKED · NEXT"
                    ),
                    action: confirmAndAdvance
                )
                .buttonStyle(ConsoleButtonStyle(tint: deckTint, prominent: true))
                .disabled(plan.currentID.map { !availableIDs.contains($0) } ?? true)
            }
        }
    }

    @ViewBuilder
    private var decisionActionReceiptButton: some View {
        if store.decisionActionReceiptDraft != nil {
            Button(copy.text("VIEW ACTION RECEIPT")) {
                updateState { store.showDecisionActionReceiptDraft() }
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            .help(copy.text("Open the unsaved in-memory action receipt"))
        } else if returnDetectedCount > 0 {
            Button(copy.text("CAPTURE ACTION RECEIPT")) {
                updateState { _ = store.captureDecisionActionReceipt() }
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            .disabled(!store.canCaptureDecisionActionReceipt())
            .help(copy.text(
                "Freeze the exact filled brief and current visible screen; this does not claim success"
            ))
        }
    }

    @ViewBuilder
    private var decisionRecoveryObservationButton: some View {
        if store.decisionRecoveryObservationDraft != nil {
            Button(copy.text("VIEW RECOVERY CHANGE")) {
                updateState { store.showDecisionRecoveryObservationDraft() }
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            .help(copy.text("Open the unsaved in-memory recovery screen comparison"))
        } else if returnDetectedCount > 0 {
            Button(copy.text("CAPTURE RECOVERY CHANGE")) {
                updateState { _ = store.captureDecisionRecoveryObservation() }
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            .disabled(!store.canCaptureDecisionRecoveryObservation())
            .help(copy.text(
                "Compare the current visible screen with the frozen receipt; this does not claim success"
            ))
        }
    }

    @ViewBuilder
    private var decisionRecoveryWitnessButton: some View {
        if store.decisionRecoveryWitnessDraft != nil {
            Button(copy.text("VIEW RECOVERY WITNESS")) {
                updateState { store.showDecisionRecoveryWitnessDraft() }
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            .help(copy.text("Open the unsaved in-memory recovery witness"))
        } else if returnDetectedCount > 0 {
            Button(copy.text("CAPTURE RECOVERY WITNESS")) {
                updateState { _ = store.captureDecisionRecoveryWitness() }
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal, prominent: true))
            .disabled(!store.canCaptureDecisionRecoveryWitness())
            .help(copy.text(
                "Freeze the exact handoff and current witness screen; Relay does not judge it"
            ))
        }
    }

    private var selectedReadyCount: Int {
        runningSessions.count {
            selectedIDs.contains($0.id) && $0.isPromptStagingReady
        }
    }

    private func collectableTargetCount(_ plan: RelayPromptReviewPlan) -> Int {
        plan.targets.count { target in
            plan.reviewedIDs.contains(target.id)
                && store.session(target.id)?.exited == false
        }
    }

    private var canStage: Bool {
        selectedReadyCount > 0 && RelayPromptStaging.payload(draft) != nil
    }

    private func stage() {
        let ids = store.stagePrompt(draft, to: selectedIDs)
        let targets = ids.compactMap { id -> RelayPromptReviewTarget? in
            guard let session = store.session(id) else { return nil }
            return RelayPromptReviewTarget(
                id: id,
                agentName: session.agentName,
                projectName: RelayTerminalContext.projectName(session.cwd),
                inputBaseline: session.inputSnapshot
            )
        }
        guard !targets.isEmpty else { return }
        let plan = RelayPromptReviewPlan(targets: targets)
        updateState {
            draft = ""
            selectedIDs.removeAll()
            store.beginPromptReview(plan)
        }
        if let id = plan.currentID {
            store.session(id)?.focus()
        }
    }

    private func selectReviewTarget(_ id: UUID) {
        guard var plan = reviewPlan else { return }
        let selected = plan.select(id, availableIDs: availableIDs)
        updateState { store.updatePromptReview(plan) }
        if let selected {
            store.session(selected)?.focus()
        }
    }

    private func confirmAndAdvance() {
        guard var plan = reviewPlan else { return }
        let next = plan.confirmCurrent(availableIDs: availableIDs)
        updateState { store.updatePromptReview(plan) }
        if let next {
            store.session(next)?.focus()
        }
    }

    private func captureResults(_ plan: RelayPromptReviewPlan) {
        updateState { _ = store.captureResultConfluence(from: plan) }
    }

    private func showArbitrationSources() {
        updateState { _ = store.showResultArbitrationSources() }
    }

    private func sealArbitrationDecision() {
        updateState { _ = store.captureResultArbitrationDecision() }
    }

    private func showArbitrationDecision() {
        updateState { _ = store.showResultArbitrationDecision() }
    }

    private func reconcileReview(availableIDs: Set<UUID>) {
        guard var plan = reviewPlan else { return }
        let previous = plan.currentID
        let next = plan.reconcile(availableIDs: availableIDs)
        guard plan != reviewPlan else { return }
        updateState { store.updatePromptReview(plan) }
        if next != previous, let next {
            store.session(next)?.focus()
        }
    }

    private func reset() {
        updateState {
            store.clearPromptReview()
            draft = ""
            selectedIDs.removeAll()
        }
        DispatchQueue.main.async { editorFocused = true }
    }

    private func discardReview() {
        reset()
    }

    private func returnToDecision() {
        updateState { _ = store.returnFromDecisionBriefReview() }
    }

    private func returnToActionReceipt() {
        updateState { _ = store.returnFromDecisionActionRecoveryReview() }
    }

    private func returnToRecoveryChange() {
        updateState { _ = store.returnFromDecisionRecoveryHandoffReview() }
    }

    private func updateState(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                changes()
            }
        }
    }

    private func close() {
        if reduceMotion {
            store.closePromptStaging()
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 1)) {
                store.closePromptStaging()
            }
        }
    }
}
