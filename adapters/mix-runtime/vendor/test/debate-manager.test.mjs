import assert from "node:assert/strict";
import test from "node:test";

import { DebateManager } from "../src/debate-manager.mjs";

class FakePeer {
  constructor(responses = []) {
    this.analysisCalls = [];
    this.debateCalls = [];
    this.responses = [...responses];
  }

  async analyze(input) {
    this.analysisCalls.push(input);
    return {
      conclusion: "Codex independent conclusion",
      rationale_summary: "Independent rationale",
      evidence_needed: [],
      confidence: "high",
    };
  }

  async debate(input) {
    this.debateCalls.push(input);
    const response = this.responses.shift();
    if (!response) throw new Error("Missing fake response");
    return response;
  }
}

function response(overrides = {}) {
  return {
    verdict: "accept",
    response_summary: "Accepted",
    blocking_disagreements: [],
    consensus_candidate: "",
    user_question: "",
    ...overrides,
  };
}

test("Codex initial analysis does not receive Claude's current conclusion", async () => {
  const peer = new FakePeer();
  const manager = new DebateManager({ peer });

  await manager.startCycle({
    question: "Which design is safer?",
    claudeConclusion: "CLAUDE_PRIVATE_SENTINEL",
    priorConsensus: "Previous accepted decision",
  });

  assert.deepEqual(peer.analysisCalls, [
    {
      question: "Which design is safer?",
      priorConsensus: "Previous accepted decision",
    },
  ]);
  assert.equal(JSON.stringify(peer.analysisCalls).includes("CLAUDE_PRIVATE_SENTINEL"), false);
});

test("an accepted Claude proposal can be finalized unchanged", async () => {
  const peer = new FakePeer([response()]);
  const manager = new DebateManager({ peer });
  const started = await manager.startCycle({
    question: "Question",
    claudeConclusion: "Claude answer",
  });

  const debated = await manager.debateRound({
    cycleId: started.cycle_id,
    claudePosition: "Claude position",
    proposedConsensus: "Final shared answer",
  });
  const finalized = manager.finalizeCycle({
    cycleId: started.cycle_id,
    consensusText: "Final shared answer",
  });

  assert.equal(debated.status, "awaiting_confirmation");
  assert.equal(finalized.final_answer, "Final shared answer");
});

test("a materially changed final answer is rejected", async () => {
  const peer = new FakePeer([response()]);
  const manager = new DebateManager({ peer });
  const started = await manager.startCycle({
    question: "Question",
    claudeConclusion: "Claude answer",
  });
  await manager.debateRound({
    cycleId: started.cycle_id,
    claudePosition: "Claude position",
    proposedConsensus: "Accepted text",
  });

  assert.throws(
    () =>
      manager.finalizeCycle({
        cycleId: started.cycle_id,
        consensusText: "Changed text",
      }),
    /differs from the candidate/,
  );
});

test("whitespace changes in the final answer are rejected", async () => {
  const peer = new FakePeer([response()]);
  const manager = new DebateManager({ peer });
  const started = await manager.startCycle({
    question: "Question",
    claudeConclusion: "Claude answer",
  });
  await manager.debateRound({
    cycleId: started.cycle_id,
    claudePosition: "Claude position",
    proposedConsensus: "if (x) {\n  run();\n}",
  });

  assert.throws(
    () =>
      manager.finalizeCycle({
        cycleId: started.cycle_id,
        consensusText: "if (x) { run(); }",
      }),
    /differs from the candidate/,
  );
});

test("Claude can accept a complete Codex counterproposal", async () => {
  const peer = new FakePeer([
    response({
      verdict: "counter",
      response_summary: "Use the safer alternative",
      consensus_candidate: "Codex replacement answer",
    }),
  ]);
  const manager = new DebateManager({ peer });
  const started = await manager.startCycle({
    question: "Question",
    claudeConclusion: "Claude answer",
  });

  const debated = await manager.debateRound({
    cycleId: started.cycle_id,
    claudePosition: "Claude position",
    proposedConsensus: "Claude proposal",
  });
  const finalized = manager.finalizeCycle({
    cycleId: started.cycle_id,
    consensusText: debated.consensus_candidate,
  });

  assert.equal(finalized.final_answer, "Codex replacement answer");
});

