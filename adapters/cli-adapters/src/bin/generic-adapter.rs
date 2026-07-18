use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use anyhow::{Context, Result, bail};
use cli_adapters::{ChildLine, emit, read_request, resolve_cli, run_cli};
use relay_protocol::{TaskOutputKind, TaskStatus};
use serde::Deserialize;

const SPEC_ENVIRONMENT: &str = "RELAY_GENERIC_SPEC";
const MAX_MESSAGE_BYTES: usize = 200;

#[derive(Debug, PartialEq)]
enum Invocation {
    Run,
    Validate(PathBuf),
}

#[derive(Debug, Deserialize)]
struct GenericManifest {
    generic: GenericSpec,
    #[serde(default)]
    requirements: Vec<GenericRequirement>,
    #[serde(default)]
    options: Vec<ManifestOption>,
}

#[derive(Debug, Deserialize)]
struct ManifestOption {
    key: String,
    #[serde(default)]
    values: Vec<String>,
    #[serde(default)]
    default: Option<String>,
}

#[derive(Debug, Deserialize)]
struct GenericSpec {
    command: String,
    #[serde(default)]
    arguments: Vec<String>,
    #[serde(default)]
    new_session_arguments: Vec<String>,
    #[serde(default)]
    resume_arguments: Option<Vec<String>>,
    #[serde(default)]
    output: Option<String>,
    #[serde(default)]
    text_paths: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct GenericRequirement {
    environment: String,
    #[serde(default)]
    candidates: Vec<String>,
}

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
                bail!("usage: generic-adapter validate --spec <absolute-path>");
            }
            Ok(Invocation::Validate(PathBuf::from(path.unwrap())))
        }
        _ => bail!("usage: generic-adapter [run | validate --spec <absolute-path>]"),
    }
}

fn run_task() -> Result<()> {
    let request = read_request("generic-adapter")?;
    let spec_path = std::env::var_os(SPEC_ENVIRONMENT)
        .map(PathBuf::from)
        .with_context(|| format!("{SPEC_ENVIRONMENT} is not set"))?;
    let manifest = load_manifest(&spec_path)?;
    let cli = resolve_command(&manifest, &spec_path)?;
    let command_name = cli
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| cli.display().to_string());

    let jsonl = manifest.generic.output.as_deref() == Some("jsonl");
    let supports_sessions = manifest.generic.resume_arguments.is_some();
    let resume = supports_sessions && request.session_id.is_some();
    let session_value = request
        .session_id
        .clone()
        .unwrap_or_else(|| request.task_id.to_string());
    let option_values = resolve_options(&manifest.options, &request.options);
    let arguments = build_arguments(
        &manifest.generic,
        resume,
        &session_value,
        &request.cwd,
        &option_values,
    );

    emit(
        &request,
        TaskStatus::Starting,
        Some(format!("Starting {command_name}")),
        None,
        None,
    )?;
    emit(
        &request,
        TaskStatus::Running,
        Some(format!("{command_name} is working")),
        None,
        None,
    )?;

    let mut last_reply = None;
    let mut stderr_tail = None;
    let status = run_cli(&cli, arguments, &request.cwd, &request.prompt, |line| {
        let classified = match line {
            ChildLine::Stdout(line) if jsonl => {
                match classify_jsonl_line(&line, &manifest.generic.text_paths) {
                    (TaskOutputKind::Assistant, text) if text.trim().is_empty() => None,
                    (TaskOutputKind::Assistant, text) => Some((TaskOutputKind::Assistant, text)),
                    (_, raw) => visible_text(&raw).map(|clean| (TaskOutputKind::System, clean)),
                }
            }
            ChildLine::Stdout(line) => {
                visible_text(&line).map(|clean| (TaskOutputKind::Assistant, clean))
            }
            ChildLine::Stderr(line) => {
                visible_text(&line).map(|clean| (TaskOutputKind::System, clean))
            }
        };
        let Some((kind, text)) = classified else {
            return Ok(());
        };
        if !text.trim().is_empty() {
            let bounded = bounded_message(&text);
            match kind {
                TaskOutputKind::Assistant => last_reply = Some(bounded),
                TaskOutputKind::System => stderr_tail = Some(bounded),
                _ => {}
            }
        }
        emit(
            &request,
            TaskStatus::Running,
            None,
            Some((kind, text)),
            None,
        )
    })?;

    if status.success() {
        let message = last_reply.unwrap_or_else(|| format!("{command_name} completed"));
        emit(
            &request,
            TaskStatus::Completed,
            Some(message),
            None,
            supports_sessions.then_some(session_value),
        )?;
    } else {
        let message = stderr_tail.unwrap_or_else(|| format!("{command_name} exited with {status}"));
        emit(
            &request,
            TaskStatus::Failed,
            Some(message.clone()),
            Some((TaskOutputKind::Error, message)),
            None,
        )?;
    }
    Ok(())
}

