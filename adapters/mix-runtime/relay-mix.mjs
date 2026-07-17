#!/usr/bin/env node

import { spawn } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  realpathSync,
  statSync,
} from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const runnerRoot = dirname(fileURLToPath(import.meta.url));
const runtimeRoot = resolve(
  process.env.RELAY_MIX_RUNTIME_ROOT || runnerRoot,
);
const { buildClaudeArgs } = await import(
  pathToFileURL(join(runtimeRoot, "bin/dual-claude.mjs")).href
);
const { prepareCodexHome } = await import(
  pathToFileURL(join(runtimeRoot, "src/codex-home.mjs")).href
);
const { readSessionState, writeSessionState } = await import(
  pathToFileURL(join(runtimeRoot, "src/session-state.mjs")).href
);

const allowedEfforts = new Set([
  "low",
  "medium",
  "high",
  "xhigh",
  "max",
  "ultra",
]);

export function parseArguments(argv) {
  const result = {
    cwd: null,
    effort: "max",
    model: "gpt-5.6-sol",
    resume: false,
    taskId: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--resume") {
      result.resume = true;
      continue;
    }
    const value = argv[index + 1];
    if (!["--cwd", "--effort", "--model", "--task-id"].includes(argument)) {
      throw new Error(`Unknown argument: ${argument}`);
    }
    if (!value) throw new Error(`${argument} requires a value.`);
    index += 1;
    if (argument === "--cwd") result.cwd = value;
    if (argument === "--effort") result.effort = value;
    if (argument === "--model") result.model = value;
    if (argument === "--task-id") result.taskId = value;
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result.taskId || "")) {
    throw new Error("--task-id must be a UUID.");
  }
  if (!result.cwd || !isAbsolute(result.cwd)) {
    throw new Error("--cwd must be an absolute directory path.");
  }
  if (!existsSync(result.cwd) || !statSync(result.cwd).isDirectory()) {
    throw new Error(`Working directory does not exist: ${result.cwd}`);
  }
  if (!result.model.trim() || result.model.length > 128) {
    throw new Error("--model is invalid.");
  }
  if (!allowedEfforts.has(result.effort)) {
    throw new Error(`Unsupported reasoning effort: ${result.effort}`);
  }
  return result;
}

export function prepareTaskRuntime({ effort, model, taskId }, stateRoot) {
  const taskDirectory = join(stateRoot, taskId);
  mkdirSync(taskDirectory, { recursive: true, mode: 0o700 });
  chmodSync(taskDirectory, 0o700);
  const stateFile = join(taskDirectory, "state.json");
  const previousState = readSessionState(stateFile);
  writeSessionState(stateFile, {
    ...previousState,
    status: "pending",
    finalAnswer: null,
    codexModel: model === "auto" ? null : model,
    reasoningEffort: effort,
  });
  const codexHome = join(taskDirectory, "codex-home");
  if (!existsSync(codexHome)) prepareCodexHome(taskDirectory);
  return { codexHome, stateFile };
}

export async function main(argv = process.argv.slice(2)) {
  const options = parseArguments(argv);
  const claudePath = process.env.RELAY_CLAUDE_PATH;
  if (!claudePath || !isAbsolute(claudePath) || !existsSync(claudePath)) {
    throw new Error("RELAY_CLAUDE_PATH does not point to Claude CLI.");
  }
  const codexPath = process.env.RELAY_CODEX_PATH;
  if (!codexPath || !isAbsolute(codexPath) || !existsSync(codexPath)) {
    throw new Error("RELAY_CODEX_PATH does not point to Codex CLI.");
  }
  const stateRoot = resolve(
    process.env.RELAY_MIX_STATE_DIR ||
      join(process.env.HOME || runnerRoot, "Library/Application Support/Relay/mix"),
  );
  mkdirSync(stateRoot, { recursive: true, mode: 0o700 });
  chmodSync(stateRoot, 0o700);
  const { codexHome, stateFile } = prepareTaskRuntime(options, stateRoot);
  const forwardedArgs = [
    "--print",
    "--input-format",
    "text",
    "--output-format",
    "stream-json",
    "--verbose",
    "--permission-mode",
    "auto",
    ...(options.resume
      ? ["--resume", options.taskId]
      : ["--session-id", options.taskId]),
  ];
  const claudeArgs = buildClaudeArgs({
    codexHome,
    projectDir: realpathSync(options.cwd),
    stateFile,
    forwardedArgs,
    userSettings: {},
  });
  const child = spawn(claudePath, claudeArgs, {
    cwd: options.cwd,
    env: {
      ...process.env,
      DUAL_CONSENSUS_STATE_FILE: stateFile,
      RELAY_CODEX_PATH: codexPath,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  child.stdout.pipe(process.stdout);
  child.stderr.pipe(process.stderr);
  process.stdin.pipe(child.stdin);
  const exitCode = await new Promise((resolveExit, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      resolveExit(signal ? 1 : (code ?? 1));
    });
  });
  process.exitCode = exitCode;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
