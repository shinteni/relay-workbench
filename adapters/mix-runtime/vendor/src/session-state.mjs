import { createHash, randomUUID } from "node:crypto";
import {
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const defaultMixStateDirectory = join(homedir(), ".claude", "mix-state");
const commandAuthorizationMaxAgeMs = 5 * 60 * 1000;

function readSessionRecord(stateFile) {
  if (!stateFile) return null;
  try {
    const value = JSON.parse(readFileSync(stateFile, "utf8"));
    return value && typeof value === "object" && !Array.isArray(value)
      ? value
      : null;
  } catch {
    return null;
  }
}

export function sessionStateFile(
  sessionId,
  stateDirectory = process.env.MIX_STATE_DIR || defaultMixStateDirectory,
) {
  if (typeof sessionId !== "string" || !sessionId.trim()) {
    throw new Error("Claude session id is required.");
  }
  const name = createHash("sha256").update(sessionId).digest("hex");
  return join(stateDirectory, `${name}.json`);
}

export function readSessionState(stateFile) {
  const value = readSessionRecord(stateFile);
  if (!value) {
    return {
      status: "missing",
      finalAnswer: null,
      codexModel: null,
      reasoningEffort: null,
    };
  }
  return {
    status: typeof value.status === "string" ? value.status : "missing",
    finalAnswer:
      typeof value.finalAnswer === "string" ? value.finalAnswer : null,
    codexModel:
      typeof value.codexModel === "string" ? value.codexModel : null,
    reasoningEffort:
      typeof value.reasoningEffort === "string"
        ? value.reasoningEffort
        : null,
  };
}

export function readSessionStatus(stateFile) {
  return readSessionState(stateFile).status;
}

export function writeSessionState(stateFile, state) {
  if (!stateFile) throw new Error("Session state file is required.");
  mkdirSync(dirname(stateFile), { recursive: true, mode: 0o700 });
  const temporaryFile = `${stateFile}.${process.pid}.${randomUUID()}.tmp`;
  writeFileSync(temporaryFile, JSON.stringify(state), { mode: 0o600 });
  renameSync(temporaryFile, stateFile);
}

export function writeSessionStatus(stateFile, status) {
  const currentState = readSessionState(stateFile);
  writeSessionState(stateFile, {
    ...currentState,
    status,
    finalAnswer: null,
  });
}

export function authorizeCommandTool(stateFile, toolName) {
  const currentRecord = readSessionRecord(stateFile) || {};
  writeSessionState(stateFile, {
    ...currentRecord,
    authorizedCommandTool: toolName,
    commandAuthorizedAt: Date.now(),
  });
}

export function clearCommandToolAuthorization(stateFile) {
  const currentRecord = readSessionRecord(stateFile);
  if (!currentRecord || !("authorizedCommandTool" in currentRecord)) return;
  delete currentRecord.authorizedCommandTool;
  delete currentRecord.commandAuthorizedAt;
  if (Object.keys(currentRecord).length) writeSessionState(stateFile, currentRecord);
  else rmSync(stateFile, { force: true });
}

export function consumeCommandToolAuthorization(stateFile, toolName) {
  const currentRecord = readSessionRecord(stateFile);
  if (!currentRecord) return false;
  const age = Date.now() - currentRecord.commandAuthorizedAt;
  const valid =
    currentRecord.authorizedCommandTool === toolName &&
    Number.isFinite(age) &&
    age >= 0 &&
    age <= commandAuthorizationMaxAgeMs;
  if (valid || !Number.isFinite(age) || age > commandAuthorizationMaxAgeMs) {
    clearCommandToolAuthorization(stateFile);
  }
  return valid;
}

export function removeSessionState(stateFile) {
  if (stateFile) rmSync(stateFile, { force: true });
}

export const DEFAULT_STATE_MAX_AGE_MS = 14 * 24 * 60 * 60 * 1000;

export function pruneStaleSessionState(
  stateDirectory = process.env.MIX_STATE_DIR || defaultMixStateDirectory,
  maxAgeMs = DEFAULT_STATE_MAX_AGE_MS,
) {
  let entries;
  try {
    entries = readdirSync(stateDirectory);
  } catch {
    return;
  }
  const cutoff = Date.now() - maxAgeMs;
  for (const name of entries) {
    if (!name.endsWith(".json")) continue;
    const filePath = join(stateDirectory, name);
    try {
      if (statSync(filePath).mtimeMs < cutoff) rmSync(filePath, { force: true });
    } catch {
      // A concurrently removed or unreadable file is not worth failing over.
    }
  }
}

export function markRecoveryIfNeeded(stateFile) {
  const previousState = readSessionState(stateFile);
  if (["missing", "pending"].includes(previousState.status)) {
    return previousState.status;
  }
  writeSessionStatus(stateFile, "recovery_needed");
  return "recovery_needed";
}
