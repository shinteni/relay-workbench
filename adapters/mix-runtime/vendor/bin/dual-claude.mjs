#!/usr/bin/env node

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { prepareCodexHome } from "../src/codex-home.mjs";

export { prepareCodexHome };

const connectorRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const consensusTools = [
  "mcp__dual_consensus__start_cycle",
  "mcp__dual_consensus__debate_round",
  "mcp__dual_consensus__finalize_cycle",
];

function shellQuote(value) {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

export function parseLauncherArgs(argv, defaultProjectDir = process.cwd()) {
  const forwardedArgs = [];
  let projectDir = defaultProjectDir;
  let userSettingsValue = null;

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--project-dir") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--project-dir requires a directory path.");
      }
      projectDir = resolve(value);
      index += 1;
    } else if (argument.startsWith("--project-dir=")) {
      projectDir = resolve(argument.slice("--project-dir=".length));
    } else if (argument === "--settings") {
      const value = argv[index + 1];
      if (!value) {
        throw new Error("--settings requires a JSON object or file path.");
      }
      userSettingsValue = value;
      index += 1;
    } else if (argument.startsWith("--settings=")) {
      userSettingsValue = argument.slice("--settings=".length);
    } else {
      forwardedArgs.push(argument);
    }
  }

  if (!existsSync(projectDir) || !statSync(projectDir).isDirectory()) {
    throw new Error(`Project directory does not exist: ${projectDir}`);
  }

  const userSettings = userSettingsValue
    ? parseJsonArgument(userSettingsValue, "--settings", projectDir)
    : {};
  return { forwardedArgs, projectDir, userSettings };
}

function parseJsonArgument(value, optionName, baseDirectory) {
  const filePath = resolve(baseDirectory, value);
  const source = existsSync(filePath) ? readFileSync(filePath, "utf8") : value;
  let parsed;
  try {
    parsed = JSON.parse(source);
  } catch {
    throw new Error(`${optionName} must contain valid JSON or name a JSON file.`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`${optionName} must contain a JSON object.`);
  }
  return parsed;
}

export function buildClaudeArgs({
  codexHome,
  projectDir,
  stateFile,
  forwardedArgs = [],
  userSettings = {},
}) {
  const promptPath = resolve(connectorRoot, "prompts/dual-consensus.md");
  const serverPath = resolve(connectorRoot, "src/mcp-server.mjs");
  const hookPath = resolve(connectorRoot, "src/consensus-hook.mjs");
  const hookCommand = `${shellQuote(process.execPath)} ${shellQuote(hookPath)}`;
  const mcpConfig = {
    mcpServers: {
      dual_consensus: {
        type: "stdio",
        command: process.execPath,
        args: [serverPath],
        env: {
          DUAL_CONSENSUS_CWD: projectDir,
          DUAL_CONSENSUS_CODEX_HOME: codexHome,
          DUAL_CONSENSUS_STATE_FILE: stateFile,
        },
      },
    },
  };
  if (
    userSettings.hooks &&
    (typeof userSettings.hooks !== "object" || Array.isArray(userSettings.hooks))
  ) {
    throw new Error("--settings hooks must be a JSON object.");
  }
  if (userSettings.disableAllHooks === true) {
    throw new Error(
      "dual mode requires hooks for its consensus gate; remove disableAllHooks from --settings or run claude directly.",
    );
  }
  const userHooks = userSettings.hooks || {};
  const connectorHook = { hooks: [{ type: "command", command: hookCommand }] };
  const hooks = { ...userHooks };
  for (const event of ["PreToolUse", "UserPromptSubmit", "Stop"]) {
    const existing = userHooks[event] || [];
    if (!Array.isArray(existing)) {
      throw new Error(`--settings hooks.${event} must be an array.`);
    }
    hooks[event] = [...existing, connectorHook];
  }
  const settings = {
    ...userSettings,
    disableAllHooks: false,
    hooks,
  };

  return [
    "--allowedTools",
    ...consensusTools,
    "--append-system-prompt-file",
    promptPath,
    ...forwardedArgs,
    "--setting-sources",
    "",
    "--strict-mcp-config",
    "--mcp-config",
    JSON.stringify(mcpConfig),
    "--settings",
    JSON.stringify(settings),
  ];
}

export async function main(argv = process.argv.slice(2)) {
  const { forwardedArgs, projectDir, userSettings } = parseLauncherArgs(argv);
  const signalExitCodes = new Map([
    ["SIGHUP", 129],
    ["SIGINT", 130],
    ["SIGTERM", 143],
  ]);
  const signalHandlers = new Map();
  let child = null;
  let receivedSignal = null;
  let sessionDirectory = null;
  for (const signal of signalExitCodes.keys()) {
    const handler = () => {
      if (receivedSignal) {
        // A repeated signal means the graceful shutdown is stuck; force it
        // so the finally-block cleanup still runs in this process.
        if (child) child.kill("SIGKILL");
        return;
      }
      receivedSignal = signal;
      if (child) child.kill(signal);
    };
    signalHandlers.set(signal, handler);
    process.on(signal, handler);
  }

  try {
    sessionDirectory = mkdtempSync(
      join(tmpdir(), `claude-codex-consensus-${randomUUID()}-`),
    );
    const stateFile = join(sessionDirectory, "state.json");
    const codexHome = prepareCodexHome(sessionDirectory);
    child = spawn(
      "claude",
      buildClaudeArgs({
        codexHome,
        projectDir,
        stateFile,
        forwardedArgs,
        userSettings,
      }),
      {
        cwd: projectDir,
        env: { ...process.env, DUAL_CONSENSUS_STATE_FILE: stateFile },
        stdio: "inherit",
      },
    );
    const exitCode = await new Promise((resolveExit, reject) => {
      child.once("error", (error) =>
        reject(
          error?.code === "ENOENT"
            ? new Error(
                "Could not find the 'claude' executable on PATH. Shell aliases are not visible to this launcher — add the claude binary's directory to PATH.",
              )
            : error,
        ),
      );
      child.once("exit", (code, signal) => {
        if (signal) {
          resolveExit(1);
        } else {
          resolveExit(code ?? 1);
        }
      });
    });
    process.exitCode = receivedSignal
      ? signalExitCodes.get(receivedSignal)
      : exitCode;
  } finally {
    for (const [signal, handler] of signalHandlers) {
      process.removeListener(signal, handler);
    }
    if (sessionDirectory) {
      rmSync(sessionDirectory, { recursive: true, force: true });
    }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
