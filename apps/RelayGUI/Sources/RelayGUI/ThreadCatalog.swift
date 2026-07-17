import Foundation

enum RelayThreadFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case waiting
    case failed
    case done

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    func includes(_ status: RelayTaskStatus) -> Bool {
        switch self {
        case .all:
            true
        case .active:
            status == .queued || status == .starting || status == .running
        case .waiting:
            status == .waitingForApproval || status == .waitingForInput
        case .failed:
            status == .failed
        case .done:
            status == .completed || status == .canceled
        }
    }
}

struct RelayAgentActivity: Equatable {
    let active: Int
    let waiting: Int

    var hasWork: Bool { active > 0 || waiting > 0 }
}

struct RelayTaskGroup: Identifiable {
    let cwd: String
    let tasks: [RelayTask]

    var id: String { cwd }

    var name: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }
}

enum ThreadCatalog {
    static func filtered(
        _ tasks: [RelayTask],
        query: String,
        filter: RelayThreadFilter = .all
    ) -> [RelayTask] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.filter { task in
            guard filter.includes(task.status) else { return false }
            guard !query.isEmpty else { return true }
            return [task.displayTitle, task.promptPreview, task.adapterID, task.cwd, task.shortID]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    static func grouped(
        _ tasks: [RelayTask],
        query: String,
        filter: RelayThreadFilter = .all
    ) -> [RelayTaskGroup] {
        var order: [String] = []
        var groups: [String: [RelayTask]] = [:]
        for task in filtered(tasks, query: query, filter: filter) {
            if groups[task.cwd] == nil {
                order.append(task.cwd)
            }
            groups[task.cwd, default: []].append(task)
        }
        return order.map { cwd in
            RelayTaskGroup(cwd: cwd, tasks: groups[cwd] ?? [])
        }
    }

    static func count(_ tasks: [RelayTask], filter: RelayThreadFilter) -> Int {
        tasks.lazy.filter { filter.includes($0.status) }.count
    }

    static func activity(_ tasks: [RelayTask], agentID: String) -> RelayAgentActivity {
        let agentTasks = tasks.lazy.filter { $0.adapterID == agentID }
        return RelayAgentActivity(
            active: agentTasks.filter { RelayThreadFilter.active.includes($0.status) }.count,
            waiting: agentTasks.filter { RelayThreadFilter.waiting.includes($0.status) }.count
        )
    }
}