test("unresolved evidence requests stop at the round limit", async () => {
  const peer = new FakePeer([
    response({ verdict: "need_evidence", response_summary: "Need a source" }),
    response({ verdict: "need_evidence", response_summary: "Still missing" }),
  ]);
  const manager = new DebateManager({ peer, maxRounds: 2 });
  const started = await manager.startCycle({
    question: "Question",
    claudeConclusion: "Claude answer",
  });

  const first = await manager.debateRound({
    cycleId: started.cycle_id,
    claudePosition: "Position",
    proposedConsensus: "Proposal",
  });
  const second = await manager.debateRound({
    cycleId: started.cycle_id,
    claudePosition: "Position with evidence",
    proposedConsensus: "Proposal",
    evidence: "Some evidence",
  });

  assert.equal(first.status, "need_evidence");
  assert.equal(second.status, "limit_reached");
});

test("prior consensus is included only when explicitly provided", async () => {
  const peer = new FakePeer([response()]);
  const manager = new DebateManager({ peer });
  const first = await manager.startCycle({
    question: "First question",
    claudeConclusion: "Claude answer",
  });
  await manager.debateRound({
    cycleId: first.cycle_id,
    claudePosition: "Position",
    proposedConsensus: "Shared baseline",
  });
  manager.finalizeCycle({
    cycleId: first.cycle_id,
    consensusText: "Shared baseline",
  });

  await manager.startCycle({
    question: "Next instruction",
    claudeConclusion: "Next Claude answer",
  });
  assert.equal(peer.analysisCalls[1].priorConsensus, "");

  const explicitPeer = new FakePeer();
  const explicitManager = new DebateManager({ peer: explicitPeer });
  await explicitManager.startCycle({
    question: "Verification instruction",
    claudeConclusion: "Verification answer",
    priorConsensus: "Shared baseline",
  });

  assert.equal(explicitPeer.analysisCalls[0].priorConsensus, "Shared baseline");
});

test("concurrent debate rounds are applied in request order", async () => {
  class RacingPeer extends FakePeer {
    async debate(input) {
      this.debateCalls.push(input);
      await new Promise((resolve) =>
        setTimeout(resolve, input.round === 1 ? 30 : 1),
      );
      return input.round === 1
        ? response()
        : response({
            verdict: "counter",
            consensus_candidate: "Candidate B",
          });
    }
  }

  const manager = new DebateManager({ peer: new RacingPeer() });
  const started = await manager.startCycle({
    question: "Question",
    claudeConclusion: "Claude answer",
  });
  const [first, second] = await Promise.all([
    manager.debateRound({
      cycleId: started.cycle_id,
      claudePosition: "First position",
      proposedConsensus: "Candidate A",
    }),
    manager.debateRound({
      cycleId: started.cycle_id,
      claudePosition: "Second position",
      proposedConsensus: "Candidate B",
    }),
  ]);

  assert.equal(first.consensus_candidate, "Candidate A");
  assert.equal(second.consensus_candidate, "Candidate B");
  assert.equal(manager.getCycle(started.cycle_id).consensusCandidate, "Candidate B");
});

test("a new cycle supersedes an unresolved one instead of wedging", async () => {
  const peer = new FakePeer();
  const manager = new DebateManager({ peer });
  const abandoned = await manager.startCycle({
    question: "Interrupted question",
    claudeConclusion: "Interrupted answer",
  });

  const replacement = await manager.startCycle({
    question: "Next question",
    claudeConclusion: "Next answer",
  });

  assert.notEqual(replacement.cycle_id, abandoned.cycle_id);
  assert.equal(manager.activeCycleId, replacement.cycle_id);
  assert.throws(() => manager.getCycle(abandoned.cycle_id), /Unknown cycle/);
  assert.equal(peer.analysisCalls.length, 2);
});

test("starting a cycle waits for the superseded cycle's in-flight round", async () => {
  let releaseDebate;
  class SlowDebatePeer extends FakePeer {
    async debate(input) {
      this.debateCalls.push(input);
      await new Promise((resolve) => {
        releaseDebate = resolve;
      });
      return response();
    }
  }

  const peer = new SlowDebatePeer();
  const manager = new DebateManager({ peer });
  const first = await manager.startCycle({
    question: "First",
    claudeConclusion: "First answer",
  });
  const inFlightRound = manager.debateRound({
    cycleId: first.cycle_id,
    claudePosition: "Position",
    proposedConsensus: "Candidate",
  });
  const superseding = manager.startCycle({
    question: "Second",
    claudeConclusion: "Second answer",
  });

  await new Promise((resolve) => setTimeout(resolve, 10));
  // The superseding start must not analyze until the in-flight round settles.
  assert.equal(peer.analysisCalls.length, 1);
  releaseDebate();
  const [roundResult, started] = await Promise.all([inFlightRound, superseding]);

  assert.equal(peer.analysisCalls.length, 2);
  assert.equal(roundResult.status, "awaiting_confirmation");
  assert.equal(manager.activeCycleId, started.cycle_id);
  assert.throws(() => manager.getCycle(first.cycle_id), /Unknown cycle/);
});

