use std::collections::HashMap;
use std::ffi::OsString;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command, ExitCode, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use cli_adapters::spec::{
    ManifestOption, ManifestRequirement, bounded_message, resolve_options, resolve_spec_command,
    substitute, validate_argument_list, validate_command_key, validate_options,
    validate_placeholders, validate_requirements,
};
use cli_adapters::{emit, emit_interaction, read_request};
use relay_protocol::{
    AdapterInteraction, AdapterInteractionKind, AdapterInteractionOption,
    AdapterInteractionResponse, AdapterRunRequest, TaskOutputKind, TaskStatus,
};
use serde::Deserialize;
use serde_json::{Value, json};

const SPEC_ENVIRONMENT: &str = "RELAY_ACP_SPEC";
const ACP_PROTOCOL_VERSION: u64 = 1;
const MAX_PREVIEW_BYTES: usize = 200;
const MAX_TOOL_TEXT_BYTES: usize = 8 * 1024;
const MAX_INTERACTION_MESSAGE_BYTES: usize = 8 * 1024;
const MAX_ACTION_VALUE_BYTES: usize = 256;
const MAX_ACTION_LABEL_BYTES: usize = 256;
const MAX_ACTIONS: usize = 8;
const STARTUP_TIMEOUT: Duration = Duration::from_secs(60);
const IDLE_POLL_INTERVAL: Duration = Duration::from_secs(60);
const IDLE_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// After the turn ends the agent gets a short window to exit on stdin EOF so
/// it can flush session state (e.g. transcripts) before being killed.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

#[derive(Debug, PartialEq)]
enum Invocation {
    Run,
    Validate(PathBuf),
}

#[derive(Debug, Deserialize)]
struct AcpManifest {
    acp: AcpSpec,
    #[serde(default)]
    requirements: Vec<ManifestRequirement>,
    #[serde(default)]
    options: Vec<ManifestOption>,
}

#[derive(Debug, Deserialize)]
struct AcpSpec {
    command: String,
    #[serde(default)]
    arguments: Vec<String>,
}

enum ProcessEvent {
    Agent(String),
    AgentClosed,
    Stderr(String),
    Relay(String),
    RelayClosed,
}

/// A JSON-RPC error returned by the agent (as opposed to a transport failure).
#[derive(Debug)]
struct RpcError {
    code: i64,
    message: String,
}

impl RpcError {
    fn is_auth_required(&self) -> bool {
        self.code == -32000
    }
}

struct TerminalResult {
    status: TaskStatus,
    message: String,
    error: Option<String>,
    session_id: Option<String>,
}

/// Pure per-turn state: accumulated message/thought chunks and open tool calls.
#[derive(Default)]
struct TurnState {
    message: String,
    thought: String,
    tool_titles: HashMap<String, String>,
    last_reply: Option<String>,
}

type Emission = (TaskOutputKind, String);

fn main() -> ExitCode {
    match dispatch() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error:#}");
            ExitCode::FAILURE
        }
    }
}

fn dispatch() -> Result<()> {
    match parse_invocation(std::env::args_os().skip(1))? {
        Invocation::Run => run_task(),
        Invocation::Validate(path) => {
            load_manifest(&path)?;
            Ok(())
        }
    }
}

fn parse_invocation(arguments: impl IntoIterator<Item = OsString>) -> Result<Invocation> {
    let mut arguments = arguments.into_iter();
    let Some(command) = arguments.next() else {
        return Ok(Invocation::Run);
    };
    match command.to_str() {
        Some("run") if arguments.next().is_none() => Ok(Invocation::Run),
        Some("validate") => {
            let flag = arguments.next();
            let path = arguments.next();
            if flag.as_deref() != Some(std::ffi::OsStr::new("--spec"))
                || path.is_none()
                || arguments.next().is_some()
            {
                bail!("usage: acp-adapter validate --spec <absolute-path>");
            }
            Ok(Invocation::Validate(PathBuf::from(path.unwrap())))
        }
        _ => bail!("usage: acp-adapter [run | validate --spec <absolute-path>]"),
    }
}

fn load_manifest(path: &Path) -> Result<AcpManifest> {
    if !path.is_absolute() {
        bail!(
            "{SPEC_ENVIRONMENT} must be an absolute path: {}",
            path.display()
        );
    }
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read acp manifest {}", path.display()))?;
    let manifest: AcpManifest = serde_json::from_str(&content)
        .with_context(|| format!("failed to decode acp manifest {}", path.display()))?;
    validate_manifest(&manifest)?;
    Ok(manifest)
}

fn validate_manifest(manifest: &AcpManifest) -> Result<()> {
    validate_requirements(&manifest.requirements, &manifest.acp.command)?;
    validate_options(&manifest.options)?;
    validate_spec(&manifest.acp, &manifest.options)
}

fn validate_spec(spec: &AcpSpec, options: &[ManifestOption]) -> Result<()> {
    validate_command_key(&spec.command)?;
    validate_argument_list(&spec.arguments)?;
    for argument in &spec.arguments {
        validate_placeholders(argument, options, false)?;
    }
    Ok(())
}

fn build_arguments(
    spec: &AcpSpec,
    cwd: &Path,
    option_values: &[(String, String)],
) -> Vec<OsString> {
    spec.arguments
        .iter()
        .map(|argument| substitute(argument, "", cwd, option_values))
        .collect()
}

