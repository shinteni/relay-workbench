import AppKit
import SwiftTerm
import SwiftUI

enum RelayTerminalLauncher {
    struct Spec: Equatable {
        let executable: String
        let arguments: [String]
    }

    static let maxSessions = 4

    /// Interactive command for embedding an agent's real CLI. `nil` when the
    /// agent has no standalone interactive CLI (e.g. MIX composite runtime).
    static func spec(for agent: RelayAgent, optionValue: (String) -> String?) -> Spec? {
        switch agent.id {
        case "mix":
            return nil
        case "claude":
            return agent.registrationEnvironment["RELAY_CLAUDE_PATH"].map {
                Spec(executable: $0, arguments: [])
            }
        case "codex":
            return agent.registrationEnvironment["RELAY_CODEX_PATH"].map {
                Spec(executable: $0, arguments: [])
            }
        case "ollama":
            guard let binary = agent.registrationEnvironment["RELAY_OLLAMA_PATH"] else {
                return nil
            }
            var model = optionValue("model") ?? ""
            if model.isEmpty || model == "default" {
                model = agent.options.first { $0.key == "model" }?.defaultValue ?? ""
            }
            guard !model.isEmpty, model != "default" else {
                return Spec(executable: binary, arguments: ["run", "gemma4:latest"])
            }
            return Spec(executable: binary, arguments: ["run", model])
        default:
            if let binary = agent.versionExecutablePath {
                return Spec(executable: binary, arguments: [])
            }
            let fallback = agent.registrationEnvironment
                .filter { $0.key != "RELAY_GENERIC_SPEC" }
                .values
                .sorted()
                .first
            return fallback.map { Spec(executable: $0, arguments: []) }
        }
    }

    /// The command line executed inside the login shell.
    static func shellCommand(_ spec: Spec) -> String {
        (["exec", quoted(spec.executable)] + spec.arguments.map(quoted))
            .joined(separator: " ")
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// KEY=VALUE pairs for the PTY child, based on the GUI's environment.
    static func environment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"]?.isEmpty != false {
            env["LANG"] = "en_US.UTF-8"
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    static func resolvedWorkingDirectory(
        _ path: String,
        fileManager: FileManager = .default
    ) -> String {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return path
        }
        return fileManager.homeDirectoryForCurrentUser.path
    }
}

enum RelayTerminalContext {
    static func projectName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent
        return name.isEmpty ? "/" : name
    }

    static func sidebarSubtitle(cwd: String, detail: String) -> String {
        let project = projectName(cwd)
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare(project) == .orderedSame {
            return project
        }
        return "\(project) · \(trimmed)"
    }
}

enum RelayTerminalActivity {
    static let activeInterval: TimeInterval = 1.5

    static func isActive(lastOutputAt: Date?, now: Date) -> Bool {
        guard let lastOutputAt else { return false }
        let elapsed = now.timeIntervalSince(lastOutputAt)
        return elapsed >= 0 && elapsed <= activeInterval
    }
}

enum RelayPromptStaging {
    static let maxBytes = 64 * 1024
    private static let start = Array("\u{1B}[200~".utf8)
    private static let end = Array("\u{1B}[201~".utf8)

    static func sanitized(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= maxBytes else { return nil }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            switch scalar.value {
            case 0x09:
                scalars.append(contentsOf: "    ".unicodeScalars)
            case 0x0A:
                scalars.append(scalar)
            case 0x00 ... 0x1F, 0x7F ... 0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        let result = String(scalars)
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.utf8.count <= maxBytes else { return nil }
        return result
    }

    static func payload(_ text: String) -> [UInt8]? {
        guard let text = sanitized(text) else { return nil }
        return start + Array(text.utf8) + end
    }
}

enum RelayTerminalContextRelay {
    static let maxCaptureBytes = 48 * 1024
    private static let truncationMarker = "…\n"

    static func capture(_ data: Data) -> String? {
        let normalized = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var scalars = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A:
                scalars.append(scalar)
            case 0x00 ... 0x1F, 0x7F ... 0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        var lines = String(scalars).split(
            separator: "\n", omittingEmptySubsequences: false
        ).map(String.init)
        while lines.first?.allSatisfy({ $0.isWhitespace }) == true {
            lines.removeFirst()
        }
        while lines.last?.allSatisfy({ $0.isWhitespace }) == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }
        return limitedTail(lines.joined(separator: "\n"))
    }

    static func payload(
        instruction: String,
        context: String,
        sourceAgent: String,
        projectName: String
    ) -> String? {
        guard let instruction = RelayPromptStaging.sanitized(instruction),
              let context = RelayPromptStaging.sanitized(context) else { return nil }
        return RelayPromptStaging.sanitized(
            "\(instruction)\n\n[Relay context · \(sourceAgent) · \(projectName)]\n\(context)"
        )
    }

    private static func limitedTail(_ text: String) -> String {
        let bytes = Data(text.utf8)
        guard bytes.count > maxCaptureBytes else { return text }
        let markerBytes = Data(truncationMarker.utf8)
        let allowance = maxCaptureBytes - markerBytes.count
        var start = bytes.count - allowance
        while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 {
            start += 1
        }
        return truncationMarker + String(decoding: bytes[start...], as: UTF8.self)
    }
}

struct RelayContextRelayDraft: Identifiable, Equatable {
    let id = UUID()
    let sourceID: UUID
    let sourceAgentName: String
    let projectName: String
    let context: String
}

struct RelayResultSnapshot: Identifiable, Codable, Equatable {
    let id: UUID
    let agentName: String
    let projectName: String
    let text: String
}

struct RelayResultConfluence: Identifiable, Codable, Equatable {
    let id: UUID
    let snapshots: [RelayResultSnapshot]

    init(id: UUID = UUID(), snapshots: [RelayResultSnapshot]) {
        self.id = id
        self.snapshots = snapshots
    }
}

struct RelayResultArbitrationSourcePlan: Identifiable, Codable, Equatable {
    let id: UUID
    let agentName: String
    let projectName: String
    let originalBytes: Int
    let retainedBytes: Int
    let truncated: Bool
}

struct RelayResultArbitrationPlan: Codable, Equatable {
    let payload: String
    let sources: [RelayResultArbitrationSourcePlan]

    var payloadBytes: Int { payload.utf8.count }
}

struct RelayResultArbitrationReceipt: Codable, Equatable {
    let confluence: RelayResultConfluence
    let plan: RelayResultArbitrationPlan
    let targetID: UUID
    let parentCheckpointID: UUID?

    init(
        confluence: RelayResultConfluence,
        plan: RelayResultArbitrationPlan,
        targetID: UUID,
        parentCheckpointID: UUID? = nil
    ) {
        self.confluence = confluence
        self.plan = plan
        self.targetID = targetID
        self.parentCheckpointID = parentCheckpointID
    }
}

struct RelayResultArbitrationDecision: Identifiable, Codable, Equatable {
    let id: UUID
    let receipt: RelayResultArbitrationReceipt
    let result: RelayResultSnapshot

    init(
        id: UUID = UUID(),
        receipt: RelayResultArbitrationReceipt,
        result: RelayResultSnapshot
    ) {
        self.id = id
        self.receipt = receipt
        self.result = result
    }
}

struct RelayDecisionBriefPlan: Equatable {
    let payload: String
    let decisionOriginalBytes: Int
    let decisionRetainedBytes: Int
    let decisionTruncated: Bool

    var payloadBytes: Int { payload.utf8.count }
}

enum RelayDecisionBrief {
    private static let truncationMarker = "… [earlier decision truncated]\n"

    static func plan(
        checkpoint: RelayDecisionCheckpoint,
        annotation: RelayDecisionAnnotation?,
        instruction: String
    ) -> RelayDecisionBriefPlan? {
        let annotation = annotation?.checkpointID == checkpoint.id ? annotation : nil
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstruction: String?
        if trimmedInstruction.isEmpty {
            normalizedInstruction = nil
        } else {
            guard let sanitized = RelayPromptStaging.sanitized(instruction) else { return nil }
            normalizedInstruction = sanitized
        }
        guard let agentName = label(checkpoint.decision.result.agentName),
              let projectName = label(checkpoint.decision.result.projectName),
              let result = RelayPromptStaging.sanitized(checkpoint.decision.result.text) else {
            return nil
        }

        var metadata = [
            "[Relay decision brief · sealed local checkpoint]",
            "Checkpoint: \(checkpoint.id.uuidString)",
            "Saved: \(checkpoint.savedAt.ISO8601Format())",
            "Arbiter: \(agentName) · \(projectName)",
            "Frozen sources: \(checkpoint.decision.receipt.plan.sources.count)",
        ]
        if let title = annotation?.title, !title.isEmpty,
           let title = label(title) {
            metadata.append("Title: \(title)")
        }
        if let tags = annotation?.tags, !tags.isEmpty,
           let tags = label(tags.joined(separator: ", ")) {
            metadata.append("Tags: \(tags)")
        }
        metadata.append("[Sealed result]")

        let prefix = [normalizedInstruction, metadata.joined(separator: "\n")]
            .compactMap { $0 }
            .joined(separator: "\n\n") + "\n"
        let resultBytes = Data(result.utf8)
        let availableBytes = RelayPromptStaging.maxBytes - prefix.utf8.count
        guard availableBytes > 0,
              let limited = limitedTail(resultBytes, maxBytes: availableBytes),
              let payload = RelayPromptStaging.sanitized(prefix + limited.text) else {
            return nil
        }
        return RelayDecisionBriefPlan(
            payload: payload,
            decisionOriginalBytes: resultBytes.count,
            decisionRetainedBytes: limited.retainedBytes,
            decisionTruncated: limited.truncated
        )
    }

    private static func label(_ text: String) -> String? {
        RelayPromptStaging.sanitized(text)?
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func limitedTail(
        _ bytes: Data,
        maxBytes: Int
    ) -> (text: String, retainedBytes: Int, truncated: Bool)? {
        guard bytes.count > maxBytes else {
            return (String(decoding: bytes, as: UTF8.self), bytes.count, false)
        }
        let markerBytes = Data(truncationMarker.utf8)
        guard maxBytes > markerBytes.count else { return nil }
        var start = bytes.count - (maxBytes - markerBytes.count)
        while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 {
            start += 1
        }
        return (
            truncationMarker + String(decoding: bytes[start...], as: UTF8.self),
            bytes.count - start,
            true
        )
    }
}

enum RelayDecisionDeltaKind: Equatable {
    case unchanged
    case removed
    case added
}

struct RelayDecisionDeltaRow: Identifiable, Equatable {
    let id: Int
    let kind: RelayDecisionDeltaKind
    let parentLineNumber: Int?
    let derivedLineNumber: Int?
    let text: String
}

struct RelayDecisionDelta: Equatable {
    static let maxLinesPerSide = 300
    static let maxBytesPerSide = 64 * 1024

    let rows: [RelayDecisionDeltaRow]
    let parentTruncated: Bool
    let derivedTruncated: Bool
    let parentBytes: Int
    let derivedBytes: Int

    var addedCount: Int { rows.count { $0.kind == .added } }
    var removedCount: Int { rows.count { $0.kind == .removed } }
    var unchangedCount: Int { rows.count { $0.kind == .unchanged } }

    init(parent: String, derived: String) {
        let parentSide = Self.limitedLines(parent)
        let derivedSide = Self.limitedLines(derived)
        rows = Self.alignedRows(
            parent: parentSide.lines,
            parentStartLine: parentSide.startLine,
            derived: derivedSide.lines,
            derivedStartLine: derivedSide.startLine
        )
        parentTruncated = parentSide.truncated
        derivedTruncated = derivedSide.truncated
        parentBytes = parentSide.bytes
        derivedBytes = derivedSide.bytes
    }

    private static func limitedLines(
        _ text: String
    ) -> (lines: [String], startLine: Int, truncated: Bool, bytes: Int) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let bytes = Data(normalized.utf8)
        var truncated = bytes.count > maxBytesPerSide
        var bounded = normalized
        var startLine = 1
        if truncated {
            var start = bytes.count - maxBytesPerSide
            while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 {
                start += 1
            }
            startLine += bytes[..<start].count { $0 == 0x0A }
            bounded = String(decoding: bytes[start...], as: UTF8.self)
        }
        var lines = bounded.split(
            separator: "\n", omittingEmptySubsequences: false
        ).map(String.init)
        if lines.count > maxLinesPerSide {
            startLine += lines.count - maxLinesPerSide
            lines = Array(lines.suffix(maxLinesPerSide))
            truncated = true
        }
        return (
            lines,
            startLine,
            truncated,
            lines.joined(separator: "\n").utf8.count
        )
    }

    private static func alignedRows(
        parent: [String],
        parentStartLine: Int,
        derived: [String],
        derivedStartLine: Int
    ) -> [RelayDecisionDeltaRow] {
        var common = Array(
            repeating: Array(repeating: 0, count: derived.count + 1),
            count: parent.count + 1
        )
        if !parent.isEmpty, !derived.isEmpty {
            for parentIndex in stride(from: parent.count - 1, through: 0, by: -1) {
                for derivedIndex in stride(from: derived.count - 1, through: 0, by: -1) {
                    common[parentIndex][derivedIndex] = parent[parentIndex] == derived[derivedIndex]
                        ? common[parentIndex + 1][derivedIndex + 1] + 1
                        : max(
                            common[parentIndex + 1][derivedIndex],
                            common[parentIndex][derivedIndex + 1]
                        )
                }
            }
        }

        var rows: [RelayDecisionDeltaRow] = []
        var parentIndex = 0
        var derivedIndex = 0
        while parentIndex < parent.count || derivedIndex < derived.count {
            if parentIndex < parent.count,
               derivedIndex < derived.count,
               parent[parentIndex] == derived[derivedIndex] {
                rows.append(RelayDecisionDeltaRow(
                    id: rows.count,
                    kind: .unchanged,
                    parentLineNumber: parentStartLine + parentIndex,
                    derivedLineNumber: derivedStartLine + derivedIndex,
                    text: parent[parentIndex]
                ))
                parentIndex += 1
                derivedIndex += 1
            } else if parentIndex < parent.count,
                      derivedIndex == derived.count
                        || common[parentIndex + 1][derivedIndex]
                            >= common[parentIndex][derivedIndex + 1] {
                rows.append(RelayDecisionDeltaRow(
                    id: rows.count,
                    kind: .removed,
                    parentLineNumber: parentStartLine + parentIndex,
                    derivedLineNumber: nil,
                    text: parent[parentIndex]
                ))
                parentIndex += 1
            } else {
                rows.append(RelayDecisionDeltaRow(
                    id: rows.count,
                    kind: .added,
                    parentLineNumber: nil,
                    derivedLineNumber: derivedStartLine + derivedIndex,
                    text: derived[derivedIndex]
                ))
                derivedIndex += 1
            }
        }
        return rows
    }
}

enum RelayResultSnapshotDrift: Equatable {
    case unchanged
    case changed
    case closed
}

enum RelayResultArbitration {
    private static let truncationMarker = "… [earlier screen truncated]\n"

    static func payload(
        instruction: String,
        snapshots: [RelayResultSnapshot]
    ) -> String? {
        plan(instruction: instruction, snapshots: snapshots)?.payload
    }

    static func plan(
        instruction: String,
        snapshots: [RelayResultSnapshot]
    ) -> RelayResultArbitrationPlan? {
        guard let instruction = RelayPromptStaging.sanitized(instruction),
              !snapshots.isEmpty else { return nil }
        let sources = snapshots.enumerated().compactMap { index, snapshot
            -> (snapshot: RelayResultSnapshot, header: String, text: String)? in
            guard let agentName = label(snapshot.agentName),
                  let projectName = label(snapshot.projectName),
                  let text = RelayPromptStaging.sanitized(snapshot.text) else { return nil }
            return (
                snapshot,
                "[Result \(index + 1) · \(agentName) · \(projectName)]\n",
                text
            )
        }
        guard sources.count == snapshots.count else { return nil }

        let prefix = "\(instruction)\n\n[Relay frozen results · \(sources.count) CLI screens]\n\n"
        let fixed = prefix + sources.map(\.header).joined(separator: "\n\n")
        let availableBytes = RelayPromptStaging.maxBytes - fixed.utf8.count
        guard availableBytes > 0 else { return nil }

        let budgets = sourceBudgets(
            sizes: sources.map { $0.text.utf8.count },
            total: availableBytes
        )
        var blocks: [String] = []
        var sourcePlans: [RelayResultArbitrationSourcePlan] = []
        for (index, source) in sources.enumerated() {
            guard let limited = limitedTail(source.text, maxBytes: budgets[index]) else {
                return nil
            }
            blocks.append(source.header + limited.text)
            sourcePlans.append(RelayResultArbitrationSourcePlan(
                id: source.snapshot.id,
                agentName: source.snapshot.agentName,
                projectName: source.snapshot.projectName,
                originalBytes: source.text.utf8.count,
                retainedBytes: limited.retainedBytes,
                truncated: limited.truncated
            ))
        }
        guard let payload = RelayPromptStaging.sanitized(
            prefix + blocks.joined(separator: "\n\n")
        ) else { return nil }
        return RelayResultArbitrationPlan(payload: payload, sources: sourcePlans)
    }

    private static func sourceBudgets(sizes: [Int], total: Int) -> [Int] {
        var budgets = Array(repeating: 0, count: sizes.count)
        var pending = Set(sizes.indices)
        var remaining = total
        while !pending.isEmpty {
            let share = remaining / pending.count
            let completed = pending.filter { sizes[$0] <= share }
            if completed.isEmpty {
                let ordered = pending.sorted()
                let base = remaining / ordered.count
                let remainder = remaining % ordered.count
                for (offset, index) in ordered.enumerated() {
                    budgets[index] = base + (offset < remainder ? 1 : 0)
                }
                break
            }
            for index in completed {
                budgets[index] = sizes[index]
                remaining -= sizes[index]
                pending.remove(index)
            }
        }
        return budgets
    }

    private static func label(_ text: String) -> String? {
        RelayPromptStaging.sanitized(text)?
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func limitedTail(
        _ text: String,
        maxBytes: Int
    ) -> (text: String, retainedBytes: Int, truncated: Bool)? {
        let bytes = Data(text.utf8)
        guard bytes.count > maxBytes else { return (text, bytes.count, false) }
        let markerBytes = Data(truncationMarker.utf8)
        guard maxBytes > markerBytes.count else { return nil }
        var start = bytes.count - (maxBytes - markerBytes.count)
        while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 {
            start += 1
        }
        return (
            truncationMarker + String(decoding: bytes[start...], as: UTF8.self),
            bytes.count - start,
            true
        )
    }
}

enum RelayTerminalInputSignal: Equatable {
    case edited
    case returnKey
}

enum RelayTerminalInputClassifier {
    private static let editingControls: Set<UInt8> = [0x04, 0x08, 0x0B, 0x14, 0x15, 0x17, 0x19, 0x7F]

