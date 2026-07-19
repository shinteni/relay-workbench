import Foundation

/// A named seat preset: an underlying agent plus explicit option overrides
/// and extra rules text. Personas are user-authored configuration — they are
/// stored locally, applied visibly (rules become part of the prompt), and
/// never inferred.
struct RelayPersona: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var agentID: String
    var options: [String: String]
    var rules: String

    init(
        id: UUID = UUID(),
        name: String,
        agentID: String,
        options: [String: String] = [:],
        rules: String = ""
    ) {
        self.id = id
        self.name = name
        self.agentID = agentID
        self.options = options
        self.rules = rules
    }
}

/// A member reference resolved for dispatch: either a plain agent or a
/// persona expanded into its underlying agent, overrides, and rules.
struct RelayMemberResolution: Equatable {
    let memberID: String
    let agentID: String
    let displayName: String
    let optionOverrides: [String: String]
    let rules: String
}

enum RelayPersonaStore {
    static let defaultsKey = "agentPersonas"
    static let maxCount = 24
    static let maxNameBytes = 48
    static let maxRulesBytes = 4000
    private static let memberPrefix = "persona:"

    static func load(defaults: UserDefaults = .standard) -> [RelayPersona] {
        guard let data = defaults.data(forKey: defaultsKey),
              let personas = try? JSONDecoder().decode(
                  [RelayPersona].self, from: data
              ) else {
            return []
        }
        return Array(personas.prefix(maxCount))
    }

    static func save(
        _ personas: [RelayPersona], defaults: UserDefaults = .standard
    ) {
        let bounded = Array(personas.prefix(maxCount))
        if let data = try? JSONEncoder().encode(bounded) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    static func memberID(for persona: RelayPersona) -> String {
        memberPrefix + persona.id.uuidString
    }

    static func personaID(fromMember memberID: String) -> UUID? {
        guard memberID.hasPrefix(memberPrefix) else { return nil }
        return UUID(uuidString: String(memberID.dropFirst(memberPrefix.count)))
    }

    /// Validation reason (English key for `copy.text`) or nil when valid.
    static func validationError(name: String, rules: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.utf8.count > maxNameBytes
            || trimmed.contains(where: \.isNewline) {
            return "Preset name must be 1–48 bytes on a single line"
        }
        if rules.utf8.count > maxRulesBytes {
            return "Preset rules must stay within 4000 bytes"
        }
        return nil
    }

    /// Resolves a member ID (agent ID or `persona:<uuid>`) for dispatch.
    /// Returns nil when the persona or its underlying agent no longer exists.
    static func resolve(
        memberID: String,
        personas: [RelayPersona],
        agents: [RelayAgent]
    ) -> RelayMemberResolution? {
        if let personaID = personaID(fromMember: memberID) {
            guard let persona = personas.first(where: { $0.id == personaID }),
                  agents.contains(where: { $0.id == persona.agentID }) else {
                return nil
            }
            return RelayMemberResolution(
                memberID: memberID,
                agentID: persona.agentID,
                displayName: persona.name,
                optionOverrides: persona.options,
                rules: persona.rules
            )
        }
        guard let agent = agents.first(where: { $0.id == memberID }) else {
            return nil
        }
        return RelayMemberResolution(
            memberID: memberID,
            agentID: agent.id,
            displayName: agent.name,
            optionOverrides: [:],
            rules: ""
        )
    }

    /// Prepends persona rules to a prompt as a visible block.
    static func applyRules(_ rules: String, to prompt: String) -> String {
        let trimmed = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prompt }
        return trimmed + "\n\n---\n\n" + prompt
    }
}
