import Foundation

/// Structured verdict extraction for one-click daemon arbitration: the judge
/// is asked for a single JSON object; parsing is strict and local, and any
/// non-conforming reply falls back verbatim so no ruling is ever lost.
enum RelayArbitrationVerdict {
    struct Parsed: Equatable {
        let verdict: String
        let rationale: String?
        let confidence: String?
        let isStructured: Bool
    }

    /// Appended to the arbitration payload for daemon judges only; the
    /// human-terminal arbitration path keeps the untouched payload.
    static let schemaInstruction = """
    ---
    Reply with exactly one JSON object and nothing else (no code fence, no prose):
    {"verdict": "<your final ruling>", "rationale": "<brief reasoning>", "confidence": "high" | "medium" | "low"}
    "verdict" is required; "rationale" and "confidence" are optional.
    """

    static func payloadForDaemonJudge(_ payload: String) -> String {
        payload + "\n\n" + schemaInstruction
    }

    /// Parses the judge's reply. The last valid JSON object containing a
    /// non-empty string `verdict` wins; otherwise the whole reply becomes an
    /// unstructured verdict.
    static func parse(_ raw: String) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for candidate in jsonCandidates(in: trimmed).reversed() {
            if let parsed = decode(candidate) {
                return parsed
            }
        }
        return Parsed(
            verdict: trimmed, rationale: nil, confidence: nil, isStructured: false
        )
    }

    private static func decode(_ candidate: String) -> Parsed? {
        guard let data = candidate.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any],
              let verdict = (object["verdict"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !verdict.isEmpty else {
            return nil
        }
        let rationale = (object["rationale"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = (object["confidence"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return Parsed(
            verdict: verdict,
            rationale: (rationale?.isEmpty == false) ? rationale : nil,
            confidence: ["high", "medium", "low"].contains(confidence ?? "")
                ? confidence : nil,
            isStructured: true
        )
    }

    /// Candidate JSON objects: the full reply, fenced blocks, and balanced
    /// top-level `{…}` spans, in order of appearance.
    private static func jsonCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        if text.hasPrefix("{") {
            candidates.append(text)
        }
        var depth = 0
        var inString = false
        var escaped = false
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    if depth == 0 {
                        start = index
                    }
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0, let opened = start {
                        candidates.append(
                            String(text[opened...index])
                        )
                        start = nil
                    }
                    if depth < 0 {
                        depth = 0
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return candidates
    }
}
