import Foundation

/// Deterministic unified-diff parsing and reassembly for selective adoption:
/// a `git diff` patch is split into files and hunks, the user picks a subset,
/// and a valid patch is rebuilt with hunk headers re-based so `git apply`
/// receives exact target line numbers even when earlier hunks were dropped.
enum RelayDiffPatch {
    struct Hunk: Identifiable, Equatable {
        /// Position of the hunk within its file section (0-based).
        let id: Int
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        /// Trailing context on the `@@` line (function name etc.), may be empty.
        let heading: String
        /// Body lines exactly as emitted by git (leading ' ', '+', '-', '\').
        let lines: [String]

        var added: Int { lines.filter { $0.hasPrefix("+") }.count }
        var removed: Int { lines.filter { $0.hasPrefix("-") }.count }

        func headerLine(newStart adjustedNewStart: Int) -> String {
            let old = oldCount == 1 ? "-\(oldStart)" : "-\(oldStart),\(oldCount)"
            let new = newCount == 1
                ? "+\(adjustedNewStart)" : "+\(adjustedNewStart),\(newCount)"
            let suffix = heading.isEmpty ? "" : " \(heading)"
            return "@@ \(old) \(new) @@\(suffix)"
        }
    }

    struct FileDiff: Identifiable, Equatable {
        /// Position of the file within the patch (0-based).
        let id: Int
        /// Header lines verbatim: `diff --git`, mode/index/rename lines,
        /// `---`/`+++` when present.
        let headerLines: [String]
        /// Path shown to the user (the post-image path when available).
        let displayPath: String
        /// Binary sections carry no applicable hunks and cannot be adopted
        /// through a text patch.
        let isBinary: Bool
        let hunks: [Hunk]
    }

    /// One selected hunk; a file with no hunks (pure rename / mode change)
    /// is addressed with `hunk == nil`.
    struct Selection: Hashable {
        let file: Int
        let hunk: Int?
    }

