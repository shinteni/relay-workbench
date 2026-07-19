import Foundation

/// Fork planning for chain follow-ups: a completed chain can branch into a
/// fresh chain window where every step whose adapter supports `session_fork`
/// continues a *copy* of its session; other steps start over. The original
/// chain and its sessions are never touched.
enum RelayChainFork {
    struct Step: Equatable {
        let agentID: String
        /// Session the forked step continues from; nil → starts fresh.
        let forkFromSession: String?
    }

    static let capability = "session_fork"
    static let optionKey = "relay_fork_from"

    /// Builds the plan from the completed chain's ordered steps.
    static func plan(
        steps: [(agentID: String, sessionID: String?)],
        capabilities: (String) -> Set<String>
    ) -> [Step] {
        steps.map { step in
            let canFork = capabilities(step.agentID).contains(capability)
            return Step(
                agentID: step.agentID,
                forkFromSession: canFork ? step.sessionID : nil
            )
        }
    }

    /// Per-step option overrides (1-based step indices) for `startChainRun`.
    static func overrides(for plan: [Step]) -> [Int: [String: String]] {
        var overrides: [Int: [String: String]] = [:]
        for (index, step) in plan.enumerated() {
            if let session = step.forkFromSession, !session.isEmpty {
                overrides[index + 1] = [optionKey: session]
            }
        }
        return overrides
    }

    static func forkedCount(_ plan: [Step]) -> Int {
        plan.filter { $0.forkFromSession?.isEmpty == false }.count
    }

    /// Human summary for the forked window: how many steps carry memory.
    static func notice(_ plan: [Step], copy: RelayCopy) -> String {
        let forked = forkedCount(plan)
        let fresh = plan.count - forked
        if fresh == 0 {
            return copy.text("⑂ Forked — every step continues a copy of its session.")
        }
        if forked == 0 {
            return copy.text("⑂ Forked — no step supports session forking; all start fresh.")
        }
        return copy.text("⑂ Forked — ⟨FORKED⟩ step(s) continue copied sessions, ⟨FRESH⟩ start fresh.")
            .replacingOccurrences(of: "⟨FORKED⟩", with: String(forked))
            .replacingOccurrences(of: "⟨FRESH⟩", with: String(fresh))
    }
}
