import Foundation
import Testing
@testable import RelayGUI

struct TaskHookTests {
    private func task(
        id: String, adapter: String, status: RelayTaskStatus,
        message: String? = nil
    ) -> RelayTask {
        RelayTask(
            id: id,
            adapterID: adapter,
            promptPreview: "prompt",
            title: nil,
            pendingInteraction: nil,
            cwd: "/tmp",
            status: status,
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1,
            latestMessage: message,
            sessionID: nil,
            turnCount: 1,
            adapterOptions: [:]
        )
    }

    @Test
    func notificationEventsMapToHookEvents() {
        #expect(RelayTaskHookEngine.hookEvent(
            for: .finished(task(id: "1", adapter: "codex", status: .completed))
        ) == .completed)
        #expect(RelayTaskHookEngine.hookEvent(
            for: .finished(task(id: "1", adapter: "codex", status: .failed))
        ) == .failed)
        #expect(RelayTaskHookEngine.hookEvent(
            for: .waiting(task(id: "1", adapter: "codex", status: .waitingForApproval))
        ) == .waiting)
        #expect(RelayTaskHookEngine.hookEvent(
            for: .finished(task(id: "1", adapter: "codex", status: .canceled))
        ) == nil)
    }

    @Test
    func matchingFiltersByEventAndAgentScope() {
        let anyCompleted = RelayTaskHook(event: .completed, command: "a")
        let claudeCompleted = RelayTaskHook(
            event: .completed, agentID: "claude", command: "b"
        )
        let anyFailed = RelayTaskHook(event: .failed, command: "c")
        let hooks = [anyCompleted, claudeCompleted, anyFailed]

        #expect(RelayTaskHookEngine.matching(
            hooks: hooks, event: .completed, adapterID: "claude"
        ) == [anyCompleted, claudeCompleted])
        #expect(RelayTaskHookEngine.matching(
            hooks: hooks, event: .completed, adapterID: "codex"
        ) == [anyCompleted])
        #expect(RelayTaskHookEngine.matching(
            hooks: hooks, event: .waiting, adapterID: "claude"
        ).isEmpty)
    }

    @Test
    func environmentCarriesBoundedTaskFacts() {
        let environment = RelayTaskHookEngine.environment(
            task: task(
                id: "t-1", adapter: "claude", status: .completed,
                message: String(repeating: "长", count: 1200)
            ),
            event: .completed
        )
        #expect(environment["RELAY_TASK_ID"] == "t-1")
        #expect(environment["RELAY_TASK_EVENT"] == "completed")
        #expect(environment["RELAY_TASK_ADAPTER"] == "claude")
        #expect(environment["RELAY_TASK_STATUS"] == "completed")
        #expect((environment["RELAY_TASK_MESSAGE"] ?? "").count == 1000)
    }

    @Test
    func storeRoundTripsAndValidates() {
        let defaults = UserDefaults(suiteName: "TaskHookTests-\(UUID())")!
        let hooks = [
            RelayTaskHook(event: .completed, command: "afplay /System/Library/Sounds/Glass.aiff"),
            RelayTaskHook(event: .waiting, agentID: "codex", command: "open -g relay://waiting"),
        ]
        RelayTaskHookStore.save(hooks, defaults: defaults)
        #expect(RelayTaskHookStore.load(defaults: defaults) == hooks)

        #expect(RelayTaskHookStore.validationError(command: "echo ok") == nil)
        #expect(RelayTaskHookStore.validationError(command: "  ") != nil)
        #expect(RelayTaskHookStore.validationError(
            command: String(repeating: "x", count: 1001)
        ) != nil)
        #expect(RelayTaskHookEngine.dedupKey(taskID: "t", event: .failed) == "t:failed")
    }
}
