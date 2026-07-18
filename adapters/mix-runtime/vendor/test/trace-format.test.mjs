import assert from "node:assert/strict";
import test from "node:test";

import {
  formatDebateTrace,
  formatFinalTrace,
  formatInitialTrace,
} from "../src/trace-format.mjs";

test("initial trace clearly labels Claude and Codex", () => {
  const text = formatInitialTrace("Claude conclusion", {
    cycle_id: "cycle-1",
    status: "debating",
    codex_initial_conclusion: "Codex conclusion",
    codex_rationale_summary: "Codex rationale",
    evidence_needed: [],
    confidence: "high",
    round: 0,
    max_rounds: 4,
    codex_model: "gpt-5.6-sol",
    codex_reasoning_effort: "high",
  });

  assert.match(text, /^🟣 MIX · cycle-1/m);
  assert.match(text, /^状态：debating · 回合：0\/4/m);
  assert.match(text, /^🔵 Claude/m);
  assert.match(text, /^🟢 Codex · gpt-5.6-sol · high/m);
  assert.ok(text.indexOf("🔵 Claude") < text.indexOf("🟢 Codex"));
});

test("debate trace identifies each side and preserves every control field", () => {
  const text = formatDebateTrace(
    "Claude position",
    "Shared proposal",
    {
      codex_response: "Codex objection",
      blocking_disagreements: ["Missing evidence"],
      consensus_candidate: "Revised consensus",
      status: "awaiting_confirmation",
      user_question: null,
      codex_accepts_candidate: true,
      round: 1,
      max_rounds: 4,
      codex_model: "gpt-5.6-sol",
      codex_reasoning_effort: "high",
    },
  );

  assert.match(text, /^🟣 MIX · 辩论回合 1\/4/m);
  assert.match(text, /🔵 Claude[\s\S]*Claude position/);
  assert.match(
    text,
    /🟢 Codex · gpt-5.6-sol · high[\s\S]*Codex objection/,
  );
  assert.match(text, /Missing evidence/);
  assert.match(text, /共识候选：[\s\S]*Revised consensus/);
  assert.match(text, /^Codex 接受候选：是/m);
  assert.match(text, /^需要用户回答：无/m);
  assert.match(text, /^状态：awaiting_confirmation/m);
});

test("final trace uses the MIX consensus label", () => {
  assert.equal(formatFinalTrace("Final answer"), "🟣 MIX 共识\nFinal answer");
});
