import Foundation
import Testing
@testable import RelayGUI

struct SelfCheckTests {
    @Test
    func disabledLeavesThePromptUntouched() {
        #expect(
            RelaySelfCheck.apply("修好这个 bug", enabled: false, language: .chinese)
                == "修好这个 bug"
        )
    }

    @Test
    func enabledAppendsTheLocalizedAppendixOnce() {
        let applied = RelaySelfCheck.apply(
            "修好这个 bug", enabled: true, language: .chinese
        )
        #expect(applied.hasPrefix("修好这个 bug\n\n---\n"))
        #expect(applied.contains("自检"))
        #expect(applied.contains("最后用一行说明自检结果"))

        let japanese = RelaySelfCheck.apply(
            "バグを直す", enabled: true, language: .japanese
        )
        #expect(japanese.contains("セルフチェック"))
    }

    @Test
    func togglePersistsPerWindowKind() {
        let defaults = UserDefaults(suiteName: "SelfCheckTests-\(UUID())")!
        #expect(!RelaySelfCheck.isEnabled(
            key: RelaySelfCheck.compareDefaultsKey, defaults: defaults
        ))
        RelaySelfCheck.setEnabled(
            true, key: RelaySelfCheck.compareDefaultsKey, defaults: defaults
        )
        #expect(RelaySelfCheck.isEnabled(
            key: RelaySelfCheck.compareDefaultsKey, defaults: defaults
        ))
        #expect(!RelaySelfCheck.isEnabled(
            key: RelaySelfCheck.chainDefaultsKey, defaults: defaults
        ))
    }
}
