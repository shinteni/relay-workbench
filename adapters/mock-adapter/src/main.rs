use std::env;
use std::error::Error;
use std::io::{self, BufRead, Write};
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use relay_protocol::{
    AdapterEvent, AdapterOutput, AdapterRunRequest, PROTOCOL_VERSION, TaskOutputKind, TaskStatus,
};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    if arguments.as_slice() != ["run"] {
        return Err("usage: mock-adapter run".into());
    }

    let mut input = String::new();
    io::stdin().lock().read_line(&mut input)?;
    let request: AdapterRunRequest = serde_json::from_str(&input)?;
    if request.protocol_version != PROTOCOL_VERSION {
        return Err(format!("unsupported protocol version: {}", request.protocol_version).into());
    }

    let mut output = io::stdout().lock();
    emit(
        &mut output,
        AdapterEvent {
            task_id: request.task_id,
            status: TaskStatus::Starting,
            message: Some("mock adapter started".to_owned()),
            output: None,
            session_id: Some(request.task_id.to_string()),
            interaction: None,
        },
    )?;
    emit(
        &mut output,
        AdapterEvent {
            task_id: request.task_id,
            status: TaskStatus::Running,
            message: Some("mock task running".to_owned()),
            output: None,
            session_id: None,
            interaction: None,
        },
    )?;
    thread::sleep(Duration::from_millis(1_500));
    emit(
        &mut output,
        AdapterEvent {
            task_id: request.task_id,
            status: TaskStatus::Completed,
            message: Some("mock task completed".to_owned()),
            output: Some(AdapterOutput {
                kind: TaskOutputKind::Assistant,
                text: format!("Mock received: {}", request.prompt),
            }),
            session_id: None,
            interaction: None,
        },
    )?;

    Ok(())
}

fn emit(output: &mut impl Write, event: AdapterEvent) -> Result<(), Box<dyn Error>> {
    serde_json::to_writer(&mut *output, &event)?;
    output.write_all(b"\n")?;
    output.flush()?;
    Ok(())
}
