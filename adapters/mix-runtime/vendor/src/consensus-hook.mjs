#!/usr/bin/env node

import { realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";

import {
  authorizeCommandTool,
  clearCommandToolAuthorization,
  consumeCommandToolAuthorization,
  readSessionState,
  removeSessionState,
  sessionStateFile,
  writeSessionStatus,
} from "./session-state.mjs";

const CONSENSUS_TOOL_PREFIXES = [
  "mcp__dual_consensus__",
  "mcp__plugin_mix_codex__",
];

const COMMAND_TOOLS = new Set([
  "activate",
  "configure_model",
  "deactivate",
]);

// Tools that cannot change project or system state. Anything not listed —
// including unknown MCP tools — is treated as mutating.
const NON_MUTATING_TOOLS = new Set([
  "Read",
  "Glob",
  "Grep",
  "WebFetch",
  "WebSearch",
  "TodoWrite",
  "TodoRead",
  "NotebookRead",
  "AskUserQuestion",
  "BashOutput",
  "TaskOutput",
  "ListMcpResourcesTool",
  "ReadMcpResourceTool",
]);

function consensusToolName(toolName) {
  for (const prefix of CONSENSUS_TOOL_PREFIXES) {
    if (toolName?.startsWith(prefix)) return toolName.slice(prefix.length);
  }
  return null;
}

function explicitMixCommandTool(prompt) {
  if (typeof prompt !== "string") return null;
  const match = prompt.trim().match(/^\/(\S+)(?:\s+([\s\S]*))?$/);
  if (!match) return null;
  const command = match[1].toLowerCase();
  const argumentsText = (match[2] || "").trim();
  if (command === "mix-model") return "configure_model";
  if (command === "mix-out") return "deactivate";
  if (command !== "mix") return null;
  if (/^out[.,!?;:，。！？；：]*$/i.test(argumentsText)) {
    return "deactivate";
  }
  if (argumentsText.split(/\s+/, 1)[0] === "model") {
    return "configure_model";
  }
  return "activate";
}

function denyCommandTool() {
  return {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason:
        "MIX command tools require the matching explicit /mix command from the user.",
    },
  };
}

function activeMixContext(sessionId, previousStatus) {
  const cycleInstruction =
    previousStatus === "need_user"
      ? "The previous cycle paused on a blocking question and the user has now answered. Continue that same cycle: call mcp__plugin_mix_codex__debate_round with its cycle_id, folding the user's answer into Claude's position and evidence. Only call start_cycle with the fully recomposed original task if that cycle is no longer available."
      : "For the current user prompt, independently form Claude's concise conclusion, then call mcp__plugin_mix_codex__start_cycle with the exact task before answering or mutating anything.";
  return [
    "MIX mode is active for this Claude Code session and remains active until the user enters /mix out.",
    `Use session_id ${JSON.stringify(sessionId)} in every MIX MCP call.`,
    "For an explicit /mix model command, call mcp__plugin_mix_codex__configure_model, passing optional model and reasoning_effort arguments, and stop without starting a consensus cycle.",
    cycleInstruction,
    "Compare the labeled Codex conclusion, submit a complete candidate with mcp__plugin_mix_codex__debate_round, and continue only while material disagreement or missing evidence remains.",
    "Only mcp__plugin_mix_codex__finalize_cycle establishes consensus; call it with the cycle_id and omit consensus_text so the server finalizes the exact accepted candidate. For answer-only work, output exactly final_answer with no tool calls in between. For requested actions, first finalize the execution plan, perform only that plan, then run and finalize a read-only verification cycle and output exactly its final_answer.",
    "If the result is need_user, ask only the blocking question. If it is limit_reached, report only the unresolved blocking point. If a MIX tool reports that the Codex peer failed, briefly tell the user and stop; MIX stays active. Never reveal hidden chain-of-thought.",
  ].join("\n");
}