fn run_task() -> Result<()> {
    let request = read_request("acp-adapter")?;
    let spec_path = std::env::var_os(SPEC_ENVIRONMENT)
        .map(PathBuf::from)
        .with_context(|| format!("{SPEC_ENVIRONMENT} is not set"))?;
    let manifest = load_manifest(&spec_path)?;
    let cli = resolve_spec_command(&manifest.acp.command, &manifest.requirements, &spec_path)?;
    let command_name = cli
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| cli.display().to_string());
    let option_values = resolve_options(&manifest.options, &request.options);
    let arguments = build_arguments(&manifest.acp, &request.cwd, &option_values);

    emit(
        &request,
        TaskStatus::Starting,
        Some(format!("Starting {command_name} (ACP)")),
        None,
        request.session_id.clone(),
    )?;

    let mut child = Command::new(&cli)
        .args(arguments)
        .current_dir(&request.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to start {}", cli.display()))?;
    let mut agent_stdin = child.stdin.take().context("ACP agent stdin is unavailable")?;
    let agent_stdout = child
        .stdout
        .take()
        .context("ACP agent stdout is unavailable")?;
    let agent_stderr = child
        .stderr
        .take()
        .context("ACP agent stderr is unavailable")?;
    let (sender, receiver) = mpsc::channel();
    let stdout_sender = sender.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(agent_stdout).lines().map_while(Result::ok) {
            if stdout_sender.send(ProcessEvent::Agent(line)).is_err() {
                return;
            }
        }
        let _ = stdout_sender.send(ProcessEvent::AgentClosed);
    });
    let stderr_sender = sender.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(agent_stderr).lines().map_while(Result::ok) {
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

    let result = run_turn(&request, &command_name, &receiver, &mut agent_stdin);
    drop(agent_stdin);
    let terminal = match result {
        Ok(terminal) => terminal,
        Err(error) => TerminalResult {
            status: TaskStatus::Failed,
            message: format!("{error:#}"),
            error: Some(format!("{error:#}")),
            session_id: None,
        },
    };
    emit(
        &request,
        terminal.status,
        Some(terminal.message),
        terminal
            .error
            .map(|message| (TaskOutputKind::Error, message)),
        terminal.session_id,
    )?;
    let deadline = Instant::now() + SHUTDOWN_GRACE;
    while matches!(child.try_wait(), Ok(None)) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
    }
    let _ = child.kill();
    let _ = child.wait();
    Ok(())
}