test("a failed peer turn does not consume the round budget", async () => {
  class FlakyPeer extends FakePeer {
    async debate(input) {
      this.debateCalls.push(input);
      if (this.debateCalls.length === 1) {
        throw new Error("Codex Exec exited with code 1");
      }
      return response();
    }
  }

  const peer = new FlakyPeer();
  const manager = new DebateManager({ peer, maxRounds: 2 });
  const started = await manager.startCycle({
    question: "Question",
    claudeConclusion: "Claude answer",
  });

  await assert.rejects(
    manager.debateRound({
      cycleId: started.cycle_id,
      claudePosition: "Position",
      proposedConsensus: "Proposal",
    }),
    /exited with code 1/,
  );
  assert.equal(manager.getCycle(started.cycle_id).round, 0);

  const retried = await manager.debateRound({
    cycleId: started.cycle_id,
    claudePosition: "Position",
    proposedConsensus: "Proposal",
  });
  assert.equal(retried.round, 1);
  assert.equal(retried.status, "awaiting_confirmation");
});

test("finalize without consensus text uses the stored accepted candidate", async () => {
  const peer = new FakePeer([
    response({
      verdict: "counter",
      response_summary: "Use the safer alternative",
      consensus_candidate: "Codex replacement answer\n",
    }),
  ]);
  const manager = new DebateManager({ peer });
  const started = await manager.startCycle({
    question: "Question",
    claudeConclusion: "Claude answer",
  });
  await manager.debateRound({
    cycleId: started.cycle_id,
    claudePosition: "Claude position",
    proposedConsensus: "Claude proposal",
  });

  const finalized = manager.finalizeCycle({ cycleId: started.cycle_id });

  assert.equal(finalized.final_answer, "Codex replacement answer\n");
});

test("reset discards an unfinished cycle before a new MIX turn", async () => {
  const peer = new FakePeer();
  const manager = new DebateManager({ peer });
  const first = await manager.startCycle({
    question: "First question",
    claudeConclusion: "First answer",
  });

  manager.reset();

  assert.throws(() => manager.getCycle(first.cycle_id), /Unknown cycle/);
  const second = await manager.startCycle({
    question: "Second question",
    claudeConclusion: "Second answer",
  });
  assert.notEqual(second.cycle_id, first.cycle_id);
});

test("reset invalidates an in-flight cycle start", async () => {
  let releaseAnalysis;
  const peer = new FakePeer();
  peer.analyze = () =>
    new Promise((resolve) => {
      releaseAnalysis = resolve;
    });
  const manager = new DebateManager({ peer });
  const pending = manager.startCycle({
    question: "Interrupted question",
    claudeConclusion: "Interrupted answer",
  });
  while (!releaseAnalysis) await new Promise((resolve) => setImmediate(resolve));

  manager.reset();
  releaseAnalysis({
    conclusion: "Stale conclusion",
    rationale_summary: "Stale rationale",
    evidence_needed: [],
    confidence: "high",
  });

  await assert.rejects(pending, /reset/);
  assert.equal(manager.activeCycleId, null);
  assert.equal(manager.cycles.size, 0);
});

test("reset invalidates an in-flight debate round", async () => {
  let releaseDebate;
  class ResetPeer extends FakePeer {
    async debate(input) {
      this.debateCalls.push(input);
      return new Promise((resolve) => {
        releaseDebate = () => resolve(response());
      });
    }
  }
  const manager = new DebateManager({ peer: new ResetPeer() });
  const started = await manager.startCycle({
    question: "Question",
    claudeConclusion: "Answer",
  });
  const pending = manager.debateRound({
    cycleId: started.cycle_id,
    claudePosition: "Position",
    proposedConsensus: "Candidate",
  });
  while (!releaseDebate) await new Promise((resolve) => setImmediate(resolve));

  manager.reset();
  releaseDebate();

  await assert.rejects(pending, /reset/);
  assert.equal(manager.activeCycleId, null);
  assert.equal(manager.cycles.size, 0);
});
