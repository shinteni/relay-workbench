use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{ChildStdin, Command, ExitCode, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

const IDLE_POLL_INTERVAL: Duration = Duration::from_secs(60);
const IDLE_TIMEOUT: Duration = Duration::from_secs(15 * 60);

use anyhow::{Context, Result, bail};
use cli_adapters::{emit, emit_interaction, read_request, resolve_cli};
use relay_protocol::{
    AdapterInteraction, AdapterInteractionKind, AdapterInteractionOption,
    AdapterInteractionQuestion, AdapterInteractionResponse, AdapterRunRequest, TaskOutputKind,
    TaskStatus,
};
use serde_json::{Map, Value, json};

enum ProcessEvent {
    AppServer(String),
    AppServerClosed,
    Stderr(String),
    Relay(String),
    RelayClosed,
}

struct PendingRequest {
    rpc_id: Value,
    method: String,
}

struct TerminalResult {
    status: TaskStatus,
    message: String,
    error: Option<String>,
}

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
    let request = read_request("codex-adapter")?;
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let codex = resolve_cli(
        "RELAY_CODEX_PATH",
        &[
            PathBuf::from("/Applications/ChatGPT.app/Contents/Resources/codex"),
            home.join(".local/bin/codex"),
            PathBuf::from("/opt/homebrew/bin/codex"),
            PathBuf::from("/usr/local/bin/codex"),
        ],
    )?;
    emit(
        &request,
        TaskStatus::Starting,
        Some("Starting Codex app server".to_owned()),
        None,
        request.session_id.clone(),
    )?;

    let mut child = Command::new(&codex)
        .args(["app-server", "--stdio"])
        .current_dir(&request.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to start {}", codex.display()))?;
    let mut app_stdin = child
        .stdin
        .take()
        .context("Codex app-server stdin is unavailable")?;
    let app_stdout = child
        .stdout
        .take()
        .context("Codex app-server stdout is unavailable")?;
    let app_stderr = child
        .stderr
        .take()
        .context("Codex app-server stderr is unavailable")?;
    let (sender, receiver) = mpsc::channel();
    let stdout_sender = sender.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(app_stdout).lines().map_while(Result::ok) {
            if stdout_sender.send(ProcessEvent::AppServer(line)).is_err() {
                return;
            }
        }
        let _ = stdout_sender.send(ProcessEvent::AppServerClosed);
    });
    let stderr_sender = sender.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(app_stderr).lines().map_while(Result::ok) {
            if stderr_sender.send(ProcessEvent::Stderr(line)).is_err() {
                return;
            }
        }
    });
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines().map_while(Result::ok) {
            if sender.send(ProcessEvent::Relay(line)).is_err() {
                return;
            }
        }
        let _ = sender.send(ProcessEvent::RelayClosed);
    });

    let result = run_turn(&request, &receiver, &mut app_stdin);
    drop(app_stdin);
    let _ = child.kill();
    let _ = child.wait();
    let terminal = result?;
    emit(
        &request,
        terminal.status,
        Some(terminal.message),
        terminal
            .error
            .map(|message| (TaskOutputKind::Error, message)),
        None,
    )
}

