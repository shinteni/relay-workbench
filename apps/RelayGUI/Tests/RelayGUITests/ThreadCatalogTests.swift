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

    private func task(
        id: String,
        title: String?,
        prompt: String,
        adapter: String,
        cwd: String,
        status: RelayTaskStatus = .completed
    ) -> RelayTask {
        RelayTask(
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
            adapterOptions: [:]
        )
    }
}
