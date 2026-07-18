import Foundation
import Testing
@testable import RelayGUI

@Suite("RelayLocalizationTests")
struct RelayLocalizationTests {
    @Test("defaults to Chinese and persists Japanese")
    func persistsSelectedLanguage() throws {
        let suiteName = "RelayLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(RelayLanguage.load(from: defaults) == .chinese)
        RelayLanguage.japanese.save(to: defaults)
        #expect(RelayLanguage.load(from: defaults) == .japanese)
    }

    @Test("provides Chinese and Japanese interface copy")
    func translatesInterfaceCopy() {
        let chinese = RelayCopy(language: .chinese)
        let japanese = RelayCopy(language: .japanese)

        #expect(chinese.text("Settings") == "设置")
        #expect(japanese.text("Settings") == "設定")
        #expect(chinese.taskStatus(.waitingForInput) == "等待输入")
        #expect(japanese.taskStatus(.waitingForInput) == "入力待ち")
        #expect(chinese.codexMode(.plan) == "计划")
        #expect(japanese.codexMode(.plan) == "計画")
    }

    @Test("keeps unknown CLI text unchanged")
    func preservesUnknownText() {
        let copy = RelayCopy(language: .japanese)
        #expect(copy.text("MODEL_OUTPUT_FROM_CLI") == "MODEL_OUTPUT_FROM_CLI")
    }
}
