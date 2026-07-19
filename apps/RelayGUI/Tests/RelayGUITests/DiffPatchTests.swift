import Foundation
import Testing
@testable import RelayGUI

struct DiffPatchTests {
    private let sample = """
    diff --git a/a.txt b/a.txt
    index 1111111..2222222 100644
    --- a/a.txt
    +++ b/a.txt
    @@ -1,3 +1,4 @@ heading
     one
    +added-early
     two
     three
    @@ -10,2 +11,3 @@
     ten
    +added-late
     eleven
    diff --git a/new.txt b/new.txt
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +first
    +second
    diff --git a/logo.png b/logo.png
    index 4444444..5555555 100644
    Binary files a/logo.png and b/logo.png differ
    diff --git a/old-name.txt b/new-name.txt
    similarity index 100%
    rename from old-name.txt
    rename to new-name.txt
    """

    @Test
    func parsesFilesHunksCountsAndKinds() {
        let files = RelayDiffPatch.parse(sample)
        #expect(files.count == 4)

        #expect(files[0].displayPath == "a.txt")
        #expect(files[0].hunks.count == 2)
        #expect(files[0].hunks[0].heading == "heading")
        #expect(files[0].hunks[0].added == 1)
        #expect(files[0].hunks[0].removed == 0)
        #expect(files[0].hunks[1].newStart == 11)

        #expect(files[1].displayPath == "new.txt")
        #expect(files[1].hunks.count == 1)
        #expect(files[1].hunks[0].added == 2)

        #expect(files[2].displayPath == "logo.png")
        #expect(files[2].isBinary)
        #expect(files[2].hunks.isEmpty)

        #expect(files[3].displayPath == "new-name.txt")
        #expect(!files[3].isBinary)
        #expect(files[3].hunks.isEmpty)
    }

    @Test
    func assemblingEverythingReproducesTextSections() {
        let files = RelayDiffPatch.parse(sample)
        let everything = RelayDiffPatch.assemble(
            files: files, selected: RelayDiffPatch.selectAll(files)
        )
        // Binary sections are excluded; text sections survive verbatim.
        #expect(!everything.contains("Binary files"))
        #expect(everything.contains("diff --git a/a.txt b/a.txt"))
        #expect(everything.contains("@@ -1,3 +1,4 @@ heading"))
        #expect(everything.contains("@@ -10,2 +11,3 @@"))
        #expect(everything.contains("rename to new-name.txt"))
        #expect(everything.hasSuffix("\n"))
        #expect(RelayDiffPatch.selectAll(files).count == 4)
    }

    @Test
    func droppingAnEarlierHunkRebasesLaterTargets() {
        let files = RelayDiffPatch.parse(sample)
        let onlyLate = RelayDiffPatch.assemble(
            files: files,
            selected: [RelayDiffPatch.Selection(file: 0, hunk: 1)]
        )
        // The first hunk added one line; without it the second hunk's target
        // start shifts from 11 back to 10. The old side is untouched.
        #expect(onlyLate.contains("@@ -10,2 +10,3 @@"))
        #expect(!onlyLate.contains("added-early"))
        #expect(onlyLate.contains("added-late"))
    }

    @Test
    func selectionsAreScopedPerFile() {
        let files = RelayDiffPatch.parse(sample)
        let newFileOnly = RelayDiffPatch.assemble(
            files: files,
            selected: [RelayDiffPatch.Selection(file: 1, hunk: 0)]
        )
        #expect(newFileOnly.contains("new file mode"))
        #expect(!newFileOnly.contains("a.txt"))

        let renameOnly = RelayDiffPatch.assemble(
            files: files,
            selected: [RelayDiffPatch.Selection(file: 3, hunk: nil)]
        )
        #expect(renameOnly.contains("rename from old-name.txt"))
        #expect(!renameOnly.contains("@@"))

        #expect(RelayDiffPatch.assemble(files: files, selected: []).isEmpty)
    }

