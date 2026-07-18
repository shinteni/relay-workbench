use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{Context, Result, anyhow};
use clap::{Parser, Subcommand};
use relay_protocol::{
    AdapterInteractionResponse, ChainStep, DaemonRequest, DaemonResponse, MAX_CHAIN_STEPS,
    MAX_PROMPT_BYTES,
};
use uuid::Uuid;

#[derive(Debug, Parser)]
#[command(about = "Development client for relayd")]
struct Arguments {
    #[arg(long)]
    socket: PathBuf,
    #[command(subcommand)]
    command: ClientCommand,
}

#[derive(Debug, Subcommand)]
enum ClientCommand {
    Ping,
    Start {
        #[arg(long)]
        id: Option<Uuid>,
        #[arg(long)]
        adapter: String,
        #[arg(long)]
        prompt: Option<String>,
        #[arg(long, conflicts_with = "prompt")]
        stdin: bool,
        #[arg(long)]
        cwd: Option<PathBuf>,
        #[arg(long = "option", value_name = "KEY=VALUE")]
        options: Vec<String>,
    },
    StartChain {
        #[arg(long)]
        id: Option<Uuid>,
        #[arg(long = "step", value_name = "ADAPTER")]
        steps: Vec<String>,
        #[arg(long)]
        prompt: Option<String>,
        #[arg(long, conflicts_with = "prompt")]
        stdin: bool,
        #[arg(long)]
        cwd: Option<PathBuf>,
        #[arg(long)]
        note: Option<String>,
        #[arg(long = "step-option", value_name = "STEP:KEY=VALUE")]
        step_options: Vec<String>,
    },
    Get {
        id: Uuid,
    },
    Continue {
        id: Uuid,
        #[arg(long)]
        prompt: Option<String>,
        #[arg(long, conflicts_with = "prompt")]
        stdin: bool,
        #[arg(long = "option", value_name = "KEY=VALUE")]
        options: Vec<String>,
    },
    Output {
        id: Uuid,
    },
    List,
    Watch {
        #[arg(long, default_value_t = 1_000)]
        interval_ms: u64,
        #[arg(long)]
        parent_pid: Option<u32>,
    },
    Cancel {
        id: Uuid,
    },
    Delete {
        id: Uuid,
    },
    Rename {
        id: Uuid,
        #[arg(long)]
        title: String,
    },
    Respond {
        id: Uuid,
        #[arg(long)]
        stdin: bool,
        #[arg(long)]
        interaction: Option<String>,
        #[arg(long)]
        action: Option<String>,
        #[arg(long = "answer", value_name = "QUESTION=VALUE")]
        answers: Vec<String>,
    },
    RegisterAdapter {
        #[arg(long)]
        id: String,
        #[arg(long)]
        executable: PathBuf,
        #[arg(long = "environment", value_name = "KEY=VALUE")]
        environment: Vec<String>,
    },
    UnregisterAdapter {
        #[arg(long)]
        id: String,
    },
    Shutdown,
}

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(error) => {
            eprintln!("{error:#}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<bool> {
    let arguments = Arguments::parse();
    let (request, start_id) = match arguments.command {
        ClientCommand::Ping => (DaemonRequest::Ping, None),
        ClientCommand::Watch {
            interval_ms,
            parent_pid,
        } => {
            return watch_tasks(&arguments.socket, interval_ms, parent_pid).await;
        }
        ClientCommand::Start {
            id,
            adapter,
            prompt,
            stdin,
            cwd,
            options,
        } => {
            let id = id.unwrap_or_else(Uuid::new_v4);
            let prompt = prompt_input(stdin, prompt, std::io::stdin().lock())?;
            let cwd = cwd
                .map(Ok)
                .unwrap_or_else(std::env::current_dir)
                .context("failed to resolve cwd")?;
            (
                DaemonRequest::StartTask {
                    id,
                    adapter_id: adapter,
                    prompt,
                    cwd,
                    options: parse_key_values(options, "adapter option")?,
                },
                Some(id),
            )
        }
        ClientCommand::StartChain {
            id,
            steps,
            prompt,
            stdin,
            cwd,
            note,
            step_options,
        } => {
            if !(2..=MAX_CHAIN_STEPS).contains(&steps.len()) {
                return Err(anyhow!(
                    "a chain requires between 2 and {MAX_CHAIN_STEPS} --step values"
                ));
            }
            let options = parse_step_options(step_options, steps.len())?;
            let id = id.unwrap_or_else(Uuid::new_v4);
            let prompt = prompt_input(stdin, prompt, std::io::stdin().lock())?;
            let cwd = cwd
                .map(Ok)
                .unwrap_or_else(std::env::current_dir)
                .context("failed to resolve cwd")?;
            (
                DaemonRequest::StartChain {
                    id,
                    prompt,
                    cwd,
                    steps: steps
                        .into_iter()
                        .zip(options)
                        .map(|(adapter_id, options)| ChainStep {
                            adapter_id,
                            options,
                        })
                        .collect(),
                    note,
                },
                Some(id),
            )
        }
        ClientCommand::Get { id } => (DaemonRequest::GetTask { id }, None),
        ClientCommand::Continue {
            id,
            prompt,
            stdin,
            options,
        } => {
            let prompt = prompt_input(stdin, prompt, std::io::stdin().lock())?;
            (
                DaemonRequest::ContinueTask {
                    id,
                    prompt,
                    options: parse_key_values(options, "adapter option")?,
                },
                None,
            )
        }
        ClientCommand::Output { id } => (DaemonRequest::GetTaskOutput { id }, None),
        ClientCommand::List => (DaemonRequest::ListTasks, None),
        ClientCommand::Cancel { id } => (DaemonRequest::CancelTask { id }, None),
        ClientCommand::Delete { id } => (DaemonRequest::DeleteTask { id }, None),
        ClientCommand::Rename { id, title } => (DaemonRequest::RenameTask { id, title }, None),
        ClientCommand::Respond {
            id,
            stdin,
            interaction,
            action,
            answers,
        } => (
            DaemonRequest::RespondToInteraction {
                id,
                response: interaction_response(stdin, interaction, action, answers)?,
            },
            None,
        ),
        ClientCommand::RegisterAdapter {
            id,
            executable,
            environment,
        } => (
            DaemonRequest::RegisterAdapter {
                id,
                executable,
                environment: parse_key_values(environment, "adapter environment")?,
            },
            None,
        ),
        ClientCommand::UnregisterAdapter { id } => (DaemonRequest::UnregisterAdapter { id }, None),
        ClientCommand::Shutdown => (DaemonRequest::Shutdown, None),
    };
    let response = relayd::send_request(&arguments.socket, &request)
        .await
        .map_err(|error| match start_id {
            Some(id) => anyhow!(
                "start request {id} did not receive a response; query this ID before retrying: {error}"
            ),
            None => error,
        })?;
    println!(
        "{}",
        serde_json::to_string_pretty(&response).context("failed to encode response")?
    );
    Ok(!matches!(response, DaemonResponse::Error { .. }))
}

async fn watch_tasks(
    socket: &std::path::Path,
    interval_ms: u64,
    parent_pid: Option<u32>,
) -> Result<bool> {
    if !(100..=60_000).contains(&interval_ms) {
        return Err(anyhow!(
            "watch interval must be between 100 and 60000 milliseconds"
        ));
    }
    let mut previous = None;
    loop {
        if !watch_parent_matches(parent_pid) {
            return Ok(true);
        }
        let response = relayd::send_request(socket, &DaemonRequest::ListTasks).await?;
        if let Some(line) = changed_response_line(&response, &mut previous)? {
            let mut stdout = std::io::stdout().lock();
            stdout.write_all(line.as_bytes())?;
            stdout.write_all(b"\n")?;
            stdout.flush()?;
        }
        tokio::time::sleep(std::time::Duration::from_millis(interval_ms)).await;
    }
}

fn watch_parent_matches(expected: Option<u32>) -> bool {
    match expected {
        None => true,
        Some(0) => false,
        Some(expected) => (unsafe { libc::getppid() }) as u32 == expected,
    }
}

fn changed_response_line(
    response: &DaemonResponse,
    previous: &mut Option<String>,
) -> Result<Option<String>> {
    let line = serde_json::to_string(response).context("failed to encode watch response")?;
    if previous.as_ref() == Some(&line) {
        return Ok(None);
    }
    *previous = Some(line.clone());
    Ok(Some(line))
}

fn parse_key_values(values: Vec<String>, kind: &str) -> Result<BTreeMap<String, String>> {
    let mut options = BTreeMap::new();
    for value in values {
        let (key, value) = value
            .split_once('=')
            .with_context(|| format!("{kind} must use KEY=VALUE: {value}"))?;
        if key.is_empty() || value.is_empty() {
            return Err(anyhow!("{kind} must use non-empty KEY=VALUE"));
        }
        if options.insert(key.to_owned(), value.to_owned()).is_some() {
            return Err(anyhow!("{kind} {key} was provided more than once"));
        }
    }
    Ok(options)
}

fn parse_step_options(
    values: Vec<String>,
    step_count: usize,
) -> Result<Vec<BTreeMap<String, String>>> {
    let mut options = vec![BTreeMap::new(); step_count];
    for value in values {
        let (step, option) = value
            .split_once(':')
            .with_context(|| format!("step option must use STEP:KEY=VALUE: {value}"))?;
        let step = step
            .parse::<usize>()
            .with_context(|| format!("step option index is invalid: {step}"))?;
        if step == 0 || step > step_count {
            return Err(anyhow!(
                "step option index must be between 1 and {step_count}"
            ));
        }
        let parsed = parse_key_values(vec![option.to_owned()], "step option")?;
        let (key, value) = parsed.into_iter().next().unwrap();
        if options[step - 1].insert(key.clone(), value).is_some() {
            return Err(anyhow!(
                "step option {key} was provided more than once for step {step}"
            ));
        }
    }
    Ok(options)
}

fn parse_answers(values: Vec<String>) -> Result<BTreeMap<String, Vec<String>>> {
    let mut answers = BTreeMap::<String, Vec<String>>::new();
    for value in values {
        let (key, value) = value
            .split_once('=')
            .with_context(|| format!("answer must use QUESTION=VALUE: {value}"))?;
        if key.is_empty() || value.is_empty() {
            return Err(anyhow!("answer must use non-empty QUESTION=VALUE"));
        }
        answers
            .entry(key.to_owned())
            .or_default()
            .push(value.to_owned());
    }
    Ok(answers)
}

fn prompt_input(from_stdin: bool, prompt: Option<String>, reader: impl Read) -> Result<String> {
    match (from_stdin, prompt) {
        (true, None) => {
            let mut prompt = String::new();
            reader
                .take(MAX_PROMPT_BYTES as u64 + 1)
                .read_to_string(&mut prompt)
                .context("failed to read prompt from stdin")?;
            if prompt.len() > MAX_PROMPT_BYTES {
                return Err(anyhow!("prompt from stdin is too large"));
            }
            Ok(prompt)
        }
        (false, Some(prompt)) => Ok(prompt),
        (true, Some(_)) => Err(anyhow!("--stdin cannot be combined with --prompt")),
        (false, None) => Err(anyhow!("--prompt or --stdin is required")),
    }
}

fn interaction_response(
    from_stdin: bool,
    interaction: Option<String>,
    action: Option<String>,
    answers: Vec<String>,
) -> Result<AdapterInteractionResponse> {
    if from_stdin {
        if interaction.is_some() || action.is_some() || !answers.is_empty() {
            return Err(anyhow!(
                "--stdin cannot be combined with interaction response arguments"
            ));
        }
        let mut encoded = String::new();
        std::io::stdin()
            .take(64 * 1024 + 1)
            .read_to_string(&mut encoded)
            .context("failed to read interaction response from stdin")?;
        if encoded.len() > 64 * 1024 {
            return Err(anyhow!("interaction response from stdin is too large"));
        }
        return serde_json::from_str(&encoded)
            .context("failed to decode interaction response from stdin");
    }
    Ok(AdapterInteractionResponse {
        interaction_id: interaction.context("--interaction is required without --stdin")?,
        action,
        answers: parse_answers(answers)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_adapter_options() {
        assert_eq!(
            parse_key_values(vec!["codex_model=gpt-5.6-sol".to_owned()], "adapter option").unwrap(),
            BTreeMap::from([("codex_model".to_owned(), "gpt-5.6-sol".to_owned())])
        );
    }

    #[test]
    fn rejects_duplicate_adapter_options() {
        assert!(
            parse_key_values(
                vec!["model=a".to_owned(), "model=b".to_owned()],
                "adapter option"
            )
            .is_err()
        );
    }

    #[test]
    fn parses_one_based_chain_step_options() {
        assert_eq!(
            parse_step_options(
                vec!["1:codex_mode=plan".to_owned(), "2:model=opus".to_owned(),],
                2,
            )
            .unwrap(),
            vec![
                BTreeMap::from([("codex_mode".to_owned(), "plan".to_owned())]),
                BTreeMap::from([("model".to_owned(), "opus".to_owned())]),
            ]
        );
    }

    #[test]
    fn rejects_chain_step_options_outside_the_plan() {
        assert!(parse_step_options(vec!["3:model=opus".to_owned()], 2).is_err());
        assert!(parse_step_options(vec!["0:model=opus".to_owned()], 2).is_err());
    }

    #[test]
    fn watch_output_is_emitted_only_when_tasks_change() {
        let first = DaemonResponse::Tasks { tasks: Vec::new() };
        let mut previous = None;

        assert!(
            changed_response_line(&first, &mut previous)
                .unwrap()
                .is_some()
        );
        assert_eq!(changed_response_line(&first, &mut previous).unwrap(), None);

        let changed = DaemonResponse::Error {
            code: "changed".to_owned(),
            message: "changed".to_owned(),
        };
        assert!(
            changed_response_line(&changed, &mut previous)
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn watch_parent_guard_accepts_only_the_current_parent() {
        let parent_pid = unsafe { libc::getppid() };
        assert!(parent_pid > 0);
        assert!(watch_parent_matches(None));
        assert!(watch_parent_matches(Some(parent_pid as u32)));
        assert!(!watch_parent_matches(Some(0)));
    }

    #[test]
    fn repeated_answers_are_grouped_by_question() {
        assert_eq!(
            parse_answers(vec!["choice=A".to_owned(), "choice=B".to_owned()]).unwrap(),
            BTreeMap::from([("choice".to_owned(), vec!["A".to_owned(), "B".to_owned()])])
        );
    }

    #[test]
    fn stdin_prompt_preserves_multiline_text() {
        assert_eq!(
            prompt_input(true, None, "第一行\nsecond line".as_bytes()).unwrap(),
            "第一行\nsecond line"
        );
    }

    #[test]
    fn prompt_requires_exactly_one_source() {
        assert!(prompt_input(false, None, "".as_bytes()).is_err());
        assert!(prompt_input(true, Some("visible".to_owned()), "hidden".as_bytes()).is_err());
    }

    #[test]
    fn oversized_stdin_prompt_is_rejected() {
        let oversized = vec![b'x'; MAX_PROMPT_BYTES + 1];
        assert!(prompt_input(true, None, oversized.as_slice()).is_err());
    }
}
