import AppKit
import UserNotifications

enum RelayNotificationEvent: Equatable {
    case finished(RelayTask)
    case waiting(RelayTask)

    var task: RelayTask {
        switch self {
        case let .finished(task), let .waiting(task):
            task
        }
    }
}

enum RelayNotificationPlanner {
    static func events(
        previous: [String: RelayTaskStatus]?,
        current: [RelayTask]
    ) -> [RelayNotificationEvent] {
        guard let previous else { return [] }
        return current.compactMap { task in
            guard previous[task.id] != task.status else { return nil }
            switch task.status {
            case .completed, .failed:
                return .finished(task)
            case .waitingForApproval, .waitingForInput:
                return .waiting(task)
            case .queued, .starting, .running, .canceled:
                return nil
            }
        }
    }

    static func baseline(_ tasks: [RelayTask]) -> [String: RelayTaskStatus] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.status) })
    }
}

@MainActor
final class RelayNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onSelectTask: ((String) -> Void)?
    var isUserWatching: (() -> Bool)?
    private var authorizationRequested = false
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    func activate() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ events: [RelayNotificationEvent], enabled: Bool, copy: RelayCopy) {
        guard enabled,
              notificationsAvailable,
              !events.isEmpty,
              isUserWatching?() != true else { return }
        requestAuthorizationIfNeeded()
        let center = UNUserNotificationCenter.current()
        for event in events {
            let task = event.task
            let content = UNMutableNotificationContent()
            content.title = String(task.displayTitle.prefix(60))
            content.body = "\(task.adapterID.uppercased()) · \(copy.taskStatus(task.status))"
            content.sound = .default
            content.userInfo = ["taskID": task.id]
            center.add(UNNotificationRequest(
                identifier: "relay-task-\(task.id)",
                content: content,
                trigger: nil
            ))
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let taskID = response.notification.request.content.userInfo["taskID"] as? String
        Task { @MainActor in
            if let taskID {
                self.onSelectTask?(taskID)
            }
            completionHandler()
        }
    }
}
