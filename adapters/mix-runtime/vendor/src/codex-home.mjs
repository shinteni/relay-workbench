import { existsSync, mkdirSync, symlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

export function prepareCodexHome(
  sessionDirectory,
  sourceCodexHome = process.env.CODEX_HOME || resolve(homedir(), ".codex"),
) {
  const codexHome = join(sessionDirectory, "codex-home");
  mkdirSync(codexHome, { mode: 0o700 });
  const sourceAuth = join(sourceCodexHome, "auth.json");
  if (existsSync(sourceAuth)) {
    symlinkSync(sourceAuth, join(codexHome, "auth.json"));
  }
  return codexHome;
}
