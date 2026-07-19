import Foundation
import Testing
@testable import RelayGUI

struct ChainForkTests {
    @Test
    func planForksOnlyCapableStepsWithSessions() {
        let plan = RelayChainFork.plan(
            steps: [
                ("claude", "sess-a"),
                ("codex", "sess-b"),
                ("claude", nil),
            ],
            capabilities: { id in id == "claude" ? ["session_resume", "session_fork"] : ["session_resume"] }
        )
        #expect(plan == [
            RelayChainFork.Step(agentID: "claude", forkFromSession: "sess-a"),
            RelayChainFork.Step(agentID: "codex", forkFromSession: nil),
            RelayChainFork.Step(agentID: "claude", forkFromSession: nil),
        ])
        #expect(RelayChainFork.forkedCount(plan) == 1)
    }

    @Test
    func overridesUseOneBasedIndicesAndSkipFreshSteps() {
        let plan = [
            RelayChainFork.Step(agentID: "claude", forkFromSession: "sess-a"),
            RelayChainFork.Step(agentID: "codex", forkFromSession: nil),
            RelayChainFork.Step(agentID: "claude", forkFromSession: "sess-c"),
        ]
        #expect(RelayChainFork.overrides(for: plan) == [
            1: ["relay_fork_from": "sess-a"],
            3: ["relay_fork_from": "sess-c"],
        ])
    }

    @Test
    func noticeSummarizesForkAndFreshCounts() {
        let copy = RelayCopy(language: .chinese)
        let mixed = [
            RelayChainFork.Step(agentID: "claude", forkFromSession: "s"),
            RelayChainFork.Step(agentID: "codex", forkFromSession: nil),
        ]
        #expect(RelayChainFork.notice(mixed, copy: copy).contains("1"))
        let all = [RelayChainFork.Step(agentID: "claude", forkFromSession: "s")]
        #expect(RelayChainFork.notice(all, copy: copy).contains("每一步"))
        let none = [RelayChainFork.Step(agentID: "codex", forkFromSession: nil)]
        #expect(RelayChainFork.notice(none, copy: copy).contains("重新开始"))
    }
}
