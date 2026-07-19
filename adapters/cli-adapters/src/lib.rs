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

/// Manifest rules shared by the built-in spec-driven runtimes (generic, acp).
/// Each runtime binary remains the single authority for its own spec section;
/// the requirement, option and placeholder rules below are identical across them.
pub mod spec {
    use std::collections::BTreeMap;
    use std::ffi::OsString;
    use std::path::{Path, PathBuf};

    use anyhow::{Result, bail};
    use serde::Deserialize;

    #[derive(Debug, Deserialize)]
    pub struct ManifestOption {
        pub key: String,
        #[serde(default)]
        pub values: Vec<String>,
        #[serde(default)]
        pub default: Option<String>,
    }

    #[derive(Debug, Deserialize)]
    pub struct ManifestRequirement {
        pub environment: String,
        #[serde(default)]
        pub candidates: Vec<String>,
    }

    pub fn validate_requirements(
        requirements: &[ManifestRequirement],
        command: &str,
    ) -> Result<()> {
        if requirements.len() > 15 {
            bail!("spec-driven adapters allow at most 15 requirements");
        }
        let mut environments = std::collections::BTreeSet::new();
        for requirement in requirements {
            if !requirement.environment.starts_with("RELAY_")
                || requirement.environment.len() > 64
                || !requirement
                    .environment
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
                || !environments.insert(requirement.environment.as_str())
            {
                bail!(
                    "manifest requirement environment is invalid: {}",
                    requirement.environment
                );
            }
            if requirement.candidates.is_empty()
                || requirement.candidates.len() > 16
                || requirement
                    .candidates
                    .iter()
                    .any(|candidate| candidate.is_empty() || candidate.len() > 1024)
            {
                bail!(
                    "manifest requirement candidates are invalid: {}",
                    requirement.environment
                );
            }
        }
        if !environments.contains(command) {
            bail!("spec command must match a requirement environment key: {command}");
        }
        Ok(())
    }

    pub fn validate_command_key(command: &str) -> Result<()> {
        if !command.starts_with("RELAY_")
            || !command
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
        {
            bail!("spec command must name a RELAY_ environment key: {command}");
        }
        Ok(())
    }

    pub fn validate_options(options: &[ManifestOption]) -> Result<()> {
        if options.len() > 8 {
            bail!("a manifest allows at most 8 options");
        }
        let mut keys = std::collections::BTreeSet::new();
        for option in options {
            if option.key.is_empty()
                || option.key.len() > 32
                || option.key.starts_with("relay")
                || !option.key.bytes().all(|byte| {
                    byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
                })
            {
                bail!("manifest option key is invalid: {}", option.key);
            }
            if !keys.insert(&option.key) {
                bail!("manifest option key is duplicated: {}", option.key);
            }
            if option.values.is_empty()
                || option.values.len() > 24
                || option.values.iter().any(|value| {
                    value.is_empty() || value.len() > 64 || value.chars().any(char::is_control)
                })
            {
                bail!("manifest option values are invalid: {}", option.key);
            }
            if let Some(default) = &option.default
                && !option.values.contains(default)
            {
                bail!(
                    "manifest option default is not among its values: {}",
                    option.key
                );
            }
        }
        Ok(())
    }

    pub fn resolve_options(
        options: &[ManifestOption],
        provided: &BTreeMap<String, String>,
    ) -> Vec<(String, String)> {
        options
            .iter()
            .map(|option| {
                let value = provided
                    .get(&option.key)
                    .or(option.default.as_ref())
                    .unwrap_or(&option.values[0])
                    .clone();
                (option.key.clone(), value)
            })
            .collect()
    }

    pub fn validate_argument_list(arguments: &[String]) -> Result<()> {
        if arguments.len() > 32 || arguments.iter().any(|argument| argument.len() > 512) {
            bail!("spec arguments are invalid");
        }
        Ok(())
    }

    pub fn validate_placeholders(
        argument: &str,
        options: &[ManifestOption],
        allow_session: bool,
    ) -> Result<()> {
        for token in placeholders(argument) {
            if token == "cwd" || (allow_session && token == "session") {
                continue;
            }
            if let Some(key) = token.strip_prefix("option:") {
                if options.iter().any(|option| option.key == key) {
                    continue;
                }
                bail!(
                    "placeholder {{{token}}} references an undeclared option in argument: {argument}"
                );
            }
            bail!("unknown placeholder {{{token}}} in argument: {argument}");
        }
        Ok(())
    }

    pub fn placeholders(value: &str) -> impl Iterator<Item = &str> {
        value.split('{').skip(1).filter_map(|part| {
            let token = part.split('}').next()?;
            (part.len() > token.len()
                && !token.is_empty()
                && token.bytes().all(|byte| {
                    byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || matches!(byte, b'_' | b'-' | b':')
                }))
            .then_some(token)
        })
    }

    pub fn substitute(
        argument: &str,
        session: &str,
        cwd: &Path,
        option_values: &[(String, String)],
    ) -> OsString {
        let mut result = String::with_capacity(argument.len());
        let mut rest = argument;
        'outer: while let Some(start) = rest.find('{') {
            let (head, tail) = rest.split_at(start);
            result.push_str(head);
            if let Some(after) = tail.strip_prefix("{session}") {
                result.push_str(session);
                rest = after;
                continue;
            }
            if let Some(after) = tail.strip_prefix("{cwd}") {
                result.push_str(&cwd.to_string_lossy());
                rest = after;
                continue;
            }
            for (key, value) in option_values {
                if let Some(after) = tail.strip_prefix(&format!("{{option:{key}}}")) {
                    result.push_str(value);
                    rest = after;
                    continue 'outer;
                }
            }
            result.push('{');
            rest = &tail[1..];
        }
        result.push_str(rest);
        OsString::from(result)
    }

    pub fn resolve_candidate(raw: &str, manifest_directory: &Path, home: &Path) -> PathBuf {
        if raw == "~" {
            return home.to_path_buf();
        }
        if let Some(rest) = raw.strip_prefix("~/") {
            return home.join(rest);
        }
        let path = Path::new(raw);
        if path.is_absolute() {
            return path.to_path_buf();
        }
        manifest_directory.join(path)
    }

    pub fn resolve_spec_command(
        command: &str,
        requirements: &[ManifestRequirement],
        spec_path: &Path,
    ) -> Result<PathBuf> {
        let manifest_directory = spec_path.parent().unwrap_or(Path::new("/"));
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_default();
        let candidates = requirements
            .iter()
            .find(|requirement| requirement.environment == command)
            .map(|requirement| {
                requirement
                    .candidates
                    .iter()
                    .map(|candidate| resolve_candidate(candidate, manifest_directory, &home))
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        super::resolve_cli(command, &candidates)
    }

    pub fn bounded_message(value: &str, max_bytes: usize) -> String {
        let trimmed = value.trim();
        if trimmed.len() <= max_bytes {
            return trimmed.to_owned();
        }
        let mut cut = max_bytes;
        while !trimmed.is_char_boundary(cut) {
            cut -= 1;
        }
        format!("{}…", &trimmed[..cut])
    }
}