fn run_turn(
    request: &AdapterRunRequest,
    command_name: &str,
    receiver: &Receiver<ProcessEvent>,
    agent_stdin: &mut ChildStdin,
) -> Result<TerminalResult> {
    let mut stderr_tail = String::new();

    send_message(agent_stdin, &initialize_request(1))?;
    let init = match wait_for_response(receiver, agent_stdin, 1, &mut stderr_tail)? {
        Ok(result) => result,
        Err(error) => bail!("ACP initialize failed: {}", error.message),
    };
    check_protocol_version(&init)?;
    let load_supported = init
        .pointer("/agentCapabilities/loadSession")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let auth_hint = auth_methods_hint(&init);

    let cwd = request.cwd.to_string_lossy().into_owned();
    let mut session_id = None;
    if let Some(existing) = &request.session_id {
        if load_supported {
            send_message(agent_stdin, &load_session_request(2, existing, &cwd))?;
            match wait_for_response(receiver, agent_stdin, 2, &mut stderr_tail)? {
                Ok(_) => session_id = Some(existing.clone()),
                Err(error) if error.is_auth_required() => bail!(auth_error(&auth_hint)),
                Err(error) => emit(
                    request,
                    TaskStatus::Running,
                    None,
                    Some((
                        TaskOutputKind::System,
                        format!(
                            "Previous ACP session could not be restored ({}); starting a new session",
                            error.message
                        ),
                    )),
                    None,
                )?,
            }
        } else {
            emit(
                request,
                TaskStatus::Running,
                None,
                Some((
                    TaskOutputKind::System,
                    "The agent does not support session restore; starting a new session".to_owned(),
                )),
                None,
            )?;
        }
    }
    let session_id = match session_id {
        Some(session_id) => session_id,
        None => {
            send_message(agent_stdin, &new_session_request(3, &cwd))?;
            match wait_for_response(receiver, agent_stdin, 3, &mut stderr_tail)? {
                Ok(result) => result
                    .get("sessionId")
                    .and_then(Value::as_str)
                    .context("ACP session/new response did not include a sessionId")?
                    .to_owned(),
                Err(error) if error.is_auth_required() => bail!(auth_error(&auth_hint)),
                Err(error) => bail!("ACP session/new failed: {}", error.message),
            }
        }
    };
    emit(
        request,
        TaskStatus::Running,
        Some("ACP session started".to_owned()),
        None,
        Some(session_id.clone()),
    )?;

    send_message(
        agent_stdin,
        &prompt_request(4, &session_id, &request.prompt),
    )?;
    emit(
        request,
        TaskStatus::Running,
        Some(format!("{command_name} is working")),
        None,
        None,
    )?;

    // While a permission gate is open, non-interaction events must not reach the
    // daemon: every applied event overwrites the task's pending interaction, so a
    // stray Running/output event would silently dismiss the gate the user still
    // has to answer. Output produced meanwhile is deferred and flushed after the
    // response; further permission requests queue until the current gate closes.
    let mut state = TurnState::default();
    let mut gate: Option<(String, Value)> = None;
    let mut queued_gates = std::collections::VecDeque::<(String, Value, AdapterInteraction)>::new();
    let mut deferred: Vec<Emission> = Vec::new();
    let mut last_activity = Instant::now();
    loop {
        let event = match receiver.recv_timeout(IDLE_POLL_INTERVAL) {
            Ok(event) => event,
            Err(RecvTimeoutError::Timeout) => {
                if gate.is_none()
                    && queued_gates.is_empty()
                    && last_activity.elapsed() >= IDLE_TIMEOUT
                {
                    bail!(
                        "The ACP agent produced no activity for {} minutes; treating it as hung. The session is preserved and can be continued.",
                        IDLE_TIMEOUT.as_secs() / 60
                    );
                }
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => bail!("ACP event stream closed"),
        };
        last_activity = Instant::now();
        match event {
            ProcessEvent::Agent(line) => {
                if line.trim().is_empty() {
                    continue;
                }
                let Ok(value) = serde_json::from_str::<Value>(&line) else {
                    sink(request, &gate, &mut deferred, (TaskOutputKind::System, line))?;
                    continue;
                };
                if value.get("method").is_some() && value.get("id").is_some() {
                    if let Some((interaction_id, rpc_id, interaction)) =
                        handle_agent_request(request, agent_stdin, &mut state, &gate, &mut deferred, &value)?
                    {
                        if gate.is_none() {
                            gate = Some((interaction_id, rpc_id));
                            emit_interaction(
                                request,
                                TaskStatus::WaitingForApproval,
                                "The ACP agent is waiting for your approval".to_owned(),
                                interaction,
                            )?;
                        } else {
                            queued_gates.push_back((interaction_id, rpc_id, interaction));
                        }
                    }
                } else if value.get("method").is_some() {
                    if let Some(update) = session_update(&value, &session_id) {
                        for emission in apply_update(&mut state, update) {
                            sink(request, &gate, &mut deferred, emission)?;
                        }
                    }
                } else if response_id(&value) == Some(4) {
                    for emission in deferred.drain(..) {
                        emit_output(request, emission)?;
                    }
                    for emission in flush(&mut state) {
                        emit_output(request, emission)?;
                    }
                    return Ok(turn_terminal(
                        &value,
                        command_name,
                        state.last_reply.take(),
                        session_id,
                    ));
                }
            }
            ProcessEvent::Relay(line) => {
                if line.trim().is_empty() {
                    continue;
                }
                let response: AdapterInteractionResponse = serde_json::from_str(&line)
                    .context("failed to decode Relay interaction response")?;
                let rpc_id = match gate.take() {
                    Some((gate_id, rpc_id)) if gate_id == response.interaction_id => rpc_id,
                    _ => bail!("Relay responded to an unknown ACP interaction"),
                };
                send_message(
                    agent_stdin,
                    &json!({
                        "jsonrpc": "2.0",
                        "id": rpc_id,
                        "result": permission_response(&response),
                    }),
                )?;
                emit(
                    request,
                    TaskStatus::Running,
                    Some(format!("{command_name} is continuing")),
                    None,
                    None,
                )?;
                for emission in deferred.drain(..) {
                    emit_output(request, emission)?;
                }
                for emission in flush(&mut state) {
                    emit_output(request, emission)?;
                }
                if let Some((interaction_id, rpc_id, interaction)) = queued_gates.pop_front() {
                    gate = Some((interaction_id, rpc_id));
                    emit_interaction(
                        request,
                        TaskStatus::WaitingForApproval,
                        "The ACP agent is waiting for your approval".to_owned(),
                        interaction,
                    )?;
                }
            }
            ProcessEvent::Stderr(line) => {
                if !line.trim().is_empty() {
                    stderr_tail = line;
                }
            }
            ProcessEvent::AgentClosed => {
                let message = if stderr_tail.is_empty() {
                    "The ACP agent closed unexpectedly".to_owned()
                } else {
                    stderr_tail
                };
                bail!(message);
            }
            ProcessEvent::RelayClosed => bail!("Relay closed the interaction channel"),
        }
    }
}

fn emit_output(request: &AdapterRunRequest, emission: Emission) -> Result<()> {
    emit(request, TaskStatus::Running, None, Some(emission), None)
}

/// Emits an output immediately, or defers it while a permission gate is open so
/// the daemon-side pending interaction is not overwritten.
fn sink(
    request: &AdapterRunRequest,
    gate: &Option<(String, Value)>,
    deferred: &mut Vec<Emission>,
    emission: Emission,
) -> Result<()> {
    if gate.is_some() {
        deferred.push(emission);
        Ok(())
    } else {
        emit_output(request, emission)
    }
}

fn initialize_request(id: i64) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": {
            "protocolVersion": ACP_PROTOCOL_VERSION,
            "clientInfo": {
                "name": "relay",
                "title": "Relay",
                "version": env!("CARGO_PKG_VERSION")
            },
            "clientCapabilities": {
                "fs": { "readTextFile": false, "writeTextFile": false },
                "terminal": false
            }
        }
    })
}

fn new_session_request(id: i64, cwd: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "session/new",
        "params": { "cwd": cwd, "mcpServers": [] }
    })
}

fn load_session_request(id: i64, session_id: &str, cwd: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "session/load",
        "params": { "sessionId": session_id, "cwd": cwd, "mcpServers": [] }
    })
}

fn prompt_request(id: i64, session_id: &str, prompt: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "session/prompt",
        "params": {
            "sessionId": session_id,
            "prompt": [{ "type": "text", "text": prompt }]
        }
    })
}

fn check_protocol_version(init: &Value) -> Result<()> {
    let version = init.get("protocolVersion").and_then(Value::as_u64);
    if version != Some(ACP_PROTOCOL_VERSION) {
        bail!(
            "the agent negotiated ACP protocol version {}; Relay supports version {ACP_PROTOCOL_VERSION}",
            init.get("protocolVersion").unwrap_or(&Value::Null)
        );
    }
    Ok(())
}

