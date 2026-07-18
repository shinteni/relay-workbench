import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const reasoningEffortLabels = new Map([
  ["low", "Light"],
  ["medium", "Medium"],
  ["high", "High"],
  ["xhigh", "Extra High"],
  ["max", "Max"],
  ["ultra", "Ultra"],
]);

export const DEFAULT_REASONING_EFFORT = "max";

export function readCodexModelOptions(
  sourceCodexHome = process.env.CODEX_HOME || resolve(homedir(), ".codex"),
) {
  const catalog = JSON.parse(
    readFileSync(join(sourceCodexHome, "models_cache.json"), "utf8"),
  );
  const models = (catalog.models || [])
    .filter(
      (model) =>
        model?.visibility === "list" &&
        typeof model.slug === "string" &&
        typeof model.display_name === "string",
    )
    .map((model) => ({
      slug: model.slug,
      displayName: model.display_name,
      priority:
        typeof model.priority === "number"
          ? model.priority
          : Number.MAX_SAFE_INTEGER,
      defaultReasoningEffort:
        typeof model.default_reasoning_level === "string"
          ? model.default_reasoning_level
          : null,
      reasoningEfforts: (model.supported_reasoning_levels || [])
        .filter((level) => reasoningEffortLabels.has(level?.effort))
        .map((level) => ({
          effort: level.effort,
          displayName: reasoningEffortLabels.get(level.effort),
          description:
            typeof level.description === "string" ? level.description : "",
        })),
    }))
    .sort((left, right) => left.priority - right.priority);
  if (!models.length) {
    throw new Error("No selectable Codex models were found in models_cache.json.");
  }
  return models;
}
