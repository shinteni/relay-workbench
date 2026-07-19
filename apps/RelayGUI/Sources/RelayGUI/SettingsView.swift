import AppKit
import SwiftUI

private enum RelaySettingsSection: CaseIterable {
    case general
    case agents

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .agents: "terminal"
        }
    }

    func title(_ copy: RelayCopy) -> String {
        copy.text(self == .general ? "General" : "Agents")
    }
}

struct RelaySettingsRoot: View {
    @ObservedObject var relay: RelayService

    var body: some View {
        SettingsView()
            .environmentObject(relay)
            .environment(\.relayLanguage, relay.language)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var relay: RelayService
    @State private var selection = RelaySettingsSection.general
    @State private var personaDraft: RelayPersona?
    @State private var personaError: String?
    @State private var hookDraft: RelayTaskHook?
    @State private var hookError: String?

    private var copy: RelayCopy { RelayCopy(language: relay.language) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(width: 1)

            detail
        }
        .background(RelayPalette.ink)
        .foregroundStyle(RelayPalette.text)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(">")
                    .foregroundStyle(RelayPalette.signal)
                Text("CONFIG_")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .tracking(0.8)
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 25)

            ForEach(RelaySettingsSection.allCases, id: \.self) { section in
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .frame(width: 16)
                        Text(section.title(copy))
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selection == section ? RelayPalette.text : RelayPalette.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(selection == section ? RelayPalette.signal.opacity(0.12) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(alignment: .leading) {
                        if selection == section {
                            Rectangle()
                                .fill(RelayPalette.signal)
                                .frame(width: 2)
                                .padding(.vertical, 7)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(RelayPalette.success)
                    .frame(width: 6, height: 6)
                    .shadow(color: RelayPalette.success.opacity(0.5), radius: 4)
                Text(copy.text("Settings are saved automatically"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
            }
            .padding(18)
        }
        .background(RelayPalette.panel)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.text("Settings").uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.3)
                    .foregroundStyle(RelayPalette.signal)
                Text(selection.title(copy))
                    .font(.system(size: 24, weight: .semibold))
            }
            .padding(.horizontal, 34)
            .padding(.top, 32)
            .padding(.bottom, 22)

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if selection == .general {
                        generalSettings
                    } else {
                        agentSettings
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var generalSettings: some View {
        VStack(spacing: 0) {
            settingsRow(
                title: copy.text("Interface language"),
                description: copy.text("Changes the language used by Relay. CLI output and agent replies stay unchanged.")
            ) {
                HStack(spacing: 6) {
                    languageButton(.chinese, key: "Chinese")
                    languageButton(.japanese, key: "Japanese")
                }
            }

            settingsRow(
                title: copy.text("Quick input bar"),
                description: copy.text("Press Option-Space anywhere to send a task to the background daemon.")
            ) {
                HStack(spacing: 6) {
                    Button(copy.text("On")) { relay.setQuickBarEnabled(true) }
                        .buttonStyle(SettingsChoiceButtonStyle(selected: relay.quickBarEnabled))
                    Button(copy.text("Off")) { relay.setQuickBarEnabled(false) }
                        .buttonStyle(SettingsChoiceButtonStyle(selected: !relay.quickBarEnabled))
                }
            }

            settingsRow(
                title: copy.text("System notifications"),
                description: copy.text("Notify when a background task finishes, fails, or waits for your response.")
            ) {
                HStack(spacing: 6) {
                    Button(copy.text("On")) { relay.setNotificationsEnabled(true) }
                        .buttonStyle(SettingsChoiceButtonStyle(selected: relay.notificationsEnabled))
                    Button(copy.text("Off")) { relay.setNotificationsEnabled(false) }
                        .buttonStyle(SettingsChoiceButtonStyle(selected: !relay.notificationsEnabled))
                }
            }

            settingsRow(
                title: copy.text("Daemon log"),
                description: copy.text("relayd writes diagnostics to a local log file inside Application Support.")
            ) {
                Button(copy.text("Open log")) { relay.openDaemonLog() }
                    .buttonStyle(SettingsActionButtonStyle())
            }

            hookSettings

            settingsRow(
                title: copy.text("Default working directory"),
                description: copy.text("Used when creating a new thread. Existing threads keep their own working directory.")
            ) {
                HStack(spacing: 8) {
                    TextField(copy.text("Working directory"), text: Binding(
                        get: { relay.defaultWorkingDirectory },
                        set: { relay.setDefaultWorkingDirectory($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RelayPalette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Button(copy.text("Choose…")) { chooseDirectory() }
                        .buttonStyle(SettingsActionButtonStyle())
                }
            }
        }
    }

    private var agentSettings: some View {
        VStack(spacing: 0) {
            settingsRow(
                title: copy.text("Codex default mode"),
                description: copy.text("Default runs directly. Plan allows Codex to ask questions before execution.")
            ) {
                HStack(spacing: 6) {
                    ForEach(RelayCodexMode.allCases, id: \.rawValue) { mode in
                        Button(copy.codexMode(mode)) { relay.setCodexMode(mode) }
                            .buttonStyle(SettingsChoiceButtonStyle(selected: relay.codexMode == mode))
                    }
                }
            }

            settingsRow(
                title: copy.text("MIX default model"),
                description: copy.text("The Codex model used when MIX combines Claude and Codex.")
            ) {
                settingsMenu(relay.mixModel, width: 210) {
                    ForEach(relay.mixModels, id: \.self) { model in
                        Button(model) { relay.setMixModel(model) }
                    }
                }
            }

            settingsRow(
                title: copy.text("Reasoning effort"),
                description: copy.text("Used by the selected Codex model inside MIX.")
            ) {
                settingsMenu(relay.mixEffort.uppercased(), width: 130) {
                    ForEach(relay.mixEfforts, id: \.self) { effort in
                        Button(effort.uppercased()) { relay.setMixEffort(effort) }
                    }
                }
            }

            personaSettings
        }
    }

    private var hookSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(copy.text("Task lifecycle hooks"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(copy.text("Run a local command when a background task completes, fails, or waits for you. Task facts arrive as RELAY_TASK_* environment variables; hooks fire while the GUI is running."))
                        .font(.system(size: 11))
                        .foregroundStyle(RelayPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(copy.text("ADD HOOK")) {
                    hookDraft = RelayTaskHook(event: .completed, command: "")
                    hookError = nil
                }
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(relay.taskHooks.count >= RelayTaskHookStore.maxCount)
            }

            ForEach(relay.taskHooks) { hook in
                HStack(spacing: 10) {
                    Text(copy.text(hookEventKey(hook.event)))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(hookEventTint(hook.event))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(hookEventTint(hook.event).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(hook.agentID.flatMap { id in
                        relay.agents.first { $0.id == id }?.name
                    } ?? copy.text("Any agent"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                    Text(hook.command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(RelayPalette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(copy.text("EDIT")) {
                        hookDraft = hook
                        hookError = nil
                    }
                    .buttonStyle(SettingsActionButtonStyle())
                    Button(copy.text("DELETE")) {
                        relay.deleteTaskHook(id: hook.id)
                    }
                    .buttonStyle(SettingsActionButtonStyle())
                }
                .padding(.vertical, 4)
            }

            if hookDraft != nil {
                hookEditor
            }

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)
        }
        .padding(.vertical, 22)
    }

    private var hookEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                settingsMenu(
                    copy.text(hookEventKey(hookDraft?.event ?? .completed)),
                    width: 140
                ) {
                    ForEach(RelayTaskHook.Event.allCases, id: \.rawValue) { event in
                        Button(copy.text(hookEventKey(event))) {
                            hookDraft?.event = event
                        }
                    }
                }
                settingsMenu(
                    hookDraft?.agentID.flatMap { id in
                        relay.agents.first { $0.id == id }?.name
                    } ?? copy.text("Any agent"),
                    width: 160
                ) {
                    Button(copy.text("Any agent")) { hookDraft?.agentID = nil }
                    ForEach(relay.agents) { agent in
                        Button(agent.name) { hookDraft?.agentID = agent.id }
                    }
                }
                Spacer()
            }

            TextField(
                copy.text("Command run with /bin/zsh -c (task facts come via RELAY_TASK_* env)"),
                text: Binding(
                    get: { hookDraft?.command ?? "" },
                    set: { hookDraft?.command = $0 }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1...4)
            .padding(9)
            .background(RelayPalette.raised)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let hookError {
                Text(copy.text(hookError))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RelayPalette.danger)
            }

            HStack(spacing: 8) {
                Button(copy.text("SAVE HOOK")) {
                    guard var draft = hookDraft else { return }
                    draft.command = draft.command
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let reason = RelayTaskHookStore.validationError(
                        command: draft.command
                    ) {
                        hookError = reason
                        return
                    }
                    relay.saveTaskHook(draft)
                    hookDraft = nil
                    hookError = nil
                }
                .buttonStyle(SettingsActionButtonStyle())
                Button(copy.text("CANCEL")) {
                    hookDraft = nil
                    hookError = nil
                }
                .buttonStyle(SettingsActionButtonStyle())
                Spacer()
            }
        }
        .padding(12)
        .background(RelayPalette.panel.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
    }

    private func hookEventKey(_ event: RelayTaskHook.Event) -> String {
        switch event {
        case .completed: "hook · completed"
        case .failed: "hook · failed"
        case .waiting: "hook · waiting"
        }
    }

    private func hookEventTint(_ event: RelayTaskHook.Event) -> SwiftUI.Color {
        switch event {
        case .completed: RelayPalette.success
        case .failed: RelayPalette.danger
        case .waiting: RelayPalette.warning
        }
    }

    private var personaSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(copy.text("Seat presets"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(copy.text("Named personas — an agent plus option overrides and extra rules. Pick them as members in dialogues and comparisons."))
                        .font(.system(size: 11))
                        .foregroundStyle(RelayPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(copy.text("ADD PRESET")) {
                    personaDraft = RelayPersona(
                        name: "",
                        agentID: relay.agents.first(where: \.isAvailable)?.id ?? ""
                    )
                    personaError = nil
                }
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(relay.personas.count >= RelayPersonaStore.maxCount)
            }

            ForEach(relay.personas) { persona in
                HStack(spacing: 10) {
                    Text("☰ \(persona.name)")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RelayPalette.text)
                    Text(relay.agents.first { $0.id == persona.agentID }?.name
                        ?? persona.agentID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(RelayPalette.muted)
                    if !persona.options.isEmpty {
                        Text(persona.options
                            .sorted { $0.key < $1.key }
                            .map { "\($0.key)=\($0.value)" }
                            .joined(separator: " "))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(RelayPalette.signal)
                            .lineLimit(1)
                    }
                    if !persona.rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(copy.text("rules"))
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(RelayPalette.warning)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RelayPalette.warning.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    Button(copy.text("EDIT")) {
                        personaDraft = persona
                        personaError = nil
                    }
                    .buttonStyle(SettingsActionButtonStyle())
                    Button(copy.text("DELETE")) {
                        relay.deletePersona(id: persona.id)
                    }
                    .buttonStyle(SettingsActionButtonStyle())
                }
                .padding(.vertical, 4)
            }

            if let draft = personaDraft {
                personaEditor(draft)
            }

            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)
        }
        .padding(.vertical, 22)
    }

    private func personaEditor(_ draft: RelayPersona) -> some View {
        let agent = relay.agents.first { $0.id == draft.agentID }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(copy.text("Preset name"), text: Binding(
                    get: { personaDraft?.name ?? "" },
                    set: { personaDraft?.name = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(width: 200)
                .background(RelayPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                settingsMenu(
                    agent?.name ?? copy.text("Agent"), width: 160
                ) {
                    ForEach(relay.agents.filter(\.isAvailable)) { candidate in
                        Button(candidate.name) {
                            personaDraft?.agentID = candidate.id
                            personaDraft?.options = [:]
                        }
                    }
                }
                Spacer()
            }

            if let agent, !agent.options.isEmpty {
                HStack(spacing: 8) {
                    ForEach(agent.options, id: \.key) { option in
                        settingsMenu(
                            "\(option.label): \(personaDraft?.options[option.key] ?? copy.text("(default)"))",
                            width: 190
                        ) {
                            Button(copy.text("(default)")) {
                                personaDraft?.options[option.key] = nil
                            }
                            ForEach(option.values, id: \.self) { value in
                                Button(value) {
                                    personaDraft?.options[option.key] = value
                                }
                            }
                        }
                    }
                    Spacer()
                }
            }

            TextField(
                copy.text("Extra rules prepended to this seat's prompts (optional)"),
                text: Binding(
                    get: { personaDraft?.rules ?? "" },
                    set: { personaDraft?.rules = $0 }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(2...6)
            .padding(9)
            .background(RelayPalette.raised)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let personaError {
                Text(copy.text(personaError))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RelayPalette.danger)
            }

            HStack(spacing: 8) {
                Button(copy.text("SAVE PRESET")) {
                    guard var draft = personaDraft else { return }
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let reason = RelayPersonaStore.validationError(
                        name: draft.name, rules: draft.rules
                    ) {
                        personaError = reason
                        return
                    }
                    guard relay.agents.contains(where: { $0.id == draft.agentID }) else {
                        personaError = "Pick an agent for this preset"
                        return
                    }
                    relay.savePersona(draft)
                    personaDraft = nil
                    personaError = nil
                }
                .buttonStyle(SettingsActionButtonStyle())
                Button(copy.text("CANCEL")) {
                    personaDraft = nil
                    personaError = nil
                }
                .buttonStyle(SettingsActionButtonStyle())
                Spacer()
            }
        }
        .padding(12)
        .background(RelayPalette.panel.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(RelayPalette.line, lineWidth: 1)
        }
    }

    private func settingsRow<Control: View>(
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(RelayPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                control()
            }
            Rectangle()
                .fill(RelayPalette.line)
                .frame(height: 1)
        }
        .padding(.vertical, 22)
    }

    private func languageButton(_ language: RelayLanguage, key: String) -> some View {
        Button(copy.text(key)) { relay.setLanguage(language) }
            .buttonStyle(SettingsChoiceButtonStyle(selected: relay.language == language))
    }

    private func settingsMenu<Content: View>(
        _ title: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: 10) {
                Text(title)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(RelayPalette.muted)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: width)
            .background(RelayPalette.raised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(RelayPalette.line, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: relay.defaultWorkingDirectory)
        panel.prompt = copy.text("Choose…")
        if panel.runModal() == .OK, let url = panel.url {
            relay.activateProjectDirectory(url.path)
        }
    }
}

private struct SettingsChoiceButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? RelayPalette.ink : RelayPalette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? RelayPalette.signal : RelayPalette.raised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? .clear : RelayPalette.line, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct SettingsActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(RelayPalette.signal)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RelayPalette.signal.opacity(configuration.isPressed ? 0.16 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(RelayPalette.signal.opacity(0.35), lineWidth: 1)
            }
    }
}
