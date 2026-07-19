import Foundation

struct RelayDecisionCheckpoint: Identifiable, Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let savedAt: Date
    let decision: RelayResultArbitrationDecision

    init(
        id: UUID = UUID(),
        savedAt: Date,
        decision: RelayResultArbitrationDecision
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.savedAt = savedAt
        self.decision = decision
    }
}

struct RelayDecisionAnnotation: Identifiable, Codable, Equatable {
    static let currentSchemaVersion = 1
    static let maxTitleCharacters = 80
    static let maxTagCount = 8
    static let maxTagCharacters = 24

    let schemaVersion: Int
    let checkpointID: UUID
    let title: String
    let tags: [String]
    let isPinned: Bool
    let updatedAt: Date

    var id: UUID { checkpointID }

    init?(
        checkpointID: UUID,
        title: String,
        tagsText: String,
        isPinned: Bool,
        updatedAt: Date = Date()
    ) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = Self.parseTags(tagsText)
        guard title.count <= Self.maxTitleCharacters,
              !title.contains(where: \.isNewline),
              tags.count <= Self.maxTagCount,
              tags.allSatisfy({ !$0.isEmpty && $0.count <= Self.maxTagCharacters }) else {
            return nil
        }
        schemaVersion = Self.currentSchemaVersion
        self.checkpointID = checkpointID
        self.title = title
        self.tags = tags
        self.isPinned = isPinned
        self.updatedAt = updatedAt
    }

    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",，、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { tag in
                guard !tag.isEmpty else { return false }
                return seen.insert(normalized(tag)).inserted
            }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}

struct RelayDecisionActionReceipt: Identifiable, Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let checkpointID: UUID
    let capturedAt: Date
    let briefPayload: String
    let decisionOriginalBytes: Int
    let decisionRetainedBytes: Int
    let decisionTruncated: Bool
    let targetID: UUID
    let targetAgentName: String
    let targetProjectName: String
    let editedAfterFill: Bool
    let returnDetected: Bool
    let visibleScreen: String

    var briefPayloadBytes: Int { briefPayload.utf8.count }
    var visibleScreenBytes: Int { visibleScreen.utf8.count }

    init(
        id: UUID = UUID(),
        checkpointID: UUID,
        capturedAt: Date = Date(),
        briefPayload: String,
        decisionOriginalBytes: Int,
        decisionRetainedBytes: Int,
        decisionTruncated: Bool,
        targetID: UUID,
        targetAgentName: String,
        targetProjectName: String,
        editedAfterFill: Bool,
        returnDetected: Bool,
        visibleScreen: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.checkpointID = checkpointID
        self.capturedAt = capturedAt
        self.briefPayload = briefPayload
        self.decisionOriginalBytes = decisionOriginalBytes
        self.decisionRetainedBytes = decisionRetainedBytes
        self.decisionTruncated = decisionTruncated
        self.targetID = targetID
        self.targetAgentName = targetAgentName
        self.targetProjectName = targetProjectName
        self.editedAfterFill = editedAfterFill
        self.returnDetected = returnDetected
        self.visibleScreen = visibleScreen
    }
}

struct RelayDecisionRecoveryObservation: Identifiable, Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let checkpointID: UUID
    let actionReceiptID: UUID
    let capturedAt: Date
    let targetID: UUID
    let targetAgentName: String
    let targetProjectName: String
    let editedAfterFill: Bool
    let returnDetected: Bool
    let visibleScreen: String

    var visibleScreenBytes: Int { visibleScreen.utf8.count }

    init(
        id: UUID = UUID(),
        checkpointID: UUID,
        actionReceiptID: UUID,
        capturedAt: Date = Date(),
        targetID: UUID,
        targetAgentName: String,
        targetProjectName: String,
        editedAfterFill: Bool,
        returnDetected: Bool,
        visibleScreen: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.checkpointID = checkpointID
        self.actionReceiptID = actionReceiptID
        self.capturedAt = capturedAt
        self.targetID = targetID
        self.targetAgentName = targetAgentName
        self.targetProjectName = targetProjectName
        self.editedAfterFill = editedAfterFill
        self.returnDetected = returnDetected
        self.visibleScreen = visibleScreen
    }
}

enum RelayDecisionRecoveryWitnessAssessment: String, Codable, CaseIterable {
    case supportsChange = "supports_change"
    case raisesConcern = "raises_concern"
    case inconclusive
}

