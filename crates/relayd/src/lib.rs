use std::collections::{BTreeMap, HashMap};
use std::future::Future;
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, anyhow, bail};
use relay_protocol::{
    AdapterEvent, AdapterInteraction, AdapterInteractionKind, AdapterInteractionResponse,
    AdapterRunRequest, ChainStep, DaemonRequest, DaemonResponse, MAX_CHAIN_STEPS, MAX_PROMPT_BYTES,
    PROTOCOL_VERSION, TaskOutput, TaskOutputKind, TaskSnapshot, TaskStatus,
};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::process::{Child, ChildStderr, Command};
use tokio::sync::{
    Mutex, Notify, RwLock, RwLockReadGuard, RwLockWriteGuard, Semaphore, mpsc, oneshot,
};
use tokio::task::{JoinHandle, JoinSet};
use uuid::Uuid;

const MAX_LINE_BYTES: usize = 2 * 1024 * 1024;
const MAX_PROMPT_PREVIEW_BYTES: usize = 512;
const MAX_TASK_TITLE_BYTES: usize = 256;
const MAX_INTERACTION_ID_BYTES: usize = 256;
const MAX_INTERACTION_TITLE_BYTES: usize = 256;
const MAX_INTERACTION_MESSAGE_BYTES: usize = 16 * 1024;
const MAX_INTERACTION_ACTIONS: usize = 8;
const MAX_INTERACTION_QUESTIONS: usize = 3;
const MAX_INTERACTION_OPTIONS: usize = 8;
const MAX_INTERACTION_VALUE_BYTES: usize = 256;
const MAX_INTERACTION_LABEL_BYTES: usize = 512;
const MAX_INTERACTION_DESCRIPTION_BYTES: usize = 2 * 1024;
const MAX_INTERACTION_ANSWER_BYTES: usize = 16 * 1024;
const MAX_STATUS_MESSAGE_BYTES: usize = 2 * 1024;
const MAX_CWD_BYTES: usize = 1024;
const MAX_ADAPTER_ID_BYTES: usize = 256;
const MAX_STORED_TASKS: usize = 64;
const MAX_ACTIVE_TASKS: usize = 16;
const MAX_CLIENT_CONNECTIONS: usize = 64;
const MAX_TASK_OUTPUT_BYTES: usize = 384 * 1024;
const MAX_TASK_OUTPUT_EVENTS: usize = 2048;
const MAX_OUTPUT_EVENT_BYTES: usize = 32 * 1024;
const MAX_ADAPTER_OPTIONS: usize = 16;
const MAX_ADAPTER_OPTION_KEY_BYTES: usize = 64;
const MAX_ADAPTER_OPTION_VALUE_BYTES: usize = 256;
const MAX_ADAPTER_ENVIRONMENT: usize = 16;
const MAX_ADAPTER_ENVIRONMENT_KEY_BYTES: usize = 64;
const MAX_ADAPTER_ENVIRONMENT_VALUE_BYTES: usize = 1024;
const MAX_CHAIN_NOTE_BYTES: usize = 256;
const MAX_PERSISTED_TASK_BYTES: usize = 2 * 1024 * 1024;
const TASK_STATE_VERSION: u32 = 1;
const CLIENT_REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const PROCESS_GROUP_EXIT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const PROCESS_GROUP_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(10);
const CHAIN_GROUP_OPTION: &str = "relay_group";
const CHAIN_STEP_OPTION: &str = "relay_chain_step";
const CHAIN_AGENTS_OPTION: &str = "relay_chain_agents";
const CHAIN_NOTE_OPTION: &str = "relay_chain_note";

#[derive(Debug, Clone)]
pub struct AdapterRegistration {
    pub id: String,
    pub executable: PathBuf,
    pub environment: BTreeMap<String, String>,
}

#[derive(Debug)]
pub struct DaemonConfig {
    pub socket_path: PathBuf,
    pub state_directory: PathBuf,
    pub adapters: Vec<AdapterRegistration>,
}

struct TaskEntry {
    snapshot: TaskSnapshot,
    prompt: String,
    output: Vec<TaskOutput>,
    output_bytes: usize,
    output_truncated: bool,
    next_output_sequence: u64,
    cancel: Option<oneshot::Sender<CancelRequest>>,
    runner: Option<JoinHandle<()>>,
    response_pending: bool,
    chain: Option<ChainContext>,
}

struct CancelRequest {
    acknowledged: oneshot::Sender<std::result::Result<(), String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct ChainContext {
    id: Uuid,
    step: usize,
    steps: Vec<ChainStep>,
    note: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedTask {
    version: u32,
    snapshot: TaskSnapshot,
    output: Vec<TaskOutput>,
    output_truncated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    chain: Option<ChainContext>,
}

impl PersistedTask {
    fn from_entry(entry: &TaskEntry) -> Self {
        Self {
            version: TASK_STATE_VERSION,
            snapshot: entry.snapshot.clone(),
            output: entry.output.clone(),
            output_truncated: entry.output_truncated,
            chain: entry.chain.clone(),
        }
    }

    fn into_entry(self, expected_id: Uuid) -> Result<TaskEntry> {
        if self.version != TASK_STATE_VERSION {
            bail!("unsupported task state version: {}", self.version);
        }
        if self.snapshot.id != expected_id {
            bail!("task state ID does not match its file name");
        }
        validate_persisted_snapshot(&self.snapshot)?;
        if let Some(chain) = &self.chain {
            validate_chain_context(&self.snapshot, chain)?;
        }
        if self.output.len() > MAX_TASK_OUTPUT_EVENTS {
            bail!("persisted task has too many output events");
        }
        let mut output_bytes = 0_usize;
        let mut previous_sequence = None;
        for output in &self.output {
            if output.text.len() > MAX_OUTPUT_EVENT_BYTES {
                bail!("persisted output event is too large");
            }
            output_bytes = output_bytes.saturating_add(output.text.len());
            if output_bytes > MAX_TASK_OUTPUT_BYTES {
                bail!("persisted task output is too large");
            }
            if previous_sequence.is_some_and(|sequence| output.sequence <= sequence) {
                bail!("persisted output sequence is not strictly increasing");
            }
            previous_sequence = Some(output.sequence);
        }
        let next_output_sequence = previous_sequence
            .map(|sequence| sequence.saturating_add(1))
            .unwrap_or(0);
        Ok(TaskEntry {
            snapshot: self.snapshot,
            prompt: String::new(),
            output: self.output,
            output_bytes,
            output_truncated: self.output_truncated,
            next_output_sequence,
            cancel: None,
            runner: None,
            response_pending: false,
            chain: self.chain,
        })
    }
}

#[derive(Debug, Clone)]
struct TaskPersistence {
    directory: Option<PathBuf>,
}

impl TaskPersistence {
    fn prepare(directory: PathBuf) -> Result<Self> {
        prepare_state_directory(&directory)?;
        Ok(Self {
            directory: Some(directory),
        })
    }

    #[cfg(test)]
    fn disabled() -> Self {
        Self { directory: None }
    }

    fn load(&self) -> Result<HashMap<Uuid, TaskEntry>> {
        let Some(directory) = &self.directory else {
            return Ok(HashMap::new());
        };
        let mut tasks = HashMap::new();
        for item in std::fs::read_dir(directory).with_context(|| {
            format!(
                "failed to read task state directory {}",
                directory.display()
            )
        })? {
            let item = item.context("failed to read task state directory entry")?;
            let path = item.path();
            if path.extension().and_then(|extension| extension.to_str()) != Some("json") {
                continue;
            }
            let stem = path
                .file_stem()
                .and_then(|stem| stem.to_str())
                .ok_or_else(|| anyhow!("task state file name is not valid UTF-8"))?;
            let id = Uuid::parse_str(stem).with_context(|| {
                format!("task state file has an invalid ID: {}", path.display())
            })?;
            let metadata = std::fs::symlink_metadata(&path)
                .with_context(|| format!("failed to inspect task state {}", path.display()))?;
            if !metadata.file_type().is_file() {
                bail!("task state is not a regular file: {}", path.display());
            }
            if metadata.permissions().mode() & 0o077 != 0 {
                bail!("task state must be private (0600): {}", path.display());
            }
            validate_path_owner(&metadata, &path, false)?;
            if path_has_writable_acl(&path)? {
                bail!("task state has a writable ACL: {}", path.display());
            }
            if metadata.len() > MAX_PERSISTED_TASK_BYTES as u64 {
                bail!("task state is too large: {}", path.display());
            }
            let encoded = std::fs::read(&path)
                .with_context(|| format!("failed to read task state {}", path.display()))?;
            let persisted: PersistedTask = serde_json::from_slice(&encoded)
                .with_context(|| format!("failed to decode task state {}", path.display()))?;
            if tasks.len() >= MAX_STORED_TASKS {
                bail!("task state directory exceeds the history limit");
            }
            tasks.insert(id, persisted.into_entry(id)?);
        }
        Ok(tasks)
    }

    fn write(&self, task: &PersistedTask) -> Result<()> {
        let Some(directory) = &self.directory else {
            return Ok(());
        };
        let encoded = serde_json::to_vec(task).context("failed to encode task state")?;
        if encoded.len() > MAX_PERSISTED_TASK_BYTES {
            bail!("encoded task state exceeds the size limit");
        }
        let final_path = directory.join(format!("{}.json", task.snapshot.id));
        let temporary_path = directory.join(format!(".{}.json.tmp", task.snapshot.id));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary_path)
            .with_context(|| {
                format!(
                    "failed to open temporary task state {}",
                    temporary_path.display()
                )
            })?;
        std::fs::set_permissions(&temporary_path, std::fs::Permissions::from_mode(0o600))?;
        file.write_all(&encoded)
            .context("failed to write task state")?;
        file.write_all(b"\n")
            .context("failed to finish task state")?;
        file.sync_all().context("failed to sync task state")?;
        std::fs::rename(&temporary_path, &final_path)
            .with_context(|| format!("failed to replace task state {}", final_path.display()))?;
        sync_directory(directory)
    }

    fn remove(&self, id: Uuid) -> Result<()> {
        let Some(directory) = &self.directory else {
            return Ok(());
        };
        let path = directory.join(format!("{id}.json"));
        match std::fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_file() => {
                std::fs::remove_file(&path)
                    .with_context(|| format!("failed to remove task state {}", path.display()))?;
                sync_directory(directory)
            }
            Ok(_) => bail!("task state is not a regular file: {}", path.display()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error)
                .with_context(|| format!("failed to inspect task state {}", path.display())),
        }
    }
}

struct TaskStore {
    entries: RwLock<HashMap<Uuid, TaskEntry>>,
    interaction_responders: RwLock<HashMap<Uuid, mpsc::Sender<AdapterInteractionResponse>>>,
    persistence: TaskPersistence,
    persistence_lock: Mutex<()>,
    chain_lock: Mutex<()>,
    chain_notify: Notify,
}

impl TaskStore {
    fn new(entries: HashMap<Uuid, TaskEntry>, persistence: TaskPersistence) -> Self {
        Self {
            entries: RwLock::new(entries),
            interaction_responders: RwLock::new(HashMap::new()),
            persistence,
            persistence_lock: Mutex::new(()),
            chain_lock: Mutex::new(()),
            chain_notify: Notify::new(),
        }
    }

    async fn read(&self) -> RwLockReadGuard<'_, HashMap<Uuid, TaskEntry>> {
        self.entries.read().await
    }

    async fn write(&self) -> RwLockWriteGuard<'_, HashMap<Uuid, TaskEntry>> {
        self.entries.write().await
    }

    async fn set_interaction_responder(
        &self,
        id: Uuid,
        responder: mpsc::Sender<AdapterInteractionResponse>,
    ) {
        self.interaction_responders
            .write()
            .await
            .insert(id, responder);
    }

    async fn interaction_responder(
        &self,
        id: Uuid,
    ) -> Option<mpsc::Sender<AdapterInteractionResponse>> {
        self.interaction_responders.read().await.get(&id).cloned()
    }

    async fn clear_interaction_responder(&self, id: Uuid) {
        self.interaction_responders.write().await.remove(&id);
    }

    async fn persist_task(&self, id: Uuid) -> Result<()> {
        let _guard = self.persistence_lock.lock().await;
        let task = {
            let entries = self.entries.read().await;
            entries.get(&id).map(PersistedTask::from_entry)
        };
        let Some(task) = task else {
            return Ok(());
        };
        let persistence = self.persistence.clone();
        tokio::task::spawn_blocking(move || persistence.write(&task))
            .await
            .context("task state writer stopped unexpectedly")?
    }

    async fn remove_persisted_task(&self, id: Uuid) -> Result<()> {
        let _guard = self.persistence_lock.lock().await;
        let persistence = self.persistence.clone();
        tokio::task::spawn_blocking(move || persistence.remove(id))
            .await
            .context("task state remover stopped unexpectedly")?
    }
}

type SharedTaskStore = Arc<TaskStore>;
type AdapterStore = Arc<RwLock<HashMap<String, AdapterRegistration>>>;

pub async fn serve(config: DaemonConfig, shutdown: impl Future<Output = ()> + Send) -> Result<()> {
    let adapters = Arc::new(RwLock::new(validate_adapters(config.adapters)?));
    let persistence = TaskPersistence::prepare(config.state_directory)?;
    let mut restored_tasks = persistence.load()?;
    let interrupted_tasks = recover_interrupted_tasks(&mut restored_tasks);
    prepare_socket_directory(&config.socket_path)?;
    let _socket_lock = SocketLock::acquire(&config.socket_path)?;
    prepare_socket_path(&config.socket_path).await?;
    let listener = UnixListener::bind(&config.socket_path)
        .with_context(|| format!("failed to bind socket {}", config.socket_path.display()))?;
    std::fs::set_permissions(&config.socket_path, std::fs::Permissions::from_mode(0o600))
        .with_context(|| {
            format!(
                "failed to set socket permissions {}",
                config.socket_path.display()
            )
        })?;
    let _socket_guard = SocketGuard::new(&config.socket_path)?;
    let tasks = Arc::new(TaskStore::new(restored_tasks, persistence));
    for id in interrupted_tasks {
        tasks.persist_task(id).await?;
    }
    let scheduler_tasks = tasks.clone();
    let scheduler_adapters = adapters.clone();
    let chain_scheduler = tokio::spawn(async move {
        loop {
            scheduler_tasks.chain_notify.notified().await;
            advance_pending_chains(&scheduler_tasks, &scheduler_adapters).await;
        }
    });
    tasks.chain_notify.notify_one();
    let client_slots = Arc::new(Semaphore::new(MAX_CLIENT_CONNECTIONS));
    let mut client_tasks = JoinSet::new();
    let shutdown_requested = Arc::new(Notify::new());

    tokio::pin!(shutdown);
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _)) => {
                        let Ok(permit) = client_slots.clone().try_acquire_owned() else {
                            continue;
                        };
                        let tasks = tasks.clone();
                        let adapters = adapters.clone();
                        let shutdown_requested = shutdown_requested.clone();
                        client_tasks.spawn(async move {
                            let _permit = permit;
                            if let Err(error) = handle_connection(
                                stream,
                                tasks,
                                adapters,
                                shutdown_requested,
                            )
                            .await
                            {
                                eprintln!("client connection failed: {error:#}");
                            }
                        });
                    }
                    Err(error) => {
                        eprintln!("failed to accept client: {error}");
                        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    }
                }
            }
            _ = client_tasks.join_next(), if !client_tasks.is_empty() => {}
            () = shutdown_requested.notified() => break,
            () = &mut shutdown => break,
        }
    }

    client_tasks.shutdown().await;
    chain_scheduler.abort();
    let _ = chain_scheduler.await;
    shutdown_tasks(&tasks).await;
    Ok(())
}

