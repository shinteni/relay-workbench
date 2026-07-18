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
            relay.setDefaultWorkingDirectory(url.path)
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