struct RelayDecisionRecoveryWitness: Identifiable, Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
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
    let assessment: RelayDecisionRecoveryWitnessAssessment
    let visibleScreen: String

    var handoffPayloadBytes: Int { handoffPayload.utf8.count }
    var visibleScreenBytes: Int { visibleScreen.utf8.count }

    init(
        id: UUID = UUID(),
        checkpointID: UUID,
        actionReceiptID: UUID,
        recoveryObservationID: UUID,
        capturedAt: Date = Date(),
        handoffPayload: String,
        frozenScreenOriginalBytes: Int,
        frozenScreenRetainedBytes: Int,
        frozenScreenTruncated: Bool,
        recoveryScreenOriginalBytes: Int,
        recoveryScreenRetainedBytes: Int,
        recoveryScreenTruncated: Bool,
        addedCount: Int,
        removedCount: Int,
        unchangedCount: Int,
        targetID: UUID,
        targetAgentName: String,
        targetProjectName: String,
        editedAfterFill: Bool,
        returnDetected: Bool,
        assessment: RelayDecisionRecoveryWitnessAssessment,
        visibleScreen: String
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.checkpointID = checkpointID
        self.actionReceiptID = actionReceiptID
        self.recoveryObservationID = recoveryObservationID
        self.capturedAt = capturedAt
        self.handoffPayload = handoffPayload
        self.frozenScreenOriginalBytes = frozenScreenOriginalBytes
        self.frozenScreenRetainedBytes = frozenScreenRetainedBytes
        self.frozenScreenTruncated = frozenScreenTruncated
        self.recoveryScreenOriginalBytes = recoveryScreenOriginalBytes
        self.recoveryScreenRetainedBytes = recoveryScreenRetainedBytes
        self.recoveryScreenTruncated = recoveryScreenTruncated
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.unchangedCount = unchangedCount
        self.targetID = targetID
        self.targetAgentName = targetAgentName
        self.targetProjectName = targetProjectName
        self.editedAfterFill = editedAfterFill
        self.returnDetected = returnDetected
        self.assessment = assessment
        self.visibleScreen = visibleScreen
    }
}

struct RelayDecisionLineage: Equatable {
    static let maxAncestors = 32

    let ancestors: [RelayDecisionCheckpoint]
    let children: [RelayDecisionCheckpoint]
    let missingParentID: UUID?
    let cycleDetected: Bool
    let depthLimited: Bool

    init(
        checkpoint: RelayDecisionCheckpoint,
        checkpoints: [RelayDecisionCheckpoint]
    ) {
        var lookup: [UUID: RelayDecisionCheckpoint] = [:]
        for item in checkpoints {
            lookup[item.id] = item
        }

        var reversedAncestors: [RelayDecisionCheckpoint] = []
        var seen: Set<UUID> = [checkpoint.id]
        var current = checkpoint
        var missingParentID: UUID?
        var cycleDetected = false
        var depthLimited = false

        for _ in 0 ..< Self.maxAncestors {
            guard let parentID = current.decision.receipt.parentCheckpointID else { break }
            guard !seen.contains(parentID) else {
                cycleDetected = true
                break
            }
            guard let parent = lookup[parentID] else {
                missingParentID = parentID
                break
            }
            reversedAncestors.append(parent)
            seen.insert(parentID)
            current = parent
        }
        if !cycleDetected,
           missingParentID == nil,
           reversedAncestors.count == Self.maxAncestors,
           current.decision.receipt.parentCheckpointID != nil {
            depthLimited = true
        }

        ancestors = reversedAncestors.reversed()
        children = checkpoints
            .filter {
                $0.id != checkpoint.id
                    && $0.decision.receipt.parentCheckpointID == checkpoint.id
            }
            .sorted {
                if $0.savedAt == $1.savedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.savedAt > $1.savedAt
            }
        self.missingParentID = missingParentID
        self.cycleDetected = cycleDetected
        self.depthLimited = depthLimited
    }
}

struct RelayDecisionFamily: Equatable {
    static let maxMembers = 64

    let members: [RelayDecisionCheckpoint]
    let limited: Bool

