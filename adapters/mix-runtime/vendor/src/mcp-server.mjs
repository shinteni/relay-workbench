#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as z from "zod/v4";

import { prepareCodexHome } from "./codex-home.mjs";
import { CodexPeer } from "./codex-peer.mjs";
import { DebateManager } from "./debate-manager.mjs";
import {
  DEFAULT_REASONING_EFFORT,
  readCodexModelOptions,
} from "./model-options.mjs";
import {
  markRecoveryIfNeeded,
  pruneStaleSessionState,
  readSessionState,
  readSessionStatus,
  removeSessionState,
  sessionStateFile,
  writeSessionState,
  writeSessionStatus,
} from "./session-state.mjs";
import {
  formatDebateTrace,
  formatFinalTrace,
  formatInitialTrace,
} from "./trace-format.mjs";

const cwd =
  process.env.DUAL_CONSENSUS_CWD ||
  process.env.CLAUDE_PROJECT_DIR ||
  process.cwd();
const configuredCodexHome = process.env.DUAL_CONSENSUS_CODEX_HOME;
const configuredStateFile = process.env.DUAL_CONSENSUS_STATE_FILE;
let runtimeDirectory = null;
let runtimeCodexHome = null;

function ensureCodexHome() {
  if (configuredCodexHome) return configuredCodexHome;
  if (!runtimeCodexHome) {
    runtimeDirectory = mkdtempSync(join(tmpdir(), "claude-codex-mix-"));
    registerRuntimeCleanup();
    runtimeCodexHome = prepareCodexHome(runtimeDirectory);
  }
  return runtimeCodexHome;
}

if (configuredStateFile) markRecoveryIfNeeded(configuredStateFile);
else pruneStaleSessionState();
const peer = new CodexPeer({ cwd, codexHomeFactory: ensureCodexHome });
const manager = new DebateManager({ peer });
const server = new McpServer({
  name: "mix-claude-codex-consensus",
  version: "0.1.0",
});
let pluginSessionId = null;
let pluginStateInitialized = false;

function resolveStateFile(sessionId) {
  if (configuredStateFile) return configuredStateFile;
  if (!sessionId) throw new Error("Claude session id is required for /mix.");
  if (pluginSessionId !== sessionId) {
    // The same server process may serve a new Claude session id (e.g. after
    // /clear). Rebind instead of rejecting: per-session state is already
    // isolated on disk, only the in-memory debate must not leak across.
    manager.reset();
    pluginSessionId = sessionId;
    pluginStateInitialized = false;
  }
  const stateFile = sessionStateFile(sessionId);
  if (!pluginStateInitialized) {
    markRecoveryIfNeeded(stateFile);
    pluginStateInitialized = true;
  }
  return stateFile;
}

const BLOCKING_STATUSES = new Set([
  "pending",
  "debating",
  "need_evidence",
  "awaiting_confirmation",
  "executing",
  "recovery_needed",
]);

function failCycleTool(stateFile, error) {
  if (error.code === "MIX_CYCLE_RESET") throw error;
  // Leave a status the Stop hook does not block on, so a Codex failure is
  // reported to the user instead of looping the turn against the same error.
  if (BLOCKING_STATUSES.has(readSessionStatus(stateFile))) {
    writeSessionStatus(stateFile, "peer_error");
  }
  throw new Error(
    `${error.message} — the MIX consensus round failed. Briefly tell the user, suggest retrying or /mix out, and do not fabricate a consensus. MIX stays active.`,
  );
}

function requireActiveStateFile(sessionId) {
  const stateFile = resolveStateFile(sessionId);
  if (!configuredStateFile && readSessionStatus(stateFile) === "missing") {
    throw new Error("MIX mode is not active. Invoke /mix first.");
  }
  return stateFile;
}

function toolResult(value, trace = JSON.stringify(value)) {
  return {
    content: [{ type: "text", text: trace }],
    structuredContent: value,
  };
}

function traceResult(trace) {
  return {
    content: [{ type: "text", text: trace }],
  };
}

function modelTraceFields(state) {
  return {
    codex_model: state.codexModel || "auto",
    codex_reasoning_effort:
      state.reasoningEffort || DEFAULT_REASONING_EFFORT,
  };
}

server.registerTool(
  "activate",
  {
    description:
      "Activate persistent MIX mode only for an explicit /mix skill invocation. MIX remains active until deactivate is called by /mix out.",
    inputSchema: {
      session_id: z.string().min(1),
      task_present: z.boolean(),
    },
    outputSchema: {
      status: z.literal("active"),
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false,
    },
  },
  ({ session_id, task_present }) => {
    const stateFile = resolveStateFile(session_id);
    manager.reset();
    writeSessionStatus(stateFile, task_present ? "pending" : "idle");
    return toolResult({ status: "active" }, "🟣 MIX\n状态：已启用");
  },
);

