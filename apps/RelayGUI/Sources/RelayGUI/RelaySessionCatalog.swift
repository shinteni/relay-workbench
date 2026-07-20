import Foundation

/// The session library is a browsable front for what the daemon already
/// records: every dialogue turn, compare member, chain step, and quick-bar
/// task. It groups raw tasks into session entries, derives titles, and
/// filters locally — embedded terminal PTY content is never part of it.
enum RelaySessionKind: String, CaseIterable {
    case compare
    case chain
    case single

    var glyph: String {
        switch self {
        case .compare: "⋈"
        case .chain: "›"
        case .single: "•"
        }
    }
}

struct RelaySessionEntry: Identifiable, Equatable {
    let id: String
    let kind: RelaySessionKind
    /// Explicit title of the lead task, or its prompt preview as fallback.
    let title: String
    let agentsLabel: String
    let projectPath: String
    let updatedAtMilliseconds: UInt64
    let hasActiveTask: Bool
    let turnCount: UInt32
    let tasks: [RelayTask]

    var leadTask: RelayTask? { tasks.first }
    var projectName: String {
        RelayTerminalContext.projectName(projectPath)
    }
}

/// サイドバーに表示するプロジェクト単位の履歴項目。
/// セッションと保存済みチェックポイントの保存・再開方式は変えず、
/// ユーザー向けのナビゲーションだけを統一する。
struct RelayProjectHistoryEntry: Identifiable, Equatable {
    enum Source: Equatable {
        case session(RelaySessionEntry)
        case decision(RelayDecisionCheckpoint)
    }

    let id: String
    let title: String
    let projectPath: String?
    let projectName: String
    let updatedAtMilliseconds: UInt64
    let hasActiveTask: Bool
    let source: Source
}

struct RelayProjectHistoryGroup: Identifiable, Equatable {
    let id: String
    let path: String?
    let name: String
    let entries: [RelayProjectHistoryEntry]
}

enum RelaySessionCatalog {
    /// Groups daemon tasks into session entries, newest activity first.
    /// Tasks sharing a `relay_group` become one compare/chain entry; the
    /// rest (dialogue seats, quick-bar tasks, one-click judges) are singles.
    static func entries(tasks: [RelayTask]) -> [RelaySessionEntry] {
        var grouped: [String: [RelayTask]] = [:]
        var singles: [RelayTask] = []
        for task in tasks {
            if let group = task.compareGroup, !group.isEmpty {
                grouped[group, default: []].append(task)
            } else {
                singles.append(task)
            }
        }

        var entries: [RelaySessionEntry] = []
        for (group, members) in grouped {
            let isChain = members.contains { $0.chainStep != nil }
            let ordered = members.sorted {
                ($0.chainStep ?? 0, $0.createdAtMilliseconds)
                    < ($1.chainStep ?? 0, $1.createdAtMilliseconds)
            }
            guard let lead = ordered.first else { continue }
            entries.append(RelaySessionEntry(
                id: group,
                kind: isChain ? .chain : .compare,
                title: lead.displayTitle,
                agentsLabel: ordered
                    .map { $0.adapterID.uppercased() }
                    .joined(separator: isChain ? " › " : " · "),
                projectPath: lead.cwd,
                updatedAtMilliseconds: ordered
                    .map(\.updatedAtMilliseconds).max() ?? 0,
                hasActiveTask: ordered.contains { !$0.status.isTerminal },
                turnCount: ordered.map(\.turnCount).reduce(0, +),
                tasks: ordered
            ))
        }
        for task in singles {
            entries.append(RelaySessionEntry(
                id: task.id,
                kind: .single,
                title: task.displayTitle,
                agentsLabel: task.adapterID.uppercased(),
                projectPath: task.cwd,
                updatedAtMilliseconds: task.updatedAtMilliseconds,
                hasActiveTask: !task.status.isTerminal,
                turnCount: task.turnCount,
                tasks: [task]
            ))
        }
        return entries.sorted {
            if $0.updatedAtMilliseconds == $1.updatedAtMilliseconds {
                return $0.id < $1.id
            }
            return $0.updatedAtMilliseconds > $1.updatedAtMilliseconds
        }
    }