    static func classify(_ data: ArraySlice<UInt8>) -> RelayTerminalInputSignal? {
        let bytes = Array(data)
        var edited = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x0A || byte == 0x0D {
                return .returnKey
            }
            if byte == 0x1B {
                guard index + 1 < bytes.count else { break }
                let next = bytes[index + 1]
                if next == 0x5B {
                    let parametersStart = index + 2
                    var end = parametersStart
                    while end < bytes.count, !(0x40 ... 0x7E).contains(bytes[end]) {
                        end += 1
                    }
                    guard end < bytes.count else { break }
                    if bytes[end] == 0x75,
                       let codepoint = kittyCodepoint(bytes[parametersStart ..< end]) {
                        if codepoint == 10 || codepoint == 13 {
                            return .returnKey
                        }
                        if editingControls.contains(UInt8(clamping: codepoint))
                            || (codepoint >= 0x20 && !(0xE000 ... 0xF8FF).contains(codepoint)) {
                            edited = true
                        }
                    }
                    index = end + 1
                    continue
                }
                if next == 0x4F {
                    index = min(index + 3, bytes.count)
                    continue
                }
                if next == 0x64 || next == 0x7F {
                    edited = true
                }
                index += 2
                continue
            }
            if editingControls.contains(byte) || (byte >= 0x20 && byte != 0x7F) {
                edited = true
            }
            index += 1
        }
        return edited ? .edited : nil
    }

    private static func kittyCodepoint(_ parameters: ArraySlice<UInt8>) -> Int? {
        let digits = parameters.prefix { (0x30 ... 0x39).contains($0) }
        guard !digits.isEmpty else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }
}

struct RelayTerminalInputSnapshot: Equatable {
    let generation: Int
    let editRevision: Int
    let returnRevision: Int

    static let zero = RelayTerminalInputSnapshot(
        generation: 0, editRevision: 0, returnRevision: 0
    )
}

enum RelayPromptTargetSignal: Equatable {
    case none
    case edited
    case returnDetected
    case restarted
    case closed

    static func resolve(
        baseline: RelayTerminalInputSnapshot,
        current: RelayTerminalInputSnapshot?
    ) -> RelayPromptTargetSignal {
        guard let current else { return .closed }
        guard current.generation == baseline.generation else { return .restarted }
        if current.returnRevision > baseline.returnRevision {
            return .returnDetected
        }
        if current.editRevision > baseline.editRevision {
            return .edited
        }
        return .none
    }
}

struct RelayPromptReviewTarget: Identifiable, Equatable {
    let id: UUID
    let agentName: String
    let projectName: String
    let inputBaseline: RelayTerminalInputSnapshot

    init(
        id: UUID,
        agentName: String,
        projectName: String,
        inputBaseline: RelayTerminalInputSnapshot = .zero
    ) {
        self.id = id
        self.agentName = agentName
        self.projectName = projectName
        self.inputBaseline = inputBaseline
    }
}

struct RelayPromptReviewPlan: Equatable {
    let targets: [RelayPromptReviewTarget]
    private(set) var reviewedIDs = Set<UUID>()
    private(set) var currentID: UUID?

    init(targets: [RelayPromptReviewTarget]) {
        var seen = Set<UUID>()
        self.targets = targets.filter { seen.insert($0.id).inserted }
        currentID = self.targets.first?.id
    }

    func reviewedCount() -> Int {
        targets.count { reviewedIDs.contains($0.id) }
    }

    func closedCount(availableIDs: Set<UUID>) -> Int {
        targets.count { !availableIDs.contains($0.id) }
    }

    func pendingCount(availableIDs: Set<UUID>) -> Int {
        targets.count {
            availableIDs.contains($0.id) && !reviewedIDs.contains($0.id)
        }
    }

    func isFinished(availableIDs: Set<UUID>) -> Bool {
        !targets.isEmpty && targets.allSatisfy {
            reviewedIDs.contains($0.id) || !availableIDs.contains($0.id)
        }
    }

    func isComplete() -> Bool {
        !targets.isEmpty && targets.allSatisfy { reviewedIDs.contains($0.id) }
    }

    func nextPendingID(availableIDs: Set<UUID>) -> UUID? {
        if let currentID,
           availableIDs.contains(currentID),
           !reviewedIDs.contains(currentID) {
            return currentID
        }
        return targets.first {
            availableIDs.contains($0.id) && !reviewedIDs.contains($0.id)
        }?.id
    }

    @discardableResult
    mutating func selectNextPending(availableIDs: Set<UUID>) -> UUID? {
        currentID = nextPendingID(availableIDs: availableIDs)
        return currentID
    }

    @discardableResult
    mutating func select(_ id: UUID, availableIDs: Set<UUID>) -> UUID? {
        guard targets.contains(where: { $0.id == id }), availableIDs.contains(id) else {
            return nil
        }
        currentID = id
        return id
    }

    @discardableResult
    mutating func confirmCurrent(availableIDs: Set<UUID>) -> UUID? {
        guard let currentID, availableIDs.contains(currentID) else {
            return reconcile(availableIDs: availableIDs)
        }
        reviewedIDs.insert(currentID)
        let ids = targets.map(\.id)
        guard let index = ids.firstIndex(of: currentID) else {
            self.currentID = nil
            return nil
        }
        let candidates = Array(ids.dropFirst(index + 1)) + Array(ids.prefix(index + 1))
        let next = candidates.first {
            availableIDs.contains($0) && !reviewedIDs.contains($0)
        }
        self.currentID = next
        return next
    }

    @discardableResult
    mutating func reconcile(availableIDs: Set<UUID>) -> UUID? {
        if let currentID, availableIDs.contains(currentID) {
            return currentID
        }
        currentID = targets.first {
            availableIDs.contains($0.id) && !reviewedIDs.contains($0.id)
        }?.id
        return currentID
    }
}

enum RelayTerminalAttentionKind: Equatable {
    case promptReview
    case pendingOutput
    case activeOutput
}

struct RelayTerminalAttention: Equatable {
    let kind: RelayTerminalAttentionKind
    let sessionID: UUID
    let count: Int
}

struct RelayTerminalReturnTicket: Equatable {
    let sessionID: UUID
    let closesPromptStaging: Bool
}

struct RelayAttentionRoutePulse: Identifiable, Equatable {
    let id = UUID()
    let sourceID: UUID
    let targetID: UUID
}

/// Which edge or corner of a floating terminal window a resize drag grabs.
enum RelayResizeHandle: CaseIterable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var affectsLeft: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }

    var affectsRight: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }

    var affectsTop: Bool {
        self == .top || self == .topLeft || self == .topRight
    }

    var affectsBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
}

/// Pure frame math for free-floating terminal windows inside the workspace.
enum RelayWindowGeometry {
    static let minSize = CGSize(width: 320, height: 200)
    /// Reserved band at the top of the workspace. Zero: the header drag is
    /// AppKit-backed (`mouseDownCanMoveWindow = false`), so it keeps working
    /// even inside the main window's transparent titlebar strip.
    static let topInset: CGFloat = 0
    static let margin: CGFloat = 10
    static let tileGap: CGFloat = 10

    /// The area of the workspace that windows may occupy.
    static func canvas(_ size: CGSize) -> CGRect {
        CGRect(
            x: 0, y: topInset,
            width: max(size.width, 0),
            height: max(size.height - topInset, 0)
        )
    }

    /// Shrinks and shifts a frame until it lies inside the canvas.
    static func fitted(_ frame: CGRect, in size: CGSize) -> CGRect {
        let area = canvas(size)
        guard area.width > 0, area.height > 0 else { return frame }
        var fit = frame
        fit.size.width = min(max(fit.width, min(minSize.width, area.width)), area.width)
        fit.size.height = min(max(fit.height, min(minSize.height, area.height)), area.height)
        fit.origin.x = min(max(fit.minX, area.minX), area.maxX - fit.width)
        fit.origin.y = min(max(fit.minY, area.minY), area.maxY - fit.height)
        return fit
    }

    static func moved(
        _ base: CGRect, translation: CGSize, in size: CGSize
    ) -> CGRect {
        fitted(
            CGRect(
                x: base.minX + translation.width,
                y: base.minY + translation.height,
                width: base.width,
                height: base.height
            ),
            in: size
        )
    }

    static func resized(
        _ base: CGRect,
        handle: RelayResizeHandle,
        translation: CGSize,
        in size: CGSize
    ) -> CGRect {
        let area = canvas(size)
        var frame = base
        if handle.affectsLeft {
            let newLeft = min(
                max(base.minX + translation.width, area.minX),
                base.maxX - minSize.width
            )
            frame.origin.x = newLeft
            frame.size.width = base.maxX - newLeft
        }
        if handle.affectsRight {
            let newRight = min(
                max(base.maxX + translation.width, base.minX + minSize.width),
                area.maxX
            )
            frame.size.width = newRight - base.minX
        }
        if handle.affectsTop {
            let newTop = min(
                max(base.minY + translation.height, area.minY),
                base.maxY - minSize.height
            )
            frame.origin.y = newTop
            frame.size.height = base.maxY - newTop
        }
        if handle.affectsBottom {
            let newBottom = min(
                max(base.maxY + translation.height, base.minY + minSize.height),
                area.maxY
            )
            frame.size.height = newBottom - base.minY
        }
        return frame
    }

    /// Staggered default frame for the n-th opened window.
    static func cascadeFrame(serial: Int, in size: CGSize) -> CGRect {
        let area = canvas(size)
        guard area.width >= minSize.width, area.height >= minSize.height else {
            return CGRect(origin: CGPoint(x: 0, y: topInset), size: minSize)
        }
        let width = min(max(area.width * 0.58, 460), area.width - margin * 2)
        let height = min(max(area.height * 0.62, 340), area.height - margin * 2)
        let offset = CGFloat(serial % 6) * 30
        return fitted(
            CGRect(
                x: area.minX + margin + offset,
                y: area.minY + margin + offset,
                width: width,
                height: height
            ),
            in: size
        )
    }

    /// Non-overlapping grid frames for `count` windows (1 full, 2 columns,
    /// 3 one tall + two stacked, 4 a 2×2 grid).
    static func tiled(count: Int, in size: CGSize) -> [CGRect] {
        let area = canvas(size).insetBy(dx: margin, dy: margin)
        guard count > 0, area.width > 0, area.height > 0 else { return [] }

        func hsplit(_ rect: CGRect) -> (CGRect, CGRect) {
            let width = (rect.width - tileGap) / 2
            return (
                CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                CGRect(x: rect.minX + width + tileGap, y: rect.minY, width: width, height: rect.height)
            )
        }
        func vsplit(_ rect: CGRect) -> (CGRect, CGRect) {
            let height = (rect.height - tileGap) / 2
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                CGRect(x: rect.minX, y: rect.minY + height + tileGap, width: rect.width, height: height)
            )
        }

        func row(_ rect: CGRect, count: Int) -> [CGRect] {
            guard count > 0 else { return [] }
            let width = (rect.width - tileGap * CGFloat(count - 1)) / CGFloat(count)
            return (0..<count).map { index in
                CGRect(
                    x: rect.minX + CGFloat(index) * (width + tileGap),
                    y: rect.minY, width: width, height: rect.height
                )
            }
        }

        switch count {
        case 1:
            return [area]
        case 2:
            let (left, right) = hsplit(area)
            return [left, right]
        case 3:
            let (left, right) = hsplit(area)
            let (rightTop, rightBottom) = vsplit(right)
            return [left, rightTop, rightBottom]
        case 4:
            let (left, right) = hsplit(area)
            let (leftTop, leftBottom) = vsplit(left)
            let (rightTop, rightBottom) = vsplit(right)
            return [leftTop, rightTop, leftBottom, rightBottom]
        default:
            let (top, bottom) = vsplit(area)
            let topCount = (count + 1) / 2
            return row(top, count: topCount) + row(bottom, count: count - topCount)
        }
    }
}

/// 前回のデスクを構成した CLI ターミナルの復元用データ。
/// メインウィンドウのサイズ変更後も配置を保つため、座標は正規化する。
struct RelayDeskSnapshot: Codable, Equatable {
    static let defaultsKey = "terminalDesk.v1"

    struct Terminal: Codable, Equatable {
        let agentID: String
        let cwd: String
        let frame: NormalizedFrame
    }

    struct NormalizedFrame: Codable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double

        init(_ frame: CGRect, in canvasSize: CGSize) {
            let canvas = RelayWindowGeometry.canvas(canvasSize)
            x = canvas.width > 0 ? (frame.minX - canvas.minX) / canvas.width : 0
            y = canvas.height > 0 ? (frame.minY - canvas.minY) / canvas.height : 0
            width = canvas.width > 0 ? frame.width / canvas.width : 1
            height = canvas.height > 0 ? frame.height / canvas.height : 1
        }

        func rect(in canvasSize: CGSize) -> CGRect {
            let canvas = RelayWindowGeometry.canvas(canvasSize)
            return CGRect(
                x: canvas.minX + x * canvas.width,
                y: canvas.minY + y * canvas.height,
                width: width * canvas.width,
                height: height * canvas.height
            )
        }
    }

    let terminals: [Terminal]
}

final class RelayTerminalNSView: LocalProcessTerminalView {
    var onFocusChange: (() -> Void)?
    var onOutput: (() -> Void)?
    var onUserInput: ((RelayTerminalInputSignal) -> Void)?
    private var lastOutputNotificationUptime = 0.0
    private var suppressUserInputObservation = false

    func sendProgrammatically(data: ArraySlice<UInt8>) {
        suppressUserInputObservation = true
        defer { suppressUserInputObservation = false }
        send(data: data)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if !suppressUserInputObservation,
           let signal = RelayTerminalInputClassifier.classify(data) {
            onUserInput?(signal)
        }
        super.send(source: source, data: data)
    }

    override func mouseDown(with event: NSEvent) {
        onFocusChange?()
        super.mouseDown(with: event)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastOutputNotificationUptime >= 0.15 else { return }
        lastOutputNotificationUptime = now
        onOutput?()
    }
}

/// AppKit-backed drag surface for a floating window's header. Unlike a
/// SwiftUI DragGesture, it opts out of window-background dragging and keeps
/// receiving events inside the main window's transparent titlebar strip, so
/// floating windows can be grabbed all the way at the top of the workspace.
final class RelayPanelDragNSView: NSView {
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGSize) -> Void)?
    var onDragEnded: ((CGSize) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var startLocation: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startLocation = nil
            onDoubleClick?()
            return
        }
        startLocation = event.locationInWindow
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startLocation else { return }
        onDragMoved?(translation(from: start, to: event.locationInWindow))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startLocation else { return }
        startLocation = nil
        onDragEnded?(translation(from: start, to: event.locationInWindow))
    }

    /// AppKit window coordinates are y-up; SwiftUI frames are y-down.
    private func translation(from start: NSPoint, to now: NSPoint) -> CGSize {
        CGSize(width: now.x - start.x, height: start.y - now.y)
    }
}

struct RelayPanelDragArea: NSViewRepresentable {
    let onBegan: () -> Void
    let onMoved: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> RelayPanelDragNSView {
        RelayPanelDragNSView()
    }

    func updateNSView(_ nsView: RelayPanelDragNSView, context: Context) {
        nsView.onDragBegan = onBegan
        nsView.onDragMoved = onMoved
        nsView.onDragEnded = onEnded
        nsView.onDoubleClick = onDoubleClick
    }
}

@MainActor
final class RelayTerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let agentID: String
    let agentName: String
    let accent: SwiftUI.Color
    let cwd: String
    private let spec: RelayTerminalLauncher.Spec

    @Published private(set) var exited = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var windowTitle = ""
    @Published private(set) var generation = 0
    @Published private(set) var lastOutputAt: Date?
    @Published private(set) var editInputRevision = 0
    @Published private(set) var returnInputRevision = 0

    var onFocus: (() -> Void)?
    var onOutputRecorded: ((Date) -> Void)?
    var onReset: (() -> Void)?
    private(set) var terminalView: RelayTerminalNSView

    init(agent: RelayAgent, cwd: String, spec: RelayTerminalLauncher.Spec) {
        self.agentID = agent.id
        self.agentName = agent.name
        self.accent = agent.accent
        self.cwd = RelayTerminalLauncher.resolvedWorkingDirectory(cwd)
        self.spec = spec
        self.terminalView = Self.makeTerminalView()
        attachAndStart()
    }

    private static func makeTerminalView() -> RelayTerminalNSView {
        let view = RelayTerminalNSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        // BISECT-MARKER
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0.051, green: 0.051, blue: 0.055, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 0.92, green: 0.92, blue: 0.93, alpha: 1)
        return view
    }

    private func attachAndStart() {
        terminalView.processDelegate = self
        terminalView.onFocusChange = { [weak self] in
            self?.onFocus?()
        }
        terminalView.onOutput = { [weak self] in
            Task { @MainActor in
                self?.recordOutput()
            }
        }
        terminalView.onUserInput = { [weak self] signal in
            Task { @MainActor in
                self?.recordUserInput(signal)
            }
        }
        terminalView.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", RelayTerminalLauncher.shellCommand(spec)],
            environment: RelayTerminalLauncher.environment(),
            execName: nil,
            currentDirectory: cwd
        )
    }

    func restart() {
        guard exited else { return }
        onReset?()
        terminalView.processDelegate = nil
        terminalView.onFocusChange = nil
        terminalView.onOutput = nil
        terminalView.onUserInput = nil
        terminalView = Self.makeTerminalView()
        exited = false
        exitCode = nil
        lastOutputAt = nil
        editInputRevision = 0
        returnInputRevision = 0
        generation += 1
        attachAndStart()
    }

    func recordOutput(at date: Date = Date()) {
        guard !exited else { return }
        lastOutputAt = date
        onOutputRecorded?(date)
    }

    func isReceivingOutput(at date: Date) -> Bool {
        !exited && RelayTerminalActivity.isActive(lastOutputAt: lastOutputAt, now: date)
    }

    var inputSnapshot: RelayTerminalInputSnapshot {
        RelayTerminalInputSnapshot(
            generation: generation,
            editRevision: editInputRevision,
            returnRevision: returnInputRevision
        )
    }

    func recordUserInput(_ signal: RelayTerminalInputSignal) {
        guard !exited else { return }
        switch signal {
        case .edited:
            editInputRevision += 1
        case .returnKey:
            returnInputRevision += 1
        }
    }

    var isPromptStagingReady: Bool {
        !exited && terminalView.getTerminal().bracketedPasteMode
    }

    @discardableResult
    func stagePrompt(_ text: String) -> Bool {
        guard isPromptStagingReady,
              let payload = RelayPromptStaging.payload(text) else { return false }
        terminalView.sendProgrammatically(data: payload[...])
        return true
    }

    func captureContext() -> String? {
        guard !exited else { return nil }
        let terminal = terminalView.getTerminal()
        let firstVisibleRow = max(terminal.buffer.yDisp, 0)
        let visibleText = terminal.getText(
            start: Position(col: 0, row: firstVisibleRow),
            end: Position(
                col: max(terminal.cols, 1),
                row: firstVisibleRow + max(terminal.rows, 1)
            )
        )
        return RelayTerminalContextRelay.capture(Data(visibleText.utf8))
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
        onFocus?()
    }

    func shutdown() {
        terminalView.processDelegate = nil
        terminalView.onFocusChange = nil
        terminalView.onOutput = nil
        terminalView.onUserInput = nil
        onFocus = nil
        onOutputRecorded = nil
        onReset = nil
        if !exited {
            terminalView.terminate()
        }
    }
}

