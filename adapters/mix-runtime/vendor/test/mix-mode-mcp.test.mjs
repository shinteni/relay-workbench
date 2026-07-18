import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

import {
  readSessionState,
  readSessionStatus,
  sessionStateFile,
  writeSessionState,
} from "../src/session-state.mjs";

test("MCP activate persists MIX state and deactivate is the only exit", async () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-mcp-"));
  const codexHome = join(directory, "codex-home");
  const stateDirectory = join(directory, "state");
  const client = new Client({ name: "mix-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [
      fileURLToPath(new URL("../src/mcp-server.mjs", import.meta.url)),
    ],
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    env: {
      DUAL_CONSENSUS_CODEX_HOME: codexHome,
      MIX_STATE_DIR: stateDirectory,
    },
    stderr: "pipe",
  });

  try {
    await client.connect(transport);
    const inactiveStart = await client.callTool({
      name: "start_cycle",
      arguments: {
        session_id: "claude-session",
        question: "Question",
        claude_conclusion: "Claude conclusion",
      },
    });
    assert.equal(inactiveStart.isError, true);
    assert.match(inactiveStart.content[0].text, /not active/i);
    assert.equal(
      readSessionStatus(sessionStateFile("claude-session", stateDirectory)),
      "missing",
    );

    const activated = await client.callTool({
      name: "activate",
      arguments: {
        session_id: "claude-session",
        task_present: false,
      },
    });
    assert.equal(activated.structuredContent.status, "active");
    assert.equal(activated.content[0].text, "🟣 MIX\n状态：已启用");
    assert.equal(
      readSessionStatus(sessionStateFile("claude-session", stateDirectory)),
      "idle",
    );

    await client.callTool({
      name: "activate",
      arguments: {
        session_id: "claude-session",
        task_present: true,
      },
    });
    assert.equal(
      readSessionStatus(sessionStateFile("claude-session", stateDirectory)),
      "pending",
    );

    const deactivated = await client.callTool({
      name: "deactivate",
      arguments: { session_id: "claude-session" },
    });
    assert.equal(deactivated.structuredContent.status, "inactive");
    assert.equal(deactivated.content[0].text, "🟣 MIX\n状态：已退出");
    assert.equal(
      readSessionStatus(sessionStateFile("claude-session", stateDirectory)),
      "missing",
    );
  } finally {
    await transport.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("MCP server rebinds to a new session id after /clear", async () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-mcp-rebind-"));
  const stateDirectory = join(directory, "state");
  const client = new Client({ name: "mix-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [
      fileURLToPath(new URL("../src/mcp-server.mjs", import.meta.url)),
    ],
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    env: {
      DUAL_CONSENSUS_CODEX_HOME: join(directory, "codex-home"),
      MIX_STATE_DIR: stateDirectory,
    },
    stderr: "pipe",
  });

  try {
    await client.connect(transport);
    const first = await client.callTool({
      name: "activate",
      arguments: { session_id: "session-before-clear", task_present: false },
    });
    assert.equal(first.structuredContent.status, "active");

    const second = await client.callTool({
      name: "activate",
      arguments: { session_id: "session-after-clear", task_present: false },
    });
    assert.equal(second.isError ?? false, false);
    assert.equal(second.structuredContent.status, "active");
    assert.equal(
      readSessionStatus(sessionStateFile("session-after-clear", stateDirectory)),
      "idle",
    );

    const exited = await client.callTool({
      name: "deactivate",
      arguments: { session_id: "session-after-clear" },
    });
    assert.equal(exited.structuredContent.status, "inactive");
  } finally {
    await transport.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("a missing in-memory cycle requests recovery instead of peer failure", async () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-mcp-recovery-"));
  const stateDirectory = join(directory, "state");
  const stateFile = sessionStateFile("resumed-session", stateDirectory);
  writeSessionState(stateFile, {
    status: "pending",
    finalAnswer: null,
    codexModel: null,
    reasoningEffort: "max",
  });
  const client = new Client({ name: "mix-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [
      fileURLToPath(new URL("../src/mcp-server.mjs", import.meta.url)),
    ],
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    env: {
      DUAL_CONSENSUS_CODEX_HOME: join(directory, "codex-home"),
      MIX_STATE_DIR: stateDirectory,
    },
    stderr: "pipe",
  });

  try {
    await client.connect(transport);
    const result = await client.callTool({
      name: "debate_round",
      arguments: {
        session_id: "resumed-session",
        cycle_id: "lost-cycle",
        claude_position: "Position",
        proposed_consensus: "Proposal",
      },
    });

    assert.equal(result.isError ?? false, false);
    assert.match(result.content[0].text, /start_cycle/);
    assert.equal(readSessionStatus(stateFile), "recovery_needed");
  } finally {
    await transport.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("MCP model command degrades gracefully without a Codex model catalog", async () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-mcp-nocatalog-"));
  const emptyCodexHome = join(directory, "empty-codex-home");
  mkdirSync(emptyCodexHome);
  const client = new Client({ name: "mix-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [
      fileURLToPath(new URL("../src/mcp-server.mjs", import.meta.url)),
    ],
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    env: {
      CODEX_HOME: emptyCodexHome,
      DUAL_CONSENSUS_CODEX_HOME: join(directory, "runtime-codex-home"),
      MIX_STATE_DIR: join(directory, "state"),
    },
    stderr: "pipe",
  });

  try {
    await client.connect(transport);
    const shown = await client.callTool({
      name: "configure_model",
      arguments: { session_id: "claude-session" },
    });

    assert.equal(shown.isError ?? false, false);
    assert.match(shown.content[0].text, /当前：auto · max/);
    assert.match(shown.content[0].text, /models_cache\.json/);

    const configured = await client.callTool({
      name: "configure_model",
      arguments: {
        session_id: "claude-session",
        model: "sol",
        reasoning_effort: "xhigh",
      },
    });
    assert.equal(configured.isError ?? false, false);
    assert.match(configured.content[0].text, /无法配置模型/);
  } finally {
    await transport.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("MCP cycle tools expose labeled text instead of structured JSON", async () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-mcp-tools-"));
  const client = new Client({ name: "mix-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [
      fileURLToPath(new URL("../src/mcp-server.mjs", import.meta.url)),
    ],
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    env: {
      DUAL_CONSENSUS_CODEX_HOME: join(directory, "codex-home"),
      MIX_STATE_DIR: join(directory, "state"),
    },
    stderr: "pipe",
  });

  try {
    await client.connect(transport);
    const { tools } = await client.listTools();
    const toolsByName = new Map(tools.map((tool) => [tool.name, tool]));

    for (const name of ["start_cycle", "debate_round", "finalize_cycle"]) {
      assert.equal(toolsByName.get(name).outputSchema, undefined);
    }
    assert.equal(toolsByName.get("configure_model").outputSchema, undefined);
    assert.ok(toolsByName.get("activate").outputSchema);
    assert.ok(toolsByName.get("deactivate").outputSchema);
  } finally {
    await transport.close();
    rmSync(directory, { recursive: true, force: true });
  }
});

test("MCP model command works without elicitation or active MIX", async () => {
  const directory = mkdtempSync(join(tmpdir(), "mix-mcp-model-"));
  const sourceCodexHome = join(directory, "source-codex-home");
  const stateDirectory = join(directory, "state");
  mkdirSync(sourceCodexHome);
  writeFileSync(
    join(sourceCodexHome, "models_cache.json"),
    JSON.stringify({
      fetched_at: "2026-07-13T09:22:57Z",
      models: [
        {
          slug: "gpt-5.6-sol",
          display_name: "GPT-5.6-Sol",
          visibility: "list",
          default_reasoning_level: "medium",
          supported_reasoning_levels: [
            { effort: "low", description: "Fast" },
            { effort: "medium", description: "Balanced" },
            { effort: "high", description: "Deep" },
            { effort: "xhigh", description: "Extra deep" },
            { effort: "max", description: "Maximum" },
            { effort: "ultra", description: "Delegation" },
          ],
        },
      ],
    }),
  );

  const client = new Client({ name: "mix-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [
      fileURLToPath(new URL("../src/mcp-server.mjs", import.meta.url)),
    ],
    cwd: fileURLToPath(new URL("..", import.meta.url)),
    env: {
      CODEX_HOME: sourceCodexHome,
      DUAL_CONSENSUS_CODEX_HOME: join(directory, "runtime-codex-home"),
      MIX_STATE_DIR: stateDirectory,
    },
    stderr: "pipe",
  });

  try {
    await client.connect(transport);
    const stateFile = sessionStateFile("claude-session", stateDirectory);
    const shown = await client.callTool({
      name: "configure_model",
      arguments: { session_id: "claude-session" },
    });

    assert.match(shown.content[0].text, /当前：auto · max/);
    assert.match(shown.content[0].text, /\/mix model <model> <effort>/);
    assert.equal(readSessionStatus(stateFile), "missing");

    const configured = await client.callTool({
      name: "configure_model",
      arguments: {
        session_id: "claude-session",
        model: "sol",
        reasoning_effort: "xhigh",
      },
    });

    assert.match(configured.content[0].text, /gpt-5\.6-sol/);
    assert.match(configured.content[0].text, /xhigh/);
    assert.deepEqual(readSessionState(stateFile), {
      status: "missing",
      finalAnswer: null,
      codexModel: "gpt-5.6-sol",
      reasoningEffort: "xhigh",
    });

    await client.callTool({
      name: "activate",
      arguments: { session_id: "claude-session", task_present: false },
    });
    assert.equal(readSessionStatus(stateFile), "idle");

    const invalid = await client.callTool({
      name: "configure_model",
      arguments: {
        session_id: "claude-session",
        model: "unknown",
        reasoning_effort: "xhigh",
      },
    });
    assert.match(invalid.content[0].text, /无法识别模型：unknown/);
    assert.match(invalid.content[0].text, /可用模型：auto, sol/);
    assert.equal(readSessionState(stateFile).codexModel, "gpt-5.6-sol");
    assert.equal(readSessionState(stateFile).reasoningEffort, "xhigh");
  } finally {
    await transport.close();
    rmSync(directory, { recursive: true, force: true });
  }
});
