import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  markRecoveryIfNeeded,
  pruneStaleSessionState,
  readSessionState,
  readSessionStatus,
  removeSessionState,
  sessionStateFile,
  writeSessionState,
  writeSessionStatus,
} from "../src/session-state.mjs";

test("plugin session state paths are stable without exposing session ids", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-state-root-"));
  try {
    const first = sessionStateFile("session-one", directory);
    const repeated = sessionStateFile("session-one", directory);
    const second = sessionStateFile("session-two", directory);

    assert.equal(first, repeated);
    assert.notEqual(first, second);
    assert.equal(first.includes("session-one"), false);
    assert.throws(() => sessionStateFile("", directory), /session id/i);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("session state can be created and removed when its directory is absent", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-state-root-"));
  const stateDirectory = join(directory, "nested");
  const stateFile = sessionStateFile("session", stateDirectory);
  try {
    writeSessionStatus(stateFile, "pending");
    assert.equal(readSessionStatus(stateFile), "pending");
    removeSessionState(stateFile);
    assert.equal(readSessionStatus(stateFile), "missing");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("server restart preserves pending state and resets active work", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-state-"));
  const stateFile = join(directory, "state.json");
  try {
    writeSessionStatus(stateFile, "pending");
    assert.equal(markRecoveryIfNeeded(stateFile), "pending");
    assert.equal(readSessionStatus(stateFile), "pending");

    writeSessionStatus(stateFile, "debating");
    assert.equal(markRecoveryIfNeeded(stateFile), "recovery_needed");
    assert.equal(readSessionStatus(stateFile), "recovery_needed");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("pruning removes only stale state files and tolerates a missing directory", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-state-prune-"));
  try {
    const staleFile = sessionStateFile("stale-session", directory);
    const freshFile = sessionStateFile("fresh-session", directory);
    writeSessionStatus(staleFile, "debating");
    writeSessionStatus(freshFile, "idle");
    const staleTime = new Date(Date.now() - 15 * 24 * 60 * 60 * 1000);
    utimesSync(staleFile, staleTime, staleTime);

    pruneStaleSessionState(directory);

    assert.equal(existsSync(staleFile), false);
    assert.equal(existsSync(freshFile), true);
    pruneStaleSessionState(join(directory, "does-not-exist"));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("model selection survives status changes and is removed by /mix out", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-state-model-"));
  const stateFile = join(directory, "state.json");
  try {
    writeSessionState(stateFile, {
      status: "idle",
      finalAnswer: null,
      codexModel: "gpt-5.6-sol",
      reasoningEffort: "high",
    });

    writeSessionStatus(stateFile, "pending");
    assert.deepEqual(readSessionState(stateFile), {
      status: "pending",
      finalAnswer: null,
      codexModel: "gpt-5.6-sol",
      reasoningEffort: "high",
    });

    removeSessionState(stateFile);
    assert.deepEqual(readSessionState(stateFile), {
      status: "missing",
      finalAnswer: null,
      codexModel: null,
      reasoningEffort: null,
    });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