extension RelayTerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(
        source: LocalProcessTerminalView, newCols: Int, newRows: Int
    ) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in
            self.windowTitle = title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.exited = true
            self.exitCode = exitCode
        }
    }
}

/// A window in the workspace: an embedded CLI terminal, an agent dialogue,
/// a parallel compare, or a sequential chain.
enum RelayWorkspaceItem: Identifiable {
    case terminal(RelayTerminalSession)
    case dialogue(RelayDialogueRun)
    case compare(RelayCompareRun)
    case chain(RelayChainRun)
    case approvals(RelayApprovalPanel)

    var id: UUID {
        switch self {
        case .terminal(let session): session.id
        case .dialogue(let run): run.id
        case .compare(let run): run.id
        case .chain(let run): run.id
        case .approvals(let panel): panel.id
        }
    }
}

struct RelayDecisionActionRecoveryPlan: Equatable {
    let payload: String
    let decisionBriefOriginalBytes: Int
    let decisionBriefRetainedBytes: Int
    let decisionBriefTruncated: Bool
    let visibleScreenOriginalBytes: Int
    let visibleScreenRetainedBytes: Int
    let visibleScreenTruncated: Bool

    var payloadBytes: Int { payload.utf8.count }
}

enum RelayDecisionActionRecovery {
    private static let decisionTruncationMarker =
        "… [earlier filled decision brief truncated]\n"
    private static let screenTruncationMarker =
        "… [earlier frozen screen truncated]\n"

    static func plan(
        receipt: RelayDecisionActionReceipt,
        instruction: String
    ) -> RelayDecisionActionRecoveryPlan? {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstruction: String?
        if trimmedInstruction.isEmpty {
            normalizedInstruction = nil
        } else {
            guard let sanitized = RelayPromptStaging.sanitized(instruction) else { return nil }
            normalizedInstruction = sanitized
        }
        guard let agentName = label(receipt.targetAgentName),
              let projectName = label(receipt.targetProjectName),
              let decisionBrief = RelayPromptStaging.sanitized(receipt.briefPayload),
              let visibleScreen = RelayPromptStaging.sanitized(receipt.visibleScreen) else {
            return nil
        }

        let metadata = [
            "[Relay action recovery brief · frozen local receipt]",
            "Checkpoint: \(receipt.checkpointID.uuidString)",
            "Receipt: \(receipt.id.uuidString)",
            "Captured: \(receipt.capturedAt.ISO8601Format())",
            "Original target: \(agentName) · \(projectName)",
            "User Return: detected; Relay did not send it",
            "Evidence note: the frozen screen is not proof of completion or success",
        ].joined(separator: "\n")
        let prefix = [normalizedInstruction, metadata]
            .compactMap { $0 }
            .joined(separator: "\n\n") + "\n\n"
        let decisionHeader = "[Exact filled decision brief]\n"
        let screenHeader = "\n\n[Frozen visible screen]\n"
        let fixedBytes = prefix.utf8.count + decisionHeader.utf8.count + screenHeader.utf8.count
        let availableBytes = RelayPromptStaging.maxBytes - fixedBytes
        guard availableBytes > 0 else { return nil }

        let decisionBytes = Data(decisionBrief.utf8)
        let screenBytes = Data(visibleScreen.utf8)
        var decisionBudget = min(decisionBytes.count, availableBytes / 2)
        var screenBudget = min(screenBytes.count, availableBytes - decisionBudget)
        var unusedBytes = availableBytes - decisionBudget - screenBudget
        if unusedBytes > 0, decisionBudget < decisionBytes.count {
            let additional = min(unusedBytes, decisionBytes.count - decisionBudget)
            decisionBudget += additional
            unusedBytes -= additional
        }
        if unusedBytes > 0, screenBudget < screenBytes.count {
            screenBudget += min(unusedBytes, screenBytes.count - screenBudget)
        }
        guard let limitedDecision = limitedTail(
            decisionBytes,
            maxBytes: decisionBudget,
            marker: decisionTruncationMarker
        ), let limitedScreen = limitedTail(
            screenBytes,
            maxBytes: screenBudget,
            marker: screenTruncationMarker
        ), let payload = RelayPromptStaging.sanitized(
            prefix + decisionHeader + limitedDecision.text
                + screenHeader + limitedScreen.text
        ) else {
            return nil
        }

        return RelayDecisionActionRecoveryPlan(
            payload: payload,
            decisionBriefOriginalBytes: decisionBytes.count,
            decisionBriefRetainedBytes: limitedDecision.retainedBytes,
            decisionBriefTruncated: limitedDecision.truncated,
            visibleScreenOriginalBytes: screenBytes.count,
            visibleScreenRetainedBytes: limitedScreen.retainedBytes,
            visibleScreenTruncated: limitedScreen.truncated
        )
    }

    private static func label(_ text: String) -> String? {
        RelayPromptStaging.sanitized(text)?
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func limitedTail(
        _ bytes: Data,
        maxBytes: Int,
        marker: String
    ) -> (text: String, retainedBytes: Int, truncated: Bool)? {
        guard bytes.count > maxBytes else {
            return (String(decoding: bytes, as: UTF8.self), bytes.count, false)
        }
        let markerBytes = Data(marker.utf8)
        guard maxBytes > markerBytes.count else { return nil }
        var start = bytes.count - (maxBytes - markerBytes.count)
        while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 {
            start += 1
        }
        return (
            marker + String(decoding: bytes[start...], as: UTF8.self),
            bytes.count - start,
            true
        )
    }
}

struct RelayDecisionRecoveryHandoffPlan: Equatable {
    let payload: String
    let frozenScreenOriginalBytes: Int
    let frozenScreenRetainedBytes: Int
    let frozenScreenTruncated: Bool
    let recoveryScreenOriginalBytes: Int
    let recoveryScreenRetainedBytes: Int
    let recoveryScreenTruncated: Bool
    let addedCount: Int
    let removedCount: Int
    let unchangedCount: Int

    var payloadBytes: Int { payload.utf8.count }
}

struct RelayDecisionRecoveryWitnessDraft: Equatable {
    let id: UUID
    let checkpointID: UUID
    let actionReceiptID: UUID
    let recoveryObservationID: UUID
    let capturedAt: Date
    let handoffPayload: String
    let frozenScreenOriginalBytes: Int
    let frozenScreenRetainedBytes: Int
    let frozenScreenTruncated: Bool
    let recoveryScreenOriginalBytes: Int
    let recoveryScreenRetainedBytes: Int
    let recoveryScreenTruncated: Bool
    let addedCount: Int
    let removedCount: Int
    let unchangedCount: Int
    let targetID: UUID
    let targetAgentName: String
    let targetProjectName: String
    let editedAfterFill: Bool
    let returnDetected: Bool
    let visibleScreen: String

    var handoffPayloadBytes: Int { handoffPayload.utf8.count }
    var visibleScreenBytes: Int { visibleScreen.utf8.count }

    func witness(
        assessment: RelayDecisionRecoveryWitnessAssessment
    ) -> RelayDecisionRecoveryWitness {
        RelayDecisionRecoveryWitness(
            id: id,
            checkpointID: checkpointID,
            actionReceiptID: actionReceiptID,
            recoveryObservationID: recoveryObservationID,
            capturedAt: capturedAt,
            handoffPayload: handoffPayload,
            frozenScreenOriginalBytes: frozenScreenOriginalBytes,
            frozenScreenRetainedBytes: frozenScreenRetainedBytes,
            frozenScreenTruncated: frozenScreenTruncated,
            recoveryScreenOriginalBytes: recoveryScreenOriginalBytes,
            recoveryScreenRetainedBytes: recoveryScreenRetainedBytes,
            recoveryScreenTruncated: recoveryScreenTruncated,
            addedCount: addedCount,
            removedCount: removedCount,
            unchangedCount: unchangedCount,
            targetID: targetID,
            targetAgentName: targetAgentName,
            targetProjectName: targetProjectName,
            editedAfterFill: editedAfterFill,
            returnDetected: returnDetected,
            assessment: assessment,
            visibleScreen: visibleScreen
        )
    }
}

struct RelayDecisionRecoveryWitnessComparison: Equatable {
    let left: RelayDecisionRecoveryWitness
    let right: RelayDecisionRecoveryWitness
    let screenDelta: RelayDecisionDelta

    var handoffPayloadsMatch: Bool {
        left.handoffPayload == right.handoffPayload
    }

    var assessmentsMatch: Bool {
        left.assessment == right.assessment
    }

    init?(
        left: RelayDecisionRecoveryWitness,
        right: RelayDecisionRecoveryWitness
    ) {
        guard left.id != right.id,
              left.checkpointID == right.checkpointID,
              left.actionReceiptID == right.actionReceiptID,
              left.recoveryObservationID == right.recoveryObservationID else {
            return nil
        }
        self.left = left
        self.right = right
        screenDelta = RelayDecisionDelta(
            parent: left.visibleScreen,
            derived: right.visibleScreen
        )
    }
}

enum RelayDecisionRecoveryHandoff {
    private static let frozenTruncationMarker =
        "… [earlier frozen receipt screen truncated]\n"
    private static let recoveryTruncationMarker =
        "… [earlier recovery screen truncated]\n"

    static func plan(
        receipt: RelayDecisionActionReceipt,
        observation: RelayDecisionRecoveryObservation,
        instruction: String
    ) -> RelayDecisionRecoveryHandoffPlan? {
        guard observation.checkpointID == receipt.checkpointID,
              observation.actionReceiptID == receipt.id else { return nil }
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedInstruction: String?
        if trimmedInstruction.isEmpty {
            normalizedInstruction = nil
        } else {
            guard let sanitized = RelayPromptStaging.sanitized(instruction) else { return nil }
            normalizedInstruction = sanitized
        }
        guard let agentName = label(observation.targetAgentName),
              let projectName = label(observation.targetProjectName),
              let frozenScreen = RelayPromptStaging.sanitized(receipt.visibleScreen),
              let recoveryScreen = RelayPromptStaging.sanitized(observation.visibleScreen) else {
            return nil
        }

        let delta = RelayDecisionDelta(parent: frozenScreen, derived: recoveryScreen)
        let metadata = [
            "[Relay recovery change handoff · private local evidence]",
            "Checkpoint: \(observation.checkpointID.uuidString)",
            "Action receipt: \(observation.actionReceiptID.uuidString)",
            "Recovery observation: \(observation.id.uuidString)",
            "Captured: \(observation.capturedAt.ISO8601Format())",
            "Recovery target: \(agentName) · \(projectName)",
            "User Return: detected; Relay did not send it",
            "Edited after fill: \(observation.editedAfterFill ? "yes" : "no")",
            "Visible screen change: +\(delta.addedCount) added; −\(delta.removedCount) removed; =\(delta.unchangedCount) unchanged",
            "Evidence note: visible screen change is not proof of completion or success",
        ].joined(separator: "\n")
        let prefix = [normalizedInstruction, metadata]
            .compactMap { $0 }
            .joined(separator: "\n\n") + "\n\n"
        let frozenHeader = "[Frozen action receipt screen]\n"
        let recoveryHeader = "\n\n[Recovery screen]\n"
        let fixedBytes = prefix.utf8.count + frozenHeader.utf8.count
            + recoveryHeader.utf8.count
        let availableBytes = RelayPromptStaging.maxBytes - fixedBytes
        guard availableBytes > 0 else { return nil }

        let frozenBytes = Data(frozenScreen.utf8)
        let recoveryBytes = Data(recoveryScreen.utf8)
        var frozenBudget = min(frozenBytes.count, availableBytes / 2)
        var recoveryBudget = min(recoveryBytes.count, availableBytes - frozenBudget)
        var unusedBytes = availableBytes - frozenBudget - recoveryBudget
        if unusedBytes > 0, frozenBudget < frozenBytes.count {
            let additional = min(unusedBytes, frozenBytes.count - frozenBudget)
            frozenBudget += additional
            unusedBytes -= additional
        }
        if unusedBytes > 0, recoveryBudget < recoveryBytes.count {
            recoveryBudget += min(unusedBytes, recoveryBytes.count - recoveryBudget)
        }
        guard let limitedFrozen = limitedTail(
            frozenBytes,
            maxBytes: frozenBudget,
            marker: frozenTruncationMarker
        ), let limitedRecovery = limitedTail(
            recoveryBytes,
            maxBytes: recoveryBudget,
            marker: recoveryTruncationMarker
        ), let payload = RelayPromptStaging.sanitized(
            prefix + frozenHeader + limitedFrozen.text
                + recoveryHeader + limitedRecovery.text
        ) else {
            return nil
        }

        return RelayDecisionRecoveryHandoffPlan(
            payload: payload,
            frozenScreenOriginalBytes: frozenBytes.count,
            frozenScreenRetainedBytes: limitedFrozen.retainedBytes,
            frozenScreenTruncated: limitedFrozen.truncated,
            recoveryScreenOriginalBytes: recoveryBytes.count,
            recoveryScreenRetainedBytes: limitedRecovery.retainedBytes,
            recoveryScreenTruncated: limitedRecovery.truncated,
            addedCount: delta.addedCount,
            removedCount: delta.removedCount,
            unchangedCount: delta.unchangedCount
        )
    }

    private static func label(_ text: String) -> String? {
        RelayPromptStaging.sanitized(text)?
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func limitedTail(
        _ bytes: Data,
        maxBytes: Int,
        marker: String
    ) -> (text: String, retainedBytes: Int, truncated: Bool)? {
        guard bytes.count > maxBytes else {
            return (String(decoding: bytes, as: UTF8.self), bytes.count, false)
        }
        let markerBytes = Data(marker.utf8)
        guard maxBytes > markerBytes.count else { return nil }
        var start = bytes.count - (maxBytes - markerBytes.count)
        while start < bytes.endIndex, bytes[start] & 0xC0 == 0x80 {
            start += 1
        }
        return (
            marker + String(decoding: bytes[start...], as: UTF8.self),
            bytes.count - start,
            true
        )
    }
}

@MainActor
final class RelayTerminalStore: ObservableObject {
    static let maxDialogues = 2
    static let maxCompares = 2
    static let maxChains = 2

    @Published private(set) var sessions: [RelayTerminalSession] = []
    @Published private(set) var dialogues: [RelayDialogueRun] = []
    @Published private(set) var compares: [RelayCompareRun] = []
    @Published private(set) var chains: [RelayChainRun] = []
    @Published private(set) var approvalPanel: RelayApprovalPanel?
    /// Window frames in workspace coordinates, one per window.
    @Published private(set) var windowFrames: [UUID: CGRect] = [:]
    /// Stacking order, back to front (last is topmost).
    @Published private(set) var zOrder: [UUID] = []
    @Published private(set) var focusedID: UUID?
    /// One sticky timestamp per terminal whose output has not been viewed yet.
    @Published private(set) var pendingOutputDates: [UUID: Date] = [:]
    @Published private(set) var promptStagingVisible = false
    @Published private(set) var promptReviewPlan: RelayPromptReviewPlan?
    @Published private(set) var attentionReturnTicket: RelayTerminalReturnTicket?
    @Published private(set) var attentionRoutePulse: RelayAttentionRoutePulse?
    @Published private(set) var contextRelayDraft: RelayContextRelayDraft?
    @Published private(set) var resultConfluence: RelayResultConfluence?
    @Published private(set) var resultArbitrationReceipt: RelayResultArbitrationReceipt?
    @Published private(set) var resultArbitrationDecision: RelayResultArbitrationDecision?
    @Published private(set) var resultArbitrationDecisionVisible = false
    @Published private(set) var savedDecisionCheckpoints: [RelayDecisionCheckpoint] = []
    @Published private(set) var decisionArchiveRejectedCount = 0
    @Published private(set) var decisionAnnotations: [UUID: RelayDecisionAnnotation] = [:]
    @Published private(set) var decisionAnnotationRejectedCount = 0
    @Published private(set) var savedDecisionActionReceipts: [RelayDecisionActionReceipt] = []
    @Published private(set) var decisionActionReceiptRejectedCount = 0
    @Published private(set) var savedDecisionRecoveryObservations: [RelayDecisionRecoveryObservation] = []
    @Published private(set) var decisionRecoveryObservationRejectedCount = 0
    @Published private(set) var savedDecisionRecoveryWitnesses: [RelayDecisionRecoveryWitness] = []
    @Published private(set) var decisionRecoveryWitnessRejectedCount = 0
    @Published private(set) var decisionLibraryVisible = false
    @Published var decisionLibraryQuery = ""
    @Published private(set) var selectedDecisionCheckpoint: RelayDecisionCheckpoint?
    @Published private(set) var liveDecisionCheckpointID: UUID?
    @Published private(set) var resultConfluenceReplayCheckpoint: RelayDecisionCheckpoint?
    @Published private(set) var decisionBriefCheckpoint: RelayDecisionCheckpoint?
    @Published private(set) var decisionBriefPlan: RelayDecisionBriefPlan?
    @Published private(set) var decisionActionReceiptDraft: RelayDecisionActionReceipt?
    @Published private(set) var selectedDecisionActionReceipt: RelayDecisionActionReceipt?
    @Published private(set) var decisionActionReceiptVisible = false
    @Published private(set) var decisionActionRecoveryReceipt: RelayDecisionActionReceipt?
    @Published private(set) var decisionActionRecoveryPlan: RelayDecisionActionRecoveryPlan?
    @Published private(set) var decisionRecoveryObservationDraft: RelayDecisionRecoveryObservation?
    @Published private(set) var selectedDecisionRecoveryObservation: RelayDecisionRecoveryObservation?
    @Published private(set) var decisionRecoveryObservationVisible = false
    @Published private(set) var decisionRecoveryHandoffReceipt: RelayDecisionActionReceipt?
    @Published private(set) var decisionRecoveryHandoffObservation: RelayDecisionRecoveryObservation?
    @Published private(set) var decisionRecoveryHandoffPlan: RelayDecisionRecoveryHandoffPlan?
    @Published private(set) var decisionRecoveryWitnessDraft: RelayDecisionRecoveryWitnessDraft?
    @Published private(set) var decisionRecoveryWitnessAssessment: RelayDecisionRecoveryWitnessAssessment?
    @Published private(set) var selectedDecisionRecoveryWitness: RelayDecisionRecoveryWitness?
    @Published private(set) var decisionRecoveryWitnessVisible = false
    /// Localization key for a transient sidebar notice.
    @Published private(set) var noticeKey: String?
    @Published private(set) var restorableDesk: RelayDeskSnapshot?
    private var zoomRestore: [UUID: CGRect] = [:]
    private var canvasSize: CGSize = .zero
    private var openSerial = 0
    private let defaults: UserDefaults
    private let decisionArchive: RelayDecisionArchive
    private let isTerminalViewed: @MainActor (RelayTerminalSession) -> Bool
    private var restoringDesk = false
    private var decisionLibraryReturnsToLiveDecision = false

