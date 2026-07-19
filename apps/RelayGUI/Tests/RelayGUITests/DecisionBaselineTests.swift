import Foundation
import Testing
@testable import RelayGUI

struct DecisionBaselineTests {
    @Test
    func legacyCheckpointsDecodeWithoutBaseline() throws {
        let legacy = """
        {
          "schemaVersion": 1,
          "id": "55555555-5555-5555-5555-555555555555",
          "savedAt": "2026-07-01T00:00:00Z",
          "decision": {
            "id": "11111111-1111-1111-1111-111111111111",
            "receipt": {
              "confluence": {"id": "22222222-2222-2222-2222-222222222222", "snapshots": []},
              "plan": {"payload": "p", "sources": []},
              "targetID": "33333333-3333-3333-3333-333333333333"
            },
            "result": {
              "id": "44444444-4444-4444-4444-444444444444",
              "agentName": "Claude",
              "projectName": "demo",
              "text": "verdict"
            }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let checkpoint = try decoder.decode(
            RelayDecisionCheckpoint.self, from: Data(legacy.utf8)
        )
        #expect(checkpoint.baseline == nil)
    }

    @Test
    func captureAndDriftAgainstRealRepository() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("RelayBaselineTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Not a repository yet → capture declines.
        #expect(await RelayDecisionBaseline.capture(projectPath: root.path) == nil)

        try await RelayWorktree.runGit(["-C", root.path, "init"])
        try await RelayWorktree.runGit(["-C", root.path, "config", "user.email", "relay@test"])
        try await RelayWorktree.runGit(["-C", root.path, "config", "user.name", "relay"])
        try "one\n".write(
            to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8
        )
        try await RelayWorktree.runGit(["-C", root.path, "add", "-A"])
        try await RelayWorktree.runGit(["-C", root.path, "commit", "-m", "base"])

        let clean = try #require(
            await RelayDecisionBaseline.capture(projectPath: root.path)
        )
        #expect(clean.commit.count >= 7)
        #expect(!clean.dirty)
        #expect(await clean.checkDrift() == .unchanged(dirtyNow: false))

        try "two\n".write(
            to: root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8
        )
        let dirty = try #require(
            await RelayDecisionBaseline.capture(projectPath: root.path)
        )
        #expect(dirty.dirty)
        #expect(await clean.checkDrift() == .unchanged(dirtyNow: true))

        try await RelayWorktree.runGit(["-C", root.path, "add", "-A"])
        try await RelayWorktree.runGit(["-C", root.path, "commit", "-m", "next"])
        let drift = await clean.checkDrift()
        guard case .moved(let current, let dirtyNow) = drift else {
            Issue.record("expected moved, got \(drift)")
            return
        }
        #expect(current != clean.commit)
        #expect(!dirtyNow)

        let gone = RelayDecisionBaseline(
            projectPath: root.appendingPathComponent("nope").path,
            commit: clean.commit,
            dirty: false
        )
        #expect(await gone.checkDrift() == .missing)
    }
}