fn run_turn(
    request: &AdapterRunRequest,
    receiver: &Receiver<ProcessEvent>,
    app_stdin: &mut ChildStdin,
) -> Result<TerminalResult> {
    let mut stderr_tail = String::new();
    send_message(
        app_stdin,
        &json!({
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "relay",
                    "title": "Relay",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "capabilities": { "experimentalApi": true }
            }
        }),
    )?;
    wait_for_response(receiver, 1, &mut stderr_tail)?;
    send_message(app_stdin, &json!({ "method": "initialized" }))?;

    let cwd = request.cwd.to_string_lossy();
    let thread_method = if request.session_id.is_some() {
        "thread/resume"
    } else {
        "thread/start"
    };
    let mut thread_params = json!({
        "cwd": cwd,
        "approvalPolicy": "on-request",
        "approvalsReviewer": "user",
        "sandbox": "workspace-write"
    });
    if let Some(session_id) = &request.session_id {
        thread_params["threadId"] = Value::String(session_id.clone());
    }
    send_message(
        app_stdin,
        &json!({ "id": 2, "method": thread_method, "params": thread_params }),
    )?;
    let thread_response = wait_for_response(receiver, 2, &mut stderr_tail)?;
    let thread_id = thread_response
        .pointer("/thread/id")
        .and_then(Value::as_str)
        .context("Codex thread response did not include an ID")?
        .to_owned();
    let model = thread_response
        .get("model")
        .and_then(Value::as_str)
        .context("Codex thread response did not include a model")?;
    emit(
        request,
        TaskStatus::Running,
        Some("Codex session started".to_owned()),
        None,
        Some(thread_id.clone()),
    )?;

    let mut turn_params = json!({
        "threadId": thread_id,
        "input": [{ "type": "text", "text": request.prompt }]
    });
    if let Some(mode) = request.options.get("codex_mode") {
        if mode != "plan" {
            bail!("unsupported Codex mode: {mode}");
        }
        turn_params["collaborationMode"] = json!({
            "mode": "plan",
            "settings": { "model": model }
        });
    }
    send_message(
        app_stdin,
        &json!({ "id": 3, "method": "turn/start", "params": turn_params }),
    )?;
    wait_for_response(receiver, 3, &mut stderr_tail)?;
    emit(
        request,
        TaskStatus::Running,
        Some("Codex is working".to_owned()),
        None,
        None,
    )?;

    let mut pending = HashMap::<String, PendingRequest>::new();
    let mut open_items = 0usize;
    let mut last_activity = Instant::now();
    loop {
        let event = match receiver.recv_timeout(IDLE_POLL_INTERVAL) {
            Ok(event) => event,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if pending.is_empty() && open_items == 0 && last_activity.elapsed() >= IDLE_TIMEOUT
                {
                    bail!(
                        "Codex produced no activity for {} minutes; treating the app server as hung. The session is preserved and can be continued.",
                        IDLE_TIMEOUT.as_secs() / 60
                    );
                }
                continue;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => bail!("Codex event stream closed"),
        };
        last_activity = Instant::now();
        match event {
            ProcessEvent::AppServer(line) => {
                let value: Value = serde_json::from_str(&line)
                    .with_context(|| format!("failed to decode Codex app-server event: {line}"))?;
                match value.get("method").and_then(Value::as_str) {
                    Some("item/started") => open_items += 1,
                    Some("item/completed") => open_items = open_items.saturating_sub(1),
                    _ => {}
                }
                if value.get("method").is_some() && value.get("id").is_some() {
                    handle_server_request(request, app_stdin, &mut pending, &value)?;
                } else if let Some(terminal) = handle_notification(request, &value)? {
                    return Ok(terminal);
                }
            }
            ProcessEvent::Relay(line) => {
                if line.trim().is_empty() {
                    continue;
                }
                let response: AdapterInteractionResponse = serde_json::from_str(&line)
                    .context("failed to decode Relay interaction response")?;
                let pending_request = pending
                    .remove(&response.interaction_id)
                    .context("Relay responded to an unknown Codex interaction")?;
                let result = response_payload(&pending_request.method, response)?;
                send_message(
                    app_stdin,
                    &json!({ "id": pending_request.rpc_id, "result": result }),
                )?;
                emit(
                    request,
                    TaskStatus::Running,
                    Some("Codex is continuing".to_owned()),
                    None,
                    None,
                )?;
            }
            ProcessEvent::Stderr(line) => {
                if !line.trim().is_empty() {
                    stderr_tail = line;
                }
            }
            ProcessEvent::AppServerClosed => {
                let message = if stderr_tail.is_empty() {
                    "Codex app server closed unexpectedly".to_owned()
                } else {
                    stderr_tail
                };
                bail!(message);
            }
            ProcessEvent::RelayClosed => bail!("Relay closed the interaction channel"),
        }
    }
}