pub async fn send_request(socket_path: &Path, request: &DaemonRequest) -> Result<DaemonResponse> {
    let stream = tokio::time::timeout(CLIENT_REQUEST_TIMEOUT, UnixStream::connect(socket_path))
        .await
        .context("timed out connecting to daemon")?
        .with_context(|| format!("failed to connect to {}", socket_path.display()))?;
    let (read_half, mut write_half) = stream.into_split();
    let mut request_json = serde_json::to_vec(request).context("failed to encode request")?;
    if request_json.len() > MAX_LINE_BYTES {
        bail!("request exceeds {MAX_LINE_BYTES} bytes");
    }
    request_json.push(b'\n');
    tokio::time::timeout(CLIENT_REQUEST_TIMEOUT, write_half.write_all(&request_json))
        .await
        .context("timed out writing request")?
        .context("failed to write request")?;
    tokio::time::timeout(CLIENT_REQUEST_TIMEOUT, write_half.shutdown())
        .await
        .context("timed out finishing request")?
        .context("failed to finish request")?;

    let mut reader = BufReader::new(read_half);
    let response_line =
        tokio::time::timeout(CLIENT_REQUEST_TIMEOUT, read_bounded_line(&mut reader))
            .await
            .context("timed out reading response")?
            .context("failed to read response")?
            .ok_or_else(|| anyhow!("daemon closed the connection without a response"))?;
    serde_json::from_slice(&response_line).context("failed to decode daemon response")
}

async fn handle_connection(
    stream: UnixStream,
    tasks: SharedTaskStore,
    adapters: AdapterStore,
    shutdown_requested: Arc<Notify>,
) -> Result<()> {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut should_shutdown = false;
    let response =
        match tokio::time::timeout(CLIENT_REQUEST_TIMEOUT, read_bounded_line(&mut reader)).await {
            Err(_) => error_response("request_timeout", "request was not sent in time"),
            Ok(Ok(None)) => error_response("invalid_request", "request is empty"),
            Ok(Err(error)) if error.kind() == std::io::ErrorKind::InvalidData => {
                error_response("request_too_large", &error.to_string())
            }
            Ok(Err(error)) => return Err(error).context("failed to read request"),
            Ok(Ok(Some(request_line))) => {
                match serde_json::from_slice::<DaemonRequest>(&request_line) {
                    Ok(request) => {
                        should_shutdown = matches!(request, DaemonRequest::Shutdown);
                        process_request(request, tasks, adapters).await
                    }
                    Err(error) => error_response("invalid_request", &error.to_string()),
                }
            }
        };

    let mut response_json = serde_json::to_vec(&response).context("failed to encode response")?;
    if response_json.len() > MAX_LINE_BYTES {
        response_json = serde_json::to_vec(&error_response(
            "response_too_large",
            "response exceeds the protocol frame limit",
        ))?;
    }
    response_json.push(b'\n');
    tokio::time::timeout(CLIENT_REQUEST_TIMEOUT, write_half.write_all(&response_json))
        .await
        .context("timed out writing response")?
        .context("failed to write response")?;
    if should_shutdown {
        shutdown_requested.notify_one();
    }
    Ok(())
}

async fn process_request(
    request: DaemonRequest,
    tasks: SharedTaskStore,
    adapters: AdapterStore,
) -> DaemonResponse {
    match request {
        DaemonRequest::Ping => DaemonResponse::Pong {
            protocol_version: PROTOCOL_VERSION,
            daemon_version: env!("CARGO_PKG_VERSION").to_owned(),
            adapters: {
                let mut ids = adapters.read().await.keys().cloned().collect::<Vec<_>>();
                ids.sort();
                ids
            },
        },
        DaemonRequest::StartTask {
            id,
            adapter_id,
            prompt,
            cwd,
            options,
        } => start_task(id, adapter_id, prompt, cwd, options, tasks, adapters).await,
        DaemonRequest::StartChain {
            id,
            prompt,
            cwd,
            steps,
            note,
        } => start_chain(id, prompt, cwd, steps, note, tasks, adapters).await,
        DaemonRequest::ContinueTask {
            id,
            prompt,
            options,
        } => continue_task(id, prompt, options, tasks, adapters).await,
        DaemonRequest::GetTask { id } => {
            let tasks = tasks.read().await;
            match tasks.get(&id) {
                Some(entry) => DaemonResponse::Task {
                    task: entry.snapshot.clone(),
                },
                None => error_response("task_not_found", &format!("task {id} was not found")),
            }
        }
        DaemonRequest::ListTasks => {
            let tasks = tasks.read().await;
            let mut snapshots = tasks
                .values()
                .map(|entry| entry.snapshot.clone())
                .collect::<Vec<_>>();
            snapshots.sort_by_key(|task| (task.created_at_ms, task.id));
            DaemonResponse::Tasks { tasks: snapshots }
        }
        DaemonRequest::GetTaskOutput { id } => {
            let tasks = tasks.read().await;
            match tasks.get(&id) {
                Some(entry) => DaemonResponse::TaskOutput {
                    task_id: id,
                    output: entry.output.clone(),
                    truncated: entry.output_truncated,
                },
                None => error_response("task_not_found", &format!("task {id} was not found")),
            }
        }
        DaemonRequest::CancelTask { id } => cancel_task(id, tasks).await,
        DaemonRequest::DeleteTask { id } => delete_task(id, tasks).await,
        DaemonRequest::RenameTask { id, title } => rename_task(id, title, tasks).await,
        DaemonRequest::RespondToInteraction { id, response } => {
            respond_to_interaction(id, response, tasks).await
        }
        DaemonRequest::RegisterAdapter {
            id,
            executable,
            environment,
        } => register_adapter(id, executable, environment, tasks, adapters).await,
        DaemonRequest::UnregisterAdapter { id } => unregister_adapter(id, adapters).await,
        DaemonRequest::Shutdown => DaemonResponse::ShuttingDown,
    }
}

async fn start_task(
    id: Uuid,
    adapter_id: String,
    prompt: String,
    cwd: PathBuf,
    options: BTreeMap<String, String>,
    tasks: SharedTaskStore,
    adapters: AdapterStore,
) -> DaemonResponse {
    start_task_inner(
        id,
        ChainStep {
            adapter_id,
            options,
        },
        prompt,
        cwd,
        None,
        tasks,
        adapters,
    )
    .await
}

async fn start_chain(
    id: Uuid,
    prompt: String,
    cwd: PathBuf,
    steps: Vec<ChainStep>,
    note: Option<String>,
    tasks: SharedTaskStore,
    adapters: AdapterStore,
) -> DaemonResponse {
    if let Some(entry) = tasks.read().await.get(&id) {
        return DaemonResponse::Task {
            task: entry.snapshot.clone(),
        };
    }
    let context = match prepare_chain_context(id, steps, note, &adapters).await {
        Ok(context) => context,
        Err(message) => return error_response("invalid_chain", &message),
    };
    let first = context.steps[0].clone();
    let options = match chain_step_options(&context, first.options.clone()) {
        Ok(options) => options,
        Err(message) => return error_response("invalid_chain", message),
    };
    start_task_inner(
        id,
        ChainStep {
            adapter_id: first.adapter_id,
            options,
        },
        prompt,
        cwd,
        Some(context),
        tasks,
        adapters,
    )
    .await
}

async fn start_task_inner(
    id: Uuid,
    step: ChainStep,
    prompt: String,
    cwd: PathBuf,
    chain: Option<ChainContext>,
    tasks: SharedTaskStore,
    adapters: AdapterStore,
) -> DaemonResponse {
    let ChainStep {
        adapter_id,
        options,
    } = step;
    if id.is_nil() {
        return error_response("invalid_task_id", "task ID must not be nil");
    }
    if let Some(entry) = tasks.read().await.get(&id) {
        return DaemonResponse::Task {
            task: entry.snapshot.clone(),
        };
    }
    if !valid_adapter_id(&adapter_id) {
        return error_response("invalid_adapter_id", "adapter ID is invalid");
    }
    let Some(adapter) = adapters.read().await.get(&adapter_id).cloned() else {
        return error_response(
            "adapter_not_found",
            &format!("adapter {adapter_id} is not registered"),
        );
    };
    if prompt.trim().is_empty() {
        return error_response("invalid_prompt", "prompt must not be empty");
    }
    if prompt.len() > MAX_PROMPT_BYTES {
        return error_response("invalid_prompt", "prompt is too large");
    }
    if let Err(message) = validate_adapter_options(&options) {
        return error_response("invalid_adapter_options", message);
    }
    if !cwd.is_absolute() {
        return error_response("invalid_cwd", "cwd must be absolute");
    }
    let cwd = match std::fs::canonicalize(&cwd) {
        Ok(path) if path.is_dir() => path,
        Ok(_) => return error_response("invalid_cwd", "cwd must be a directory"),
        Err(error) => return error_response("invalid_cwd", &error.to_string()),
    };
    let Some(cwd_text) = cwd.to_str() else {
        return error_response("invalid_cwd", "cwd must be valid UTF-8");
    };
    if cwd_text.len() > MAX_CWD_BYTES {
        return error_response("invalid_cwd", "cwd is too long");
    }

    let now = timestamp_ms();
    let snapshot = TaskSnapshot {
        id,
        adapter_id,
        prompt_preview: bounded_summary(&prompt, MAX_PROMPT_PREVIEW_BYTES),
        title: None,
        pending_interaction: None,
        cwd,
        status: TaskStatus::Queued,
        created_at_ms: now,
        updated_at_ms: now,
        latest_message: None,
        session_id: None,
        turn_count: 1,
        adapter_options: options,
    };
    let (cancel_sender, cancel_receiver) = oneshot::channel();
    let mut task_entries = tasks.write().await;
    if let Some(entry) = task_entries.get(&id) {
        return DaemonResponse::Task {
            task: entry.snapshot.clone(),
        };
    }
    if task_entries
        .values()
        .filter(|entry| !entry.snapshot.status.is_terminal())
        .count()
        >= MAX_ACTIVE_TASKS
    {
        return error_response("task_capacity", "too many tasks are currently active");
    }
    if task_entries.len() >= MAX_STORED_TASKS {
        let oldest_terminal = task_entries
            .iter()
            .filter(|(_, entry)| {
                entry.snapshot.status.is_terminal()
                    && !entry.response_pending
                    && entry.runner.as_ref().is_none_or(JoinHandle::is_finished)
            })
            .min_by_key(|(_, entry)| (entry.snapshot.created_at_ms, entry.snapshot.id))
            .map(|(id, _)| *id);
        let Some(oldest_terminal) = oldest_terminal else {
            return error_response("task_capacity", "task history is full");
        };
        if let Err(error) = tasks.remove_persisted_task(oldest_terminal).await {
            return error_response("state_persistence_failed", &error.to_string());
        }
        task_entries.remove(&oldest_terminal);
    }
    let mut entry = TaskEntry {
        snapshot: snapshot.clone(),
        prompt: prompt.clone(),
        output: Vec::new(),
        output_bytes: 0,
        output_truncated: false,
        next_output_sequence: 0,
        cancel: Some(cancel_sender),
        runner: None,
        response_pending: false,
        chain,
    };
    append_task_output(&mut entry, TaskOutputKind::User, prompt);
    task_entries.insert(id, entry);
    drop(task_entries);

    if let Err(error) = tasks.persist_task(id).await {
        tasks.write().await.remove(&id);
        let _ = tasks.remove_persisted_task(id).await;
        return error_response("state_persistence_failed", &error.to_string());
    }

    let task_store = tasks.clone();
    let runner = tokio::spawn(async move {
        run_adapter_task(id, adapter, task_store, cancel_receiver).await;
    });
    tasks.write().await.get_mut(&id).unwrap().runner = Some(runner);

    DaemonResponse::Task { task: snapshot }
}

async fn continue_task(
    id: Uuid,
    prompt: String,
    options: BTreeMap<String, String>,
    tasks: SharedTaskStore,
    adapters: AdapterStore,
) -> DaemonResponse {
    if prompt.trim().is_empty() {
        return error_response("invalid_prompt", "prompt must not be empty");
    }
    if prompt.len() > MAX_PROMPT_BYTES {
        return error_response("invalid_prompt", "prompt is too large");
    }
    if let Err(message) = validate_adapter_options(&options) {
        return error_response("invalid_adapter_options", message);
    }

    let mut task_entries = tasks.write().await;
    let Some(existing) = task_entries.get(&id) else {
        return error_response("task_not_found", &format!("task {id} was not found"));
    };
    if !existing.snapshot.status.is_terminal() {
        return error_response("task_active", "task is still running");
    }
    if existing.snapshot.session_id.is_none() {
        return error_response("session_unavailable", "task has no resumable CLI session");
    }
    if task_entries
        .values()
        .filter(|entry| !entry.snapshot.status.is_terminal())
        .count()
        >= MAX_ACTIVE_TASKS
    {
        return error_response("task_capacity", "too many tasks are currently active");
    }
    let adapter_id = existing.snapshot.adapter_id.clone();
    let chain = existing.chain.clone();
    let Some(adapter) = adapters.read().await.get(&adapter_id).cloned() else {
        return error_response(
            "adapter_not_found",
            &format!("adapter {adapter_id} is not registered"),
        );
    };
    let replacement_options = if options.is_empty() {
        None
    } else if let Some(chain) = &chain {
        match chain_step_options(chain, options) {
            Ok(options) => Some(options),
            Err(message) => return error_response("invalid_adapter_options", message),
        }
    } else {
        Some(options)
    };

    let (cancel_sender, cancel_receiver) = oneshot::channel();
    let entry = task_entries.get_mut(&id).unwrap();
    entry.prompt = prompt.clone();
    entry.snapshot.status = TaskStatus::Queued;
    touch_task(entry);
    entry.snapshot.latest_message = Some("continuation queued".to_owned());
    entry.snapshot.turn_count = entry.snapshot.turn_count.saturating_add(1);
    if let Some(options) = replacement_options {
        entry.snapshot.adapter_options = options;
    }
    entry.cancel = Some(cancel_sender);
    entry.response_pending = false;
    append_task_output(entry, TaskOutputKind::User, prompt);
    let snapshot = entry.snapshot.clone();
    drop(task_entries);

    if let Err(error) = tasks.persist_task(id).await {
        let message = format!("failed to persist continuation: {error}");
        let mut task_entries = tasks.write().await;
        if let Some(entry) = task_entries.get_mut(&id) {
            entry.snapshot.status = TaskStatus::Failed;
            touch_task(entry);
            entry.snapshot.latest_message =
                Some(bounded_summary(&message, MAX_STATUS_MESSAGE_BYTES));
            append_task_output(entry, TaskOutputKind::Error, message);
            entry.prompt.clear();
            entry.cancel = None;
        }
        return error_response("state_persistence_failed", &error.to_string());
    }

    let task_store = tasks.clone();
    let runner = tokio::spawn(async move {
        run_adapter_task(id, adapter, task_store, cancel_receiver).await;
    });
    tasks.write().await.get_mut(&id).unwrap().runner = Some(runner);

    DaemonResponse::Task { task: snapshot }
}

async fn cancel_task(id: Uuid, tasks: SharedTaskStore) -> DaemonResponse {
    let acknowledgment = {
        let mut tasks = tasks.write().await;
        let Some(entry) = tasks.get_mut(&id) else {
            return error_response("task_not_found", &format!("task {id} was not found"));
        };
        if entry.snapshot.status.is_terminal() {
            return DaemonResponse::Task {
                task: entry.snapshot.clone(),
            };
        }
        let Some(cancel) = entry.cancel.take() else {
            return error_response(
                "cancellation_in_progress",
                "task cancellation is in progress",
            );
        };
        let (acknowledged, acknowledgment) = oneshot::channel();
        let _ = cancel.send(CancelRequest { acknowledged });
        entry.response_pending = true;
        touch_task(entry);
        entry.snapshot.latest_message = Some("cancellation requested".to_owned());
        acknowledgment
    };

    if let Err(error) = tasks.persist_task(id).await {
        eprintln!("failed to persist cancellation request for {id}: {error:#}");
    }

    let outcome = acknowledgment.await;
    let mut tasks = tasks.write().await;
    let Some(entry) = tasks.get_mut(&id) else {
        return error_response("task_not_found", &format!("task {id} was not found"));
    };
    entry.response_pending = false;
    match outcome {
        Ok(Err(message)) => error_response("cancel_failed", &message),
        Ok(Ok(())) | Err(_) if entry.snapshot.status.is_terminal() => DaemonResponse::Task {
            task: entry.snapshot.clone(),
        },
        Ok(Ok(())) | Err(_) => {
            error_response("cancel_failed", "adapter did not acknowledge cancellation")
        }
    }
}

