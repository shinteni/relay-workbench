import Foundation
import Testing
@testable import RelayGUI

struct NotificationPlannerTests {
    @Test
    func firstSnapshotOnlySeedsTheBaseline() {
        let tasks = [task(id: "1", status: .completed)]

        #expect(RelayNotificationPlanner.events(previous: nil, current: tasks).isEmpty)
        #expect(RelayNotificationPlanner.baseline(tasks) == ["1": .completed])
    }

    @Test
    func statusTransitionsMapToFinishedAndWaitingEvents() {
        let previous: [String: RelayTaskStatus] = [
            "1": .running,
            "2": .running,
            "3": .running,
            "4": .completed,
        ]
        let current = [
            task(id: "1", status: .completed),
            task(id: "2", status: .waitingForApproval),
            task(id: "3", status: .canceled),
            task(id: "4", status: .completed),
        ]

        let events = RelayNotificationPlanner.events(previous: previous, current: current)

        #expect(events == [
            .finished(current[0]),
            .waiting(current[1]),
        ])
    }

    @Test
    func unseenTaskAppearingTerminalNotifies() {
        let events = RelayNotificationPlanner.events(
            previous: [:],
            current: [task(id: "9", status: .failed)]
        )

        #expect(events == [.finished(task(id: "9", status: .failed))])
    }

    @Test
    func lastTurnAnswerCollectsAssistantTextAfterLatestUserEntry() {
        let output = [
            item(sequence: 0, kind: .assistant, text: "旧回答"),
            item(sequence: 1, kind: .user, text: "新问题"),
            item(sequence: 2, kind: .tool, text: "调用工具"),
            item(sequence: 3, kind: .assistant, text: "第一段"),
            item(sequence: 4, kind: .assistant, text: "第二段"),
        ]

        #expect(ThreadCatalog.lastTurnAnswer(output) == "第一段\n第二段")
        #expect(ThreadCatalog.lastTurnAnswer([
            item(sequence: 0, kind: .user, text: "只有问题"),
        ]).isEmpty)
    }

    private func item(
        sequence: UInt64,
        kind: RelayOutputKind,
        text: String
    ) -> RelayTaskOutput {
        RelayTaskOutput(sequence: sequence, timestampMilliseconds: 1, kind: kind, text: text)
    }

    private func task(id: String, status: RelayTaskStatus) -> RelayTask {
        RelayTask(
            id: id,
            adapterID: "codex",
            promptPreview: "prompt",
            title: nil,
            pendingInteraction: nil,
            cwd: "/tmp",
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
