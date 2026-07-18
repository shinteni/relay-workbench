function formatList(values) {
  return values.length ? values.map((value) => `- ${value}`).join("\n") : "- 无";
}

function formatCodexLabel(result) {
  return `🟢 Codex · ${result.codex_model || "auto"} · ${result.codex_reasoning_effort || "default"}`;
}

export function formatInitialTrace(claudeConclusion, result) {
  return [
    `🟣 MIX · ${result.cycle_id}`,
    `状态：${result.status} · 回合：${result.round}/${result.max_rounds}`,
    "",
    "🔵 Claude",
    claudeConclusion,
    "",
    formatCodexLabel(result),
    result.codex_initial_conclusion,
    "",
    `依据摘要：${result.codex_rationale_summary}`,
    `置信度：${result.confidence}`,
    "待补证据：",
    formatList(result.evidence_needed),
  ].join("\n");
}

export function formatDebateTrace(claudePosition, proposedConsensus, result) {
  return [
    `🟣 MIX · 辩论回合 ${result.round}/${result.max_rounds}`,
    "",
    "🔵 Claude",
    claudePosition,
    "",
    "提议的共识：",
    proposedConsensus,
    "",
    formatCodexLabel(result),
    result.codex_response,
    "",
    "🟣 共识状态",
    `Codex 接受候选：${result.codex_accepts_candidate ? "是" : "否"}`,
    "共识候选：",
    result.consensus_candidate ?? "无",
    "未解决分歧：",
    formatList(result.blocking_disagreements),
    `需要用户回答：${result.user_question ?? "无"}`,
    `状态：${result.status}`,
  ].join("\n");
}

export function formatFinalTrace(finalAnswer) {
  return `🟣 MIX 共识\n${finalAnswer}`;
}
