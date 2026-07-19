import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class RelayHotkey {
    static let quickBarID: UInt32 = 0x514B4252
    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onPress: (() -> Void)?

    func register(onPress: @escaping () -> Void) {
        guard hotkeyRef == nil else {
            self.onPress = onPress
            return
        }
        self.onPress = onPress
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, context in
                guard let event, let context else { return noErr }
                var hotkeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                if hotkeyID.id == RelayHotkey.quickBarID {
                    let hotkey = Unmanaged<RelayHotkey>
                        .fromOpaque(context)
                        .takeUnretainedValue()
                    Task { @MainActor in
                        hotkey.onPress?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        let hotkeyID = EventHotKeyID(signature: Self.quickBarID, id: Self.quickBarID)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotkeyID,
            GetEventDispatcherTarget(),
            0,
            &hotkeyRef
        )
    }

    func unregister() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
            self.hotkeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        onPress = nil
    }
}

@MainActor
final class RelayQuickBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
final class RelayQuickBarController {
    private var panel: NSPanel?
    private weak var relay: RelayService?
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    func toggle(relay: RelayService) {
        if let panel, panel.isVisible {
            close()
        } else {
            show(relay: relay)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func show(relay: RelayService) {
        self.relay = relay
        if panel == nil {
            let content = QuickBarView(relay: relay, dismiss: { [weak self] in
                self?.close()
            })
            let hosting = NSHostingController(rootView: content)
            let panel = RelayQuickBarPanel(contentViewController: hosting)
            panel.styleMask = [.nonactivatingPanel, .fullSizeContentView, .titled]
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.setContentSize(NSSize(width: 620, height: 118))
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.close()
                }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let panel = self.panel,
                      panel.isVisible, event.keyCode == 53 else {
                    return event
                }
                close()
                return nil
            }
            self.panel = panel
        }
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panel.frame.width / 2,
            y: frame.minY + frame.height * 0.62
        ))
        panel.makeKeyAndOrderFront(nil)
    }
}

private struct QuickBarView: View {
    @ObservedObject var relay: RelayService
    let dismiss: () -> Void
    @State private var prompt = ""
    @State private var agentID = ""
    @FocusState private var focused: Bool

    private var copy: RelayCopy { RelayCopy(language: relay.language) }

    private var agent: RelayAgent? {
        relay.agents.first { $0.id == agentID } ?? relay.selectedAgent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button(action: cycleAgent) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill((agent?.accent ?? RelayPalette.signal).opacity(0.2))
                            .frame(width: 20, height: 20)
                            .overlay {
                                Text(agent?.monogram ?? "--")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(agent?.accent ?? RelayPalette.muted)
                            }
                        Text(agent?.name ?? copy.text("unavailable"))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                }
                .buttonStyle(.plain)
                .help(copy.text("Switch agent (Tab)"))

                TextField(copy.text("Send a task without leaving your app…"), text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .focused($focused)
                    .onSubmit(submit)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(RelayPalette.muted)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(RelayPalette.raised.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .help(copy.text("Close (Esc)"))
            }

            HStack(spacing: 12) {
                Text("⌥␣")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted.opacity(0.7))
                Text(copy.text("Runs in the background — you'll get a notification."))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                Spacer()
                Text(relay.defaultWorkingDirectory)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 620)
        .background {
            ZStack {
                RelayMaterial(material: .hudWindow)
                Color.black.opacity(0.25)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke((agent?.accent ?? RelayPalette.signal).opacity(0.35), lineWidth: 1)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            agentID = relay.selectedAgentID
            prompt = ""
            focused = true
        }
        .onExitCommand(perform: dismiss)
        .onKeyPress(.tab) {
            cycleAgent()
            return .handled
        }
    }

    private func cycleAgent() {
        let available = relay.agents.filter(\.isAvailable)
        guard !available.isEmpty else { return }
        if let index = available.firstIndex(where: { $0.id == (agent?.id ?? "") }) {
            agentID = available[(index + 1) % available.count].id
        } else {
            agentID = available[0].id
        }
    }

    private func submit() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let agent else { return }
        prompt = ""
        dismiss()
        Task {
            await relay.quickSubmit(agentID: agent.id, prompt: trimmed)
        }
    }
}
