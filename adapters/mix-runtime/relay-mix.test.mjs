import assert from "node:assert/strict";
import { test } from "node:test";

import { parseArguments } from "./relay-mix.mjs";

test("parses a new MIX task", () => {
  const result = parseArguments([
    "--task-id",
    "550e8400-e29b-41d4-a716-446655440000",
    "--cwd",
    "/tmp",
    "--model",
    "gpt-5.6-sol",
    "--effort",
    "max",
  ]);

  assert.equal(result.resume, false);
  assert.equal(result.model, "gpt-5.6-sol");
  assert.equal(result.effort, "max");
});

test("parses a resumed MIX task", () => {
  const result = parseArguments([
    "--task-id",
    "550e8400-e29b-41d4-a716-446655440000",
    "--cwd",
    "/tmp",
    "--resume",
  ]);

  assert.equal(result.resume, true);
});

test("rejects an unsupported effort", () => {
  assert.throws(
    () =>
      parseArguments([
        "--task-id",
        "550e8400-e29b-41d4-a716-446655440000",
        "--cwd",
        "/tmp",
        "--effort",
        "extreme",
      ]),
    /Unsupported reasoning effort/,
  );
});
