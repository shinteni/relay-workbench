import assert from "node:assert/strict";
import test from "node:test";

import { CodexPeer } from "../src/codex-peer.mjs";

test("Codex peer requires an isolated home when using the real SDK", () => {
  assert.throws(
    () => new CodexPeer({ cwd: "/tmp" }),
    /isolated Codex home is required/,
  );
});

test("Codex peer disables inherited app capabilities", () => {
  const peer = new CodexPeer({
    cwd: "/tmp",
    codexHome: "/tmp/isolated-codex-home",
  });

  assert.equal(peer.codex.options.env.CODEX_HOME, "/tmp/isolated-codex-home");
  assert.deepEqual(peer.codex.options.config.features, {
    apps: false,
    multi_agent: false,
    plugin_sharing: false,
    plugins: false,
    remote_plugin: false,
    skill_mcp_dependency_install: false,
  });
});

test("a Codex home factory is not invoked until the peer is actually used", () => {
  let factoryCalls = 0;
  const peer = new CodexPeer({
    cwd: "/tmp",
    codexHomeFactory: () => {
      factoryCalls += 1;
      return "/tmp/lazy-codex-home";
    },
  });

  assert.equal(factoryCalls, 0);
  assert.equal(peer.codex, null);

  peer.ensureCodex();
  peer.ensureCodex();

  assert.equal(factoryCalls, 1);
  assert.equal(peer.codex.options.env.CODEX_HOME, "/tmp/lazy-codex-home");
});

test("Codex turns use read-only options and an abort signal", async () => {
  const calls = [];
  const fakeCodex = {
    startThread(options) {
      calls.push({ type: "start", options });
      return {
        id: "thread-id",
        async run(_prompt, turnOptions) {
          calls.push({ type: "run", options: turnOptions });
          return {
            finalResponse: JSON.stringify({
              conclusion: "Conclusion",
              rationale_summary: "Rationale",
              evidence_needed: [],
              confidence: "high",
            }),
          };
        },
      };
    },
  };
  const peer = new CodexPeer({ cwd: "/tmp", codex: fakeCodex });
  peer.setModelOptions({
    model: "gpt-5.6-sol",
    reasoningEffort: "high",
  });

  await peer.analyze({ question: "Question", priorConsensus: "" });

  assert.equal(calls[0].options.model, "gpt-5.6-sol");
  assert.equal(calls[0].options.modelReasoningEffort, "high");
  assert.equal(calls[0].options.sandboxMode, "read-only");
  assert.equal(calls[0].options.networkAccessEnabled, false);
  assert.equal(calls[0].options.webSearchMode, "disabled");
  assert.equal(calls[1].options.signal instanceof AbortSignal, true);
});

test("each analysis starts a new thread while debate uses the current thread", async () => {
  const threads = [];
  const fakeCodex = {
    startThread() {
      const thread = {
        id: `thread-${threads.length + 1}`,
        runs: [],
        async run(prompt) {
          this.runs.push(prompt);
          if (prompt.includes("Independently analyze")) {
            return {
              finalResponse: JSON.stringify({
                conclusion: "Conclusion",
                rationale_summary: "Rationale",
                evidence_needed: [],
                confidence: "high",
              }),
            };
          }
          return {
            finalResponse: JSON.stringify({
              verdict: "accept",
              response_summary: "Accepted",
              blocking_disagreements: [],
              consensus_candidate: "",
              user_question: "",
            }),
          };
        },
      };
      threads.push(thread);
      return thread;
    },
  };
  const peer = new CodexPeer({ cwd: "/tmp", codex: fakeCodex });

  await peer.analyze({ question: "First", priorConsensus: "" });
  await peer.debate({
    question: "First",
    claudePosition: "Position",
    proposedConsensus: "Candidate",
    evidence: "",
    round: 1,
  });
  await peer.analyze({ question: "Second", priorConsensus: "" });

  assert.equal(threads.length, 2);
  assert.equal(threads[0].runs.length, 2);
  assert.equal(threads[1].runs.length, 1);
});

test("a malformed Codex response is not echoed in the error", async () => {
  const peer = new CodexPeer({
    cwd: "/tmp",
    codex: {
      startThread() {
        return {
          id: "thread-id",
          async run() {
            return { finalResponse: "SENSITIVE_SENTINEL_FROM_PEER" };
          },
        };
      },
    },
  });

  await assert.rejects(
    peer.analyze({ question: "Question", priorConsensus: "" }),
    (error) => {
      assert.match(error.message, /non-JSON response/);
      assert.equal(error.message.includes("SENSITIVE_SENTINEL_FROM_PEER"), false);
      return true;
    },
  );
});
