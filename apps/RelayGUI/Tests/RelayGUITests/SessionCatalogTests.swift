import Foundation
import Testing
@testable import RelayGUI

struct SessionCatalogTests {
    private func task(
        id: String,
        adapter: String = "claude",
        prompt: String = "prompt",
        title: String? = nil,
        options: [String: String] = [:],
        status: RelayTaskStatus = .completed,
        updated: UInt64 = 100,
        turns: UInt32 = 1,
        cwd: String = "/Users/example/demo"
    ) -> RelayTask {
        RelayTask(
            id: id,
            adapterID: adapter,
            promptPreview: prompt,
            title: title,
            pendingInteraction: nil,
            cwd: cwd,
            status: status,
            createdAtMilliseconds: updated,
            updatedAtMilliseconds: updated,
            latestMessage: nil,
            sessionID: nil,
            turnCount: turns,
            adapterOptions: options
        )
    }

    @Test
    func groupsChainsComparesAndSinglesWithNewestFirst() {
        let tasks = [
            task(id: "d1", prompt: "圆桌发言", updated: 50),
            task(id: "c1", adapter: "claude",
                 options: ["relay_group": "g1", "relay_chain_step": "1"],
                 updated: 10, turns: 2),
            task(id: "c2", adapter: "codex",
                 options: ["relay_group": "g1", "relay_chain_step": "2"],
                 updated: 90, turns: 1),
            task(id: "m1", adapter: "ollama",
                 options: ["relay_group": "g2"], updated: 70),
            task(id: "m2", adapter: "ollama",
                 options: ["relay_group": "g2"], status: .running, updated: 60),
        ]
        let entries = RelaySessionCatalog.entries(tasks: tasks)

        #expect(entries.map(\.id) == ["g1", "g2", "d1"])
        let chain = entries[0]
        #expect(chain.kind == .chain)
        #expect(chain.agentsLabel == "CLAUDE › CODEX")
        #expect(chain.turnCount == 3)
        #expect(!chain.hasActiveTask)
        let compare = entries[1]
        #expect(compare.kind == .compare)
        #expect(compare.agentsLabel == "OLLAMA · OLLAMA")
        #expect(compare.hasActiveTask)
        #expect(entries[2].kind == .single)
        #expect(entries[2].title == "圆桌发言")
    }

    @Test
    func chainStepsOrderByStepNotByTime() {
        let tasks = [
            task(id: "s2", adapter: "codex",
                 options: ["relay_group": "g", "relay_chain_step": "2"], updated: 10),
            task(id: "s1", adapter: "claude",
                 options: ["relay_group": "g", "relay_chain_step": "1"], updated: 99),
        ]
        let entry = RelaySessionCatalog.entries(tasks: tasks)[0]
        #expect(entry.tasks.map(\.id) == ["s1", "s2"])
        #expect(entry.title == entry.tasks[0].displayTitle)
    }

    @Test
    func explicitTitleWinsOverPromptPreview() {
        let entries = RelaySessionCatalog.entries(tasks: [
            task(id: "t", prompt: "很长的提示词", title: "发布评审"),
        ])
        #expect(entries[0].title == "发布评审")
    }

    @Test
    func filterMatchesAcrossFieldsAndKind() {
        let entries = RelaySessionCatalog.entries(tasks: [
            task(id: "a", prompt: "修复 ACP 适配器", updated: 30),
            task(id: "b", adapter: "codex", prompt: "写周报",
                 options: ["relay_group": "g", "relay_chain_step": "1"],
                 updated: 20),
        ])

        #expect(RelaySessionCatalog.filter(entries, query: "acp").map(\.id) == ["a"])
        #expect(RelaySessionCatalog.filter(entries, query: "CODEX 周报").map(\.id) == ["g"])
        #expect(RelaySessionCatalog.filter(entries, query: "不存在").isEmpty)
        #expect(RelaySessionCatalog.filter(entries, query: "", kind: .chain).map(\.id) == ["g"])
        #expect(RelaySessionCatalog.filter(entries, query: "acp", kind: .chain).isEmpty)
        #expect(RelaySessionCatalog.filter(entries, query: "  ").count == 2)
    }
}

extension SessionCatalogTests {
    @Test
    func projectFoldersFollowMostRecentActivity() {
        let entries = RelaySessionCatalog.entries(tasks: [
            RelayTask(
                id: "old-a", adapterID: "claude", promptPreview: "旧任务",
                title: nil, pendingInteraction: nil, cwd: "/Users/x/alpha",
                status: .completed, createdAtMilliseconds: 10,
                updatedAtMilliseconds: 10, latestMessage: nil, sessionID: nil,
                turnCount: 1, adapterOptions: [:]
            ),
            RelayTask(
                id: "new-b", adapterID: "codex", promptPreview: "新任务",
                title: nil, pendingInteraction: nil, cwd: "/Users/x/beta",
                status: .completed, createdAtMilliseconds: 90,
                updatedAtMilliseconds: 90, latestMessage: nil, sessionID: nil,
                turnCount: 1, adapterOptions: [:]
            ),
            RelayTask(
                id: "mid-a", adapterID: "claude", promptPreview: "中任务",
                title: nil, pendingInteraction: nil, cwd: "/Users/x/alpha",
                status: .running, createdAtMilliseconds: 50,
                updatedAtMilliseconds: 50, latestMessage: nil, sessionID: nil,
                turnCount: 1, adapterOptions: [:]
            ),
        ])
        let projects = RelaySessionCatalog.byProject(entries)

        #expect(projects.map(\.name) == ["beta", "alpha"])
        #expect(projects[1].entries.map(\.id) == ["mid-a", "old-a"])
        #expect(projects[1].entries[0].hasActiveTask)
        #expect(projects[0].path == "/Users/x/beta")
    }
}