fn wait_for_response(
    receiver: &Receiver<ProcessEvent>,
    expected_id: i64,
    stderr_tail: &mut String,
) -> Result<Value> {
    loop {
        match receiver.recv_timeout(Duration::from_secs(30)) {
            Err(RecvTimeoutError::Timeout) => bail!(
                "Codex app server timed out; allow Relay to access the working directory in macOS System Settings"
            ),
            Err(RecvTimeoutError::Disconnected) => bail!("Codex event stream closed"),
            Ok(event) => match event {
                ProcessEvent::AppServer(line) => {
                    let value: Value = serde_json::from_str(&line).with_context(|| {
                        format!("failed to decode Codex app-server response: {line}")
                    })?;
                    if value.get("id").and_then(Value::as_i64) != Some(expected_id) {
                        continue;
                    }
                    if let Some(error) = value.get("error") {
                        bail!("Codex app-server request failed: {error}");
                    }
                    return value
                        .get("result")
                        .cloned()
                        .context("Codex app-server response did not include a result");
                }
                ProcessEvent::Stderr(line) => {
                    if !line.trim().is_empty() {
                        *stderr_tail = line;
                    }
                }
                ProcessEvent::AppServerClosed => {
                    if stderr_tail.is_empty() {
                        bail!("Codex app server closed during startup");
                    }
                    bail!(stderr_tail.clone());
                }
                ProcessEvent::Relay(_) => {
                    bail!("Relay sent a response before Codex requested input")
                }
                ProcessEvent::RelayClosed => bail!("Relay closed the interaction channel"),
            },
        }
    }
}

fn handle_server_request(
    request: &AdapterRunRequest,
    app_stdin: &mut ChildStdin,
    pending: &mut HashMap<String, PendingRequest>,
    value: &Value,
) -> Result<()> {
    let method = value
        .get("method")
        .and_then(Value::as_str)
        .context("Codex server request did not include a method")?;
    let rpc_id = value
        .get("id")
        .cloned()
        .context("Codex server request did not include an ID")?;
    let interaction_id = serde_json::to_string(&rpc_id)?;
    let params = value.get("params").unwrap_or(&Value::Null);
    let interaction = match method {
        "item/commandExecution/requestApproval" => {
            command_approval(interaction_id.clone(), params)?
        }
        "item/fileChange/requestApproval" => file_approval(interaction_id.clone(), params),
        "item/tool/requestUserInput" => user_input(interaction_id.clone(), params)?,
        _ => {
            send_message(
                app_stdin,
                &json!({
                    "id": rpc_id,
                    "error": { "code": -32601, "message": "Relay does not support this Codex request" }
                }),
            )?;
            return Ok(());
        }
    };
    let status = match interaction.kind {
        AdapterInteractionKind::Approval => TaskStatus::WaitingForApproval,
        AdapterInteractionKind::Input => TaskStatus::WaitingForInput,
    };
    pending.insert(
        interaction_id,
        PendingRequest {
            rpc_id,
            method: method.to_owned(),
        },
    );
    emit_interaction(
        request,
        status,
        "Codex is waiting for your response".to_owned(),
        interaction,
    )
}

fn command_approval(id: String, params: &Value) -> Result<AdapterInteraction> {
    let mut lines = Vec::new();
    if let Some(reason) = params.get("reason").and_then(Value::as_str) {
        lines.push(reason.to_owned());
    }
    if let Some(command) = params.get("command").and_then(Value::as_str) {
        lines.push(format!("$ {command}"));
    }
    if let Some(cwd) = params.get("cwd").and_then(Value::as_str) {
        lines.push(format!("cwd: {cwd}"));
    }
    let decisions = params
        .get("availableDecisions")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .filter(|values| !values.is_empty())
        .unwrap_or_else(|| {
            vec![
                "accept".to_owned(),
                "acceptForSession".to_owned(),
                "decline".to_owned(),
                "cancel".to_owned(),
            ]
        });
    let actions = decisions
        .into_iter()
        .filter_map(|decision| approval_option(&decision))
        .collect::<Vec<_>>();
    if actions.is_empty() {
        bail!("Codex command approval did not include a supported decision");
    }
    Ok(AdapterInteraction {
        id,
        kind: AdapterInteractionKind::Approval,
        title: "Command approval".to_owned(),
        message: if lines.is_empty() {
            "Codex wants to run a command.".to_owned()
        } else {
            lines.join("\n")
        },
        actions,
        questions: Vec::new(),
    })
}

