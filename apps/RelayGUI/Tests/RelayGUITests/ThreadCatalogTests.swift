import Foundation
import Testing
@testable import RelayGUI

struct ThreadCatalogTests {
    @Test
    func filtersAcrossTitleAgentAndDirectory() {
        let tasks = [
            task(id: "11111111", title: "Release audit", prompt: "inspect", adapter: "codex", cwd: "/tmp/relay"),
            task(id: "22222222", title: nil, prompt: "Write docs", adapter: "claude", cwd: "/tmp/docs"),
        ]

        #expect(ThreadCatalog.filtered(tasks, query: "release").map(\.id) == ["11111111"])
        #expect(ThreadCatalog.filtered(tasks, query: "CLAUDE").map(\.id) == ["22222222"])
        #expect(ThreadCatalog.filtered(tasks, query: "/tmp/relay").map(\.id) == ["11111111"])
        #expect(ThreadCatalog.filtered(tasks, query: "inspect").map(\.id) == ["11111111"])
    }

    @Test
    func groupsByDirectoryWithoutChangingTaskOrder() {
        let tasks = [
            task(id: "1", title: nil, prompt: "first", adapter: "codex", cwd: "/tmp/relay"),
            task(id: "2", title: nil, prompt: "second", adapter: "claude", cwd: "/tmp/docs"),
            task(id: "3", title: nil, prompt: "third", adapter: "mix", cwd: "/tmp/relay"),
        ]

        let groups = ThreadCatalog.grouped(tasks, query: "")

        #expect(groups.map(\.cwd) == ["/tmp/relay", "/tmp/docs"])
        #expect(groups[0].tasks.map(\.id) == ["1", "3"])
        #expect(groups[0].name == "relay")
    }

    @Test
    func filtersByOperationalStatusAndQuery() {
        let tasks = [
            task(id: "1", title: "Build", prompt: "compile", adapter: "codex", cwd: "/tmp/relay", status: .running),
            task(id: "2", title: "Approve", prompt: "ship", adapter: "codex", cwd: "/tmp/relay", status: .waitingForApproval),
            task(id: "3", title: "Broken docs", prompt: "write", adapter: "claude", cwd: "/tmp/docs", status: .failed),
            task(id: "4", title: "Finished docs", prompt: "publish", adapter: "claude", cwd: "/tmp/docs", status: .completed),
            task(id: "5", title: "Stopped", prompt: "cancel", adapter: "mix", cwd: "/tmp/mix", status: .canceled),
        ]

        #expect(ThreadCatalog.filtered(tasks, query: "", filter: .active).map(\.id) == ["1"])
        #expect(ThreadCatalog.filtered(tasks, query: "", filter: .waiting).map(\.id) == ["2"])
        #expect(ThreadCatalog.filtered(tasks, query: "docs", filter: .failed).map(\.id) == ["3"])
        #expect(ThreadCatalog.filtered(tasks, query: "", filter: .done).map(\.id) == ["4", "5"])
        #expect(ThreadCatalog.count(tasks, filter: .all) == 5)
    }

    @Test
    func countsAgentActivitySeparatelyFromWaitingTasks() {
        let tasks = [
            task(id: "1", title: nil, prompt: "one", adapter: "codex", cwd: "/tmp", status: .queued),
            task(id: "2", title: nil, prompt: "two", adapter: "codex", cwd: "/tmp", status: .running),
            task(id: "3", title: nil, prompt: "three", adapter: "codex", cwd: "/tmp", status: .waitingForInput),
            task(id: "4", title: nil, prompt: "four", adapter: "codex", cwd: "/tmp", status: .completed),
            task(id: "5", title: nil, prompt: "five", adapter: "claude", cwd: "/tmp", status: .running),
        ]

        #expect(ThreadCatalog.activity(tasks, agentID: "codex") == RelayAgentActivity(active: 2, waiting: 1))
        #expect(ThreadCatalog.activity(tasks, agentID: "claude") == RelayAgentActivity(active: 1, waiting: 0))
        #expect(ThreadCatalog.activity(tasks, agentID: "mix") == RelayAgentActivity(active: 0, waiting: 0))
    }

    @Test
    func compareMembersAreScopedToGroupAndOrderedByAgent() {
        let tasks = [
            task(id: "9", title: nil, prompt: "other", adapter: "codex", cwd: "/tmp"),
            task(id: "2", title: nil, prompt: "same", adapter: "ollama", cwd: "/tmp", group: "g1"),
            task(id: "1", title: nil, prompt: "same", adapter: "claude", cwd: "/tmp", group: "g1"),
            task(id: "3", title: nil, prompt: "same", adapter: "codex", cwd: "/tmp", group: "g2"),
        ]

        let members = ThreadCatalog.compareMembers(tasks, group: "g1")

        #expect(members.map(\.id) == ["1", "2"])
        #expect(members.map(\.adapterID) == ["claude", "ollama"])
        #expect(tasks[1].compareGroup == "g1")
        #expect(tasks[0].compareGroup == nil)
    }

    @Test
    func parsesExplicitHandoffAndRejectsUnknownAgent() {
        let agents = [agent(id: "codex"), agent(id: "claude")]

        let handoff = ThreadCatalog.parseHandoff(
            "@CLAUDE verify the implementation",
            agents: agents
        )

        #expect(handoff?.agentID == "claude")
        #expect(handoff?.instruction == "verify the implementation")
        #expect(ThreadCatalog.parseHandoff("@unknown continue", agents: agents) == nil)
        #expect(ThreadCatalog.parseHandoff("continue normally", agents: agents) == nil)
    }

    @Test
    func handoffTranscriptRespectsUTF8ByteLimit() {
        let transcript = ThreadCatalog.transcriptText([
            output(sequence: 0, kind: .user, text: "旧指示"),
            output(sequence: 1, kind: .assistant, text: "日本語の回答です"),
        ], limitBytes: 18)

        #expect(transcript.hasPrefix("…"))
        #expect(transcript.utf8.count <= 18)
        #expect(String(data: Data(transcript.utf8), encoding: .utf8) == transcript)
    }

    private func task(
        id: String,
        title: String?,
        prompt: String,
        adapter: String,
        cwd: String,
        status: RelayTaskStatus = .completed,
        group: String? = nil,
        options: [String: String] = [:]
    ) -> RelayTask {
        var adapterOptions = options
        if let group {
            adapterOptions["relay_group"] = group
        }
        return RelayTask(
            id: id,
            adapterID: adapter,
            promptPreview: prompt,
            title: title,
            pendingInteraction: nil,
            cwd: cwd,
            status: status,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1,
            latestMessage: nil,
            sessionID: nil,
            turnCount: 1,
            adapterOptions: adapterOptions
        )
    }

    private func output(sequence: UInt64, kind: RelayOutputKind, text: String) -> RelayTaskOutput {
        RelayTaskOutput(
            sequence: sequence,
            timestampMilliseconds: sequence,
            kind: kind,
            text: text
        )
    }

    private func agent(id: String) -> RelayAgent {
        RelayAgent(
            id: id,
            name: id.capitalized,
            detail: "Test agent",
            manifestURL: URL(fileURLWithPath: "/tmp/\(id).json"),
            adapterExecutablePath: "/bin/true",
            usesGenericRuntime: false,
            registrationEnvironment: [:],
            capabilities: [],
            versionExecutablePath: nil,
            versionArguments: [],
            options: [],
            version: nil,
            health: .ready
        )
    }
}
