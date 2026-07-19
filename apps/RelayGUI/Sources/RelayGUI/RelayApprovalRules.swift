import Foundation

/// A user-created auto-approval rule: when a matching tool approval arrives
/// from the same agent, Relay responds automatically with the stored action.
/// Rules are explicit, visible, and deletable — never inferred.
struct RelayApprovalRule: Codable, Identifiable, Equatable {
    let id: UUID
    let adapterID: String
    /// Normalized leading tokens of the approved command (e.g. "npm test").
    let commandPrefix: String
    let actionValue: String
    let actionLabel: String
    let createdAtMilliseconds: UInt64

    init(
        id: UUID = UUID(),
        adapterID: String,
        commandPrefix: String,
        actionValue: String,
        actionLabel: String,
        createdAtMilliseconds: UInt64
    ) {
        self.id = id
        self.adapterID = adapterID
        self.commandPrefix = commandPrefix
        self.actionValue = actionValue
        self.actionLabel = actionLabel
        self.createdAtMilliseconds = createdAtMilliseconds
    }
}

enum RelayApprovalRules {
    static let defaultsKey = "approvalRules"
    static let maxRules = 64

    /// First line of the approval body with shell prompt noise stripped.
    static func commandLine(from interaction: RelayInteraction) -> String? {
        guard interaction.kind == .approval else { return nil }
        let source = interaction.message.isEmpty
            ? interaction.title : interaction.message
        guard var line = source
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) else { return nil }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("$") {
            line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return line.isEmpty ? nil : line
    }

    /// Rule pattern derived from a command line: its first two tokens.
    static func prefix(of commandLine: String) -> String {
        commandLine
            .split(separator: " ", omittingEmptySubsequences: true)
            .prefix(2)
            .joined(separator: " ")
    }

    /// Token-boundary prefix match, scoped to one agent, and only when the
    /// stored action is actually offered by the interaction.
    static func matches(
        _ rule: RelayApprovalRule,
        adapterID: String,
        interaction: RelayInteraction
    ) -> Bool {
        guard rule.adapterID == adapterID,
              interaction.kind == .approval,
              interaction.questions.isEmpty,
              interaction.actions.contains(where: { $0.value == rule.actionValue }),
              let line = commandLine(from: interaction) else { return false }
        let tokens = line
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let ruleTokens = rule.commandPrefix
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !ruleTokens.isEmpty, tokens.count >= ruleTokens.count else {
            return false
        }
        return Array(tokens.prefix(ruleTokens.count)) == ruleTokens
    }

    static func load(from defaults: UserDefaults = .standard) -> [RelayApprovalRule] {
        guard let data = defaults.data(forKey: defaultsKey),
              let rules = try? JSONDecoder().decode(
                  [RelayApprovalRule].self, from: data
              ) else { return [] }
        return rules
    }

    static func store(
        _ rules: [RelayApprovalRule], to defaults: UserDefaults = .standard
    ) {
        let capped = Array(rules.prefix(maxRules))
        if let data = try? JSONEncoder().encode(capped) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
