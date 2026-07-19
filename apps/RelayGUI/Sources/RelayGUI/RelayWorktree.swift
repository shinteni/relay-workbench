import Foundation

/// Git worktree isolation for parallel implementation runs: every compare
/// member works in its own detached worktree so agents never stomp each
/// other's files; the winning diff can be adopted back into the project.
enum RelayWorktree {
    struct GitError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Root directory holding Relay-managed worktrees, outside any project.
    static var worktreeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Relay/worktrees", isDirectory: true)
    }

    @discardableResult
    static func runGit(
        _ arguments: [String], stdin: Data? = nil
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            let output = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = output
            process.standardError = errorPipe
            if let stdin {
                let input = Pipe()
                process.standardInput = input
                try process.run()
                input.fileHandleForWriting.write(stdin)
                input.fileHandleForWriting.closeFile()
            } else {
                try process.run()
            }
            let outData = output.fileHandleForReading.readDataToEndOfFile()
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw GitError(message: String(decoding: errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    static func isGitRepo(_ path: String) async -> Bool {
        (try? await runGit(["-C", path, "rev-parse", "--git-dir"])) != nil
    }

    /// Creates a detached worktree of the project and returns its base commit.
    static func create(
        project: String, destination: URL
    ) async throws -> String {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await runGit([
            "-C", project, "worktree", "add", "--detach", destination.path,
        ])
        return try await runGit(["-C", destination.path, "rev-parse", "HEAD"])
    }

    /// Short summary of everything changed versus the base commit
    /// (committed and uncommitted alike). Empty string when untouched.
    static func shortStat(worktree: String, base: String) async -> String {
        let stat = (try? await runGit([
            "-C", worktree, "diff", "--shortstat", base,
        ])) ?? ""
        if !stat.isEmpty { return stat }
        let untracked = (try? await runGit([
            "-C", worktree, "ls-files", "--others", "--exclude-standard",
        ])) ?? ""
        let count = untracked.isEmpty
            ? 0 : untracked.split(separator: "\n").count
        return count > 0 ? "+\(count) new file(s)" : ""
    }

    /// Applies the worktree's changes (vs. base) onto the project tree.
    /// Returns a human-readable summary; throws when the patch cannot apply.
    static func adopt(
        worktree: String, base: String, into project: String
    ) async throws -> String {
        // Stage untracked files so they are part of the diff, without
        // committing anything in the worktree.
        _ = try? await runGit(["-C", worktree, "add", "-A", "-N"])
        let patch = try await runGit(["-C", worktree, "diff", base])
        guard !patch.isEmpty else {
            return ""
        }
        try await runGit(
            ["-C", project, "apply", "--whitespace=nowarn"],
            stdin: Data((patch + "\n").utf8)
        )
        return (try? await runGit([
            "-C", worktree, "diff", "--shortstat", base,
        ])) ?? ""
    }

    static func remove(project: String, worktree: String) async {
        _ = try? await runGit([
            "-C", project, "worktree", "remove", "--force", worktree,
        ])
        _ = try? await runGit(["-C", project, "worktree", "prune"])
    }
}