    static func parse(_ patch: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var headerLines: [String] = []
        var hunks: [Hunk] = []
        var currentHunkHeader: (Int, Int, Int, Int, String)?
        var currentHunkLines: [String] = []
        var oldRemaining = 0
        var newRemaining = 0
        var isBinary = false

        func closeHunk() {
            if let (oldStart, oldCount, newStart, newCount, heading) = currentHunkHeader {
                hunks.append(Hunk(
                    id: hunks.count,
                    oldStart: oldStart, oldCount: oldCount,
                    newStart: newStart, newCount: newCount,
                    heading: heading, lines: currentHunkLines
                ))
            }
            currentHunkHeader = nil
            currentHunkLines = []
            oldRemaining = 0
            newRemaining = 0
        }

        func closeFile() {
            closeHunk()
            guard !headerLines.isEmpty else { return }
            files.append(FileDiff(
                id: files.count,
                headerLines: headerLines,
                displayPath: displayPath(of: headerLines),
                isBinary: isBinary,
                hunks: hunks
            ))
            headerLines = []
            hunks = []
            isBinary = false
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init) {
            if line.hasPrefix("diff --git ") {
                closeFile()
                headerLines.append(line)
            } else if headerLines.isEmpty {
                continue
            } else if let header = parseHunkHeader(line) {
                closeHunk()
                currentHunkHeader = header
                oldRemaining = header.1
                newRemaining = header.3
            } else if currentHunkHeader != nil, oldRemaining > 0 || newRemaining > 0 {
                if line.hasPrefix("+") {
                    newRemaining -= 1
                    currentHunkLines.append(line)
                } else if line.hasPrefix("-") {
                    oldRemaining -= 1
                    currentHunkLines.append(line)
                } else if line.hasPrefix("\\") {
                    currentHunkLines.append(line)
                } else {
                    // Context line; a fully blank one may arrive without its
                    // leading space if trailing whitespace was stripped.
                    oldRemaining -= 1
                    newRemaining -= 1
                    currentHunkLines.append(line.isEmpty ? " " : line)
                }
            } else if currentHunkHeader != nil, line.hasPrefix("\\") {
                currentHunkLines.append(line)
            } else {
                closeHunk()
                if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                    isBinary = true
                }
                if !line.isEmpty {
                    headerLines.append(line)
                }
            }
        }
        closeFile()
        return files
    }

    /// Rebuilds a patch containing only the selected hunks. Hunk headers are
    /// re-based: each retained hunk's `+` start shifts by the net line delta
    /// of dropped hunks that precede it in the same file. Binary files are
    /// never emitted. Returns an empty string when nothing usable is selected.
    static func assemble(files: [FileDiff], selected: Set<Selection>) -> String {
        var sections: [String] = []
        for file in files where !file.isBinary {
            let wholeFile = selected.contains(Selection(file: file.id, hunk: nil))
            let chosen = file.hunks.filter {
                wholeFile || selected.contains(Selection(file: file.id, hunk: $0.id))
            }
            if file.hunks.isEmpty {
                if wholeFile {
                    sections.append(file.headerLines.joined(separator: "\n"))
                }
                continue
            }
            guard !chosen.isEmpty else { continue }
            var lines = file.headerLines
            var delta = 0
            var kept = chosen.makeIterator()
            var next = kept.next()
            for hunk in file.hunks {
                if let current = next, current.id == hunk.id {
                    lines.append(hunk.headerLine(newStart: hunk.newStart - delta))
                    lines.append(contentsOf: hunk.lines)
                    next = kept.next()
                } else {
                    delta += hunk.added - hunk.removed
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        guard !sections.isEmpty else { return "" }
        return sections.joined(separator: "\n") + "\n"
    }

    static func selectAll(_ files: [FileDiff]) -> Set<Selection> {
        var selected = Set<Selection>()
        for file in files where !file.isBinary {
            if file.hunks.isEmpty {
                selected.insert(Selection(file: file.id, hunk: nil))
            } else {
                for hunk in file.hunks {
                    selected.insert(Selection(file: file.id, hunk: hunk.id))
                }
            }
        }
        return selected
    }

    /// `@@ -old[,count] +new[,count] @@ heading`
    private static func parseHunkHeader(
        _ line: String
    ) -> (Int, Int, Int, Int, String)? {
        guard line.hasPrefix("@@ ") else { return nil }
        guard let close = line.range(of: " @@", range: line.index(line.startIndex, offsetBy: 3)..<line.endIndex) else {
            return nil
        }
        let ranges = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound]
            .split(separator: " ")
        guard ranges.count == 2,
              let old = parseRange(ranges[0], prefix: "-"),
              let new = parseRange(ranges[1], prefix: "+") else {
            return nil
        }
        let heading = String(line[close.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        return (old.0, old.1, new.0, new.1, heading)
    }

    private static func parseRange(
        _ value: Substring, prefix: String
    ) -> (Int, Int)? {
        guard value.hasPrefix(prefix) else { return nil }
        let parts = value.dropFirst().split(separator: ",")
        guard let start = Int(parts.first ?? "") else { return nil }
        let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        return (start, count)
    }

    private static func displayPath(of headerLines: [String]) -> String {
        for line in headerLines {
            if line.hasPrefix("+++ b/") {
                return String(line.dropFirst(6))
            }
            if line.hasPrefix("rename to ") {
                return String(line.dropFirst(10))
            }
        }
        for line in headerLines {
            if line.hasPrefix("--- a/") {
                return String(line.dropFirst(6))
            }
        }
        if let first = headerLines.first, first.hasPrefix("diff --git a/") {
            let trimmed = first.dropFirst("diff --git a/".count)
            if let separator = trimmed.range(of: " b/") {
                return String(trimmed[separator.upperBound...])
            }
        }
        return headerLines.first ?? "?"
    }
}