fn load_manifest(path: &Path) -> Result<GenericManifest> {
    if !path.is_absolute() {
        bail!(
            "{SPEC_ENVIRONMENT} must be an absolute path: {}",
            path.display()
        );
    }
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read generic manifest {}", path.display()))?;
    let manifest: GenericManifest = serde_json::from_str(&content)
        .with_context(|| format!("failed to decode generic manifest {}", path.display()))?;
    validate_manifest(&manifest)?;
    Ok(manifest)
}

fn validate_manifest(manifest: &GenericManifest) -> Result<()> {
    validate_requirements(&manifest.requirements, &manifest.generic.command)?;
    validate_options(&manifest.options)?;
    validate_spec(&manifest.generic, &manifest.options)
}

fn validate_requirements(requirements: &[GenericRequirement], command: &str) -> Result<()> {
    if requirements.len() > 15 {
        bail!("generic adapters allow at most 15 requirements");
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
                "generic requirement environment is invalid: {}",
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
                "generic requirement candidates are invalid: {}",
                requirement.environment
            );
        }
    }
    if !environments.contains(command) {
        bail!("generic command must match a requirement environment key: {command}");
    }
    Ok(())
}

fn validate_options(options: &[ManifestOption]) -> Result<()> {
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

fn resolve_options(
    options: &[ManifestOption],
    provided: &std::collections::BTreeMap<String, String>,
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

fn validate_spec(spec: &GenericSpec, options: &[ManifestOption]) -> Result<()> {
    if !spec.command.starts_with("RELAY_")
        || !spec
            .command
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
    {
        bail!(
            "generic command must name a RELAY_ environment key: {}",
            spec.command
        );
    }
    match spec.output.as_deref() {
        None | Some("text") => {
            if !spec.text_paths.is_empty() {
                bail!("text_paths is only supported with the jsonl output mode");
            }
        }
        Some("jsonl") => {
            if spec.text_paths.is_empty() || spec.text_paths.len() > 8 {
                bail!("jsonl output requires between 1 and 8 text_paths");
            }
            for path in &spec.text_paths {
                if path.is_empty()
                    || path.len() > 128
                    || !path.bytes().all(|byte| {
                        byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-')
                    })
                {
                    bail!("jsonl text path is invalid: {path}");
                }
            }
        }
        Some(mode) => bail!("unsupported generic output mode: {mode}"),
    }
    let argument_lists = [
        spec.arguments.as_slice(),
        spec.new_session_arguments.as_slice(),
        spec.resume_arguments.as_deref().unwrap_or_default(),
    ];
    for arguments in argument_lists {
        if arguments.len() > 32 || arguments.iter().any(|argument| argument.len() > 512) {
            bail!("generic arguments are invalid");
        }
        for argument in arguments {
            validate_placeholders(argument, options)?;
        }
    }
    if spec.resume_arguments.is_none()
        && argument_lists
            .into_iter()
            .flatten()
            .any(|argument| argument.contains("{session}"))
    {
        bail!("the {{session}} placeholder requires resume_arguments");
    }
    Ok(())
}

fn validate_placeholders(argument: &str, options: &[ManifestOption]) -> Result<()> {
    for token in placeholders(argument) {
        if token == "session" || token == "cwd" {
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

fn placeholders(value: &str) -> impl Iterator<Item = &str> {
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

fn resolve_command(manifest: &GenericManifest, spec_path: &Path) -> Result<PathBuf> {
    let manifest_directory = spec_path.parent().unwrap_or(Path::new("/"));
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default();
    let candidates = manifest
        .requirements
        .iter()
        .find(|requirement| requirement.environment == manifest.generic.command)
        .map(|requirement| {
            requirement
                .candidates
                .iter()
                .map(|candidate| resolve_candidate(candidate, manifest_directory, &home))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    resolve_cli(&manifest.generic.command, &candidates)
}

fn resolve_candidate(raw: &str, manifest_directory: &Path, home: &Path) -> PathBuf {
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

fn build_arguments(
    spec: &GenericSpec,
    resume: bool,
    session: &str,
    cwd: &Path,
    option_values: &[(String, String)],
) -> Vec<OsString> {
    let extra = if resume {
        spec.resume_arguments.as_deref().unwrap_or_default()
    } else {
        spec.new_session_arguments.as_slice()
    };
    spec.arguments
        .iter()
        .chain(extra)
        .map(|argument| substitute(argument, session, cwd, option_values))
        .collect()
}

fn substitute(
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

fn classify_jsonl_line(line: &str, text_paths: &[String]) -> (TaskOutputKind, String) {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
        return (TaskOutputKind::System, line.to_owned());
    };
    text_paths
        .iter()
        .find_map(|path| extract_text(&value, path))
        .map(|text| (TaskOutputKind::Assistant, text))
        .unwrap_or_else(|| (TaskOutputKind::System, line.to_owned()))
}

fn extract_text(value: &serde_json::Value, path: &str) -> Option<String> {
    let mut current = value;
    for segment in path.split('.') {
        current = match segment.parse::<usize>() {
            Ok(index) => current.as_array()?.get(index)?,
            Err(_) => current.as_object()?.get(segment)?,
        };
    }
    current.as_str().map(str::to_owned)
}

fn visible_text(raw: &str) -> Option<String> {
    if raw
        .bytes()
        .all(|byte| (byte >= 0x20 && byte != 0x7f) || byte == b'\t')
    {
        return Some(raw.trim_end().to_owned());
    }
    let mut screen: Vec<char> = Vec::new();
    let mut cursor = 0usize;
    let mut had_controls = false;
    let mut characters = raw.chars().peekable();
    while let Some(character) = characters.next() {
        match character {
            '\u{1b}' => {
                had_controls = true;
                match characters.peek() {
                    Some('[') => {
                        characters.next();
                        apply_csi(&mut characters, &mut screen, &mut cursor);
                    }
                    Some(']') => {
                        characters.next();
                        skip_osc(&mut characters);
                    }
                    _ => {
                        characters.next();
                    }
                }
            }
            '\r' => {
                had_controls = true;
                cursor = 0;
            }
            '\u{8}' => {
                had_controls = true;
                cursor = cursor.saturating_sub(1);
            }
            '\t' => put(&mut screen, &mut cursor, '\t'),
            character if character.is_control() => had_controls = true,
            character => put(&mut screen, &mut cursor, character),
        }
    }
    let rendered = screen.iter().collect::<String>().trim_end().to_owned();
    let has_content = rendered.chars().any(|character| {
        !character.is_whitespace() && !('\u{2800}'..='\u{28ff}').contains(&character)
    });
    (has_content || !had_controls).then_some(rendered)
}

fn put(screen: &mut Vec<char>, cursor: &mut usize, character: char) {
    if *cursor < screen.len() {
        screen[*cursor] = character;
    } else {
        screen.push(character);
    }
    *cursor += 1;
}

fn apply_csi(
    characters: &mut std::iter::Peekable<std::str::Chars>,
    screen: &mut Vec<char>,
    cursor: &mut usize,
) {
    let mut parameters = String::new();
    let mut function = None;
    for character in characters.by_ref() {
        if ('\u{40}'..='\u{7e}').contains(&character) {
            function = Some(character);
            break;
        }
        parameters.push(character);
    }
    let count = parameters
        .trim_start_matches(['?', '>', '<', '='])
        .split(';')
        .next()
        .unwrap_or_default()
        .parse::<usize>()
        .unwrap_or(1)
        .max(1);
    match function {
        Some('K') => match parameters.as_str() {
            "" | "0" => screen.truncate(*cursor),
            "1" => {
                let end = (*cursor + 1).min(screen.len());
                screen[..end].fill(' ');
            }
            "2" => screen.clear(),
            _ => {}
        },
        Some('D') => *cursor = cursor.saturating_sub(count),
        Some('C') => move_cursor(screen, cursor, *cursor + count),
        Some('G') => move_cursor(screen, cursor, count.saturating_sub(1)),
        _ => {}
    }
}

fn move_cursor(screen: &mut Vec<char>, cursor: &mut usize, target: usize) {
    while screen.len() < target {
        screen.push(' ');
    }
    *cursor = target;
}

fn skip_osc(characters: &mut std::iter::Peekable<std::str::Chars>) {
    while let Some(character) = characters.next() {
        if character == '\u{7}' {
            break;
        }
        if character == '\u{1b}' && characters.peek() == Some(&'\\') {
            characters.next();
            break;
        }
    }
}

fn bounded_message(value: &str) -> String {
    let trimmed = value.trim();
    if trimmed.len() <= MAX_MESSAGE_BYTES {
        return trimmed.to_owned();
    }
    let mut cut = MAX_MESSAGE_BYTES;
    while !trimmed.is_char_boundary(cut) {
        cut -= 1;
    }
    format!("{}…", &trimmed[..cut])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(resume_arguments: Option<Vec<&str>>) -> GenericSpec {
        GenericSpec {
            command: "RELAY_EXAMPLE_PATH".to_owned(),
            arguments: vec!["--quiet".to_owned()],
            new_session_arguments: vec!["--session-id".to_owned(), "{session}".to_owned()],
            resume_arguments: resume_arguments
                .map(|arguments| arguments.into_iter().map(str::to_owned).collect()),
            output: None,
            text_paths: Vec::new(),
        }
    }

    fn requirement(environment: &str) -> GenericRequirement {
        GenericRequirement {
            environment: environment.to_owned(),
            candidates: vec!["/bin/cat".to_owned()],
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
    fn manifest_parses_generic_section_and_ignores_other_fields() {
        let manifest: GenericManifest = serde_json::from_str(
            r#"{
                "schema_version": 1,
                "id": "example",
                "name": "Example",
                "generic": {"command": "RELAY_EXAMPLE_PATH"},
                "requirements": [
                    {"name": "Example", "environment": "RELAY_EXAMPLE_PATH", "candidates": ["bin/example"]}
                ]
            }"#,
        )
        .unwrap();
        assert_eq!(manifest.generic.command, "RELAY_EXAMPLE_PATH");
        assert!(manifest.generic.arguments.is_empty());
        assert!(manifest.generic.resume_arguments.is_none());
        assert_eq!(manifest.requirements[0].candidates, ["bin/example"]);
    }

    #[test]
    fn unknown_output_mode_is_rejected() {
        let mut invalid = spec(Some(vec!["--resume", "{session}"]));
        invalid.output = Some("jsonl".to_owned());
        assert!(validate_spec(&invalid, &[]).is_err());
        invalid.output = Some("text".to_owned());
        assert!(validate_spec(&invalid, &[]).is_ok());
    }

    #[test]
    fn session_placeholder_requires_resume_arguments() {
        assert!(validate_spec(&spec(None), &[]).is_err());
        assert!(validate_spec(&spec(Some(vec!["--resume", "{session}"])), &[]).is_ok());
        let mut stateless = spec(None);
        stateless.new_session_arguments = Vec::new();
        assert!(validate_spec(&stateless, &[]).is_ok());
    }

    #[test]
    fn manifest_requires_the_command_requirement() {
        let manifest = GenericManifest {
            generic: spec(Some(vec!["--resume", "{session}"])),
            requirements: vec![requirement("RELAY_OTHER_PATH")],
            options: Vec::new(),
        };
        assert!(validate_manifest(&manifest).is_err());

        let valid = GenericManifest {
            requirements: vec![requirement("RELAY_EXAMPLE_PATH")],
            ..manifest
        };
        assert!(validate_manifest(&valid).is_ok());
    }

    #[test]
    fn generic_argument_bounds_are_validated_by_the_runtime() {
        let mut invalid = spec(Some(vec!["--resume", "{session}"]));
        invalid.arguments = vec!["x".repeat(513)];
        assert!(validate_spec(&invalid, &[]).is_err());

        invalid.arguments = (0..33).map(|index| index.to_string()).collect();
        assert!(validate_spec(&invalid, &[]).is_err());
    }

    #[test]
    fn unknown_placeholder_is_rejected() {
        let mut invalid = spec(None);
        invalid.arguments = vec!["--model".to_owned(), "{model}".to_owned()];
        assert!(validate_spec(&invalid, &[]).is_err());
    }

    #[test]
    fn arguments_substitute_session_and_cwd() {
        let spec = spec(Some(vec!["--resume", "{session}", "--dir", "{cwd}"]));
        let resumed = build_arguments(&spec, true, "session-9", Path::new("/tmp/project"), &[]);
        assert_eq!(
            resumed,
            ["--quiet", "--resume", "session-9", "--dir", "/tmp/project"].map(OsString::from)
        );
        let first_turn = build_arguments(&spec, false, "task-1", Path::new("/tmp/project"), &[]);
        assert_eq!(
            first_turn,
            ["--quiet", "--session-id", "task-1"].map(OsString::from)
        );
    }

    #[test]
    fn braces_in_substituted_values_are_not_reparsed() {
        assert_eq!(
            substitute("{cwd}", "task-1", Path::new("/tmp/{weird}"), &[]),
            OsString::from("/tmp/{weird}")
        );
        assert_eq!(
            substitute("{session}", "sess{cwd}ion", Path::new("/tmp/project"), &[]),
            OsString::from("sess{cwd}ion")
        );
        assert_eq!(
            substitute("a{b}c{session}", "S", Path::new("/tmp"), &[]),
            OsString::from("a{b}cS")
        );
    }

    #[test]
    fn candidates_resolve_home_and_manifest_relative_paths() {
        let manifest_directory = Path::new("/opt/relay/adapters");
        let home = Path::new("/Users/example");
        assert_eq!(
            resolve_candidate("~/bin/tool", manifest_directory, home),
            PathBuf::from("/Users/example/bin/tool")
        );
        assert_eq!(
            resolve_candidate("../bin/tool", manifest_directory, home),
            PathBuf::from("/opt/relay/adapters/../bin/tool")
        );
        assert_eq!(
            resolve_candidate("/usr/local/bin/tool", manifest_directory, home),
            PathBuf::from("/usr/local/bin/tool")
        );
    }

    #[test]
    fn jsonl_mode_requires_text_paths_and_text_mode_forbids_them() {
        let mut jsonl = spec(Some(vec!["--resume", "{session}"]));
        jsonl.output = Some("jsonl".to_owned());
        assert!(validate_spec(&jsonl, &[]).is_err());
        jsonl.text_paths = vec!["response".to_owned()];
        assert!(validate_spec(&jsonl, &[]).is_ok());
        jsonl.text_paths = vec!["bad path".to_owned()];
        assert!(validate_spec(&jsonl, &[]).is_err());

        let mut text = spec(Some(vec!["--resume", "{session}"]));
        text.text_paths = vec!["response".to_owned()];
        assert!(validate_spec(&text, &[]).is_err());
    }

    #[test]
    fn jsonl_lines_map_to_assistant_via_first_matching_path() {
        let paths = vec!["response".to_owned(), "message.content.0.text".to_owned()];
        assert_eq!(
            classify_jsonl_line(r#"{"response":"第一段"}"#, &paths),
            (TaskOutputKind::Assistant, "第一段".to_owned())
        );
        assert_eq!(
            classify_jsonl_line(r#"{"message":{"content":[{"text":"第二段"}]}}"#, &paths),
            (TaskOutputKind::Assistant, "第二段".to_owned())
        );
        assert_eq!(
            classify_jsonl_line(r#"{"type":"meta","response":7}"#, &paths),
            (
                TaskOutputKind::System,
                r#"{"type":"meta","response":7}"#.to_owned()
            )
        );
        assert_eq!(
            classify_jsonl_line("not json", &paths),
            (TaskOutputKind::System, "not json".to_owned())
        );
    }

    fn option(key: &str, values: Vec<&str>, default: Option<&str>) -> ManifestOption {
        ManifestOption {
            key: key.to_owned(),
            values: values.into_iter().map(str::to_owned).collect(),
            default: default.map(str::to_owned),
        }
    }

    #[test]
    fn option_placeholders_resolve_from_request_default_and_first_value() {
        let options = [
            option("model", vec!["a", "b"], Some("b")),
            option("mode", vec!["x"], None),
        ];
        let provided = std::collections::BTreeMap::from([("model".to_owned(), "a".to_owned())]);
        let resolved = resolve_options(&options, &provided);
        assert_eq!(
            resolved,
            [
                ("model".to_owned(), "a".to_owned()),
                ("mode".to_owned(), "x".to_owned()),
            ]
        );
        let fallback = resolve_options(&options, &std::collections::BTreeMap::new());
        assert_eq!(fallback[0].1, "b");
        assert_eq!(
            substitute(
                "run {option:model} -m {option:mode}",
                "s",
                Path::new("/tmp"),
                &resolved
            ),
            OsString::from("run a -m x")
        );
    }

    #[test]
    fn option_declarations_are_validated() {
        assert!(validate_options(&[option("model", vec!["a"], None)]).is_ok());
        assert!(validate_options(&[option("relay_thing", vec!["a"], None)]).is_err());
        assert!(validate_options(&[option("Bad", vec!["a"], None)]).is_err());
        assert!(validate_options(&[option("model", vec![], None)]).is_err());
        assert!(validate_options(&[option("model", vec!["a"], Some("z"))]).is_err());
        assert!(
            validate_options(&[option("m", vec!["a"], None), option("m", vec!["b"], None)])
                .is_err()
        );
    }

    #[test]
    fn undeclared_option_placeholder_is_rejected() {
        let mut invalid = spec(Some(vec!["--resume", "{session}"]));
        invalid.arguments = vec!["{option:model}".to_owned()];
        assert!(validate_spec(&invalid, &[]).is_err());
        assert!(validate_spec(&invalid, &[option("model", vec!["a"], None)]).is_ok());
    }

    #[test]
    fn visible_text_replays_cursor_moves_and_erasures() {
        assert_eq!(
            visible_text("Google Dee\u{1b}[3D\u{1b}[KDeepMind").as_deref(),
            Some("Google DeepMind")
        );
        assert_eq!(visible_text("12345\rab").as_deref(), Some("ab345"));
        assert_eq!(visible_text("abc\u{1b}[2K"), None);
        assert_eq!(
            visible_text("\u{1b}]0;window title\u{7}answer").as_deref(),
            Some("answer")
        );
    }

    #[test]
    fn erase_to_start_includes_cursor_and_columns_pad() {
        assert_eq!(
            visible_text("abcde\u{1b}[3G\u{1b}[1KXY").as_deref(),
            Some("  XYe")
        );
        assert_eq!(
            visible_text("Done\u{1b}[10G[ok]").as_deref(),
            Some("Done     [ok]")
        );
        assert_eq!(visible_text("ab\u{1b}[3Ccd").as_deref(), Some("ab   cd"));
    }

    #[test]
    fn spinner_and_control_only_lines_are_dropped() {
        let spinner = "\u{1b}[?2026h\u{1b}[?25l\u{1b}[1G⠙ \u{1b}[K\u{1b}[?25h\u{1b}[?2026l";
        assert_eq!(visible_text(spinner), None);
        assert_eq!(visible_text("\u{1b}[?25h"), None);
    }

    #[test]
    fn plain_lines_survive_and_blank_lines_are_preserved() {
        assert_eq!(
            visible_text("  indented text  ").as_deref(),
            Some("  indented text")
        );
        assert_eq!(visible_text("").as_deref(), Some(""));
        assert_eq!(visible_text("普通文本").as_deref(), Some("普通文本"));
    }

    #[test]
    fn long_messages_are_bounded_on_character_boundaries() {
        let long = "答".repeat(120);
        let bounded = bounded_message(&long);
        assert!(bounded.ends_with('…'));
        assert!(bounded.len() <= MAX_MESSAGE_BYTES + '…'.len_utf8());
    }
}
