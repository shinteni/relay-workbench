import Foundation
import Testing
@testable import RelayGUI

struct PersonaTests {
    private func agent(_ id: String, name: String) -> RelayAgent {
        RelayAgent(
            id: id,
            name: name,
            detail: "",
            manifestURL: URL(fileURLWithPath: "/tmp/\(id).json"),
            adapterExecutablePath: "/tmp/adapter",
            usesGenericRuntime: false,
            registrationEnvironment: [:],
            capabilities: [],
            versionExecutablePath: nil,
            versionArguments: [],
            version: nil,
            health: .ready
        )
    }

    @Test
    func plainAgentIDsResolveWithoutOverrides() {
        let resolved = RelayPersonaStore.resolve(
            memberID: "claude",
            personas: [],
            agents: [agent("claude", name: "Claude")]
        )
        #expect(resolved == RelayMemberResolution(
            memberID: "claude",
            agentID: "claude",
            displayName: "Claude",
            optionOverrides: [:],
            rules: ""
        ))
        #expect(RelayPersonaStore.resolve(
            memberID: "missing", personas: [], agents: []
        ) == nil)
    }

    @Test
    func personaMemberIDsRoundTripAndResolve() {
        let persona = RelayPersona(
            name: "评审员",
            agentID: "claude",
            options: ["claude_effort": "high"],
            rules: "只做代码评审。"
        )
        let memberID = RelayPersonaStore.memberID(for: persona)
        #expect(RelayPersonaStore.personaID(fromMember: memberID) == persona.id)
        #expect(RelayPersonaStore.personaID(fromMember: "claude") == nil)

        let resolved = RelayPersonaStore.resolve(
            memberID: memberID,
            personas: [persona],
            agents: [agent("claude", name: "Claude")]
        )
        #expect(resolved?.displayName == "评审员")
        #expect(resolved?.agentID == "claude")
        #expect(resolved?.optionOverrides == ["claude_effort": "high"])
        #expect(resolved?.rules == "只做代码评审。")

        // Persona whose underlying agent vanished resolves to nil.
        #expect(RelayPersonaStore.resolve(
            memberID: memberID, personas: [persona], agents: []
        ) == nil)
    }

    @Test
    func rulesPrependVisiblyAndEmptyRulesAreNoOp() {
        #expect(
            RelayPersonaStore.applyRules("", to: "任务") == "任务"
        )
        #expect(
            RelayPersonaStore.applyRules("  \n", to: "任务") == "任务"
        )
        #expect(
            RelayPersonaStore.applyRules("只说要点。", to: "任务")
                == "只说要点。\n\n---\n\n任务"
        )
    }

    @Test
    func storePersistsBoundedListAndValidates() {
        let defaults = UserDefaults(suiteName: "PersonaTests-\(UUID())")!
        let personas = [
            RelayPersona(name: "A", agentID: "claude"),
            RelayPersona(name: "B", agentID: "codex", rules: "r"),
        ]
        RelayPersonaStore.save(personas, defaults: defaults)
        let loaded = RelayPersonaStore.load(defaults: defaults)
        #expect(loaded == personas)

        #expect(RelayPersonaStore.validationError(name: "评审员", rules: "") == nil)
        #expect(RelayPersonaStore.validationError(name: "", rules: "") != nil)
        #expect(RelayPersonaStore.validationError(
            name: "a\nb", rules: ""
        ) != nil)
        #expect(RelayPersonaStore.validationError(
            name: String(repeating: "长", count: 20), rules: ""
        ) != nil)
        #expect(RelayPersonaStore.validationError(
            name: "ok", rules: String(repeating: "r", count: 4001)
        ) != nil)
    }
}