server.registerTool(
  "deactivate",
  {
    description:
      "Deactivate MIX mode for this Claude Code session. This is called only for an explicit /mix out command.",
    inputSchema: {
      session_id: z.string().min(1),
    },
    outputSchema: {
      status: z.literal("inactive"),
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false,
    },
  },
  ({ session_id }) => {
    const stateFile = resolveStateFile(session_id);
    manager.reset();
    removeSessionState(stateFile);
    return toolResult({ status: "inactive" }, "🟣 MIX\n状态：已退出");
  },
);

server.registerTool(
  "configure_model",
  {
    description:
      "Show or update the Codex model and reasoning effort for this Claude session. Short model aliases such as sol are accepted. This never starts a debate, activates MIX, or exits MIX.",
    inputSchema: {
      session_id: z.string().min(1),
      model: z.string().min(1).optional(),
      reasoning_effort: z.string().min(1).optional(),
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false,
    },
  },
  async ({ session_id, model: requestedModel, reasoning_effort }) => {
    const stateFile = resolveStateFile(session_id);
    if (manager.activeCycleId) {
      const cycle = manager.getCycle(manager.activeCycleId);
      if (!["consensus", "limit_reached"].includes(cycle.status)) {
        // "idle" lets the refusal be delivered; the unresolved cycle is
        // superseded by the next start_cycle rather than blocking Stop.
        if (readSessionStatus(stateFile) !== "missing") {
          writeSessionStatus(stateFile, "idle");
        }
        return traceResult(
          "🟣 MIX 模型配置\n当前共识周期尚未结束，不能切换模型。",
        );
      }
    }

    const previousState = readSessionState(stateFile);
    try {
      let models = null;
      let catalogError = null;
      try {
        models = readCodexModelOptions();
      } catch (error) {
        catalogError = error;
      }
      const usage = models
        ? [
            "用法：/mix model <model> <effort>",
            `可用模型：auto, ${models
              .map((candidate) => candidate.slug.split("-").at(-1))
              .join(", ")}（也可使用完整型号）`,
          ]
        : [
            "用法：/mix model <model> <effort>",
            "无法读取 Codex 模型目录（models_cache.json）。请先运行一次 codex CLI 以生成模型缓存。",
          ];
      const finishWithoutChange = (message) => {
        if (previousState.status !== "missing") {
          writeSessionState(stateFile, {
            ...previousState,
            status: "idle",
            finalAnswer: null,
          });
        }
        return traceResult(["🟣 MIX 模型配置", message, ...usage].join("\n"));
      };

      if (requestedModel === undefined && reasoning_effort === undefined) {
        return finishWithoutChange(
          `当前：${previousState.codexModel || "auto"} · ${previousState.reasoningEffort || DEFAULT_REASONING_EFFORT}`,
        );
      }
      if (requestedModel === undefined || reasoning_effort === undefined) {
        return finishWithoutChange("模型和思考等级必须同时提供。");
      }
      if (!models) {
        return finishWithoutChange(
          `无法配置模型：${catalogError.message}`,
        );
      }

      const normalizedModel = requestedModel.trim().toLowerCase();
      const matchingModels = models.filter(
        (candidate) =>
          candidate.slug.toLowerCase() === normalizedModel ||
          candidate.slug.toLowerCase().endsWith(`-${normalizedModel}`),
      );
      if (normalizedModel !== "auto" && matchingModels.length !== 1) {
        return finishWithoutChange(`无法识别模型：${requestedModel}`);
      }
      const selectedModel =
        normalizedModel === "auto" ? models[0] : matchingModels[0];
      const normalizedEffort = reasoning_effort.trim().toLowerCase();
      const supportedEfforts = selectedModel.reasoningEfforts.map(
        (level) => level.effort,
      );
      if (!supportedEfforts.includes(normalizedEffort)) {
        return finishWithoutChange(
          `思考等级 ${reasoning_effort} 不适用于 ${selectedModel.slug}。可用等级：${supportedEfforts.join(", ")}`,
        );
      }

      const nextState = {
        ...previousState,
        status: previousState.status === "missing" ? "missing" : "idle",
        finalAnswer: null,
        codexModel: normalizedModel === "auto" ? null : selectedModel.slug,
        reasoningEffort: normalizedEffort,
      };
      writeSessionState(stateFile, nextState);
      peer.setModelOptions({
        model: nextState.codexModel,
        reasoningEffort: nextState.reasoningEffort,
      });
      manager.reset();
      return traceResult(
        [
          "🟣 MIX 模型配置已更新",
          "",
          `🟢 Codex · ${nextState.codexModel || "auto"}`,
          `思考等级：${nextState.reasoningEffort}`,
          "生效时间：下一个共识周期",
        ].join("\n"),
      );
    } catch (error) {
      // Restore the previous configuration, but never re-persist a blocking
      // status: a failed config command must not railroad the turn into a
      // consensus cycle.
      writeSessionState(stateFile, {
        ...previousState,
        status: previousState.status === "missing" ? "missing" : "idle",
        finalAnswer: null,
      });
      throw error;
    }
  },
);

