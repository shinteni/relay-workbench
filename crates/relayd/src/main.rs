use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::Parser;
use relayd::{AdapterRegistration, DaemonConfig};

#[derive(Debug, Parser)]
#[command(about = "Local multi-CLI task daemon")]
struct Arguments {
    #[arg(long)]
    socket: PathBuf,
    #[arg(long)]
    state_dir: PathBuf,
    #[arg(long = "adapter", value_name = "ID=EXECUTABLE")]
    adapters: Vec<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let arguments = Arguments::parse();
    let adapters = arguments
        .adapters
        .iter()
        .map(|value| parse_adapter(value))
        .collect::<Result<Vec<_>>>()?;
    relayd::serve(
        DaemonConfig {
            socket_path: arguments.socket,
            state_directory: arguments.state_dir,
            adapters,
        },
        async {
            if let Err(error) = tokio::signal::ctrl_c().await {
                eprintln!("failed to listen for shutdown signal: {error}");
            }
        },
    )
    .await
}

fn parse_adapter(value: &str) -> Result<AdapterRegistration> {
    let (id, executable) = value
        .split_once('=')
        .with_context(|| format!("adapter must use ID=EXECUTABLE: {value}"))?;
    if id.is_empty() || executable.is_empty() {
        bail!("adapter must use non-empty ID=EXECUTABLE: {value}");
    }
    Ok(AdapterRegistration {
        id: id.to_owned(),
        executable: PathBuf::from(executable),
        environment: BTreeMap::new(),
    })
}
