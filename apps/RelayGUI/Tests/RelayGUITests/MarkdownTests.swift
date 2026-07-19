import Foundation
import Testing
@testable import RelayGUI

struct MarkdownTests {
    @Test
    func splitsFencedCodeBlocksFromParagraphs() {
        let blocks = RelayMarkdown.blocks("""
        说明第一段。

        ```swift
        let value = 1
        ```

        结尾说明。
        """)

        #expect(blocks == [
            .paragraph("说明第一段。"),
            .code(language: "swift", text: "let value = 1"),
            .paragraph("结尾说明。"),
        ])
    }

    @Test
    func unterminatedFenceStillYieldsCodeBlock() {
        let blocks = RelayMarkdown.blocks("前文\n```\nraw line")

        #expect(blocks == [
            .paragraph("前文"),
            .code(language: nil, text: "raw line"),
        ])
    }

    @Test
    func exportContainsMetadataUserHeadingAndCollapsedTool() {
        let copy = RelayCopy(language: .chinese)
        let markdown = RelayMarkdown.exportMarkdown(
            task: RelayTask(
                id: "task-1",
                adapterID: "ollama",
                promptPreview: "问题",
                title: "对比结论",
                pendingInteraction: nil,
                cwd: "/tmp/project",
                status: .completed,
                createdAtMilliseconds: 1,
                updatedAtMilliseconds: 2,
                latestMessage: nil,
                sessionID: nil,
                turnCount: 1,
                adapterOptions: [:]
            ),
            output: [
                RelayTaskOutput(sequence: 0, timestampMilliseconds: 1, kind: .user, text: "问题"),
                RelayTaskOutput(sequence: 1, timestampMilliseconds: 2, kind: .tool, text: "$ ls"),
                RelayTaskOutput(sequence: 2, timestampMilliseconds: 3, kind: .assistant, text: "答案"),
            ],
            copy: copy
        )

        #expect(markdown.hasPrefix("# 对比结论"))
        #expect(markdown.contains("- Agent: ollama"))
        #expect(markdown.contains("## \(copy.outputKind(.user))"))
        #expect(markdown.contains("<details><summary>\(copy.outputKind(.tool))</summary>"))
        #expect(markdown.contains("答案"))
    }
}