fn auth_methods_hint(init: &Value) -> String {
    init.get("authMethods")
        .and_then(Value::as_array)
        .map(|methods| {
            methods
                .iter()
                .filter_map(|method| {
                    method
                        .get("name")
                        .or_else(|| method.get("id"))
                        .and_then(Value::as_str)
                })
                .collect::<Vec<_>>()
                .join(", ")
        })
        .unwrap_or_default()
}

fn auth_error(auth_hint: &str) -> String {
    if auth_hint.is_empty() {
        "The ACP agent requires authentication; log in with the CLI first".to_owned()
    } else {
        format!(
            "The ACP agent requires authentication ({auth_hint}); log in with the CLI first"
        )
    }
}

fn response_id(value: &Value) -> Option<i64> {
    (value.get("result").is_some() || value.get("error").is_some())
        .then(|| value.get("id").and_then(Value::as_i64))
        .flatten()
}

/// JSON-RPC error text including `data.details`, where agents such as
/// claude-code-acp put the actionable cause behind a generic "Internal error".
fn rpc_error_text(error: &Value) -> String {
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("unknown ACP error");
    match error.pointer("/data/details").and_then(Value::as_str) {
        Some(details) if !details.trim().is_empty() && details != message => {
            format!("{message}: {details}")
        }
        _ => message.to_owned(),
    }
}

/// Extracts the update payload from a `session/update` notification for our session.
fn session_update<'a>(value: &'a Value, session_id: &str) -> Option<&'a Value> {
    if value.get("method").and_then(Value::as_str) != Some("session/update") {
        return None;
    }
    let params = value.get("params")?;
    if params.get("sessionId").and_then(Value::as_str) != Some(session_id) {
        return None;
    }
    params.get("update")
}

fn apply_update(state: &mut TurnState, update: &Value) -> Vec<Emission> {
    let kind = update
        .get("sessionUpdate")
        .and_then(Value::as_str)
        .unwrap_or_default();
    match kind {
        "agent_message_chunk" => {
            if let Some(text) = update.get("content").map(content_text) {
                state.message.push_str(&text);
            }
            Vec::new()
        }
        "agent_thought_chunk" => {
            if let Some(text) = update.get("content").map(content_text) {
                state.thought.push_str(&text);
            }
            Vec::new()
        }
        "tool_call" => {
            let mut emissions = flush(state);
            let title = update
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or("tool")
                .to_owned();
            if let Some(id) = update.get("toolCallId").and_then(Value::as_str) {
                state.tool_titles.insert(id.to_owned(), title.clone());
            }
            emissions.push((TaskOutputKind::Tool, format!("⚙ {title}")));
            emissions
        }
        "tool_call_update" => {
            let status = update
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if status != "completed" && status != "failed" {
                return Vec::new();
            }
            let mut emissions = flush(state);
            let title = update
                .get("title")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| {
                    update
                        .get("toolCallId")
                        .and_then(Value::as_str)
                        .and_then(|id| state.tool_titles.get(id).cloned())
                })
                .unwrap_or_else(|| "tool".to_owned());
            let mut text = format!("{title} — {status}");
            let content = tool_content_text(update.get("content"));
            if !content.is_empty() {
                text.push('\n');
                text.push_str(&bounded_message(&content, MAX_TOOL_TEXT_BYTES));
            }
            emissions.push((TaskOutputKind::Tool, text));
            emissions
        }
        _ => Vec::new(),
    }
}

/// Flushes accumulated chunks into output emissions at a message boundary.
fn flush(state: &mut TurnState) -> Vec<Emission> {
    let mut emissions = Vec::new();
    if !state.thought.trim().is_empty() {
        emissions.push((TaskOutputKind::System, state.thought.trim().to_owned()));
    }
    state.thought.clear();
    if !state.message.trim().is_empty() {
        state.last_reply = Some(bounded_message(&state.message, MAX_PREVIEW_BYTES));
        emissions.push((TaskOutputKind::Assistant, state.message.trim().to_owned()));
    }
    state.message.clear();
    emissions
}

fn content_text(block: &Value) -> String {
    match block.get("type").and_then(Value::as_str).unwrap_or_default() {
        "text" => block
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
        "image" => "[image]".to_owned(),
        "audio" => "[audio]".to_owned(),
        "resource_link" => format!(
            "[resource: {}]",
            block.get("uri").and_then(Value::as_str).unwrap_or("?")
        ),
        "resource" => block
            .pointer("/resource/text")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| {
                format!(
                    "[resource: {}]",
                    block
                        .pointer("/resource/uri")
                        .and_then(Value::as_str)
                        .unwrap_or("?")
                )
            }),
        other => format!("[{other}]"),
    }
}