    init(
        defaults: UserDefaults = .standard,
        decisionArchive: RelayDecisionArchive = .live(),
        isTerminalViewed: @escaping @MainActor (RelayTerminalSession) -> Bool = { session in
            guard NSApplication.shared.isActive else { return false }
            return session.terminalView.window?.isKeyWindow == true
        }
    ) {
        self.defaults = defaults
        self.decisionArchive = decisionArchive
        self.isTerminalViewed = isTerminalViewed
        if let data = defaults.data(forKey: RelayDeskSnapshot.defaultsKey),
           let snapshot = try? JSONDecoder().decode(RelayDeskSnapshot.self, from: data),
           !snapshot.terminals.isEmpty {
            restorableDesk = snapshot
        }
        reloadDecisionArchive()
    }

    /// Windows in paint order (back to front).
    var orderedItems: [RelayWorkspaceItem] {
        zOrder.compactMap { id in
            if let session = session(id) {
                return .terminal(session)
            }
            if let run = dialogue(id) {
                return .dialogue(run)
            }
            if let run = compare(id) {
                return .compare(run)
            }
            if let run = chain(id) {
                return .chain(run)
            }
            if let panel = approvalPanel, panel.id == id {
                return .approvals(panel)
            }
            return nil
        }
    }

    var resultConfluenceReplayCheckpointID: UUID? {
        resultConfluenceReplayCheckpoint?.id
    }

    var canBeginDecisionCheckpointReplay: Bool {
        selectedDecisionCheckpoint != nil
            && contextRelayDraft == nil
            && resultConfluence == nil
            && resultArbitrationReceipt == nil
            && resultArbitrationDecision == nil
            && promptReviewPlan == nil
            && !decisionActionReceiptVisible
    }

    var activeDecisionActionReceipt: RelayDecisionActionReceipt? {
        guard decisionActionReceiptVisible else { return nil }
        return selectedDecisionActionReceipt ?? decisionActionReceiptDraft
    }

    var activeDecisionActionReceiptIsSaved: Bool {
        decisionActionReceiptVisible && selectedDecisionActionReceipt != nil
    }

    var activeDecisionRecoveryObservation: RelayDecisionRecoveryObservation? {
        guard decisionRecoveryObservationVisible else { return nil }
        return selectedDecisionRecoveryObservation ?? decisionRecoveryObservationDraft
    }

    var activeDecisionRecoveryObservationIsSaved: Bool {
        decisionRecoveryObservationVisible && selectedDecisionRecoveryObservation != nil
    }

    var activeDecisionRecoveryWitness: RelayDecisionRecoveryWitness? {
        guard decisionRecoveryWitnessVisible else { return nil }
        return selectedDecisionRecoveryWitness
    }

    var activeDecisionRecoveryWitnessDraft: RelayDecisionRecoveryWitnessDraft? {
        guard decisionRecoveryWitnessVisible else { return nil }
        return decisionRecoveryWitnessDraft
    }

    func session(_ id: UUID) -> RelayTerminalSession? {
        sessions.first { $0.id == id }
    }

    func dialogue(_ id: UUID) -> RelayDialogueRun? {
        dialogues.first { $0.id == id }
    }

    func compare(_ id: UUID) -> RelayCompareRun? {
        compares.first { $0.id == id }
    }

    func chain(_ id: UUID) -> RelayChainRun? {
        chains.first { $0.id == id }
    }

    func activeTerminalCount(at date: Date) -> Int {
        sessions.count { $0.isReceivingOutput(at: date) }
    }

    var pendingOutputCount: Int {
        pendingOutputDates.count
    }

    var promptReviewPendingCount: Int {
        guard let promptReviewPlan else { return 0 }
        return promptReviewPlan.pendingCount(availableIDs: Set(
            sessions.filter { !$0.exited }.map(\.id)
        ))
    }

    var attentionPendingCount: Int {
        promptReviewPendingCount + pendingOutputCount
    }

    var attentionReturnSession: RelayTerminalSession? {
        guard let id = attentionReturnTicket?.sessionID,
              let session = session(id), !session.exited else { return nil }
        return session
    }

    func nextAttention(at date: Date = Date()) -> RelayTerminalAttention? {
        let availableIDs = Set(sessions.filter { !$0.exited }.map(\.id))
        if let promptReviewPlan,
           let id = promptReviewPlan.nextPendingID(availableIDs: availableIDs) {
            return RelayTerminalAttention(
                kind: .promptReview,
                sessionID: id,
                count: attentionPendingCount
            )
        }
        if let id = pendingOutputDates
            .filter({ availableIDs.contains($0.key) })
            .min(by: { $0.value < $1.value })?
            .key {
            return RelayTerminalAttention(
                kind: .pendingOutput,
                sessionID: id,
                count: pendingOutputCount
            )
        }
        guard let session = sessions
            .filter({ $0.isReceivingOutput(at: date) })
            .max(by: { ($0.lastOutputAt ?? .distantPast) < ($1.lastOutputAt ?? .distantPast) })
        else { return nil }
        return RelayTerminalAttention(
            kind: .activeOutput,
            sessionID: session.id,
            count: activeTerminalCount(at: date)
        )
    }

    @discardableResult
    func focusNextAttention(at date: Date = Date()) -> RelayTerminalAttention? {
        guard let attention = nextAttention(at: date),
              let session = session(attention.sessionID) else { return nil }
        let openedPromptStaging = attention.kind == .promptReview && !promptStagingVisible
        if let focusedID,
           focusedID != attention.sessionID,
           let source = self.session(focusedID), !source.exited {
            attentionReturnTicket = RelayTerminalReturnTicket(
                sessionID: source.id,
                closesPromptStaging: openedPromptStaging
            )
            publishAttentionRoutePulse(from: source.id, to: attention.sessionID)
        } else if focusedID != attention.sessionID {
            attentionReturnTicket = nil
        }
        if attention.kind == .promptReview, var plan = promptReviewPlan {
            let availableIDs = Set(sessions.filter { !$0.exited }.map(\.id))
            guard plan.selectNextPending(availableIDs: availableIDs) != nil else { return nil }
            promptReviewPlan = plan
            promptStagingVisible = true
        }
        session.focus()
        return attention
    }

    @discardableResult
    func returnFromAttention() -> UUID? {
        guard let ticket = attentionReturnTicket,
              let session = session(ticket.sessionID), !session.exited else {
            attentionReturnTicket = nil
            return nil
        }
        attentionReturnTicket = nil
        if ticket.closesPromptStaging {
            promptStagingVisible = false
        }
        if let focusedID,
           focusedID != session.id,
           self.session(focusedID) != nil {
            publishAttentionRoutePulse(from: focusedID, to: session.id)
        }
        session.focus()
        return session.id
    }

    func dismissAttentionRoutePulse(_ id: UUID) {
        guard attentionRoutePulse?.id == id else { return }
        attentionRoutePulse = nil
    }

    private func publishAttentionRoutePulse(from sourceID: UUID, to targetID: UUID) {
        let pulse = RelayAttentionRoutePulse(sourceID: sourceID, targetID: targetID)
        attentionRoutePulse = pulse
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            self?.dismissAttentionRoutePulse(pulse.id)
        }
    }

    func needsOutputReview(_ id: UUID) -> Bool {
        pendingOutputDates[id] != nil
    }

    @discardableResult
    func focusLatestOutput(at date: Date = Date()) -> UUID? {
        guard let session = sessions
            .filter({ $0.isReceivingOutput(at: date) })
            .max(by: { ($0.lastOutputAt ?? .distantPast) < ($1.lastOutputAt ?? .distantPast) })
        else { return nil }
        session.focus()
        return session.id
    }

    @discardableResult
    func focusNextPendingOutput() -> UUID? {
        guard let id = pendingOutputDates
            .filter({ self.session($0.key) != nil })
            .min(by: { $0.value < $1.value })?
            .key,
            let session = session(id)
        else { return nil }
        session.focus()
        return id
    }

    func markFocusedOutputReviewed() {
        guard let focusedID,
              let session = session(focusedID),
              isTerminalViewed(session) else { return }
        pendingOutputDates.removeValue(forKey: focusedID)
    }

    func togglePromptStaging() {
        guard contextRelayDraft == nil, resultConfluence == nil else { return }
        promptStagingVisible.toggle()
    }

    func closePromptStaging() {
        promptStagingVisible = false
    }

    func beginPromptReview(_ plan: RelayPromptReviewPlan) {
        decisionBriefCheckpoint = nil
        decisionBriefPlan = nil
        decisionActionReceiptDraft = nil
        selectedDecisionActionReceipt = nil
        decisionActionReceiptVisible = false
        decisionActionRecoveryReceipt = nil
        decisionActionRecoveryPlan = nil
        decisionRecoveryObservationDraft = nil
        selectedDecisionRecoveryObservation = nil
        decisionRecoveryObservationVisible = false
        decisionRecoveryHandoffReceipt = nil
        decisionRecoveryHandoffObservation = nil
        decisionRecoveryHandoffPlan = nil
        decisionRecoveryWitnessDraft = nil
        decisionRecoveryWitnessAssessment = nil
        selectedDecisionRecoveryWitness = nil
        decisionRecoveryWitnessVisible = false
        resultConfluence = nil
        resultConfluenceReplayCheckpoint = nil
        resultArbitrationReceipt = nil
        resultArbitrationDecision = nil
        resultArbitrationDecisionVisible = false
        promptReviewPlan = plan
        promptStagingVisible = true
    }

    func updatePromptReview(_ plan: RelayPromptReviewPlan) {
        guard promptReviewPlan != nil else { return }
        promptReviewPlan = plan
    }

    func clearPromptReview() {
        promptReviewPlan = nil
        decisionBriefCheckpoint = nil
        decisionBriefPlan = nil
        decisionActionReceiptDraft = nil
        decisionActionRecoveryReceipt = nil
        decisionActionRecoveryPlan = nil
        decisionRecoveryObservationDraft = nil
        selectedDecisionRecoveryObservation = nil
        decisionRecoveryObservationVisible = false
        decisionRecoveryHandoffReceipt = nil
        decisionRecoveryHandoffObservation = nil
        decisionRecoveryHandoffPlan = nil
        decisionRecoveryWitnessDraft = nil
        decisionRecoveryWitnessAssessment = nil
        selectedDecisionRecoveryWitness = nil
        decisionRecoveryWitnessVisible = false
        if selectedDecisionActionReceipt == nil {
            decisionActionReceiptVisible = false
        }
        if resultConfluence?.id == resultArbitrationReceipt?.confluence.id {
            resultConfluence = nil
        }
        resultArbitrationReceipt = nil
        resultArbitrationDecision = nil
        resultArbitrationDecisionVisible = false
        resultConfluenceReplayCheckpoint = nil
    }

    @discardableResult
    func stagePrompt(_ text: String, to targetIDs: Set<UUID>) -> [UUID] {
        zOrder.compactMap { id in
            guard targetIDs.contains(id),
                  let session = session(id),
                  session.stagePrompt(text) else { return nil }
            return id
        }
    }

    func canBeginContextRelay(from session: RelayTerminalSession) -> Bool {
        !session.exited
            && contextRelayDraft == nil
            && resultConfluence == nil
            && !promptStagingVisible
            && promptReviewPlan == nil
            && sessions.contains { $0.id != session.id && !$0.exited }
    }

    @discardableResult
    func beginContextRelay(from session: RelayTerminalSession) -> Bool {
        guard canBeginContextRelay(from: session) else {
            noticeKey = sessions.contains { $0.id != session.id && !$0.exited }
                ? "Finish the current prompt flow before relaying context."
                : "Open another terminal to receive this context."
            return false
        }
        guard let context = session.captureContext() else {
            noticeKey = "No terminal text to relay."
            return false
        }
        contextRelayDraft = RelayContextRelayDraft(
            sourceID: session.id,
            sourceAgentName: session.agentName,
            projectName: RelayTerminalContext.projectName(session.cwd),
            context: context
        )
        noticeKey = nil
        activate(session.id)
        return true
    }

    func cancelContextRelay() {
        contextRelayDraft = nil
    }

    @discardableResult
    func completeContextRelay(
        instruction: String,
        context: String,
        targetIDs: Set<UUID>
    ) -> Bool {
        guard let draft = contextRelayDraft,
              let payload = RelayTerminalContextRelay.payload(
                  instruction: instruction,
                  context: context,
                  sourceAgent: draft.sourceAgentName,
                  projectName: draft.projectName
              ) else { return false }
        let eligibleIDs = targetIDs.subtracting([draft.sourceID])
        let baselinePairs: [(UUID, RelayTerminalInputSnapshot)] = sessions.compactMap { target in
            guard eligibleIDs.contains(target.id), !target.exited else { return nil }
            return (target.id, target.inputSnapshot)
        }
        let baselines = Dictionary(uniqueKeysWithValues: baselinePairs)
        let stagedIDs = stagePrompt(payload, to: eligibleIDs)
        let targets = stagedIDs.compactMap { id -> RelayPromptReviewTarget? in
            guard let target = session(id), let baseline = baselines[id] else { return nil }
            return RelayPromptReviewTarget(
                id: target.id,
                agentName: target.agentName,
                projectName: RelayTerminalContext.projectName(target.cwd),
                inputBaseline: baseline
            )
        }
        guard let firstTarget = targets.first,
              let firstSession = session(firstTarget.id) else { return false }

        contextRelayDraft = nil
        beginPromptReview(RelayPromptReviewPlan(targets: targets))
        if let source = session(draft.sourceID), !source.exited {
            attentionReturnTicket = RelayTerminalReturnTicket(
                sessionID: source.id,
                closesPromptStaging: true
            )
            publishAttentionRoutePulse(from: source.id, to: firstSession.id)
        }
        firstSession.focus()
        return true
    }

    @discardableResult
    func captureResultConfluence(from plan: RelayPromptReviewPlan) -> Bool {
        guard promptReviewPlan == plan, plan.isComplete() else {
            noticeKey = "Finish checking every target before collecting screens."
            return false
        }
        let snapshots = resultSnapshots(for: plan.targets.map(\.id))
        guard snapshots.count >= 2 else {
            noticeKey = "Keep at least two reviewed terminals open to collect screens."
            return false
        }
        resultConfluence = RelayResultConfluence(snapshots: snapshots)
        resultConfluenceReplayCheckpoint = nil
        promptStagingVisible = false
        noticeKey = nil
        return true
    }

    @discardableResult
    func refreshResultConfluence() -> Bool {
        guard resultConfluenceReplayCheckpoint == nil else {
            noticeKey = "Saved checkpoint sources cannot be recaptured."
            return false
        }
        guard let resultConfluence else { return false }
        let snapshots = resultSnapshots(for: resultConfluence.snapshots.map(\.id))
        guard snapshots.count == resultConfluence.snapshots.count,
              snapshots.count >= 2 else {
            noticeKey = "Keep every collected terminal open to recapture screens."
            return false
        }
        self.resultConfluence = RelayResultConfluence(snapshots: snapshots)
        noticeKey = nil
        return true
    }

    @discardableResult
    func focusResultSnapshot(_ id: UUID) -> UUID? {
        guard resultConfluence?.snapshots.contains(where: { $0.id == id }) == true,
              let target = session(id), !target.exited else { return nil }
        if let focusedID, focusedID != id, session(focusedID) != nil {
            publishAttentionRoutePulse(from: focusedID, to: id)
        }
        target.focus()
        return id
    }

    func returnFromResultConfluence() {
        resultConfluence = nil
        if let checkpoint = resultConfluenceReplayCheckpoint {
            selectedDecisionCheckpoint = checkpoint
            resultConfluenceReplayCheckpoint = nil
            decisionLibraryVisible = false
            noticeKey = nil
            return
        }
        if promptReviewPlan != nil {
            promptStagingVisible = true
        }
    }

    @discardableResult
    func showResultArbitrationSources() -> Bool {
        guard let receipt = resultArbitrationReceipt,
              promptReviewPlan?.targets.map(\.id) == [receipt.targetID] else { return false }
        resultConfluence = receipt.confluence
        resultConfluenceReplayCheckpoint = nil
        resultArbitrationDecisionVisible = false
        promptStagingVisible = false
        return true
    }

    @discardableResult
    func captureResultArbitrationDecision() -> Bool {
        guard resultArbitrationDecision == nil else { return false }
        guard let receipt = resultArbitrationReceipt,
              let plan = promptReviewPlan,
              plan.targets.map(\.id) == [receipt.targetID],
              plan.isComplete() else {
            noticeKey = "Finish checking the arbiter before sealing its result."
            return false
        }
        guard let result = resultSnapshots(for: [receipt.targetID]).first else {
            noticeKey = "Keep the reviewed arbiter open to seal its result."
            return false
        }
        resultArbitrationDecision = RelayResultArbitrationDecision(
            receipt: receipt,
            result: result
        )
        resultArbitrationDecisionVisible = true
        promptStagingVisible = false
        noticeKey = nil
        return true
    }

    @discardableResult
    func showResultArbitrationDecision() -> Bool {
        guard resultArbitrationDecision != nil else { return false }
        resultConfluence = nil
        resultArbitrationDecisionVisible = true
        promptStagingVisible = false
        return true
    }

    func returnFromResultArbitrationDecision() {
        resultArbitrationDecisionVisible = false
        if promptReviewPlan != nil {
            promptStagingVisible = true
        }
    }

    @discardableResult
    func saveResultArbitrationDecision() -> Bool {
        guard let decision = resultArbitrationDecision else { return false }
        if let existing = savedDecisionCheckpoints.first(where: {
            $0.decision.id == decision.id
        }) {
            liveDecisionCheckpointID = existing.id
            return true
        }
        do {
            let checkpoint = try decisionArchive.save(decision)
            liveDecisionCheckpointID = checkpoint.id
            reloadDecisionArchive()
            noticeKey = "Decision checkpoint saved locally."
            return true
        } catch {
            noticeKey = "Could not save the decision checkpoint."
            return false
        }
    }

    func showDecisionLibrary(returningToLiveDecision: Bool = false) {
        decisionLibraryReturnsToLiveDecision = returningToLiveDecision
        selectedDecisionCheckpoint = nil
        decisionLibraryVisible = true
        resultArbitrationDecisionVisible = false
        promptStagingVisible = false
    }

    func closeDecisionLibrary() {
        selectedDecisionCheckpoint = nil
        decisionLibraryVisible = false
        decisionLibraryQuery = ""
        if decisionLibraryReturnsToLiveDecision,
           resultArbitrationDecision != nil {
            resultArbitrationDecisionVisible = true
        }
        decisionLibraryReturnsToLiveDecision = false
    }

    func openDecisionCheckpoint(_ checkpoint: RelayDecisionCheckpoint) {
        guard savedDecisionCheckpoints.contains(where: { $0.id == checkpoint.id }) else {
            return
        }
        resultConfluenceReplayCheckpoint = nil
        selectedDecisionCheckpoint = checkpoint
        decisionLibraryVisible = false
    }

