import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { evaluateHook } from "../src/consensus-hook.mjs";
import {
  readSessionState,
  readSessionStatus,
  sessionStateFile,
  writeSessionState,
  writeSessionStatus,
} from "../src/session-state.mjs";

test("a submitted prompt resets the launcher session to pending", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-hook-"));
  const stateFile = join(directory, "state.json");
  try {
    writeSessionStatus(stateFile, "consensus");
    const result = evaluateHook(
      { hook_event_name: "UserPromptSubmit" },
      stateFile,
    );

    assert.equal(result, null);
    assert.equal(readSessionStatus(stateFile), "pending");
    assert.equal(readSessionState(stateFile).finalAnswer, null);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Stop is blocked until the exact consensus is finalized", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-hook-"));
  const stateFile = join(directory, "state.json");
  try {
    for (const status of [
      "pending",
      "debating",
      "need_evidence",
      "awaiting_confirmation",
    ]) {
      writeSessionStatus(stateFile, status);
      const result = evaluateHook({ hook_event_name: "Stop" }, stateFile);
      assert.equal(result.decision, "block");
    }

    writeSessionState(stateFile, {
      status: "consensus",
      finalAnswer: "Exact final answer",
    });
    assert.equal(
      evaluateHook(
        {
          hook_event_name: "Stop",
          last_assistant_message: "Exact final answer",
        },
        stateFile,
      ),
      null,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Stop rejects output that differs from the finalized answer", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-hook-"));
  const stateFile = join(directory, "state.json");
  try {
    writeSessionState(stateFile, {
      status: "consensus",
      finalAnswer: "Accepted answer",
    });
    const result = evaluateHook(
      {
        hook_event_name: "Stop",
        last_assistant_message: "Accepted answer with an extra sentence",
      },
      stateFile,
    );

    assert.equal(result.decision, "block");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("ordinary tools use native Claude permissions and execution is still tracked", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-hook-"));
  const stateFile = join(directory, "state.json");
  try {
    writeSessionStatus(stateFile, "pending");
    for (const tool_name of ["Read", "Edit", "Bash", "Task"]) {
      assert.equal(
        evaluateHook({ hook_event_name: "PreToolUse", tool_name }, stateFile),
        null,
      );
    }
    assert.equal(readSessionStatus(stateFile), "pending");

    writeSessionState(stateFile, {
      status: "consensus",
      finalAnswer: "Authorized plan",
    });
    assert.equal(
      evaluateHook(
        { hook_event_name: "PreToolUse", tool_name: "Edit" },
        stateFile,
      ),
      null,
    );
    assert.equal(readSessionStatus(stateFile), "executing");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("read-only tools after consensus do not trigger the executing transition", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-hook-"));
  const stateFile = join(directory, "state.json");
  try {
    writeSessionState(stateFile, {
      status: "consensus",
      finalAnswer: "Agreed answer",
    });
    for (const tool_name of ["Read", "Glob", "Grep", "TodoWrite", "WebFetch"]) {
      assert.equal(
        evaluateHook({ hook_event_name: "PreToolUse", tool_name }, stateFile),
        null,
      );
      assert.equal(readSessionStatus(stateFile), "consensus");
    }
    assert.equal(readSessionState(stateFile).finalAnswer, "Agreed answer");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("launcher hook process fails closed on invalid input", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-hook-"));
  const stateFile = join(directory, "state.json");
  const result = spawnSync(
    process.execPath,
    [fileURLToPath(new URL("../src/consensus-hook.mjs", import.meta.url))],
    {
      input: "not-json",
      encoding: "utf8",
      env: { ...process.env, DUAL_CONSENSUS_STATE_FILE: stateFile },
    },
  );

  assert.equal(result.status, 2);
  assert.match(result.stderr, /failed closed/);
  rmSync(directory, { recursive: true, force: true });
});

test("plugin hook process fails open on invalid input", () => {
  const result = spawnSync(
    process.execPath,
    [fileURLToPath(new URL("../src/consensus-hook.mjs", import.meta.url))],
    {
      input: "not-json",
      encoding: "utf8",
      env: { ...process.env, DUAL_CONSENSUS_STATE_FILE: "" },
    },
  );

  assert.equal(result.status, 0);
  assert.equal(result.stderr, "");
});

test("plugin hook runs when its entry path contains a symlink", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-link-"));
  const stateDirectory = join(directory, "state");
  const projectLink = join(directory, "mix-runtime");
  const projectRoot = fileURLToPath(new URL("..", import.meta.url));
  symlinkSync(projectRoot, projectLink, "dir");
  writeSessionStatus(
    sessionStateFile("claude-session", stateDirectory),
    "pending",
  );

  try {
    const result = spawnSync(
      process.execPath,
      [join(projectLink, "src", "consensus-hook.mjs")],
      {
        input: JSON.stringify({
          hook_event_name: "PreToolUse",
          session_id: "claude-session",
          tool_name: "mcp__plugin_mix_codex__start_cycle",
        }),
        encoding: "utf8",
        env: { ...process.env, MIX_STATE_DIR: stateDirectory },
      },
    );

    assert.equal(result.status, 0);
    assert.equal(
      JSON.parse(result.stdout).hookSpecificOutput.permissionDecision,
      "allow",
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("Stop allows a blocking user question, a round-limit report, or a peer failure", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-hook-"));
  const stateFile = join(directory, "state.json");
  try {
    for (const status of ["idle", "need_user", "limit_reached", "peer_error"]) {
      writeSessionStatus(stateFile, status);
      assert.equal(evaluateHook({ hook_event_name: "Stop" }, stateFile), null);
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("a delivered consensus answer is consumed so later tools cannot re-trigger executing", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-hook-"));
  const stateFile = join(directory, "state.json");
  try {
    writeSessionState(stateFile, {
      status: "consensus",
      finalAnswer: "Exact final answer",
    });
    assert.equal(
      evaluateHook(
        {
          hook_event_name: "Stop",
          last_assistant_message: "Exact final answer\n",
        },
        stateFile,
      ),
      null,
    );
    assert.equal(readSessionStatus(stateFile), "idle");
    assert.equal(readSessionState(stateFile).finalAnswer, null);

    assert.equal(
      evaluateHook(
        { hook_event_name: "PreToolUse", tool_name: "Edit" },
        stateFile,
      ),
      null,
    );
    assert.equal(readSessionStatus(stateFile), "idle");
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("a blocked consensus stop repeats the expected answer text", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-hook-"));
  const stateFile = join(directory, "state.json");
  try {
    writeSessionState(stateFile, {
      status: "consensus",
      finalAnswer: "Accepted answer",
    });
    const result = evaluateHook(
      { hook_event_name: "Stop", last_assistant_message: "Something else" },
      stateFile,
    );
    assert.equal(result.decision, "block");
    assert.match(result.reason, /Accepted answer/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("a skill-scoped hook allows ordinary tools in an active MIX session", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    const stateFile = sessionStateFile("claude-session", directory);
    writeSessionStatus(stateFile, "pending");

    const result = evaluateHook(
      {
        hook_event_name: "PreToolUse",
        session_id: "claude-session",
        tool_name: "Edit",
      },
    );

    assert.equal(result, null);
    assert.equal(readSessionStatus(stateFile), "pending");
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("a completed plugin cycle remains active until /mix out", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    const stateFile = sessionStateFile("claude-session", directory);
    writeSessionState(stateFile, {
      status: "consensus",
      finalAnswer: "Exact answer",
    });

    assert.equal(
      evaluateHook({
        hook_event_name: "Stop",
        session_id: "claude-session",
        last_assistant_message: "Exact answer",
      }),
      null,
    );
    // Delivered answers are consumed, but MIX itself stays active.
    assert.equal(readSessionStatus(stateFile), "idle");

    assert.equal(
      evaluateHook({
        hook_event_name: "SessionEnd",
        session_id: "claude-session",
        reason: "exit",
      }),
      null,
    );
    assert.equal(readSessionStatus(stateFile), "idle");
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("/clear removes the cleared session's MIX state", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    const stateFile = sessionStateFile("claude-session", directory);
    writeSessionStatus(stateFile, "idle");

    assert.equal(
      evaluateHook({
        hook_event_name: "SessionEnd",
        session_id: "claude-session",
        reason: "clear",
      }),
      null,
    );
    assert.equal(readSessionStatus(stateFile), "missing");

    writeSessionState(stateFile, {
      status: "missing",
      finalAnswer: null,
      codexModel: "gpt-5.6-sol",
      reasoningEffort: "max",
    });
    assert.equal(existsSync(stateFile), true);
    evaluateHook({
      hook_event_name: "SessionEnd",
      session_id: "claude-session",
      reason: "clear",
    });
    assert.equal(existsSync(stateFile), false);
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("plugin hooks are silent outside MIX mode", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    const input = { session_id: "native-session" };

    assert.equal(
      evaluateHook({ ...input, hook_event_name: "UserPromptSubmit" }),
      null,
    );
    assert.equal(
      evaluateHook({
        ...input,
        hook_event_name: "PreToolUse",
        tool_name: "Edit",
      }),
      null,
    );
    assert.equal(
      evaluateHook({ ...input, hook_event_name: "Stop" }),
      null,
    );
    assert.equal(
      readSessionStatus(sessionStateFile("native-session", directory)),
      "missing",
    );
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("only explicit MIX commands authorize command tools once", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    for (const { prompt, tool } of [
      { prompt: "/mix", tool: "activate" },
      { prompt: "/mix-model sol max", tool: "configure_model" },
    ]) {
      evaluateHook({
        hook_event_name: "UserPromptSubmit",
        session_id: "new-session",
        prompt,
      });
      const authorized = evaluateHook({
        hook_event_name: "PreToolUse",
        session_id: "new-session",
        tool_name: `mcp__plugin_mix_codex__${tool}`,
      });
      assert.equal(
        authorized.hookSpecificOutput.permissionDecision,
        "allow",
      );
      const reused = evaluateHook({
        hook_event_name: "PreToolUse",
        session_id: "new-session",
        tool_name: `mcp__plugin_mix_codex__${tool}`,
      });
      assert.equal(reused.hookSpecificOutput.permissionDecision, "deny");
    }
    assert.equal(
      readSessionStatus(sessionStateFile("new-session", directory)),
      "missing",
    );
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("cycle tools are not auto-approved while MIX is inactive", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    for (const tool of ["start_cycle", "debate_round", "finalize_cycle"]) {
      assert.equal(
        evaluateHook({
          hook_event_name: "PreToolUse",
          session_id: "new-session",
          tool_name: `mcp__plugin_mix_codex__${tool}`,
        }),
        null,
      );
    }
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("an explicit deactivate goes through native permission exactly once", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    const stateFile = sessionStateFile("claude-session", directory);
    writeSessionStatus(stateFile, "idle");
    evaluateHook({
      hook_event_name: "UserPromptSubmit",
      session_id: "claude-session",
      prompt: "/mix out",
    });

    assert.equal(
      evaluateHook({
        hook_event_name: "PreToolUse",
        session_id: "claude-session",
        tool_name: "mcp__plugin_mix_codex__deactivate",
      }),
      null,
    );
    const reused = evaluateHook({
      hook_event_name: "PreToolUse",
      session_id: "claude-session",
      tool_name: "mcp__plugin_mix_codex__deactivate",
    });
    assert.equal(reused.hookSpecificOutput.permissionDecision, "deny");
    assert.equal(readSessionStatus(stateFile), "pending");
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("ordinary prompts cannot authorize command tools or clear the gate", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    const stateFile = sessionStateFile("claude-session", directory);
    writeSessionStatus(stateFile, "idle");
    evaluateHook({
      hook_event_name: "UserPromptSubmit",
      session_id: "claude-session",
      prompt: "Answer without consensus",
    });

    for (const tool of ["activate", "configure_model", "deactivate"]) {
      const result = evaluateHook({
        hook_event_name: "PreToolUse",
        session_id: "claude-session",
        tool_name: `mcp__plugin_mix_codex__${tool}`,
      });
      assert.equal(result.hookSpecificOutput.permissionDecision, "deny");
    }
    assert.equal(readSessionStatus(stateFile), "pending");
    assert.equal(
      evaluateHook(
        { hook_event_name: "Stop", last_assistant_message: "No consensus" },
        stateFile,
      ).decision,
      "block",
    );
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("an active MIX session reinjects the consensus protocol each turn", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    const stateFile = sessionStateFile("claude-session", directory);
    writeSessionStatus(stateFile, "idle");

    const result = evaluateHook({
      hook_event_name: "UserPromptSubmit",
      session_id: "claude-session",
    });

    assert.equal(readSessionStatus(stateFile), "pending");
    assert.equal(
      result.hookSpecificOutput.hookEventName,
      "UserPromptSubmit",
    );
    assert.match(
      result.hookSpecificOutput.additionalContext,
      /MIX mode is active/,
    );
    assert.match(
      result.hookSpecificOutput.additionalContext,
      /mcp__plugin_mix_codex__start_cycle/,
    );
    assert.match(
      result.hookSpecificOutput.additionalContext,
      /claude-session/,
    );
    assert.match(result.hookSpecificOutput.additionalContext, /\/mix out/);
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("a prompt after need_user directs resuming the same cycle", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    const stateFile = sessionStateFile("claude-session", directory);
    writeSessionStatus(stateFile, "need_user");

    const result = evaluateHook({
      hook_event_name: "UserPromptSubmit",
      session_id: "claude-session",
    });

    assert.equal(readSessionStatus(stateFile), "pending");
    assert.match(
      result.hookSpecificOutput.additionalContext,
      /Continue that same cycle/,
    );
    assert.match(
      result.hookSpecificOutput.additionalContext,
      /mcp__plugin_mix_codex__debate_round/,
    );
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});

test("an active MIX session explicitly approves its consensus MCP tools", () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-hook-"));
  const previousDirectory = process.env.MIX_STATE_DIR;
  process.env.MIX_STATE_DIR = directory;
  try {
    const stateFile = sessionStateFile("claude-session", directory);
    writeSessionStatus(stateFile, "pending");

    const result = evaluateHook({
      hook_event_name: "PreToolUse",
      session_id: "claude-session",
      tool_name: "mcp__plugin_mix_codex__start_cycle",
    });

    assert.equal(
      result.hookSpecificOutput.permissionDecision,
      "allow",
    );
    assert.equal(readSessionStatus(stateFile), "pending");
  } finally {
    if (previousDirectory === undefined) delete process.env.MIX_STATE_DIR;
    else process.env.MIX_STATE_DIR = previousDirectory;
    rmSync(directory, { recursive: true, force: true });
  }
});