    init(
        checkpoint: RelayDecisionCheckpoint,
        checkpoints: [RelayDecisionCheckpoint]
    ) {
        var lookup: [UUID: RelayDecisionCheckpoint] = [:]
        for item in checkpoints {
            lookup[item.id] = item
        }

        var neighbors: [UUID: Set<UUID>] = [:]
        for item in lookup.values {
            guard let parentID = item.decision.receipt.parentCheckpointID,
                  parentID != item.id,
                  lookup[parentID] != nil else {
                continue
            }
            neighbors[item.id, default: []].insert(parentID)
            neighbors[parentID, default: []].insert(item.id)
        }

        var visited: Set<UUID> = [checkpoint.id]
        var queue = [checkpoint.id]
        var memberIDs: [UUID] = []
        var queueIndex = 0
        var limited = false

        while queueIndex < queue.count {
            let currentID = queue[queueIndex]
            queueIndex += 1
            for neighborID in (neighbors[currentID] ?? []).sorted(by: {
                $0.uuidString < $1.uuidString
            }) where visited.insert(neighborID).inserted {
                guard memberIDs.count < Self.maxMembers else {
                    limited = true
                    continue
                }
                memberIDs.append(neighborID)
                queue.append(neighborID)
            }
        }

        members = memberIDs.compactMap { lookup[$0] }.sorted {
            if $0.savedAt == $1.savedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.savedAt > $1.savedAt
        }
        self.limited = limited
    }
}

enum RelayDecisionSearch {
    static func filter(
        _ checkpoints: [RelayDecisionCheckpoint],
        query: String,
        annotations: [UUID: RelayDecisionAnnotation] = [:]
    ) -> [RelayDecisionCheckpoint] {
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty }
        let matches = terms.isEmpty ? checkpoints : checkpoints.filter { checkpoint in
            let decision = checkpoint.decision
            var fields = [
                checkpoint.id.uuidString,
                decision.result.agentName,
                decision.result.projectName,
                decision.result.text,
            ]
            if let parentID = decision.receipt.parentCheckpointID {
                fields.append(parentID.uuidString)
            }
            for source in decision.receipt.confluence.snapshots {
                fields.append(source.agentName)
                fields.append(source.projectName)
                fields.append(source.text)
            }
            if let annotation = annotations[checkpoint.id] {
                fields.append(annotation.title)
                fields.append(contentsOf: annotation.tags)
            }
            let haystack = normalized(fields.joined(separator: "\n"))
            return terms.allSatisfy(haystack.contains)
        }
        return matches.sorted { lhs, rhs in
            let lhsPinned = annotations[lhs.id]?.isPinned == true
            let rhsPinned = annotations[rhs.id]?.isPinned == true
            if lhsPinned != rhsPinned { return lhsPinned }
            if lhs.savedAt == rhs.savedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.savedAt > rhs.savedAt
        }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}

struct RelayDecisionArchiveContents: Equatable {
    let checkpoints: [RelayDecisionCheckpoint]
    let rejectedCount: Int
    let annotations: [UUID: RelayDecisionAnnotation]
    let rejectedAnnotationCount: Int
    let actionReceipts: [RelayDecisionActionReceipt]
    let rejectedActionReceiptCount: Int
    let recoveryObservations: [RelayDecisionRecoveryObservation]
    let rejectedRecoveryObservationCount: Int
    let recoveryWitnesses: [RelayDecisionRecoveryWitness]
    let rejectedRecoveryWitnessCount: Int
}

enum RelayDecisionArchiveError: Error {
    case invalidCheckpoint
    case checkpointTooLarge
    case invalidAnnotation
    case annotationTooLarge
    case invalidActionReceipt
    case actionReceiptTooLarge
    case invalidRecoveryObservation
    case recoveryObservationTooLarge
    case invalidRecoveryWitness
    case recoveryWitnessTooLarge
}

struct RelayDecisionArchive {
    static let maxCheckpointBytes = 1024 * 1024
    static let maxAnnotationBytes = 16 * 1024
    static let maxActionReceiptBytes = 160 * 1024
    static let maxRecoveryObservationBytes = 96 * 1024
    static let maxRecoveryWitnessBytes = 160 * 1024

