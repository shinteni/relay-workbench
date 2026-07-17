use std::ffi::OsString;
use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::Result;
use cli_adapters::{ChildLine, emit, read_request, resolve_cli, run_cli};
use relay_protocol::{TaskOutputKind, TaskStatus};
use serde_json::Value;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    let request = read_request("mix-adapter")?;
    let node = resolve_cli(
        "RELAY_NODE_PATH",
        &[
            PathBuf::from("/opt/homebrew/bin/node"),
            PathBuf::from("/usr/local/bin/node"),
        ],
    )?;
    let runner = resolve_cli("RELAY_MIX_RUNNER", &[])?;
    let session_id = request
        .session_id
        .clone()
        .unwrap_or_else(|| request.task_id.to_string());
    emit(
        &request,
        TaskStatus::Starting,
        Some("Starting MIX consensus".to_owned()),
        None,
        Some(session_id),
    )?;

    let model = request
        .options
        .get("codex_model")
        .map(String::as_str)
        .unwrap_or("gpt-5.6-sol");
    let effort = request
        .options
        .get("codex_reasoning_effort")
        .map(String::as_str)
        .unwrap_or("max");
    let mut arguments = vec![
        runner.into_os_string(),
        OsString::from("--task-id"),
        OsString::from(request.task_id.to_string()),
        OsString::from("--cwd"),
        request.cwd.as_os_str().to_owned(),
        OsString::from("--model"),
        OsString::from(model),
        OsString::from("--effort"),
        OsString::from(effort),
    ];
    if request.session_id.is_some() {
        arguments.push(OsString::from("--resume"));
    }
    emit(
        &request,
        TaskStatus::Running,
        Some("Claude and Codex are analyzing independently".to_owned()),
        None,
        None,
    )?;

    let mut failure = None;
    let mut final_answer = None;
    let mut stderr_tail = String::new();
    let status = run_cli(
        &node,
        arguments,
        &request.cwd,
        &request.prompt,
        |line| match line {
            ChildLine::Stdout(line) => {
                let value: Value = serde_json::from_str(&line)?;
                handle_mix_event(&request, &value, &mut final_answer, &mut failure)
            }
            ChildLine::Stderr(line) => {
                if !line.trim().is_empty() {
                    stderr_tail = line;
                }
                Ok(())
            }
        },
    )?;

    if status.success() && failure.is_none() {
        if let Some(answer) = final_answer.filter(|answer| !answer.trim().is_empty()) {
            emit(
                &request,
                TaskStatus::Completed,
                Some("MIX consensus completed".to_owned()),
                Some((TaskOutputKind::Assistant, answer)),
                None,
            )?;
            return Ok(());
        }
        failure = Some("MIX completed without a final answer".to_owned());
    }

    let message = failure
        .or_else(|| (!stderr_tail.is_empty()).then_some(stderr_tail))
        .unwrap_or_else(|| format!("MIX exited with {status}"));
    emit(
        &request,
        TaskStatus::Failed,
        Some(message.clone()),
        Some((TaskOutputKind::Error, message)),
        None,
    )?;
    Ok(())
}

fn handle_mix_event(
    request: &relay_protocol::AdapterRunRequest,
    value: &Value,
    final_answer: &mut Option<String>,
    failure: &mut Option<String>,
) -> Result<()> {
    match value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default()
    {
        "system" if value.get("subtype").and_then(Value::as_str) == Some("init") => emit(
            request,
            TaskStatus::Running,
            Some("MIX session started".to_owned()),
            None,
            None,
        ),
        "assistant" => {
            let Some(content) = value.pointer("/message/content").and_then(Value::as_array) else {
                return Ok(());
            };
            for item in content {
                let Some(name) = item
                    .get("name")
                    .and_then(Value::as_str)
                    .filter(|_| item.get("type").and_then(Value::as_str) == Some("tool_use"))
                else {
                    continue;
                };
                if let Some(message) = mix_status_message(name) {
                    emit(
                        request,
                        TaskStatus::Running,
                        Some(message.to_owned()),
                        None,
                        None,
                    )?;
                }
            }
            Ok(())
        }
        "result" => {
            if value.get("is_error").and_then(Value::as_bool) == Some(true) {
                *failure = Some(
                    value
                        .get("result")
                        .and_then(Value::as_str)
                        .unwrap_or("MIX reported an error")
                        .to_owned(),
                );
            } else if let Some(answer) = value.get("result").and_then(Value::as_str) {
                *final_answer = Some(answer.to_owned());
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn mix_status_message(tool_name: &str) -> Option<&'static str> {
    if tool_name.ends_with("start_cycle") {
        Some("Claude and Codex formed independent conclusions")
    } else if tool_name.ends_with("debate_round") {
        Some("Claude and Codex are resolving differences")
    } else if tool_name.ends_with("finalize_cycle") {
        Some("Claude and Codex reached consensus")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_consensus_tools_produce_public_statuses() {
        assert_eq!(
            mix_status_message("mcp__dual_consensus__start_cycle"),
            Some("Claude and Codex formed independent conclusions")
        );
        assert_eq!(mix_status_message("Read"), None);
    }
}
