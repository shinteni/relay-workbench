import Foundation

/// Optional self-verification appendix for orchestration prompts: one
/// checkbox appends a fixed instruction asking the agent to verify its own
/// work before delivering. Nothing is inferred — the appendix is part of the
/// same prompt, visible to the agent, and off by default.
enum RelaySelfCheck {
    static let compareDefaultsKey = "selfCheckCompare"
    static let chainDefaultsKey = "selfCheckChain"

    static func isEnabled(
        key: String, defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setEnabled(
        _ enabled: Bool, key: String, defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: key)
    }

    /// Appends the self-check instruction when enabled; otherwise returns the
    /// prompt untouched.
    static func apply(
        _ prompt: String, enabled: Bool, language: RelayLanguage
    ) -> String {
        guard enabled else { return prompt }
        let copy = RelayCopy(language: language)
        return prompt + "\n\n---\n" + copy.text(
            "After finishing, run a self-check: verify each requirement above is met, actually test what can be tested, fix anything you find before delivering, and end with one line stating the self-check result."
        )
    }
}
