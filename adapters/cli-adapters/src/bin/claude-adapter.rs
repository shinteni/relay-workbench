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
    let request = read_request("claude-adapter")?;
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let claude = resolve_cli(
        "RELAY_CLAUDE_PATH",
        &[
            home.join(".local/bin/claude"),
            PathBuf::from("/opt/homebrew/bin/claude"),
            PathBuf::from("/usr/local/bin/claude"),
        ],
    )?;
    let session_id = request
        .session_id
        .clone()
        .unwrap_or_else(|| request.task_id.to_string());
    emit(
        &request,
        TaskStatus::Starting,
        Some("Starting Claude CLI".to_owned()),
        None,
        None,
    )?;

    let mut arguments = vec![
        OsString::from("-p"),
        OsString::from("--input-format"),
        OsString::from("text"),
        OsString::from("--output-format"),
        OsString::from("stream-json"),
        OsString::from("--verbose"),
        OsString::from("--permission-mode"),
        OsString::from("auto"),
    ];
    if let Some(model) = request
        .options
        .get("claude_model")
        .filter(|value| !value.is_empty() && *value != "default")
    {
        arguments.extend([OsString::from("--model"), OsString::from(model)]);
    }
    if let Some(effort) = request
        .options
        .get("claude_effort")
        .filter(|value| !value.is_empty() && *value != "default")
    {
        arguments.extend([OsString::from("--effort"), OsString::from(effort)]);
    }
    arguments.extend(session_arguments(
        &session_id,
        request.session_id.is_some(),
        request
            .options
            .get("relay_fork_from")
            .map(String::as_str)
            .filter(|value| !value.is_empty()),
    ));
    emit(
        &request,
        TaskStatus::Running,
        Some("Claude is working".to_owned()),
        None,
        None,
    )?;

    let mut failure = None;
    let mut stderr_tail = String::new();
    let status = run_cli(
        &claude,
        arguments,
        &request.cwd,
        &request.prompt,
        |line| match line {
            ChildLine::Stdout(line) => {
                let value: Value = serde_json::from_str(&line)?;
                handle_claude_event(&request, &value, &mut failure)
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
        emit(
            &request,
            TaskStatus::Completed,
            Some("Claude completed".to_owned()),
            None,
            Some(session_id),
        )?;
        Ok(())
    } else {
        let message = failure
            .or_else(|| (!stderr_tail.is_empty()).then_some(stderr_tail))
            .unwrap_or_else(|| format!("Claude exited with {status}"));
        emit(
            &request,
            TaskStatus::Failed,
            Some(message.clone()),
            Some((TaskOutputKind::Error, message)),
            None,
        )?;
        Ok(())
    }
}

/// Session arguments for the three flows: resume an existing session, fork a
/// foreign session into this task's own session ID, or start fresh. Forking
/// only applies to first turns — continued turns already own their session.
fn session_arguments(
    session_id: &str,
    resume: bool,
    fork_from: Option<&str>,
) -> Vec<OsString> {
    if resume {
        return vec![OsString::from("--resume"), OsString::from(session_id)];
    }
    if let Some(fork_from) = fork_from {
        return vec![
            OsString::from("--resume"),
            OsString::from(fork_from),
            OsString::from("--fork-session"),
            OsString::from("--session-id"),
            OsString::from(session_id),
        ];
    }
    vec![OsString::from("--session-id"), OsString::from(session_id)]
}

fn handle_claude_event(
    request: &relay_protocol::AdapterRunRequest,
    value: &Value,
    failure: &mut Option<String>,
) -> Result<()> {
    let event_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    match event_type {
        "system" if value.get("subtype").and_then(Value::as_str) == Some("init") => emit(
            request,
            TaskStatus::Running,
            Some("Claude session started".to_owned()),
            None,
            value
                .get("session_id")
                .and_then(Value::as_str)
                .map(str::to_owned),
        ),
        "assistant" => {
            let Some(content) = value.pointer("/message/content").and_then(Value::as_array) else {
                return Ok(());
            };
            for item in content {
                match item.get("type").and_then(Value::as_str).unwrap_or_default() {
                    "text" => {
                        if let Some(text) = item.get("text").and_then(Value::as_str) {
                            emit(
                                request,
                                TaskStatus::Running,
                                Some("Claude responded".to_owned()),
                                Some((TaskOutputKind::Assistant, text.to_owned())),
                                None,
                            )?;
                        }
                    }
                    "tool_use" => {
                        let name = item.get("name").and_then(Value::as_str).unwrap_or("tool");
                        let input = item.get("input").cloned().unwrap_or(Value::Null);
                        emit(
                            request,
                            TaskStatus::Running,
                            Some(format!("Claude called {name}")),
                            Some((
                                TaskOutputKind::Tool,
                                format!("$ {name}\n{}", serde_json::to_string_pretty(&input)?),
                            )),
                            None,
                        )?;
                    }
                    _ => {}
                }
            }
            Ok(())
        }
        "user" => {
            let Some(content) = value.pointer("/message/content").and_then(Value::as_array) else {
                return Ok(());
            };
            for item in content {
                if item.get("type").and_then(Value::as_str) == Some("tool_result") {
                    let text = item
                        .get("content")
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    if !text.is_empty() {
                        emit(
                            request,
                            TaskStatus::Running,
                            Some("Claude received tool output".to_owned()),
                            Some((TaskOutputKind::Tool, text.to_owned())),
                            None,
                        )?;
                    }
                }
            }
            Ok(())
        }
        "result" => {
            if value.get("is_error").and_then(Value::as_bool) == Some(true) {
                let message = value
                    .get("result")
                    .and_then(Value::as_str)
                    .unwrap_or("Claude reported an error")
                    .to_owned();
                *failure = Some(message);
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resume_wins_over_fork_and_uses_the_existing_session() {
        assert_eq!(
            session_arguments("sess-1", true, Some("origin")),
            ["--resume", "sess-1"].map(OsString::from)
        );
    }

    #[test]
    fn first_turn_fork_resumes_origin_into_a_new_session() {
        assert_eq!(
            session_arguments("task-9", false, Some("origin-7")),
            [
                "--resume", "origin-7", "--fork-session", "--session-id", "task-9",
            ]
            .map(OsString::from)
        );
    }

    #[test]
    fn plain_first_turns_start_their_own_session() {
        assert_eq!(
            session_arguments("task-9", false, None),
            ["--session-id", "task-9"].map(OsString::from)
        );
    }
}