async fn delete_task(id: Uuid, tasks: SharedTaskStore) -> DaemonResponse {
    let mut entries = tasks.write().await;
    let Some(entry) = entries.get(&id) else {
        return error_response("task_not_found", &format!("task {id} was not found"));
    };
    if !entry.snapshot.status.is_terminal() {
        return error_response(
            "task_active",
            "active tasks must be canceled before deletion",
        );
    }
    if entry.response_pending
        || entry
            .runner
            .as_ref()
            .is_some_and(|runner| !runner.is_finished())
    {
        return error_response(
            "task_cleanup_in_progress",
            "task cleanup is still in progress",
        );
    }
    if let Err(error) = tasks.remove_persisted_task(id).await {
        return error_response("state_persistence_failed", &error.to_string());
    }
    entries.remove(&id);
    DaemonResponse::TaskDeleted { task_id: id }
}

async fn rename_task(id: Uuid, title: String, tasks: SharedTaskStore) -> DaemonResponse {
    let title = match normalized_task_title(&title) {
        Ok(title) => title,
        Err(message) => return error_response("invalid_task_title", message),
    };
    let (previous_title, snapshot) = {
        let mut entries = tasks.write().await;
        let Some(entry) = entries.get_mut(&id) else {
            return error_response("task_not_found", &format!("task {id} was not found"));
        };
        let previous_title = entry.snapshot.title.replace(title.clone());
        (previous_title, entry.snapshot.clone())
    };
    if let Err(error) = tasks.persist_task(id).await {
        let mut entries = tasks.write().await;
        if let Some(entry) = entries.get_mut(&id)
            && entry.snapshot.title.as_deref() == Some(title.as_str())
        {
            entry.snapshot.title = previous_title;
        }
        return error_response("state_persistence_failed", &error.to_string());
    }
    DaemonResponse::Task { task: snapshot }
}

async fn respond_to_interaction(
    id: Uuid,
    response: AdapterInteractionResponse,
    tasks: SharedTaskStore,
) -> DaemonResponse {
    let Some(responder) = tasks.interaction_responder(id).await else {
        return error_response(
            "interaction_unavailable",
            "task does not have a live interaction channel",
        );
    };
    let snapshot = {
        let mut entries = tasks.write().await;
        let Some(entry) = entries.get_mut(&id) else {
            return error_response("task_not_found", &format!("task {id} was not found"));
        };
        let Some(interaction) = entry.snapshot.pending_interaction.as_ref() else {
            return error_response(
                "interaction_not_pending",
                "task is not waiting for a response",
            );
        };
        if response.interaction_id != interaction.id {
            return error_response(
                "interaction_mismatch",
                "interaction response does not match the pending request",
            );
        }
        if let Err(error) = validate_interaction_response(interaction, &response) {
            return error_response("invalid_interaction_response", &error.to_string());
        }
        if let Err(error) = responder.try_send(response) {
            return error_response(
                "interaction_unavailable",
                &format!("failed to send interaction response: {error}"),
            );
        }
        entry.snapshot.pending_interaction = None;
        entry.snapshot.status = TaskStatus::Running;
        touch_task(entry);
        entry.snapshot.latest_message = Some("interaction response submitted".to_owned());
        append_task_output(
            entry,
            TaskOutputKind::System,
            "Interaction response submitted".to_owned(),
        );
        entry.snapshot.clone()
    };
    if let Err(error) = tasks.persist_task(id).await {
        eprintln!("failed to persist interaction response for {id}: {error:#}");
    }
    DaemonResponse::Task { task: snapshot }
}

async fn register_adapter(
    id: String,
    executable: PathBuf,
    environment: BTreeMap<String, String>,
    tasks: SharedTaskStore,
    adapters: AdapterStore,
) -> DaemonResponse {
    let registration = match validate_adapter(AdapterRegistration {
        id,
        executable,
        environment,
    }) {
        Ok(registration) => registration,
        Err(error) => return error_response("invalid_adapter", &error.to_string()),
    };
    let adapter_id = registration.id.clone();
    adapters
        .write()
        .await
        .insert(adapter_id.clone(), registration);
    advance_pending_chains(&tasks, &adapters).await;
    DaemonResponse::AdapterRegistered { adapter_id }
}

async fn unregister_adapter(id: String, adapters: AdapterStore) -> DaemonResponse {
    if !valid_adapter_id(&id) {
        return error_response("invalid_adapter_id", "adapter ID is invalid");
    }
    adapters.write().await.remove(&id);
    DaemonResponse::AdapterUnregistered { adapter_id: id }
}

async fn run_adapter_task(
    id: Uuid,
    adapter: AdapterRegistration,
    tasks: SharedTaskStore,
    cancel: oneshot::Receiver<CancelRequest>,
) {
    let (interaction_responder, interaction_responses) = mpsc::channel(1);
    tasks
        .set_interaction_responder(id, interaction_responder)
        .await;
    run_adapter_task_inner(id, adapter, tasks.clone(), cancel, interaction_responses).await;
    tasks.clear_interaction_responder(id).await;
    tasks.chain_notify.notify_one();
}

async fn run_adapter_task_inner(
    id: Uuid,
    adapter: AdapterRegistration,
    tasks: SharedTaskStore,
    mut cancel: oneshot::Receiver<CancelRequest>,
    mut interaction_responses: mpsc::Receiver<AdapterInteractionResponse>,
) {
    let Some((snapshot, prompt)) = task_input(&tasks, id).await else {
        return;
    };
    match cancel.try_recv() {
        Ok(request) => {
            finish_cancellation(&tasks, id, Some(request), Ok(())).await;
            return;
        }
        Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
            fail_task(&tasks, id, "cancellation channel closed".to_owned()).await;
            return;
        }
        Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {}
    }
    let mut command = Command::new(&adapter.executable);
    command
        .arg("run")
        .envs(&adapter.environment)
        .current_dir(&snapshot.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .process_group(0);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            fail_task(&tasks, id, format!("failed to start adapter: {error}")).await;
            return;
        }
    };
    let process_group = child.id().and_then(|pid| i32::try_from(pid).ok());

    let stderr_task = child
        .stderr
        .take()
        .map(|stderr| tokio::spawn(drain_stderr(stderr)));
    let request = AdapterRunRequest {
        protocol_version: PROTOCOL_VERSION,
        task_id: id,
        prompt,
        cwd: snapshot.cwd,
        session_id: snapshot.session_id,
        options: snapshot.adapter_options,
    };
    let Some(mut stdin) = child.stdin.take() else {
        fail_and_terminate(
            &mut child,
            process_group,
            &tasks,
            id,
            "adapter stdin is unavailable".to_owned(),
        )
        .await;
        return;
    };
    let (cancellation, write_result) = {
        let write_request = async {
            let mut json =
                serde_json::to_vec(&request).context("failed to encode adapter request")?;
            json.push(b'\n');
            stdin
                .write_all(&json)
                .await
                .context("failed to write adapter request")?;
            Result::<()>::Ok(())
        };
        tokio::pin!(write_request);
        tokio::select! {
            biased;
            request = &mut cancel => (Some(request), None),
            result = &mut write_request => (None, Some(result)),
        }
    };
    if let Some(request) = cancellation {
        let result = terminate_child(&mut child, process_group)
            .await
            .map_err(|error| error.to_string());
        finish_cancellation(&tasks, id, request.ok(), result).await;
        return;
    }
    match write_result {
        Some(Err(error)) => {
            fail_and_terminate(&mut child, process_group, &tasks, id, error.to_string()).await;
            return;
        }
        Some(Ok(())) => {}
        None => unreachable!(),
    }

    let Some(stdout) = child.stdout.take() else {
        fail_and_terminate(
            &mut child,
            process_group,
            &tasks,
            id,
            "adapter stdout is unavailable".to_owned(),
        )
        .await;
        return;
    };
    let mut reader = BufReader::new(stdout);
    let mut terminal_event = None;

    loop {
        tokio::select! {
            biased;
            request = &mut cancel => {
                let result = terminate_child(&mut child, process_group)
                    .await
                    .map_err(|error| error.to_string());
                finish_cancellation(&tasks, id, request.ok(), result).await;
                return;
            }
            response = interaction_responses.recv() => {
                let Some(response) = response else {
                    fail_and_terminate(&mut child, process_group, &tasks, id, "interaction response channel closed".to_owned()).await;
                    return;
                };
                let mut json = match serde_json::to_vec(&response) {
                    Ok(json) => json,
                    Err(error) => {
                        fail_and_terminate(&mut child, process_group, &tasks, id, format!("failed to encode interaction response: {error}")).await;
                        return;
                    }
                };
                json.push(b'\n');
                if let Err(error) = stdin.write_all(&json).await {
                    fail_and_terminate(&mut child, process_group, &tasks, id, format!("failed to write interaction response: {error}")).await;
                    return;
                }
            }
            line = read_bounded_line(&mut reader) => {
                match line {
                    Ok(Some(line)) => {
                        let event = match serde_json::from_slice::<AdapterEvent>(&line) {
                            Ok(event) => event,
                            Err(error) => {
                                fail_and_terminate(&mut child, process_group, &tasks, id, format!("invalid adapter event: {error}")).await;
                                return;
                            }
                        };
                        if event.task_id != id {
                            fail_and_terminate(&mut child, process_group, &tasks, id, "adapter event task ID does not match".to_owned()).await;
                            return;
                        }
                        if let Err(error) = validate_adapter_event(&event) {
                            fail_and_terminate(&mut child, process_group, &tasks, id, format!("invalid adapter event: {error}")).await;
                            return;
                        }
                        if terminal_event.is_some() {
                            fail_and_terminate(&mut child, process_group, &tasks, id, "adapter emitted an event after a terminal event".to_owned()).await;
                            return;
                        }
                        if event.status.is_terminal() {
                            terminal_event = Some(event);
                        } else {
                            apply_event(&tasks, event).await;
                        }
                    }
                    Ok(None) => break,
                    Err(error) => {
                        fail_and_terminate(&mut child, process_group, &tasks, id, format!("failed to read adapter event: {error}")).await;
                        return;
                    }
                }
            }
        }
    }

    drop(stdin);

    let wait_result = tokio::select! {
        biased;
        request = &mut cancel => {
            let result = terminate_child(&mut child, process_group)
                .await
                .map_err(|error| error.to_string());
            finish_cancellation(&tasks, id, request.ok(), result).await;
            return;
        }
        result = child.wait() => result,
    };
    let status = match wait_result {
        Ok(status) => status,
        Err(error) => {
            fail_task(&tasks, id, format!("failed to wait for adapter: {error}")).await;
            return;
        }
    };
    if let Some(process_group) = process_group {
        match signal_process_group(process_group) {
            Ok(()) => {
                if let Err(error) = wait_for_process_group_exit(process_group).await {
                    fail_task(
                        &tasks,
                        id,
                        format!("failed to clean up adapter descendants: {error}"),
                    )
                    .await;
                    return;
                }
            }
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {}
            Err(error) => {
                fail_task(
                    &tasks,
                    id,
                    format!("failed to clean up adapter descendants: {error}"),
                )
                .await;
                return;
            }
        }
    }
    if let Err(error) = wait_for_stderr(stderr_task).await {
        fail_task(&tasks, id, error.to_string()).await;
        return;
    }
    if !status.success() {
        fail_task(&tasks, id, format!("adapter exited with {status}")).await;
    } else {
        match terminal_event {
            Some(event) => {
                apply_event(&tasks, event).await;
                clear_cancel_sender(&tasks, id).await;
            }
            None => {
                fail_task(
                    &tasks,
                    id,
                    "adapter exited without a terminal event".to_owned(),
                )
                .await;
            }
        }
    }
}

async fn fail_and_terminate(
    child: &mut Child,
    process_group: Option<i32>,
    tasks: &TaskStore,
    id: Uuid,
    message: String,
) {
    let message = match terminate_child(child, process_group).await {
        Ok(()) => message,
        Err(error) => {
            format!("{message}; failed to stop adapter: {error}")
        }
    };
    fail_task(tasks, id, message).await;
}

async fn terminate_child(child: &mut Child, process_group: Option<i32>) -> Result<()> {
    let group_result = process_group.map(signal_process_group);
    let group_signal_sent = matches!(group_result, Some(Ok(())));
    let group_error = match group_result {
        Some(Err(error)) if error.raw_os_error() != Some(libc::ESRCH) => Some(error),
        _ => None,
    };
    if !group_signal_sent {
        let kill_result = child.kill().await;
        if let Err(error) = kill_result
            && child.try_wait()?.is_none()
        {
            return Err(error).context("failed to kill adapter process");
        }
    }
    child
        .wait()
        .await
        .context("failed to reap adapter process")?;
    if let Some(error) = group_error {
        let Some(process_group) = process_group else {
            return Err(error).context("failed to kill adapter process group");
        };
        return wait_for_process_group_exit(process_group)
            .await
            .with_context(|| format!("failed to kill adapter process group: {error}"));
    }
    if group_signal_sent && let Some(process_group) = process_group {
        wait_for_process_group_exit(process_group).await?;
    }
    Ok(())
}

