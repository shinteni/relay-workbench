import Foundation

/// User-authored lifecycle hooks: when a background task completes, fails,
/// or starts waiting for a response, an explicitly configured local command
/// runs. Task facts travel via environment variables only — they are never
/// interpolated into the command string. Hooks execute while the GUI runs.
struct RelayTaskHook: Identifiable, Codable, Equatable {
    enum Event: String, Codable, CaseIterable {
        case completed
        case failed
        case waiting
    }

    let id: UUID
    var event: Event
    /// Restricts the hook to one agent; nil fires for every agent.
    var agentID: String?
    var command: String

    init(
        id: UUID = UUID(),
        event: Event,
        agentID: String? = nil,
        command: String
    ) {
        self.id = id
        self.event = event
        self.agentID = agentID
        self.command = command
    }
}

enum RelayTaskHookStore {
    static let defaultsKey = "taskLifecycleHooks"
    static let maxCount = 32
    static let maxCommandBytes = 1000

    static func load(defaults: UserDefaults = .standard) -> [RelayTaskHook] {
        guard let data = defaults.data(forKey: defaultsKey),
              let hooks = try? JSONDecoder().decode(
                  [RelayTaskHook].self, from: data
              ) else {
            return []
        }
        return Array(hooks.prefix(maxCount))
    }

    static func save(
        _ hooks: [RelayTaskHook], defaults: UserDefaults = .standard
    ) {
        let bounded = Array(hooks.prefix(maxCount))
        if let data = try? JSONEncoder().encode(bounded) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// Validation reason (English key for `copy.text`) or nil when valid.
    static func validationError(command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.utf8.count > maxCommandBytes {
            return "Hook command must be 1–1000 bytes"
        }
        return nil
    }
}

enum RelayTaskHookEngine {
    /// Maps a task-transition notification event onto the hook event kind.
    static func hookEvent(
        for notification: RelayNotificationEvent
    ) -> RelayTaskHook.Event? {
        switch notification {
        case .finished(let task):
            switch task.status {
            case .completed: return .completed
            case .failed: return .failed
            default: return nil
            }
        case .waiting:
            return .waiting
        }
    }

    static func matching(
        hooks: [RelayTaskHook],
        event: RelayTaskHook.Event,
        adapterID: String
    ) -> [RelayTaskHook] {
        hooks.filter { hook in
            hook.event == event
                && (hook.agentID == nil || hook.agentID == adapterID)
        }
    }

    /// Task facts as environment variables, bounded so a runaway message
    /// cannot bloat the child environment.
    static func environment(
        task: RelayTask, event: RelayTaskHook.Event
    ) -> [String: String] {
        var environment: [String: String] = [
            "RELAY_TASK_ID": task.id,
            "RELAY_TASK_EVENT": event.rawValue,
            "RELAY_TASK_STATUS": task.status.rawValue,
            "RELAY_TASK_ADAPTER": task.adapterID,
            "RELAY_TASK_TITLE": String(task.displayTitle.prefix(120)),
        ]
        if let message = task.latestMessage {
            environment["RELAY_TASK_MESSAGE"] = String(message.prefix(1000))
        }
        return environment
    }

    static func dedupKey(taskID: String, event: RelayTaskHook.Event) -> String {
        "\(taskID):\(event.rawValue)"
    }
}

/// Executes matched hooks, once per task per event kind.
@MainActor
final class RelayTaskHookRunner {
    private var fired = Set<String>()

    func process(
        events: [RelayNotificationEvent],
        hooks: [RelayTaskHook]
    ) {
        guard !hooks.isEmpty else { return }
        for notification in events {
            guard let event = RelayTaskHookEngine.hookEvent(for: notification) else {
                continue
            }
            let task = notification.task
            let key = RelayTaskHookEngine.dedupKey(taskID: task.id, event: event)
            guard !fired.contains(key) else { continue }
            let matched = RelayTaskHookEngine.matching(
                hooks: hooks, event: event, adapterID: task.adapterID
            )
            guard !matched.isEmpty else { continue }
            fired.insert(key)
            if fired.count > 4096 {
                fired.removeAll()
                fired.insert(key)
            }
            let extraEnvironment = RelayTaskHookEngine.environment(
                task: task, event: event
            )
            for hook in matched {
                launch(command: hook.command, extraEnvironment: extraEnvironment)
            }
        }
    }

    private func launch(command: String, extraEnvironment: [String: String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment
            .merging(extraEnvironment) { _, added in added }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