    let directoryURL: URL
    private let fileManager: FileManager
    private let trashItem: (URL) throws -> Void

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        trashItem: ((URL) throws -> Void)? = nil
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.trashItem = trashItem ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
    }

    static func live(fileManager: FileManager = .default) -> RelayDecisionArchive {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return RelayDecisionArchive(
            directoryURL: support
                .appendingPathComponent("Relay", isDirectory: true)
                .appendingPathComponent("decisions", isDirectory: true),
            fileManager: fileManager
        )
    }

    func load() throws -> RelayDecisionArchiveContents {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return RelayDecisionArchiveContents(
                checkpoints: [],
                rejectedCount: 0,
                annotations: [:],
                rejectedAnnotationCount: 0,
                actionReceipts: [],
                rejectedActionReceiptCount: 0,
                recoveryObservations: [],
                rejectedRecoveryObservationCount: 0,
                recoveryWitnesses: [],
                rejectedRecoveryWitnessCount: 0
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        var checkpoints: [RelayDecisionCheckpoint] = []
        var rejectedCount = 0
        var seen = Set<UUID>()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let fileSize = values.fileSize,
                      fileSize <= Self.maxCheckpointBytes else {
                    throw RelayDecisionArchiveError.checkpointTooLarge
                }
                let checkpoint = try decoder.decode(
                    RelayDecisionCheckpoint.self,
                    from: Data(contentsOf: url)
                )
                guard url.deletingPathExtension().lastPathComponent == checkpoint.id.uuidString,
                      seen.insert(checkpoint.id).inserted,
                      Self.isValid(checkpoint) else {
                    throw RelayDecisionArchiveError.invalidCheckpoint
                }
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                checkpoints.append(checkpoint)
            } catch {
                rejectedCount += 1
            }
        }

        checkpoints.sort {
            if $0.savedAt == $1.savedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.savedAt > $1.savedAt
        }
        let annotationContents = loadAnnotations(checkpointIDs: Set(checkpoints.map(\.id)))
        let actionReceiptContents = loadActionReceipts(
            checkpointIDs: Set(checkpoints.map(\.id))
        )
        let recoveryObservationContents = loadRecoveryObservations(
            checkpointIDs: Set(checkpoints.map(\.id)),
            actionReceipts: actionReceiptContents.receipts
        )
        let recoveryWitnessContents = loadRecoveryWitnesses(
            checkpointIDs: Set(checkpoints.map(\.id)),
            actionReceipts: actionReceiptContents.receipts,
            recoveryObservations: recoveryObservationContents.observations
        )
        return RelayDecisionArchiveContents(
            checkpoints: checkpoints,
            rejectedCount: rejectedCount,
            annotations: annotationContents.annotations,
            rejectedAnnotationCount: annotationContents.rejectedCount,
            actionReceipts: actionReceiptContents.receipts,
            rejectedActionReceiptCount: actionReceiptContents.rejectedCount,
            recoveryObservations: recoveryObservationContents.observations,
            rejectedRecoveryObservationCount: recoveryObservationContents.rejectedCount,
            recoveryWitnesses: recoveryWitnessContents.witnesses,
            rejectedRecoveryWitnessCount: recoveryWitnessContents.rejectedCount
        )
    }

    func save(
        _ decision: RelayResultArbitrationDecision,
        savedAt: Date = Date()
    ) throws -> RelayDecisionCheckpoint {
        let checkpoint = RelayDecisionCheckpoint(savedAt: savedAt, decision: decision)
        guard Self.isValid(checkpoint) else {
            throw RelayDecisionArchiveError.invalidCheckpoint
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(checkpoint)
        guard data.count <= Self.maxCheckpointBytes else {
            throw RelayDecisionArchiveError.checkpointTooLarge
        }

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
        let destination = fileURL(for: checkpoint)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RelayDecisionArchiveError.invalidCheckpoint
        }
        try data.write(to: destination, options: .atomic)
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return checkpoint
    }

    func saveAnnotation(_ annotation: RelayDecisionAnnotation) throws {
        guard Self.isValid(annotation),
              fileManager.fileExists(atPath: fileURL(for: annotation.checkpointID).path) else {
            throw RelayDecisionArchiveError.invalidAnnotation
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(annotation)
        guard data.count <= Self.maxAnnotationBytes else {
            throw RelayDecisionArchiveError.annotationTooLarge
        }

        try fileManager.createDirectory(
            at: annotationDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: annotationDirectoryURL.path
        )
        let destination = annotationFileURL(for: annotation.checkpointID)
        try data.write(to: destination, options: .atomic)
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func saveActionReceipt(
        _ receipt: RelayDecisionActionReceipt
    ) throws -> RelayDecisionActionReceipt {
        guard Self.isValid(receipt),
              fileManager.fileExists(atPath: fileURL(for: receipt.checkpointID).path) else {
            throw RelayDecisionArchiveError.invalidActionReceipt
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= Self.maxActionReceiptBytes else {
            throw RelayDecisionArchiveError.actionReceiptTooLarge
        }

        try fileManager.createDirectory(
            at: actionReceiptDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: actionReceiptDirectoryURL.path
        )
        let destination = actionReceiptFileURL(for: receipt)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RelayDecisionArchiveError.invalidActionReceipt
        }
        try data.write(to: destination, options: .atomic)
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return receipt
    }

    func saveRecoveryObservation(
        _ observation: RelayDecisionRecoveryObservation
    ) throws -> RelayDecisionRecoveryObservation {
        let actionReceiptURL = actionReceiptDirectoryURL.appendingPathComponent(
            "\(observation.checkpointID.uuidString).\(observation.actionReceiptID.uuidString).action.json"
        )
        guard Self.isValid(observation),
              fileManager.fileExists(atPath: fileURL(for: observation.checkpointID).path),
              fileManager.fileExists(atPath: actionReceiptURL.path) else {
            throw RelayDecisionArchiveError.invalidRecoveryObservation
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(observation)
        guard data.count <= Self.maxRecoveryObservationBytes else {
            throw RelayDecisionArchiveError.recoveryObservationTooLarge
        }

        try fileManager.createDirectory(
            at: recoveryObservationDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: recoveryObservationDirectoryURL.path
        )
        let destination = recoveryObservationFileURL(for: observation)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RelayDecisionArchiveError.invalidRecoveryObservation
        }
        try data.write(to: destination, options: .atomic)
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return observation
    }

    func saveRecoveryWitness(
        _ witness: RelayDecisionRecoveryWitness
    ) throws -> RelayDecisionRecoveryWitness {
        let actionReceiptURL = actionReceiptDirectoryURL.appendingPathComponent(
            "\(witness.checkpointID.uuidString).\(witness.actionReceiptID.uuidString).action.json"
        )
        let recoveryObservationURL = recoveryObservationDirectoryURL.appendingPathComponent(
            "\(witness.checkpointID.uuidString)."
                + "\(witness.actionReceiptID.uuidString)."
                + "\(witness.recoveryObservationID.uuidString).recovery.json"
        )
        guard Self.isValid(witness),
              fileManager.fileExists(atPath: fileURL(for: witness.checkpointID).path),
              fileManager.fileExists(atPath: actionReceiptURL.path),
              fileManager.fileExists(atPath: recoveryObservationURL.path) else {
            throw RelayDecisionArchiveError.invalidRecoveryWitness
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(witness)
        guard data.count <= Self.maxRecoveryWitnessBytes else {
            throw RelayDecisionArchiveError.recoveryWitnessTooLarge
        }

        try fileManager.createDirectory(
            at: recoveryWitnessDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: recoveryWitnessDirectoryURL.path
        )
        let destination = recoveryWitnessFileURL(for: witness)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw RelayDecisionArchiveError.invalidRecoveryWitness
        }
        try data.write(to: destination, options: .atomic)
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        return witness
    }

    func moveToTrash(_ checkpoint: RelayDecisionCheckpoint) throws {
        let url = fileURL(for: checkpoint)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RelayDecisionArchiveError.invalidCheckpoint
        }
        let annotationURL = annotationFileURL(for: checkpoint.id)
        if fileManager.fileExists(atPath: annotationURL.path) {
            try trashItem(annotationURL)
        }
        if fileManager.fileExists(atPath: recoveryWitnessDirectoryURL.path) {
            let prefix = "\(checkpoint.id.uuidString)."
            let urls = try fileManager.contentsOfDirectory(
                at: recoveryWitnessDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasPrefix(prefix) }
            for witnessURL in urls {
                try trashItem(witnessURL)
            }
        }
        if fileManager.fileExists(atPath: recoveryObservationDirectoryURL.path) {
            let prefix = "\(checkpoint.id.uuidString)."
            let urls = try fileManager.contentsOfDirectory(
                at: recoveryObservationDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasPrefix(prefix) }
            for observationURL in urls {
                try trashItem(observationURL)
            }
        }
        if fileManager.fileExists(atPath: actionReceiptDirectoryURL.path) {
            let prefix = "\(checkpoint.id.uuidString)."
            let urls = try fileManager.contentsOfDirectory(
                at: actionReceiptDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasPrefix(prefix) }
            for receiptURL in urls {
                try trashItem(receiptURL)
            }
        }
        try trashItem(url)
    }

    private func fileURL(for checkpoint: RelayDecisionCheckpoint) -> URL {
        fileURL(for: checkpoint.id)
    }

    private func fileURL(for checkpointID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(checkpointID.uuidString).json")
    }

    private var annotationDirectoryURL: URL {
        directoryURL.appendingPathComponent("annotations", isDirectory: true)
    }

    private func annotationFileURL(for checkpointID: UUID) -> URL {
        annotationDirectoryURL.appendingPathComponent(
            "\(checkpointID.uuidString).annotation.json"
        )
    }

    private var actionReceiptDirectoryURL: URL {
        directoryURL.appendingPathComponent("action-receipts", isDirectory: true)
    }

    private func actionReceiptFileURL(for receipt: RelayDecisionActionReceipt) -> URL {
        actionReceiptDirectoryURL.appendingPathComponent(
            "\(receipt.checkpointID.uuidString).\(receipt.id.uuidString).action.json"
        )
    }

    private var recoveryObservationDirectoryURL: URL {
        directoryURL.appendingPathComponent("recovery-observations", isDirectory: true)
    }

    private func recoveryObservationFileURL(
        for observation: RelayDecisionRecoveryObservation
    ) -> URL {
        recoveryObservationDirectoryURL.appendingPathComponent(
            "\(observation.checkpointID.uuidString)."
                + "\(observation.actionReceiptID.uuidString)."
                + "\(observation.id.uuidString).recovery.json"
        )
    }

    private var recoveryWitnessDirectoryURL: URL {
        directoryURL.appendingPathComponent("recovery-witnesses", isDirectory: true)
    }

    private func recoveryWitnessFileURL(
        for witness: RelayDecisionRecoveryWitness
    ) -> URL {
        recoveryWitnessDirectoryURL.appendingPathComponent(
            "\(witness.checkpointID.uuidString)."
                + "\(witness.actionReceiptID.uuidString)."
                + "\(witness.recoveryObservationID.uuidString)."
                + "\(witness.id.uuidString).witness.json"
        )
    }

    private func loadAnnotations(
        checkpointIDs: Set<UUID>
    ) -> (annotations: [UUID: RelayDecisionAnnotation], rejectedCount: Int) {
        guard fileManager.fileExists(atPath: annotationDirectoryURL.path) else {
            return ([:], 0)
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: annotationDirectoryURL.path
            )
            let urls = try fileManager.contentsOfDirectory(
                at: annotationDirectoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            var annotations: [UUID: RelayDecisionAnnotation] = [:]
            var rejectedCount = 0
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for url in urls {
                do {
                    let values = try url.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey]
                    )
                    guard values.isRegularFile == true,
                          let fileSize = values.fileSize,
                          fileSize <= Self.maxAnnotationBytes else {
                        throw RelayDecisionArchiveError.annotationTooLarge
                    }
                    let annotation = try decoder.decode(
                        RelayDecisionAnnotation.self,
                        from: Data(contentsOf: url)
                    )
                    guard url.lastPathComponent
                        == "\(annotation.checkpointID.uuidString).annotation.json",
                        checkpointIDs.contains(annotation.checkpointID),
                        annotations[annotation.checkpointID] == nil,
                        Self.isValid(annotation) else {
                        throw RelayDecisionArchiveError.invalidAnnotation
                    }
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: url.path
                    )
                    annotations[annotation.checkpointID] = annotation
                } catch {
                    rejectedCount += 1
                }
            }
            return (annotations, rejectedCount)
        } catch {
            return ([:], 1)
        }
    }

    private func loadActionReceipts(
        checkpointIDs: Set<UUID>
    ) -> (receipts: [RelayDecisionActionReceipt], rejectedCount: Int) {
        guard fileManager.fileExists(atPath: actionReceiptDirectoryURL.path) else {
            return ([], 0)
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: actionReceiptDirectoryURL.path
            )
            let urls = try fileManager.contentsOfDirectory(
                at: actionReceiptDirectoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            var receipts: [RelayDecisionActionReceipt] = []
            var rejectedCount = 0
            var seen = Set<UUID>()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for url in urls {
                do {
                    let values = try url.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey]
                    )
                    guard values.isRegularFile == true,
                          let fileSize = values.fileSize,
                          fileSize <= Self.maxActionReceiptBytes else {
                        throw RelayDecisionArchiveError.actionReceiptTooLarge
                    }
                    let receipt = try decoder.decode(
                        RelayDecisionActionReceipt.self,
                        from: Data(contentsOf: url)
                    )
                    guard url.lastPathComponent
                        == "\(receipt.checkpointID.uuidString).\(receipt.id.uuidString).action.json",
                        checkpointIDs.contains(receipt.checkpointID),
                        seen.insert(receipt.id).inserted,
                        Self.isValid(receipt) else {
                        throw RelayDecisionArchiveError.invalidActionReceipt
                    }
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: url.path
                    )
                    receipts.append(receipt)
                } catch {
                    rejectedCount += 1
                }
            }
            receipts.sort {
                if $0.capturedAt == $1.capturedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.capturedAt > $1.capturedAt
            }
            return (receipts, rejectedCount)
        } catch {
            return ([], 1)
        }
    }

    private func loadRecoveryObservations(
        checkpointIDs: Set<UUID>,
        actionReceipts: [RelayDecisionActionReceipt]
    ) -> (observations: [RelayDecisionRecoveryObservation], rejectedCount: Int) {
        guard fileManager.fileExists(atPath: recoveryObservationDirectoryURL.path) else {
            return ([], 0)
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: recoveryObservationDirectoryURL.path
            )
            let urls = try fileManager.contentsOfDirectory(
                at: recoveryObservationDirectoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            let receiptCheckpoints = Dictionary(
                uniqueKeysWithValues: actionReceipts.map { ($0.id, $0.checkpointID) }
            )
            var observations: [RelayDecisionRecoveryObservation] = []
            var rejectedCount = 0
            var seen = Set<UUID>()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for url in urls {
                do {
                    let values = try url.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey]
                    )
                    guard values.isRegularFile == true,
                          let fileSize = values.fileSize,
                          fileSize <= Self.maxRecoveryObservationBytes else {
                        throw RelayDecisionArchiveError.recoveryObservationTooLarge
                    }
                    let observation = try decoder.decode(
                        RelayDecisionRecoveryObservation.self,
                        from: Data(contentsOf: url)
                    )
                    let expectedName = "\(observation.checkpointID.uuidString)."
                        + "\(observation.actionReceiptID.uuidString)."
                        + "\(observation.id.uuidString).recovery.json"
                    guard url.lastPathComponent == expectedName,
                          checkpointIDs.contains(observation.checkpointID),
                          receiptCheckpoints[observation.actionReceiptID]
                            == observation.checkpointID,
                          seen.insert(observation.id).inserted,
                          Self.isValid(observation) else {
                        throw RelayDecisionArchiveError.invalidRecoveryObservation
                    }
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: url.path
                    )
                    observations.append(observation)
                } catch {
                    rejectedCount += 1
                }
            }
            observations.sort {
                if $0.capturedAt == $1.capturedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.capturedAt > $1.capturedAt
            }
            return (observations, rejectedCount)
        } catch {
            return ([], 1)
        }
    }

    private func loadRecoveryWitnesses(
        checkpointIDs: Set<UUID>,
        actionReceipts: [RelayDecisionActionReceipt],
        recoveryObservations: [RelayDecisionRecoveryObservation]
    ) -> (witnesses: [RelayDecisionRecoveryWitness], rejectedCount: Int) {
        guard fileManager.fileExists(atPath: recoveryWitnessDirectoryURL.path) else {
            return ([], 0)
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: recoveryWitnessDirectoryURL.path
            )
            let urls = try fileManager.contentsOfDirectory(
                at: recoveryWitnessDirectoryURL,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            let receiptCheckpoints = Dictionary(
                uniqueKeysWithValues: actionReceipts.map { ($0.id, $0.checkpointID) }
            )
            let observationLineage = Dictionary(
                uniqueKeysWithValues: recoveryObservations.map {
                    ($0.id, ($0.checkpointID, $0.actionReceiptID))
                }
            )
            var witnesses: [RelayDecisionRecoveryWitness] = []
            var rejectedCount = 0
            var seen = Set<UUID>()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for url in urls {
                do {
                    let values = try url.resourceValues(
                        forKeys: [.fileSizeKey, .isRegularFileKey]
                    )
                    guard values.isRegularFile == true,
                          let fileSize = values.fileSize,
                          fileSize <= Self.maxRecoveryWitnessBytes else {
                        throw RelayDecisionArchiveError.recoveryWitnessTooLarge
                    }
                    let witness = try decoder.decode(
                        RelayDecisionRecoveryWitness.self,
                        from: Data(contentsOf: url)
                    )
                    let expectedName = "\(witness.checkpointID.uuidString)."
                        + "\(witness.actionReceiptID.uuidString)."
                        + "\(witness.recoveryObservationID.uuidString)."
                        + "\(witness.id.uuidString).witness.json"
                    guard url.lastPathComponent == expectedName,
                          checkpointIDs.contains(witness.checkpointID),
                          receiptCheckpoints[witness.actionReceiptID]
                            == witness.checkpointID,
                          observationLineage[witness.recoveryObservationID]?.0
                            == witness.checkpointID,
                          observationLineage[witness.recoveryObservationID]?.1
                            == witness.actionReceiptID,
                          seen.insert(witness.id).inserted,
                          Self.isValid(witness) else {
                        throw RelayDecisionArchiveError.invalidRecoveryWitness
                    }
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: url.path
                    )
                    witnesses.append(witness)
                } catch {
                    rejectedCount += 1
                }
            }
            witnesses.sort {
                if $0.capturedAt == $1.capturedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.capturedAt > $1.capturedAt
            }
            return (witnesses, rejectedCount)
        } catch {
            return ([], 1)
        }
    }

    private static func isValid(_ checkpoint: RelayDecisionCheckpoint) -> Bool {
        let decision = checkpoint.decision
        let snapshots = decision.receipt.confluence.snapshots
        let sources = decision.receipt.plan.sources
        return checkpoint.schemaVersion == RelayDecisionCheckpoint.currentSchemaVersion
            && snapshots.count >= 2
            && snapshots.map(\.id) == sources.map(\.id)
            && sources.allSatisfy {
                $0.originalBytes >= 0
                    && $0.retainedBytes >= 0
                    && $0.retainedBytes <= $0.originalBytes
            }
            && !decision.receipt.plan.payload.isEmpty
            && decision.receipt.plan.payloadBytes <= RelayPromptStaging.maxBytes
            && decision.receipt.targetID == decision.result.id
            && decision.receipt.parentCheckpointID != checkpoint.id
            && !decision.result.text.isEmpty
    }

    private static func isValid(_ annotation: RelayDecisionAnnotation) -> Bool {
        annotation.schemaVersion == RelayDecisionAnnotation.currentSchemaVersion
            && annotation.title.count <= RelayDecisionAnnotation.maxTitleCharacters
            && !annotation.title.contains(where: \.isNewline)
            && annotation.tags.count <= RelayDecisionAnnotation.maxTagCount
            && annotation.tags.allSatisfy {
                !$0.isEmpty
                    && $0.count <= RelayDecisionAnnotation.maxTagCharacters
                    && !$0.contains(where: \.isNewline)
            }
            && RelayDecisionAnnotation.parseTags(annotation.tags.joined(separator: ","))
                == annotation.tags
    }

    private static func isValid(_ receipt: RelayDecisionActionReceipt) -> Bool {
        receipt.schemaVersion == RelayDecisionActionReceipt.currentSchemaVersion
            && receipt.returnDetected
            && !receipt.briefPayload.isEmpty
            && receipt.briefPayloadBytes <= RelayPromptStaging.maxBytes
            && receipt.decisionOriginalBytes >= 0
            && receipt.decisionRetainedBytes >= 0
            && receipt.decisionRetainedBytes <= receipt.decisionOriginalBytes
            && !receipt.targetAgentName.isEmpty
            && !receipt.targetProjectName.isEmpty
            && !receipt.visibleScreen.isEmpty
            && receipt.visibleScreenBytes <= RelayTerminalContextRelay.maxCaptureBytes
    }

    private static func isValid(_ observation: RelayDecisionRecoveryObservation) -> Bool {
        observation.schemaVersion == RelayDecisionRecoveryObservation.currentSchemaVersion
            && observation.returnDetected
            && !observation.targetAgentName.isEmpty
            && !observation.targetProjectName.isEmpty
            && !observation.visibleScreen.isEmpty
            && observation.visibleScreenBytes <= RelayTerminalContextRelay.maxCaptureBytes
    }

    private static func isValid(_ witness: RelayDecisionRecoveryWitness) -> Bool {
        witness.schemaVersion == RelayDecisionRecoveryWitness.currentSchemaVersion
            && witness.returnDetected
            && !witness.handoffPayload.isEmpty
            && witness.handoffPayloadBytes <= RelayPromptStaging.maxBytes
            && witness.frozenScreenOriginalBytes >= 0
            && witness.frozenScreenRetainedBytes >= 0
            && witness.frozenScreenRetainedBytes <= witness.frozenScreenOriginalBytes
            && witness.recoveryScreenOriginalBytes >= 0
            && witness.recoveryScreenRetainedBytes >= 0
            && witness.recoveryScreenRetainedBytes <= witness.recoveryScreenOriginalBytes
            && witness.addedCount >= 0
            && witness.removedCount >= 0
            && witness.unchangedCount >= 0
            && !witness.targetAgentName.isEmpty
            && !witness.targetProjectName.isEmpty
            && !witness.visibleScreen.isEmpty
            && witness.visibleScreenBytes <= RelayTerminalContextRelay.maxCaptureBytes
    }
}
