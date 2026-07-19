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
                .filter { $0.key != "RELAY_GENERIC_SPEC" && $0.key != "RELAY_ACP_SPEC" }
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
    /// Scrollback rows included above the live screen when capturing.
    static let maxHistoryRows = 600
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

/// A one-click daemon arbitration in flight (judge agent working headlessly).
struct RelayDaemonArbitrationState: Equatable {
    let judgeAgentID: String
    let judgeName: String
}

struct RelayResultArbitrationDecision: Identifiable, Codable, Equatable {
    let id: UUID
    let receipt: RelayResultArbitrationReceipt
    let result: RelayResultSnapshot
    /// Parsed fields of a structured daemon verdict. `result.text` always
    /// keeps the judge's raw reply verbatim; these are display-layer extras
    /// and stay nil for terminal arbitrations and legacy records.
    let structuredVerdict: String?
    let structuredRationale: String?
    let structuredConfidence: String?

    init(
        id: UUID = UUID(),
        receipt: RelayResultArbitrationReceipt,
        result: RelayResultSnapshot,
        structuredVerdict: String? = nil,
        structuredRationale: String? = nil,
        structuredConfidence: String? = nil
    ) {
        self.id = id
        self.receipt = receipt
        self.result = result
        self.structuredVerdict = structuredVerdict
        self.structuredRationale = structuredRationale
        self.structuredConfidence = structuredConfidence
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

    /// Builds the sealed decision for a one-click daemon arbitration. The
    /// receipt's target and the result snapshot share one identity — the
    /// archive validator requires `receipt.targetID == result.id`, so two
    /// independent UUIDs would make the checkpoint unsaveable.
    static func daemonDecision(
        confluence: RelayResultConfluence,
        plan: RelayResultArbitrationPlan,
        parentCheckpointID: UUID?,
        judgeName: String,
        reply: String
    ) -> RelayResultArbitrationDecision {
        let parsed = RelayArbitrationVerdict.parse(reply)
        let resultID = UUID()
        return RelayResultArbitrationDecision(
            receipt: RelayResultArbitrationReceipt(
                confluence: confluence,
                plan: plan,
                targetID: resultID,
                parentCheckpointID: parentCheckpointID
            ),
            result: RelayResultSnapshot(
                id: resultID,
                agentName: judgeName,
                projectName: confluence.snapshots.first?.projectName ?? "",
                text: reply
            ),
            structuredVerdict: parsed.isStructured ? parsed.verdict : nil,
            structuredRationale: parsed.isStructured ? parsed.rationale : nil,
            structuredConfidence: parsed.isStructured ? parsed.confidence : nil
        )
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
        // Recent scrollback + the live screen; the sanitizer keeps a
        // UTF-8-safe 48 KiB tail, so old history falls off first.
        let liveTop = max(terminal.buffer.yDisp, 0)
        let firstRow = max(liveTop - RelayTerminalContextRelay.maxHistoryRows, 0)
        let capturedText = terminal.getText(
            start: Position(col: 0, row: firstRow),
            end: Position(
                col: max(terminal.cols, 1),
                row: liveTop + max(terminal.rows, 1)
            )
        )
        return RelayTerminalContextRelay.capture(Data(capturedText.utf8))
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
    /// Windows collapsed into the bottom dock strip.
    @Published private(set) var minimizedWindows: Set<UUID> = []
    /// One-click daemon arbitration in flight, if any.
    @Published private(set) var daemonArbitration: RelayDaemonArbitrationState?
    @Published private(set) var daemonArbitrationFailure: String?
    private var daemonArbitrationTask: Task<Void, Never>?
    private var daemonArbitrationTaskID: String?
    private weak var daemonArbitrationRelay: RelayService?
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

    /// Forks clean daemon results (roundtable / compare answers) into live
    /// terminals through the same context-relay deck.
    @discardableResult
    func beginContextRelay(
        results: [RelayResultSnapshot],
        sourceName: String,
        sourceWindowID: UUID
    ) -> Bool {
        guard contextRelayDraft == nil, resultConfluence == nil,
              !promptStagingVisible, promptReviewPlan == nil else {
            noticeKey = "Finish the current prompt flow before relaying context."
            return false
        }
        guard sessions.contains(where: { !$0.exited }) else {
            noticeKey = "Open another terminal to receive this context."
            return false
        }
        let joined = results
            .map { "【\($0.agentName)】\n\($0.text)" }
            .joined(separator: "\n\n")
        guard let first = results.first,
              let context = RelayTerminalContextRelay.capture(Data(joined.utf8)) else {
            noticeKey = "No terminal text to relay."
            return false
        }
        contextRelayDraft = RelayContextRelayDraft(
            sourceID: sourceWindowID,
            sourceAgentName: sourceName,
            projectName: first.projectName,
            context: context
        )
        noticeKey = nil
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
    /// Bridge: presents structured daemon results (compare members, dialogue
    /// turns) in the confluence panel, feeding the existing arbitration and
    /// decision-archive pipeline without screen scraping.
    func presentResultConfluence(snapshots: [RelayResultSnapshot]) -> Bool {
        let usable = snapshots.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard usable.count >= 2 else {
            noticeKey = "Need at least two non-empty results to arbitrate."
            return false
        }
        resultConfluence = RelayResultConfluence(snapshots: usable)
        resultConfluenceReplayCheckpoint = nil
        promptStagingVisible = false
        noticeKey = nil
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

    /// One-click arbitration: sends the exact arbitration payload to a
    /// daemon agent, waits for its structured verdict, and presents the
    /// decision directly — no live terminal, no manual Return.
    @discardableResult
    func beginDaemonArbitration(
        relay: RelayService, judge: RelayAgent, instruction: String
    ) -> Bool {
        guard daemonArbitration == nil,
              let confluence = resultConfluence,
              let plan = RelayResultArbitration.plan(
                  instruction: instruction, snapshots: confluence.snapshots
              ) else { return false }
        let parentCheckpointID = resultConfluenceReplayCheckpoint?.id
        daemonArbitration = RelayDaemonArbitrationState(
            judgeAgentID: judge.id, judgeName: judge.name
        )
        daemonArbitrationFailure = nil
        daemonArbitrationRelay = relay
        noticeKey = nil
        daemonArbitrationTask = Task { [weak self, weak relay] in
            guard let relay else { return }
            do {
                let taskID = try await relay.startDialogueTask(
                    agentID: judge.id,
                    prompt: RelayArbitrationVerdict.payloadForDaemonJudge(plan.payload)
                )
                self?.daemonArbitrationTaskID = taskID
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 700_000_000)
                    guard let snapshot = relay.taskSnapshot(taskID) else { continue }
                    guard snapshot.status.isTerminal else { continue }
                    if snapshot.status == .completed { break }
                    self?.failDaemonArbitration(
                        snapshot.latestMessage ?? snapshot.status.rawValue
                    )
                    return
                }
                let output = await relay.outputItems(taskID: taskID)
                let reply = ThreadCatalog.lastTurnAnswer(output)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, !reply.isEmpty else {
                    self?.failDaemonArbitration("empty verdict")
                    return
                }
                self.resultArbitrationDecision = RelayResultArbitration.daemonDecision(
                    confluence: confluence,
                    plan: plan,
                    parentCheckpointID: parentCheckpointID,
                    judgeName: judge.name,
                    reply: reply
                )
                self.resultConfluence = nil
                self.resultConfluenceReplayCheckpoint = nil
                self.resultArbitrationDecisionVisible = true
                self.promptStagingVisible = false
                self.daemonArbitration = nil
                self.daemonArbitrationTaskID = nil
            } catch is CancellationError {
                return
            } catch {
                self?.failDaemonArbitration(error.localizedDescription)
            }
        }
        return true
    }

    func cancelDaemonArbitration() {
        daemonArbitrationTask?.cancel()
        daemonArbitrationTask = nil
        if let taskID = daemonArbitrationTaskID {
            let relay = daemonArbitrationRelay
            Task { await relay?.cancelBackgroundTask(taskID) }
        }
        daemonArbitration = nil
        daemonArbitrationTaskID = nil
        daemonArbitrationFailure = nil
    }

    private func failDaemonArbitration(_ message: String) {
        daemonArbitration = nil
        daemonArbitrationTaskID = nil
        daemonArbitrationFailure = message
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
    func saveResultArbitrationDecision(
        baseline: RelayDecisionBaseline? = nil
    ) -> Bool {
        guard let decision = resultArbitrationDecision else { return false }
        if let existing = savedDecisionCheckpoints.first(where: {
            $0.decision.id == decision.id
        }) {
            liveDecisionCheckpointID = existing.id
            return true
        }
        do {
            let checkpoint = try decisionArchive.save(decision, baseline: baseline)
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
        minimizedWindows.remove(id)
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
        minimizedWindows.remove(id)
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

    func minimizeWindow(_ id: UUID) {
        guard zOrder.contains(id) else { return }
        minimizedWindows.insert(id)
        if focusedID == id {
            focusedID = zOrder.last { !minimizedWindows.contains($0) }
        }
    }

    func restoreWindow(_ id: UUID) {
        activate(id)
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
        let moved = RelayWindowGeometry.moved(
            base, translation: translation, in: canvasSize
        )
        windowFrames[id] = RelayWindowGeometry.edgeSnapTarget(moved, in: canvasSize)
            ?? moved
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
        let ids = zOrder.filter { !minimizedWindows.contains($0) }
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
        minimizedWindows.removeAll()
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
    var personas: [RelayPersona] = []
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
                    if !store.minimizedWindows.contains(item.id) {
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
                            personas: personas,
                            frame: store.frame(for: run.id),
                            canvasSize: proxy.size,
                            focused: store.focusedID == run.id
                        )
                    case .compare(let run):
                        RelayCompareWindow(
                            store: store,
                            run: run,
                            agents: agents,
                            personas: personas,
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
            .overlay(alignment: .bottom) { dockStrip }
            .onAppear { store.reportWorkspaceSize(proxy.size) }
            .onChange(of: proxy.size) { _, size in
                store.reportWorkspaceSize(size)
            }
        }
    }

    @ViewBuilder private var dockStrip: some View {
        let minimized = store.zOrder.filter { store.minimizedWindows.contains($0) }
        if !minimized.isEmpty {
            HStack(spacing: 6) {
                ForEach(minimized, id: \.self) { id in
                    if let item = store.orderedItems.first(where: { $0.id == id }) {
                        dockChip(item)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RelayPalette.raised.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(RelayPalette.line, lineWidth: 1)
            }
            .padding(.bottom, 10)
        }
    }

    private func dockChip(_ item: RelayWorkspaceItem) -> some View {
        let (glyph, tint, title): (String, SwiftUI.Color, String) = {
            switch item {
            case .terminal(let session):
                return ("▣", session.exited ? RelayPalette.danger : session.accent, session.agentName)
            case .dialogue:
                return ("⇄", RelayPalette.mix, copy.text("Dialogue"))
            case .compare:
                return ("⋈", RelayPalette.signal, copy.text("COMPARE"))
            case .chain:
                return ("›", RelayPalette.warning, copy.text("CHAIN"))
            case .approvals:
                return ("◇", RelayPalette.warning, copy.text("Approvals"))
            }
        }()
        return Button {
            store.restoreWindow(item.id)
        } label: {
            HStack(spacing: 4) {
                Text(glyph)
                    .foregroundStyle(tint)
                Text(title)
            }
        }
        .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
        .help(copy.text("Restore this window"))
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

struct RelayContextForkRail: View {
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




extension RelayDecisionRecoveryWitnessAssessment {
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






extension View {
    func decisionCard(tint: SwiftUI.Color) -> some View {
        clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(tint.opacity(0.34), lineWidth: 1)
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
                store.minimizeWindow(windowID)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(ConsoleButtonStyle(tint: RelayPalette.muted))
            .help(copy.text("Minimize to the dock"))
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
                .foregroundStyle(RelayPalette.text)
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