fn signal_process_group(process_group: i32) -> std::io::Result<()> {
    // この子プロセス専用に作成したプロセスグループだけを終了する。
    let result = unsafe { libc::kill(-process_group, libc::SIGKILL) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

async fn wait_for_process_group_exit(process_group: i32) -> Result<()> {
    let deadline = tokio::time::Instant::now() + PROCESS_GROUP_EXIT_TIMEOUT;
    loop {
        if !process_group_exists(process_group)? {
            return Ok(());
        }
        // 最初の SIGKILL と fork が競合して遅れて現れた子プロセスも同じ専用グループで止める。
        match signal_process_group(process_group) {
            Ok(()) => {}
            Err(error) if error.raw_os_error() == Some(libc::ESRCH) => return Ok(()),
            Err(error) => return Err(error).context("failed to kill adapter process group"),
        }
        if tokio::time::Instant::now() >= deadline {
            bail!("adapter process group {process_group} did not exit after termination request");
        }
        tokio::time::sleep(PROCESS_GROUP_POLL_INTERVAL).await;
    }
}

fn process_group_exists(process_group: i32) -> std::io::Result<bool> {
    let result = unsafe { libc::kill(-process_group, 0) };
    if result == 0 {
        #[cfg(target_os = "macos")]
        return macos_process_group_has_live_members(process_group);
        #[cfg(not(target_os = "macos"))]
        return Ok(true);
    }
    let error = std::io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::ESRCH) => Ok(false),
        Some(libc::EPERM) => Ok(true),
        _ => Err(error),
    }
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct MacOSProcBsdShortInfo {
    pid: u32,
    parent_pid: u32,
    process_group: u32,
    status: u32,
    command: [libc::c_char; 16],
    flags: u32,
    uid: libc::uid_t,
    gid: libc::gid_t,
    real_uid: libc::uid_t,
    real_gid: libc::gid_t,
    saved_uid: libc::uid_t,
    saved_gid: libc::gid_t,
    reserved: u32,
}

#[cfg(target_os = "macos")]
#[link(name = "proc")]
unsafe extern "C" {
    fn proc_listpids(
        process_type: u32,
        type_info: u32,
        buffer: *mut libc::c_void,
        buffer_size: libc::c_int,
    ) -> libc::c_int;
    fn proc_pidinfo(
        pid: libc::c_int,
        flavor: libc::c_int,
        argument: u64,
        buffer: *mut libc::c_void,
        buffer_size: libc::c_int,
    ) -> libc::c_int;
}

#[cfg(target_os = "macos")]
fn macos_process_group_has_live_members(process_group: i32) -> std::io::Result<bool> {
    const PROC_PGRP_ONLY: u32 = 2;
    const PROC_PIDT_SHORTBSDINFO: libc::c_int = 13;
    let required = unsafe {
        proc_listpids(
            PROC_PGRP_ONLY,
            process_group as u32,
            std::ptr::null_mut(),
            0,
        )
    };
    if required <= 0 {
        return Ok(false);
    }
    let mut pids = vec![0_i32; required as usize / std::mem::size_of::<i32>() + 16];
    let bytes = unsafe {
        proc_listpids(
            PROC_PGRP_ONLY,
            process_group as u32,
            pids.as_mut_ptr().cast(),
            (pids.len() * std::mem::size_of::<i32>()) as libc::c_int,
        )
    };
    if bytes < 0 {
        return Err(std::io::Error::last_os_error());
    }
    pids.truncate(bytes as usize / std::mem::size_of::<i32>());

    for pid in pids.into_iter().filter(|pid| *pid > 0) {
        let mut info = std::mem::MaybeUninit::<MacOSProcBsdShortInfo>::uninit();
        let expected = std::mem::size_of::<MacOSProcBsdShortInfo>() as libc::c_int;
        let received = unsafe {
            proc_pidinfo(
                pid,
                PROC_PIDT_SHORTBSDINFO,
                0,
                info.as_mut_ptr().cast(),
                expected,
            )
        };
        if received == 0 {
            continue;
        }
        if received != expected {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "proc_pidinfo returned an unexpected record size",
            ));
        }
        let info = unsafe { info.assume_init() };
        // SIGKILL 済みのゾンビは実行できず、親プロセスからも回収できないため待機対象にしない。
        if info.status != libc::SZOMB {
            return Ok(true);
        }
    }
    Ok(false)
}

async fn wait_for_stderr(stderr_task: Option<JoinHandle<()>>) -> Result<()> {
    let Some(mut task) = stderr_task else {
        return Ok(());
    };
    match tokio::time::timeout(std::time::Duration::from_secs(1), &mut task).await {
        Ok(result) => result.context("adapter stderr reader failed"),
        Err(_) => {
            task.abort();
            bail!("adapter stderr remained open after the adapter exited")
        }
    }
}

async fn read_bounded_line<R>(reader: &mut R) -> std::io::Result<Option<Vec<u8>>>
where
    R: AsyncBufRead + Unpin,
{
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return if line.is_empty() {
                Ok(None)
            } else {
                Ok(Some(line))
            };
        }
        let newline = available.iter().position(|byte| *byte == b'\n');
        let payload_len = newline.unwrap_or(available.len());
        if line.len().saturating_add(payload_len) > MAX_LINE_BYTES {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("protocol line exceeds {MAX_LINE_BYTES} bytes"),
            ));
        }
        line.extend_from_slice(&available[..payload_len]);
        let consumed = payload_len + usize::from(newline.is_some());
        reader.consume(consumed);
        if newline.is_some() {
            return Ok(Some(line));
        }
    }
}

async fn drain_stderr(mut stderr: ChildStderr) {
    let mut buffer = [0_u8; 4096];
    loop {
        match stderr.read(&mut buffer).await {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
    }
}

async fn task_input(tasks: &TaskStore, id: Uuid) -> Option<(TaskSnapshot, String)> {
    tasks
        .read()
        .await
        .get(&id)
        .map(|entry| (entry.snapshot.clone(), entry.prompt.clone()))
}

async fn apply_event(tasks: &TaskStore, event: AdapterEvent) {
    let id = event.task_id;
    let mut entries = tasks.write().await;
    let Some(entry) = entries.get_mut(&id) else {
        return;
    };
    if entry.snapshot.status.is_terminal() {
        return;
    }
    entry.snapshot.status = event.status;
    entry.snapshot.pending_interaction = event.interaction.map(Box::new);
    if let Some(message) = event.message {
        entry.snapshot.latest_message = Some(bounded_summary(&message, MAX_STATUS_MESSAGE_BYTES));
    }
    if let Some(session_id) = event.session_id {
        entry.snapshot.session_id = Some(bounded_summary(&session_id, 256));
    }
    if let Some(output) = event.output {
        append_task_output(entry, output.kind, output.text);
    }
    touch_task(entry);
    if entry.snapshot.status.is_terminal() {
        entry.prompt.clear();
    }
    drop(entries);
    if let Err(error) = tasks.persist_task(id).await {
        eprintln!("failed to persist task event for {id}: {error:#}");
    }
}

async fn fail_task(tasks: &TaskStore, id: Uuid, message: String) {
    let mut entries = tasks.write().await;
    let Some(entry) = entries.get_mut(&id) else {
        return;
    };
    if entry.snapshot.status == TaskStatus::Canceled {
        return;
    }
    entry.snapshot.status = TaskStatus::Failed;
    entry.snapshot.pending_interaction = None;
    entry.snapshot.latest_message = Some(bounded_summary(&message, MAX_STATUS_MESSAGE_BYTES));
    touch_task(entry);
    append_task_output(entry, TaskOutputKind::Error, message);
    entry.prompt.clear();
    entry.cancel = None;
    drop(entries);
    if let Err(error) = tasks.persist_task(id).await {
        eprintln!("failed to persist failed task {id}: {error:#}");
    }
}

async fn set_canceled(tasks: &TaskStore, id: Uuid) {
    let mut entries = tasks.write().await;
    let Some(entry) = entries.get_mut(&id) else {
        return;
    };
    entry.snapshot.status = TaskStatus::Canceled;
    entry.snapshot.pending_interaction = None;
    touch_task(entry);
    entry.snapshot.latest_message = Some("task canceled".to_owned());
    append_task_output(entry, TaskOutputKind::System, "Task canceled".to_owned());
    entry.prompt.clear();
    entry.cancel = None;
    drop(entries);
    if let Err(error) = tasks.persist_task(id).await {
        eprintln!("failed to persist canceled task {id}: {error:#}");
    }
}

async fn finish_cancellation(
    tasks: &TaskStore,
    id: Uuid,
    request: Option<CancelRequest>,
    result: std::result::Result<(), String>,
) {
    match &result {
        Ok(()) => set_canceled(tasks, id).await,
        Err(message) => fail_task(tasks, id, format!("failed to stop adapter: {message}")).await,
    }
    if let Some(request) = request {
        let _ = request.acknowledged.send(result);
    }
}

async fn clear_cancel_sender(tasks: &TaskStore, id: Uuid) {
    let mut tasks = tasks.write().await;
    if let Some(entry) = tasks.get_mut(&id) {
        entry.cancel = None;
    }
}

async fn shutdown_tasks(tasks: &TaskStore) {
    let (acknowledgments, runners) = {
        let mut tasks = tasks.write().await;
        let mut acknowledgments = Vec::new();
        let mut runners = Vec::new();
        for entry in tasks.values_mut() {
            if let Some(cancel) = entry.cancel.take() {
                let (acknowledged, acknowledgment) = oneshot::channel();
                if cancel.send(CancelRequest { acknowledged }).is_ok() {
                    acknowledgments.push(acknowledgment);
                }
            }
            if let Some(runner) = entry.runner.take() {
                runners.push(runner);
            }
        }
        (acknowledgments, runners)
    };
    for acknowledgment in acknowledgments {
        let _ = acknowledgment.await;
    }
    for runner in runners {
        let _ = runner.await;
    }
}

fn validate_adapters(
    registrations: Vec<AdapterRegistration>,
) -> Result<HashMap<String, AdapterRegistration>> {
    let mut adapters = HashMap::new();
    for registration in registrations {
        let registration = validate_adapter(registration)?;
        if adapters.contains_key(&registration.id) {
            bail!("adapter {} is registered more than once", registration.id);
        }
        adapters.insert(registration.id.clone(), registration);
    }
    Ok(adapters)
}

fn validate_adapter(mut registration: AdapterRegistration) -> Result<AdapterRegistration> {
    if !valid_adapter_id(&registration.id) {
        bail!("adapter ID is invalid: {}", registration.id);
    }
    let executable = std::fs::canonicalize(&registration.executable).with_context(|| {
        format!(
            "adapter executable does not exist: {}",
            registration.executable.display()
        )
    })?;
    let metadata = std::fs::metadata(&executable)?;
    if !metadata.is_file()
        || metadata.permissions().mode() & 0o111 == 0
        || metadata.permissions().mode() & 0o022 != 0
    {
        bail!("adapter is not executable: {}", executable.display());
    }
    validate_path_owner(&metadata, &executable, true)?;
    if path_has_writable_acl(&executable)? {
        bail!("adapter has a writable ACL: {}", executable.display());
    }
    validate_path_ancestors(&executable)?;
    validate_adapter_environment(&registration.environment)?;
    registration.executable = executable;
    Ok(registration)
}

fn validate_adapter_environment(environment: &BTreeMap<String, String>) -> Result<()> {
    if environment.len() > MAX_ADAPTER_ENVIRONMENT {
        bail!("adapter environment has too many entries");
    }
    for (key, value) in environment {
        if key.len() > MAX_ADAPTER_ENVIRONMENT_KEY_BYTES
            || !key.starts_with("RELAY_")
            || !key
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
        {
            bail!("adapter environment key is invalid: {key}");
        }
        if value.is_empty()
            || value.len() > MAX_ADAPTER_ENVIRONMENT_VALUE_BYTES
            || !Path::new(value).is_absolute()
        {
            bail!("adapter environment value is invalid: {key}");
        }
    }
    Ok(())
}

fn validate_adapter_event(event: &AdapterEvent) -> Result<()> {
    match (&event.status, &event.interaction) {
        (TaskStatus::WaitingForApproval, Some(interaction))
            if interaction.kind == AdapterInteractionKind::Approval => {}
        (TaskStatus::WaitingForInput, Some(interaction))
            if interaction.kind == AdapterInteractionKind::Input => {}
        (TaskStatus::WaitingForApproval | TaskStatus::WaitingForInput, _) => {
            bail!("waiting status does not match its interaction")
        }
        (_, Some(_)) => bail!("interaction requires a waiting status"),
        (_, None) => {}
    }
    if let Some(interaction) = &event.interaction {
        validate_interaction(interaction)?;
    }
    Ok(())
}

fn validate_interaction(interaction: &AdapterInteraction) -> Result<()> {
    if interaction.id.is_empty() || interaction.id.len() > MAX_INTERACTION_ID_BYTES {
        bail!("interaction ID is invalid");
    }
    if interaction.title.is_empty() || interaction.title.len() > MAX_INTERACTION_TITLE_BYTES {
        bail!("interaction title is invalid");
    }
    if interaction.message.is_empty() || interaction.message.len() > MAX_INTERACTION_MESSAGE_BYTES {
        bail!("interaction message is invalid");
    }
    if interaction.actions.len() > MAX_INTERACTION_ACTIONS
        || interaction.questions.len() > MAX_INTERACTION_QUESTIONS
    {
        bail!("interaction has too many controls");
    }
    match interaction.kind {
        AdapterInteractionKind::Approval
            if interaction.actions.is_empty() || !interaction.questions.is_empty() =>
        {
            bail!("approval interaction controls are invalid")
        }
        AdapterInteractionKind::Input
            if !interaction.actions.is_empty() || interaction.questions.is_empty() =>
        {
            bail!("input interaction controls are invalid")
        }
        _ => {}
    }
    validate_interaction_options(&interaction.actions)?;
    let mut question_ids = HashMap::new();
    for question in &interaction.questions {
        if question.id.is_empty()
            || question.id.len() > MAX_INTERACTION_ID_BYTES
            || question.prompt.is_empty()
            || question.prompt.len() > MAX_INTERACTION_MESSAGE_BYTES
            || question.options.len() > MAX_INTERACTION_OPTIONS
        {
            bail!("interaction question is invalid");
        }
        if question_ids.insert(question.id.as_str(), ()).is_some() {
            bail!("interaction question IDs must be unique");
        }
        if question.options.is_empty() && !question.allow_custom {
            bail!("interaction question has no answer control");
        }
        validate_interaction_options(&question.options)?;
    }
    Ok(())
}

fn validate_interaction_options(
    options: &[relay_protocol::AdapterInteractionOption],
) -> Result<()> {
    let mut values = HashMap::new();
    for option in options {
        if option.value.is_empty()
            || option.value.len() > MAX_INTERACTION_VALUE_BYTES
            || option.label.is_empty()
            || option.label.len() > MAX_INTERACTION_LABEL_BYTES
            || option
                .description
                .as_ref()
                .is_some_and(|description| description.len() > MAX_INTERACTION_DESCRIPTION_BYTES)
        {
            bail!("interaction option is invalid");
        }
        if values.insert(option.value.as_str(), ()).is_some() {
            bail!("interaction option values must be unique");
        }
    }
    Ok(())
}

fn validate_interaction_response(
    interaction: &AdapterInteraction,
    response: &AdapterInteractionResponse,
) -> Result<()> {
    match interaction.kind {
        AdapterInteractionKind::Approval => {
            if !response.answers.is_empty() {
                bail!("approval response must not contain answers");
            }
            let action = response
                .action
                .as_deref()
                .ok_or_else(|| anyhow!("approval response requires an action"))?;
            if !interaction
                .actions
                .iter()
                .any(|option| option.value == action)
            {
                bail!("approval response action is not available");
            }
        }
        AdapterInteractionKind::Input => {
            if response.action.is_some() {
                bail!("input response must not contain an action");
            }
            if response.answers.len() != interaction.questions.len() {
                bail!("input response must answer every question");
            }
            for question in &interaction.questions {
                let answers = response
                    .answers
                    .get(&question.id)
                    .ok_or_else(|| anyhow!("input response is missing an answer"))?;
                if answers.is_empty() {
                    bail!("input response answer must not be empty");
                }
                for answer in answers {
                    if answer.is_empty() || answer.len() > MAX_INTERACTION_ANSWER_BYTES {
                        bail!("input response answer is invalid");
                    }
                    if !question.allow_custom
                        && !question
                            .options
                            .iter()
                            .any(|option| option.value == *answer)
                    {
                        bail!("input response answer is not available");
                    }
                }
            }
        }
    }
    Ok(())
}

fn validate_persisted_snapshot(snapshot: &TaskSnapshot) -> Result<()> {
    if snapshot.id.is_nil() {
        bail!("persisted task ID must not be nil");
    }
    if !valid_adapter_id(&snapshot.adapter_id) {
        bail!("persisted task adapter ID is invalid");
    }
    if snapshot.prompt_preview.len() > MAX_PROMPT_PREVIEW_BYTES {
        bail!("persisted task prompt preview is too large");
    }
    if let Some(title) = &snapshot.title {
        let normalized = normalized_task_title(title).map_err(anyhow::Error::msg)?;
        if normalized != *title {
            bail!("persisted task title is not normalized");
        }
    }
    match &snapshot.pending_interaction {
        Some(interaction) => {
            validate_interaction(interaction)?;
            let expected_status = match interaction.kind {
                AdapterInteractionKind::Approval => TaskStatus::WaitingForApproval,
                AdapterInteractionKind::Input => TaskStatus::WaitingForInput,
            };
            if snapshot.status != expected_status {
                bail!("persisted interaction does not match task status");
            }
        }
        None if matches!(
            snapshot.status,
            TaskStatus::WaitingForApproval | TaskStatus::WaitingForInput
        ) =>
        {
            bail!("persisted waiting task has no interaction")
        }
        None => {}
    }
    if !snapshot.cwd.is_absolute() {
        bail!("persisted task working directory must be absolute");
    }
    let cwd = snapshot
        .cwd
        .to_str()
        .ok_or_else(|| anyhow!("persisted task working directory must be valid UTF-8"))?;
    if cwd.len() > MAX_CWD_BYTES {
        bail!("persisted task working directory is too large");
    }
    if snapshot
        .latest_message
        .as_ref()
        .is_some_and(|message| message.len() > MAX_STATUS_MESSAGE_BYTES)
    {
        bail!("persisted task status message is too large");
    }
    if snapshot
        .session_id
        .as_ref()
        .is_some_and(|session_id| session_id.len() > 256)
    {
        bail!("persisted task session ID is too large");
    }
    if snapshot.turn_count == 0 {
        bail!("persisted task turn count must be positive");
    }
    if snapshot.updated_at_ms < snapshot.created_at_ms {
        bail!("persisted task timestamps are invalid");
    }
    validate_adapter_options(&snapshot.adapter_options).map_err(anyhow::Error::msg)
}

fn normalized_task_title(value: &str) -> std::result::Result<String, &'static str> {
    let value = value.trim();
    if value.is_empty() {
        return Err("task title must not be empty");
    }
    if value.len() > MAX_TASK_TITLE_BYTES {
        return Err("task title is too large");
    }
    let title = bounded_summary(value, MAX_TASK_TITLE_BYTES)
        .trim()
        .to_owned();
    if title.is_empty() {
        return Err("task title must contain visible text");
    }
    Ok(title)
}

