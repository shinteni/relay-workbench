use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;
use uuid::Uuid;

const PROTOCOL_VERSION_TEXT: &str =
    include_str!("../../../apps/RelayGUI/Sources/RelayGUI/Resources/protocol-version.txt");
pub const PROTOCOL_VERSION: u32 = parse_protocol_version(PROTOCOL_VERSION_TEXT);

const fn parse_protocol_version(value: &str) -> u32 {
    let bytes = value.as_bytes();
    let mut index = 0;
    let mut result = 0u32;
    let mut has_digit = false;
    while index < bytes.len() {
        let byte = bytes[index];
        if byte >= b'0' && byte <= b'9' {
            has_digit = true;
            result = result * 10 + (byte - b'0') as u32;
        } else if byte != b' ' && byte != b'\t' && byte != b'\r' && byte != b'\n' {
            panic!("invalid protocol version");
        }
        index += 1;
    }
    assert!(has_digit && result > 0, "invalid protocol version");
    result
}
pub const MAX_PROMPT_BYTES: usize = 512 * 1024;
pub const MAX_CHAIN_STEPS: usize = 4;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Queued,
    Starting,
    Running,
    WaitingForApproval,
    WaitingForInput,
    Completed,
    Failed,
    Canceled,
}

impl TaskStatus {
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Canceled)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TaskSnapshot {
    pub id: Uuid,
    pub adapter_id: String,
    pub prompt_preview: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_interaction: Option<Box<AdapterInteraction>>,
    pub cwd: PathBuf,
    pub status: TaskStatus,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    pub latest_message: Option<String>,
    pub session_id: Option<String>,
    pub turn_count: u32,
    pub adapter_options: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TaskOutputKind {
    User,
    Assistant,
    Tool,
    System,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AdapterInteractionKind {
    Approval,
    Input,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterInteractionOption {
    pub value: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterInteractionQuestion {
    pub id: String,
    pub prompt: String,
    #[serde(default)]
    pub options: Vec<AdapterInteractionOption>,
    #[serde(default)]
    pub allow_custom: bool,
    #[serde(default)]
    pub secret: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterInteraction {
    pub id: String,
    pub kind: AdapterInteractionKind,
    pub title: String,
    pub message: String,
    #[serde(default)]
    pub actions: Vec<AdapterInteractionOption>,
    #[serde(default)]
    pub questions: Vec<AdapterInteractionQuestion>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterInteractionResponse {
    pub interaction_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
    #[serde(default)]
    pub answers: BTreeMap<String, Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TaskOutput {
    pub sequence: u64,
    pub timestamp_ms: u64,
    pub kind: TaskOutputKind,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChainStep {
    pub adapter_id: String,
    #[serde(default)]
    pub options: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DaemonRequest {
    Ping,
    StartTask {
        id: Uuid,
        adapter_id: String,
        prompt: String,
        cwd: PathBuf,
        #[serde(default)]
        options: BTreeMap<String, String>,
    },
    StartChain {
        id: Uuid,
        prompt: String,
        cwd: PathBuf,
        steps: Vec<ChainStep>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        note: Option<String>,
    },
    ContinueTask {
        id: Uuid,
        prompt: String,
        #[serde(default)]
        options: BTreeMap<String, String>,
    },
    GetTask {
        id: Uuid,
    },
    GetTaskOutput {
        id: Uuid,
    },
    ListTasks,
    CancelTask {
        id: Uuid,
    },
    DeleteTask {
        id: Uuid,
    },
    RenameTask {
        id: Uuid,
        title: String,
    },
    RespondToInteraction {
        id: Uuid,
        response: AdapterInteractionResponse,
    },
    RegisterAdapter {
        id: String,
        executable: PathBuf,
        #[serde(default)]
        environment: BTreeMap<String, String>,
    },
    UnregisterAdapter {
        id: String,
    },
    Shutdown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DaemonResponse {
    Pong {
        protocol_version: u32,
        daemon_version: String,
        adapters: Vec<String>,
    },
    Task {
        task: TaskSnapshot,
    },
    TaskOutput {
        task_id: Uuid,
        output: Vec<TaskOutput>,
        truncated: bool,
    },
    Tasks {
        tasks: Vec<TaskSnapshot>,
    },
    TaskDeleted {
        task_id: Uuid,
    },
    AdapterRegistered {
        adapter_id: String,
    },
    AdapterUnregistered {
        adapter_id: String,
    },
    ShuttingDown,
    Error {
        code: String,
        message: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterRunRequest {
    pub protocol_version: u32,
    pub task_id: Uuid,
    pub prompt: String,
    pub cwd: PathBuf,
    pub session_id: Option<String>,
    #[serde(default)]
    pub options: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterOutput {
    pub kind: TaskOutputKind,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterEvent {
    pub task_id: Uuid,
    pub status: TaskStatus,
    pub message: Option<String>,
    pub output: Option<AdapterOutput>,
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interaction: Option<AdapterInteraction>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    fn task_snapshot() -> TaskSnapshot {
        TaskSnapshot {
            id: Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap(),
            adapter_id: "codex".to_owned(),
            prompt_preview: "run tests".to_owned(),
            title: None,
            pending_interaction: None,
            cwd: PathBuf::from("/tmp/project"),
            status: TaskStatus::Running,
            created_at_ms: 100,
            updated_at_ms: 200,
            latest_message: Some("working".to_owned()),
            session_id: Some("session-1".to_owned()),
            turn_count: 1,
            adapter_options: BTreeMap::from([("codex_model".to_owned(), "gpt-5.6-sol".to_owned())]),
        }
    }

    #[test]
    fn task_status_uses_snake_case() {
        assert_eq!(
            serde_json::to_value(TaskStatus::WaitingForApproval).unwrap(),
            json!("waiting_for_approval")
        );
    }

    #[test]
    fn daemon_request_has_type_tag_and_round_trips() {
        let request = DaemonRequest::ContinueTask {
            id: Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap(),
            prompt: "continue".to_owned(),
            options: BTreeMap::new(),
        };
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["type"], json!("continue_task"));
        assert_eq!(
            serde_json::from_value::<DaemonRequest>(value).unwrap(),
            request
        );
    }

    #[test]
    fn chain_request_round_trips() {
        let request = DaemonRequest::StartChain {
            id: Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap(),
            prompt: "review this change".to_owned(),
            cwd: PathBuf::from("/tmp/project"),
            steps: vec![
                ChainStep {
                    adapter_id: "codex".to_owned(),
                    options: BTreeMap::from([("codex_mode".to_owned(), "plan".to_owned())]),
                },
                ChainStep {
                    adapter_id: "claude".to_owned(),
                    options: BTreeMap::new(),
                },
            ],
            note: Some("Verify the previous answer.".to_owned()),
        };
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["type"], json!("start_chain"));
        assert_eq!(value["steps"][0]["adapter_id"], json!("codex"));
        assert_eq!(
            serde_json::from_value::<DaemonRequest>(value).unwrap(),
            request
        );
    }

    #[test]
    fn daemon_response_has_type_tag_and_round_trips() {
        let response = DaemonResponse::Task {
            task: task_snapshot(),
        };
        let value = serde_json::to_value(&response).unwrap();
        assert_eq!(value["type"], json!("task"));
        assert_eq!(
            serde_json::from_value::<DaemonResponse>(value).unwrap(),
            response
        );
    }

    #[test]
    fn task_deleted_response_round_trips() {
        let task_id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        let response = DaemonResponse::TaskDeleted { task_id };
        let value = serde_json::to_value(&response).unwrap();
        assert_eq!(value["type"], json!("task_deleted"));
        assert_eq!(
            serde_json::from_value::<DaemonResponse>(value).unwrap(),
            response
        );
    }

    #[test]
    fn rename_request_round_trips() {
        let request = DaemonRequest::RenameTask {
            id: Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap(),
            title: "Release audit".to_owned(),
        };
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["type"], json!("rename_task"));
        assert_eq!(
            serde_json::from_value::<DaemonRequest>(value).unwrap(),
            request
        );
    }

    #[test]
    fn snapshot_without_title_remains_compatible() {
        let value = serde_json::to_value(task_snapshot()).unwrap();
        assert!(value.get("title").is_none());
        let decoded = serde_json::from_value::<TaskSnapshot>(value).unwrap();
        assert_eq!(decoded.title, None);
    }

    #[test]
    fn adapter_registration_round_trips() {
        let request = DaemonRequest::RegisterAdapter {
            id: "gemini".to_owned(),
            executable: PathBuf::from("/tmp/gemini-adapter"),
            environment: BTreeMap::from([(
                "RELAY_GEMINI_PATH".to_owned(),
                "/usr/local/bin/gemini".to_owned(),
            )]),
        };
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["type"], json!("register_adapter"));
        assert_eq!(
            serde_json::from_value::<DaemonRequest>(value).unwrap(),
            request
        );
    }

    #[test]
    fn adapter_unregistration_round_trips() {
        let request = DaemonRequest::UnregisterAdapter {
            id: "gemini".to_owned(),
        };
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["type"], json!("unregister_adapter"));
        assert_eq!(
            serde_json::from_value::<DaemonRequest>(value).unwrap(),
            request
        );

        let response = DaemonResponse::AdapterUnregistered {
            adapter_id: "gemini".to_owned(),
        };
        let value = serde_json::to_value(&response).unwrap();
        assert_eq!(value["type"], json!("adapter_unregistered"));
        assert_eq!(
            serde_json::from_value::<DaemonResponse>(value).unwrap(),
            response
        );
    }

    #[test]
    fn adapter_messages_round_trip() {
        let task_id = Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap();
        let request = AdapterRunRequest {
            protocol_version: PROTOCOL_VERSION,
            task_id,
            prompt: "run tests".to_owned(),
            cwd: PathBuf::from("/tmp/project"),
            session_id: None,
            options: BTreeMap::new(),
        };
        let event = AdapterEvent {
            task_id,
            status: TaskStatus::Running,
            message: Some("responding".to_owned()),
            output: Some(AdapterOutput {
                kind: TaskOutputKind::Assistant,
                text: "hello".to_owned(),
            }),
            session_id: Some("session-1".to_owned()),
            interaction: None,
        };
        assert_eq!(
            serde_json::from_str::<AdapterRunRequest>(&serde_json::to_string(&request).unwrap())
                .unwrap(),
            request
        );
        assert_eq!(
            serde_json::from_str::<AdapterEvent>(&serde_json::to_string(&event).unwrap()).unwrap(),
            event
        );
    }

    #[test]
    fn only_finished_statuses_are_terminal() {
        let cases = [
            (TaskStatus::Queued, false),
            (TaskStatus::Starting, false),
            (TaskStatus::Running, false),
            (TaskStatus::WaitingForApproval, false),
            (TaskStatus::WaitingForInput, false),
            (TaskStatus::Completed, true),
            (TaskStatus::Failed, true),
            (TaskStatus::Canceled, true),
        ];
        for (status, expected) in cases {
            assert_eq!(status.is_terminal(), expected, "status: {status:?}");
        }
    }

    #[test]
    fn protocol_version_is_numeric_json() {
        let response = DaemonResponse::Pong {
            protocol_version: PROTOCOL_VERSION,
            daemon_version: "0.2.0".to_owned(),
            adapters: vec!["codex".to_owned(), "claude".to_owned()],
        };
        let value: Value = serde_json::to_value(response).unwrap();
        assert_eq!(value["protocol_version"], json!(PROTOCOL_VERSION));
        assert_eq!(value["adapters"], json!(["codex", "claude"]));
    }

    #[test]
    fn interaction_response_round_trips() {
        let request = DaemonRequest::RespondToInteraction {
            id: Uuid::parse_str("550e8400-e29b-41d4-a716-446655440000").unwrap(),
            response: AdapterInteractionResponse {
                interaction_id: "approval-1".to_owned(),
                action: Some("accept".to_owned()),
                answers: BTreeMap::new(),
            },
        };
        let value = serde_json::to_value(&request).unwrap();
        assert_eq!(value["type"], json!("respond_to_interaction"));
        assert_eq!(
            serde_json::from_value::<DaemonRequest>(value).unwrap(),
            request
        );
    }
}
