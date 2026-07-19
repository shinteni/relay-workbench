import AppKit
import Combine
import SwiftUI

@MainActor
final class RelayApplicationDelegate: NSObject, NSApplicationDelegate {
    let relay = RelayService()
    private let notifier = RelayNotifier()
    private let hotkey = RelayHotkey()
    private let quickBar = RelayQuickBarController()
    private var quickBarObservation: AnyCancellable?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        synchronizeQuickBarHotkey(enabled: relay.quickBarEnabled)
        quickBarObservation = relay.$quickBarEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.synchronizeQuickBarHotkey(enabled: enabled)
            }
        notifier.activate()
        notifier.isUserWatching = { [weak self] in
            NSApplication.shared.isActive && self?.mainWindow?.isVisible == true
        }
        notifier.onSelectTask = { [weak self] taskID in
            guard let self else { return }
            showMainWindow()
            relay.selectTask(taskID)
        }
        relay.onTaskEvents = { [weak self] events in
            guard let self else { return }
            notifier.post(
                events,
                enabled: relay.notificationsEnabled,
                copy: RelayCopy(language: relay.language)
            )
        }
        relay.startMonitoring()
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        relay.stopMonitoring()
    }

    private func synchronizeQuickBarHotkey(enabled: Bool) {
        if enabled {
            hotkey.register { [weak self] in
                guard let self else { return }
                quickBar.toggle(relay: relay)
            }
        } else {
            quickBar.close()
            hotkey.unregister()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        if mainWindow == nil {
            let root = RelayMainRoot(
                relay: relay,
                openSettings: showSettingsWindow
            )
                .preferredColorScheme(.dark)
                .frame(minWidth: 960, minHeight: 620)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "Relay"
            window.identifier = NSUserInterfaceItemIdentifier("main")
            window.styleMask = [
                .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
            ]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            // Background dragging would swallow mouseDown before the floating
            // terminal windows' drag gestures see it; the titlebar strip still
            // moves the app window.
            window.isMovableByWindowBackground = false
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.isOpaque = false
            window.backgroundColor = .clear
            window.minSize = NSSize(width: 960, height: 620)
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow() {
        if settingsWindow == nil {
            let root = RelaySettingsRoot(relay: relay)
                .preferredColorScheme(.dark)
                .frame(minWidth: 720, minHeight: 500)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: controller)
            window.title = "Relay"
            window.identifier = NSUserInterfaceItemIdentifier("settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.minSize = NSSize(width: 720, height: 500)
            window.setContentSize(NSSize(width: 780, height: 540))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct RelayMainRoot: View {
    @ObservedObject var relay: RelayService
    let openSettings: () -> Void

    var body: some View {
        ContentView(openSettings: openSettings)
            .environmentObject(relay)
            .environment(\.relayLanguage, relay.language)
    }
}

@main
struct RelayGUIApp: App {
    @NSApplicationDelegateAdaptor(RelayApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            RelayStatusMenu(
                openMainWindow: appDelegate.showMainWindow,
                openSettings: appDelegate.showSettingsWindow
            )
                .environmentObject(appDelegate.relay)
        } label: {
            RelayMenuBarLabel()
                .environmentObject(appDelegate.relay)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            RelaySettingsCommands(
                relay: appDelegate.relay,
                openSettings: appDelegate.showSettingsWindow
            )
        }
    }
}

private struct RelaySettingsCommands: Commands {
    @ObservedObject var relay: RelayService
    let openSettings: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(RelayCopy(language: relay.language).text("Open Settings…")) {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

private struct RelayMenuBarLabel: View {
    @EnvironmentObject private var relay: RelayService

    private var backgroundTaskCount: Int {
        relay.tasks.lazy.filter { !$0.status.isTerminal }.count
    }

    var body: some View {
        let copy = RelayCopy(language: relay.language)
        Image(systemName: backgroundTaskCount == 0 ? "terminal" : "terminal.fill")
            .accessibilityLabel("Relay, \(backgroundTaskCount) \(copy.text("background tasks"))")
    }
}

private struct RelayStatusMenu: View {
    @EnvironmentObject private var relay: RelayService
    let openMainWindow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        let copy = RelayCopy(language: relay.language)
        Text("DAEMON \(copy.daemonState(relay.daemonState))\(daemonVersion)")
        Text("\(activeCount) \(copy.text("ACTIVE")) · \(waitingCount) \(copy.text("WAITING"))")

        Divider()

        if backgroundTasks.isEmpty {
            Text(copy.text("No active or waiting tasks"))
        } else {
            ForEach(Array(backgroundTasks.prefix(6))) { task in
                Button("\(copy.taskStatus(task.status)) · \(task.displayTitle)") {
                    relay.selectTask(task.id)
                    showMainWindow()
                }
            }
            if backgroundTasks.count > 6 {
                Text("+\(backgroundTasks.count - 6)")
            }
        }

        Divider()

        Button(copy.text("Open Relay")) { showMainWindow() }
        Button(copy.text("Open Settings…")) { openSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Button(copy.text("Refresh Status")) {
            Task { await relay.refreshAll() }
        }

        Divider()

        Text(copy.text("Daemon continues after the UI quits"))
        Button(copy.text("Quit Relay UI")) {
            NSApplication.shared.terminate(nil)
        }
    }

    private var backgroundTasks: [RelayTask] {
        relay.tasks.filter { !$0.status.isTerminal }
    }

    private var activeCount: Int {
        ThreadCatalog.count(relay.tasks, filter: .active)
    }

    private var waitingCount: Int {
        ThreadCatalog.count(relay.tasks, filter: .waiting)
    }

    private var daemonVersion: String {
        relay.daemonVersion.map { " v\($0)" } ?? ""
    }

    private func showMainWindow() {
        openMainWindow()
    }
}