fn recover_interrupted_tasks(tasks: &mut HashMap<Uuid, TaskEntry>) -> Vec<Uuid> {
    let mut recovered = Vec::new();
    for (id, entry) in tasks {
        if entry.snapshot.status.is_terminal() {
            continue;
        }
        let message = if entry.snapshot.session_id.is_some() {
            "Relay restarted before this turn completed. Continue the thread to resume its CLI session."
        } else {
            "Relay restarted before this turn completed."
        };
        entry.snapshot.status = TaskStatus::Failed;
        entry.snapshot.pending_interaction = None;
        entry.snapshot.latest_message = Some(message.to_owned());
        touch_task(entry);
        append_task_output(entry, TaskOutputKind::Error, message.to_owned());
        entry.prompt.clear();
        entry.cancel = None;
        entry.runner = None;
        entry.response_pending = false;
        recovered.push(*id);
    }
    recovered
}

fn prepare_state_directory(directory: &Path) -> Result<()> {
    if !directory.exists() {
        std::fs::create_dir_all(directory).with_context(|| {
            format!(
                "failed to create task state directory {}",
                directory.display()
            )
        })?;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))?;
    }
    let metadata = std::fs::symlink_metadata(directory)?;
    if !metadata.file_type().is_dir() {
        bail!(
            "task state path is not a directory: {}",
            directory.display()
        );
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        bail!("task state directory must be private (0700)");
    }
    validate_path_owner(&metadata, directory, false)?;
    if path_has_writable_acl(directory)? {
        bail!("task state directory has a writable ACL");
    }
    validate_path_ancestors(directory)
}

fn sync_directory(directory: &Path) -> Result<()> {
    std::fs::File::open(directory)
        .with_context(|| format!("failed to open state directory {}", directory.display()))?
        .sync_all()
        .with_context(|| format!("failed to sync state directory {}", directory.display()))
}

async fn prepare_socket_path(socket_path: &Path) -> Result<()> {
    let metadata = match std::fs::symlink_metadata(socket_path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_socket() {
        bail!(
            "refusing to replace non-socket path {}",
            socket_path.display()
        );
    }
    if UnixStream::connect(socket_path).await.is_ok() {
        bail!("a daemon is already listening on {}", socket_path.display());
    }
    std::fs::remove_file(socket_path)
        .with_context(|| format!("failed to remove stale socket {}", socket_path.display()))?;
    Ok(())
}

fn prepare_socket_directory(socket_path: &Path) -> Result<()> {
    let parent = socket_path
        .parent()
        .ok_or_else(|| anyhow!("socket path must have a parent directory"))?;
    if !parent.exists() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create socket directory {}", parent.display()))?;
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    }
    let metadata = std::fs::symlink_metadata(parent)?;
    if !metadata.file_type().is_dir() {
        bail!("socket parent is not a directory: {}", parent.display());
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        bail!("socket parent must be private (0700): {}", parent.display());
    }
    validate_path_owner(&metadata, parent, false)?;
    if path_has_writable_acl(parent)? {
        bail!("socket parent has a writable ACL: {}", parent.display());
    }
    validate_path_ancestors(parent)?;
    Ok(())
}

async fn prepare_chain_context(
    id: Uuid,
    steps: Vec<ChainStep>,
    note: Option<String>,
    adapters: &AdapterStore,
) -> std::result::Result<ChainContext, String> {
    if id.is_nil() {
        return Err("chain ID must not be nil".to_owned());
    }
    if !(2..=MAX_CHAIN_STEPS).contains(&steps.len()) {
        return Err(format!(
            "a chain requires between 2 and {MAX_CHAIN_STEPS} steps"
        ));
    }
    let note = note.unwrap_or_default().trim().to_owned();
    if note.len() > MAX_CHAIN_NOTE_BYTES || note.chars().any(char::is_control) {
        return Err("chain note is invalid".to_owned());
    }
    let agents = steps
        .iter()
        .map(|step| step.adapter_id.as_str())
        .collect::<Vec<_>>()
        .join(",");
    if agents.len() > MAX_ADAPTER_OPTION_VALUE_BYTES {
        return Err("chain adapter list is too large".to_owned());
    }
    let registered = adapters.read().await;
    for step in &steps {
        if !valid_adapter_id(&step.adapter_id) {
            return Err(format!("chain adapter ID is invalid: {}", step.adapter_id));
        }
        if !registered.contains_key(&step.adapter_id) {
            return Err(format!(
                "chain adapter is not registered: {}",
                step.adapter_id
            ));
        }
        if step.options.keys().any(|key| is_chain_option(key)) {
            return Err("chain metadata cannot be provided as a step option".to_owned());
        }
        validate_adapter_options(&step.options).map_err(str::to_owned)?;
    }
    let context = ChainContext {
        id,
        step: 0,
        steps,
        note,
    };
    for (step, planned) in context.steps.iter().enumerate() {
        let mut candidate = context.clone();
        candidate.step = step;
        chain_step_options(&candidate, planned.options.clone()).map_err(str::to_owned)?;
    }
    Ok(context)
}

fn validate_chain_context(snapshot: &TaskSnapshot, chain: &ChainContext) -> Result<()> {
    if chain.id.is_nil() || !(2..=MAX_CHAIN_STEPS).contains(&chain.steps.len()) {
        bail!("persisted chain plan is invalid");
    }
    if chain.step >= chain.steps.len() || snapshot.adapter_id != chain.steps[chain.step].adapter_id
    {
        bail!("persisted chain step does not match its task");
    }
    if chain.note.len() > MAX_CHAIN_NOTE_BYTES || chain.note.chars().any(char::is_control) {
        bail!("persisted chain note is invalid");
    }
    for step in &chain.steps {
        if !valid_adapter_id(&step.adapter_id)
            || step.options.keys().any(|key| is_chain_option(key))
        {
            bail!("persisted chain adapter is invalid");
        }
        validate_adapter_options(&step.options).map_err(anyhow::Error::msg)?;
    }
    let agents = chain
        .steps
        .iter()
        .map(|step| step.adapter_id.as_str())
        .collect::<Vec<_>>()
        .join(",");
    if agents.len() > MAX_ADAPTER_OPTION_VALUE_BYTES
        || snapshot.adapter_options.get(CHAIN_GROUP_OPTION) != Some(&chain.id.to_string())
        || snapshot.adapter_options.get(CHAIN_STEP_OPTION) != Some(&chain.step.to_string())
        || snapshot.adapter_options.get(CHAIN_AGENTS_OPTION) != Some(&agents)
        || match snapshot.adapter_options.get(CHAIN_NOTE_OPTION) {
            Some(note) => note != &chain.note || chain.note.is_empty(),
            None => !chain.note.is_empty(),
        }
    {
        bail!("persisted chain metadata is invalid");
    }
    Ok(())
}

fn chain_step_options(
    chain: &ChainContext,
    mut options: BTreeMap<String, String>,
) -> std::result::Result<BTreeMap<String, String>, &'static str> {
    if options.keys().any(|key| is_chain_option(key)) {
        return Err("chain metadata cannot be provided as a step option");
    }
    options.insert(CHAIN_GROUP_OPTION.to_owned(), chain.id.to_string());
    options.insert(CHAIN_STEP_OPTION.to_owned(), chain.step.to_string());
    options.insert(
        CHAIN_AGENTS_OPTION.to_owned(),
        chain
            .steps
            .iter()
            .map(|step| step.adapter_id.as_str())
            .collect::<Vec<_>>()
            .join(","),
    );
    if !chain.note.is_empty() {
        options.insert(CHAIN_NOTE_OPTION.to_owned(), chain.note.clone());
    }
    validate_adapter_options(&options)?;
    Ok(options)
}

fn is_chain_option(key: &str) -> bool {
    matches!(
        key,
        CHAIN_GROUP_OPTION | CHAIN_STEP_OPTION | CHAIN_AGENTS_OPTION | CHAIN_NOTE_OPTION
    )
}

#[derive(Debug, Clone)]
struct PendingChainAdvance {
    source_id: Uuid,
    context: ChainContext,
    answer: String,
    cwd: PathBuf,
}

fn pending_chain_advances(entries: &HashMap<Uuid, TaskEntry>) -> Vec<PendingChainAdvance> {
    let mut contexts = BTreeMap::<Uuid, ChainContext>::new();
    for entry in entries.values() {
        let Some(chain) = &entry.chain else { continue };
        if chain.step == 0 {
            contexts.insert(chain.id, chain.clone());
        } else {
            contexts.entry(chain.id).or_insert_with(|| chain.clone());
        }
    }

    let mut advances = Vec::new();
    for (chain_id, context) in contexts {
        let mut members = entries
            .iter()
            .filter_map(|(id, entry)| {
                entry
                    .chain
                    .as_ref()
                    .filter(|chain| chain.id == chain_id)
                    .map(|chain| (*id, entry, chain))
            })
            .collect::<Vec<_>>();
        members.sort_by_key(|(_, _, chain)| chain.step);
        if members.is_empty()
            || members
                .iter()
                .any(|(_, _, chain)| chain.steps != context.steps || chain.note != context.note)
            || members
                .windows(2)
                .any(|pair| pair[0].2.step == pair[1].2.step)
        {
            continue;
        }
        let (source_id, source, source_chain) = members.last().unwrap();
        if source_chain.step + 1 >= context.steps.len()
            || source.snapshot.status != TaskStatus::Completed
        {
            continue;
        }
        advances.push(PendingChainAdvance {
            source_id: *source_id,
            context: (*source_chain).clone(),
            answer: last_turn_answer(&source.output),
            cwd: source.snapshot.cwd.clone(),
        });
    }
    advances.sort_by_key(|advance| advance.context.id);
    advances
}

fn last_turn_answer(output: &[TaskOutput]) -> String {
    let start = output
        .iter()
        .rposition(|item| item.kind == TaskOutputKind::User)
        .map_or(0, |index| index + 1);
    output[start..]
        .iter()
        .filter(|item| item.kind == TaskOutputKind::Assistant)
        .map(|item| item.text.as_str())
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_owned()
}

async fn advance_pending_chains(tasks: &SharedTaskStore, adapters: &AdapterStore) {
    let _guard = tasks.chain_lock.lock().await;
    let advances = {
        let entries = tasks.read().await;
        pending_chain_advances(&entries)
    };
    for advance in advances {
        let next_step = advance.context.step + 1;
        let next = advance.context.steps[next_step].clone();
        if advance.answer.is_empty() {
            update_chain_source(
                tasks,
                advance.source_id,
                format!("Chain halted: step {} has no assistant answer", next_step),
                Some(TaskOutputKind::Error),
            )
            .await;
            continue;
        }
        if !adapters.read().await.contains_key(&next.adapter_id) {
            update_chain_source(
                tasks,
                advance.source_id,
                format!("Chain waiting for adapter {}", next.adapter_id),
                Some(TaskOutputKind::System),
            )
            .await;
            continue;
        }
        let mut context = advance.context;
        context.step = next_step;
        let options = match chain_step_options(&context, next.options) {
            Ok(options) => options,
            Err(message) => {
                update_chain_source(
                    tasks,
                    advance.source_id,
                    format!("Chain halted: {message}"),
                    Some(TaskOutputKind::Error),
                )
                .await;
                continue;
            }
        };
        let instruction = if context.note.is_empty() {
            "基于上一步的输出继续处理："
        } else {
            &context.note
        };
        let response = start_task_inner(
            Uuid::new_v4(),
            ChainStep {
                adapter_id: next.adapter_id.clone(),
                options,
            },
            format!("{instruction}\n\n{}", advance.answer),
            advance.cwd,
            Some(context),
            tasks.clone(),
            adapters.clone(),
        )
        .await;
        match response {
            DaemonResponse::Task { .. } => {
                update_chain_source(
                    tasks,
                    advance.source_id,
                    format!("Chain advanced to {}", next.adapter_id),
                    None,
                )
                .await;
            }
            DaemonResponse::Error { code, message } => {
                update_chain_source(
                    tasks,
                    advance.source_id,
                    format!("Chain waiting: {code}: {message}"),
                    Some(TaskOutputKind::Error),
                )
                .await;
            }
            _ => {}
        }
    }
}

async fn update_chain_source(
    tasks: &SharedTaskStore,
    id: Uuid,
    message: String,
    output_kind: Option<TaskOutputKind>,
) {
    let changed = {
        let mut entries = tasks.write().await;
        let Some(entry) = entries.get_mut(&id) else {
            return;
        };
        if entry.snapshot.latest_message.as_deref() == Some(message.as_str()) {
            return;
        }
        entry.snapshot.latest_message = Some(message.clone());
        touch_task(entry);
        if let Some(kind) = output_kind {
            append_task_output(entry, kind, message);
        }
        true
    };
    if changed && let Err(error) = tasks.persist_task(id).await {
        eprintln!("failed to persist chain state for {id}: {error:#}");
    }
}

fn valid_adapter_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ADAPTER_ID_BYTES
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn validate_adapter_options(
    options: &BTreeMap<String, String>,
) -> std::result::Result<(), &'static str> {
    if options.len() > MAX_ADAPTER_OPTIONS {
        return Err("too many adapter options");
    }
    for (key, value) in options {
        if key.is_empty()
            || key.len() > MAX_ADAPTER_OPTION_KEY_BYTES
            || !key
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        {
            return Err("adapter option key is invalid");
        }
        if value.is_empty()
            || value.len() > MAX_ADAPTER_OPTION_VALUE_BYTES
            || value.chars().any(char::is_control)
        {
            return Err("adapter option value is invalid");
        }
    }
    Ok(())
}

fn validate_path_ancestors(path: &Path) -> Result<()> {
    for ancestor in path.ancestors().skip(1) {
        let link_metadata = std::fs::symlink_metadata(ancestor)?;
        if link_metadata.file_type().is_symlink() && link_metadata.uid() != 0 {
            bail!("path has an untrusted symlink: {}", ancestor.display());
        }
        let metadata = std::fs::metadata(ancestor)?;
        let mode = metadata.permissions().mode();
        if mode & 0o022 != 0 && mode & libc::S_ISVTX as u32 == 0 {
            bail!(
                "path has a writable non-sticky ancestor: {}",
                ancestor.display()
            );
        }
        validate_path_owner(&metadata, ancestor, true)?;
        if path_has_writable_acl(ancestor)? {
            bail!("path has a writable ACL: {}", ancestor.display());
        }
    }
    Ok(())
}