    @discardableResult
    func beginDecisionCheckpointReplay(_ checkpoint: RelayDecisionCheckpoint) -> Bool {
        guard canBeginDecisionCheckpointReplay,
              selectedDecisionCheckpoint?.id == checkpoint.id,
              savedDecisionCheckpoints.contains(where: { $0.id == checkpoint.id }) else {
            noticeKey = "Finish the current prompt flow before replaying a checkpoint."
            return false
        }
        selectedDecisionCheckpoint = nil
        decisionLibraryVisible = false
        decisionLibraryReturnsToLiveDecision = false
        resultConfluence = checkpoint.decision.receipt.confluence
        resultConfluenceReplayCheckpoint = checkpoint
        promptStagingVisible = false
        noticeKey = nil
        return true
    }

    @discardableResult
    func completeDecisionBrief(
        checkpoint: RelayDecisionCheckpoint,
        instruction: String,
        targetID: UUID
    ) -> Bool {
        guard canBeginDecisionCheckpointReplay,
              selectedDecisionCheckpoint?.id == checkpoint.id,
              savedDecisionCheckpoints.contains(where: { $0.id == checkpoint.id }) else {
            noticeKey = "Finish the current prompt flow before continuing from a decision."
            return false
        }
        guard let briefPlan = RelayDecisionBrief.plan(
            checkpoint: checkpoint,
            annotation: decisionAnnotation(for: checkpoint),
            instruction: instruction
        ) else {
            noticeKey = "The decision brief does not fit the local prompt limit."
            return false
        }
        guard let target = session(targetID), target.isPromptStagingReady else {
            noticeKey = "Confirm one live target is at an input prompt before continuing."
            return false
        }

        let sourceID = focusedID
        let inputBaseline = target.inputSnapshot
        guard target.stagePrompt(briefPlan.payload) else { return false }
        let review = RelayPromptReviewPlan(targets: [
            RelayPromptReviewTarget(
                id: target.id,
                agentName: target.agentName,
                projectName: RelayTerminalContext.projectName(target.cwd),
                inputBaseline: inputBaseline
            ),
        ])
        beginPromptReview(review)
        decisionBriefCheckpoint = checkpoint
        decisionBriefPlan = briefPlan
        selectedDecisionCheckpoint = nil
        decisionLibraryVisible = false
        decisionLibraryReturnsToLiveDecision = false
        attentionReturnTicket = nil
        noticeKey = nil
        if let sourceID, sourceID != target.id,
           let source = session(sourceID), !source.exited {
            publishAttentionRoutePulse(from: source.id, to: target.id)
        }
        target.focus()
        return true
    }

    func canCaptureDecisionActionReceipt() -> Bool {
        guard decisionActionReceiptDraft == nil,
              let plan = promptReviewPlan,
              plan.targets.count == 1,
              let target = plan.targets.first,
              decisionBriefCheckpoint != nil,
              decisionBriefPlan != nil,
              let session = session(target.id),
              !session.exited else {
            return false
        }
        return RelayPromptTargetSignal.resolve(
            baseline: target.inputBaseline,
            current: session.inputSnapshot
        ) == .returnDetected
    }

    @discardableResult
    func captureDecisionActionReceipt(capturedAt: Date = Date()) -> Bool {
        guard canCaptureDecisionActionReceipt() else {
            noticeKey = "Return must be detected before capturing an action receipt."
            return false
        }
        guard let checkpoint = decisionBriefCheckpoint,
              let brief = decisionBriefPlan,
              let target = promptReviewPlan?.targets.first,
              let session = session(target.id),
              let visibleScreen = session.captureContext() else {
            noticeKey = "Keep the target open with a visible screen before capturing a receipt."
            return false
        }
        let currentInput = session.inputSnapshot
        let receipt = RelayDecisionActionReceipt(
            checkpointID: checkpoint.id,
            capturedAt: capturedAt,
            briefPayload: brief.payload,
            decisionOriginalBytes: brief.decisionOriginalBytes,
            decisionRetainedBytes: brief.decisionRetainedBytes,
            decisionTruncated: brief.decisionTruncated,
            targetID: target.id,
            targetAgentName: target.agentName,
            targetProjectName: target.projectName,
            editedAfterFill: currentInput.editRevision > target.inputBaseline.editRevision,
            returnDetected: true,
            visibleScreen: visibleScreen
        )
        decisionActionReceiptDraft = receipt
        selectedDecisionActionReceipt = nil
        decisionActionReceiptVisible = true
        promptStagingVisible = false
        noticeKey = nil
        return true
    }

    func showDecisionActionReceiptDraft() {
        guard decisionActionReceiptDraft != nil else { return }
        selectedDecisionActionReceipt = nil
        decisionActionReceiptVisible = true
        promptStagingVisible = false
    }

    @discardableResult
    func saveDecisionActionReceipt() -> Bool {
        guard let receipt = decisionActionReceiptDraft else { return false }
        do {
            let saved = try decisionArchive.saveActionReceipt(receipt)
            reloadDecisionArchive()
            decisionActionReceiptDraft = nil
            selectedDecisionActionReceipt = savedDecisionActionReceipts.first {
                $0.id == saved.id
            } ?? saved
            decisionActionReceiptVisible = true
            noticeKey = "Action receipt saved locally."
            return true
        } catch {
            noticeKey = "Could not save the action receipt."
            return false
        }
    }

    func decisionActionReceipts(
        for checkpoint: RelayDecisionCheckpoint
    ) -> [RelayDecisionActionReceipt] {
        savedDecisionActionReceipts.filter { $0.checkpointID == checkpoint.id }
    }

    func openDecisionActionReceipt(_ receipt: RelayDecisionActionReceipt) {
        guard savedDecisionActionReceipts.contains(where: { $0.id == receipt.id }),
              savedDecisionCheckpoints.contains(where: { $0.id == receipt.checkpointID }) else {
            return
        }
        selectedDecisionCheckpoint = nil
        selectedDecisionActionReceipt = receipt
        decisionActionReceiptVisible = true
        selectedDecisionRecoveryObservation = nil
        decisionRecoveryObservationVisible = false
        decisionRecoveryHandoffReceipt = nil
        decisionRecoveryHandoffObservation = nil
        decisionRecoveryHandoffPlan = nil
        decisionLibraryVisible = false
        promptStagingVisible = false
    }

    func returnFromDecisionActionReceipt(discardingDraft: Bool = false) {
        let receipt = activeDecisionActionReceipt
        let wasSaved = selectedDecisionActionReceipt != nil
        if discardingDraft {
            decisionActionReceiptDraft = nil
        }
        selectedDecisionActionReceipt = nil
        decisionActionReceiptVisible = false

        if wasSaved || discardingDraft {
            promptReviewPlan = nil
            decisionBriefCheckpoint = nil
            decisionBriefPlan = nil
            attentionReturnTicket = nil
        }

        if !wasSaved,
           !discardingDraft,
           promptReviewPlan != nil,
           receipt.flatMap({ session($0.targetID) })?.exited == false {
            promptStagingVisible = true
            return
        }
        promptStagingVisible = false
        if let checkpointID = receipt?.checkpointID,
           let checkpoint = savedDecisionCheckpoints.first(where: { $0.id == checkpointID }) {
            selectedDecisionCheckpoint = checkpoint
            decisionLibraryVisible = false
        } else {
            decisionLibraryVisible = true
        }
    }

    @discardableResult
    func completeDecisionActionRecovery(
        receipt: RelayDecisionActionReceipt,
        instruction: String,
        targetID: UUID
    ) -> Bool {
        guard decisionActionReceiptVisible,
              selectedDecisionActionReceipt?.id == receipt.id,
              savedDecisionActionReceipts.contains(where: { $0.id == receipt.id }),
              savedDecisionCheckpoints.contains(where: { $0.id == receipt.checkpointID }),
              promptReviewPlan == nil else {
            noticeKey = "Finish the current prompt flow before recovering from a receipt."
            return false
        }
        guard let recoveryPlan = RelayDecisionActionRecovery.plan(
            receipt: receipt,
            instruction: instruction
        ) else {
            noticeKey = "The action recovery brief does not fit the local prompt limit."
            return false
        }
        guard let target = session(targetID), target.isPromptStagingReady else {
            noticeKey = "Confirm one live target is at an input prompt before recovering."
            return false
        }

        let sourceID = focusedID
        let inputBaseline = target.inputSnapshot
        guard target.stagePrompt(recoveryPlan.payload) else { return false }
        let review = RelayPromptReviewPlan(targets: [
            RelayPromptReviewTarget(
                id: target.id,
                agentName: target.agentName,
                projectName: RelayTerminalContext.projectName(target.cwd),
                inputBaseline: inputBaseline
            ),
        ])
        beginPromptReview(review)
        decisionActionRecoveryReceipt = receipt
        decisionActionRecoveryPlan = recoveryPlan
        attentionReturnTicket = nil
        noticeKey = nil
        if let sourceID, sourceID != target.id,
           let source = session(sourceID), !source.exited {
            publishAttentionRoutePulse(from: source.id, to: target.id)
        }
        target.focus()
        return true
    }

    @discardableResult
    func returnFromDecisionActionRecoveryReview() -> Bool {
        guard let receipt = decisionActionRecoveryReceipt,
              savedDecisionActionReceipts.contains(where: { $0.id == receipt.id }),
              savedDecisionCheckpoints.contains(where: { $0.id == receipt.checkpointID }) else {
            clearPromptReview()
            promptStagingVisible = false
            return false
        }
        promptReviewPlan = nil
        promptStagingVisible = false
        decisionActionRecoveryReceipt = nil
        decisionActionRecoveryPlan = nil
        attentionReturnTicket = nil
        selectedDecisionCheckpoint = nil
        selectedDecisionActionReceipt = receipt
        decisionActionReceiptVisible = true
        decisionLibraryVisible = false
        decisionLibraryReturnsToLiveDecision = false
        noticeKey = nil
        return true
    }

    func decisionRecoveryObservations(
        for receipt: RelayDecisionActionReceipt
    ) -> [RelayDecisionRecoveryObservation] {
        savedDecisionRecoveryObservations.filter { $0.actionReceiptID == receipt.id }
    }

    func canCaptureDecisionRecoveryObservation() -> Bool {
        guard decisionRecoveryObservationDraft == nil,
              decisionActionRecoveryReceipt != nil,
              let plan = promptReviewPlan,
              plan.targets.count == 1,
              let target = plan.targets.first,
              let session = session(target.id),
              !session.exited else {
            return false
        }
        return RelayPromptTargetSignal.resolve(
            baseline: target.inputBaseline,
            current: session.inputSnapshot
        ) == .returnDetected
    }

    @discardableResult
    func captureDecisionRecoveryObservation(capturedAt: Date = Date()) -> Bool {
        guard canCaptureDecisionRecoveryObservation() else {
            noticeKey = "Return must be detected before capturing a recovery change."
            return false
        }
        guard let receipt = decisionActionRecoveryReceipt,
              savedDecisionActionReceipts.contains(where: { $0.id == receipt.id }),
              let target = promptReviewPlan?.targets.first,
              let session = session(target.id),
              let visibleScreen = session.captureContext() else {
            noticeKey = "Keep the recovery target open with a visible screen before capturing."
            return false
        }
        let currentInput = session.inputSnapshot
        let observation = RelayDecisionRecoveryObservation(
            checkpointID: receipt.checkpointID,
            actionReceiptID: receipt.id,
            capturedAt: capturedAt,
            targetID: target.id,
            targetAgentName: target.agentName,
            targetProjectName: target.projectName,
            editedAfterFill: currentInput.editRevision > target.inputBaseline.editRevision,
            returnDetected: true,
            visibleScreen: visibleScreen
        )
        decisionRecoveryObservationDraft = observation
        selectedDecisionRecoveryObservation = nil
        decisionRecoveryObservationVisible = true
        decisionActionReceiptVisible = false
        promptStagingVisible = false
        noticeKey = nil
        return true
    }

    func showDecisionRecoveryObservationDraft() {
        guard decisionRecoveryObservationDraft != nil else { return }
        selectedDecisionRecoveryObservation = nil
        decisionRecoveryObservationVisible = true
        promptStagingVisible = false
    }

    @discardableResult
    func saveDecisionRecoveryObservation() -> Bool {
        guard let observation = decisionRecoveryObservationDraft else { return false }
        do {
            let saved = try decisionArchive.saveRecoveryObservation(observation)
            reloadDecisionArchive()
            decisionRecoveryObservationDraft = nil
            selectedDecisionRecoveryObservation = savedDecisionRecoveryObservations.first {
                $0.id == saved.id
            } ?? saved
            decisionRecoveryObservationVisible = true
            noticeKey = "Recovery change saved locally."
            return true
        } catch {
            noticeKey = "Could not save the recovery change."
            return false
        }
    }

    func openDecisionRecoveryObservation(_ observation: RelayDecisionRecoveryObservation) {
        guard savedDecisionRecoveryObservations.contains(where: { $0.id == observation.id }),
              let receipt = savedDecisionActionReceipts.first(where: {
                  $0.id == observation.actionReceiptID
                      && $0.checkpointID == observation.checkpointID
              }) else {
            return
        }
        selectedDecisionCheckpoint = nil
        selectedDecisionActionReceipt = receipt
        decisionActionReceiptVisible = false
        decisionRecoveryObservationDraft = nil
        selectedDecisionRecoveryObservation = observation
        decisionRecoveryObservationVisible = true
        decisionRecoveryHandoffReceipt = nil
        decisionRecoveryHandoffObservation = nil
        decisionRecoveryHandoffPlan = nil
        decisionLibraryVisible = false
        promptStagingVisible = false
    }

    func returnFromDecisionRecoveryObservation(discardingDraft: Bool = false) {
        let observation = activeDecisionRecoveryObservation
        let wasSaved = selectedDecisionRecoveryObservation != nil
        if discardingDraft {
            decisionRecoveryObservationDraft = nil
        }
        selectedDecisionRecoveryObservation = nil
        decisionRecoveryObservationVisible = false

        if !wasSaved,
           !discardingDraft,
           promptReviewPlan != nil,
           observation.flatMap({ session($0.targetID) })?.exited == false {
            promptStagingVisible = true
            return
        }

        promptReviewPlan = nil
        promptStagingVisible = false
        attentionReturnTicket = nil
        decisionActionRecoveryPlan = nil
        decisionRecoveryHandoffReceipt = nil
        decisionRecoveryHandoffObservation = nil
        decisionRecoveryHandoffPlan = nil
        let receiptID = observation?.actionReceiptID ?? decisionActionRecoveryReceipt?.id
        decisionActionRecoveryReceipt = nil
        if let receiptID,
           let receipt = savedDecisionActionReceipts.first(where: { $0.id == receiptID }) {
            selectedDecisionActionReceipt = receipt
            decisionActionReceiptVisible = true
            selectedDecisionCheckpoint = nil
            decisionLibraryVisible = false
        } else {
            selectedDecisionActionReceipt = nil
            decisionActionReceiptVisible = false
            decisionLibraryVisible = true
        }
        noticeKey = nil
    }

    @discardableResult
    func completeDecisionRecoveryHandoff(
        receipt: RelayDecisionActionReceipt,
        observation: RelayDecisionRecoveryObservation,
        instruction: String,
        targetID: UUID
    ) -> Bool {
        let replacesCapturedRecoveryReview = promptReviewPlan != nil
            && decisionActionRecoveryReceipt?.id == receipt.id
            && selectedDecisionRecoveryObservation?.id == observation.id
        guard decisionRecoveryObservationVisible,
              selectedDecisionRecoveryObservation?.id == observation.id,
              savedDecisionRecoveryObservations.contains(where: { $0.id == observation.id }),
              savedDecisionActionReceipts.contains(where: {
                  $0.id == receipt.id && $0.checkpointID == observation.checkpointID
              }),
              savedDecisionCheckpoints.contains(where: { $0.id == observation.checkpointID }),
              promptReviewPlan == nil || replacesCapturedRecoveryReview else {
            noticeKey = "Finish the current prompt flow before relaying a recovery change."
            return false
        }
        guard let handoffPlan = RelayDecisionRecoveryHandoff.plan(
            receipt: receipt,
            observation: observation,
            instruction: instruction
        ) else {
            noticeKey = "The recovery change handoff does not fit the local prompt limit."
            return false
        }
        guard let target = session(targetID), target.isPromptStagingReady else {
            noticeKey = "Confirm one live target is at an input prompt before relaying the change."
            return false
        }

        let sourceID = focusedID
        let inputBaseline = target.inputSnapshot
        guard target.stagePrompt(handoffPlan.payload) else { return false }
        let review = RelayPromptReviewPlan(targets: [
            RelayPromptReviewTarget(
                id: target.id,
                agentName: target.agentName,
                projectName: RelayTerminalContext.projectName(target.cwd),
                inputBaseline: inputBaseline
            ),
        ])
        beginPromptReview(review)
        decisionRecoveryHandoffReceipt = receipt
        decisionRecoveryHandoffObservation = observation
        decisionRecoveryHandoffPlan = handoffPlan
        attentionReturnTicket = nil
        noticeKey = nil
        if let sourceID, sourceID != target.id,
           let source = session(sourceID), !source.exited {
            publishAttentionRoutePulse(from: source.id, to: target.id)
        }
        target.focus()
        return true
    }

    func canCaptureDecisionRecoveryWitness() -> Bool {
        guard decisionRecoveryWitnessDraft == nil,
              decisionRecoveryHandoffReceipt != nil,
              decisionRecoveryHandoffObservation != nil,
              let plan = promptReviewPlan,
              plan.targets.count == 1,
              let target = plan.targets.first,
              let session = session(target.id),
              !session.exited else {
            return false
        }
        return RelayPromptTargetSignal.resolve(
            baseline: target.inputBaseline,
            current: session.inputSnapshot
        ) == .returnDetected
    }

