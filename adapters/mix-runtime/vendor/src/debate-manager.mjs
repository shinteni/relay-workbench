import { createHash, randomUUID } from "node:crypto";

export const DEFAULT_MAX_ROUNDS = 4;

function consensusHash(value) {
  return createHash("sha256").update(value).digest("hex");
}

export class DebateManager {
  constructor({ peer, maxRounds = DEFAULT_MAX_ROUNDS }) {
    this.peer = peer;
    this.maxRounds = maxRounds;
    this.cycles = new Map();
    this.cycleLocks = new Map();
    this.startLock = Promise.resolve();
    this.activeCycleId = null;
    this.generation = 0;
  }

  reset() {
    this.generation += 1;
    this.cycles.clear();
    this.cycleLocks.clear();
    this.startLock = Promise.resolve();
    this.activeCycleId = null;
  }

  assertGeneration(generation) {
    if (generation === this.generation) return;
    const error = new Error("The MIX cycle was reset before completion.");
    error.code = "MIX_CYCLE_RESET";
    throw error;
  }

  getCycle(cycleId) {
    const cycle = this.cycles.get(cycleId);
    if (!cycle) {
      const error = new Error(`Unknown cycle: ${cycleId}`);
      error.code = "MIX_UNKNOWN_CYCLE";
      throw error;
    }
    return cycle;
  }

  async startCycle({ question, claudeConclusion, priorConsensus }) {
    const generation = this.generation;
    const current = this.startLock
      .catch(() => undefined)
      .then(() =>
        this.runStartCycle({
          question,
          claudeConclusion,
          priorConsensus,
          generation,
        }),
      );
    this.startLock = current;
    return current;
  }

  async runStartCycle({
    question,
    claudeConclusion,
    priorConsensus,
    generation,
  }) {
    this.assertGeneration(generation);
    let resolvedCycleId = null;
    if (this.activeCycleId) {
      // A new cycle supersedes whatever came before it: a user prompt that
      // reaches start_cycle means the previous, possibly interrupted cycle
      // has been abandoned. Wait for its in-flight round before dropping it.
      const pendingRound = this.cycleLocks.get(this.activeCycleId);
      if (pendingRound) await pendingRound.catch(() => undefined);
      this.assertGeneration(generation);
      resolvedCycleId = this.activeCycleId;
    }

    const effectivePriorConsensus = priorConsensus ?? "";
    const codexInitial = await this.peer.analyze({
      question,
      priorConsensus: effectivePriorConsensus,
    });
    this.assertGeneration(generation);
    const cycleId = randomUUID();
    if (resolvedCycleId) this.cycles.delete(resolvedCycleId);
    const cycle = {
      acceptedCandidateHash: null,
      claudeConclusion,
      codexInitial,
      consensusCandidate: null,
      id: cycleId,
      priorConsensus: effectivePriorConsensus,
      question,
      round: 0,
      status: "debating",
    };
    this.cycles.set(cycleId, cycle);
    this.activeCycleId = cycleId;

    return {
      cycle_id: cycleId,
      status: cycle.status,
      codex_initial_conclusion: codexInitial.conclusion,
      codex_rationale_summary: codexInitial.rationale_summary,
      evidence_needed: codexInitial.evidence_needed,
      confidence: codexInitial.confidence,
      round: cycle.round,
      max_rounds: this.maxRounds,
    };
  }

  async debateRound({
    cycleId,
    claudePosition,
    proposedConsensus,
    evidence = "",
  }) {
    const generation = this.generation;
    const previous = this.cycleLocks.get(cycleId) || Promise.resolve();
    const current = previous
      .catch(() => undefined)
      .then(() =>
        this.runDebateRound({
          cycleId,
          claudePosition,
          proposedConsensus,
          evidence,
          generation,
        }),
      );
    this.cycleLocks.set(cycleId, current);
    try {
      return await current;
    } finally {
      if (this.cycleLocks.get(cycleId) === current) {
        this.cycleLocks.delete(cycleId);
      }
    }
  }

  async runDebateRound({
    cycleId,
    claudePosition,
    proposedConsensus,
    evidence,
    generation,
  }) {
    this.assertGeneration(generation);
    const cycle = this.getCycle(cycleId);
    if (["consensus", "limit_reached"].includes(cycle.status)) {
      throw new Error(`Cycle ${cycleId} cannot continue from status ${cycle.status}.`);
    }
    if (cycle.round >= this.maxRounds) {
      cycle.status = "limit_reached";
      return this.formatDebateResult(cycle, {
        response_summary: "The debate round limit was reached.",
        blocking_disagreements: [],
      });
    }

    // Commit the round only after the peer turn succeeds, so a timeout or
    // transport failure can be retried without consuming the round budget.
    const round = cycle.round + 1;
    const codexResponse = await this.peer.debate({
      question: cycle.question,
      claudePosition,
      proposedConsensus,
      evidence,
      round,
    });
    this.assertGeneration(generation);
    cycle.round = round;

    cycle.acceptedCandidateHash = null;
    cycle.consensusCandidate = null;

    if (codexResponse.verdict === "accept") {
      cycle.consensusCandidate = proposedConsensus;
      cycle.acceptedCandidateHash = consensusHash(proposedConsensus);
      cycle.status = "awaiting_confirmation";
    } else if (codexResponse.verdict === "counter") {
      if (!codexResponse.consensus_candidate.trim()) {
        throw new Error("Codex returned counter without a consensus candidate.");
      }
      cycle.consensusCandidate = codexResponse.consensus_candidate;
      cycle.acceptedCandidateHash = consensusHash(codexResponse.consensus_candidate);
      cycle.status = "awaiting_confirmation";
    } else if (codexResponse.verdict === "need_user") {
      cycle.status = "need_user";
    } else if (cycle.round >= this.maxRounds) {
      cycle.status = "limit_reached";
    } else {
      cycle.status = "need_evidence";
    }

    return this.formatDebateResult(cycle, codexResponse);
  }

  finalizeCycle({ cycleId, consensusText }) {
    const cycle = this.getCycle(cycleId);
    if (cycle.status !== "awaiting_confirmation" || !cycle.acceptedCandidateHash) {
      throw new Error("Codex has not accepted the current consensus candidate.");
    }
    // The accepted candidate is stored server-side, so callers can omit the
    // text instead of reproducing it byte-for-byte from the rendered trace.
    const finalText = consensusText ?? cycle.consensusCandidate;
    if (consensusHash(finalText) !== cycle.acceptedCandidateHash) {
      throw new Error("The final consensus differs from the candidate Codex accepted.");
    }

    cycle.status = "consensus";
    cycle.consensusCandidate = finalText;

    return {
      status: "consensus",
      final_answer: finalText,
    };
  }

  formatDebateResult(cycle, codexResponse) {
    return {
      status: cycle.status,
      round: cycle.round,
      max_rounds: this.maxRounds,
      codex_response: codexResponse.response_summary,
      consensus_candidate: cycle.consensusCandidate,
      blocking_disagreements: codexResponse.blocking_disagreements,
      user_question: codexResponse.user_question || null,
      codex_accepts_candidate: Boolean(cycle.acceptedCandidateHash),
    };
  }
}
