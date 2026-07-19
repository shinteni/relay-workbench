import Foundation
import Testing
@testable import RelayGUI

struct ArbitrationVerdictTests {
    @Test
    func parsesBareJSONObject() {
        let parsed = RelayArbitrationVerdict.parse(
            #"{"verdict": "方案 A 更稳", "rationale": "改动面更小", "confidence": "HIGH"}"#
        )
        #expect(parsed.isStructured)
        #expect(parsed.verdict == "方案 A 更稳")
        #expect(parsed.rationale == "改动面更小")
        #expect(parsed.confidence == "high")
    }

    @Test
    func parsesObjectEmbeddedInProseAndFences() {
        let reply = """
        Sure, here is my ruling:
        ```json
        {"verdict": "pick B", "confidence": "medium"}
        ```
        Hope this helps.
        """
        let parsed = RelayArbitrationVerdict.parse(reply)
        #expect(parsed.isStructured)
        #expect(parsed.verdict == "pick B")
        #expect(parsed.rationale == nil)
        #expect(parsed.confidence == "medium")
    }

    @Test
    func lastValidObjectWinsAndBracesInsideStringsAreSafe() {
        let reply = """
        {"verdict": "draft"}
        thinking… {"note": "not a verdict"}
        {"verdict": "final {answer}", "rationale": "with } inside strings"}
        """
        let parsed = RelayArbitrationVerdict.parse(reply)
        #expect(parsed.isStructured)
        #expect(parsed.verdict == "final {answer}")
        #expect(parsed.rationale == "with } inside strings")
    }

    @Test
    func nonConformingRepliesFallBackVerbatim() {
        let plain = RelayArbitrationVerdict.parse("方案 B 明显更好，因为……")
        #expect(!plain.isStructured)
        #expect(plain.verdict == "方案 B 明显更好，因为……")
        #expect(plain.rationale == nil)

        let emptyVerdict = RelayArbitrationVerdict.parse(#"{"verdict": "  "}"#)
        #expect(!emptyVerdict.isStructured)

        let invalidConfidence = RelayArbitrationVerdict.parse(
            #"{"verdict": "ok", "confidence": "certain"}"#
        )
        #expect(invalidConfidence.isStructured)
        #expect(invalidConfidence.confidence == nil)
    }

    @Test
    func daemonPayloadAppendsSchemaAndTerminalPayloadIsUntouched() {
        let payload = "ARBITRATE THESE RESULTS…"
        let daemon = RelayArbitrationVerdict.payloadForDaemonJudge(payload)
        #expect(daemon.hasPrefix(payload))
        #expect(daemon.contains("\"verdict\""))
        #expect(daemon.contains("Reply with exactly one JSON object"))
        #expect(!payload.contains("verdict"))
    }

    @Test
    func daemonDecisionSharesOneIdentityAndCarriesParsedFields() throws {
        let snapshots = [
            RelayResultSnapshot(id: UUID(), agentName: "Ollama", projectName: "demo", text: "方案甲"),
            RelayResultSnapshot(id: UUID(), agentName: "评审员", projectName: "demo", text: "方案乙"),
        ]
        let plan = try #require(RelayResultArbitration.plan(
            instruction: "选一个", snapshots: snapshots
        ))
        let decision = RelayResultArbitration.daemonDecision(
            confluence: RelayResultConfluence(snapshots: snapshots),
            plan: plan,
            parentCheckpointID: nil,
            judgeName: "Claude",
            reply: #"{"verdict": "方案乙", "confidence": "high"}"#
        )
        // The archive validator requires receipt.targetID == result.id;
        // two independent UUIDs made one-click decisions unsaveable.
        #expect(decision.receipt.targetID == decision.result.id)
        #expect(decision.result.text == #"{"verdict": "方案乙", "confidence": "high"}"#)
        #expect(decision.structuredVerdict == "方案乙")
        #expect(decision.structuredConfidence == "high")
        #expect(decision.receipt.plan.sources.map(\.id) == snapshots.map(\.id))
    }

    @Test
    func legacyDecisionRecordsDecodeWithoutStructuredFields() throws {
        let legacy = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "receipt": {
            "confluence": {"id": "22222222-2222-2222-2222-222222222222", "snapshots": []},
            "plan": {"payload": "p", "sources": []},
            "targetID": "33333333-3333-3333-3333-333333333333"
          },
          "result": {
            "id": "44444444-4444-4444-4444-444444444444",
            "agentName": "Claude",
            "projectName": "demo",
            "text": "verdict text"
          }
        }
        """
        let decision = try JSONDecoder().decode(
            RelayResultArbitrationDecision.self, from: Data(legacy.utf8)
        )
        #expect(decision.structuredVerdict == nil)
        #expect(decision.structuredRationale == nil)
        #expect(decision.structuredConfidence == nil)
        #expect(decision.result.text == "verdict text")
    }
}