    @discardableResult
    func captureDecisionRecoveryWitness(capturedAt: Date = Date()) -> Bool {
        guard canCaptureDecisionRecoveryWitness() else {
            noticeKey = "Return must be detected before capturing a recovery witness."
            return false
        }
        guard let receipt = decisionRecoveryHandoffReceipt,
              let observation = decisionRecoveryHandoffObservation,
              let handoff = decisionRecoveryHandoffPlan,
              savedDecisionActionReceipts.contains(where: {
                  $0.id == receipt.id && $0.checkpointID == observation.checkpointID
              }),
              savedDecisionRecoveryObservations.contains(where: {
                  $0.id == observation.id && $0.actionReceiptID == receipt.id
              }),
              let target = promptReviewPlan?.targets.first,
              let session = session(target.id),
              let visibleScreen = session.captureContext() else {
            noticeKey = "Keep the witness CLI open with a visible screen before capturing."
            return false
        }
        let currentInput = session.inputSnapshot
        decisionRecoveryWitnessDraft = RelayDecisionRecoveryWitnessDraft(
            id: UUID(),
            checkpointID: observation.checkpointID,
            actionReceiptID: receipt.id,
            recoveryObservationID: observation.id,
            capturedAt: capturedAt,
            handoffPayload: handoff.payload,
            frozenScreenOriginalBytes: handoff.frozenScreenOriginalBytes,
            frozenScreenRetainedBytes: handoff.frozenScreenRetainedBytes,
            frozenScreenTruncated: handoff.frozenScreenTruncated,
            recoveryScreenOriginalBytes: handoff.recoveryScreenOriginalBytes,
            recoveryScreenRetainedBytes: handoff.recoveryScreenRetainedBytes,
            recoveryScreenTruncated: handoff.recoveryScreenTruncated,
            addedCount: handoff.addedCount,
            removedCount: handoff.removedCount,
            unchangedCount: handoff.unchangedCount,
            targetID: target.id,
            targetAgentName: target.agentName,
            targetProjectName: target.projectName,
            editedAfterFill: currentInput.editRevision > target.inputBaseline.editRevision,
            returnDetected: true,
            visibleScreen: visibleScreen
        )
        decisionRecoveryWitnessAssessment = nil
        selectedDecisionRecoveryWitness = nil
        decisionRecoveryWitnessVisible = true
        promptStagingVisible = false
        noticeKey = nil
        return true
    }

    func showDecisionRecoveryWitnessDraft() {
        guard decisionRecoveryWitnessDraft != nil else { return }
        selectedDecisionRecoveryWitness = nil
        decisionRecoveryWitnessVisible = true
        promptStagingVisible = false
    }

    func setDecisionRecoveryWitnessAssessment(
        _ assessment: RelayDecisionRecoveryWitnessAssessment
    ) {
        guard decisionRecoveryWitnessDraft != nil else { return }
        decisionRecoveryWitnessAssessment = assessment
    }

    @discardableResult
    func saveDecisionRecoveryWitness(
        assessment: RelayDecisionRecoveryWitnessAssessment
    ) -> Bool {
        guard let draft = decisionRecoveryWitnessDraft else { return false }
        do {
            let saved = try decisionArchive.saveRecoveryWitness(
                draft.witness(assessment: assessment)
            )
            reloadDecisionArchive()
            decisionRecoveryWitnessDraft = nil
            decisionRecoveryWitnessAssessment = nil
            selectedDecisionRecoveryWitness = savedDecisionRecoveryWitnesses.first {
                $0.id == saved.id
            } ?? saved
            decisionRecoveryWitnessVisible = true
            noticeKey = "Recovery witness saved locally."
            return true
        } catch {
            noticeKey = "Could not save the recovery witness."
            return false
        }
    }

    func decisionRecoveryWitnesses(
        for observation: RelayDecisionRecoveryObservation
    ) -> [RelayDecisionRecoveryWitness] {
        savedDecisionRecoveryWitnesses.filter {
            $0.recoveryObservationID == observation.id
        }
    }

    func openDecisionRecoveryWitness(_ witness: RelayDecisionRecoveryWitness) {
        guard savedDecisionRecoveryWitnesses.contains(where: { $0.id == witness.id }),
              let receipt = savedDecisionActionReceipts.first(where: {
                  $0.id == witness.actionReceiptID
                      && $0.checkpointID == witness.checkpointID
              }),
              let observation = savedDecisionRecoveryObservations.first(where: {
                  $0.id == witness.recoveryObservationID
                      && $0.actionReceiptID == receipt.id
                      && $0.checkpointID == receipt.checkpointID
              }) else {
            return
        }
        selectedDecisionCheckpoint = nil
        selectedDecisionActionReceipt = receipt
        decisionActionReceiptVisible = false
        selectedDecisionRecoveryObservation = observation
        decisionRecoveryObservationVisible = false
        decisionRecoveryWitnessDraft = nil
        decisionRecoveryWitnessAssessment = nil
        selectedDecisionRecoveryWitness = witness
        decisionRecoveryWitnessVisible = true
        decisionLibraryVisible = false
        promptStagingVisible = false
    }

    func returnFromDecisionRecoveryWitness(discardingDraft: Bool = false) {
        let draft = activeDecisionRecoveryWitnessDraft
        let witness = activeDecisionRecoveryWitness
        let wasSaved = witness != nil
        if discardingDraft {
            decisionRecoveryWitnessDraft = nil
            decisionRecoveryWitnessAssessment = nil
        }
        selectedDecisionRecoveryWitness = nil
        decisionRecoveryWitnessVisible = false

        if !wasSaved,
           !discardingDraft,
           promptReviewPlan != nil,
           draft.flatMap({ session($0.targetID) })?.exited == false {
            promptStagingVisible = true
            return
        }

        decisionRecoveryWitnessAssessment = nil

        promptReviewPlan = nil
        promptStagingVisible = false
        attentionReturnTicket = nil
        decisionRecoveryHandoffReceipt = nil
        decisionRecoveryHandoffObservation = nil
        decisionRecoveryHandoffPlan = nil
        let observationID = witness?.recoveryObservationID
            ?? draft?.recoveryObservationID
        if let observationID,
           let observation = savedDecisionRecoveryObservations.first(where: {
               $0.id == observationID
           }),
           let receipt = savedDecisionActionReceipts.first(where: {
               $0.id == observation.actionReceiptID
           }) {
            selectedDecisionCheckpoint = nil
            selectedDecisionActionReceipt = receipt
            decisionActionReceiptVisible = false
            selectedDecisionRecoveryObservation = observation
            decisionRecoveryObservationVisible = true
            decisionLibraryVisible = false
        } else {
            selectedDecisionRecoveryObservation = nil
            decisionRecoveryObservationVisible = false
            decisionLibraryVisible = true
        }
        noticeKey = nil
    }

    @discardableResult
    func returnFromDecisionRecoveryHandoffReview() -> Bool {
        guard let receipt = decisionRecoveryHandoffReceipt,
              let observation = decisionRecoveryHandoffObservation,
              savedDecisionRecoveryObservations.contains(where: { $0.id == observation.id }),
              savedDecisionActionReceipts.contains(where: {
                  $0.id == receipt.id && $0.checkpointID == observation.checkpointID
              }),
              savedDecisionCheckpoints.contains(where: { $0.id == observation.checkpointID }) else {
            clearPromptReview()
            promptStagingVisible = false
            return false
        }
        promptReviewPlan = nil
        promptStagingVisible = false
        attentionReturnTicket = nil
        decisionRecoveryHandoffReceipt = nil
        decisionRecoveryHandoffObservation = nil
        decisionRecoveryHandoffPlan = nil
        selectedDecisionCheckpoint = nil
        selectedDecisionActionReceipt = receipt
        decisionActionReceiptVisible = false
        selectedDecisionRecoveryObservation = observation
        decisionRecoveryObservationVisible = true
        decisionLibraryVisible = false
        decisionLibraryReturnsToLiveDecision = false
        noticeKey = nil
        return true
    }

    @discardableResult
    func returnFromDecisionBriefReview() -> Bool {
        guard let checkpoint = decisionBriefCheckpoint,
              savedDecisionCheckpoints.contains(where: { $0.id == checkpoint.id }) else {
            clearPromptReview()
            promptStagingVisible = false
            return false
        }
        promptReviewPlan = nil
        promptStagingVisible = false
        decisionBriefCheckpoint = nil
        decisionBriefPlan = nil
        decisionActionReceiptDraft = nil
        decisionActionReceiptVisible = false
        attentionReturnTicket = nil
        selectedDecisionCheckpoint = checkpoint
        decisionLibraryVisible = false
        decisionLibraryReturnsToLiveDecision = false
        noticeKey = nil
        return true
    }

    func parentDecisionCheckpoint(
        for checkpoint: RelayDecisionCheckpoint
    ) -> RelayDecisionCheckpoint? {
        guard let parentID = checkpoint.decision.receipt.parentCheckpointID else {
            return nil
        }
        return savedDecisionCheckpoints.first { $0.id == parentID }
    }

    func decisionLineage(
        for checkpoint: RelayDecisionCheckpoint
    ) -> RelayDecisionLineage? {
        guard savedDecisionCheckpoints.contains(where: { $0.id == checkpoint.id }) else {
            return nil
        }
        return RelayDecisionLineage(
            checkpoint: checkpoint,
            checkpoints: savedDecisionCheckpoints
        )
    }

    func decisionFamily(
        for checkpoint: RelayDecisionCheckpoint
    ) -> RelayDecisionFamily? {
        guard savedDecisionCheckpoints.contains(where: { $0.id == checkpoint.id }) else {
            return nil
        }
        return RelayDecisionFamily(
            checkpoint: checkpoint,
            checkpoints: savedDecisionCheckpoints
        )
    }

    func decisionAnnotation(
        for checkpoint: RelayDecisionCheckpoint
    ) -> RelayDecisionAnnotation? {
        decisionAnnotations[checkpoint.id]
    }

    @discardableResult
    func updateDecisionAnnotation(
        for checkpoint: RelayDecisionCheckpoint,
        title: String,
        tagsText: String,
        isPinned: Bool
    ) -> Bool {
        guard savedDecisionCheckpoints.contains(where: { $0.id == checkpoint.id }) else {
            return false
        }
        guard let annotation = RelayDecisionAnnotation(
            checkpointID: checkpoint.id,
            title: title,
            tagsText: tagsText,
            isPinned: isPinned
        ) else {
            noticeKey = "Decision label is too long."
            return false
        }
        do {
            try decisionArchive.saveAnnotation(annotation)
            reloadDecisionArchive()
            noticeKey = "Decision label saved locally."
            return true
        } catch {
            noticeKey = "Could not save the decision label."
            return false
        }
    }

    @discardableResult
    func toggleDecisionPin(_ checkpoint: RelayDecisionCheckpoint) -> Bool {
        let annotation = decisionAnnotation(for: checkpoint)
        return updateDecisionAnnotation(
            for: checkpoint,
            title: annotation?.title ?? "",
            tagsText: annotation?.tags.joined(separator: ", ") ?? "",
            isPinned: !(annotation?.isPinned ?? false)
        )
    }

    func returnFromDecisionCheckpoint() {
        selectedDecisionCheckpoint = nil
        decisionLibraryVisible = true
    }

    @discardableResult
    func moveDecisionCheckpointToTrash(_ checkpoint: RelayDecisionCheckpoint) -> Bool {
        do {
            try decisionArchive.moveToTrash(checkpoint)
            if selectedDecisionCheckpoint?.id == checkpoint.id {
                selectedDecisionCheckpoint = nil
                decisionLibraryVisible = true
            }
            if liveDecisionCheckpointID == checkpoint.id {
                liveDecisionCheckpointID = nil
            }
            if decisionActionReceiptDraft?.checkpointID == checkpoint.id {
                decisionActionReceiptDraft = nil
                decisionActionReceiptVisible = false
            }
            if selectedDecisionActionReceipt?.checkpointID == checkpoint.id {
                selectedDecisionActionReceipt = nil
                decisionActionReceiptVisible = false
            }
            if decisionRecoveryObservationDraft?.checkpointID == checkpoint.id {
                decisionRecoveryObservationDraft = nil
                decisionRecoveryObservationVisible = false
            }
            if selectedDecisionRecoveryObservation?.checkpointID == checkpoint.id {
                selectedDecisionRecoveryObservation = nil
                decisionRecoveryObservationVisible = false
            }
            if decisionRecoveryHandoffObservation?.checkpointID == checkpoint.id {
                decisionRecoveryHandoffReceipt = nil
                decisionRecoveryHandoffObservation = nil
                decisionRecoveryHandoffPlan = nil
                promptReviewPlan = nil
                promptStagingVisible = false
            }
            if decisionRecoveryWitnessDraft?.checkpointID == checkpoint.id {
                decisionRecoveryWitnessDraft = nil
                decisionRecoveryWitnessAssessment = nil
                decisionRecoveryWitnessVisible = false
            }
            if selectedDecisionRecoveryWitness?.checkpointID == checkpoint.id {
                selectedDecisionRecoveryWitness = nil
                decisionRecoveryWitnessVisible = false
            }
            reloadDecisionArchive()
            noticeKey = nil
            return true
        } catch {
            noticeKey = "Could not move the decision checkpoint to Trash."
            return false
        }
    }

    func resultArbitrationSourceDrift() -> [UUID: RelayResultSnapshotDrift] {
        guard let receipt = resultArbitrationReceipt else { return [:] }
        return Dictionary(uniqueKeysWithValues: receipt.confluence.snapshots.map { snapshot in
            guard let session = session(snapshot.id), !session.exited else {
                return (snapshot.id, .closed)
            }
            return (
                snapshot.id,
                session.captureContext() == snapshot.text ? .unchanged : .changed
            )
        })
    }

    func clearResultConfluence() {
        resultConfluence = nil
        if let checkpoint = resultConfluenceReplayCheckpoint {
            selectedDecisionCheckpoint = checkpoint
            decisionLibraryVisible = false
        }
        resultConfluenceReplayCheckpoint = nil
    }

    @discardableResult
    func completeResultArbitration(instruction: String, targetID: UUID) -> Bool {
        guard let resultConfluence else { return false }
        let parentCheckpointID = resultConfluenceReplayCheckpoint?.id
        guard let arbitrationPlan = RelayResultArbitration.plan(
            instruction: instruction,
            snapshots: resultConfluence.snapshots
        ) else {
            noticeKey = "Write an arbitration instruction that fits the local prompt limit."
            return false
        }
        guard let target = session(targetID), target.isPromptStagingReady else {
            noticeKey = "Confirm one live target is at an input prompt before relaying results."
            return false
        }

        let sourceID = focusedID
        let inputBaseline = target.inputSnapshot
        guard target.stagePrompt(arbitrationPlan.payload) else { return false }
        let receipt = RelayResultArbitrationReceipt(
            confluence: resultConfluence,
            plan: arbitrationPlan,
            targetID: target.id,
            parentCheckpointID: parentCheckpointID
        )
        let plan = RelayPromptReviewPlan(targets: [
            RelayPromptReviewTarget(
                id: target.id,
                agentName: target.agentName,
                projectName: RelayTerminalContext.projectName(target.cwd),
                inputBaseline: inputBaseline
            ),
        ])
        beginPromptReview(plan)
        resultArbitrationReceipt = receipt
        noticeKey = nil
        if let sourceID,
           sourceID != target.id,
           let source = session(sourceID), !source.exited {
            attentionReturnTicket = RelayTerminalReturnTicket(
                sessionID: source.id,
                closesPromptStaging: true
            )
            publishAttentionRoutePulse(from: source.id, to: target.id)
        }
        target.focus()
        return true
    }

    private func resultSnapshots(for ids: [UUID]) -> [RelayResultSnapshot] {
        ids.compactMap { id in
            guard let session = session(id), !session.exited,
                  let text = session.captureContext() else { return nil }
            return RelayResultSnapshot(
                id: session.id,
                agentName: session.agentName,
                projectName: RelayTerminalContext.projectName(session.cwd),
                text: text
            )
        }
    }

    private func reloadDecisionArchive() {
        do {
            let contents = try decisionArchive.load()
            savedDecisionCheckpoints = contents.checkpoints
            decisionArchiveRejectedCount = contents.rejectedCount
            decisionAnnotations = contents.annotations
            decisionAnnotationRejectedCount = contents.rejectedAnnotationCount
            savedDecisionActionReceipts = contents.actionReceipts
            decisionActionReceiptRejectedCount = contents.rejectedActionReceiptCount
            savedDecisionRecoveryObservations = contents.recoveryObservations
            decisionRecoveryObservationRejectedCount =
                contents.rejectedRecoveryObservationCount
            savedDecisionRecoveryWitnesses = contents.recoveryWitnesses
            decisionRecoveryWitnessRejectedCount = contents.rejectedRecoveryWitnessCount
        } catch {
            savedDecisionCheckpoints = []
            decisionArchiveRejectedCount = 0
            decisionAnnotations = [:]
            decisionAnnotationRejectedCount = 0
            savedDecisionActionReceipts = []
            decisionActionReceiptRejectedCount = 0
            savedDecisionRecoveryObservations = []
            decisionRecoveryObservationRejectedCount = 0
            savedDecisionRecoveryWitnesses = []
            decisionRecoveryWitnessRejectedCount = 0
            noticeKey = "Could not load saved decision checkpoints."
        }
    }

    private func connect(_ session: RelayTerminalSession) {
        session.onFocus = { [weak self, weak session] in
            guard let self, let session else { return }
            self.activate(session.id)
        }
        session.onOutputRecorded = { [weak self, weak session] date in
            guard let self, let session else { return }
            if self.focusedID == session.id, self.isTerminalViewed(session) {
                self.pendingOutputDates.removeValue(forKey: session.id)
            } else {
                self.pendingOutputDates[session.id] = date
            }
        }
        session.onReset = { [weak self, weak session] in
            guard let self, let session else { return }
            self.pendingOutputDates.removeValue(forKey: session.id)
        }
    }

    /// Registers any non-terminal window at a cascaded frame.
    private func registerWindow(_ id: UUID) {
        windowFrames[id] = RelayWindowGeometry.cascadeFrame(
            serial: openSerial, in: canvasSize
        )
        openSerial += 1
        zOrder.append(id)
        focusedID = id
    }

    private func unregisterWindow(_ id: UUID) {
        windowFrames.removeValue(forKey: id)
        zoomRestore.removeValue(forKey: id)
        zOrder.removeAll { $0 == id }
        if focusedID == id {
            focusedID = zOrder.last
        }
    }

    func frame(for id: UUID) -> CGRect {
        windowFrames[id] ?? RelayWindowGeometry.cascadeFrame(serial: 0, in: canvasSize)
    }

    func open(
        agent: RelayAgent,
        cwd: String,
        optionValue: (String) -> String?
    ) {
        guard sessions.count < RelayTerminalLauncher.maxSessions else {
            noticeKey = "Terminal limit reached (4)"
            return
        }
        guard let spec = RelayTerminalLauncher.spec(for: agent, optionValue: optionValue) else {
            noticeKey = agent.id == "mix"
                ? "MIX has no standalone CLI to embed."
                : "This agent's CLI was not found."
            return
        }
        noticeKey = nil
        let session = RelayTerminalSession(agent: agent, cwd: cwd, spec: spec)
        connect(session)
        sessions.append(session)
        windowFrames[session.id] = RelayWindowGeometry.cascadeFrame(
            serial: openSerial, in: canvasSize
        )
        openSerial += 1
        zOrder.append(session.id)
        focusedID = session.id
        DispatchQueue.main.async {
            session.focus()
        }
        persistDesk()
    }

