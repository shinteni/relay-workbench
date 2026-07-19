//! A scriptable ACP agent used to exercise the acp-adapter without a real CLI.
//!
//! Speaks newline-delimited JSON-RPC 2.0 on stdio. Prompt text selects the
//! scenario: `PERMISSION` raises a permission request, `TOOL` streams a tool
//! call, `REFUSE` stops with a refusal, `FSREQ` issues an unsupported client
//! request first; anything else echoes the prompt back in two message chunks.

use std::io::{BufRead, Lines, StdinLock, Write};

use serde_json::{Value, json};

const SESSION_ID: &str = "mock-acp-session";

fn main() {
    if let Err(error) = run() {
        eprintln!("mock-acp-agent: {error}");
        std::process::exit(1);
    }
}

fn run() -> std::io::Result<()> {
    let stdin = std::io::stdin();
    let mut lines = stdin.lock().lines();
    let mut resumed = false;
    while let Some(line) = lines.next() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let method = value.get("method").and_then(Value::as_str).unwrap_or_default();
        let id = value.get("id").cloned();
        match method {
            "initialize" => send_response(
                id,
                json!({
                    "protocolVersion": 1,
                    "agentCapabilities": { "loadSession": true },
                    "authMethods": []
                }),
            )?,
            "session/new" => send_response(id, json!({ "sessionId": SESSION_ID }))?,
            "session/load" => {
                let session = value
                    .pointer("/params/sessionId")
                    .and_then(Value::as_str)
                    .unwrap_or(SESSION_ID)
                    .to_owned();
                send_update(
                    &session,
                    json!({
                        "sessionUpdate": "user_message_chunk",
                        "content": { "type": "text", "text": "earlier prompt" }
                    }),
                )?;
                send_update(
                    &session,
                    json!({
                        "sessionUpdate": "agent_message_chunk",
                        "content": { "type": "text", "text": "earlier reply" }
                    }),
                )?;
                resumed = true;
                send_response(id, Value::Null)?;
            }
            "session/prompt" => {
                let session = value
                    .pointer("/params/sessionId")
                    .and_then(Value::as_str)
                    .unwrap_or(SESSION_ID)
                    .to_owned();
                let text = value
                    .pointer("/params/prompt/0/text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                if text.contains("REFUSE") {
                    send_response(id, json!({ "stopReason": "refusal" }))?;
                    continue;
                }
                if text.contains("FSREQ") {
                    send_line(&json!({
                        "jsonrpc": "2.0",
                        "id": 101,
                        "method": "fs/read_text_file",
                        "params": { "sessionId": session, "path": "/tmp/mock" }
                    }))?;
                    let reply = wait_for_id(&mut lines, 101)?;
                    let code = reply
                        .pointer("/error/code")
                        .and_then(Value::as_i64)
                        .unwrap_or_default();
                    send_message_chunk(&session, &format!("fs request answered with {code}"))?;
                    send_response(id, json!({ "stopReason": "end_turn" }))?;
                    continue;
                }
                if text.contains("PERMISSION_PARALLEL") {
                    send_permission_request(&session, 100)?;
                    send_update(
                        &session,
                        json!({
                            "sessionUpdate": "tool_call",
                            "toolCallId": "tool-p",
                            "title": "Parallel probe",
                            "kind": "read",
                            "status": "in_progress"
                        }),
                    )?;
                    send_message_chunk(&session, "parallel note while gate is open")?;
                    let reply = wait_for_id(&mut lines, 100)?;
                    let outcome = selected_option(&reply);
                    send_message_chunk(&session, &format!("permission outcome: {outcome}"))?;
                    send_response(id, json!({ "stopReason": "end_turn" }))?;
                    continue;
                }
                if text.contains("PERMISSION_DOUBLE") {
                    send_permission_request(&session, 100)?;
                    send_permission_request(&session, 102)?;
                    let first = selected_option(&wait_for_id(&mut lines, 100)?);
                    let second = selected_option(&wait_for_id(&mut lines, 102)?);
                    send_message_chunk(&session, &format!("permission outcomes: {first}+{second}"))?;
                    send_response(id, json!({ "stopReason": "end_turn" }))?;
                    continue;
                }
                if text.contains("PERMISSION") {
                    send_permission_request(&session, 100)?;
                    let reply = wait_for_id(&mut lines, 100)?;
                    let outcome = selected_option(&reply);
                    send_message_chunk(&session, &format!("permission outcome: {outcome}"))?;
                    send_response(id, json!({ "stopReason": "end_turn" }))?;
                    continue;
                }
                if text.contains("TOOL") {
                    send_update(
                        &session,
                        json!({
                            "sessionUpdate": "tool_call",
                            "toolCallId": "tool-1",
                            "title": "Read mock file",
                            "kind": "read",
                            "status": "in_progress"
                        }),
                    )?;
                    send_update(
                        &session,
                        json!({
                            "sessionUpdate": "tool_call_update",
                            "toolCallId": "tool-1",
                            "status": "completed",
                            "content": [{
                                "type": "content",
                                "content": { "type": "text", "text": "mock file body" }
                            }]
                        }),
                    )?;
                }
                send_update(
                    &session,
                    json!({
                        "sessionUpdate": "agent_thought_chunk",
                        "content": { "type": "text", "text": "mock thinking" }
                    }),
                )?;
                let prefix = if resumed { "resumed " } else { "" };
                send_message_chunk(&session, &format!("{prefix}echo: "))?;
                send_message_chunk(&session, &text)?;
                send_response(id, json!({ "stopReason": "end_turn" }))?;
            }
            _ if id.is_some() => send_line(&json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32601, "message": "mock-acp-agent does not support this method" }
            }))?,
            _ => {}
        }
    }
    Ok(())
}

fn send_permission_request(session: &str, id: i64) -> std::io::Result<()> {
    send_line(&json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "session/request_permission",
        "params": {
            "sessionId": session,
            "toolCall": {
                "toolCallId": format!("call-{id}"),
                "title": "touch /tmp/mock-acp",
                "kind": "execute",
                "locations": [{ "path": "/tmp/mock-acp" }]
            },
            "options": [
                { "optionId": "proceed-once", "name": "Proceed", "kind": "allow_once" },
                { "optionId": "halt", "name": "Halt", "kind": "reject_once" }
            ]
        }
    }))
}

fn selected_option(reply: &Value) -> String {
    reply
        .pointer("/result/outcome/optionId")
        .and_then(Value::as_str)
        .unwrap_or("cancelled")
        .to_owned()
}

fn wait_for_id(lines: &mut Lines<StdinLock>, expected: i64) -> std::io::Result<Value> {
    for line in lines.by_ref() {
        let line = line?;
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if value.get("id").and_then(Value::as_i64) == Some(expected)
            && (value.get("result").is_some() || value.get("error").is_some())
        {
            return Ok(value);
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::UnexpectedEof,
        "client closed before answering",
    ))
}

fn send_message_chunk(session: &str, text: &str) -> std::io::Result<()> {
    send_update(
        session,
        json!({
            "sessionUpdate": "agent_message_chunk",
            "content": { "type": "text", "text": text }
        }),
    )
}

fn send_update(session: &str, update: Value) -> std::io::Result<()> {
    send_line(&json!({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": { "sessionId": session, "update": update }
    }))
}

fn send_response(id: Option<Value>, result: Value) -> std::io::Result<()> {
    send_line(&json!({
        "jsonrpc": "2.0",
        "id": id.unwrap_or(Value::Null),
        "result": result
    }))
}

fn send_line(value: &Value) -> std::io::Result<()> {
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, value)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}
