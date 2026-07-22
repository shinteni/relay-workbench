import Foundation
import Testing
@testable import RelayGUI

struct RelayTerminalTests {
    @Test
    func decisionDeltaAlignsParentAndDerivedResultsWithoutGuessing() {
        let delta = RelayDecisionDelta(
            parent: "shared\nold evidence\nunchanged tail",
            derived: "shared\nnew evidence\nunchanged tail\nnew conclusion"
        )

        #expect(delta.rows.map(\.kind) == [
            .unchanged,
            .removed,
            .added,
            .unchanged,
            .added,
        ])
        #expect(delta.rows.map(\.parentLineNumber) == [1, 2, nil, 3, nil])
        #expect(delta.rows.map(\.derivedLineNumber) == [1, nil, 2, 3, 4])
        #expect(delta.addedCount == 2)
        #expect(delta.removedCount == 1)
        #expect(delta.unchangedCount == 2)
        #expect(!delta.parentTruncated)
        #expect(!delta.derivedTruncated)
    }

    @Test
    func decisionDeltaKeepsOnlyABoundedUTF8SafeTail() {
        let prefix = String(repeating: "earlier父\n", count: RelayDecisionDelta.maxLinesPerSide)
        let parent = prefix + "PARENT_TAIL"
        let derived = prefix + "DERIVED_TAIL"
        let delta = RelayDecisionDelta(parent: parent, derived: derived)

        #expect(delta.parentTruncated)
        #expect(delta.derivedTruncated)
        #expect(delta.rows.contains { $0.text == "PARENT_TAIL" && $0.kind == .removed })
        #expect(delta.rows.contains { $0.text == "DERIVED_TAIL" && $0.kind == .added })
        #expect(delta.rows.first(where: { $0.text == "PARENT_TAIL" })?.parentLineNumber == 301)
        #expect(delta.rows.first(where: { $0.text == "DERIVED_TAIL" })?.derivedLineNumber == 301)
        #expect(delta.parentBytes <= RelayDecisionDelta.maxBytesPerSide)
        #expect(delta.derivedBytes <= RelayDecisionDelta.maxBytesPerSide)
        #expect(delta.rows.count <= RelayDecisionDelta.maxLinesPerSide * 2)
    }

    @Test
    func decisionLineageNavigatesBranchesAndStopsAtMissingParentsOrCycles() throws {
        let rootID = UUID()
        let childID = UUID()
        let grandchildID = UUID()
        let siblingID = UUID()
        let root = try checkpoint(id: rootID, parentID: nil, savedAt: 1, marker: "ROOT")
        let child = try checkpoint(id: childID, parentID: rootID, savedAt: 2, marker: "CHILD")
        let grandchild = try checkpoint(
            id: grandchildID, parentID: childID, savedAt: 3, marker: "GRANDCHILD"
        )
        let sibling = try checkpoint(
            id: siblingID, parentID: rootID, savedAt: 4, marker: "SIBLING"
        )
        let checkpoints = [grandchild, root, sibling, child]

        let grandchildLineage = RelayDecisionLineage(
            checkpoint: grandchild,
            checkpoints: checkpoints
        )
        #expect(grandchildLineage.ancestors.map(\.id) == [rootID, childID])
        #expect(grandchildLineage.children.isEmpty)
        #expect(grandchildLineage.missingParentID == nil)
        #expect(!grandchildLineage.cycleDetected)

        let rootLineage = RelayDecisionLineage(checkpoint: root, checkpoints: checkpoints)
        #expect(rootLineage.ancestors.isEmpty)
        #expect(rootLineage.children.map(\.id) == [siblingID, childID])

        let missingID = UUID()
        let orphan = try checkpoint(
            id: UUID(), parentID: missingID, savedAt: 5, marker: "ORPHAN"
        )
        let orphanLineage = RelayDecisionLineage(checkpoint: orphan, checkpoints: [orphan])
        #expect(orphanLineage.ancestors.isEmpty)
        #expect(orphanLineage.missingParentID == missingID)
        #expect(!orphanLineage.cycleDetected)

        let cycleAID = UUID()
        let cycleBID = UUID()
        let cycleA = try checkpoint(
            id: cycleAID, parentID: cycleBID, savedAt: 6, marker: "CYCLE A"
        )
        let cycleB = try checkpoint(
            id: cycleBID, parentID: cycleAID, savedAt: 7, marker: "CYCLE B"
        )
        let cycleLineage = RelayDecisionLineage(
            checkpoint: cycleA,
            checkpoints: [cycleA, cycleB]
        )
        #expect(cycleLineage.ancestors.map(\.id) == [cycleBID])
        #expect(cycleLineage.cycleDetected)
        #expect(cycleLineage.missingParentID == nil)
    }

    @Test
    func decisionFamilyFindsConnectedBranchesAndCapsTraversal() throws {
        let rootID = UUID()
        let childAID = UUID()
        let currentID = UUID()
        let childBID = UUID()
        let grandchildBID = UUID()
        let root = try checkpoint(id: rootID, parentID: nil, savedAt: 1, marker: "ROOT")
        let childA = try checkpoint(
            id: childAID, parentID: rootID, savedAt: 2, marker: "CHILD A"
        )
        let current = try checkpoint(
            id: currentID, parentID: childAID, savedAt: 3, marker: "CURRENT"
        )
        let childB = try checkpoint(
            id: childBID, parentID: rootID, savedAt: 4, marker: "CHILD B"
        )
        let grandchildB = try checkpoint(
            id: grandchildBID, parentID: childBID, savedAt: 5, marker: "GRANDCHILD B"
        )
        let unrelated = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 6, marker: "UNRELATED"
        )

        let family = RelayDecisionFamily(
            checkpoint: current,
            checkpoints: [unrelated, childB, current, root, grandchildB, childA]
        )
        #expect(family.members.map(\.id) == [grandchildBID, childBID, childAID, rootID])
        #expect(!family.limited)

        let cycleAID = UUID()
        let cycleBID = UUID()
        let cycleA = try checkpoint(
            id: cycleAID, parentID: cycleBID, savedAt: 7, marker: "CYCLE A"
        )
        let cycleB = try checkpoint(
            id: cycleBID, parentID: cycleAID, savedAt: 8, marker: "CYCLE B"
        )
        let cycleFamily = RelayDecisionFamily(
            checkpoint: cycleA,
            checkpoints: [cycleA, cycleB]
        )
        #expect(cycleFamily.members.map(\.id) == [cycleBID])
        #expect(!cycleFamily.limited)

        var chain = [root]
        var parentID = rootID
        for index in 1 ... RelayDecisionFamily.maxMembers + 1 {
            let node = try checkpoint(
                id: UUID(),
                parentID: parentID,
                savedAt: TimeInterval(index + 10),
                marker: "CHAIN \(index)"
            )
            chain.append(node)
            parentID = node.id
        }
        let limitedFamily = RelayDecisionFamily(checkpoint: root, checkpoints: chain)
        #expect(limitedFamily.members.count == RelayDecisionFamily.maxMembers)
        #expect(limitedFamily.limited)
    }

    @Test
    func decisionSearchMatchesAllTermsAcrossPrivateCheckpointContent() throws {
        let matching = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 1, marker: "Résumé FINAL_日本"
        )
        let other = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 2, marker: "Other conclusion"
        )
        let checkpoints = [other, matching]

        #expect(RelayDecisionSearch.filter(checkpoints, query: "").map(\.id)
            == checkpoints.map(\.id))
        #expect(RelayDecisionSearch.filter(checkpoints, query: "claude FINAL").map(\.id)
            == [matching.id])
        #expect(RelayDecisionSearch.filter(checkpoints, query: "resume 日本").map(\.id)
            == [matching.id])
        #expect(RelayDecisionSearch.filter(checkpoints, query: "ＲＥＬＡＹ final").map(\.id)
            == [matching.id])
        #expect(RelayDecisionSearch.filter(checkpoints, query: "missing").isEmpty)
        #expect(RelayDecisionSearch.filter(
            checkpoints,
            query: String(matching.id.uuidString.prefix(8))
        ).map(\.id) == [matching.id])
    }

    @Test
    func decisionAnnotationsStaySeparateAndDriveSearchAndPinnedOrder() throws {
        let older = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 1, marker: "Older conclusion"
        )
        let newer = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 2, marker: "Newer conclusion"
        )
        let annotation = try #require(RelayDecisionAnnotation(
            checkpointID: older.id,
            title: "  Release gate  ",
            tagsText: "Ship，Privacy, ship、レビュー",
            isPinned: true,
            updatedAt: Date(timeIntervalSince1970: 3)
        ))

        #expect(annotation.title == "Release gate")
        #expect(annotation.tags == ["Ship", "Privacy", "レビュー"])
        #expect(RelayDecisionSearch.filter(
            [newer, older],
            query: "release privacy",
            annotations: [older.id: annotation]
        ).map(\.id) == [older.id])
        #expect(RelayDecisionSearch.filter(
            [newer, older],
            query: "",
            annotations: [older.id: annotation]
        ).map(\.id) == [older.id, newer.id])
        #expect(RelayDecisionAnnotation(
            checkpointID: older.id,
            title: String(repeating: "x", count: RelayDecisionAnnotation.maxTitleCharacters + 1),
            tagsText: "",
            isPinned: false
        ) == nil)
    }

    @MainActor
    @Test
    func decisionSearchSurvivesOpeningAResultUntilLibraryCloses() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RelayDecisionSearchTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let archive = RelayDecisionArchive(directoryURL: root)
        let source = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 1, marker: "SEARCH RESULT"
        )
        let saved = try archive.save(source.decision)
        let suiteName = "RelayDecisionSearchTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RelayTerminalStore(defaults: defaults, decisionArchive: archive)

        store.showDecisionLibrary()
        store.decisionLibraryQuery = "search result"
        store.openDecisionCheckpoint(saved)
        store.returnFromDecisionCheckpoint()
        #expect(store.decisionLibraryQuery == "search result")

        store.closeDecisionLibrary()
        #expect(store.decisionLibraryQuery.isEmpty)
    }

    @MainActor
    @Test
    func decisionLabelsPersistAcrossStoreRestartsWithoutChangingEvidence() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RelayDecisionLabelTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let archive = RelayDecisionArchive(directoryURL: root)
        let source = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 1, marker: "IMMUTABLE EVIDENCE"
        )
        let saved = try archive.save(source.decision)
        let evidenceURL = root.appendingPathComponent("\(saved.id.uuidString).json")
        let originalEvidence = try Data(contentsOf: evidenceURL)
        let suiteName = "RelayDecisionLabelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RelayTerminalStore(defaults: defaults, decisionArchive: archive)

        #expect(store.updateDecisionAnnotation(
            for: saved,
            title: "Release decision",
            tagsText: "ship, privacy",
            isPinned: true
        ))
        #expect(store.decisionAnnotation(for: saved)?.title == "Release decision")
        #expect(store.decisionAnnotation(for: saved)?.tags == ["ship", "privacy"])
        #expect(store.decisionAnnotation(for: saved)?.isPinned == true)
        #expect(try Data(contentsOf: evidenceURL) == originalEvidence)

        let restored = RelayTerminalStore(defaults: defaults, decisionArchive: archive)
        #expect(restored.decisionAnnotation(for: saved) == store.decisionAnnotation(for: saved))
        #expect(restored.toggleDecisionPin(saved))
        #expect(restored.decisionAnnotation(for: saved)?.isPinned == false)
        #expect(try Data(contentsOf: evidenceURL) == originalEvidence)

        #expect(!restored.updateDecisionAnnotation(
            for: saved,
            title: String(
                repeating: "x",
                count: RelayDecisionAnnotation.maxTitleCharacters + 1
            ),
            tagsText: "",
            isPinned: false
        ))
        #expect(restored.noticeKey == "Decision label is too long.")
    }

    @Test
    func decisionArchivePersistsPrivateFilesAndMovesThemToTrash() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RelayDecisionArchiveTests-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("decisions", isDirectory: true)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let archive = RelayDecisionArchive(
            directoryURL: directory,
            trashItem: { url in
                try fileManager.moveItem(
                    at: url,
                    to: trash.appendingPathComponent(url.lastPathComponent)
                )
            }
        )
        let sourceA = RelayResultSnapshot(
            id: UUID(), agentName: "Codex", projectName: "relay", text: "A evidence"
        )
        let sourceB = RelayResultSnapshot(
            id: UUID(), agentName: "Claude", projectName: "relay", text: "B evidence"
        )
        let result = RelayResultSnapshot(
            id: UUID(), agentName: "Grok", projectName: "relay", text: "Final decision"
        )
        let plan = try #require(RelayResultArbitration.plan(
            instruction: "Resolve with evidence.", snapshots: [sourceA, sourceB]
        ))
        let decision = RelayResultArbitrationDecision(
            receipt: RelayResultArbitrationReceipt(
                confluence: RelayResultConfluence(snapshots: [sourceA, sourceB]),
                plan: plan,
                targetID: result.id
            ),
            result: result
        )
        let savedAt = Date(timeIntervalSince1970: 1_784_400_000)

        let checkpoint = try archive.save(decision, savedAt: savedAt)
        #expect(checkpoint.savedAt == savedAt)
        #expect(checkpoint.decision == decision)
        let fileURL = directory.appendingPathComponent("\(checkpoint.id.uuidString).json")
        #expect(fileManager.fileExists(atPath: fileURL.path))
        let directoryAttributes = try fileManager.attributesOfItem(atPath: directory.path)
        let fileAttributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let checkpointData = try Data(contentsOf: fileURL)
        let annotation = try #require(RelayDecisionAnnotation(
            checkpointID: checkpoint.id,
            title: "Ship decision",
            tagsText: "release, private",
            isPinned: true,
            updatedAt: savedAt
        ))
        try archive.saveAnnotation(annotation)
        let annotationURL = directory
            .appendingPathComponent("annotations", isDirectory: true)
            .appendingPathComponent("\(checkpoint.id.uuidString).annotation.json")
        #expect(fileManager.fileExists(atPath: annotationURL.path))
        #expect(try Data(contentsOf: fileURL) == checkpointData)
        let annotationAttributes = try fileManager.attributesOfItem(atPath: annotationURL.path)
        #expect((annotationAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let actionReceipt = RelayDecisionActionReceipt(
            checkpointID: checkpoint.id,
            capturedAt: savedAt,
            briefPayload: "Exact filled decision brief",
            decisionOriginalBytes: 14,
            decisionRetainedBytes: 14,
            decisionTruncated: false,
            targetID: result.id,
            targetAgentName: result.agentName,
            targetProjectName: result.projectName,
            editedAfterFill: true,
            returnDetected: true,
            visibleScreen: "Current visible screen"
        )
        _ = try archive.saveActionReceipt(actionReceipt)
        let actionReceiptDirectory = directory
            .appendingPathComponent("action-receipts", isDirectory: true)
        let actionReceiptURL = actionReceiptDirectory.appendingPathComponent(
            "\(checkpoint.id.uuidString).\(actionReceipt.id.uuidString).action.json"
        )
        #expect(fileManager.fileExists(atPath: actionReceiptURL.path))
        #expect(try Data(contentsOf: fileURL) == checkpointData)
        let actionReceiptDirectoryAttributes = try fileManager.attributesOfItem(
            atPath: actionReceiptDirectory.path
        )
        let actionReceiptAttributes = try fileManager.attributesOfItem(
            atPath: actionReceiptURL.path
        )
        let actionReceiptData = try Data(contentsOf: actionReceiptURL)
        #expect((actionReceiptDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((actionReceiptAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let recoveryObservation = RelayDecisionRecoveryObservation(
            checkpointID: checkpoint.id,
            actionReceiptID: actionReceipt.id,
            capturedAt: savedAt.addingTimeInterval(1),
            targetID: UUID(),
            targetAgentName: "Ollama",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            visibleScreen: "Current visible screen\nRecovered visible screen"
        )
        _ = try archive.saveRecoveryObservation(recoveryObservation)
        let recoveryObservationDirectory = directory
            .appendingPathComponent("recovery-observations", isDirectory: true)
        let recoveryObservationURL = recoveryObservationDirectory.appendingPathComponent(
            "\(checkpoint.id.uuidString).\(actionReceipt.id.uuidString)."
                + "\(recoveryObservation.id.uuidString).recovery.json"
        )
        #expect(fileManager.fileExists(atPath: recoveryObservationURL.path))
        #expect(try Data(contentsOf: fileURL) == checkpointData)
        #expect(try Data(contentsOf: actionReceiptURL) == actionReceiptData)
        let recoveryDirectoryAttributes = try fileManager.attributesOfItem(
            atPath: recoveryObservationDirectory.path
        )
        let recoveryAttributes = try fileManager.attributesOfItem(
            atPath: recoveryObservationURL.path
        )
        #expect((recoveryDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((recoveryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let recoveryWitness = RelayDecisionRecoveryWitness(
            checkpointID: checkpoint.id,
            actionReceiptID: actionReceipt.id,
            recoveryObservationID: recoveryObservation.id,
            capturedAt: savedAt.addingTimeInterval(2),
            handoffPayload: "Exact recovery handoff payload",
            frozenScreenOriginalBytes: 22,
            frozenScreenRetainedBytes: 22,
            frozenScreenTruncated: false,
            recoveryScreenOriginalBytes: 47,
            recoveryScreenRetainedBytes: 47,
            recoveryScreenTruncated: false,
            addedCount: 1,
            removedCount: 0,
            unchangedCount: 1,
            targetID: UUID(),
            targetAgentName: "Claude",
            targetProjectName: "relay",
            editedAfterFill: true,
            returnDetected: true,
            assessment: .raisesConcern,
            visibleScreen: "Independent review found one concern"
        )
        _ = try archive.saveRecoveryWitness(recoveryWitness)
        let recoveryWitnessDirectory = directory
            .appendingPathComponent("recovery-witnesses", isDirectory: true)
        let recoveryWitnessURL = recoveryWitnessDirectory.appendingPathComponent(
            "\(checkpoint.id.uuidString).\(actionReceipt.id.uuidString)."
                + "\(recoveryObservation.id.uuidString)."
                + "\(recoveryWitness.id.uuidString).witness.json"
        )
        #expect(fileManager.fileExists(atPath: recoveryWitnessURL.path))
        #expect(try Data(contentsOf: fileURL) == checkpointData)
        #expect(try Data(contentsOf: actionReceiptURL) == actionReceiptData)
        let recoveryObservationData = try Data(contentsOf: recoveryObservationURL)
        #expect(try Data(contentsOf: recoveryObservationURL) == recoveryObservationData)
        let recoveryWitnessDirectoryAttributes = try fileManager.attributesOfItem(
            atPath: recoveryWitnessDirectory.path
        )
        let recoveryWitnessAttributes = try fileManager.attributesOfItem(
            atPath: recoveryWitnessURL.path
        )
        #expect((recoveryWitnessDirectoryAttributes[.posixPermissions] as? NSNumber)?.intValue
            == 0o700)
        #expect((recoveryWitnessAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("broken.json")
        )
        let selfParentID = UUID()
        let selfParentDecision = RelayResultArbitrationDecision(
            receipt: RelayResultArbitrationReceipt(
                confluence: decision.receipt.confluence,
                plan: decision.receipt.plan,
                targetID: result.id,
                parentCheckpointID: selfParentID
            ),
            result: result
        )
        let selfParent = RelayDecisionCheckpoint(
            id: selfParentID,
            savedAt: savedAt,
            decision: selfParentDecision
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(selfParent).write(
            to: directory.appendingPathComponent("\(selfParentID.uuidString).json")
        )
        try Data("not-json".utf8).write(
            to: directory
                .appendingPathComponent("annotations", isDirectory: true)
                .appendingPathComponent("broken.annotation.json")
        )
        try Data("not-json".utf8).write(
            to: actionReceiptDirectory.appendingPathComponent("broken.action.json")
        )
        let orphan = RelayDecisionActionReceipt(
            checkpointID: UUID(),
            capturedAt: savedAt,
            briefPayload: "Orphan brief",
            decisionOriginalBytes: 6,
            decisionRetainedBytes: 6,
            decisionTruncated: false,
            targetID: result.id,
            targetAgentName: result.agentName,
            targetProjectName: result.projectName,
            editedAfterFill: false,
            returnDetected: true,
            visibleScreen: "Orphan screen"
        )
        try encoder.encode(orphan).write(
            to: actionReceiptDirectory.appendingPathComponent(
                "\(orphan.checkpointID.uuidString).\(orphan.id.uuidString).action.json"
            )
        )
        try Data(repeating: 0, count: RelayDecisionArchive.maxActionReceiptBytes + 1).write(
            to: actionReceiptDirectory.appendingPathComponent("oversized.action.json")
        )
        try Data("not-json".utf8).write(
            to: recoveryObservationDirectory.appendingPathComponent("broken.recovery.json")
        )
        let orphanObservation = RelayDecisionRecoveryObservation(
            checkpointID: checkpoint.id,
            actionReceiptID: UUID(),
            capturedAt: savedAt,
            targetID: UUID(),
            targetAgentName: "Codex",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            visibleScreen: "Orphan recovery screen"
        )
        try encoder.encode(orphanObservation).write(
            to: recoveryObservationDirectory.appendingPathComponent(
                "\(orphanObservation.checkpointID.uuidString)."
                    + "\(orphanObservation.actionReceiptID.uuidString)."
                    + "\(orphanObservation.id.uuidString).recovery.json"
            )
        )
        try Data(
            repeating: 0,
            count: RelayDecisionArchive.maxRecoveryObservationBytes + 1
        ).write(
            to: recoveryObservationDirectory.appendingPathComponent("oversized.recovery.json")
        )
        try Data("not-json".utf8).write(
            to: recoveryWitnessDirectory.appendingPathComponent("broken.witness.json")
        )
        let orphanWitness = RelayDecisionRecoveryWitness(
            checkpointID: checkpoint.id,
            actionReceiptID: actionReceipt.id,
            recoveryObservationID: UUID(),
            capturedAt: savedAt,
            handoffPayload: "Orphan handoff payload",
            frozenScreenOriginalBytes: 10,
            frozenScreenRetainedBytes: 10,
            frozenScreenTruncated: false,
            recoveryScreenOriginalBytes: 10,
            recoveryScreenRetainedBytes: 10,
            recoveryScreenTruncated: false,
            addedCount: 0,
            removedCount: 0,
            unchangedCount: 1,
            targetID: UUID(),
            targetAgentName: "Codex",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            assessment: .inconclusive,
            visibleScreen: "Orphan witness screen"
        )
        try encoder.encode(orphanWitness).write(
            to: recoveryWitnessDirectory.appendingPathComponent(
                "\(orphanWitness.checkpointID.uuidString)."
                    + "\(orphanWitness.actionReceiptID.uuidString)."
                    + "\(orphanWitness.recoveryObservationID.uuidString)."
                    + "\(orphanWitness.id.uuidString).witness.json"
            )
        )
        try Data(
            repeating: 0,
            count: RelayDecisionArchive.maxRecoveryWitnessBytes + 1
        ).write(
            to: recoveryWitnessDirectory.appendingPathComponent("oversized.witness.json")
        )
        let loaded = try archive.load()
        #expect(loaded.checkpoints == [checkpoint])
        #expect(loaded.rejectedCount == 2)
        #expect(loaded.annotations == [checkpoint.id: annotation])
        #expect(loaded.rejectedAnnotationCount == 1)
        #expect(loaded.actionReceipts == [actionReceipt])
        #expect(loaded.rejectedActionReceiptCount == 3)
        #expect(loaded.recoveryObservations == [recoveryObservation])
        #expect(loaded.rejectedRecoveryObservationCount == 3)
        #expect(loaded.recoveryWitnesses == [recoveryWitness])
        #expect(loaded.rejectedRecoveryWitnessCount == 3)

        try archive.moveToTrash(checkpoint)
        #expect(!fileManager.fileExists(atPath: fileURL.path))
        #expect(!fileManager.fileExists(atPath: annotationURL.path))
        #expect(!fileManager.fileExists(atPath: actionReceiptURL.path))
        #expect(!fileManager.fileExists(atPath: recoveryObservationURL.path))
        #expect(!fileManager.fileExists(atPath: recoveryWitnessURL.path))
        #expect(fileManager.fileExists(
            atPath: trash.appendingPathComponent(fileURL.lastPathComponent).path
        ))
        #expect(fileManager.fileExists(
            atPath: trash.appendingPathComponent(annotationURL.lastPathComponent).path
        ))
        #expect(fileManager.fileExists(
            atPath: trash.appendingPathComponent(actionReceiptURL.lastPathComponent).path
        ))
        #expect(fileManager.fileExists(
            atPath: trash.appendingPathComponent(recoveryObservationURL.lastPathComponent).path
        ))
        #expect(fileManager.fileExists(
            atPath: trash.appendingPathComponent(recoveryWitnessURL.lastPathComponent).path
        ))
    }

    @MainActor
    @Test
    func savedDecisionCheckpointReplaysIntoAnImmutableDerivedDecision() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RelayDecisionReplayTests-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("decisions", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let archive = RelayDecisionArchive(directoryURL: directory)

        let sourceA = RelayResultSnapshot(
            id: UUID(), agentName: "Codex", projectName: "relay", text: "PARENT EVIDENCE A"
        )
        let sourceB = RelayResultSnapshot(
            id: UUID(), agentName: "Claude", projectName: "relay", text: "PARENT EVIDENCE B"
        )
        let parentResult = RelayResultSnapshot(
            id: UUID(), agentName: "Grok", projectName: "relay", text: "PARENT DECISION"
        )
        let parentPlan = try #require(RelayResultArbitration.plan(
            instruction: "Resolve the parent evidence.",
            snapshots: [sourceA, sourceB]
        ))
        let parentDecision = RelayResultArbitrationDecision(
            receipt: RelayResultArbitrationReceipt(
                confluence: RelayResultConfluence(snapshots: [sourceA, sourceB]),
                plan: parentPlan,
                targetID: parentResult.id
            ),
            result: parentResult
        )
        let parent = try archive.save(
            parentDecision,
            savedAt: Date(timeIntervalSince1970: 1_784_400_000)
        )
        let parentURL = directory.appendingPathComponent("\(parent.id.uuidString).json")
        let originalParentData = try Data(contentsOf: parentURL)

        let suiteName = "RelayTerminalTests.decisionReplay.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RelayTerminalStore(defaults: defaults, decisionArchive: archive)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        store.open(
            agent: agent(
                id: "ollama",
                environment: ["RELAY_OLLAMA_PATH": "/bin/cat"]
            ),
            cwd: NSTemporaryDirectory()
        ) { _ in "gemma4:latest" }
        let target = try #require(store.sessions.first)
        target.terminalView.feed(text: "\u{1B}[?2004h")

        store.openDecisionCheckpoint(parent)
        #expect(store.canBeginDecisionCheckpointReplay)
        #expect(store.beginDecisionCheckpointReplay(parent))
        #expect(store.selectedDecisionCheckpoint == nil)
        #expect(store.resultConfluence == parentDecision.receipt.confluence)
        #expect(store.resultConfluenceReplayCheckpointID == parent.id)
        #expect(!store.refreshResultConfluence())
        #expect(store.noticeKey == "Saved checkpoint sources cannot be recaptured.")

        store.returnFromResultConfluence()
        #expect(store.resultConfluence == nil)
        #expect(store.resultConfluenceReplayCheckpointID == nil)
        #expect(store.selectedDecisionCheckpoint == parent)

        #expect(store.beginDecisionCheckpointReplay(parent))
        #expect(store.completeResultArbitration(
            instruction: "Re-evaluate the parent evidence with a fresh arbiter.",
            targetID: target.id
        ))
        #expect(store.resultConfluenceReplayCheckpointID == nil)
        #expect(store.resultArbitrationReceipt?.parentCheckpointID == parent.id)
        guard var review = store.promptReviewPlan else {
            Issue.record("replayed arbitration should enter one-target review")
            return
        }
        _ = review.confirmCurrent(availableIDs: [target.id])
        store.updatePromptReview(review)
        target.terminalView.feed(text: "DERIVED DECISION 64\n")
        #expect(store.captureResultArbitrationDecision())
        #expect(store.resultArbitrationDecision?.receipt.parentCheckpointID == parent.id)
        #expect(store.saveResultArbitrationDecision())

        let contents = try archive.load()
        #expect(contents.checkpoints.count == 2)
        let derived = try #require(contents.checkpoints.first(where: { $0.id != parent.id }))
        #expect(derived.decision.receipt.parentCheckpointID == parent.id)
        #expect(derived.decision.result.text.contains("DERIVED DECISION 64"))
        #expect(try Data(contentsOf: parentURL) == originalParentData)

        store.close(target)
    }

    @MainActor
    @Test
    func savedDecisionBriefFillsOneReadyCLIAndReturnsWithoutRunning() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RelayDecisionBriefTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let archive = RelayDecisionArchive(directoryURL: root)
        let source = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 1_784_400_000,
            marker: "SHIP THE VERIFIED LOCAL FLOW"
        )
        let saved = try archive.save(source.decision, savedAt: source.savedAt)
        let annotation = try #require(RelayDecisionAnnotation(
            checkpointID: saved.id,
            title: "Release gate",
            tagsText: "local, review",
            isPinned: true
        ))
        try archive.saveAnnotation(annotation)
        let suiteName = "RelayTerminalTests.decisionBrief.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RelayTerminalStore(defaults: defaults, decisionArchive: archive)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        store.open(
            agent: agent(
                id: "ollama",
                environment: ["RELAY_OLLAMA_PATH": "/bin/cat"]
            ),
            cwd: NSTemporaryDirectory()
        ) { _ in "gemma4:latest" }
        let target = try #require(store.sessions.first)
        store.openDecisionCheckpoint(saved)

        #expect(!store.completeDecisionBrief(
            checkpoint: saved,
            instruction: "Implement only the verified next step.",
            targetID: target.id
        ))
        #expect(store.selectedDecisionCheckpoint == saved)
        target.terminalView.feed(text: "\u{1B}[?2004h")
        let baseline = target.inputSnapshot

        #expect(store.completeDecisionBrief(
            checkpoint: saved,
            instruction: "Implement only the verified next step.",
            targetID: target.id
        ))
        #expect(store.selectedDecisionCheckpoint == nil)
        #expect(store.promptStagingVisible)
        #expect(store.promptReviewPlan?.targets.map(\.id) == [target.id])
        #expect(store.decisionBriefCheckpoint == saved)
        #expect(store.decisionBriefPlan?.payload.contains("Release gate") == true)
        #expect(store.decisionBriefPlan?.payload.contains("SHIP THE VERIFIED LOCAL FLOW") == true)
        #expect(target.inputSnapshot == baseline)

        #expect(store.returnFromDecisionBriefReview())
        #expect(store.selectedDecisionCheckpoint == saved)
        #expect(store.promptReviewPlan == nil)
        #expect(!store.promptStagingVisible)
        #expect(store.decisionBriefCheckpoint == nil)
        #expect(store.decisionBriefPlan == nil)
        #expect(target.inputSnapshot == baseline)

        #expect(store.completeDecisionBrief(
            checkpoint: saved,
            instruction: "",
            targetID: target.id
        ))
        store.clearPromptReview()
        #expect(store.decisionBriefCheckpoint == nil)
        #expect(store.decisionBriefPlan == nil)

        store.openDecisionCheckpoint(saved)
        #expect(store.completeDecisionBrief(
            checkpoint: saved,
            instruction: "",
            targetID: target.id
        ))
        store.close(target)
        #expect(store.selectedDecisionCheckpoint == saved)
        #expect(store.promptReviewPlan == nil)
        #expect(store.decisionBriefCheckpoint == nil)
    }

    @MainActor
    @Test
    func decisionActionReceiptRequiresHumanReturnAndPreservesExactEvidence() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RelayDecisionActionReceiptTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let archive = RelayDecisionArchive(directoryURL: root)
        let source = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 1_784_400_000,
            marker: "VERIFIED ACTION SOURCE 71"
        )
        let saved = try archive.save(source.decision, savedAt: source.savedAt)
        let checkpointURL = root.appendingPathComponent("\(saved.id.uuidString).json")
        let checkpointData = try Data(contentsOf: checkpointURL)
        let suiteName = "RelayTerminalTests.actionReceipt.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RelayTerminalStore(defaults: defaults, decisionArchive: archive)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        store.open(
            agent: agent(
                id: "ollama",
                environment: ["RELAY_OLLAMA_PATH": "/bin/cat"]
            ),
            cwd: NSTemporaryDirectory()
        ) { _ in "gemma4:latest" }
        let target = try #require(store.sessions.first)
        target.terminalView.feed(text: "\u{1B}[?2004h")
        store.openDecisionCheckpoint(saved)
        #expect(store.completeDecisionBrief(
            checkpoint: saved,
            instruction: "Apply only the verified action.",
            targetID: target.id
        ))
        let brief = try #require(store.decisionBriefPlan)

        #expect(!store.canCaptureDecisionActionReceipt())
        #expect(!store.captureDecisionActionReceipt())
        #expect(store.noticeKey == "Return must be detected before capturing an action receipt.")
        #expect(store.decisionActionReceiptDraft == nil)

        target.terminalView.feed(text: "CURRENT VISIBLE OUTCOME 71\n")
        target.recordUserInput(.edited)
        target.recordUserInput(.returnKey)
        let inputAfterReturn = target.inputSnapshot
        #expect(store.canCaptureDecisionActionReceipt())
        let capturedAt = Date(timeIntervalSince1970: 1_784_400_071)
        #expect(store.captureDecisionActionReceipt(capturedAt: capturedAt))
        let draft = try #require(store.decisionActionReceiptDraft)
        #expect(draft.checkpointID == saved.id)
        #expect(draft.capturedAt == capturedAt)
        #expect(draft.briefPayload == brief.payload)
        #expect(draft.editedAfterFill)
        #expect(draft.returnDetected)
        #expect(draft.visibleScreen.contains("CURRENT VISIBLE OUTCOME 71"))
        #expect(target.inputSnapshot == inputAfterReturn)
        #expect(store.activeDecisionActionReceipt == draft)
        #expect(!store.activeDecisionActionReceiptIsSaved)
        #expect(!store.promptStagingVisible)
        #expect(try archive.load().actionReceipts.isEmpty)

        store.returnFromDecisionActionReceipt()
        #expect(store.promptStagingVisible)
        #expect(store.decisionActionReceiptDraft == draft)
        #expect(target.inputSnapshot == inputAfterReturn)
        store.showDecisionActionReceiptDraft()
        #expect(store.activeDecisionActionReceipt == draft)

        #expect(store.saveDecisionActionReceipt())
        let persisted = try #require(store.selectedDecisionActionReceipt)
        #expect(persisted == draft)
        #expect(store.activeDecisionActionReceiptIsSaved)
        #expect(try Data(contentsOf: checkpointURL) == checkpointData)
        let restored = RelayTerminalStore(defaults: defaults, decisionArchive: archive)
        #expect(restored.savedDecisionActionReceipts == [persisted])
        #expect(restored.decisionActionReceipts(for: saved) == [persisted])

        store.returnFromDecisionActionReceipt()
        #expect(store.activeDecisionActionReceipt == nil)
        #expect(store.selectedDecisionCheckpoint == saved)
        #expect(store.promptReviewPlan == nil)
        #expect(store.decisionBriefPlan == nil)
        store.openDecisionActionReceipt(persisted)
        #expect(store.activeDecisionActionReceipt == persisted)
        #expect(store.activeDecisionActionReceiptIsSaved)
        store.returnFromDecisionActionReceipt()
        #expect(store.selectedDecisionCheckpoint == saved)

        store.close(target)
    }

    @MainActor
    @Test
    func savedActionReceiptRecoversIntoOneReadyCLIWithoutRunning() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RelayActionRecoveryTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let archive = RelayDecisionArchive(directoryURL: root)
        let source = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 1_784_400_000,
            marker: "RECOVERY SOURCE 72"
        )
        let saved = try archive.save(source.decision, savedAt: source.savedAt)
        let receipt = RelayDecisionActionReceipt(
            checkpointID: saved.id,
            capturedAt: Date(timeIntervalSince1970: 1_784_400_072),
            briefPayload: "[Relay decision brief]\nRECOVER ACTION 72",
            decisionOriginalBytes: 17,
            decisionRetainedBytes: 17,
            decisionTruncated: false,
            targetID: UUID(),
            targetAgentName: "Codex",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            visibleScreen: "FROZEN RECOVERY SCREEN 72"
        )
        let persisted = try archive.saveActionReceipt(receipt)
        let suiteName = "RelayTerminalTests.actionRecovery.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RelayTerminalStore(defaults: defaults, decisionArchive: archive)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        store.open(
            agent: agent(
                id: "ollama",
                environment: ["RELAY_OLLAMA_PATH": "/bin/cat"]
            ),
            cwd: NSTemporaryDirectory()
        ) { _ in "gemma4:latest" }
        let target = try #require(store.sessions.first)
        let loadedReceipt = try #require(store.savedDecisionActionReceipts.first)
        #expect(loadedReceipt == persisted)
        store.openDecisionActionReceipt(loadedReceipt)

        #expect(!store.completeDecisionActionRecovery(
            receipt: loadedReceipt,
            instruction: "Continue from the frozen state.",
            targetID: target.id
        ))
        #expect(store.noticeKey == "Confirm one live target is at an input prompt before recovering.")
        #expect(store.activeDecisionActionReceipt == loadedReceipt)

        target.terminalView.feed(text: "\u{1B}[?2004h")
        let baseline = target.inputSnapshot
        #expect(store.completeDecisionActionRecovery(
            receipt: loadedReceipt,
            instruction: "Continue from the frozen state.",
            targetID: target.id
        ))
        let plan = try #require(store.decisionActionRecoveryPlan)
        #expect(plan.payload.contains("Continue from the frozen state."))
        #expect(plan.payload.contains(saved.id.uuidString))
        #expect(plan.payload.contains(loadedReceipt.id.uuidString))
        #expect(plan.payload.contains("RECOVER ACTION 72"))
        #expect(plan.payload.contains("FROZEN RECOVERY SCREEN 72"))
        #expect(store.decisionActionRecoveryReceipt == loadedReceipt)
        #expect(store.promptReviewPlan?.targets.map(\.id) == [target.id])
        #expect(store.promptStagingVisible)
        #expect(store.activeDecisionActionReceipt == nil)
        #expect(target.inputSnapshot == baseline)

        #expect(store.returnFromDecisionActionRecoveryReview())
        #expect(store.activeDecisionActionReceipt == loadedReceipt)
        #expect(store.activeDecisionActionReceiptIsSaved)
        #expect(store.decisionActionRecoveryReceipt == nil)
        #expect(store.decisionActionRecoveryPlan == nil)
        #expect(store.promptReviewPlan == nil)
        #expect(!store.promptStagingVisible)
        #expect(target.inputSnapshot == baseline)

        #expect(store.completeDecisionActionRecovery(
            receipt: loadedReceipt,
            instruction: "",
            targetID: target.id
        ))
        store.close(target)
        #expect(store.sessions.isEmpty)
        #expect(store.activeDecisionActionReceipt == loadedReceipt)
        #expect(store.decisionActionRecoveryReceipt == nil)
        #expect(store.promptReviewPlan == nil)
    }

    @MainActor
    @Test
    func recoveryChangeHandoffSharesTheUTF8BudgetAndKeepsExactLineage() throws {
        let checkpointID = UUID()
        let receipt = RelayDecisionActionReceipt(
            checkpointID: checkpointID,
            capturedAt: Date(timeIntervalSince1970: 1_784_400_073),
            briefPayload: "[Relay decision brief]\nHANDOFF 74",
            decisionOriginalBytes: 10,
            decisionRetainedBytes: 10,
            decisionTruncated: false,
            targetID: UUID(),
            targetAgentName: "Codex",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            visibleScreen: String(repeating: "F", count: 40_000) + "\nFROZEN 74"
        )
        let observation = RelayDecisionRecoveryObservation(
            checkpointID: checkpointID,
            actionReceiptID: receipt.id,
            capturedAt: Date(timeIntervalSince1970: 1_784_400_074),
            targetID: UUID(),
            targetAgentName: "Ollama",
            targetProjectName: "relay",
            editedAfterFill: true,
            returnDetected: true,
            visibleScreen: String(repeating: "恢", count: 13_000) + "\nRECOVERY 74"
        )

        let plan = try #require(RelayDecisionRecoveryHandoff.plan(
            receipt: receipt,
            observation: observation,
            instruction: "Review the recorded change."
        ))
        #expect(plan.payloadBytes <= RelayPromptStaging.maxBytes)
        #expect(plan.payload.contains(checkpointID.uuidString))
        #expect(plan.payload.contains(receipt.id.uuidString))
        #expect(plan.payload.contains(observation.id.uuidString))
        #expect(plan.payload.contains("Review the recorded change."))
        #expect(plan.payload.contains("User Return: detected; Relay did not send it"))
        #expect(plan.payload.contains("visible screen change is not proof"))
        #expect(plan.frozenScreenTruncated)
        #expect(plan.recoveryScreenTruncated)
        #expect(plan.frozenScreenRetainedBytes < plan.frozenScreenOriginalBytes)
        #expect(plan.recoveryScreenRetainedBytes < plan.recoveryScreenOriginalBytes)
        #expect(plan.payload.contains("earlier frozen receipt screen truncated"))
        #expect(plan.payload.contains("earlier recovery screen truncated"))
        #expect(plan.addedCount > 0)
        #expect(plan.removedCount > 0)
    }

    @Test
    func recoveryWitnessKeepsExactHandoffAndUserAssessment() throws {
        let draft = RelayDecisionRecoveryWitnessDraft(
            id: UUID(),
            checkpointID: UUID(),
            actionReceiptID: UUID(),
            recoveryObservationID: UUID(),
            capturedAt: Date(timeIntervalSince1970: 1_784_400_075),
            handoffPayload: "[Relay recovery change handoff]\nEXACT PAYLOAD 75",
            frozenScreenOriginalBytes: 1_098,
            frozenScreenRetainedBytes: 1_098,
            frozenScreenTruncated: false,
            recoveryScreenOriginalBytes: 912,
            recoveryScreenRetainedBytes: 912,
            recoveryScreenTruncated: false,
            addedCount: 25,
            removedCount: 25,
            unchangedCount: 2,
            targetID: UUID(),
            targetAgentName: "Claude",
            targetProjectName: "relay",
            editedAfterFill: true,
            returnDetected: true,
            visibleScreen: "Independent witness screen"
        )

        let witness = draft.witness(assessment: .raisesConcern)
        #expect(witness.id == draft.id)
        #expect(witness.handoffPayload == draft.handoffPayload)
        #expect(witness.handoffPayloadBytes == draft.handoffPayloadBytes)
        #expect(witness.frozenScreenRetainedBytes == 1_098)
        #expect(witness.recoveryScreenRetainedBytes == 912)
        #expect(witness.addedCount == 25)
        #expect(witness.removedCount == 25)
        #expect(witness.unchangedCount == 2)
        #expect(witness.assessment == .raisesConcern)
        #expect(witness.visibleScreen == draft.visibleScreen)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(
            RelayDecisionRecoveryWitness.self,
            from: encoder.encode(witness)
        ) == witness)
    }

    @Test
    func recoveryWitnessComparisonRequiresTwoRecordsFromTheSameObservation() throws {
        let checkpointID = UUID()
        let actionReceiptID = UUID()
        let recoveryObservationID = UUID()
        let left = RelayDecisionRecoveryWitness(
            checkpointID: checkpointID,
            actionReceiptID: actionReceiptID,
            recoveryObservationID: recoveryObservationID,
            capturedAt: Date(timeIntervalSince1970: 1_784_400_076),
            handoffPayload: "EXACT HANDOFF 76",
            frozenScreenOriginalBytes: 1_098,
            frozenScreenRetainedBytes: 1_098,
            frozenScreenTruncated: false,
            recoveryScreenOriginalBytes: 912,
            recoveryScreenRetainedBytes: 912,
            recoveryScreenTruncated: false,
            addedCount: 25,
            removedCount: 25,
            unchangedCount: 2,
            targetID: UUID(),
            targetAgentName: "Claude",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            assessment: .supportsChange,
            visibleScreen: "shared line\nleft-only line"
        )
        let right = RelayDecisionRecoveryWitness(
            checkpointID: checkpointID,
            actionReceiptID: actionReceiptID,
            recoveryObservationID: recoveryObservationID,
            capturedAt: Date(timeIntervalSince1970: 1_784_400_077),
            handoffPayload: "EXACT HANDOFF 76",
            frozenScreenOriginalBytes: 1_098,
            frozenScreenRetainedBytes: 1_098,
            frozenScreenTruncated: false,
            recoveryScreenOriginalBytes: 912,
            recoveryScreenRetainedBytes: 912,
            recoveryScreenTruncated: false,
            addedCount: 25,
            removedCount: 25,
            unchangedCount: 2,
            targetID: UUID(),
            targetAgentName: "Codex",
            targetProjectName: "relay",
            editedAfterFill: true,
            returnDetected: true,
            assessment: .raisesConcern,
            visibleScreen: "shared line\nright-only line"
        )

        let comparison = try #require(RelayDecisionRecoveryWitnessComparison(
            left: left,
            right: right
        ))
        #expect(comparison.handoffPayloadsMatch)
        #expect(!comparison.assessmentsMatch)
        #expect(comparison.screenDelta.addedCount == 1)
        #expect(comparison.screenDelta.removedCount == 1)
        #expect(comparison.screenDelta.unchangedCount == 1)
        #expect(RelayDecisionRecoveryWitnessComparison(left: left, right: left) == nil)

        let differentPayload = RelayDecisionRecoveryWitness(
            checkpointID: checkpointID,
            actionReceiptID: actionReceiptID,
            recoveryObservationID: recoveryObservationID,
            handoffPayload: "DIFFERENT HANDOFF 76",
            frozenScreenOriginalBytes: 1_098,
            frozenScreenRetainedBytes: 1_098,
            frozenScreenTruncated: false,
            recoveryScreenOriginalBytes: 912,
            recoveryScreenRetainedBytes: 912,
            recoveryScreenTruncated: false,
            addedCount: 25,
            removedCount: 25,
            unchangedCount: 2,
            targetID: UUID(),
            targetAgentName: "Ollama",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            assessment: .inconclusive,
            visibleScreen: "different payload"
        )
        let changedHandoff = try #require(RelayDecisionRecoveryWitnessComparison(
            left: left,
            right: differentPayload
        ))
        #expect(!changedHandoff.handoffPayloadsMatch)

        let otherObservation = RelayDecisionRecoveryWitness(
            checkpointID: checkpointID,
            actionReceiptID: actionReceiptID,
            recoveryObservationID: UUID(),
            handoffPayload: "DIFFERENT HANDOFF 76",
            frozenScreenOriginalBytes: 1_098,
            frozenScreenRetainedBytes: 1_098,
            frozenScreenTruncated: false,
            recoveryScreenOriginalBytes: 912,
            recoveryScreenRetainedBytes: 912,
            recoveryScreenTruncated: false,
            addedCount: 25,
            removedCount: 25,
            unchangedCount: 2,
            targetID: UUID(),
            targetAgentName: "Ollama",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            assessment: .inconclusive,
            visibleScreen: "other observation"
        )
        #expect(RelayDecisionRecoveryWitnessComparison(
            left: left,
            right: otherObservation
        ) == nil)
    }

    @MainActor
    @Test
    func recoveryChangeRequiresHumanReturnAndPreservesParentEvidence() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("RelayRecoveryChangeTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let archive = RelayDecisionArchive(directoryURL: root)
        let source = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 1_784_400_000,
            marker: "RECOVERY CHANGE SOURCE 73"
        )
        let saved = try archive.save(source.decision, savedAt: source.savedAt)
        let receipt = RelayDecisionActionReceipt(
            checkpointID: saved.id,
            capturedAt: Date(timeIntervalSince1970: 1_784_400_072),
            briefPayload: "[Relay decision brief]\nRECOVER ACTION 73",
            decisionOriginalBytes: 17,
            decisionRetainedBytes: 17,
            decisionTruncated: false,
            targetID: UUID(),
            targetAgentName: "Codex",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            visibleScreen: "shared line\nfrozen result"
        )
        let persistedReceipt = try archive.saveActionReceipt(receipt)
        let checkpointURL = root.appendingPathComponent("\(saved.id.uuidString).json")
        let receiptURL = root
            .appendingPathComponent("action-receipts", isDirectory: true)
            .appendingPathComponent(
                "\(saved.id.uuidString).\(persistedReceipt.id.uuidString).action.json"
            )
        let checkpointData = try Data(contentsOf: checkpointURL)
        let receiptData = try Data(contentsOf: receiptURL)
        let suiteName = "RelayTerminalTests.recoveryChange.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RelayTerminalStore(defaults: defaults, decisionArchive: archive)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        store.open(
            agent: agent(
                id: "ollama",
                environment: ["RELAY_OLLAMA_PATH": "/bin/cat"]
            ),
            cwd: NSTemporaryDirectory()
        ) { _ in "gemma4:latest" }
        let target = try #require(store.sessions.first)
        target.terminalView.feed(text: "\u{1B}[?2004h")
        let loadedReceipt = try #require(store.savedDecisionActionReceipts.first)
        store.openDecisionActionReceipt(loadedReceipt)
        #expect(store.completeDecisionActionRecovery(
            receipt: loadedReceipt,
            instruction: "Continue with visible evidence.",
            targetID: target.id
        ))

        #expect(!store.canCaptureDecisionRecoveryObservation())
        #expect(!store.captureDecisionRecoveryObservation())
        #expect(store.noticeKey
            == "Return must be detected before capturing a recovery change.")
        target.terminalView.feed(text: "shared line\nrecovered result\nnew evidence\n")
        target.recordUserInput(.edited)
        target.recordUserInput(.returnKey)
        let inputAfterReturn = target.inputSnapshot
        #expect(store.canCaptureDecisionRecoveryObservation())
        let capturedAt = Date(timeIntervalSince1970: 1_784_400_073)
        #expect(store.captureDecisionRecoveryObservation(capturedAt: capturedAt))
        let draft = try #require(store.decisionRecoveryObservationDraft)
        #expect(draft.checkpointID == saved.id)
        #expect(draft.actionReceiptID == loadedReceipt.id)
        #expect(draft.capturedAt == capturedAt)
        #expect(draft.editedAfterFill)
        #expect(draft.returnDetected)
        #expect(draft.visibleScreen.contains("recovered result"))
        #expect(target.inputSnapshot == inputAfterReturn)
        #expect(store.activeDecisionRecoveryObservation == draft)
        #expect(!store.activeDecisionRecoveryObservationIsSaved)
        #expect(try archive.load().recoveryObservations.isEmpty)
        let delta = RelayDecisionDelta(
            parent: loadedReceipt.visibleScreen,
            derived: draft.visibleScreen
        )
        #expect(delta.addedCount > 0)
        #expect(delta.removedCount > 0)

        store.returnFromDecisionRecoveryObservation()
        #expect(store.promptStagingVisible)
        #expect(store.decisionRecoveryObservationDraft == draft)
        #expect(target.inputSnapshot == inputAfterReturn)
        store.showDecisionRecoveryObservationDraft()
        #expect(store.activeDecisionRecoveryObservation == draft)

        #expect(store.saveDecisionRecoveryObservation())
        let persisted = try #require(store.selectedDecisionRecoveryObservation)
        #expect(persisted == draft)
        #expect(store.activeDecisionRecoveryObservationIsSaved)
        #expect(try Data(contentsOf: checkpointURL) == checkpointData)
        #expect(try Data(contentsOf: receiptURL) == receiptData)

        let handoffBaseline = target.inputSnapshot
        #expect(store.completeDecisionRecoveryHandoff(
            receipt: loadedReceipt,
            observation: persisted,
            instruction: "Review the exact visible change.",
            targetID: target.id
        ))
        let handoff = try #require(store.decisionRecoveryHandoffPlan)
        #expect(handoff.payload.contains("Review the exact visible change."))
        #expect(handoff.payload.contains(saved.id.uuidString))
        #expect(handoff.payload.contains(loadedReceipt.id.uuidString))
        #expect(handoff.payload.contains(persisted.id.uuidString))
        #expect(store.decisionRecoveryHandoffReceipt == loadedReceipt)
        #expect(store.decisionRecoveryHandoffObservation == persisted)
        #expect(store.promptReviewPlan?.targets.map(\.id) == [target.id])
        #expect(store.promptStagingVisible)
        #expect(store.activeDecisionRecoveryObservation == nil)
        #expect(target.inputSnapshot == handoffBaseline)

        #expect(!store.canCaptureDecisionRecoveryWitness())
        #expect(!store.captureDecisionRecoveryWitness())
        #expect(store.noticeKey
            == "Return must be detected before capturing a recovery witness.")
        target.terminalView.feed(text: "INDEPENDENT WITNESS SUPPORTS THE CHANGE\n")
        target.recordUserInput(.edited)
        target.recordUserInput(.returnKey)
        let witnessInputAfterReturn = target.inputSnapshot
        #expect(store.canCaptureDecisionRecoveryWitness())
        let witnessCapturedAt = Date(timeIntervalSince1970: 1_784_400_075)
        #expect(store.captureDecisionRecoveryWitness(capturedAt: witnessCapturedAt))
        let witnessDraft = try #require(store.decisionRecoveryWitnessDraft)
        #expect(witnessDraft.checkpointID == saved.id)
        #expect(witnessDraft.actionReceiptID == loadedReceipt.id)
        #expect(witnessDraft.recoveryObservationID == persisted.id)
        #expect(witnessDraft.capturedAt == witnessCapturedAt)
        #expect(witnessDraft.editedAfterFill)
        #expect(witnessDraft.returnDetected)
        #expect(witnessDraft.visibleScreen.contains("INDEPENDENT WITNESS"))
        #expect(witnessDraft.handoffPayload == handoff.payload)
        #expect(witnessDraft.handoffPayloadBytes == handoff.payloadBytes)
        #expect(witnessDraft.addedCount == handoff.addedCount)
        #expect(witnessDraft.removedCount == handoff.removedCount)
        #expect(witnessDraft.unchangedCount == handoff.unchangedCount)
        #expect(target.inputSnapshot == witnessInputAfterReturn)
        #expect(store.activeDecisionRecoveryWitnessDraft == witnessDraft)
        #expect(store.activeDecisionRecoveryWitness == nil)
        #expect(try archive.load().recoveryWitnesses.isEmpty)
        store.setDecisionRecoveryWitnessAssessment(.inconclusive)
        #expect(store.decisionRecoveryWitnessAssessment == .inconclusive)

        store.returnFromDecisionRecoveryWitness()
        #expect(store.promptStagingVisible)
        #expect(store.decisionRecoveryWitnessDraft == witnessDraft)
        #expect(store.decisionRecoveryWitnessAssessment == .inconclusive)
        #expect(target.inputSnapshot == witnessInputAfterReturn)
        store.showDecisionRecoveryWitnessDraft()
        #expect(store.activeDecisionRecoveryWitnessDraft == witnessDraft)

        let observationURL = root
            .appendingPathComponent("recovery-observations", isDirectory: true)
            .appendingPathComponent(
                "\(persisted.checkpointID.uuidString)."
                    + "\(persisted.actionReceiptID.uuidString)."
                    + "\(persisted.id.uuidString).recovery.json"
            )
        let observationData = try Data(contentsOf: observationURL)
        #expect(store.saveDecisionRecoveryWitness(assessment: .supportsChange))
        let persistedWitness = try #require(store.selectedDecisionRecoveryWitness)
        #expect(persistedWitness.id == witnessDraft.id)
        #expect(persistedWitness.assessment == .supportsChange)
        #expect(persistedWitness.visibleScreen == witnessDraft.visibleScreen)
        #expect(store.activeDecisionRecoveryWitness == persistedWitness)
        #expect(try Data(contentsOf: checkpointURL) == checkpointData)
        #expect(try Data(contentsOf: receiptURL) == receiptData)
        #expect(try Data(contentsOf: observationURL) == observationData)

        store.returnFromDecisionRecoveryWitness()
        #expect(store.activeDecisionRecoveryObservation == persisted)
        #expect(store.activeDecisionRecoveryObservationIsSaved)
        #expect(store.decisionRecoveryHandoffReceipt == nil)
        #expect(store.decisionRecoveryHandoffObservation == nil)
        #expect(store.decisionRecoveryHandoffPlan == nil)
        #expect(store.promptReviewPlan == nil)
        #expect(!store.promptStagingVisible)
        #expect(target.inputSnapshot == witnessInputAfterReturn)

        let restored = RelayTerminalStore(defaults: defaults, decisionArchive: archive)
        #expect(restored.savedDecisionRecoveryObservations == [persisted])
        #expect(restored.decisionRecoveryObservations(for: loadedReceipt) == [persisted])
        #expect(restored.savedDecisionRecoveryWitnesses == [persistedWitness])
        #expect(restored.decisionRecoveryWitnesses(for: persisted) == [persistedWitness])
        restored.openDecisionRecoveryWitness(persistedWitness)
        #expect(restored.activeDecisionRecoveryWitness == persistedWitness)
        restored.returnFromDecisionRecoveryWitness()
        #expect(restored.activeDecisionRecoveryObservation == persisted)

        store.returnFromDecisionRecoveryObservation()
        #expect(store.activeDecisionRecoveryObservation == nil)
        #expect(store.activeDecisionActionReceipt == loadedReceipt)
        #expect(store.promptReviewPlan == nil)
        store.openDecisionRecoveryObservation(persisted)
        #expect(store.activeDecisionRecoveryObservation == persisted)
        #expect(store.activeDecisionRecoveryObservationIsSaved)
        #expect(store.completeDecisionRecoveryHandoff(
            receipt: loadedReceipt,
            observation: persisted,
            instruction: "",
            targetID: target.id
        ))
        store.close(target)
        #expect(store.sessions.isEmpty)
        #expect(store.activeDecisionRecoveryObservation == persisted)
        #expect(store.decisionRecoveryHandoffReceipt == nil)
        #expect(store.decisionRecoveryHandoffObservation == nil)
        #expect(store.decisionRecoveryHandoffPlan == nil)
        #expect(store.promptReviewPlan == nil)
    }

    private func checkpoint(
        id: UUID,
        parentID: UUID?,
        savedAt: TimeInterval,
        marker: String
    ) throws -> RelayDecisionCheckpoint {
        let sourceA = RelayResultSnapshot(
            id: UUID(), agentName: "Codex", projectName: "relay", text: "A"
        )
        let sourceB = RelayResultSnapshot(
            id: UUID(), agentName: "Claude", projectName: "relay", text: "B"
        )
        let result = RelayResultSnapshot(
            id: UUID(), agentName: "Arbiter", projectName: "relay", text: marker
        )
        let plan = try #require(RelayResultArbitration.plan(
            instruction: "Resolve.", snapshots: [sourceA, sourceB]
        ))
        return RelayDecisionCheckpoint(
            id: id,
            savedAt: Date(timeIntervalSince1970: savedAt),
            decision: RelayResultArbitrationDecision(
                receipt: RelayResultArbitrationReceipt(
                    confluence: RelayResultConfluence(snapshots: [sourceA, sourceB]),
                    plan: plan,
                    targetID: result.id,
                    parentCheckpointID: parentID
                ),
                result: result
            )
        )
    }

    private func agent(
        id: String,
        environment: [String: String],
        versionExecutablePath: String? = nil,
        options: [RelayAgentOption] = []
    ) -> RelayAgent {
        RelayAgent(
            id: id,
            name: id.capitalized,
            detail: "",
            manifestURL: URL(fileURLWithPath: "/tmp/\(id).json"),
            adapterExecutablePath: "/tmp/adapter",
            usesGenericRuntime: false,
            registrationEnvironment: environment,
            capabilities: [],
            versionExecutablePath: versionExecutablePath,
            versionArguments: [],
            options: options,
            version: nil,
            health: .ready
        )
    }

    @Test
    func claudeAndCodexEmbedTheirResolvedBinariesWithoutArguments() {
        let claude = RelayTerminalLauncher.spec(
            for: agent(id: "claude", environment: ["RELAY_CLAUDE_PATH": "/bin/claude"])
        ) { _ in nil }
        #expect(claude == .init(executable: "/bin/claude", arguments: []))

        let codex = RelayTerminalLauncher.spec(
            for: agent(id: "codex", environment: ["RELAY_CODEX_PATH": "/bin/codex"])
        ) { _ in nil }
        #expect(codex == .init(executable: "/bin/codex", arguments: []))
    }

    @Test
    func ollamaUsesSelectedModelAndFallsBackToManifestDefault() {
        let ollama = agent(
            id: "ollama",
            environment: ["RELAY_OLLAMA_PATH": "/bin/ollama", "RELAY_GENERIC_SPEC": "/tmp/x"],
            options: [RelayAgentOption(
                key: "model", label: "MODEL",
                values: ["gemma4:latest", "gemma4:e4b"], defaultValue: "gemma4:latest"
            )]
        )
        let picked = RelayTerminalLauncher.spec(for: ollama) { key in
            key == "model" ? "gemma4:e4b" : nil
        }
        #expect(picked == .init(executable: "/bin/ollama", arguments: ["run", "gemma4:e4b"]))

        let defaulted = RelayTerminalLauncher.spec(for: ollama) { _ in "default" }
        #expect(defaulted == .init(executable: "/bin/ollama", arguments: ["run", "gemma4:latest"]))
    }

    @Test
    func mixHasNoTerminalAndUnknownAgentsFallBackToRequirementBinary() {
        let mix = RelayTerminalLauncher.spec(
            for: agent(id: "mix", environment: ["RELAY_CODEX_PATH": "/bin/codex"])
        ) { _ in nil }
        #expect(mix == nil)

        let generic = RelayTerminalLauncher.spec(
            for: agent(
                id: "gemini",
                environment: ["RELAY_GEMINI_PATH": "/bin/gemini", "RELAY_GENERIC_SPEC": "/tmp/g"]
            )
        ) { _ in nil }
        #expect(generic == .init(executable: "/bin/gemini", arguments: []))

        let acp = RelayTerminalLauncher.spec(
            for: agent(
                id: "acpcli",
                environment: ["RELAY_ACPCLI_PATH": "/bin/acpcli", "RELAY_ACP_SPEC": "/tmp/a.json"]
            )
        ) { _ in nil }
        #expect(acp == .init(executable: "/bin/acpcli", arguments: []))
    }

    @Test
    func shellCommandQuotesPathsAndArguments() {
        let command = RelayTerminalLauncher.shellCommand(
            .init(executable: "/Users/o'brien/bin/claude", arguments: ["run", "a b"])
        )
        #expect(command == "exec '/Users/o'\\''brien/bin/claude' 'run' 'a b'")
    }

    @Test
    func environmentForcesTerminalIdentityAndKeepsBase() {
        let env = RelayTerminalLauncher.environment(base: [
            "PATH": "/usr/bin", "TERM": "dumb", "LANG": "",
        ])
        #expect(env.contains("TERM=xterm-256color"))
        #expect(env.contains("COLORTERM=truecolor"))
        #expect(env.contains("LANG=en_US.UTF-8"))
        #expect(env.contains("PATH=/usr/bin"))
    }

    @Test
    func workingDirectoryFallsBackToHomeWhenMissing() {
        let missing = RelayTerminalLauncher.resolvedWorkingDirectory("/nonexistent/dir")
        #expect(missing == FileManager.default.homeDirectoryForCurrentUser.path)
        let valid = RelayTerminalLauncher.resolvedWorkingDirectory(NSTemporaryDirectory())
        #expect(valid == NSTemporaryDirectory())
    }

    @Test
    func terminalContextKeepsProjectVisibleBesideDynamicTitle() {
        #expect(RelayTerminalContext.projectName("/Users/test/Documents/Relay/") == "Relay")
        #expect(RelayTerminalContext.projectName("/") == "/")
        #expect(RelayTerminalContext.sidebarSubtitle(
            cwd: "/Users/test/Documents/Relay",
            detail: "Claude Code"
        ) == "Relay · Claude Code")
        #expect(RelayTerminalContext.sidebarSubtitle(
            cwd: "/Users/test/Documents/Relay",
            detail: "relay"
        ) == "Relay")
    }

    @Test
    func terminalActivityUsesARecentOutputWindow() {
        let output = Date(timeIntervalSince1970: 100)
        #expect(!RelayTerminalActivity.isActive(lastOutputAt: nil, now: output))
        #expect(RelayTerminalActivity.isActive(lastOutputAt: output, now: output))
        #expect(RelayTerminalActivity.isActive(
            lastOutputAt: output,
            now: output.addingTimeInterval(RelayTerminalActivity.activeInterval)
        ))
        #expect(!RelayTerminalActivity.isActive(
            lastOutputAt: output,
            now: output.addingTimeInterval(RelayTerminalActivity.activeInterval + 0.01)
        ))
        #expect(!RelayTerminalActivity.isActive(
            lastOutputAt: output,
            now: output.addingTimeInterval(-0.01)
        ))
    }

    @Test
    func promptStagingBuildsAControlSafeBracketedPaste() {
        let text = "line 1\r\n\tline 2\u{1B}[201~\u{0}"
        #expect(RelayPromptStaging.sanitized(text) == "line 1\n    line 2[201~")
        #expect(RelayPromptStaging.payload(text) == Array(
            "\u{1B}[200~line 1\n    line 2[201~\u{1B}[201~".utf8
        ))
        #expect(RelayPromptStaging.payload(" \n\t") == nil)
        #expect(RelayPromptStaging.payload(
            String(repeating: "a", count: RelayPromptStaging.maxBytes + 1)
        ) == nil)
    }

    @Test
    func contextRelayCaptureKeepsACleanUTF8TailWithinItsLimit() {
        let oversized = String(repeating: "前", count: RelayTerminalContextRelay.maxCaptureBytes)
            + "\u{1B}[31m\u{0}\n最终结论"
        let captured = RelayTerminalContextRelay.capture(Data(oversized.utf8))

        #expect(captured?.hasPrefix("…\n") == true)
        #expect(captured?.hasSuffix("[31m\n最终结论") == true)
        #expect((captured?.utf8.count ?? 0) <= RelayTerminalContextRelay.maxCaptureBytes)
        #expect(RelayTerminalContextRelay.capture(Data(" \n\t".utf8)) == nil)
    }

    @Test
    func contextRelayPayloadRequiresInstructionAndEditableContext() {
        let payload = RelayTerminalContextRelay.payload(
            instruction: "Compare this conclusion with the current implementation.",
            context: "final answer\nwith evidence",
            sourceAgent: "Claude",
            projectName: "Relay"
        )

        #expect(payload?.contains("Compare this conclusion") == true)
        #expect(payload?.contains("[Relay context · Claude · Relay]") == true)
        #expect(payload?.hasSuffix("final answer\nwith evidence") == true)
        #expect(payload.flatMap(RelayPromptStaging.payload) != nil)
        #expect(RelayTerminalContextRelay.payload(
            instruction: " ", context: "context", sourceAgent: "Claude", projectName: "Relay"
        ) == nil)
        #expect(RelayTerminalContextRelay.payload(
            instruction: "continue", context: " \n", sourceAgent: "Claude", projectName: "Relay"
        ) == nil)
    }

    @Test
    func resultArbitrationPayloadKeepsEveryFrozenSourceWithinPromptLimit() {
        let largeA = String(repeating: "甲", count: 16_000) + "\nCODEX TAIL 58"
        let largeB = String(repeating: "乙", count: 16_000) + "\nGROK TAIL 58"
        let snapshots = [
            RelayResultSnapshot(
                id: UUID(), agentName: "Codex", projectName: "Relay", text: largeA
            ),
            RelayResultSnapshot(
                id: UUID(), agentName: "Grok", projectName: "Relay", text: largeB
            ),
        ]

        let payload = RelayResultArbitration.payload(
            instruction: "Resolve the disagreement with explicit evidence.",
            snapshots: snapshots
        )

        #expect((payload?.utf8.count ?? 0) <= RelayPromptStaging.maxBytes)
        #expect(payload?.hasPrefix("Resolve the disagreement") == true)
        #expect(payload?.contains("[Result 1 · Codex · Relay]") == true)
        #expect(payload?.contains("[Result 2 · Grok · Relay]") == true)
        #expect(payload?.contains("CODEX TAIL 58") == true)
        #expect(payload?.contains("GROK TAIL 58") == true)
        #expect(payload?.components(separatedBy: "… [earlier screen truncated]\n").count == 3)
        #expect(payload.flatMap(RelayPromptStaging.payload) != nil)
        #expect(RelayResultArbitration.payload(
            instruction: " ", snapshots: snapshots
        ) == nil)
        #expect(RelayResultArbitration.payload(
            instruction: "Resolve", snapshots: []
        ) == nil)
    }

    @Test
    func resultArbitrationReclaimsUnusedSourceBudgetBeforeTruncating() {
        let longResult = String(repeating: "乙", count: 16_000) + "\nLONG SOURCE TAIL 58"
        let snapshots = [
            RelayResultSnapshot(
                id: UUID(), agentName: "Codex", projectName: "Relay", text: "short result"
            ),
            RelayResultSnapshot(
                id: UUID(), agentName: "Grok", projectName: "Relay", text: longResult
            ),
        ]

        let payload = RelayResultArbitration.payload(
            instruction: "Resolve without discarding available context.",
            snapshots: snapshots
        )

        #expect(payload?.contains("short result") == true)
        #expect(payload?.contains(longResult) == true)
        #expect(payload?.contains("… [earlier screen truncated]") == false)
        #expect((payload?.utf8.count ?? 0) <= RelayPromptStaging.maxBytes)
    }

    @Test
    func resultArbitrationPlanReportsExactRetainedBytesForEverySource() throws {
        let largeResult = String(repeating: "甲", count: 21_800) + "\nLARGE TAIL 59"
        let snapshots = [
            RelayResultSnapshot(
                id: UUID(), agentName: "Codex", projectName: "Relay", text: "short result"
            ),
            RelayResultSnapshot(
                id: UUID(), agentName: "Grok", projectName: "Relay", text: largeResult
            ),
        ]

        let plan = try #require(RelayResultArbitration.plan(
            instruction: "Preview the exact context budget.",
            snapshots: snapshots
        ))

        #expect(plan.payloadBytes == plan.payload.utf8.count)
        #expect(plan.payloadBytes <= RelayPromptStaging.maxBytes)
        #expect(plan.sources.map(\.id) == snapshots.map(\.id))
        #expect(plan.sources[0].originalBytes == "short result".utf8.count)
        #expect(plan.sources[0].retainedBytes == "short result".utf8.count)
        #expect(!plan.sources[0].truncated)
        #expect(plan.sources[1].originalBytes == largeResult.utf8.count)
        #expect(plan.sources[1].retainedBytes < plan.sources[1].originalBytes)
        #expect(plan.sources[1].truncated)
        #expect(plan.payload.contains("LARGE TAIL 59"))
    }

    @Test
    func decisionBriefReportsExactUTF8TailAndPrivateProvenance() throws {
        let result = String(repeating: "界", count: 21_835) + "\nDECISION TAIL 70"
        let largeCheckpoint = try checkpoint(
            id: UUID(), parentID: nil, savedAt: 1_784_400_000, marker: result
        )
        let annotation = try #require(RelayDecisionAnnotation(
            checkpointID: largeCheckpoint.id,
            title: "Release decision",
            tagsText: "local, verified",
            isPinned: false
        ))

        let plan = try #require(RelayDecisionBrief.plan(
            checkpoint: largeCheckpoint,
            annotation: annotation,
            instruction: "Continue with the next verified change."
        ))

        #expect(plan.payloadBytes == plan.payload.utf8.count)
        #expect(plan.payloadBytes <= RelayPromptStaging.maxBytes)
        #expect(plan.payload.hasPrefix("Continue with the next verified change."))
        #expect(plan.payload.contains(largeCheckpoint.id.uuidString))
        #expect(plan.payload.contains("Title: Release decision"))
        #expect(plan.payload.contains("Tags: local, verified"))
        #expect(plan.payload.contains("DECISION TAIL 70"))
        #expect(plan.payload.contains("… [earlier decision truncated]"))
        #expect(plan.decisionOriginalBytes == result.utf8.count)
        #expect(plan.decisionRetainedBytes < plan.decisionOriginalBytes)
        #expect(plan.decisionTruncated)
        #expect(RelayPromptStaging.payload(plan.payload) != nil)

        let instructionless = try #require(RelayDecisionBrief.plan(
            checkpoint: try checkpoint(
                id: UUID(), parentID: nil, savedAt: 1, marker: "Compact result"
            ),
            annotation: nil,
            instruction: " \n"
        ))
        #expect(instructionless.payload.hasPrefix("[Relay decision brief"))
        #expect(!instructionless.decisionTruncated)
        #expect(RelayDecisionBrief.plan(
            checkpoint: largeCheckpoint,
            annotation: annotation,
            instruction: "\u{1}"
        ) == nil)
    }

    @Test
    func actionRecoveryBriefKeepsExactReceiptEvidenceWithinUTF8Limit() throws {
        let receipt = RelayDecisionActionReceipt(
            id: UUID(),
            checkpointID: UUID(),
            capturedAt: Date(timeIntervalSince1970: 1_784_400_072),
            briefPayload: "EXACT FILLED BRIEF 72",
            decisionOriginalBytes: 21,
            decisionRetainedBytes: 21,
            decisionTruncated: false,
            targetID: UUID(),
            targetAgentName: "Claude",
            targetProjectName: "relay",
            editedAfterFill: true,
            returnDetected: true,
            visibleScreen: "FROZEN VISIBLE SCREEN 72"
        )
        let plan = try #require(RelayDecisionActionRecovery.plan(
            receipt: receipt,
            instruction: "Resume only from the frozen evidence."
        ))

        #expect(plan.payload.hasPrefix("Resume only from the frozen evidence."))
        #expect(plan.payload.contains(receipt.checkpointID.uuidString))
        #expect(plan.payload.contains(receipt.id.uuidString))
        #expect(plan.payload.contains("EXACT FILLED BRIEF 72"))
        #expect(plan.payload.contains("FROZEN VISIBLE SCREEN 72"))
        #expect(plan.payload.contains("not proof of completion or success"))
        #expect(plan.payloadBytes == plan.payload.utf8.count)
        #expect(plan.payloadBytes <= RelayPromptStaging.maxBytes)
        #expect(plan.decisionBriefRetainedBytes == receipt.briefPayload.utf8.count)
        #expect(!plan.decisionBriefTruncated)
        #expect(plan.visibleScreenRetainedBytes == receipt.visibleScreen.utf8.count)
        #expect(!plan.visibleScreenTruncated)
        #expect(RelayPromptStaging.payload(plan.payload) != nil)

        let compactReceipt = RelayDecisionActionReceipt(
            checkpointID: UUID(),
            capturedAt: Date(timeIntervalSince1970: 1_784_400_072),
            briefPayload: "B",
            decisionOriginalBytes: 1,
            decisionRetainedBytes: 1,
            decisionTruncated: false,
            targetID: UUID(),
            targetAgentName: "C",
            targetProjectName: "R",
            editedAfterFill: false,
            returnDetected: true,
            visibleScreen: "S"
        )
        let nearLimit = try #require(RelayDecisionActionRecovery.plan(
            receipt: compactReceipt,
            instruction: String(repeating: "x", count: RelayPromptStaging.maxBytes - 450)
        ))
        #expect(nearLimit.payloadBytes <= RelayPromptStaging.maxBytes)
        #expect(nearLimit.decisionBriefRetainedBytes == 1)
        #expect(nearLimit.visibleScreenRetainedBytes == 1)
        #expect(!nearLimit.decisionBriefTruncated)
        #expect(!nearLimit.visibleScreenTruncated)

        let largeBrief = String(repeating: "判", count: 15_000) + "\nBRIEF TAIL 72"
        let largeScreen = String(repeating: "画", count: 15_000) + "\nSCREEN TAIL 72"
        let largeReceipt = RelayDecisionActionReceipt(
            checkpointID: UUID(),
            capturedAt: Date(timeIntervalSince1970: 1_784_400_073),
            briefPayload: largeBrief,
            decisionOriginalBytes: largeBrief.utf8.count,
            decisionRetainedBytes: largeBrief.utf8.count,
            decisionTruncated: false,
            targetID: UUID(),
            targetAgentName: "Codex",
            targetProjectName: "relay",
            editedAfterFill: false,
            returnDetected: true,
            visibleScreen: largeScreen
        )
        let limited = try #require(RelayDecisionActionRecovery.plan(
            receipt: largeReceipt,
            instruction: ""
        ))
        #expect(limited.payloadBytes <= RelayPromptStaging.maxBytes)
        #expect(limited.decisionBriefTruncated)
        #expect(limited.visibleScreenTruncated)
        #expect(limited.payload.contains("… [earlier filled decision brief truncated]"))
        #expect(limited.payload.contains("… [earlier frozen screen truncated]"))
        #expect(limited.payload.contains("BRIEF TAIL 72"))
        #expect(limited.payload.contains("SCREEN TAIL 72"))
        #expect(limited.decisionBriefRetainedBytes < limited.decisionBriefOriginalBytes)
        #expect(limited.visibleScreenRetainedBytes < limited.visibleScreenOriginalBytes)
        #expect(RelayDecisionActionRecovery.plan(
            receipt: receipt,
            instruction: "\u{1}"
        ) == nil)
    }

    @Test
    func terminalInputClassifierIgnoresNavigationButDetectsEditsAndReturn() {
        #expect(RelayTerminalInputClassifier.classify(Array("hello".utf8)[...]) == .edited)
        #expect(RelayTerminalInputClassifier.classify([0x7F][...]) == .edited)
        #expect(RelayTerminalInputClassifier.classify(Array("\u{1B}[A".utf8)[...]) == nil)
        #expect(RelayTerminalInputClassifier.classify(Array(
            "\u{1B}[200~pasted\u{1B}[201~".utf8
        )[...]) == .edited)
        #expect(RelayTerminalInputClassifier.classify([0x0D][...]) == .returnKey)
        #expect(RelayTerminalInputClassifier.classify(Array("\u{1B}[13;1u".utf8)[...]) == .returnKey)
        #expect(RelayTerminalInputClassifier.classify(Array("\u{1B}[97;1u".utf8)[...]) == .edited)
        #expect(RelayTerminalInputClassifier.classify(Array("\u{1B}[57352;1u".utf8)[...]) == nil)
    }

    @Test
    func promptTargetSignalUsesOnlyInputRevisionsAndGeneration() {
        let baseline = RelayTerminalInputSnapshot(
            generation: 2, editRevision: 3, returnRevision: 4
        )
        #expect(RelayPromptTargetSignal.resolve(
            baseline: baseline, current: baseline
        ) == .none)
        #expect(RelayPromptTargetSignal.resolve(
            baseline: baseline,
            current: .init(generation: 2, editRevision: 4, returnRevision: 4)
        ) == .edited)
        #expect(RelayPromptTargetSignal.resolve(
            baseline: baseline,
            current: .init(generation: 2, editRevision: 4, returnRevision: 5)
        ) == .returnDetected)
        #expect(RelayPromptTargetSignal.resolve(
            baseline: baseline,
            current: .init(generation: 3, editRevision: 0, returnRevision: 0)
        ) == .restarted)
        #expect(RelayPromptTargetSignal.resolve(
            baseline: baseline, current: nil
        ) == .closed)
    }

    @Test
    func promptReviewAdvancesInTargetOrderOnlyAfterConfirmation() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var plan = RelayPromptReviewPlan(targets: [
            .init(id: first, agentName: "Claude", projectName: "Relay"),
            .init(id: second, agentName: "Codex", projectName: "Relay"),
            .init(id: third, agentName: "Grok", projectName: "Relay"),
            .init(id: first, agentName: "Claude", projectName: "Relay"),
        ])
        let available = Set([first, second, third])

        #expect(plan.targets.map(\.id) == [first, second, third])
        #expect(plan.currentID == first)
        #expect(plan.reviewedCount() == 0)
        #expect(plan.select(UUID(), availableIDs: available) == nil)
        #expect(plan.currentID == first)
        #expect(plan.select(third, availableIDs: available) == third)
        #expect(plan.reviewedCount() == 0)
        #expect(plan.confirmCurrent(availableIDs: available) == first)
        #expect(plan.reviewedIDs == [third])
        #expect(plan.select(third, availableIDs: available) == third)
        #expect(plan.nextPendingID(availableIDs: available) == first)
        #expect(plan.selectNextPending(availableIDs: available) == first)
        #expect(plan.confirmCurrent(availableIDs: available) == second)
        #expect(plan.confirmCurrent(availableIDs: available) == nil)
        #expect(plan.isComplete())
        #expect(plan.isFinished(availableIDs: available))
    }

    @Test
    func promptReviewSeparatesClosedTargetsFromCheckedTargets() {
        let first = UUID()
        let closed = UUID()
        var plan = RelayPromptReviewPlan(targets: [
            .init(id: first, agentName: "Claude", projectName: "Relay"),
            .init(id: closed, agentName: "Codex", projectName: "Relay"),
        ])
        let available = Set([first])

        #expect(plan.reconcile(availableIDs: available) == first)
        #expect(plan.closedCount(availableIDs: available) == 1)
        #expect(plan.pendingCount(availableIDs: available) == 1)
        #expect(plan.confirmCurrent(availableIDs: available) == nil)
        #expect(plan.isFinished(availableIDs: available))
        #expect(!plan.isComplete())
        #expect(plan.reviewedCount() == 1)
    }

    @MainActor
    @Test
    func promptReviewSurvivesPanelHidingUntilExplicitlyCleared() {
        let suiteName = "RelayTerminalTests.promptReviewRecovery.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["claude", "codex"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard store.sessions.count == 2 else {
            Issue.record("both terminals should be open")
            return
        }
        var plan = RelayPromptReviewPlan(targets: store.sessions.map {
            .init(id: $0.id, agentName: $0.agentName, projectName: "Relay")
        })
        guard let firstID = plan.currentID else {
            Issue.record("review should start at the first terminal")
            return
        }

        store.beginPromptReview(plan)
        #expect(store.promptStagingVisible)
        #expect(store.promptReviewPendingCount == 2)

        _ = plan.confirmCurrent(availableIDs: Set(store.sessions.map(\.id)))
        store.updatePromptReview(plan)
        store.closePromptStaging()

        #expect(!store.promptStagingVisible)
        #expect(store.promptReviewPlan?.reviewedIDs == [firstID])
        #expect(store.promptReviewPendingCount == 1)

        store.togglePromptStaging()
        #expect(store.promptStagingVisible)
        #expect(store.promptReviewPlan?.currentID == plan.currentID)

        let firstSession = store.sessions[0]
        store.close(firstSession)
        #expect(store.promptReviewPlan != nil)
        let lastSession = store.sessions[0]
        store.close(lastSession)
        #expect(store.promptReviewPlan == nil)
        #expect(!store.promptStagingVisible)
    }

    @MainActor
    @Test
    func outputRadarCountsAndFocusesTheLatestActiveTerminal() {
        let suiteName = "RelayTerminalTests.outputRadar.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults, isTerminalViewed: { _ in true })
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        store.open(
            agent: agent(id: "claude", environment: ["RELAY_CLAUDE_PATH": "/bin/cat"]),
            cwd: NSTemporaryDirectory()
        ) { _ in nil }
        store.open(
            agent: agent(id: "codex", environment: ["RELAY_CODEX_PATH": "/bin/cat"]),
            cwd: NSTemporaryDirectory()
        ) { _ in nil }
        guard let claude = store.sessions.first(where: { $0.agentID == "claude" }),
              let codex = store.sessions.first(where: { $0.agentID == "codex" }) else {
            Issue.record("both terminals should be open")
            return
        }

        let now = Date(timeIntervalSince1970: 200)
        claude.recordOutput(at: now)
        codex.recordOutput(at: now.addingTimeInterval(-0.5))
        store.activate(codex.id)

        #expect(store.activeTerminalCount(at: now) == 2)
        #expect(store.focusLatestOutput(at: now) == claude.id)
        #expect(store.focusedID == claude.id)
        #expect(store.activeTerminalCount(
            at: now.addingTimeInterval(RelayTerminalActivity.activeInterval + 0.01)
        ) == 0)

        for session in store.sessions {
            store.close(session)
        }
    }

    @MainActor
    @Test
    func pendingOutputTracksOnlyUnseenTerminalsAndDeduplicates() {
        let suiteName = "RelayTerminalTests.pendingOutput.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var viewedID: UUID?
        let store = RelayTerminalStore(
            defaults: defaults,
            isTerminalViewed: { $0.id == viewedID }
        )
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["claude", "codex"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard let claude = store.sessions.first(where: { $0.agentID == "claude" }),
              let codex = store.sessions.first(where: { $0.agentID == "codex" }) else {
            Issue.record("both terminals should be open")
            return
        }

        viewedID = codex.id
        store.activate(codex.id)
        let first = Date(timeIntervalSince1970: 300)
        codex.recordOutput(at: first)
        #expect(store.pendingOutputCount == 0)

        claude.recordOutput(at: first)
        let later = first.addingTimeInterval(1)
        claude.recordOutput(at: later)
        #expect(store.pendingOutputCount == 1)
        #expect(store.pendingOutputDates[claude.id] == later)

        viewedID = nil
        codex.recordOutput(at: later)
        #expect(store.pendingOutputCount == 2)
        store.markFocusedOutputReviewed()
        #expect(store.pendingOutputCount == 2)
        viewedID = codex.id
        store.markFocusedOutputReviewed()
        #expect(store.pendingOutputCount == 1)
        #expect(store.needsOutputReview(claude.id))
        #expect(!store.needsOutputReview(codex.id))

        for session in store.sessions {
            store.close(session)
        }
    }

    @MainActor
    @Test
    func pendingOutputQueueFocusesTheOldestTerminalFirst() {
        let suiteName = "RelayTerminalTests.pendingQueue.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults, isTerminalViewed: { _ in false })
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["claude", "codex", "other"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard let claude = store.sessions.first(where: { $0.agentID == "claude" }),
              let codex = store.sessions.first(where: { $0.agentID == "codex" }) else {
            Issue.record("both terminals should be open")
            return
        }

        let first = Date(timeIntervalSince1970: 400)
        claude.recordOutput(at: first)
        codex.recordOutput(at: first.addingTimeInterval(1))
        #expect(store.pendingOutputCount == 2)
        #expect(store.focusNextPendingOutput() == claude.id)
        #expect(store.focusedID == claude.id)
        #expect(store.pendingOutputCount == 1)
        #expect(store.focusNextPendingOutput() == codex.id)
        #expect(store.focusedID == codex.id)
        #expect(store.pendingOutputCount == 0)
        #expect(store.focusNextPendingOutput() == nil)

        for session in store.sessions {
            store.close(session)
        }
    }

    @MainActor
    @Test
    func attentionRouterPrioritizesPromptReviewThenPendingAndActiveOutput() {
        let suiteName = "RelayTerminalTests.attentionRouter.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults, isTerminalViewed: { _ in false })
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["claude", "codex", "grok"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard let claude = store.sessions.first(where: { $0.agentID == "claude" }),
              let codex = store.sessions.first(where: { $0.agentID == "codex" }),
              let grok = store.sessions.first(where: { $0.agentID == "grok" }) else {
            Issue.record("three terminals should be open")
            return
        }

        let first = Date(timeIntervalSince1970: 500)
        let second = first.addingTimeInterval(0.5)
        claude.recordOutput(at: first)
        codex.recordOutput(at: second)

        var plan = RelayPromptReviewPlan(targets: [
            .init(id: codex.id, agentName: codex.agentName, projectName: "Relay"),
            .init(id: grok.id, agentName: grok.agentName, projectName: "Relay"),
        ])
        let availableIDs = Set(store.sessions.map(\.id))
        #expect(plan.confirmCurrent(availableIDs: availableIDs) == grok.id)
        #expect(plan.select(codex.id, availableIDs: availableIDs) == codex.id)
        store.beginPromptReview(plan)

        #expect(store.attentionPendingCount == 3)
        #expect(store.nextAttention(at: second) == RelayTerminalAttention(
            kind: .promptReview,
            sessionID: grok.id,
            count: 3
        ))
        #expect(store.focusNextAttention(at: second)?.kind == .promptReview)
        #expect(store.focusedID == grok.id)
        #expect(store.promptReviewPlan?.currentID == grok.id)
        #expect(store.pendingOutputCount == 2)

        store.clearPromptReview()
        store.closePromptStaging()
        #expect(store.focusNextAttention(at: second) == RelayTerminalAttention(
            kind: .pendingOutput,
            sessionID: claude.id,
            count: 2
        ))
        #expect(store.pendingOutputCount == 1)
        #expect(store.focusNextAttention(at: second) == RelayTerminalAttention(
            kind: .pendingOutput,
            sessionID: codex.id,
            count: 1
        ))
        #expect(store.pendingOutputCount == 0)
        #expect(store.nextAttention(at: second) == RelayTerminalAttention(
            kind: .activeOutput,
            sessionID: codex.id,
            count: 2
        ))

        for session in store.sessions {
            store.close(session)
        }
    }

    @MainActor
    @Test
    func attentionRouteIssuesOneReturnTicketAndRestoresPromptVisibility() {
        let suiteName = "RelayTerminalTests.attentionReturn.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults, isTerminalViewed: { _ in false })
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["claude", "codex"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard let claude = store.sessions.first(where: { $0.agentID == "claude" }),
              let codex = store.sessions.first(where: { $0.agentID == "codex" }) else {
            Issue.record("both terminals should be open")
            return
        }

        store.activate(codex.id)
        let now = Date(timeIntervalSince1970: 600)
        claude.recordOutput(at: now)
        #expect(store.focusNextAttention(at: now)?.sessionID == claude.id)
        #expect(store.attentionReturnTicket == RelayTerminalReturnTicket(
            sessionID: codex.id,
            closesPromptStaging: false
        ))
        #expect(store.returnFromAttention() == codex.id)
        #expect(store.focusedID == codex.id)
        #expect(store.attentionReturnTicket == nil)

        let plan = RelayPromptReviewPlan(targets: [
            .init(id: claude.id, agentName: claude.agentName, projectName: "Relay"),
        ])
        store.beginPromptReview(plan)
        store.closePromptStaging()
        #expect(store.focusNextAttention(at: now)?.kind == .promptReview)
        #expect(store.promptStagingVisible)
        #expect(store.attentionReturnTicket == RelayTerminalReturnTicket(
            sessionID: codex.id,
            closesPromptStaging: true
        ))
        #expect(store.returnFromAttention() == codex.id)
        #expect(!store.promptStagingVisible)
        #expect(store.promptReviewPlan != nil)

        #expect(store.focusNextAttention(at: now)?.kind == .promptReview)
        store.close(codex)
        #expect(store.attentionReturnTicket == nil)
        store.close(claude)
    }

    @MainActor
    @Test
    func attentionRoutePulseReversesAndIgnoresStaleDismissals() {
        let suiteName = "RelayTerminalTests.attentionPulse.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults, isTerminalViewed: { _ in false })
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["claude", "codex"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard let claude = store.sessions.first(where: { $0.agentID == "claude" }),
              let codex = store.sessions.first(where: { $0.agentID == "codex" }) else {
            Issue.record("both terminals should be open")
            return
        }

        store.activate(codex.id)
        let now = Date(timeIntervalSince1970: 700)
        claude.recordOutput(at: now)
        #expect(store.focusNextAttention(at: now)?.sessionID == claude.id)
        let outbound = store.attentionRoutePulse
        #expect(outbound?.sourceID == codex.id)
        #expect(outbound?.targetID == claude.id)

        #expect(store.returnFromAttention() == codex.id)
        let inbound = store.attentionRoutePulse
        #expect(inbound?.sourceID == claude.id)
        #expect(inbound?.targetID == codex.id)
        #expect(inbound?.id != outbound?.id)

        if let id = outbound?.id {
            store.dismissAttentionRoutePulse(id)
        }
        #expect(store.attentionRoutePulse?.id == inbound?.id)
        if let id = inbound?.id {
            store.dismissAttentionRoutePulse(id)
        }
        #expect(store.attentionRoutePulse == nil)

        for session in store.sessions {
            store.close(session)
        }
    }

    @MainActor
    @Test
    func promptStagingTargetsOnlyReadyRunningTerminals() {
        let suiteName = "RelayTerminalTests.promptStaging.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["claude", "codex"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard let claude = store.sessions.first(where: { $0.agentID == "claude" }),
              let codex = store.sessions.first(where: { $0.agentID == "codex" }) else {
            Issue.record("both terminals should be open")
            return
        }

        claude.terminalView.feed(text: "\u{1B}[?2004h")
        #expect(claude.isPromptStagingReady)
        #expect(!codex.isPromptStagingReady)
        let inputBaseline = claude.inputSnapshot
        store.togglePromptStaging()
        #expect(store.promptStagingVisible)
        #expect(store.stagePrompt("same prompt", to: [claude.id, codex.id]) == [claude.id])
        #expect(claude.inputSnapshot == inputBaseline)

        for session in store.sessions {
            store.close(session)
        }
        #expect(!store.promptStagingVisible)
    }

    @MainActor
    @Test
    func contextRelayForkStagesReadyTargetsThenEntersTheExistingReviewLoop() {
        let suiteName = "RelayTerminalTests.contextRelay.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["claude", "codex", "grok", "ollama"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard let claude = store.sessions.first(where: { $0.agentID == "claude" }),
              let codex = store.sessions.first(where: { $0.agentID == "codex" }),
              let grok = store.sessions.first(where: { $0.agentID == "grok" }),
              let ollama = store.sessions.first(where: { $0.agentID == "ollama" }) else {
            Issue.record("all terminals should be open")
            return
        }

        claude.terminalView.feed(text: "CLAUDE SCREEN CONTEXT\n")
        codex.terminalView.feed(text: "\u{1B}[?2004h")
        grok.terminalView.feed(text: "\u{1B}[?2004h")
        let codexBaseline = codex.inputSnapshot
        let grokBaseline = grok.inputSnapshot

        #expect(store.beginContextRelay(from: claude))
        #expect(store.contextRelayDraft?.sourceID == claude.id)
        #expect(store.contextRelayDraft?.context.contains("CLAUDE SCREEN CONTEXT") == true)
        #expect(!store.beginContextRelay(from: codex))
        #expect(!store.completeContextRelay(
            instruction: "Verify this result.",
            context: store.contextRelayDraft?.context ?? "",
            targetIDs: []
        ))
        #expect(store.contextRelayDraft != nil)
        #expect(store.completeContextRelay(
            instruction: "Verify this result.",
            context: store.contextRelayDraft?.context ?? "",
            targetIDs: [codex.id, grok.id, ollama.id]
        ))
        #expect(store.contextRelayDraft == nil)
        #expect(store.promptStagingVisible)
        #expect(store.promptReviewPlan?.targets.map(\.id) == [codex.id, grok.id])
        #expect(store.promptReviewPlan?.currentID == codex.id)
        #expect(store.focusedID == codex.id)
        #expect(store.attentionReturnTicket == RelayTerminalReturnTicket(
            sessionID: claude.id,
            closesPromptStaging: true
        ))
        #expect(store.attentionRoutePulse?.sourceID == claude.id)
        #expect(store.attentionRoutePulse?.targetID == codex.id)
        #expect(codex.inputSnapshot == codexBaseline)
        #expect(grok.inputSnapshot == grokBaseline)
        #expect(store.promptReviewPlan?.targets.contains(where: { $0.id == ollama.id }) == false)

        for session in store.sessions {
            store.close(session)
        }
    }

    @MainActor
    @Test
    func completedPromptReviewFreezesAndRefreshesTwoTerminalScreens() {
        let suiteName = "RelayTerminalTests.resultConfluence.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["codex", "grok"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard let codex = store.sessions.first(where: { $0.agentID == "codex" }),
              let grok = store.sessions.first(where: { $0.agentID == "grok" }) else {
            Issue.record("both terminals should be open")
            return
        }

        codex.terminalView.feed(text: "CODEX RESULT 57\n")
        grok.terminalView.feed(text: "GROK RESULT 57\n")
        let targets = [codex, grok].map { session in
            RelayPromptReviewTarget(
                id: session.id,
                agentName: session.agentName,
                projectName: RelayTerminalContext.projectName(session.cwd)
            )
        }
        var plan = RelayPromptReviewPlan(targets: targets)
        let availableIDs = Set(targets.map(\.id))
        store.beginPromptReview(plan)
        #expect(!store.captureResultConfluence(from: plan))

        _ = plan.confirmCurrent(availableIDs: availableIDs)
        _ = plan.confirmCurrent(availableIDs: availableIDs)
        store.updatePromptReview(plan)
        #expect(plan.isComplete())
        #expect(store.captureResultConfluence(from: plan))
        #expect(!store.promptStagingVisible)
        #expect(store.resultConfluence?.snapshots.map(\.id) == [codex.id, grok.id])
        #expect(store.resultConfluence?.snapshots[0].text.contains("CODEX RESULT 57") == true)
        #expect(store.resultConfluence?.snapshots[1].text.contains("GROK RESULT 57") == true)

        let frozenID = store.resultConfluence?.id
        codex.terminalView.feed(text: "CODEX UPDATED 57\n")
        #expect(store.resultConfluence?.snapshots[0].text.contains("CODEX UPDATED 57") == false)
        #expect(store.refreshResultConfluence())
        #expect(store.resultConfluence?.id != frozenID)
        #expect(store.resultConfluence?.snapshots[0].text.contains("CODEX UPDATED 57") == true)
        #expect(store.focusResultSnapshot(codex.id) == codex.id)
        #expect(store.focusedID == codex.id)

        store.returnFromResultConfluence()
        #expect(store.resultConfluence == nil)
        #expect(store.promptStagingVisible)

        #expect(store.captureResultConfluence(from: plan))
        store.close(grok)
        #expect(store.resultConfluence?.snapshots.count == 2)
        store.close(codex)
        #expect(store.resultConfluence == nil)
    }

    @MainActor
    @Test
    func frozenResultsStageIntoOneExplicitArbitrationTarget() {
        let suiteName = "RelayTerminalTests.resultArbitration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let archiveRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayDecisionStoreTests-\(UUID().uuidString)")
        let archiveTrash = archiveRoot.appendingPathComponent("trash", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: archiveTrash, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: archiveRoot) }
        let archive = RelayDecisionArchive(
            directoryURL: archiveRoot.appendingPathComponent("decisions", isDirectory: true),
            trashItem: { url in
                try FileManager.default.moveItem(
                    at: url,
                    to: archiveTrash.appendingPathComponent(url.lastPathComponent)
                )
            }
        )

        let store = RelayTerminalStore(defaults: defaults, decisionArchive: archive)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        for id in ["codex", "grok", "claude"] {
            store.open(
                agent: agent(
                    id: id,
                    environment: ["RELAY_\(id.uppercased())_PATH": "/bin/cat"]
                ),
                cwd: NSTemporaryDirectory()
            ) { _ in nil }
        }
        guard let codex = store.sessions.first(where: { $0.agentID == "codex" }),
              let grok = store.sessions.first(where: { $0.agentID == "grok" }),
              let claude = store.sessions.first(where: { $0.agentID == "claude" }) else {
            Issue.record("all terminals should be open")
            return
        }

        codex.terminalView.feed(text: "CODEX RESULT 58\n")
        grok.terminalView.feed(text: "GROK RESULT 58\n")
        claude.terminalView.feed(text: "\u{1B}[?2004h")
        let targets = [codex, grok].map { session in
            RelayPromptReviewTarget(
                id: session.id,
                agentName: session.agentName,
                projectName: RelayTerminalContext.projectName(session.cwd)
            )
        }
        var plan = RelayPromptReviewPlan(targets: targets)
        let availableIDs = Set(targets.map(\.id))
        _ = plan.confirmCurrent(availableIDs: availableIDs)
        _ = plan.confirmCurrent(availableIDs: availableIDs)
        store.beginPromptReview(plan)
        store.updatePromptReview(plan)
        #expect(store.captureResultConfluence(from: plan))
        guard let frozenConfluence = store.resultConfluence else {
            Issue.record("frozen provenance should exist before arbitration")
            return
        }
        store.activate(codex.id)

        #expect(!store.completeResultArbitration(
            instruction: "Resolve the disagreement.", targetID: grok.id
        ))
        #expect(store.resultConfluence != nil)
        #expect(!store.completeResultArbitration(
            instruction: " ", targetID: claude.id
        ))
        #expect(store.resultConfluence != nil)

        let inputBaseline = claude.inputSnapshot
        #expect(store.completeResultArbitration(
            instruction: "Resolve the disagreement with explicit evidence.",
            targetID: claude.id
        ))
        #expect(store.resultConfluence == nil)
        #expect(store.promptStagingVisible)
        #expect(store.promptReviewPlan?.targets.map(\.id) == [claude.id])
        #expect(store.focusedID == claude.id)
        #expect(store.attentionReturnTicket == RelayTerminalReturnTicket(
            sessionID: codex.id,
            closesPromptStaging: true
        ))
        #expect(store.attentionRoutePulse?.sourceID == codex.id)
        #expect(store.attentionRoutePulse?.targetID == claude.id)
        #expect(claude.inputSnapshot == inputBaseline)

        guard let receipt = store.resultArbitrationReceipt else {
            Issue.record("arbitration should keep an in-memory provenance receipt")
            return
        }
        #expect(receipt.confluence == frozenConfluence)
        #expect(receipt.targetID == claude.id)
        #expect(receipt.plan.payloadBytes <= RelayPromptStaging.maxBytes)
        #expect(receipt.plan.sources.map(\.id) == [codex.id, grok.id])
        #expect(store.resultArbitrationSourceDrift() == [
            codex.id: .unchanged,
            grok.id: .unchanged,
        ])

        #expect(!store.captureResultArbitrationDecision())
        guard var arbitrationReview = store.promptReviewPlan else {
            Issue.record("arbitration review should exist before sealing its result")
            return
        }
        _ = arbitrationReview.confirmCurrent(availableIDs: [claude.id])
        store.updatePromptReview(arbitrationReview)
        claude.terminalView.feed(text: "ARBITER FINAL 62\n")
        #expect(store.captureResultArbitrationDecision())
        guard let decision = store.resultArbitrationDecision else {
            Issue.record("explicit sealing should keep an in-memory decision")
            return
        }
        #expect(decision.receipt == receipt)
        #expect(decision.result.id == claude.id)
        #expect(decision.result.text.contains("ARBITER FINAL 62"))
        #expect(store.resultArbitrationDecisionVisible)
        #expect(!store.promptStagingVisible)
        #expect(store.savedDecisionCheckpoints.isEmpty)
        #expect(store.saveResultArbitrationDecision())
        guard let checkpoint = store.savedDecisionCheckpoints.first else {
            Issue.record("explicit save should create a private decision checkpoint")
            return
        }
        #expect(checkpoint.decision == decision)
        #expect(store.liveDecisionCheckpointID == checkpoint.id)
        let restoredStore = RelayTerminalStore(
            defaults: defaults,
            decisionArchive: archive
        )
        #expect(restoredStore.savedDecisionCheckpoints == [checkpoint])

        claude.terminalView.feed(text: "LATER ARBITER OUTPUT\n")
        #expect(!store.captureResultArbitrationDecision())
        #expect(store.resultArbitrationDecision == decision)
        store.returnFromResultArbitrationDecision()
        #expect(!store.resultArbitrationDecisionVisible)
        #expect(store.promptStagingVisible)
        #expect(store.showResultArbitrationDecision())
        #expect(store.resultArbitrationDecisionVisible)
        #expect(!store.promptStagingVisible)
        store.returnFromResultArbitrationDecision()

        codex.terminalView.feed(text: "CODEX SOURCE CHANGED 61\n")
        store.close(grok)
        #expect(store.resultArbitrationSourceDrift() == [
            codex.id: .changed,
            grok.id: .closed,
        ])
        #expect(store.showResultArbitrationSources())
        #expect(store.resultConfluence == frozenConfluence)
        #expect(!store.promptStagingVisible)

        store.returnFromResultConfluence()
        #expect(store.resultConfluence == nil)
        #expect(store.promptStagingVisible)
        #expect(store.resultArbitrationReceipt == receipt)

        store.clearPromptReview()
        #expect(store.resultArbitrationReceipt == nil)
        #expect(store.resultArbitrationDecision == nil)
        #expect(!store.resultArbitrationDecisionVisible)
        #expect(store.savedDecisionCheckpoints == [checkpoint])

        #expect(store.moveDecisionCheckpointToTrash(checkpoint))
        #expect(store.savedDecisionCheckpoints.isEmpty)
        #expect(store.liveDecisionCheckpointID == nil)

        for session in store.sessions {
            store.close(session)
        }
    }

    @MainActor
    @Test
    func projectPairOpensOnceAndRequestsTilingWithoutDuplicates() {
        let suiteName = "RelayTerminalTests.pair.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        let agents = [
            agent(id: "claude", environment: ["RELAY_CLAUDE_PATH": "/usr/bin/true"]),
            agent(id: "codex", environment: ["RELAY_CODEX_PATH": "/usr/bin/true"]),
        ]
        let cwd = NSTemporaryDirectory()

        #expect(store.openProjectPair(agents: agents, cwd: cwd) { _, _ in nil })
        #expect(store.sessions.count == 2)
        #expect(Set(store.sessions.map(\.agentID)) == Set(["claude", "codex"]))
        let firstIDs = Set(store.sessions.map(\.id))

        #expect(store.openProjectPair(agents: agents, cwd: cwd) { _, _ in nil })
        #expect(Set(store.sessions.map(\.id)) == firstIDs)
        #expect(store.sessions.count == 2)

        for session in store.sessions {
            store.close(session)
        }
    }

    @MainActor
    @Test
    func projectPairDoesNotPartiallyOpenWhenCapacityIsInsufficient() {
        let suiteName = "RelayTerminalTests.pairCapacity.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RelayTerminalStore(defaults: defaults)
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        let cwd = NSTemporaryDirectory()
        for id in ["one", "two", "three"] {
            store.open(
                agent: agent(id: id, environment: ["RELAY_\(id.uppercased())_PATH": "/usr/bin/true"]),
                cwd: cwd
            ) { _ in nil }
        }

        let agents = [
            agent(id: "claude", environment: ["RELAY_CLAUDE_PATH": "/usr/bin/true"]),
            agent(id: "codex", environment: ["RELAY_CODEX_PATH": "/usr/bin/true"]),
        ]
        #expect(!store.openProjectPair(agents: agents, cwd: cwd) { _, _ in nil })
        #expect(store.sessions.count == 3)
        #expect(store.sessions.allSatisfy { $0.agentID != "claude" && $0.agentID != "codex" })
        #expect(store.noticeKey == "Not enough terminal slots for this project pair.")

        for session in store.sessions {
            store.close(session)
        }
    }

    @Test
    func cascadeFramesStayInsideCanvasAndStagger() {
        let size = CGSize(width: 1200, height: 800)
        let canvas = RelayWindowGeometry.canvas(size)
        let frames = (0..<4).map {
            RelayWindowGeometry.cascadeFrame(serial: $0, in: size)
        }
        for frame in frames {
            #expect(canvas.contains(frame))
            #expect(frame.width >= RelayWindowGeometry.minSize.width)
            #expect(frame.height >= RelayWindowGeometry.minSize.height)
        }
        let origins = Set(frames.map { "\($0.minX),\($0.minY)" })
        #expect(origins.count == frames.count)
    }

    @Test
    func movedClampsWindowIntoCanvas() {
        let size = CGSize(width: 1000, height: 600)
        let base = CGRect(x: 100, y: 100, width: 400, height: 300)

        let flungOut = RelayWindowGeometry.moved(
            base, translation: CGSize(width: 5000, height: -5000), in: size
        )
        #expect(flungOut == CGRect(x: 600, y: RelayWindowGeometry.topInset, width: 400, height: 300))

        let nudged = RelayWindowGeometry.moved(
            base, translation: CGSize(width: -30, height: 20), in: size
        )
        #expect(nudged == CGRect(x: 70, y: 120, width: 400, height: 300))
    }

    @Test
    func resizedHonorsMinimumSizeAndAnchorsOppositeEdge() {
        let size = CGSize(width: 1000, height: 600)
        let base = CGRect(x: 100, y: 100, width: 400, height: 300)

        let shrunk = RelayWindowGeometry.resized(
            base, handle: .right, translation: CGSize(width: -200, height: 0), in: size
        )
        #expect(shrunk.minX == 100)
        #expect(shrunk.width == RelayWindowGeometry.minSize.width)

        let grownLeft = RelayWindowGeometry.resized(
            base, handle: .left, translation: CGSize(width: -150, height: 0), in: size
        )
        #expect(grownLeft.minX == 0)
        #expect(grownLeft.maxX == base.maxX)

        let cornered = RelayWindowGeometry.resized(
            base, handle: .bottomRight,
            translation: CGSize(width: 900, height: 900), in: size
        )
        #expect(cornered.origin == base.origin)
        #expect(cornered.maxX == 1000)
        #expect(cornered.maxY == 600)

        let topped = RelayWindowGeometry.resized(
            base, handle: .top, translation: CGSize(width: 0, height: -500), in: size
        )
        #expect(topped.minY == RelayWindowGeometry.topInset)
        #expect(topped.maxY == base.maxY)
    }

    @Test
    func fittedShrinksOversizedWindowsIntoCanvas() {
        let size = CGSize(width: 900, height: 700)
        let oversized = CGRect(x: 0, y: 0, width: 2000, height: 1500)
        let fit = RelayWindowGeometry.fitted(oversized, in: size)
        #expect(fit == CGRect(
            x: 0, y: RelayWindowGeometry.topInset,
            width: 900, height: 700 - RelayWindowGeometry.topInset
        ))

        let untouched = CGRect(x: 40, y: 100, width: 400, height: 300)
        #expect(RelayWindowGeometry.fitted(untouched, in: size) == untouched)
    }

    @MainActor
    @Test
    func deskMemoryRestoresRelativeLayoutAndClearsWhenLastTerminalCloses() throws {
        let suiteName = "RelayTerminalTests.desk.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let originalCanvas = CGSize(width: 1200, height: 800)
        let saved = RelayDeskSnapshot(terminals: [
            .init(
                agentID: "claude",
                cwd: NSTemporaryDirectory(),
                frame: .init(
                    CGRect(x: 120, y: 80, width: 800, height: 480),
                    in: originalCanvas
                )
            ),
        ])
        defaults.set(try JSONEncoder().encode(saved), forKey: RelayDeskSnapshot.defaultsKey)

        let store = RelayTerminalStore(defaults: defaults)
        store.reportWorkspaceSize(CGSize(width: 600, height: 400))
        #expect(store.restorableDesk == saved)

        let restored = store.restoreDesk(
            agents: [agent(
                id: "claude",
                environment: ["RELAY_CLAUDE_PATH": "/usr/bin/true"]
            )],
            optionValue: { _, _ in nil }
        )
        #expect(restored == 1)
        guard let session = store.sessions.first else {
            Issue.record("desk should restore one terminal")
            return
        }
        #expect(store.frame(for: session.id) == CGRect(
            x: 60, y: 40, width: 400, height: 240
        ))

        store.moveWindow(
            id: session.id,
            base: store.frame(for: session.id),
            translation: CGSize(width: 20, height: 10)
        )
        let updatedData = try #require(defaults.data(forKey: RelayDeskSnapshot.defaultsKey))
        let updated = try JSONDecoder().decode(RelayDeskSnapshot.self, from: updatedData)
        #expect(updated.terminals.first?.frame.x == 80.0 / 600.0)

        store.close(session)
        #expect(store.restorableDesk == nil)
        #expect(store.noticeKey == nil)
        #expect(defaults.data(forKey: RelayDeskSnapshot.defaultsKey) == nil)
    }

    @Test
    func tiledLayoutsFillCanvasWithoutOverlap() {
        let size = CGSize(width: 1200, height: 800)
        let canvas = RelayWindowGeometry.canvas(size)
        for count in 1...6 {
            let frames = RelayWindowGeometry.tiled(count: count, in: size)
            #expect(frames.count == count)
            for frame in frames {
                #expect(canvas.contains(frame))
            }
            for (i, a) in frames.enumerated() {
                for b in frames.dropFirst(i + 1) {
                    #expect(!a.intersects(b))
                }
            }
        }
        let quad = RelayWindowGeometry.tiled(count: 4, in: size)
        #expect(Set(quad.map { "\($0.minX),\($0.minY)" }).count == 4)
    }

    @Test
    func roundtableScriptFramesContextRelaysRecentAndMarksFinalRound() {
        let copy = RelayCopy(language: .chinese)

        let opening = RelayDialogueScript.roundtablePrompt(
            speakerHasSpoken: false, isFinalRound: false,
            topic: "9.11 和 9.9 谁大",
            otherNames: ["Codex", "Grok"], recent: [],
            includesContext: true, copy: copy
        )
        #expect(opening.contains("Codex / Grok"))
        #expect(opening.contains("圆桌"))
        #expect(opening.contains("9.11 和 9.9 谁大"))
        #expect(opening.contains("开场观点"))
        #expect(!opening.contains("最后一轮"))
        #expect(opening.contains("可以使用工具"))
        #expect(opening.contains("网络检索"))
        #expect(opening.contains("仅限读取"))
        #expect(!opening.contains("不要使用任何工具"))

        let relayed = RelayDialogueScript.roundtablePrompt(
            speakerHasSpoken: true, isFinalRound: true,
            topic: "话题",
            otherNames: ["Claude"],
            recent: [("Claude", "我认为 9.9 更大"), ("Grok", "同意")],
            includesContext: false, copy: copy
        )
        #expect(!relayed.contains("主题："))
        #expect(relayed.contains("【Claude】"))
        #expect(relayed.contains("我认为 9.9 更大"))
        #expect(relayed.contains("【Grok】"))
        #expect(relayed.contains("最后一轮"))
        #expect(relayed.contains("继续这场对话"))

        let twoPartyContext = RelayDialogueScript.roundtablePrompt(
            speakerHasSpoken: true, isFinalRound: false,
            topic: "话题", otherNames: ["Codex"],
            recent: [("Codex", "回应")],
            includesContext: true, copy: copy
        )
        #expect(twoPartyContext.contains("另一个 AI 智能体"))
        #expect(twoPartyContext.contains("主题："))
    }

    @MainActor
    @Test
    func dialogueWindowsRegisterInWorkspaceAndRespectLimit() {
        let store = RelayTerminalStore()
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        let first = RelayDialogueRun(relay: nil, participants: ["claude", "codex"])
        let second = RelayDialogueRun(relay: nil, participants: ["codex", "ollama"])
        let third = RelayDialogueRun(relay: nil, participants: ["a", "b"])

        store.openDialogue(first)
        store.openDialogue(second)
        #expect(store.dialogues.count == 2)
        #expect(store.orderedItems.map(\.id) == [first.id, second.id])
        #expect(store.focusedID == second.id)
        #expect(store.windowFrames[first.id] != nil)

        store.openDialogue(third)
        #expect(store.dialogues.count == 2)
        #expect(store.noticeKey == "Dialogue limit reached (2)")

        store.activate(first.id)
        #expect(store.orderedItems.map(\.id) == [second.id, first.id])

        store.closeDialogue(first)
        #expect(store.dialogues.count == 1)
        #expect(store.windowFrames[first.id] == nil)
        #expect(store.noticeKey == nil)
        #expect(store.orderedItems.map(\.id) == [second.id])
    }

    @MainActor
    @Test
    func compareAndChainWindowsRegisterLikeOtherPanels() {
        let store = RelayTerminalStore()
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        let compare = RelayCompareRun(relay: nil, preselected: ["claude", "codex"])
        let chain = RelayChainRun(relay: nil, preselected: ["claude", "codex"])

        store.openCompare(compare)
        store.openChain(chain)
        #expect(store.orderedItems.map(\.id) == [compare.id, chain.id])
        #expect(store.focusedID == chain.id)
        #expect(store.windowFrames[compare.id] != nil)
        #expect(store.windowFrames[chain.id] != nil)

        chain.append("ollama")
        chain.append("grok")
        chain.append("extra")
        #expect(chain.sequence.count == 4)
        chain.removeLastStep()
        #expect(chain.sequence == ["claude", "codex", "ollama"])

        compare.toggle("claude")
        #expect(compare.selection == ["codex"])
        compare.toggle("ollama")
        #expect(compare.selection == ["codex", "ollama"])

        store.closeCompare(compare)
        store.closeChain(chain)
        #expect(store.orderedItems.isEmpty)
        #expect(store.windowFrames.isEmpty)
    }

    @Test
    func roundtableMinutesMarkdownIncludesMetadataSpeakersAndModerator() {
        let copy = RelayCopy(language: .chinese)
        let markdown = RelayDialogueTranscript.markdown(
            topic: "AGI 会有主体性吗",
            participantNames: ["Claude", "Grok"],
            rounds: 2,
            statusLine: "对话完成",
            messages: [
                ("Claude", false, "开场观点"),
                ("Grok", false, "回应观点"),
                ("主持人", true, "请聚焦边界条件"),
                ("Claude", false, "收尾"),
            ],
            generatedAt: Date(timeIntervalSince1970: 1_784_500_000),
            copy: copy
        )
        #expect(markdown.contains("# 圆桌纪要: AGI 会有主体性吗"))
        #expect(markdown.contains("Claude ⇄ Grok"))
        #expect(markdown.contains("### 1 · Claude"))
        #expect(markdown.contains("> **主持人**：请聚焦边界条件"))
        #expect(markdown.contains("### 4 · Claude"))
        #expect(markdown.contains("对话完成"))
    }

    @Test
    func worktreeIsolationCreatesDiffsAdoptsAndRemoves() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("RelayWorktreeTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try await RelayWorktree.runGit(["-C", project.path, "init"])
        try await RelayWorktree.runGit(["-C", project.path, "config", "user.email", "relay@test"])
        try await RelayWorktree.runGit(["-C", project.path, "config", "user.name", "relay"])
        try "hello\n".write(
            to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )
        try await RelayWorktree.runGit(["-C", project.path, "add", "-A"])
        try await RelayWorktree.runGit(["-C", project.path, "commit", "-m", "base"])
        #expect(await RelayWorktree.isGitRepo(project.path))

        let worktree = root.appendingPathComponent("wt")
        let base = try await RelayWorktree.create(
            project: project.path, destination: worktree
        )
        #expect(base.count >= 7)

        try "hello world\n".write(
            to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )
        try "new\n".write(
            to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8
        )
        let stat = await RelayWorktree.shortStat(worktree: worktree.path, base: base)
        #expect(!stat.isEmpty)

        let adopted = try await RelayWorktree.adopt(
            worktree: worktree.path, base: base, into: project.path
        )
        #expect(!adopted.isEmpty)
        let merged = try String(
            contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8
        )
        #expect(merged == "hello world\n")
        #expect(fm.fileExists(atPath: project.appendingPathComponent("b.txt").path))

        await RelayWorktree.remove(project: project.path, worktree: worktree.path)
        #expect(!fm.fileExists(atPath: worktree.path))
    }

    @Test
    func approvalRulesMatchPerAgentWithTokenBoundaries() {
        let approve = RelayInteractionOption(
            value: "approve", label: "允许", description: nil
        )
        let interaction = RelayInteraction(
            id: "0", kind: .approval,
            title: "Codex wants to run a command",
            message: "$ npm run build\nBuilds the project",
            actions: [approve], questions: []
        )
        let line = RelayApprovalRules.commandLine(from: interaction)
        #expect(line == "npm run build")
        #expect(RelayApprovalRules.prefix(of: line ?? "") == "npm run")

        let rule = RelayApprovalRule(
            adapterID: "codex", commandPrefix: "npm run",
            actionValue: "approve", actionLabel: "允许",
            createdAtMilliseconds: 1
        )
        #expect(RelayApprovalRules.matches(rule, adapterID: "codex", interaction: interaction))
        #expect(!RelayApprovalRules.matches(rule, adapterID: "claude", interaction: interaction))

        let boundary = RelayInteraction(
            id: "1", kind: .approval, title: "t",
            message: "npm runx build", actions: [approve], questions: []
        )
        #expect(!RelayApprovalRules.matches(rule, adapterID: "codex", interaction: boundary))

        let wrongAction = RelayInteraction(
            id: "2", kind: .approval, title: "t",
            message: "npm run dev",
            actions: [RelayInteractionOption(value: "deny", label: "拒绝", description: nil)],
            questions: []
        )
        #expect(!RelayApprovalRules.matches(rule, adapterID: "codex", interaction: wrongAction))

        let input = RelayInteraction(
            id: "3", kind: .input, title: "t", message: "npm run dev",
            actions: [approve], questions: []
        )
        #expect(!RelayApprovalRules.matches(rule, adapterID: "codex", interaction: input))

        let suite = "RelayApprovalRulesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        RelayApprovalRules.store([rule], to: defaults)
        #expect(RelayApprovalRules.load(from: defaults) == [rule])
    }

    @Test
    func edgeSnapTargetsFireOnlyWhenFlushAgainstBounds() {
        let size = CGSize(width: 1200, height: 800)
        let area = RelayWindowGeometry.canvas(size)
            .insetBy(dx: RelayWindowGeometry.margin, dy: RelayWindowGeometry.margin)
        let halfWidth = (area.width - RelayWindowGeometry.tileGap) / 2
        let halfHeight = (area.height - RelayWindowGeometry.tileGap) / 2

        let flushLeft = CGRect(x: 0, y: 200, width: 400, height: 300)
        #expect(RelayWindowGeometry.edgeSnapTarget(flushLeft, in: size)
                == CGRect(x: area.minX, y: area.minY, width: halfWidth, height: area.height))

        let flushTopRight = CGRect(x: 800, y: 0, width: 400, height: 300)
        #expect(RelayWindowGeometry.edgeSnapTarget(flushTopRight, in: size)
                == CGRect(
                    x: area.minX + halfWidth + RelayWindowGeometry.tileGap,
                    y: area.minY, width: halfWidth, height: halfHeight
                ))

        let centered = CGRect(x: 300, y: 200, width: 400, height: 300)
        #expect(RelayWindowGeometry.edgeSnapTarget(centered, in: size) == nil)

        let spanning = CGRect(x: 0, y: 200, width: 1200, height: 300)
        #expect(RelayWindowGeometry.edgeSnapTarget(spanning, in: size) == nil)
    }

    @MainActor
    @Test
    func minimizedWindowsCollapseToDockAndRestoreOnActivate() {
        let store = RelayTerminalStore()
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))
        let first = RelayDialogueRun(relay: nil, participants: ["claude", "codex"])
        let second = RelayDialogueRun(relay: nil, participants: ["grok", "ollama"])
        store.openDialogue(first)
        store.openDialogue(second)

        store.minimizeWindow(first.id)
        #expect(store.minimizedWindows.contains(first.id))
        #expect(store.focusedID == second.id)

        store.minimizeWindow(second.id)
        #expect(store.focusedID == nil)

        store.arrangeAll()

        store.activate(first.id)
        #expect(!store.minimizedWindows.contains(first.id))
        #expect(store.focusedID == first.id)

        store.closeDialogue(second)
        #expect(!store.minimizedWindows.contains(second.id))
    }

    @MainActor
    @Test
    func approvalsWindowIsSingletonAndReopensByRaising() {
        let store = RelayTerminalStore()
        store.reportWorkspaceSize(CGSize(width: 1200, height: 800))

        store.openApprovals()
        guard let panel = store.approvalPanel else {
            Issue.record("approvals window should be registered")
            return
        }
        #expect(store.orderedItems.map(\.id) == [panel.id])
        #expect(store.focusedID == panel.id)

        let dialogue = RelayDialogueRun(relay: nil, participants: ["a", "b"])
        store.openDialogue(dialogue)
        #expect(store.focusedID == dialogue.id)

        store.openApprovals()
        #expect(store.approvalPanel?.id == panel.id)
        #expect(store.orderedItems.map(\.id) == [dialogue.id, panel.id])
        #expect(store.focusedID == panel.id)

        store.closeApprovals()
        #expect(store.approvalPanel == nil)
        #expect(store.windowFrames[panel.id] == nil)
        #expect(store.orderedItems.map(\.id) == [dialogue.id])
    }
}