    @discardableResult
    func openProjectPair(
        agents: [RelayAgent],
        cwd: String,
        optionValue: (RelayAgent, String) -> String?
    ) -> Bool {
        let targetIDs = ["claude", "codex"]
        let targets = targetIDs.compactMap { id in
            agents.first { $0.id == id && $0.isAvailable }
        }
        guard targets.count == targetIDs.count else {
            noticeKey = "Claude and Codex must both be available."
            return false
        }

        let missing = targets.filter { agent in
            !sessions.contains { $0.agentID == agent.id && $0.cwd == cwd }
        }
        guard sessions.count + missing.count <= RelayTerminalLauncher.maxSessions else {
            noticeKey = "Not enough terminal slots for this project pair."
            return false
        }

        for agent in missing {
            open(agent: agent, cwd: cwd) { key in
                optionValue(agent, key)
            }
        }
        let pair = targetIDs.compactMap { id in
            sessions.first { $0.agentID == id && $0.cwd == cwd }
        }
        for session in pair where session.exited {
            session.restart()
        }
        noticeKey = nil
        let shouldTile = pair.count == targetIDs.count && zOrder.count == pair.count
        if !shouldTile {
            pair.last?.focus()
        }
        return shouldTile
    }

    /// Opens a dialogue window in setup mode.
    func openDialogue(_ run: RelayDialogueRun) {
        guard dialogues.count < Self.maxDialogues else {
            noticeKey = "Dialogue limit reached (2)"
            return
        }
        noticeKey = nil
        dialogues.append(run)
        registerWindow(run.id)
    }

    func closeDialogue(_ run: RelayDialogueRun) {
        run.stop()
        dialogues.removeAll { $0.id == run.id }
        unregisterWindow(run.id)
        if noticeKey == "Dialogue limit reached (2)" {
            noticeKey = nil
        }
    }

    /// Opens a parallel-compare window in setup mode.
    func openCompare(_ run: RelayCompareRun) {
        guard compares.count < Self.maxCompares else {
            noticeKey = "Compare limit reached (2)"
            return
        }
        noticeKey = nil
        compares.append(run)
        registerWindow(run.id)
    }

    func closeCompare(_ run: RelayCompareRun) {
        run.close()
        compares.removeAll { $0.id == run.id }
        unregisterWindow(run.id)
        if noticeKey == "Compare limit reached (2)" {
            noticeKey = nil
        }
    }

    /// Opens a chain window in setup mode.
    func openChain(_ run: RelayChainRun) {
        guard chains.count < Self.maxChains else {
            noticeKey = "Chain limit reached (2)"
            return
        }
        noticeKey = nil
        chains.append(run)
        registerWindow(run.id)
    }

    func closeChain(_ run: RelayChainRun) {
        run.close()
        chains.removeAll { $0.id == run.id }
        unregisterWindow(run.id)
        if noticeKey == "Chain limit reached (2)" {
            noticeKey = nil
        }
    }

    /// Opens (or raises) the single approvals window.
    func openApprovals() {
        if let approvalPanel {
            activate(approvalPanel.id)
            return
        }
        let panel = RelayApprovalPanel()
        approvalPanel = panel
        registerWindow(panel.id)
    }

    func closeApprovals() {
        guard let panel = approvalPanel else { return }
        approvalPanel = nil
        unregisterWindow(panel.id)
    }

    /// Focuses a window and raises it to the top of the stack.
    func activate(_ id: UUID) {
        guard zOrder.contains(id) else { return }
        pendingOutputDates.removeValue(forKey: id)
        if attentionReturnTicket?.sessionID == id {
            attentionReturnTicket = nil
        }
        if focusedID != id {
            focusedID = id
        }
        if zOrder.last != id, let index = zOrder.firstIndex(of: id) {
            zOrder.remove(at: index)
            zOrder.append(id)
            persistDesk()
        }
    }

    func close(_ session: RelayTerminalSession) {
        session.shutdown()
        sessions.removeAll { $0.id == session.id }
        pendingOutputDates.removeValue(forKey: session.id)
        windowFrames.removeValue(forKey: session.id)
        zoomRestore.removeValue(forKey: session.id)
        zOrder.removeAll { $0 == session.id }
        if focusedID == session.id {
            focusedID = zOrder.last
        }
        if attentionReturnTicket?.sessionID == session.id
            || attentionReturnTicket?.sessionID == focusedID {
            attentionReturnTicket = nil
        }
        if attentionRoutePulse?.sourceID == session.id
            || attentionRoutePulse?.targetID == session.id {
            attentionRoutePulse = nil
        }
        if sessions.count < RelayTerminalLauncher.maxSessions,
           let noticeKey,
           [
               "Terminal limit reached (4)",
               "Not enough terminal slots for this project pair.",
           ].contains(noticeKey) {
            self.noticeKey = nil
        }
        if sessions.isEmpty, let noticeKey,
           [
               "Desk restored.",
               "Some saved terminals are unavailable.",
               "Saved terminals are unavailable.",
           ].contains(noticeKey) {
            self.noticeKey = nil
        }
        if sessions.isEmpty {
            let returnCheckpoint = decisionBriefCheckpoint
            let returnActionReceipt = decisionActionRecoveryReceipt
            let returnRecoveryHandoffReceipt = decisionRecoveryHandoffReceipt
            let returnRecoveryHandoffObservation = decisionRecoveryHandoffObservation
            promptStagingVisible = false
            promptReviewPlan = nil
            decisionBriefCheckpoint = nil
            decisionBriefPlan = nil
            decisionActionRecoveryReceipt = nil
            decisionActionRecoveryPlan = nil
            decisionRecoveryHandoffReceipt = nil
            decisionRecoveryHandoffObservation = nil
            decisionRecoveryHandoffPlan = nil
            contextRelayDraft = nil
            if resultConfluenceReplayCheckpoint == nil {
                resultConfluence = nil
            }
            resultArbitrationReceipt = nil
            resultArbitrationDecision = nil
            resultArbitrationDecisionVisible = false
            if decisionRecoveryWitnessDraft != nil {
                selectedDecisionCheckpoint = nil
                decisionActionReceiptVisible = false
                decisionRecoveryObservationVisible = false
                decisionRecoveryWitnessVisible = true
            } else if decisionRecoveryObservationDraft != nil {
                selectedDecisionCheckpoint = nil
                decisionActionReceiptVisible = false
                decisionRecoveryObservationVisible = true
            } else if let returnRecoveryHandoffReceipt,
                      let returnRecoveryHandoffObservation,
                      savedDecisionActionReceipts.contains(where: {
                          $0.id == returnRecoveryHandoffReceipt.id
                      }),
                      savedDecisionRecoveryObservations.contains(where: {
                          $0.id == returnRecoveryHandoffObservation.id
                      }) {
                selectedDecisionCheckpoint = nil
                selectedDecisionActionReceipt = returnRecoveryHandoffReceipt
                decisionActionReceiptVisible = false
                selectedDecisionRecoveryObservation = returnRecoveryHandoffObservation
                decisionRecoveryObservationVisible = true
                decisionLibraryVisible = false
            } else if decisionActionReceiptDraft != nil {
                selectedDecisionCheckpoint = nil
                decisionActionReceiptVisible = true
            } else if let returnActionReceipt,
                      savedDecisionActionReceipts.contains(where: {
                          $0.id == returnActionReceipt.id
                      }) {
                selectedDecisionCheckpoint = nil
                selectedDecisionActionReceipt = returnActionReceipt
                decisionActionReceiptVisible = true
                decisionLibraryVisible = false
            } else if let returnCheckpoint,
               savedDecisionCheckpoints.contains(where: { $0.id == returnCheckpoint.id }) {
                selectedDecisionCheckpoint = returnCheckpoint
                decisionLibraryVisible = false
            }
        }
        persistDesk()
    }

    func moveWindow(id: UUID, base: CGRect, translation: CGSize) {
        guard windowFrames[id] != nil else { return }
        zoomRestore.removeValue(forKey: id)
        windowFrames[id] = RelayWindowGeometry.moved(
            base, translation: translation, in: canvasSize
        )
        persistDesk()
    }

    func resizeWindow(
        id: UUID, base: CGRect, handle: RelayResizeHandle, translation: CGSize
    ) {
        guard windowFrames[id] != nil else { return }
        zoomRestore.removeValue(forKey: id)
        windowFrames[id] = RelayWindowGeometry.resized(
            base, handle: handle, translation: translation, in: canvasSize
        )
        persistDesk()
    }

    /// Fills the workspace with this window, or restores its previous frame.
    func toggleZoom(_ id: UUID) {
        guard let current = windowFrames[id] else { return }
        activate(id)
        if let restore = zoomRestore.removeValue(forKey: id) {
            windowFrames[id] = RelayWindowGeometry.fitted(restore, in: canvasSize)
        } else {
            guard let full = RelayWindowGeometry.tiled(count: 1, in: canvasSize).first else {
                return
            }
            zoomRestore[id] = current
            windowFrames[id] = full
        }
        persistDesk()
    }

    /// Arranges all windows into a non-overlapping grid.
    func arrangeAll() {
        let ids = zOrder
        let frames = RelayWindowGeometry.tiled(count: ids.count, in: canvasSize)
        guard frames.count == ids.count else { return }
        zoomRestore.removeAll()
        for (index, id) in ids.enumerated() {
            windowFrames[id] = frames[index]
        }
        persistDesk()
    }

    func reportWorkspaceSize(_ size: CGSize) {
        guard size != canvasSize, size.width > 0, size.height > 0 else { return }
        canvasSize = size
        for (id, frame) in windowFrames {
            windowFrames[id] = RelayWindowGeometry.fitted(frame, in: size)
        }
    }

    /// 前回の CLI デスクだけを開き直す。意図しないモデル実行を避けるため、
    /// 対話・比較・チェーンのウィンドウは復元対象に含めない。
    @discardableResult
    func restoreDesk(
        agents: [RelayAgent],
        optionValue: (RelayAgent, String) -> String?
    ) -> Int {
        guard sessions.isEmpty,
              canvasSize.width > 0, canvasSize.height > 0,
              let snapshot = restorableDesk else {
            return 0
        }

        restoringDesk = true
        var restored = 0
        for saved in snapshot.terminals.prefix(RelayTerminalLauncher.maxSessions) {
            guard let agent = agents.first(where: {
                $0.id == saved.agentID && $0.isAvailable
            }), let spec = RelayTerminalLauncher.spec(
                for: agent,
                optionValue: { optionValue(agent, $0) }
            ) else {
                continue
            }

            let session = RelayTerminalSession(agent: agent, cwd: saved.cwd, spec: spec)
            connect(session)
            sessions.append(session)
            windowFrames[session.id] = RelayWindowGeometry.fitted(
                saved.frame.rect(in: canvasSize), in: canvasSize
            )
            zOrder.append(session.id)
            restored += 1
        }
        restoringDesk = false

        if restored == 0 {
            noticeKey = "Saved terminals are unavailable."
            return 0
        }
        focusedID = zOrder.last
        openSerial += restored
        noticeKey = restored < snapshot.terminals.count
            ? "Some saved terminals are unavailable."
            : "Desk restored."
        persistDesk()
        if let focusedID, let session = session(focusedID) {
            DispatchQueue.main.async { session.focus() }
        }
        return restored
    }

    func forgetDesk() {
        defaults.removeObject(forKey: RelayDeskSnapshot.defaultsKey)
        restorableDesk = nil
    }

    private func persistDesk() {
        guard !restoringDesk else { return }
        guard !sessions.isEmpty else {
            forgetDesk()
            return
        }
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }

        let saved = zOrder.compactMap { id -> RelayDeskSnapshot.Terminal? in
            guard let session = session(id), let frame = windowFrames[id] else { return nil }
            return RelayDeskSnapshot.Terminal(
                agentID: session.agentID,
                cwd: session.cwd,
                frame: RelayDeskSnapshot.NormalizedFrame(frame, in: canvasSize)
            )
        }
        let snapshot = RelayDeskSnapshot(terminals: saved)
        guard !saved.isEmpty, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: RelayDeskSnapshot.defaultsKey)
        restorableDesk = snapshot
    }

    func shutdownAll() {
        for session in sessions {
            session.shutdown()
        }
        for run in dialogues {
            run.stop()
        }
        for run in compares {
            run.close()
        }
        for run in chains {
            run.close()
        }
        sessions.removeAll()
        dialogues.removeAll()
        compares.removeAll()
        chains.removeAll()
        approvalPanel = nil
        windowFrames.removeAll()
        zoomRestore.removeAll()
        zOrder.removeAll()
        focusedID = nil
        attentionReturnTicket = nil
        attentionRoutePulse = nil
        contextRelayDraft = nil
        resultConfluence = nil
        resultConfluenceReplayCheckpoint = nil
        resultArbitrationReceipt = nil
        resultArbitrationDecision = nil
        resultArbitrationDecisionVisible = false
        decisionBriefCheckpoint = nil
        decisionBriefPlan = nil
        decisionActionReceiptDraft = nil
        selectedDecisionActionReceipt = nil
        decisionActionReceiptVisible = false
        decisionActionRecoveryReceipt = nil
        decisionActionRecoveryPlan = nil
        decisionRecoveryObservationDraft = nil
        selectedDecisionRecoveryObservation = nil
        decisionRecoveryObservationVisible = false
        decisionRecoveryHandoffReceipt = nil
        decisionRecoveryHandoffObservation = nil
        decisionRecoveryHandoffPlan = nil
        decisionRecoveryWitnessDraft = nil
        decisionRecoveryWitnessAssessment = nil
        selectedDecisionRecoveryWitness = nil
        decisionRecoveryWitnessVisible = false
        persistDesk()
    }
}

struct RelayTerminalHost: NSViewRepresentable {
    let session: RelayTerminalSession

    func makeNSView(context: Context) -> RelayTerminalNSView {
        let view = session.terminalView
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: RelayTerminalNSView, context: Context) {}
}

