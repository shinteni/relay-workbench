import Foundation
import Testing
@testable import RelayGUI

struct InteractionTests {
    @Test
    func decodesPendingUserInput() throws {
        let data = Data(#"""
        {
          "id": "11111111-1111-4111-8111-111111111111",
          "adapter_id": "codex",
          "prompt_preview": "plan this change",
          "title": null,
          "pending_interaction": {
            "id": "request-1",
            "kind": "input",
            "title": "Codex needs input",
            "message": "Choose one.",
            "actions": [],
            "questions": [{
              "id": "choice",
              "prompt": "Which path?",
              "options": [{"value": "A", "label": "Option A"}],
              "allow_custom": true,
              "secret": false
            }]
          },
          "cwd": "/tmp/relay",
          "status": "waiting_for_input",
          "created_at_ms": 1,
          "updated_at_ms": 2,
          "latest_message": "waiting",
          "session_id": "thread-1",
          "turn_count": 1,
          "adapter_options": {"codex_mode": "plan"}
        }
        """#.utf8)

        let task = try JSONDecoder().decode(RelayTask.self, from: data)

        #expect(task.pendingInteraction?.kind == .input)
        #expect(task.pendingInteraction?.questions.first?.allowCustom == true)
        #expect(task.pendingInteraction?.questions.first?.options.first?.value == "A")
        #expect(task.status == .waitingForInput)
    }
}
