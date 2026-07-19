import Foundation

enum RelayMarkdownBlock: Equatable {
    case paragraph(String)
    case code(language: String?, text: String)
}

enum RelayMarkdown {
    static func blocks(_ text: String) -> [RelayMarkdownBlock] {
        var blocks: [RelayMarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var insideCode = false

        func flushParagraph() {
            var lines = paragraph
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            if !lines.isEmpty {
                blocks.append(.paragraph(lines.joined(separator: "\n")))
            }
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if insideCode {
                    blocks.append(.code(
                        language: codeLanguage,
                        text: codeLines.joined(separator: "\n")
                    ))
                    codeLines = []
                    codeLanguage = nil
                    insideCode = false
                } else {
                    flushParagraph()
                    let language = trimmed.dropFirst(3)
                        .trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                    insideCode = true
                }
                continue
            }
            if insideCode {
                codeLines.append(line)
            } else {
                paragraph.append(line)
            }
        }
        if insideCode {
            blocks.append(.code(
                language: codeLanguage,
                text: codeLines.joined(separator: "\n")
            ))
        } else {
            flushParagraph()
        }
        return blocks
    }

    static func exportMarkdown(
        task: RelayTask,
        output: [RelayTaskOutput],
        copy: RelayCopy
    ) -> String {
        var lines: [String] = [
            "# \(task.displayTitle)",
            "",
            "- Agent: \(task.adapterID)",
            "- Status: \(copy.taskStatus(task.status))",
            "- Directory: `\(task.cwd)`",
            "- Thread: \(task.id)",
            "",
            "---",
            "",
        ]
        for item in output {
            switch item.kind {
            case .user:
                lines.append("## \(copy.outputKind(.user))")
                lines.append("")
                lines.append(item.text)
            case .assistant:
                lines.append(item.text)
            case .tool, .system, .error:
                lines.append("<details><summary>\(copy.outputKind(item.kind))</summary>")
                lines.append("")
                lines.append("```")
                lines.append(item.text)
                lines.append("```")
                lines.append("")
                lines.append("</details>")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