struct RelayTerminalWorkspace: View {
    @ObservedObject var store: RelayTerminalStore
    let agents: [RelayAgent]
    let onRestoreDesk: () -> Void
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                SwiftUI.Color.clear
                if store.zOrder.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ForEach(store.orderedItems) { item in
                    switch item {
                    case .terminal(let session):
                        RelayTerminalWindow(
                            store: store,
                            session: session,
                            frame: store.frame(for: session.id),
                            canvasSize: proxy.size,
                            focused: store.focusedID == session.id
                        )
                    case .dialogue(let run):
                        RelayDialogueWindow(
                            store: store,
                            run: run,
                            agents: agents,
                            frame: store.frame(for: run.id),
                            canvasSize: proxy.size,
                            focused: store.focusedID == run.id
                        )
                    case .compare(let run):
                        RelayCompareWindow(
                            store: store,
                            run: run,
                            agents: agents,
                            frame: store.frame(for: run.id),
                            canvasSize: proxy.size,
                            focused: store.focusedID == run.id
                        )
                    case .chain(let run):
                        RelayChainWindow(
                            store: store,
                            run: run,
                            agents: agents,
                            frame: store.frame(for: run.id),
                            canvasSize: proxy.size,
                            focused: store.focusedID == run.id
                        )
                    case .approvals(let panel):
                        RelayApprovalWindow(
                            store: store,
                            panel: panel,
                            frame: store.frame(for: panel.id),
                            canvasSize: proxy.size,
                            focused: store.focusedID == panel.id
                        )
                    }
                }
                if let pulse = store.attentionRoutePulse,
                   let source = store.session(pulse.sourceID),
                   let target = store.session(pulse.targetID) {
                    RelayAttentionRouteOverlay(
                        sourceFrame: store.frame(for: source.id),
                        targetFrame: store.frame(for: target.id),
                        tint: target.accent,
                        reduceMotion: reduceMotion
                    )
                    .id(pulse.id)
                    .zIndex(10_000)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                if let witness = store.activeDecisionRecoveryWitness,
                   let observation = store.savedDecisionRecoveryObservations.first(where: {
                       $0.id == witness.recoveryObservationID
                   }),
                   let receipt = store.savedDecisionActionReceipts.first(where: {
                       $0.id == witness.actionReceiptID
                           && $0.checkpointID == witness.checkpointID
                   }) {
                    RelayDecisionRecoveryWitnessDeck(
                        store: store,
                        receipt: receipt,
                        observation: observation,
                        draft: nil,
                        witness: witness
                    )
                    .id(witness.id)
                    .frame(maxWidth: 880)
                    .padding(18)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
                } else if let draft = store.activeDecisionRecoveryWitnessDraft,
                          let observation = store.savedDecisionRecoveryObservations.first(where: {
                              $0.id == draft.recoveryObservationID
                          }),
                          let receipt = store.savedDecisionActionReceipts.first(where: {
                              $0.id == draft.actionReceiptID
                                  && $0.checkpointID == draft.checkpointID
                          }) {
                    RelayDecisionRecoveryWitnessDeck(
                        store: store,
                        receipt: receipt,
                        observation: observation,
                        draft: draft,
                        witness: nil
                    )
                    .id(draft.id)
                    .frame(maxWidth: 880)
                    .padding(18)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
                } else if let observation = store.activeDecisionRecoveryObservation,
                   let receipt = store.savedDecisionActionReceipts.first(where: {
                       $0.id == observation.actionReceiptID
                           && $0.checkpointID == observation.checkpointID
                   }) {
                    RelayDecisionRecoveryObservationDeck(
                        store: store,
                        receipt: receipt,
                        observation: observation,
                        isSaved: store.activeDecisionRecoveryObservationIsSaved
                    )
                    .id(observation.id)
                    .frame(maxWidth: 880)
                    .padding(18)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .trailing).combined(with: .opacity)
                    )
                } else if let receipt = store.activeDecisionActionReceipt {
                    RelayDecisionActionReceiptDeck(
                        store: store,
                        receipt: receipt,
                        isSaved: store.activeDecisionActionReceiptIsSaved
                    )
                    .id(receipt.id)
                    .frame(maxWidth: 880)
                    .padding(18)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                } else if let checkpoint = store.selectedDecisionCheckpoint {
                    RelayResultArbitrationDecisionDeck(
                        store: store,
                        decision: checkpoint.decision,
                        checkpoint: checkpoint
                    )
                    .id(checkpoint.id)
                    .frame(maxWidth: 880)
                    .padding(18)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                } else if store.decisionLibraryVisible {
                    RelayDecisionLibraryDeck(store: store)
                        .frame(maxWidth: 760)
                        .padding(18)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                } else if let draft = store.contextRelayDraft {
                    RelayContextRelayDeck(store: store, draft: draft)
                        .id(draft.id)
                        .frame(maxWidth: 680)
                        .padding(18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if store.resultArbitrationDecisionVisible,
                          let decision = store.resultArbitrationDecision {
                    RelayResultArbitrationDecisionDeck(
                        store: store,
                        decision: decision,
                        checkpoint: nil
                    )
                        .frame(maxWidth: 880)
                        .padding(18)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                } else if let confluence = store.resultConfluence {
                    RelayResultConfluenceDeck(store: store, confluence: confluence)
                        .id(confluence.id)
                        .frame(maxWidth: 880)
                        .padding(18)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .bottom).combined(with: .opacity)
                        )
                } else if store.promptStagingVisible {
                    RelayPromptStagingDeck(store: store)
                        .frame(maxWidth: 620)
                        .padding(18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear { store.reportWorkspaceSize(proxy.size) }
            .onChange(of: proxy.size) { _, size in
                store.reportWorkspaceSize(size)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snapshot = store.restorableDesk {
                RelayDeskRecoveryCard(
                    snapshot: snapshot,
                    agents: agents,
                    onRestore: onRestoreDesk,
                    onForget: store.forgetDesk
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("┌─ \(copy.text("NO TERMINALS"))")
                    Text("│ \(copy.text("Click an agent on the left"))")
                    Text("└─ \(copy.text("to open its real CLI here"))")
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(RelayPalette.muted)
            }
        }
    }
}

private struct RelayAttentionRouteOverlay: View {
    let sourceFrame: CGRect
    let targetFrame: CGRect
    let tint: SwiftUI.Color
    let reduceMotion: Bool
    @State private var revealed = false

    private var anchors: (source: CGPoint, target: CGPoint) {
        let movesRight = targetFrame.midX >= sourceFrame.midX
        return (
            CGPoint(
                x: movesRight ? sourceFrame.maxX : sourceFrame.minX,
                y: sourceFrame.minY + 18
            ),
            CGPoint(
                x: movesRight ? targetFrame.minX : targetFrame.maxX,
                y: targetFrame.minY + 18
            )
        )
    }

    private var circuit: Path {
        let anchors = anchors
        let bendX = (anchors.source.x + anchors.target.x) / 2
        return Path { path in
            path.move(to: anchors.source)
            path.addLine(to: CGPoint(x: bendX, y: anchors.source.y))
            path.addLine(to: CGPoint(x: bendX, y: anchors.target.y))
            path.addLine(to: anchors.target)
        }
    }

    var body: some View {
        ZStack {
            if reduceMotion {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .position(anchors.target)
                Circle()
                    .stroke(tint.opacity(0.8), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                    .position(anchors.target)
            } else {
                circuit
                    .trim(from: 0, to: revealed ? 1 : 0)
                    .stroke(
                        tint.opacity(0.18),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                    )
                circuit
                    .trim(from: 0, to: revealed ? 1 : 0)
                    .stroke(
                        tint.opacity(0.95),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
                Circle()
                    .fill(tint.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .position(anchors.source)
                    .opacity(revealed ? 1 : 0)
                Circle()
                    .stroke(tint.opacity(0.95), lineWidth: 1.5)
                    .frame(width: 22, height: 22)
                    .position(anchors.target)
                    .scaleEffect(revealed ? 1 : 0.6)
                    .opacity(revealed ? 1 : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else {
                revealed = true
                return
            }
            withAnimation(.easeOut(duration: 0.38)) {
                revealed = true
            }
        }
    }
}

private struct RelayContextForkRail: View {
    let sourceAccent: SwiftUI.Color
    let targetAccents: [SwiftUI.Color]

    var body: some View {
        Canvas { context, size in
            let source = CGPoint(x: 3, y: size.height / 2)
            let junctionX = size.width * 0.46
            let accents = targetAccents.isEmpty ? [RelayPalette.muted] : targetAccents
            let targetPoints = accents.indices.map { index in
                let y = size.height * CGFloat(index + 1) / CGFloat(accents.count + 1)
                return CGPoint(x: size.width - 3, y: y)
            }

            var trunk = Path()
            trunk.move(to: source)
            trunk.addLine(to: CGPoint(x: junctionX, y: source.y))
            context.stroke(trunk, with: .color(sourceAccent), lineWidth: 1.25)

            for (index, target) in targetPoints.enumerated() {
                var branch = Path()
                branch.move(to: CGPoint(x: junctionX, y: source.y))
                branch.addLine(to: CGPoint(x: junctionX, y: target.y))
                branch.addLine(to: target)
                context.stroke(
                    branch,
                    with: .color(accents[index].opacity(targetAccents.isEmpty ? 0.42 : 0.92)),
                    style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: target.x - 2.5, y: target.y - 2.5, width: 5, height: 5)),
                    with: .color(accents[index].opacity(targetAccents.isEmpty ? 0.42 : 1))
                )
            }

            context.fill(
                Path(ellipseIn: CGRect(x: source.x - 2.5, y: source.y - 2.5, width: 5, height: 5)),
                with: .color(sourceAccent)
            )
        }
        .frame(width: 42, height: 24)
        .accessibilityHidden(true)
    }
}

private struct RelayContextRelayDeck: View {
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

private struct RelayConfluenceMark: View {
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

private struct RelayDecisionReplayMark: View {
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

private extension RelayDecisionRecoveryWitnessAssessment {
    var labelKey: String {
        switch self {
        case .supportsChange: "SUPPORTS CHANGE"
        case .raisesConcern: "RAISES CONCERN"
        case .inconclusive: "INCONCLUSIVE"
        }
    }

    var icon: String {
        switch self {
        case .supportsChange: "checkmark"
        case .raisesConcern: "exclamationmark"
        case .inconclusive: "questionmark"
        }
    }

    var tint: SwiftUI.Color {
        switch self {
        case .supportsChange: RelayPalette.success
        case .raisesConcern: RelayPalette.danger
        case .inconclusive: RelayPalette.warning
        }
    }
}

private struct RelayDecisionRecoveryWitnessDeck: View {
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

private struct RelayDecisionRecoveryObservationDeck: View {
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

private struct RelayDecisionActionReceiptDeck: View {
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

private struct RelayDecisionLibraryDeck: View {
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

private struct RelayResultArbitrationDecisionDeck: View {
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

private extension View {
    func decisionCard(tint: SwiftUI.Color) -> some View {
        clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(tint.opacity(0.34), lineWidth: 1)
            }
    }
}

private struct RelayResultConfluenceDeck: View {
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

private struct RelayPromptStagingDeck: View {
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

/// 空のワークスペースに表示する復元面。CLI を再起動する前に、
/// 記憶した空間配置を縮小図で確認できる。
private struct RelayDeskRecoveryCard: View {
    let snapshot: RelayDeskSnapshot
    let agents: [RelayAgent]
    let onRestore: () -> Void
    let onForget: () -> Void
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var agentNames: String {
        var seen = Set<String>()
        return snapshot.terminals.compactMap { terminal in
            guard seen.insert(terminal.agentID).inserted else { return nil }
            return agents.first { $0.id == terminal.agentID }?.name ?? terminal.agentID
        }.joined(separator: " + ")
    }

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Text("↺")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                    Text(copy.text("DESK MEMORY"))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                }
                .foregroundStyle(RelayPalette.signal)

                Text(agentNames)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayPalette.text)
                    .lineLimit(1)

                Text(copy.text("⟨N⟩ CLI windows · layout and folders remembered")
                    .replacingOccurrences(of: "⟨N⟩", with: "\(snapshot.terminals.count)"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)

                HStack(spacing: 8) {
                    Button("↻ \(copy.text("RESTORE DESK"))", action: onRestore)
                        .buttonStyle(ConsoleButtonStyle(
                            tint: RelayPalette.signal, prominent: true
                        ))
                    Button(copy.text("FORGET"), action: onForget)
                        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RelayDeskMiniMap(snapshot: snapshot, agents: agents)
                .frame(width: 150, height: 96)
        }
        .padding(18)
        .frame(width: 500)
        .background(RelayPalette.raised.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(RelayPalette.signal.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: SwiftUI.Color.black.opacity(0.24), radius: 18, y: 8)
    }
}

private struct RelayDeskMiniMap: View {
    let snapshot: RelayDeskSnapshot
    let agents: [RelayAgent]

    var body: some View {
        GeometryReader { proxy in
            let frames = snapshot.terminals.map { $0.frame.rect(in: proxy.size) }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(RelayPalette.ink.opacity(0.9))

                Path { path in
                    for (index, frame) in frames.enumerated() {
                        if index == 0 {
                            path.move(to: CGPoint(x: frame.midX, y: frame.midY))
                        } else {
                            path.addLine(to: CGPoint(x: frame.midX, y: frame.midY))
                        }
                    }
                }
                .stroke(
                    RelayPalette.signal.opacity(0.34),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )

                ForEach(Array(snapshot.terminals.enumerated()), id: \.offset) { index, terminal in
                    let frame = frames[index]
                    let agent = agents.first { $0.id == terminal.agentID }
                    let accent = agent?.accent ?? RelayPalette.signal
                    RoundedRectangle(cornerRadius: 4)
                        .fill(accent.opacity(0.13))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(accent.opacity(0.72), lineWidth: 1)
                        }
                        .overlay(alignment: .topLeading) {
                            Text(agent?.monogram ?? String(terminal.agentID.prefix(2)).uppercased())
                                .font(.system(size: 7, weight: .bold, design: .monospaced))
                                .foregroundStyle(accent)
                                .padding(4)
                        }
                        .frame(width: max(frame.width, 24), height: max(frame.height, 18))
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(RelayPalette.line, lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Shared chrome for free-floating workspace windows: drag the header to
/// move, drag any edge or corner to resize, click anywhere to raise,
/// double-click the header (or the ⤢ button) to maximize/restore.
struct RelayFloatingWindow<Title: View, Controls: View, Content: View>: View {
    @ObservedObject var store: RelayTerminalStore
    let windowID: UUID
    let frame: CGRect
    let canvasSize: CGSize
    let focused: Bool
    let accent: SwiftUI.Color
    let closeHelpKey: String
    let onClose: () -> Void
    @ViewBuilder let title: () -> Title
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let content: () -> Content

    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moveBase: CGRect?
    @State private var moveTranslation: CGSize = .zero
    @State private var resizeBase: CGRect?
    @State private var activeResizeHandle: RelayResizeHandle?
    @State private var resizeTranslation: CGSize = .zero

    private var copy: RelayCopy { RelayCopy(language: language) }

    /// Frame shown on screen. Live drags stay in view-local state so only
    /// this window re-renders per mouse event; the store is written once,
    /// on gesture end, with the same pure math (no jump on commit).
    private var displayFrame: CGRect {
        if let moveBase {
            return RelayWindowGeometry.moved(
                moveBase, translation: moveTranslation, in: canvasSize
            )
        }
        if let resizeBase, let activeResizeHandle {
            return RelayWindowGeometry.resized(
                resizeBase, handle: activeResizeHandle,
                translation: resizeTranslation, in: canvasSize
            )
        }
        return frame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle()
                .fill(focused ? accent.opacity(0.6) : RelayPalette.line)
                .frame(height: 1)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RelayPalette.ink)
        }
        .frame(width: displayFrame.width, height: displayFrame.height)
        .background(RelayPalette.ink)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    focused ? accent.opacity(0.5) : RelayPalette.line,
                    lineWidth: 1
                )
        }
        .shadow(
            color: SwiftUI.Color.black.opacity(focused ? 0.45 : 0.28),
            radius: focused ? 18 : 10,
            x: 0, y: 6
        )
        .overlay(alignment: .leading) { edgeGrip(.left) }
        .overlay(alignment: .trailing) { edgeGrip(.right) }
        .overlay(alignment: .top) { edgeGrip(.top) }
        .overlay(alignment: .bottom) { edgeGrip(.bottom) }
        .overlay(alignment: .topLeading) { cornerGrip(.topLeft) }
        .overlay(alignment: .topTrailing) { cornerGrip(.topRight) }
        .overlay(alignment: .bottomLeading) { cornerGrip(.bottomLeft) }
        .overlay(alignment: .bottomTrailing) { cornerGrip(.bottomRight) }
        .offset(x: displayFrame.minX, y: displayFrame.minY)
        .simultaneousGesture(
            TapGesture().onEnded { store.activate(windowID) }
        )
    }

    private var headerDragArea: some View {
        RelayPanelDragArea(
            onBegan: {
                moveBase = frame
                store.activate(windowID)
            },
            onMoved: { translation in
                moveTranslation = translation
            },
            onEnded: { translation in
                if let base = moveBase {
                    store.moveWindow(
                        id: windowID, base: base, translation: translation
                    )
                }
                moveBase = nil
                moveTranslation = .zero
            },
            onDoubleClick: {
                toggleZoom()
            }
        )
    }

    private func toggleZoom() {
        if reduceMotion {
            store.toggleZoom(windowID)
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 1.0)) {
                store.toggleZoom(windowID)
            }
        }
    }

    private func resizeGesture(_ handle: RelayResizeHandle) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if resizeBase == nil {
                    resizeBase = frame
                    activeResizeHandle = handle
                    store.activate(windowID)
                }
                resizeTranslation = value.translation
            }
            .onEnded { value in
                if let base = resizeBase, let handle = activeResizeHandle {
                    store.resizeWindow(
                        id: windowID, base: base,
                        handle: handle, translation: value.translation
                    )
                }
                resizeBase = nil
                activeResizeHandle = nil
                resizeTranslation = .zero
            }
    }

    private func edgeGrip(_ handle: RelayResizeHandle) -> some View {
        let horizontal = handle == .left || handle == .right
        return SwiftUI.Color.clear
            .frame(
                width: horizontal ? 6 : nil,
                height: horizontal ? nil : 6
            )
            .frame(
                maxWidth: horizontal ? nil : .infinity,
                maxHeight: horizontal ? .infinity : nil
            )
            .padding(horizontal ? .vertical : .horizontal, 14)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(resizeGesture(handle))
    }

    private func cornerGrip(_ handle: RelayResizeHandle) -> some View {
        SwiftUI.Color.clear
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    cornerCursor(handle).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(resizeGesture(handle))
    }

    private func cornerCursor(_ handle: RelayResizeHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch handle {
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            default: .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return NSCursor.crosshair
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("⠿")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .help(copy.text("Drag to move"))
                title()
                Spacer(minLength: 8)
            }
            .background(headerDragArea)
            controls()
            Button {
                toggleZoom()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text("Toggle maximize"))
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text(closeHelpKey))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RelayPalette.raised.opacity(focused ? 0.85 : 0.55))
    }
}

private struct RelayTerminalOutputSignal: View {
    let active: Bool
    let needsReview: Bool
    let accent: SwiftUI.Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.relayLanguage) private var language

    private var copy: RelayCopy { RelayCopy(language: language) }

    var body: some View {
        let visible = active || needsReview
        ZStack(alignment: .topTrailing) {
            Image(systemName: "waveform.path")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(accent)
                .opacity(active ? 1 : 0.72)
            if needsReview {
                Circle()
                    .fill(RelayPalette.warning)
                    .frame(width: 4, height: 4)
                    .offset(x: 2, y: -2)
            }
        }
            .scaleEffect(visible ? 1 : 0.82)
            .opacity(visible ? 1 : 0)
            .frame(width: 18, height: 16)
            .background(
                visible
                    ? (needsReview ? RelayPalette.warning : accent).opacity(0.10)
                    : SwiftUI.Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1),
                value: active
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1),
                value: needsReview
            )
            .help(copy.text(
                needsReview ? "Terminal output needs review" : "Receiving terminal output"
            ))
            .allowsHitTesting(false)
            .accessibilityLabel(copy.text(
                needsReview ? "Terminal output needs review" : "Receiving terminal output"
            ))
            .accessibilityHidden(!visible)
    }
}

/// One free-floating CLI window.
private struct RelayTerminalWindow: View {
    @ObservedObject var store: RelayTerminalStore
    @ObservedObject var session: RelayTerminalSession
    let frame: CGRect
    let canvasSize: CGSize
    let focused: Bool
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }

    private var contextRelayHelp: String {
        if store.canBeginContextRelay(from: session) {
            return copy.text("Fork current terminal screen into one or more CLIs")
        }
        if !store.sessions.contains(where: { $0.id != session.id && !$0.exited }) {
            return copy.text("Open another terminal to receive this context.")
        }
        return copy.text("Finish the current prompt flow before relaying context.")
    }

    var body: some View {
        let detail = session.windowTitle.isEmpty
            ? abbreviatedPath(session.cwd)
            : session.windowTitle
        RelayFloatingWindow(
            store: store,
            windowID: session.id,
            frame: frame,
            canvasSize: canvasSize,
            focused: focused,
            accent: session.accent,
            closeHelpKey: "Close terminal",
            onClose: { store.close(session) }
        ) {
            Circle()
                .fill(session.accent)
                .frame(width: 5, height: 5)
            Text(session.agentID.uppercased())
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(session.accent)
            if RelayTerminalContext.sidebarSubtitle(
                cwd: session.cwd,
                detail: detail
            ) != RelayTerminalContext.projectName(session.cwd) {
                Text(detail)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RelayPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text("⌂ \(RelayTerminalContext.projectName(session.cwd))")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(session.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(session.accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(session.accent.opacity(0.24), lineWidth: 1)
                }
                .fixedSize()
                .layoutPriority(1)
                .help(session.cwd)
                .accessibilityLabel(
                    "\(copy.text("PROJECT")): \(RelayTerminalContext.projectName(session.cwd))"
                )
        } controls: {
            Button(action: beginContextRelay) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: session.accent))
            .disabled(!store.canBeginContextRelay(from: session))
            .help(contextRelayHelp)
            .accessibilityLabel(contextRelayHelp)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                RelayTerminalOutputSignal(
                    active: session.isReceivingOutput(at: context.date),
                    needsReview: store.needsOutputReview(session.id),
                    accent: session.accent
                )
            }
            if session.exited {
                Text(copy.text("EXITED"))
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RelayPalette.danger.opacity(0.16))
                    .foregroundStyle(RelayPalette.danger)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Button(copy.text("RESTART")) {
                    session.restart()
                }
                .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.signal))
            }
        } content: {
            RelayTerminalHost(session: session)
                .id(session.generation)
        }
    }

    private func beginContextRelay() {
        let changes = { store.beginContextRelay(from: session) }
        if reduceMotion {
            _ = changes()
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 1.0)) {
                _ = changes()
            }
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

struct RelayTerminalSidebarRow: View {
    @ObservedObject var session: RelayTerminalSession
    var focused = false
    var needsReview = false
    let onClose: () -> Void
    var onZoom: (() -> Void)?
    @Environment(\.relayLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var copy: RelayCopy { RelayCopy(language: language) }

    var body: some View {
        let detail = session.exited
            ? copy.text("EXITED")
            : session.windowTitle.isEmpty ? session.agentID : session.windowTitle
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let active = session.isReceivingOutput(at: context.date)
            RelayPanelSidebarRow(
                glyph: active ? "≈" : needsReview ? "◆" : "▣",
                tint: session.exited
                    ? RelayPalette.danger
                    : needsReview ? RelayPalette.warning : session.accent,
                title: session.agentName,
                subtitle: RelayTerminalContext.sidebarSubtitle(
                    cwd: session.cwd,
                    detail: detail
                ),
                focused: focused,
                closeHelpKey: "Close terminal",
                onFocus: { session.focus() },
                onClose: onClose,
                onZoom: onZoom
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1),
                value: active
            )
            .animation(
                reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1),
                value: needsReview
            )
            .accessibilityValue(copy.text(
                active && needsReview
                    ? "Receiving terminal output, output needs review"
                    : active
                        ? "Receiving terminal output"
                        : needsReview ? "Terminal output needs review" : ""
            ))
            .help(session.cwd)
        }
    }
}