fn file_approval(id: String, params: &Value) -> AdapterInteraction {
    let mut lines = Vec::new();
    if let Some(reason) = params.get("reason").and_then(Value::as_str) {
        lines.push(reason.to_owned());
    }
    if let Some(root) = params.get("grantRoot").and_then(Value::as_str) {
        lines.push(format!("write access: {root}"));
    }
    AdapterInteraction {
        id,
        kind: AdapterInteractionKind::Approval,
        title: "File change approval".to_owned(),
        message: if lines.is_empty() {
            "Codex wants to change files.".to_owned()
        } else {
            lines.join("\n")
        },
        actions: ["accept", "acceptForSession", "decline", "cancel"]
            .into_iter()
            .filter_map(approval_option)
            .collect(),
        questions: Vec::new(),
    }
}

fn user_input(id: String, params: &Value) -> Result<AdapterInteraction> {
    let questions = params
        .get("questions")
        .and_then(Value::as_array)
        .context("Codex user input request did not include questions")?
        .iter()
        .map(|question| {
            let question_id = question
                .get("id")
                .and_then(Value::as_str)
                .context("Codex question did not include an ID")?;
            let prompt = question
                .get("question")
                .and_then(Value::as_str)
                .context("Codex question did not include text")?;
            let options = question
                .get("options")
                .and_then(Value::as_array)
                .map(|options| {
                    options
                        .iter()
                        .filter_map(|option| {
                            let label = option.get("label")?.as_str()?;
                            Some(AdapterInteractionOption {
                                value: label.to_owned(),
                                label: label.to_owned(),
                                description: option
                                    .get("description")
                                    .and_then(Value::as_str)
                                    .map(str::to_owned),
                            })
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            Ok(AdapterInteractionQuestion {
                id: question_id.to_owned(),
                prompt: prompt.to_owned(),
                allow_custom: question
                    .get("isOther")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                    || options.is_empty(),
                secret: question
                    .get("isSecret")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                options,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(AdapterInteraction {
        id,
        kind: AdapterInteractionKind::Input,
        title: "Codex needs input".to_owned(),
        message: "Answer the questions below to continue.".to_owned(),
        actions: Vec::new(),
        questions,
    })
}

fn approval_option(value: &str) -> Option<AdapterInteractionOption> {
    let (label, description) = match value {
        "accept" => ("Allow once", "Run only this requested action."),
        "acceptForSession" => (
            "Allow for session",
            "Allow matching prompts in this session.",
        ),
        "decline" => ("Deny", "Skip this action and let Codex continue."),
        "cancel" => ("Deny & stop", "Deny this action and interrupt the turn."),
        _ => return None,
    };
    Some(AdapterInteractionOption {
        value: value.to_owned(),
        label: label.to_owned(),
        description: Some(description.to_owned()),
    })
}

fn response_payload(method: &str, response: AdapterInteractionResponse) -> Result<Value> {
    match method {
        "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
            let action = response
                .action
                .context("Codex approval response did not include an action")?;
            Ok(json!({ "decision": action }))
        }
        "item/tool/requestUserInput" => {
            let answers = response
                .answers
                .into_iter()
                .map(|(id, answers)| (id, json!({ "answers": answers })))
                .collect::<Map<_, _>>();
            Ok(json!({ "answers": answers }))
        }
        _ => bail!("unsupported pending Codex request: {method}"),
    }
}

fn handle_notification(
    request: &AdapterRunRequest,
    value: &Value,
) -> Result<Option<TerminalResult>> {
    let method = value
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let params = value.get("params").unwrap_or(&Value::Null);
    match method {
        "item/started" => {
            let item = &params["item"];
            if item.get("type").and_then(Value::as_str) == Some("commandExecution")
                && let Some(command) = item.get("command").and_then(Value::as_str)
            {
                emit(
                    request,
                    TaskStatus::Running,
                    Some("Codex started a command".to_owned()),
                    Some((TaskOutputKind::Tool, format!("$ {command}"))),
                    None,
                )?;
            }
        }
        "item/completed" => {
            let item = &params["item"];
            match item.get("type").and_then(Value::as_str).unwrap_or_default() {
                "agentMessage" => {
                    if let Some(text) = item.get("text").and_then(Value::as_str) {
                        emit(
                            request,
                            TaskStatus::Running,
                            Some("Codex responded".to_owned()),
                            Some((TaskOutputKind::Assistant, text.to_owned())),
                            None,
                        )?;
                    }
                }
                "commandExecution" => {
                    if let Some(output) = item
                        .get("aggregatedOutput")
                        .and_then(Value::as_str)
                        .filter(|output| !output.is_empty())
                    {
                        emit(
                            request,
                            TaskStatus::Running,
                            Some("Codex completed a command".to_owned()),
                            Some((TaskOutputKind::Tool, output.to_owned())),
                            None,
                        )?;
                    } else if item.get("status").and_then(Value::as_str) != Some("completed") {
                        emit(
                            request,
                            TaskStatus::Running,
                            Some("Codex command did not complete".to_owned()),
                            Some((TaskOutputKind::Tool, serde_json::to_string(item)?)),
                            None,
                        )?;
                    }
                }
                "fileChange" => {
                    emit(
                        request,
                        TaskStatus::Running,
                        Some("Codex changed files".to_owned()),
                        Some((
                            TaskOutputKind::Tool,
                            serde_json::to_string(&item["changes"])?,
                        )),
                        None,
                    )?;
                }
                "mcpToolCall" => {
                    emit(
                        request,
                        TaskStatus::Running,
                        Some("Codex called a tool".to_owned()),
                        Some((TaskOutputKind::Tool, serde_json::to_string(item)?)),
                        None,
                    )?;
                }
                "dynamicToolCall" => {
                    emit(
                        request,
                        TaskStatus::Running,
                        Some("Codex completed a client tool call".to_owned()),
                        Some((TaskOutputKind::Tool, serde_json::to_string(item)?)),
                        None,
                    )?;
                }
                _ => {}
            }
        }
        "error" => {
            if let Some(message) = params.pointer("/error/message").and_then(Value::as_str) {
                emit(
                    request,
                    TaskStatus::Running,
                    Some("Codex warning".to_owned()),
                    Some((TaskOutputKind::System, message.to_owned())),
                    None,
                )?;
            }
        }
        "turn/completed" => {
            let turn = &params["turn"];
            let status = turn
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("failed");
            return Ok(Some(match status {
                "completed" => TerminalResult {
                    status: TaskStatus::Completed,
                    message: "Codex completed".to_owned(),
                    error: None,
                },
                "interrupted" => TerminalResult {
                    status: TaskStatus::Failed,
                    message: "Codex turn was interrupted".to_owned(),
                    error: Some("Codex turn was interrupted".to_owned()),
                },
                _ => {
                    let message = turn
                        .pointer("/error/message")
                        .and_then(Value::as_str)
                        .unwrap_or("Codex turn failed")
                        .to_owned();
                    TerminalResult {
                        status: TaskStatus::Failed,
                        message: message.clone(),
                        error: Some(message),
                    }
                }
            }));
        }
        _ => {}
    }
    Ok(None)
}

fn send_message(stdin: &mut ChildStdin, value: &Value) -> Result<()> {
    serde_json::to_writer(&mut *stdin, value)
        .context("failed to encode Codex app-server message")?;
    stdin.write_all(b"\n")?;
    stdin.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn command_approval_preserves_available_decisions() {
        let interaction = command_approval(
            "7".to_owned(),
            &json!({
                "command": "touch /tmp/example",
                "availableDecisions": ["accept", "decline"]
            }),
        )
        .unwrap();

        assert_eq!(interaction.kind, AdapterInteractionKind::Approval);
        assert_eq!(
            interaction
                .actions
                .iter()
                .map(|action| action.value.as_str())
                .collect::<Vec<_>>(),
            vec!["accept", "decline"]
        );
    }

    #[test]
    fn user_input_maps_options_and_custom_answer() {
        let interaction = user_input(
            "8".to_owned(),
            &json!({
                "questions": [{
                    "id": "choice",
                    "question": "Choose one",
                    "isOther": true,
                    "options": [{ "label": "A", "description": "First" }]
                }]
            }),
        )
        .unwrap();

        assert_eq!(interaction.kind, AdapterInteractionKind::Input);
        assert!(interaction.questions[0].allow_custom);
        assert_eq!(interaction.questions[0].options[0].value, "A");
    }

    #[test]
    fn user_input_response_uses_app_server_answer_shape() {
        let result = response_payload(
            "item/tool/requestUserInput",
            AdapterInteractionResponse {
                interaction_id: "8".to_owned(),
                action: None,
                answers: BTreeMap::from([("choice".to_owned(), vec!["A".to_owned()])]),
            },
        )
        .unwrap();

        assert_eq!(result["answers"]["choice"]["answers"][0], json!("A"));
    }
}