fn validate_path_owner(metadata: &std::fs::Metadata, path: &Path, allow_root: bool) -> Result<()> {
    // 実行中ユーザーと root 以外が所有するパスは信頼しない。
    let effective_user = unsafe { libc::geteuid() };
    if metadata.uid() != effective_user && !(allow_root && metadata.uid() == 0) {
        bail!("path has an untrusted owner: {}", path.display());
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn path_has_writable_acl(path: &Path) -> Result<bool> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    const ACL_TYPE_EXTENDED: libc::c_int = 0x100;
    const ACL_FIRST_ENTRY: libc::c_int = 0;
    const ACL_NEXT_ENTRY: libc::c_int = -1;
    const ACL_EXTENDED_ALLOW: libc::c_int = 1;
    const WRITE_PERMISSIONS: u64 =
        (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 8) | (1 << 10) | (1 << 12) | (1 << 13);

    let path = CString::new(path.as_os_str().as_bytes()).context("path contains a null byte")?;
    // macOS の拡張 ACL を読み取り、書き込み許可エントリだけを拒否する。
    let acl = unsafe { acl_get_file(path.as_ptr(), ACL_TYPE_EXTENDED) };
    if acl.is_null() {
        let error = std::io::Error::last_os_error();
        return if error.raw_os_error() == Some(libc::ENOENT) {
            Ok(false)
        } else {
            Err(error).context("failed to read path ACL")
        };
    }
    let acl = AclHandle(acl);
    let mut entry = std::ptr::null_mut();
    let mut entry_id = ACL_FIRST_ENTRY;
    loop {
        // acl が保持されている間だけ entry を参照する。
        let result = unsafe { acl_get_entry(acl.0, entry_id, &mut entry) };
        if result != 0 {
            break;
        }
        let mut tag = 0;
        let mut permissions = 0_u64;
        // entry は直前の acl_get_entry が返した有効なエントリ。
        if unsafe { acl_get_tag_type(entry, &mut tag) } != 0
            || unsafe { acl_get_permset_mask_np(entry, &mut permissions) } != 0
        {
            bail!("failed to inspect path ACL");
        }
        if tag == ACL_EXTENDED_ALLOW && permissions & WRITE_PERMISSIONS != 0 {
            return Ok(true);
        }
        entry_id = ACL_NEXT_ENTRY;
    }
    Ok(false)
}

#[cfg(not(target_os = "macos"))]
fn path_has_writable_acl(_path: &Path) -> Result<bool> {
    Ok(false)
}

#[cfg(target_os = "macos")]
struct AclHandle(*mut libc::c_void);

#[cfg(target_os = "macos")]
impl Drop for AclHandle {
    fn drop(&mut self) {
        // acl_get_file が確保したオブジェクトを一度だけ解放する。
        let _ = unsafe { acl_free(self.0) };
    }
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn acl_get_file(path: *const libc::c_char, acl_type: libc::c_int) -> *mut libc::c_void;
    fn acl_get_entry(
        acl: *mut libc::c_void,
        entry_id: libc::c_int,
        entry: *mut *mut libc::c_void,
    ) -> libc::c_int;
    fn acl_get_tag_type(entry: *mut libc::c_void, tag: *mut libc::c_int) -> libc::c_int;
    fn acl_get_permset_mask_np(entry: *mut libc::c_void, permissions: *mut u64) -> libc::c_int;
    fn acl_free(object: *mut libc::c_void) -> libc::c_int;
}

fn error_response(code: &str, message: &str) -> DaemonResponse {
    DaemonResponse::Error {
        code: code.to_owned(),
        message: message.to_owned(),
    }
}

fn bounded_summary(value: &str, max_bytes: usize) -> String {
    let mut summary = String::with_capacity(value.len().min(max_bytes));
    for character in value.chars() {
        let character = if character.is_control() {
            ' '
        } else {
            character
        };
        if summary.len() + character.len_utf8() > max_bytes {
            break;
        }
        summary.push(character);
    }
    summary
}

fn bounded_output(value: &str) -> String {
    let mut output = String::with_capacity(value.len().min(MAX_OUTPUT_EVENT_BYTES));
    for character in value.chars() {
        let character = if character.is_control() && character != '\n' && character != '\t' {
            ' '
        } else {
            character
        };
        if output.len() + character.len_utf8() > MAX_OUTPUT_EVENT_BYTES {
            break;
        }
        output.push(character);
    }
    output
}

fn append_task_output(entry: &mut TaskEntry, kind: TaskOutputKind, text: String) {
    let original_bytes = text.len();
    let text = bounded_output(&text);
    if text.len() < original_bytes {
        entry.output_truncated = true;
    }
    if text.trim().is_empty() {
        return;
    }
    let text_bytes = text.len();
    while !entry.output.is_empty()
        && (entry.output_bytes.saturating_add(text_bytes) > MAX_TASK_OUTPUT_BYTES
            || entry.output.len() >= MAX_TASK_OUTPUT_EVENTS)
    {
        let removed = entry.output.remove(0);
        entry.output_bytes = entry.output_bytes.saturating_sub(removed.text.len());
        entry.output_truncated = true;
    }
    let sequence = entry.next_output_sequence;
    entry.next_output_sequence = entry.next_output_sequence.saturating_add(1);
    entry.output_bytes = entry.output_bytes.saturating_add(text_bytes);
    entry.output.push(TaskOutput {
        sequence,
        timestamp_ms: timestamp_ms(),
        kind,
        text,
    });
}

fn touch_task(entry: &mut TaskEntry) {
    entry.snapshot.updated_at_ms =
        timestamp_ms().max(entry.snapshot.updated_at_ms.saturating_add(1));
}

fn timestamp_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

#[derive(Debug)]
struct SocketLock {
    _file: std::fs::File,
}

impl SocketLock {
    fn acquire(socket_path: &Path) -> Result<Self> {
        let mut lock_name = socket_path.as_os_str().to_os_string();
        lock_name.push(".lock");
        let lock_path = PathBuf::from(lock_name);
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&lock_path)
            .with_context(|| format!("failed to open daemon lock {}", lock_path.display()))?;
        std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o600))?;
        // ロックファイルを保持したまま、同じソケットへの二重起動を防ぐ。
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result != 0 {
            let error = std::io::Error::last_os_error();
            bail!(
                "failed to acquire daemon lock {}: {error}",
                lock_path.display()
            );
        }
        Ok(Self { _file: file })
    }
}