    /// Multi-keyword local filter over title, prompts, agents, project and ID;
    /// case-, width- and diacritic-insensitive like the decision library.
    static func filter(
        _ entries: [RelaySessionEntry],
        query: String,
        kind: RelaySessionKind? = nil
    ) -> [RelaySessionEntry] {
        let scoped = kind.map { kind in
            entries.filter { $0.kind == kind }
        } ?? entries
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return scoped }
        return scoped.filter { entry in
            var fields = [
                entry.title,
                entry.agentsLabel,
                entry.projectName,
                entry.projectPath,
                entry.id,
            ]
            fields.append(contentsOf: entry.tasks.map(\.promptPreview))
            fields.append(contentsOf: entry.tasks.compactMap(\.title))
            let haystack = normalized(fields.joined(separator: "\n"))
            return terms.allSatisfy(haystack.contains)
        }
    }

    /// Codex-style project folders: entries grouped by working directory,
    /// folders ordered by their most recent activity. Paths are normalized
    /// through symlinks so `/Users/x/proj` and its aliases fold into one.
    static func byProject(
        _ entries: [RelaySessionEntry]
    ) -> [(path: String, name: String, entries: [RelaySessionEntry])] {
        var order: [String] = []
        var buckets: [String: [RelaySessionEntry]] = [:]
        for entry in entries {
            let key = normalizedProjectPath(entry.projectPath)
            if buckets[key] == nil {
                order.append(key)
            }
            buckets[key, default: []].append(entry)
        }
        return order.map { path in
            (
                path: path,
                name: RelayTerminalContext.projectName(path),
                entries: buckets[path] ?? []
            )
        }
    }

    static func historyEntries(
        tasks: [RelayTask],
        checkpoints: [RelayDecisionCheckpoint],
        annotations: [UUID: RelayDecisionAnnotation]
    ) -> [RelayProjectHistoryEntry] {
        var history = entries(tasks: tasks).map { entry in
            RelayProjectHistoryEntry(
                id: "session:\(entry.id)",
                title: entry.title,
                projectPath: entry.projectPath,
                projectName: entry.projectName,
                updatedAtMilliseconds: entry.updatedAtMilliseconds,
                hasActiveTask: entry.hasActiveTask,
                source: .session(entry)
            )
        }
        history.append(contentsOf: checkpoints.map { checkpoint in
            let decision = checkpoint.decision
            let route = (
                decision.receipt.plan.sources.map(\.agentName)
                    + [decision.result.agentName]
            ).joined(separator: " → ")
            let annotationTitle = annotations[checkpoint.id]?.title
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let milliseconds = max(0, checkpoint.savedAt.timeIntervalSince1970 * 1_000)
            return RelayProjectHistoryEntry(
                id: "decision:\(checkpoint.id.uuidString)",
                title: annotationTitle.isEmpty ? route : annotationTitle,
                projectPath: checkpoint.baseline?.projectPath,
                projectName: decision.result.projectName,
                updatedAtMilliseconds: UInt64(milliseconds),
                hasActiveTask: false,
                source: .decision(checkpoint)
            )
        })
        return history.sorted {
            if $0.updatedAtMilliseconds == $1.updatedAtMilliseconds {
                return $0.id < $1.id
            }
            return $0.updatedAtMilliseconds > $1.updatedAtMilliseconds
        }
    }

    /// Codex と同様のプロジェクトフォルダを組み立てる。
    /// 履歴がない既知のローカルプロジェクトも表示し、パスを持たない旧形式の
    /// チェックポイントは同名プロジェクトが一意の場合にそこへ関連付ける。
    static func historyProjects(
        _ entries: [RelayProjectHistoryEntry],
        knownProjectPaths: [String]
    ) -> [RelayProjectHistoryGroup] {
        var order: [String] = []
        var paths: [String: String] = [:]
        var names: [String: String] = [:]
        var buckets: [String: [RelayProjectHistoryEntry]] = [:]
        var pathsByName: [String: Set<String>] = [:]

        func registerPath(_ path: String) {
            let normalizedPath = normalizedProjectPath(path)
            guard paths[normalizedPath] == nil else { return }
            let name = RelayTerminalContext.projectName(normalizedPath)
            paths[normalizedPath] = normalizedPath
            names[normalizedPath] = name
            order.append(normalizedPath)
            buckets[normalizedPath] = []
            pathsByName[normalized(name), default: []].insert(normalizedPath)
        }

        knownProjectPaths.forEach(registerPath)
        entries.compactMap(\.projectPath).forEach(registerPath)

        for entry in entries {
            let key: String
            if let projectPath = entry.projectPath {
                key = normalizedProjectPath(projectPath)
            } else if let onlyPath = pathsByName[normalized(entry.projectName)]?.first,
                      pathsByName[normalized(entry.projectName)]?.count == 1 {
                key = onlyPath
            } else {
                key = "name:\(normalized(entry.projectName))"
                if buckets[key] == nil {
                    order.append(key)
                    buckets[key] = []
                    names[key] = entry.projectName
                }
            }
            buckets[key, default: []].append(entry)
        }

        return order.map { key in
            RelayProjectHistoryGroup(
                id: key,
                path: paths[key],
                name: names[key] ?? key,
                entries: (buckets[key] ?? []).sorted {
                    if $0.updatedAtMilliseconds == $1.updatedAtMilliseconds {
                        return $0.id < $1.id
                    }
                    return $0.updatedAtMilliseconds > $1.updatedAtMilliseconds
                }
            )
        }
    }

    static func filterHistory(
        _ entries: [RelayProjectHistoryEntry],
        query: String,
        sessionKind: RelaySessionKind? = nil,
        annotations: [UUID: RelayDecisionAnnotation]
    ) -> [RelayProjectHistoryEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
        return entries.filter { item in
            switch item.source {
            case .session(let entry):
                guard sessionKind == nil || entry.kind == sessionKind else { return false }
                guard !terms.isEmpty else { return true }
                var fields = [
                    entry.title, entry.agentsLabel, entry.projectName,
                    entry.projectPath, entry.id,
                ]
                fields.append(contentsOf: entry.tasks.map(\.promptPreview))
                fields.append(contentsOf: entry.tasks.compactMap(\.title))
                let haystack = normalized(fields.joined(separator: "\n"))
                return terms.allSatisfy(haystack.contains)
            case .decision(let checkpoint):
                guard sessionKind == nil else { return false }
                guard !terms.isEmpty else { return true }
                return !RelayDecisionSearch.filter(
                    [checkpoint], query: query, annotations: annotations
                ).isEmpty
            }
        }
    }

    static func normalizedProjectPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}