fn tool_content_text(content: Option<&Value>) -> String {
    let Some(items) = content.and_then(Value::as_array) else {
        return String::new();
    };
    items
        .iter()
        .filter_map(|item| {
            match item.get("type").and_then(Value::as_str).unwrap_or_default() {
                "content" => item.get("content").map(content_text),
                "diff" => item
                    .get("path")
                    .and_then(Value::as_str)
                    .map(|path| format!("[diff: {path}]")),
                "terminal" => Some("[terminal output]".to_owned()),
                _ => None,
            }
        })
        .filter(|text| !text.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Handles a request coming from the agent. Unsupported methods are answered
/// with method-not-found immediately; a usable permission request is returned
/// to the caller, which decides whether to open the gate now or queue it.
fn handle_agent_request(
    request: &AdapterRunRequest,
    agent_stdin: &mut ChildStdin,
    state: &mut TurnState,
    gate: &Option<(String, Value)>,
    deferred: &mut Vec<Emission>,
    value: &Value,
) -> Result<Option<(String, Value, AdapterInteraction)>> {
    let method = value
        .get("method")
        .and_then(Value::as_str)
        .context("ACP agent request did not include a method")?;
    let rpc_id = value
        .get("id")
        .cloned()
        .context("ACP agent request did not include an ID")?;
    if method != "session/request_permission" {
        send_message(
            agent_stdin,
            &json!({
                "jsonrpc": "2.0",
                "id": rpc_id,
                "error": { "code": -32601, "message": "Relay does not support this ACP request" }
            }),
        )?;
        return Ok(None);
    }
    let params = value.get("params").unwrap_or(&Value::Null);
    let interaction_id = serde_json::to_string(&rpc_id)?;
    match permission_interaction(interaction_id.clone(), params) {
        Ok(interaction) => {
            for emission in flush(state) {
                sink(request, gate, deferred, emission)?;
            }
            Ok(Some((interaction_id, rpc_id, interaction)))
        }
        Err(error) => {
            send_message(
                agent_stdin,
                &json!({
                    "jsonrpc": "2.0",
                    "id": rpc_id,
                    "result": { "outcome": { "outcome": "cancelled" } }
                }),
            )?;
            sink(
                request,
                gate,
                deferred,
                (
                    TaskOutputKind::System,
                    format!("Cancelled an unusable ACP permission request: {error:#}"),
                ),
            )?;
            Ok(None)
        }
    }
}

fn permission_interaction(id: String, params: &Value) -> Result<AdapterInteraction> {
    if id.len() > MAX_ACTION_VALUE_BYTES {
        bail!("ACP permission request ID is too long");
    }
    let options = params
        .get("options")
        .and_then(Value::as_array)
        .filter(|options| !options.is_empty())
        .context("ACP permission request did not include options")?;
    let actions = options
        .iter()
        .take(MAX_ACTIONS)
        .map(|option| {
            let value = option
                .get("optionId")
                .and_then(Value::as_str)
                .context("ACP permission option did not include an optionId")?;
            if value.is_empty() || value.len() > MAX_ACTION_VALUE_BYTES {
                bail!("ACP permission optionId is invalid");
            }
            let label = option
                .get("name")
                .and_then(Value::as_str)
                .filter(|name| !name.trim().is_empty())
                .unwrap_or(value);
            Ok(AdapterInteractionOption {
                value: value.to_owned(),
                label: bounded_message(label, MAX_ACTION_LABEL_BYTES),
                description: option
                    .get("kind")
                    .and_then(Value::as_str)
                    .and_then(permission_kind_description)
                    .map(str::to_owned),
            })
        })
        .collect::<Result<Vec<_>>>()?;
    let tool_call = params.get("toolCall").unwrap_or(&Value::Null);
    let mut lines = Vec::new();
    if let Some(title) = tool_call.get("title").and_then(Value::as_str) {
        lines.push(title.to_owned());
    }
    if let Some(kind) = tool_call.get("kind").and_then(Value::as_str) {
        lines.push(format!("kind: {kind}"));
    }
    if let Some(locations) = tool_call.get("locations").and_then(Value::as_array) {
        for location in locations.iter().take(5) {
            if let Some(path) = location.get("path").and_then(Value::as_str) {
                lines.push(format!("path: {path}"));
            }
        }
    }
    Ok(AdapterInteraction {
        id,
        kind: AdapterInteractionKind::Approval,
        title: "Tool approval".to_owned(),
        message: if lines.is_empty() {
            "The agent wants to run a tool.".to_owned()
        } else {
            bounded_message(&lines.join("\n"), MAX_INTERACTION_MESSAGE_BYTES)
        },
        actions,
        questions: Vec::new(),
    })
}

fn permission_kind_description(kind: &str) -> Option<&'static str> {
    match kind {
        "allow_once" => Some("Allow this call once."),
        "allow_always" => Some("Allow this and future matching calls."),
        "reject_once" => Some("Reject this call."),
        "reject_always" => Some("Reject this and future matching calls."),
        _ => None,
    }
}

fn permission_response(response: &AdapterInteractionResponse) -> Value {
    match response.action.as_deref().filter(|action| !action.is_empty()) {
        Some(action) => json!({
            "outcome": { "outcome": "selected", "optionId": action }
        }),
        None => json!({ "outcome": { "outcome": "cancelled" } }),
    }
}

fn turn_terminal(
    value: &Value,
    command_name: &str,
    last_reply: Option<String>,
    session_id: String,
) -> TerminalResult {
    if let Some(error) = value.get("error") {
        let message = rpc_error_text(error);
        return TerminalResult {
            status: TaskStatus::Failed,
            message: message.clone(),
            error: Some(message),
            session_id: Some(session_id),
        };
    }
    let stop_reason = value
        .pointer("/result/stopReason")
        .and_then(Value::as_str)
        .unwrap_or_default();
    match stop_reason {
        "end_turn" => TerminalResult {
            status: TaskStatus::Completed,
            message: last_reply.unwrap_or_else(|| format!("{command_name} completed")),
            error: None,
            session_id: Some(session_id),
        },
        "max_tokens" => TerminalResult {
            status: TaskStatus::Completed,
            message: format!("{command_name} stopped at the model token limit"),
            error: None,
            session_id: Some(session_id),
        },
        "max_turn_requests" => TerminalResult {
            status: TaskStatus::Completed,
            message: format!("{command_name} reached the turn request limit"),
            error: None,
            session_id: Some(session_id),
        },
        "refusal" => TerminalResult {
            status: TaskStatus::Failed,
            message: "The agent refused to continue".to_owned(),
            error: Some("The agent refused to continue".to_owned()),
            session_id: Some(session_id),
        },
        "cancelled" => TerminalResult {
            status: TaskStatus::Failed,
            message: "The agent cancelled the turn".to_owned(),
            error: Some("The agent cancelled the turn".to_owned()),
            session_id: Some(session_id),
        },
        other => TerminalResult {
            status: TaskStatus::Completed,
            message: format!("{command_name} stopped: {other}"),
            error: None,
            session_id: Some(session_id),
        },
    }
}

/// Waits for the response to `expected_id`, answering unrelated agent requests
/// with method-not-found so the agent cannot deadlock during startup or load.
fn wait_for_response(
    receiver: &Receiver<ProcessEvent>,
    agent_stdin: &mut ChildStdin,
    expected_id: i64,
    stderr_tail: &mut String,
) -> Result<std::result::Result<Value, RpcError>> {
    loop {
        match receiver.recv_timeout(STARTUP_TIMEOUT) {
            Err(RecvTimeoutError::Timeout) => {
                bail!("the ACP agent did not answer within {}s", STARTUP_TIMEOUT.as_secs())
            }
            Err(RecvTimeoutError::Disconnected) => bail!("ACP event stream closed"),
            Ok(event) => match event {
                ProcessEvent::Agent(line) => {
                    if line.trim().is_empty() {
                        continue;
                    }
                    let Ok(value) = serde_json::from_str::<Value>(&line) else {
                        continue;
                    };
                    if value.get("method").is_some() && value.get("id").is_some() {
                        send_message(
                            agent_stdin,
                            &json!({
                                "jsonrpc": "2.0",
                                "id": value["id"],
                                "error": { "code": -32601, "message": "Relay does not support this ACP request" }
                            }),
                        )?;
                        continue;
                    }
                    if response_id(&value) != Some(expected_id) {
                        continue;
                    }
                    if let Some(error) = value.get("error") {
                        return Ok(Err(RpcError {
                            code: error.get("code").and_then(Value::as_i64).unwrap_or_default(),
                            message: rpc_error_text(error),
                        }));
                    }
                    return Ok(Ok(value.get("result").cloned().unwrap_or(Value::Null)));
                }
                ProcessEvent::Stderr(line) => {
                    if !line.trim().is_empty() {
                        *stderr_tail = line;
                    }
                }
                ProcessEvent::AgentClosed => {
                    if stderr_tail.is_empty() {
                        bail!("the ACP agent closed during startup");
                    }
                    bail!(stderr_tail.clone());
                }
                ProcessEvent::Relay(_) => {
                    bail!("Relay sent a response before the agent requested input")
                }
                ProcessEvent::RelayClosed => bail!("Relay closed the interaction channel"),
            },
        }
    }
}

fn send_message(stdin: &mut ChildStdin, value: &Value) -> Result<()> {
    serde_json::to_writer(&mut *stdin, value).context("failed to encode ACP message")?;
    stdin.write_all(b"\n")?;
    stdin.flush()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn spec(arguments: Vec<&str>) -> AcpSpec {
        AcpSpec {
            command: "RELAY_EXAMPLE_PATH".to_owned(),
            arguments: arguments.into_iter().map(str::to_owned).collect(),
        }
    }

    fn requirement(environment: &str) -> ManifestRequirement {
        ManifestRequirement {
            environment: environment.to_owned(),
            candidates: vec!["/bin/cat".to_owned()],
        }
    }

    fn option(key: &str, values: Vec<&str>) -> ManifestOption {
        ManifestOption {
            key: key.to_owned(),
            values: values.into_iter().map(str::to_owned).collect(),
            default: None,
        }
    }

    #[test]
    fn parses_run_and_validation_invocations() {
        assert_eq!(parse_invocation(Vec::new()).unwrap(), Invocation::Run);
        assert_eq!(
            parse_invocation([OsString::from("run")]).unwrap(),
            Invocation::Run
        );
        assert_eq!(
            parse_invocation([
                OsString::from("validate"),
                OsString::from("--spec"),
                OsString::from("/tmp/example.json"),
            ])
            .unwrap(),
            Invocation::Validate(PathBuf::from("/tmp/example.json"))
        );
        assert!(parse_invocation([OsString::from("validate")]).is_err());
    }

    #[test]
    fn manifest_parses_acp_section_and_ignores_other_fields() {
        let manifest: AcpManifest = serde_json::from_str(
            r#"{
                "schema_version": 1,
                "id": "example",
                "name": "Example",
                "capabilities": ["session_resume"],
                "acp": {"command": "RELAY_EXAMPLE_PATH", "arguments": ["--acp"]},
                "requirements": [
                    {"name": "Example", "environment": "RELAY_EXAMPLE_PATH", "candidates": ["bin/example"]}
                ]
            }"#,
        )
        .unwrap();
        assert_eq!(manifest.acp.command, "RELAY_EXAMPLE_PATH");
        assert_eq!(manifest.acp.arguments, ["--acp"]);
    }

    #[test]
    fn manifest_requires_the_command_requirement() {
        let manifest = AcpManifest {
            acp: spec(vec!["--acp"]),
            requirements: vec![requirement("RELAY_OTHER_PATH")],
            options: Vec::new(),
        };
        assert!(validate_manifest(&manifest).is_err());

        let valid = AcpManifest {
            requirements: vec![requirement("RELAY_EXAMPLE_PATH")],
            ..manifest
        };
        assert!(validate_manifest(&valid).is_ok());
    }

    #[test]
    fn session_placeholder_is_rejected_in_acp_arguments() {
        assert!(validate_spec(&spec(vec!["--resume", "{session}"]), &[]).is_err());
        assert!(validate_spec(&spec(vec!["--dir", "{cwd}"]), &[]).is_ok());
    }

    #[test]
    fn option_placeholders_require_declared_options() {
        let with_option = spec(vec!["--model", "{option:model}"]);
        assert!(validate_spec(&with_option, &[]).is_err());
        assert!(validate_spec(&with_option, &[option("model", vec!["fast"])]).is_ok());
    }

    #[test]
    fn argument_bounds_are_enforced() {
        assert!(validate_spec(&spec(vec![&"x".repeat(513)]), &[]).is_err());
        let many: Vec<String> = (0..33).map(|index| index.to_string()).collect();
        let too_many = AcpSpec {
            command: "RELAY_EXAMPLE_PATH".to_owned(),
            arguments: many,
        };
        assert!(validate_spec(&too_many, &[]).is_err());
    }

    #[test]
    fn arguments_substitute_cwd_and_options() {
        let spec = spec(vec!["--acp", "--dir", "{cwd}", "--model", "{option:model}"]);
        let arguments = build_arguments(
            &spec,
            Path::new("/tmp/project"),
            &[("model".to_owned(), "fast".to_owned())],
        );
        assert_eq!(
            arguments,
            ["--acp", "--dir", "/tmp/project", "--model", "fast"].map(OsString::from)
        );
    }

    #[test]
    fn initialize_request_declares_no_fs_or_terminal_capabilities() {
        let request = initialize_request(1);
        assert_eq!(request["method"], json!("initialize"));
        assert_eq!(request["params"]["protocolVersion"], json!(1));
        assert_eq!(
            request["params"]["clientCapabilities"]["fs"]["readTextFile"],
            json!(false)
        );
        assert_eq!(
            request["params"]["clientCapabilities"]["fs"]["writeTextFile"],
            json!(false)
        );
        assert_eq!(
            request["params"]["clientCapabilities"]["terminal"],
            json!(false)
        );
    }

    #[test]
    fn protocol_version_must_match() {
        assert!(check_protocol_version(&json!({"protocolVersion": 1})).is_ok());
        assert!(check_protocol_version(&json!({"protocolVersion": 2})).is_err());
        assert!(check_protocol_version(&json!({})).is_err());
    }

    #[test]
    fn session_requests_use_acp_shapes() {
        let new_session = new_session_request(3, "/tmp/project");
        assert_eq!(new_session["method"], json!("session/new"));
        assert_eq!(new_session["params"]["cwd"], json!("/tmp/project"));
        assert_eq!(new_session["params"]["mcpServers"], json!([]));

        let load = load_session_request(2, "session-1", "/tmp/project");
        assert_eq!(load["method"], json!("session/load"));
        assert_eq!(load["params"]["sessionId"], json!("session-1"));

        let prompt = prompt_request(4, "session-1", "hello");
        assert_eq!(prompt["method"], json!("session/prompt"));
        assert_eq!(
            prompt["params"]["prompt"],
            json!([{ "type": "text", "text": "hello" }])
        );
    }

    #[test]
    fn content_blocks_map_to_text() {
        assert_eq!(content_text(&json!({"type": "text", "text": "你好"})), "你好");
        assert_eq!(content_text(&json!({"type": "image", "data": "…"})), "[image]");
        assert_eq!(
            content_text(&json!({"type": "resource_link", "uri": "file:///a.rs"})),
            "[resource: file:///a.rs]"
        );
        assert_eq!(
            content_text(&json!({"type": "resource", "resource": {"uri": "u", "text": "body"}})),
            "body"
        );
        assert_eq!(content_text(&json!({"type": "unknown_block"})), "[unknown_block]");
    }

    #[test]
    fn message_chunks_accumulate_and_flush_on_tool_call() {
        let mut state = TurnState::default();
        assert!(
            apply_update(
                &mut state,
                &json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "第一"}})
            )
            .is_empty()
        );
        assert!(
            apply_update(
                &mut state,
                &json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "段"}})
            )
            .is_empty()
        );
        let emissions = apply_update(
            &mut state,
            &json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read file"}),
        );
        assert_eq!(
            emissions,
            vec![
                (TaskOutputKind::Assistant, "第一段".to_owned()),
                (TaskOutputKind::Tool, "⚙ Read file".to_owned()),
            ]
        );
        assert_eq!(state.last_reply.as_deref(), Some("第一段"));
        assert!(state.message.is_empty());
    }

    #[test]
    fn thought_chunks_flush_as_system_output() {
        let mut state = TurnState::default();
        apply_update(
            &mut state,
            &json!({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "thinking"}}),
        );
        let emissions = flush(&mut state);
        assert_eq!(emissions, vec![(TaskOutputKind::System, "thinking".to_owned())]);
        assert!(flush(&mut state).is_empty());
    }

    #[test]
    fn tool_call_updates_emit_only_on_terminal_status() {
        let mut state = TurnState::default();
        apply_update(
            &mut state,
            &json!({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Search"}),
        );
        assert!(
            apply_update(
                &mut state,
                &json!({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "in_progress"})
            )
            .is_empty()
        );
        let emissions = apply_update(
            &mut state,
            &json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": "t1",
                "status": "completed",
                "content": [{"type": "content", "content": {"type": "text", "text": "result body"}}]
            }),
        );
        assert_eq!(
            emissions,
            vec![(TaskOutputKind::Tool, "Search — completed\nresult body".to_owned())]
        );
    }

    #[test]
    fn replayed_and_unknown_updates_are_ignored() {
        let mut state = TurnState::default();
        assert!(
            apply_update(
                &mut state,
                &json!({"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": "old"}})
            )
            .is_empty()
        );
        assert!(
            apply_update(&mut state, &json!({"sessionUpdate": "plan", "entries": []})).is_empty()
        );
        assert!(flush(&mut state).is_empty());
    }

    #[test]
    fn session_update_filters_method_and_session() {
        let notification = json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {"sessionId": "s1", "update": {"sessionUpdate": "plan"}}
        });
        assert!(session_update(&notification, "s1").is_some());
        assert!(session_update(&notification, "s2").is_none());
        let other = json!({"jsonrpc": "2.0", "method": "session/other", "params": {}});
        assert!(session_update(&other, "s1").is_none());
    }

    #[test]
    fn permission_options_become_bounded_actions() {
        let interaction = permission_interaction(
            "9".to_owned(),
            &json!({
                "toolCall": {"title": "Run ls", "kind": "execute", "locations": [{"path": "/tmp"}]},
                "options": [
                    {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
                    {"optionId": "weird", "name": "", "kind": "custom_kind"}
                ]
            }),
        )
        .unwrap();
        assert_eq!(interaction.kind, AdapterInteractionKind::Approval);
        assert!(interaction.message.contains("Run ls"));
        assert!(interaction.message.contains("path: /tmp"));
        assert_eq!(
            interaction
                .actions
                .iter()
                .map(|action| action.value.as_str())
                .collect::<Vec<_>>(),
            vec!["allow", "reject", "weird"]
        );
        assert_eq!(interaction.actions[0].description.as_deref(), Some("Allow this call once."));
        assert_eq!(interaction.actions[2].label, "weird");
        assert_eq!(interaction.actions[2].description, None);
    }

    #[test]
    fn permission_actions_are_capped_and_empty_options_rejected() {
        let options: Vec<Value> = (0..12)
            .map(|index| json!({"optionId": format!("o{index}"), "name": format!("O {index}")}))
            .collect();
        let interaction = permission_interaction(
            "9".to_owned(),
            &json!({"toolCall": {}, "options": options}),
        )
        .unwrap();
        assert_eq!(interaction.actions.len(), MAX_ACTIONS);
        assert!(permission_interaction("9".to_owned(), &json!({"options": []})).is_err());
        assert!(permission_interaction("9".to_owned(), &json!({})).is_err());
    }

    #[test]
    fn permission_responses_use_acp_outcomes() {
        let selected = permission_response(&AdapterInteractionResponse {
            interaction_id: "9".to_owned(),
            action: Some("allow".to_owned()),
            answers: BTreeMap::new(),
        });
        assert_eq!(
            selected,
            json!({"outcome": {"outcome": "selected", "optionId": "allow"}})
        );
        let cancelled = permission_response(&AdapterInteractionResponse {
            interaction_id: "9".to_owned(),
            action: None,
            answers: BTreeMap::new(),
        });
        assert_eq!(cancelled, json!({"outcome": {"outcome": "cancelled"}}));
    }

    #[test]
    fn stop_reasons_map_to_terminal_statuses() {
        let terminal = |reason: &str| {
            turn_terminal(
                &json!({"id": 4, "result": {"stopReason": reason}}),
                "agent",
                Some("final".to_owned()),
                "s1".to_owned(),
            )
        };
        assert_eq!(terminal("end_turn").status, TaskStatus::Completed);
        assert_eq!(terminal("end_turn").message, "final");
        assert_eq!(terminal("max_tokens").status, TaskStatus::Completed);
        assert_eq!(terminal("refusal").status, TaskStatus::Failed);
        assert_eq!(terminal("cancelled").status, TaskStatus::Failed);
        let unknown = terminal("compaction");
        assert_eq!(unknown.status, TaskStatus::Completed);
        assert!(unknown.message.contains("compaction"));
        assert_eq!(unknown.session_id.as_deref(), Some("s1"));
    }

    #[test]
    fn prompt_errors_fail_the_turn() {
        let terminal = turn_terminal(
            &json!({"id": 4, "error": {"code": -32603, "message": "boom"}}),
            "agent",
            None,
            "s1".to_owned(),
        );
        assert_eq!(terminal.status, TaskStatus::Failed);
        assert_eq!(terminal.message, "boom");
        assert_eq!(terminal.session_id.as_deref(), Some("s1"));
    }

    #[test]
    fn rpc_error_details_are_surfaced() {
        assert_eq!(
            rpc_error_text(&json!({
                "code": -32603,
                "message": "Internal error",
                "data": {"details": "Query closed before response received"}
            })),
            "Internal error: Query closed before response received"
        );
        assert_eq!(rpc_error_text(&json!({"message": "plain"})), "plain");
        assert_eq!(
            rpc_error_text(&json!({"message": "same", "data": {"details": "same"}})),
            "same"
        );
        assert_eq!(rpc_error_text(&json!({})), "unknown ACP error");

        let terminal = turn_terminal(
            &json!({"id": 4, "error": {"message": "Internal error", "data": {"details": "root cause"}}}),
            "agent",
            None,
            "s1".to_owned(),
        );
        assert_eq!(terminal.message, "Internal error: root cause");
    }

    #[test]
    fn auth_hint_lists_method_names() {
        let init = json!({"authMethods": [
            {"id": "oauth", "name": "Log in with Google"},
            {"id": "api-key"}
        ]});
        assert_eq!(auth_methods_hint(&init), "Log in with Google, api-key");
        assert!(auth_error("").contains("requires authentication"));
        assert!(auth_error("X").contains("(X)"));
        assert!(
            RpcError { code: -32000, message: String::new() }.is_auth_required()
        );
    }

    #[test]
    fn response_ids_require_result_or_error() {
        assert_eq!(response_id(&json!({"id": 4, "result": {}})), Some(4));
        assert_eq!(response_id(&json!({"id": 4, "error": {}})), Some(4));
        assert_eq!(response_id(&json!({"id": 4})), None);
        assert_eq!(response_id(&json!({"method": "x", "id": 4, "result": {}})), Some(4));
    }
}
