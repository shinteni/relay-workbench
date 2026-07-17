use std::ffi::OsString;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::mpsc;

use anyhow::{Context, Result, bail};
use relay_protocol::{
    AdapterEvent, AdapterInteraction, AdapterOutput, AdapterRunRequest, PROTOCOL_VERSION,
    TaskOutputKind, TaskStatus,
};

pub enum ChildLine {
    Stdout(String),
    Stderr(String),
}

pub fn read_request(expected_usage: &str) -> Result<AdapterRunRequest> {
    if std::env::args().skip(1).collect::<Vec<_>>().as_slice() != ["run"] {
        bail!("usage: {expected_usage} run");
    }
    let mut input = String::new();
    std::io::stdin()
        .lock()
        .read_line(&mut input)
        .context("failed to read adapter request")?;
    let request: AdapterRunRequest =
        serde_json::from_str(&input).context("failed to decode adapter request")?;
    if request.protocol_version != PROTOCOL_VERSION {
        bail!("unsupported protocol version: {}", request.protocol_version);
    }
    Ok(request)
}

pub fn resolve_cli(environment_key: &str, candidates: &[PathBuf]) -> Result<PathBuf> {
    let configured = std::env::var_os(environment_key).map(PathBuf::from);
    let path = configured
        .into_iter()
        .chain(candidates.iter().cloned())
        .find(|path| path.is_absolute() && path.is_file() && is_executable(path))
        .with_context(|| format!("{environment_key} does not point to an executable CLI"))?;
    Ok(path)
}

pub fn emit(
    request: &AdapterRunRequest,
    status: TaskStatus,
    message: Option<String>,
    output: Option<(TaskOutputKind, String)>,
    session_id: Option<String>,
) -> Result<()> {
    emit_event(AdapterEvent {
        task_id: request.task_id,
        status,
        message,
        output: output.map(|(kind, text)| AdapterOutput { kind, text }),
        session_id,
        interaction: None,
    })
}

pub fn emit_interaction(
    request: &AdapterRunRequest,
    status: TaskStatus,
    message: String,
    interaction: AdapterInteraction,
) -> Result<()> {
    emit_event(AdapterEvent {
        task_id: request.task_id,
        status,
        message: Some(message),
        output: None,
        session_id: None,
        interaction: Some(interaction),
    })
}

fn emit_event(event: AdapterEvent) -> Result<()> {
    let mut stdout = std::io::stdout().lock();
    serde_json::to_writer(&mut stdout, &event).context("failed to encode adapter event")?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;
    Ok(())
}

pub fn run_cli(
    executable: &Path,
    arguments: Vec<OsString>,
    cwd: &Path,
    prompt: &str,
    mut handle_line: impl FnMut(ChildLine) -> Result<()>,
) -> Result<ExitStatus> {
    let mut child = Command::new(executable)
        .args(arguments)
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to start {}", executable.display()))?;

    let mut stdin = child.stdin.take().context("CLI stdin is unavailable")?;
    stdin
        .write_all(prompt.as_bytes())
        .context("failed to write CLI prompt")?;
    stdin.write_all(b"\n")?;
    drop(stdin);

    let stdout = child.stdout.take().context("CLI stdout is unavailable")?;
    let stderr = child.stderr.take().context("CLI stderr is unavailable")?;
    let (sender, receiver) = mpsc::channel();
    let stdout_sender = sender.clone();
    let stdout_thread = std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if stdout_sender.send(ChildLine::Stdout(line)).is_err() {
                break;
            }
        }
    });
    let stderr_thread = std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if sender.send(ChildLine::Stderr(line)).is_err() {
                break;
            }
        }
    });

    for line in receiver {
        handle_line(line)?;
    }
    let _ = stdout_thread.join();
    let _ = stderr_thread.join();
    child.wait().context("failed to wait for CLI")
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}
