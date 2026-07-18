import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readlinkSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  buildClaudeArgs,
  parseLauncherArgs,
  prepareCodexHome,
} from "../bin/dual-claude.mjs";

test("launcher separates its project directory option from Claude arguments", () => {
  const parsed = parseLauncherArgs(
    ["--project-dir", "/tmp", "--model", "sonnet"],
    "/ignored",
  );

  assert.equal(parsed.projectDir, "/tmp");
  assert.deepEqual(parsed.forwardedArgs, ["--model", "sonnet"]);
});

test("launcher parses explicit Claude settings instead of forwarding them", () => {
  const parsed = parseLauncherArgs(
    [
      "--settings",
      '{"env":{"EXAMPLE":"1"}}',
      "--model",
      "sonnet",
    ],
    "/tmp",
  );

  assert.deepEqual(parsed.userSettings, { env: { EXAMPLE: "1" } });
  assert.deepEqual(parsed.forwardedArgs, ["--model", "sonnet"]);
});

test("launcher resolves a settings file from the target project", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-launcher-settings-"));
  const settingsFile = join(directory, "session-settings.json");
  writeFileSync(settingsFile, '{"env":{"FROM_FILE":"1"}}');

  try {
    const parsed = parseLauncherArgs(
      ["--settings", "session-settings.json"],
      directory,
    );
    assert.deepEqual(parsed.userSettings, { env: { FROM_FILE: "1" } });
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("launcher injects the local prompt and MCP server", () => {
  const args = buildClaudeArgs({
    codexHome: "/tmp/isolated-codex-home",
    projectDir: "/tmp",
    stateFile: "/tmp/dual-state.json",
    forwardedArgs: ["--permission-mode", "plan"],
    userSettings: {
      env: { EXAMPLE: "1" },
      hooks: {
        Stop: [{ hooks: [{ type: "command", command: "existing-hook" }] }],
      },
    },
  });
  const promptIndex = args.indexOf("--append-system-prompt-file");
  const configIndex = args.indexOf("--mcp-config");
  const settingsIndex = args.indexOf("--settings");
  const config = JSON.parse(args[configIndex + 1]);
  const settings = JSON.parse(args[settingsIndex + 1]);

  assert.notEqual(promptIndex, -1);
  assert.notEqual(configIndex, -1);
  assert.notEqual(settingsIndex, -1);
  assert.equal(config.mcpServers.dual_consensus.type, "stdio");
  assert.equal(config.mcpServers.dual_consensus.env.DUAL_CONSENSUS_CWD, "/tmp");
  assert.equal(
    config.mcpServers.dual_consensus.env.DUAL_CONSENSUS_STATE_FILE,
    "/tmp/dual-state.json",
  );
  assert.equal(
    config.mcpServers.dual_consensus.env.DUAL_CONSENSUS_CODEX_HOME,
    "/tmp/isolated-codex-home",
  );
  assert.equal(settings.hooks.PreToolUse[0].hooks[0].type, "command");
  assert.equal(settings.hooks.Stop[0].hooks[0].command, "existing-hook");
  assert.equal(settings.hooks.Stop[1].hooks[0].type, "command");
  assert.equal(settings.env.EXAMPLE, "1");
  assert.equal(settings.disableAllHooks, false);
  assert.equal(args.includes("mcp__dual_consensus__finalize_cycle"), true);
  assert.equal(args.includes("--strict-mcp-config"), true);
  assert.equal(args[args.indexOf("--setting-sources") + 1], "");
  assert.equal(args.indexOf("--permission-mode") < configIndex, true);
});

test("launcher refuses settings that disable all hooks instead of silently overriding", () => {
  assert.throws(
    () =>
      buildClaudeArgs({
        codexHome: "/tmp/isolated-codex-home",
        projectDir: "/tmp",
        stateFile: "/tmp/dual-state.json",
        userSettings: { disableAllHooks: true },
      }),
    /requires hooks/,
  );
});

test("launcher creates an isolated Codex home with only the auth link", () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-launcher-"));
  const source = join(directory, "source");
  const session = join(directory, "session");
  mkdirSync(source);
  mkdirSync(session);
  const sourceAuth = join(source, "auth.json");
  writeFileSync(sourceAuth, "test-auth-placeholder");

  try {
    const codexHome = prepareCodexHome(session, source);
    assert.equal(readlinkSync(join(codexHome, "auth.json")), sourceAuth);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("launcher removes its temporary session after termination", async () => {
  const directory = mkdtempSync(join(tmpdir(), "dual-launcher-signal-"));
  const binDirectory = join(directory, "bin");
  const codexHome = join(directory, "source-codex-home");
  const projectDirectory = join(directory, "project");
  const runtimeDirectory = join(directory, "runtime");
  mkdirSync(binDirectory);
  mkdirSync(codexHome);
  mkdirSync(projectDirectory);
  mkdirSync(runtimeDirectory);
  const fakeClaude = join(binDirectory, "claude");
  writeFileSync(
    fakeClaude,
    "#!/bin/sh\ntrap 'exit 0' HUP INT TERM\nwhile :; do sleep 1; done\n",
  );
  chmodSync(fakeClaude, 0o755);

  try {
    const child = spawn(
      process.execPath,
      [
        fileURLToPath(new URL("../bin/dual-claude.mjs", import.meta.url)),
        "--project-dir",
        projectDirectory,
      ],
      {
        env: {
          ...process.env,
          CODEX_HOME: codexHome,
          PATH: `${binDirectory}:${process.env.PATH}`,
          TMPDIR: runtimeDirectory,
        },
        stdio: "ignore",
      },
    );

    await new Promise((resolve, reject) => {
      const deadline = Date.now() + 3000;
      const check = () => {
        if (
          readdirSync(runtimeDirectory).some((name) =>
            name.startsWith("claude-codex-consensus-"),
          )
        ) {
          resolve();
        } else if (Date.now() >= deadline) {
          reject(new Error("Launcher session directory was not created."));
        } else {
          setTimeout(check, 20);
        }
      };
      check();
    });

    const exitPromise = new Promise((resolve) => {
      child.once("exit", (code) => resolve(code));
    });
    child.kill("SIGTERM");
    const exitCode = await exitPromise;

    assert.equal(exitCode, 143);
    assert.deepEqual(readdirSync(runtimeDirectory), []);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