server.registerTool(
  "start_cycle",
  {
    description:
      "While MIX mode is active, start a private Claude-Codex consensus cycle. Claude must form its own conclusion first. Codex receives the user question without Claude's current conclusion.",
    inputSchema: {
      session_id: z.string().min(1).optional(),
      question: z.string().min(1),
      claude_conclusion: z.string().min(1),
      prior_consensus: z.string().optional(),
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false,
    },
  },
  async ({ session_id, question, claude_conclusion, prior_consensus }) => {
    const stateFile = requireActiveStateFile(session_id);
    const state = readSessionState(stateFile);
    peer.setModelOptions({
      model: state.codexModel,
      reasoningEffort:
        state.reasoningEffort || DEFAULT_REASONING_EFFORT,
    });
    let result;
    try {
      result = await manager.startCycle({
        question,
        claudeConclusion: claude_conclusion,
        priorConsensus: prior_consensus,
      });
    } catch (error) {
      failCycleTool(stateFile, error);
    }
    writeSessionStatus(stateFile, result.status);
    return traceResult(
      formatInitialTrace(claude_conclusion, {
        ...result,
        ...modelTraceFields(state),
      }),
    );
  },
);

server.registerTool(
  "debate_round",
  {
    description:
      "Submit Claude's latest position and a complete consensus candidate to the same Codex thread. Repeat until a candidate is accepted or the tool requires user input/stops.",
    inputSchema: {
      session_id: z.string().min(1).optional(),
      cycle_id: z.string().min(1),
      claude_position: z.string().min(1),
      proposed_consensus: z.string().min(1),
      evidence: z.string().optional(),
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false,
    },
  },
  async ({
    session_id,
    cycle_id,
    claude_position,
    proposed_consensus,
    evidence,
  }) => {
    const stateFile = requireActiveStateFile(session_id);
    const state = readSessionState(stateFile);
    let result;
    try {
      result = await manager.debateRound({
        cycleId: cycle_id,
        claudePosition: claude_position,
        proposedConsensus: proposed_consensus,
        evidence,
      });
    } catch (error) {
      if (error.code === "MIX_UNKNOWN_CYCLE") {
        writeSessionStatus(stateFile, "recovery_needed");
        return traceResult(
          "🟣 MIX 恢复\n上一个共识周期已不在内存中，请使用当前证据重新调用 start_cycle。",
        );
      }
      failCycleTool(stateFile, error);
    }
    writeSessionStatus(stateFile, result.status);
    return traceResult(
      formatDebateTrace(claude_position, proposed_consensus, {
        ...result,
        ...modelTraceFields(state),
      }),
    );
  },
);

server.registerTool(
  "finalize_cycle",
  {
    description:
      "Finalize the consensus candidate already accepted by Codex. Omit consensus_text to finalize the exact stored candidate (recommended); when provided it must match the accepted candidate byte-for-byte. Returns the only answer Claude should show the user.",
    inputSchema: {
      session_id: z.string().min(1).optional(),
      cycle_id: z.string().min(1),
      consensus_text: z.string().min(1).optional(),
    },
    annotations: {
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false,
    },
  },
  ({ session_id, cycle_id, consensus_text }) => {
    const stateFile = requireActiveStateFile(session_id);
    const state = readSessionState(stateFile);
    const result = manager.finalizeCycle({
      cycleId: cycle_id,
      consensusText: consensus_text,
    });
    writeSessionState(stateFile, {
      ...state,
      status: result.status,
      finalAnswer: result.final_answer,
    });
    return traceResult(formatFinalTrace(result.final_answer));
  },
);

function registerRuntimeCleanup() {
  const cleanup = () => {
    if (runtimeDirectory) {
      rmSync(runtimeDirectory, { recursive: true, force: true });
    }
  };
  process.once("exit", cleanup);
  process.once("SIGHUP", () => {
    cleanup();
    process.exit(129);
  });
  process.once("SIGINT", () => {
    cleanup();
    process.exit(130);
  });
  process.once("SIGTERM", () => {
    cleanup();
    process.exit(143);
  });
}

const transport = new StdioServerTransport();
await server.connect(transport);