export function evaluateHook(input, stateFile) {
  const pluginScoped = !stateFile;
  const resolvedStateFile = stateFile || sessionStateFile(input.session_id);
  const currentState = readSessionState(resolvedStateFile);

  if (input.hook_event_name === "PreToolUse") {
    const consensusTool = consensusToolName(input.tool_name);
    if (consensusTool) {
      if (COMMAND_TOOLS.has(consensusTool)) {
        if (
          !pluginScoped ||
          !consumeCommandToolAuthorization(resolvedStateFile, consensusTool)
        ) {
          return denyCommandTool();
        }
        // 明示的な無効化は Claude Code 標準の権限確認を通す。
        if (consensusTool === "deactivate") return null;
        return {
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "allow",
            permissionDecisionReason:
              "This local consensus tool is authorized for an explicit MIX command.",
          },
        };
      }
      if (currentState.status !== "missing") {
        return {
          hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "allow",
            permissionDecisionReason:
              "This local consensus tool is authorized while MIX is active.",
          },
        };
      }
      return null;
    }
    if (pluginScoped && currentState.status === "missing") return null;
    if (
      currentState.status === "consensus" &&
      !NON_MUTATING_TOOLS.has(input.tool_name)
    ) {
      writeSessionStatus(resolvedStateFile, "executing");
    }
    return null;
  }

  if (input.hook_event_name === "SessionEnd") {
    // /clear discards the conversation, so the session's MIX state would
    // otherwise be orphaned forever. Normal exits keep it for --resume.
    if (pluginScoped && input.reason === "clear") {
      removeSessionState(resolvedStateFile);
    }
    return null;
  }
  if (input.hook_event_name === "UserPromptSubmit") {
    const commandTool = pluginScoped
      ? explicitMixCommandTool(input.prompt)
      : null;
    if (pluginScoped) clearCommandToolAuthorization(resolvedStateFile);
    if (pluginScoped && currentState.status === "missing") {
      if (commandTool) authorizeCommandTool(resolvedStateFile, commandTool);
      return null;
    }
    const previousStatus = currentState.status;
    writeSessionStatus(resolvedStateFile, "pending");
    if (pluginScoped && commandTool) {
      authorizeCommandTool(resolvedStateFile, commandTool);
    }
    if (!pluginScoped) return null;
    return {
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: activeMixContext(input.session_id, previousStatus),
      },
    };
  }
  if (pluginScoped && currentState.status === "missing") return null;
  if (input.hook_event_name !== "Stop") return null;

  const status = currentState.status;
  if (["idle", "need_user", "limit_reached", "peer_error"].includes(status)) {
    return null;
  }
  if (status === "consensus") {
    if (currentState.finalAnswer === null) {
      return {
        decision: "block",
        reason:
          "The finalized answer was lost. Start a new cycle from the current evidence and finalize it before answering.",
      };
    }
    if (
      (input.last_assistant_message ?? "").trim() ===
      currentState.finalAnswer.trim()
    ) {
      // The consensus answer was delivered; consume it so later bookkeeping
      // tool calls cannot re-trigger the executing/verification path.
      writeSessionStatus(resolvedStateFile, "idle");
      return null;
    }
    return {
      decision: "block",
      reason: `Output exactly the final_answer returned by finalize_cycle, without additions or changes. Expected text:\n${currentState.finalAnswer}`,
    };
  }

  const instructions = {
    pending:
      "Do not answer yet. Form Claude's independent conclusion and call start_cycle, then complete the required debate and finalize the accepted candidate. If an unresolved cycle is waiting on the user's answer, continue it with debate_round instead.",
    debating:
      "Do not answer yet. Compare the independent conclusions and call debate_round with a complete consensus candidate.",
    need_evidence:
      "Do not answer yet. Gather the necessary read-only evidence and continue the same cycle with debate_round.",
    awaiting_confirmation:
      "Do not answer yet. Either finalize the accepted candidate with finalize_cycle (omit consensus_text) or continue debating a materially different proposal.",
    executing:
      "Do not answer yet. Start a new read-only consensus cycle to verify the completed action and agree on the exact user-facing result, then finalize it.",
    recovery_needed:
      "The consensus service restarted and lost its in-memory cycle. Start a new cycle from the current evidence before answering or taking another action.",
  };

  return {
    decision: "block",
    reason: instructions[status] || instructions.pending,
  };
}

async function readStdin() {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  return input;
}

export async function main() {
  const input = JSON.parse(await readStdin());
  const result = evaluateHook(input, process.env.DUAL_CONSENSUS_STATE_FILE);
  if (result) process.stdout.write(JSON.stringify(result));
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href
) {
  main().catch(() => {
    if (process.env.DUAL_CONSENSUS_STATE_FILE) {
      process.stderr.write("Dual consensus hook failed closed.\n");
      process.exitCode = 2;
    }
  });
}