struct SocketGuard {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl SocketGuard {
    fn new(path: &Path) -> Result<Self> {
        let metadata = std::fs::symlink_metadata(path)?;
        Ok(Self {
            path: path.to_owned(),
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        if let Ok(metadata) = std::fs::symlink_metadata(&self.path)
            && metadata.file_type().is_socket()
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task_store(entries: HashMap<Uuid, TaskEntry>) -> SharedTaskStore {
        Arc::new(TaskStore::new(entries, TaskPersistence::disabled()))
    }

    fn test_adapter(id: &str, executable: PathBuf) -> AdapterRegistration {
        AdapterRegistration {
            id: id.to_owned(),
            executable,
            environment: BTreeMap::new(),
        }
    }

    fn adapter_store(id: &str, executable: PathBuf) -> AdapterStore {
        Arc::new(RwLock::new(HashMap::from([(
            id.to_owned(),
            test_adapter(id, executable),
        )])))
    }

    fn persisted_test_entry(id: Uuid, status: TaskStatus) -> TaskEntry {
        let mut entry = TaskEntry {
            snapshot: TaskSnapshot {
                id,
                adapter_id: "mock".to_owned(),
                prompt_preview: "persist me".to_owned(),
                title: None,
                pending_interaction: None,
                cwd: PathBuf::from("/tmp"),
                status,
                created_at_ms: 1,
                updated_at_ms: 2,
                latest_message: Some("saved".to_owned()),
                session_id: Some("session-1".to_owned()),
                turn_count: 1,
                adapter_options: BTreeMap::from([("model".to_owned(), "test".to_owned())]),
            },
            prompt: String::new(),
            output: Vec::new(),
            output_bytes: 0,
            output_truncated: false,
            next_output_sequence: 0,
            cancel: None,
            runner: None,
            response_pending: false,
            chain: None,
        };
        append_task_output(&mut entry, TaskOutputKind::User, "persist me".to_owned());
        entry
    }

    fn approval_interaction(id: &str) -> AdapterInteraction {
        AdapterInteraction {
            id: id.to_owned(),
            kind: AdapterInteractionKind::Approval,
            title: "Command approval".to_owned(),
            message: "$ touch outside-workspace".to_owned(),
            actions: vec![relay_protocol::AdapterInteractionOption {
                value: "accept".to_owned(),
                label: "Allow once".to_owned(),
                description: None,
            }],
            questions: Vec::new(),
        }
    }

    async fn wait_for_completed_adapter(tasks: &SharedTaskStore, adapter_id: &str) {
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                let completed = tasks.read().await.values().any(|entry| {
                    entry.snapshot.adapter_id == adapter_id
                        && entry.snapshot.status == TaskStatus::Completed
                });
                if completed {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }

    fn completion_adapter(id: &str, executable: PathBuf, reply: &str) -> AdapterRegistration {
        AdapterRegistration {
            id: id.to_owned(),
            executable,
            environment: BTreeMap::from([("RELAY_REPLY".to_owned(), reply.to_owned())]),
        }
    }

    #[test]
    fn persisted_task_round_trips_with_private_permissions() {
        let directory = tempfile::tempdir().unwrap();
        let state_directory = directory.path().join("tasks");
        let persistence = TaskPersistence::prepare(state_directory.clone()).unwrap();
        let id = Uuid::new_v4();
        let mut entry = persisted_test_entry(id, TaskStatus::Completed);
        let chain = ChainContext {
            id,
            step: 0,
            steps: vec![
                ChainStep {
                    adapter_id: "mock".to_owned(),
                    options: BTreeMap::new(),
                },
                ChainStep {
                    adapter_id: "next".to_owned(),
                    options: BTreeMap::new(),
                },
            ],
            note: "Review:".to_owned(),
        };
        entry.snapshot.adapter_options = chain_step_options(&chain, BTreeMap::new()).unwrap();
        entry.chain = Some(chain);

        persistence
            .write(&PersistedTask::from_entry(&entry))
            .unwrap();
        let restored = persistence.load().unwrap();

        let restored = restored.get(&id).unwrap();
        assert_eq!(restored.snapshot, entry.snapshot);
        assert_eq!(restored.output, entry.output);
        assert_eq!(restored.next_output_sequence, 1);
        assert_eq!(restored.chain, entry.chain);
        assert_eq!(
            std::fs::metadata(state_directory.join(format!("{id}.json")))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        assert!(!state_directory.join(format!(".{id}.json.tmp")).exists());
    }

    #[test]
    fn interrupted_task_is_restored_as_failed_and_resumable() {
        let id = Uuid::new_v4();
        let mut tasks = HashMap::from([(id, persisted_test_entry(id, TaskStatus::Running))]);

        let recovered = recover_interrupted_tasks(&mut tasks);

        let entry = tasks.get(&id).unwrap();
        assert_eq!(recovered, vec![id]);
        assert_eq!(entry.snapshot.status, TaskStatus::Failed);
        assert_eq!(entry.snapshot.session_id.as_deref(), Some("session-1"));
        assert!(
            entry
                .output
                .iter()
                .any(|output| output.kind == TaskOutputKind::Error
                    && output.text.contains("Continue the thread"))
        );
    }

    #[tokio::test]
    async fn adapter_events_are_written_to_persistent_state() {
        let directory = tempfile::tempdir().unwrap();
        let persistence = TaskPersistence::prepare(directory.path().join("tasks")).unwrap();
        let id = Uuid::new_v4();
        let tasks = Arc::new(TaskStore::new(
            HashMap::from([(id, persisted_test_entry(id, TaskStatus::Running))]),
            persistence.clone(),
        ));

        apply_event(
            &tasks,
            AdapterEvent {
                task_id: id,
                status: TaskStatus::Completed,
                message: Some("done".to_owned()),
                output: Some(relay_protocol::AdapterOutput {
                    kind: TaskOutputKind::Assistant,
                    text: "answer".to_owned(),
                }),
                session_id: None,
                interaction: None,
            },
        )
        .await;

        let restored = persistence.load().unwrap();
        let restored = restored.get(&id).unwrap();
        assert_eq!(restored.snapshot.status, TaskStatus::Completed);
        assert_eq!(restored.output.last().unwrap().text, "answer");
    }

    #[tokio::test]
    async fn adapter_events_advance_task_time_past_the_previous_value() {
        let id = Uuid::new_v4();
        let mut entry = persisted_test_entry(id, TaskStatus::Running);
        let previous = timestamp_ms().saturating_add(60_000);
        entry.snapshot.updated_at_ms = previous;
        let tasks = task_store(HashMap::from([(id, entry)]));

        apply_event(
            &tasks,
            AdapterEvent {
                task_id: id,
                status: TaskStatus::Running,
                message: None,
                output: Some(relay_protocol::AdapterOutput {
                    kind: TaskOutputKind::Assistant,
                    text: "next output".to_owned(),
                }),
                session_id: None,
                interaction: None,
            },
        )
        .await;

        assert_eq!(
            tasks.read().await.get(&id).unwrap().snapshot.updated_at_ms,
            previous + 1
        );
    }

    #[test]
    fn malformed_persisted_task_stops_recovery() {
        let directory = tempfile::tempdir().unwrap();
        let state_directory = directory.path().join("tasks");
        let persistence = TaskPersistence::prepare(state_directory.clone()).unwrap();
        let path = state_directory.join(format!("{}.json", Uuid::new_v4()));
        std::fs::write(&path, b"not json").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();

        let error = persistence.load().err().unwrap();

        assert!(error.to_string().contains("failed to decode task state"));
    }

    #[tokio::test]
    async fn deleting_terminal_task_removes_memory_and_persisted_state() {
        let directory = tempfile::tempdir().unwrap();
        let state_directory = directory.path().join("tasks");
        let persistence = TaskPersistence::prepare(state_directory.clone()).unwrap();
        let id = Uuid::new_v4();
        let entry = persisted_test_entry(id, TaskStatus::Completed);
        persistence
            .write(&PersistedTask::from_entry(&entry))
            .unwrap();
        let tasks = Arc::new(TaskStore::new(HashMap::from([(id, entry)]), persistence));

        let response = delete_task(id, tasks.clone()).await;

        assert!(matches!(
            response,
            DaemonResponse::TaskDeleted { task_id } if task_id == id
        ));
        assert!(!tasks.read().await.contains_key(&id));
        assert!(!state_directory.join(format!("{id}.json")).exists());
    }

    #[tokio::test]
    async fn deleting_active_task_is_rejected() {
        let id = Uuid::new_v4();
        let tasks = task_store(HashMap::from([(
            id,
            persisted_test_entry(id, TaskStatus::Running),
        )]));

        let response = delete_task(id, tasks.clone()).await;

        assert!(matches!(
            response,
            DaemonResponse::Error { code, .. } if code == "task_active"
        ));
        assert!(tasks.read().await.contains_key(&id));
    }

    #[tokio::test]
    async fn renaming_task_updates_persistent_state() {
        let directory = tempfile::tempdir().unwrap();
        let persistence = TaskPersistence::prepare(directory.path().join("tasks")).unwrap();
        let id = Uuid::new_v4();
        let mut entry = persisted_test_entry(id, TaskStatus::Completed);
        entry.prompt = "original prompt".to_owned();
        let tasks = Arc::new(TaskStore::new(
            HashMap::from([(id, entry)]),
            persistence.clone(),
        ));

        let response = rename_task(id, "  Release audit  ".to_owned(), tasks.clone()).await;

        assert!(matches!(
            response,
            DaemonResponse::Task {
                task: TaskSnapshot {
                    title: Some(title),
                    ..
                }
            } if title == "Release audit"
        ));
        assert_eq!(
            tasks.read().await.get(&id).unwrap().prompt,
            "original prompt"
        );
        let restored = persistence.load().unwrap();
        assert_eq!(
            restored.get(&id).unwrap().snapshot.title.as_deref(),
            Some("Release audit")
        );
    }

    #[tokio::test]
    async fn renaming_task_rejects_empty_title() {
        let id = Uuid::new_v4();
        let tasks = task_store(HashMap::from([(
            id,
            persisted_test_entry(id, TaskStatus::Completed),
        )]));

        let response = rename_task(id, " \n ".to_owned(), tasks.clone()).await;

        assert!(matches!(
            response,
            DaemonResponse::Error { code, .. } if code == "invalid_task_title"
        ));
        assert_eq!(tasks.read().await.get(&id).unwrap().snapshot.title, None);
    }

    #[tokio::test]
    async fn pending_interaction_response_reaches_live_adapter() {
        let id = Uuid::new_v4();
        let mut entry = persisted_test_entry(id, TaskStatus::WaitingForApproval);
        entry.snapshot.pending_interaction = Some(Box::new(approval_interaction("approval-1")));
        let tasks = task_store(HashMap::from([(id, entry)]));
        let (sender, mut receiver) = mpsc::channel(1);
        tasks.set_interaction_responder(id, sender).await;
        let expected = AdapterInteractionResponse {
            interaction_id: "approval-1".to_owned(),
            action: Some("accept".to_owned()),
            answers: BTreeMap::new(),
        };

        let response = respond_to_interaction(id, expected.clone(), tasks.clone()).await;

        assert!(matches!(
            response,
            DaemonResponse::Task {
                task: TaskSnapshot {
                    status: TaskStatus::Running,
                    pending_interaction: None,
                    ..
                }
            }
        ));
        assert_eq!(receiver.try_recv().unwrap(), expected);
    }

    #[tokio::test]
    async fn unavailable_interaction_action_is_rejected() {
        let id = Uuid::new_v4();
        let mut entry = persisted_test_entry(id, TaskStatus::WaitingForApproval);
        entry.snapshot.pending_interaction = Some(Box::new(approval_interaction("approval-1")));
        let tasks = task_store(HashMap::from([(id, entry)]));
        let (sender, mut receiver) = mpsc::channel(1);
        tasks.set_interaction_responder(id, sender).await;

        let response = respond_to_interaction(
            id,
            AdapterInteractionResponse {
                interaction_id: "approval-1".to_owned(),
                action: Some("decline".to_owned()),
                answers: BTreeMap::new(),
            },
            tasks.clone(),
        )
        .await;

        assert!(matches!(
            response,
            DaemonResponse::Error { code, .. } if code == "invalid_interaction_response"
        ));
        assert!(receiver.try_recv().is_err());
        assert_eq!(
            tasks
                .read()
                .await
                .get(&id)
                .unwrap()
                .snapshot
                .pending_interaction
                .as_ref()
                .unwrap()
                .id,
            "approval-1"
        );
    }

    #[tokio::test]
    async fn regular_file_at_socket_path_is_not_removed() {
        let directory = tempfile::tempdir().unwrap();
        let socket_path = directory.path().join("relay.sock");
        std::fs::write(&socket_path, b"keep").unwrap();

        let error = prepare_socket_path(&socket_path).await.unwrap_err();

        assert!(error.to_string().contains("refusing to replace non-socket"));
        assert_eq!(std::fs::read(&socket_path).unwrap(), b"keep");
    }

    #[test]
    fn socket_lock_prevents_concurrent_daemons() {
        let directory = tempfile::tempdir().unwrap();
        let socket_path = directory.path().join("relay.sock");
        let _first = SocketLock::acquire(&socket_path).unwrap();

        let error = SocketLock::acquire(&socket_path).unwrap_err();

        assert!(error.to_string().contains("failed to acquire daemon lock"));
    }

    #[test]
    fn writable_socket_directory_is_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let socket_directory = directory.path().join("shared");
        std::fs::create_dir(&socket_directory).unwrap();
        std::fs::set_permissions(&socket_directory, std::fs::Permissions::from_mode(0o777))
            .unwrap();

        let error = prepare_socket_directory(&socket_directory.join("relay.sock")).unwrap_err();

        assert!(error.to_string().contains("must be private"));
    }

    #[test]
    fn writable_socket_ancestor_is_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let shared = directory.path().join("shared");
        let private = shared.join("private");
        std::fs::create_dir_all(&private).unwrap();
        std::fs::set_permissions(&shared, std::fs::Permissions::from_mode(0o777)).unwrap();
        std::fs::set_permissions(&private, std::fs::Permissions::from_mode(0o700)).unwrap();

        let error = prepare_socket_directory(&private.join("relay.sock")).unwrap_err();

        assert!(error.to_string().contains("writable non-sticky ancestor"));
    }

    #[test]
    fn user_owned_socket_ancestor_symlink_is_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target");
        let private = target.join("private");
        std::fs::create_dir_all(&private).unwrap();
        std::fs::set_permissions(&private, std::fs::Permissions::from_mode(0o700)).unwrap();
        let link = directory.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let error = prepare_socket_directory(&link.join("private/relay.sock")).unwrap_err();

        assert!(error.to_string().contains("untrusted symlink"));
    }

    #[test]
    fn writable_adapter_executable_is_rejected() {
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("adapter");
        std::fs::write(&executable, b"adapter").unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o777)).unwrap();

        let error = validate_adapters(vec![AdapterRegistration {
            id: "mock".to_owned(),
            executable,
            environment: BTreeMap::new(),
        }])
        .unwrap_err();

        assert!(error.to_string().contains("not executable"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn writable_acl_is_detected() {
        let directory = tempfile::tempdir().unwrap();
        let status = std::process::Command::new("/bin/chmod")
            .args(["+a", "everyone allow write,delete_child"])
            .arg(directory.path())
            .status()
            .unwrap();
        assert!(status.success());

        assert!(path_has_writable_acl(directory.path()).unwrap());
    }

    #[tokio::test]
    async fn oversized_protocol_line_is_rejected_before_newline() {
        let input = vec![b'a'; MAX_LINE_BYTES + 1];
        let mut reader = BufReader::new(input.as_slice());

        let error = read_bounded_line(&mut reader).await.unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn maximum_task_list_fits_protocol_frame() {
        let tasks = (0..MAX_STORED_TASKS)
            .map(|index| TaskSnapshot {
                id: Uuid::from_u128(index as u128 + 1),
                adapter_id: "a".repeat(MAX_ADAPTER_ID_BYTES),
                prompt_preview: "\"".repeat(MAX_PROMPT_PREVIEW_BYTES),
                title: Some("t".repeat(MAX_TASK_TITLE_BYTES)),
                pending_interaction: None,
                cwd: PathBuf::from(format!(
                    "/{}",
                    "\u{1}".repeat(MAX_CWD_BYTES.saturating_sub(1))
                )),
                status: TaskStatus::Completed,
                created_at_ms: index as u64,
                updated_at_ms: index as u64,
                latest_message: Some("\"".repeat(MAX_STATUS_MESSAGE_BYTES)),
                session_id: Some("s".repeat(256)),
                turn_count: u32::MAX,
                adapter_options: (0..MAX_ADAPTER_OPTIONS)
                    .map(|option| {
                        (
                            format!("option-{option}"),
                            "v".repeat(MAX_ADAPTER_OPTION_VALUE_BYTES),
                        )
                    })
                    .collect(),
            })
            .collect();

        let encoded = serde_json::to_vec(&DaemonResponse::Tasks { tasks }).unwrap();

        assert!(
            encoded.len() <= MAX_LINE_BYTES,
            "encoded bytes: {}",
            encoded.len()
        );
    }

    #[tokio::test]
    async fn initial_prompt_output_preserves_multiline_text() {
        let directory = tempfile::tempdir().unwrap();
        let tasks = task_store(HashMap::new());
        let adapters = adapter_store("mock", PathBuf::from("/usr/bin/true"));
        let id = Uuid::new_v4();
        let prompt = "first line\n第二行".to_owned();

        let response = start_task(
            id,
            "mock".to_owned(),
            prompt.clone(),
            directory.path().to_owned(),
            BTreeMap::new(),
            tasks.clone(),
            adapters,
        )
        .await;

        assert!(matches!(response, DaemonResponse::Task { .. }));
        assert_eq!(tasks.read().await.get(&id).unwrap().output[0].text, prompt);
        shutdown_tasks(&tasks).await;
    }

    #[tokio::test]
    async fn daemon_advances_a_chain_once_with_per_step_options() {
        let directory = tempfile::tempdir().unwrap();
        let adapter = directory.path().join("complete.sh");
        std::fs::write(
            &adapter,
            r#"#!/bin/sh
IFS= read -r request
task_id=${request#*\"task_id\":\"}
task_id=${task_id%%\"*}
printf '{\"task_id\":\"%s\",\"status\":\"completed\",\"message\":\"done\",\"output\":{\"kind\":\"assistant\",\"text\":\"%s\"},\"session_id\":null}\n' "$task_id" "$RELAY_REPLY"
"#,
        )
        .unwrap();
        std::fs::set_permissions(&adapter, std::fs::Permissions::from_mode(0o700)).unwrap();
        let adapters = Arc::new(RwLock::new(HashMap::from([
            (
                "echo-a".to_owned(),
                completion_adapter("echo-a", adapter.clone(), "first answer"),
            ),
            (
                "echo-b".to_owned(),
                completion_adapter("echo-b", adapter, "second answer"),
            ),
        ])));
        let tasks = task_store(HashMap::new());
        let chain_id = Uuid::new_v4();

        let response = start_chain(
            chain_id,
            "initial request".to_owned(),
            directory.path().to_owned(),
            vec![
                ChainStep {
                    adapter_id: "echo-a".to_owned(),
                    options: BTreeMap::from([("model".to_owned(), "alpha".to_owned())]),
                },
                ChainStep {
                    adapter_id: "echo-b".to_owned(),
                    options: BTreeMap::from([("model".to_owned(), "beta".to_owned())]),
                },
            ],
            Some("Review:".to_owned()),
            tasks.clone(),
            adapters.clone(),
        )
        .await;

        assert!(matches!(response, DaemonResponse::Task { .. }));
        wait_for_completed_adapter(&tasks, "echo-a").await;
        advance_pending_chains(&tasks, &adapters).await;
        advance_pending_chains(&tasks, &adapters).await;
        assert_eq!(tasks.read().await.len(), 2);
        wait_for_completed_adapter(&tasks, "echo-b").await;

        let entries = tasks.read().await;
        let second = entries
            .values()
            .find(|entry| entry.snapshot.adapter_id == "echo-b")
            .unwrap();
        assert_eq!(
            second
                .output
                .iter()
                .find(|item| item.kind == TaskOutputKind::User)
                .unwrap()
                .text,
            "Review:\n\nfirst answer"
        );
        assert_eq!(
            second
                .snapshot
                .adapter_options
                .get("model")
                .map(String::as_str),
            Some("beta")
        );
        assert_eq!(
            second
                .snapshot
                .adapter_options
                .get(CHAIN_STEP_OPTION)
                .map(String::as_str),
            Some("1")
        );
        assert_eq!(second.chain.as_ref().map(|chain| chain.step), Some(1));
        drop(entries);
        shutdown_tasks(&tasks).await;
    }

    #[tokio::test]
    async fn chain_requires_registered_steps_and_rejects_reserved_options() {
        let directory = tempfile::tempdir().unwrap();
        let adapters = adapter_store("echo-a", PathBuf::from("/usr/bin/true"));
        let tasks = task_store(HashMap::new());

        let missing = start_chain(
            Uuid::new_v4(),
            "test".to_owned(),
            directory.path().to_owned(),
            vec![
                ChainStep {
                    adapter_id: "echo-a".to_owned(),
                    options: BTreeMap::new(),
                },
                ChainStep {
                    adapter_id: "echo-b".to_owned(),
                    options: BTreeMap::new(),
                },
            ],
            None,
            tasks.clone(),
            adapters.clone(),
        )
        .await;
        assert!(matches!(
            missing,
            DaemonResponse::Error { code, message }
                if code == "invalid_chain" && message.contains("not registered")
        ));

        adapters.write().await.insert(
            "echo-b".to_owned(),
            test_adapter("echo-b", PathBuf::from("/usr/bin/true")),
        );
        let reserved = start_chain(
            Uuid::new_v4(),
            "test".to_owned(),
            directory.path().to_owned(),
            vec![
                ChainStep {
                    adapter_id: "echo-a".to_owned(),
                    options: BTreeMap::from([(
                        CHAIN_GROUP_OPTION.to_owned(),
                        "spoofed".to_owned(),
                    )]),
                },
                ChainStep {
                    adapter_id: "echo-b".to_owned(),
                    options: BTreeMap::new(),
                },
            ],
            None,
            tasks,
            adapters,
        )
        .await;
        assert!(matches!(
            reserved,
            DaemonResponse::Error { code, message }
                if code == "invalid_chain" && message.contains("metadata")
        ));
    }

    #[test]
    fn output_event_truncation_is_reported() {
        let id = Uuid::new_v4();
        let mut entry = persisted_test_entry(id, TaskStatus::Completed);
        entry.output.clear();
        entry.output_bytes = 0;
        entry.output_truncated = false;

        append_task_output(
            &mut entry,
            TaskOutputKind::User,
            "x".repeat(MAX_OUTPUT_EVENT_BYTES + 1),
        );

        assert_eq!(entry.output[0].text.len(), MAX_OUTPUT_EVENT_BYTES);
        assert!(entry.output_truncated);
    }

    #[tokio::test]
    async fn active_task_limit_rejects_another_start() {
        let directory = tempfile::tempdir().unwrap();
        let mut entries = HashMap::new();
        for index in 0..MAX_ACTIVE_TASKS {
            let id = Uuid::from_u128(index as u128 + 1);
            entries.insert(
                id,
                TaskEntry {
                    snapshot: TaskSnapshot {
                        id,
                        adapter_id: "mock".to_owned(),
                        prompt_preview: "test".to_owned(),
                        title: None,
                        pending_interaction: None,
                        cwd: directory.path().to_owned(),
                        status: TaskStatus::Running,
                        created_at_ms: index as u64,
                        updated_at_ms: index as u64,
                        latest_message: None,
                        session_id: None,
                        turn_count: 1,
                        adapter_options: BTreeMap::new(),
                    },
                    prompt: "test".to_owned(),
                    output: Vec::new(),
                    output_bytes: 0,
                    output_truncated: false,
                    next_output_sequence: 0,
                    cancel: None,
                    runner: None,
                    response_pending: false,
                    chain: None,
                },
            );
        }
        let tasks = task_store(entries);
        let adapters = adapter_store("mock", PathBuf::from("/usr/bin/true"));

        let response = start_task(
            Uuid::from_u128(1000),
            "mock".to_owned(),
            "test".to_owned(),
            directory.path().to_owned(),
            BTreeMap::new(),
            tasks,
            adapters,
        )
        .await;

        assert!(matches!(
            response,
            DaemonResponse::Error { code, .. } if code == "task_capacity"
        ));
    }

    #[tokio::test]
    async fn history_eviction_keeps_task_with_pending_response() {
        let directory = tempfile::tempdir().unwrap();
        let mut entries = HashMap::new();
        let protected_id = Uuid::from_u128(1);
        let evictable_id = Uuid::from_u128(2);
        for index in 0..MAX_STORED_TASKS {
            let id = Uuid::from_u128(index as u128 + 1);
            entries.insert(
                id,
                TaskEntry {
                    snapshot: TaskSnapshot {
                        id,
                        adapter_id: "mock".to_owned(),
                        prompt_preview: "test".to_owned(),
                        title: None,
                        pending_interaction: None,
                        cwd: directory.path().to_owned(),
                        status: TaskStatus::Completed,
                        created_at_ms: index as u64,
                        updated_at_ms: index as u64,
                        latest_message: None,
                        session_id: None,
                        turn_count: 1,
                        adapter_options: BTreeMap::new(),
                    },
                    prompt: String::new(),
                    output: Vec::new(),
                    output_bytes: 0,
                    output_truncated: false,
                    next_output_sequence: 0,
                    cancel: None,
                    runner: None,
                    response_pending: id == protected_id,
                    chain: None,
                },
            );
        }
        let tasks = task_store(entries);
        let adapters = adapter_store("mock", PathBuf::from("/usr/bin/true"));

        let response = start_task(
            Uuid::from_u128(1000),
            "mock".to_owned(),
            "test".to_owned(),
            directory.path().to_owned(),
            BTreeMap::new(),
            tasks.clone(),
            adapters,
        )
        .await;

        assert!(matches!(response, DaemonResponse::Task { .. }));
        let entries = tasks.read().await;
        assert!(entries.contains_key(&protected_id));
        assert!(!entries.contains_key(&evictable_id));
        drop(entries);
        shutdown_tasks(&tasks).await;
    }

    #[tokio::test]
    async fn repeated_start_id_does_not_spawn_a_second_task() {
        let directory = tempfile::tempdir().unwrap();
        let tasks = task_store(HashMap::new());
        let adapters = adapter_store("mock", PathBuf::from("/usr/bin/true"));
        let id = Uuid::new_v4();

        let first = start_task(
            id,
            "mock".to_owned(),
            "first".to_owned(),
            directory.path().to_owned(),
            BTreeMap::new(),
            tasks.clone(),
            adapters.clone(),
        )
        .await;
        let second = start_task(
            id,
            "mock".to_owned(),
            "second".to_owned(),
            directory.path().to_owned(),
            BTreeMap::new(),
            tasks.clone(),
            adapters,
        )
        .await;

        assert!(matches!(
            first,
            DaemonResponse::Task {
                task: TaskSnapshot { id: task_id, .. }
            } if task_id == id
        ));
        assert!(matches!(
            second,
            DaemonResponse::Task {
                task: TaskSnapshot { id: task_id, .. }
            } if task_id == id
        ));
        assert_eq!(tasks.read().await.len(), 1);
        shutdown_tasks(&tasks).await;
    }

    #[test]
    fn duplicate_adapter_ids_are_rejected() {
        let executable = std::env::current_exe().unwrap();
        let registrations = vec![
            AdapterRegistration {
                id: "mock".to_owned(),
                executable: executable.clone(),
                environment: BTreeMap::new(),
            },
            AdapterRegistration {
                id: "mock".to_owned(),
                executable,
                environment: BTreeMap::new(),
            },
        ];

        let error = validate_adapters(registrations).unwrap_err();

        assert!(error.to_string().contains("registered more than once"));
    }

    #[test]
    fn adapter_environment_rejects_process_environment_keys() {
        let mut registration = test_adapter("mock", std::env::current_exe().unwrap());
        registration
            .environment
            .insert("PATH".to_owned(), "/usr/bin".to_owned());

        let error = validate_adapter(registration).unwrap_err();

        assert!(error.to_string().contains("environment key is invalid"));
    }

    #[tokio::test]
    async fn adapter_can_be_registered_while_daemon_is_running() {
        let adapters = Arc::new(RwLock::new(HashMap::new()));
        let tasks = task_store(HashMap::new());
        let executable = std::env::current_exe().unwrap();
        let response = register_adapter(
            "dynamic".to_owned(),
            executable.clone(),
            BTreeMap::from([("RELAY_DYNAMIC_PATH".to_owned(), "/usr/bin/true".to_owned())]),
            tasks,
            adapters.clone(),
        )
        .await;

        assert!(matches!(
            response,
            DaemonResponse::AdapterRegistered { adapter_id } if adapter_id == "dynamic"
        ));
        let adapters = adapters.read().await;
        let registered = adapters.get("dynamic").unwrap();
        assert_eq!(
            registered.executable,
            std::fs::canonicalize(executable).unwrap()
        );
        assert_eq!(
            registered.environment.get("RELAY_DYNAMIC_PATH"),
            Some(&"/usr/bin/true".to_owned())
        );
    }

    #[tokio::test]
    async fn adapter_can_be_unregistered_without_invalidating_running_clone() {
        let executable = std::env::current_exe().unwrap();
        let registration = validate_adapter(AdapterRegistration {
            id: "dynamic".to_owned(),
            executable,
            environment: BTreeMap::new(),
        })
        .unwrap();
        let adapters = Arc::new(RwLock::new(HashMap::from([(
            registration.id.clone(),
            registration,
        )])));
        let running_clone = adapters.read().await.get("dynamic").unwrap().clone();

        let response = unregister_adapter("dynamic".to_owned(), adapters.clone()).await;

        assert!(matches!(
            response,
            DaemonResponse::AdapterUnregistered { adapter_id } if adapter_id == "dynamic"
        ));
        assert!(!adapters.read().await.contains_key("dynamic"));
        assert_eq!(running_clone.id, "dynamic");

        assert!(matches!(
            unregister_adapter("dynamic".to_owned(), adapters).await,
            DaemonResponse::AdapterUnregistered { adapter_id } if adapter_id == "dynamic"
        ));
    }

    #[tokio::test]
    async fn terminal_adapter_event_does_not_signal_cancellation() {
        let id = Uuid::new_v4();
        let (cancel_sender, mut cancel_receiver) = oneshot::channel();
        let tasks = task_store(HashMap::from([(
            id,
            TaskEntry {
                snapshot: TaskSnapshot {
                    id,
                    adapter_id: "mock".to_owned(),
                    prompt_preview: "test".to_owned(),
                    title: None,
                    pending_interaction: None,
                    cwd: PathBuf::from("/tmp"),
                    status: TaskStatus::Running,
                    created_at_ms: 1,
                    updated_at_ms: 1,
                    latest_message: None,
                    session_id: None,
                    turn_count: 1,
                    adapter_options: BTreeMap::new(),
                },
                prompt: "test".to_owned(),
                output: Vec::new(),
                output_bytes: 0,
                output_truncated: false,
                next_output_sequence: 0,
                cancel: Some(cancel_sender),
                runner: None,
                response_pending: false,
                chain: None,
            },
        )]));

        apply_event(
            &tasks,
            AdapterEvent {
                task_id: id,
                status: TaskStatus::Completed,
                message: None,
                output: None,
                session_id: None,
                interaction: None,
            },
        )
        .await;

        assert!(tasks.read().await.get(&id).unwrap().cancel.is_some());
        assert!(matches!(
            cancel_receiver.try_recv(),
            Err(tokio::sync::oneshot::error::TryRecvError::Empty)
        ));
    }

    #[tokio::test]
    async fn cancellation_before_runner_start_does_not_spawn_adapter() {
        let directory = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let (cancel_sender, cancel_receiver) = oneshot::channel();
        let tasks = task_store(HashMap::from([(
            id,
            TaskEntry {
                snapshot: TaskSnapshot {
                    id,
                    adapter_id: "touch".to_owned(),
                    prompt_preview: "test".to_owned(),
                    title: None,
                    pending_interaction: None,
                    cwd: directory.path().to_owned(),
                    status: TaskStatus::Canceled,
                    created_at_ms: 1,
                    updated_at_ms: 1,
                    latest_message: None,
                    session_id: None,
                    turn_count: 1,
                    adapter_options: BTreeMap::new(),
                },
                prompt: "test".to_owned(),
                output: Vec::new(),
                output_bytes: 0,
                output_truncated: false,
                next_output_sequence: 0,
                cancel: None,
                runner: None,
                response_pending: false,
                chain: None,
            },
        )]));
        let (acknowledged, _acknowledgment) = oneshot::channel();
        assert!(cancel_sender.send(CancelRequest { acknowledged }).is_ok());

        run_adapter_task(
            id,
            test_adapter("mock", PathBuf::from("/usr/bin/touch")),
            tasks.clone(),
            cancel_receiver,
        )
        .await;

        assert!(!directory.path().join("run").exists());
        assert_eq!(
            tasks.read().await.get(&id).unwrap().snapshot.status,
            TaskStatus::Canceled
        );
    }

    #[tokio::test]
    async fn terminate_child_waits_for_process_group_exit() {
        let directory = tempfile::tempdir().unwrap();
        let mut child = Command::new("/bin/sh")
            .arg("-c")
            .arg("sleep 30 & echo $! > descendant.pid; exec 1>&-; exec 2>&-; sleep 30")
            .current_dir(directory.path())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .unwrap();
        let process_group = i32::try_from(child.id().unwrap()).unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while !directory.path().join("descendant.pid").exists() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert!(process_group_exists(process_group).unwrap());

        terminate_child(&mut child, Some(process_group))
            .await
            .unwrap();

        assert!(!process_group_exists(process_group).unwrap());
    }

    #[tokio::test]
    async fn cancellation_is_observed_after_adapter_closes_stdout() {
        let directory = tempfile::tempdir().unwrap();
        let adapter = directory.path().join("adapter.sh");
        std::fs::write(
            &adapter,
            "#!/bin/sh\ntouch stdout-closed\nexec 1>&-\nsleep 30\n",
        )
        .unwrap();
        std::fs::set_permissions(&adapter, std::fs::Permissions::from_mode(0o700)).unwrap();
        let id = Uuid::new_v4();
        let (cancel_sender, cancel_receiver) = oneshot::channel();
        let tasks = task_store(HashMap::from([(
            id,
            TaskEntry {
                snapshot: TaskSnapshot {
                    id,
                    adapter_id: "script".to_owned(),
                    prompt_preview: "test".to_owned(),
                    title: None,
                    pending_interaction: None,
                    cwd: directory.path().to_owned(),
                    status: TaskStatus::Queued,
                    created_at_ms: 1,
                    updated_at_ms: 1,
                    latest_message: None,
                    session_id: None,
                    turn_count: 1,
                    adapter_options: BTreeMap::new(),
                },
                prompt: "test".to_owned(),
                output: Vec::new(),
                output_bytes: 0,
                output_truncated: false,
                next_output_sequence: 0,
                cancel: Some(cancel_sender),
                runner: None,
                response_pending: false,
                chain: None,
            },
        )]));
        let runner_tasks = tasks.clone();
        let runner = tokio::spawn(async move {
            run_adapter_task(
                id,
                test_adapter("script", adapter),
                runner_tasks,
                cancel_receiver,
            )
            .await;
        });
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while !directory.path().join("stdout-closed").exists() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let response = cancel_task(id, tasks.clone()).await;

        assert!(matches!(
            response,
            DaemonResponse::Task {
                task: TaskSnapshot {
                    status: TaskStatus::Canceled,
                    ..
                }
            }
        ));
        tokio::time::timeout(std::time::Duration::from_secs(2), runner)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            tasks.read().await.get(&id).unwrap().snapshot.status,
            TaskStatus::Canceled
        );
    }

    #[tokio::test]
    async fn daemon_shutdown_waits_for_adapter_cleanup() {
        let directory = tempfile::tempdir().unwrap();
        let adapter = directory.path().join("adapter.sh");
        std::fs::write(&adapter, "#!/bin/sh\ntouch started\nexec 1>&-\nsleep 30\n").unwrap();
        std::fs::set_permissions(&adapter, std::fs::Permissions::from_mode(0o700)).unwrap();
        let tasks = task_store(HashMap::new());
        let adapters = adapter_store("script", adapter);
        let response = start_task(
            Uuid::new_v4(),
            "script".to_owned(),
            "test".to_owned(),
            directory.path().to_owned(),
            BTreeMap::new(),
            tasks.clone(),
            adapters,
        )
        .await;
        let DaemonResponse::Task { task } = response else {
            panic!("task did not start");
        };
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while !directory.path().join("started").exists() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();

        tokio::time::timeout(
            PROCESS_GROUP_EXIT_TIMEOUT + std::time::Duration::from_secs(1),
            shutdown_tasks(&tasks),
        )
        .await
        .unwrap();

        let entries = tasks.read().await;
        let snapshot = &entries.get(&task.id).unwrap().snapshot;
        assert_eq!(
            snapshot.status,
            TaskStatus::Canceled,
            "unexpected shutdown result: {:?}",
            snapshot.latest_message
        );
    }

    #[tokio::test]
    async fn continuation_reuses_session_and_appends_user_output() {
        let directory = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let tasks = task_store(HashMap::from([(
            id,
            TaskEntry {
                snapshot: TaskSnapshot {
                    id,
                    adapter_id: "mock".to_owned(),
                    prompt_preview: "first".to_owned(),
                    title: None,
                    pending_interaction: None,
                    cwd: directory.path().to_owned(),
                    status: TaskStatus::Completed,
                    created_at_ms: 1,
                    updated_at_ms: 1,
                    latest_message: None,
                    session_id: Some("session-1".to_owned()),
                    turn_count: 1,
                    adapter_options: BTreeMap::from([(
                        "codex_model".to_owned(),
                        "gpt-5.6-sol".to_owned(),
                    )]),
                },
                prompt: String::new(),
                output: Vec::new(),
                output_bytes: 0,
                output_truncated: false,
                next_output_sequence: 0,
                cancel: None,
                runner: None,
                response_pending: false,
                chain: None,
            },
        )]));
        let adapters = adapter_store("mock", PathBuf::from("/usr/bin/true"));

        let response = continue_task(
            id,
            "second".to_owned(),
            BTreeMap::from([("codex_reasoning_effort".to_owned(), "max".to_owned())]),
            tasks.clone(),
            adapters,
        )
        .await;

        assert!(matches!(
            response,
            DaemonResponse::Task {
                task: TaskSnapshot {
                    turn_count: 2,
                    session_id: Some(session_id),
                    ..
                }
            } if session_id == "session-1"
        ));
        let entries = tasks.read().await;
        let entry = entries.get(&id).unwrap();
        assert_eq!(
            entry.snapshot.adapter_options,
            BTreeMap::from([("codex_reasoning_effort".to_owned(), "max".to_owned())])
        );
        assert!(
            entry
                .output
                .iter()
                .any(|item| { item.kind == TaskOutputKind::User && item.text == "second" })
        );
        drop(entries);
        shutdown_tasks(&tasks).await;
    }

    #[tokio::test]
    async fn task_output_response_preserves_event_order() {
        let id = Uuid::new_v4();
        let mut entry = TaskEntry {
            snapshot: TaskSnapshot {
                id,
                adapter_id: "mock".to_owned(),
                prompt_preview: "test".to_owned(),
                title: None,
                pending_interaction: None,
                cwd: PathBuf::from("/tmp"),
                status: TaskStatus::Completed,
                created_at_ms: 1,
                updated_at_ms: 1,
                latest_message: None,
                session_id: Some("session-1".to_owned()),
                turn_count: 1,
                adapter_options: BTreeMap::new(),
            },
            prompt: String::new(),
            output: Vec::new(),
            output_bytes: 0,
            output_truncated: false,
            next_output_sequence: 0,
            cancel: None,
            runner: None,
            response_pending: false,
            chain: None,
        };
        append_task_output(&mut entry, TaskOutputKind::User, "question".to_owned());
        append_task_output(&mut entry, TaskOutputKind::Assistant, "answer".to_owned());
        let tasks = task_store(HashMap::from([(id, entry)]));

        let response = process_request(
            DaemonRequest::GetTaskOutput { id },
            tasks,
            Arc::new(RwLock::new(HashMap::new())),
        )
        .await;

        assert!(matches!(
            response,
            DaemonResponse::TaskOutput { output, truncated: false, .. }
                if output.len() == 2
                    && output[0].kind == TaskOutputKind::User
                    && output[1].kind == TaskOutputKind::Assistant
        ));
    }
}