    @Test
    func binaryFilesAreNeverAssembled() {
        let files = RelayDiffPatch.parse(sample)
        let attempted = RelayDiffPatch.assemble(
            files: files,
            selected: [RelayDiffPatch.Selection(file: 2, hunk: nil)]
        )
        #expect(attempted.isEmpty)
    }

    @Test
    func shorthandHeadersAndNoNewlineMarkersRoundTrip() {
        let patch = """
        diff --git a/x b/x
        index 1..2 100644
        --- a/x
        +++ b/x
        @@ -1 +1 @@
        -old
        +new
        \\ No newline at end of file
        """
        let files = RelayDiffPatch.parse(patch)
        #expect(files.count == 1)
        #expect(files[0].hunks[0].oldCount == 1)
        #expect(files[0].hunks[0].lines.last == "\\ No newline at end of file")
        let out = RelayDiffPatch.assemble(
            files: files, selected: RelayDiffPatch.selectAll(files)
        )
        #expect(out.contains("@@ -1 +1 @@"))
        #expect(out.contains("\\ No newline at end of file"))
    }

    @Test
    func selectiveAdoptionAppliesOnlyChosenHunksToRealRepo() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("RelayHunkTests-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try await RelayWorktree.runGit(["-C", project.path, "init"])
        try await RelayWorktree.runGit(["-C", project.path, "config", "user.email", "relay@test"])
        try await RelayWorktree.runGit(["-C", project.path, "config", "user.name", "relay"])
        let baseLines = (1...99).map { "line\($0)" }
        try (baseLines.joined(separator: "\n") + "\n").write(
            to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )
        try "keep\n".write(
            to: project.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8
        )
        try await RelayWorktree.runGit(["-C", project.path, "add", "-A"])
        try await RelayWorktree.runGit(["-C", project.path, "commit", "-m", "base"])

        let worktree = root.appendingPathComponent("wt")
        let base = try await RelayWorktree.create(
            project: project.path, destination: worktree
        )

        // Two far-apart edits in a.txt (two hunks), one edit in b.txt, one new file.
        var editedLines = baseLines
        editedLines[1] = "line2-EDITED-TOP"
        editedLines[96] = "line97-EDITED-BOTTOM"
        try (editedLines.joined(separator: "\n") + "\n").write(
            to: worktree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8
        )
        try "keep\nb-changed\n".write(
            to: worktree.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8
        )
        try "fresh\n".write(
            to: worktree.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8
        )

        let patch = try await RelayWorktree.changesPatch(
            worktree: worktree.path, base: base
        )
        let files = RelayDiffPatch.parse(patch)
        let a = try #require(files.first { $0.displayPath == "a.txt" })
        let c = try #require(files.first { $0.displayPath == "c.txt" })
        #expect(a.hunks.count == 2)

        // Adopt only a.txt's second hunk plus the new file; skip b.txt entirely.
        let selected: Set<RelayDiffPatch.Selection> = [
            .init(file: a.id, hunk: a.hunks[1].id),
            .init(file: c.id, hunk: c.hunks.first?.id),
        ]
        let subset = RelayDiffPatch.assemble(files: files, selected: selected)
        try await RelayWorktree.applyPatch(subset, into: project.path)

        let mergedA = try String(
            contentsOf: project.appendingPathComponent("a.txt"), encoding: .utf8
        )
        #expect(mergedA.contains("line97-EDITED-BOTTOM"))
        #expect(!mergedA.contains("line2-EDITED-TOP"))
        let mergedB = try String(
            contentsOf: project.appendingPathComponent("b.txt"), encoding: .utf8
        )
        #expect(mergedB == "keep\n")
        let mergedC = try String(
            contentsOf: project.appendingPathComponent("c.txt"), encoding: .utf8
        )
        #expect(mergedC == "fresh\n")

        await RelayWorktree.remove(project: project.path, worktree: worktree.path)
    }
}
