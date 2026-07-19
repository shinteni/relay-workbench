import Foundation
import Testing
@testable import RelayGUI

struct ClaudeModelsTests {
    @Test
    func familyMaximaPreferVersionTuplesOverDateSuffixes() {
        let harvested: Set<String> = [
            "claude-opus-4-8", "claude-opus-4-20250514", "claude-opus-4-1-20250805",
            "claude-opus-4-6", "claude-sonnet-5", "claude-sonnet-4-6",
            "claude-sonnet-4-5-20250929", "claude-haiku-4-5",
            "claude-haiku-4-5-20251001", "claude-fable-5",
        ]

        #expect(RelayClaudeModels.familyMaxima(harvested) == [
            "claude-fable-5",
            "claude-opus-4-8",
            "claude-sonnet-5",
            "claude-haiku-4-5",
        ])
    }

    @Test
    func scanExtractsIdentifiersFromBinaryBytes() {
        let blob = Data("garbage\0claude-fable-5\0more\0claude-opus-4-8\0claude-unrelated-thing".utf8)

        let found = RelayClaudeModels.scan(blob)

        #expect(found.contains("claude-fable-5"))
        #expect(found.contains("claude-opus-4-8"))
        #expect(found.contains("claude-unrelated-thing") == false)
        #expect(found.allSatisfy { $0.hasPrefix("claude-") })

        let compound = RelayClaudeModels.scan(
            Data("x\0claude-fable-5-mythos-5\0claude-fable-5\0".utf8)
        )
        #expect(compound.contains("claude-fable-5"))
        #expect(compound.contains("claude-fable-5-mythos-5") == false)
    }

    @Test
    func accountExtrasReadAdditionalModelOptions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-config-\(UUID().uuidString).json")
        try Data("""
        {"additionalModelOptionsCache": [
            {"value": "claude-fable-5[1m]", "label": "Fable"},
            {"value": "", "label": "empty"}
        ]}
        """.utf8).write(to: url)

        #expect(RelayClaudeModels.accountExtras(url) == ["claude-fable-5[1m]"])
        #expect(RelayClaudeModels.accountExtras(url.appendingPathExtension("missing")).isEmpty)
    }
}
