use crate::error::Result;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::{extract::State, Json};
use color_eyre::eyre::{Error, OptionExt};
use rmcp::{
    handler::server::tool::Parameters,
    model::{
        CallToolResult, Content, Implementation, ProtocolVersion, ServerCapabilities, ServerInfo,
    },
    schemars, tool, tool_handler, tool_router, ErrorData, ServerHandler,
};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::sync::Arc;
use tokio::sync::oneshot::Receiver;
use tokio::sync::{mpsc, watch, Mutex};
use tokio::time::Duration;
use uuid::Uuid;

pub const STUDIO_PLUGIN_PORT: u16 = 44755;
const LONG_POLL_DURATION: Duration = Duration::from_secs(15);

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct ToolArguments {
    args: ToolArgumentValues,
    id: Option<Uuid>,
}

#[derive(Deserialize, Serialize, Clone, Debug)]
pub struct RunCommandResponse {
    response: String,
    id: Uuid,
}

pub struct AppState {
    process_queue: VecDeque<ToolArguments>,
    output_map: HashMap<Uuid, mpsc::UnboundedSender<Result<String>>>,
    waiter: watch::Receiver<()>,
    trigger: watch::Sender<()>,
}
pub type PackedState = Arc<Mutex<AppState>>;

impl AppState {
    pub fn new() -> Self {
        let (trigger, waiter) = watch::channel(());
        Self {
            process_queue: VecDeque::new(),
            output_map: HashMap::new(),
            waiter,
            trigger,
        }
    }
}

impl ToolArguments {
    fn new(args: ToolArgumentValues) -> (Self, Uuid) {
        Self { args, id: None }.with_id()
    }
    fn with_id(self) -> (Self, Uuid) {
        let id = Uuid::new_v4();
        (
            Self {
                args: self.args,
                id: Some(id),
            },
            id,
        )
    }
}
#[derive(Clone)]
pub struct RBXStudioServer {
    state: PackedState,
    tool_router: rmcp::handler::server::tool::ToolRouter<Self>,
}

#[tool_handler]
impl ServerHandler for RBXStudioServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            protocol_version: ProtocolVersion::V_2025_03_26,
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            server_info: Implementation::from_build_env(),
            instructions: Some(
                "User run_command to query data from Roblox Studio place or to change it"
                    .to_string(),
            ),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct RunCode {
    #[schemars(description = "Code to run")]
    command: String,
}
#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct InsertModel {
    #[schemars(description = "Query to search for the model")]
    query: String,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "snake_case")]
enum TestAndPlayAction {
    #[schemars(description = "Start a standard play solo session and wait for it to finish")]
    PlaySolo,
    #[schemars(description = "Stop any running play, playtest, or test execution session")]
    Stop,
    #[schemars(description = "Execute TestService tests and collect diagnostics")]
    RunTests,
    #[schemars(description = "Start a playtest session (e.g. start server + player)")]
    RunPlaytest,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(rename_all = "camelCase")]
struct TestAndPlayControlOptions {
    #[serde(default)]
    #[schemars(description = "Seconds to wait before treating the action as timed out")]
    timeout_seconds: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Seconds between polling Studio for status updates")]
    poll_interval_seconds: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Optional subset of TestService test names to execute")]
    test_names: Vec<String>,
    #[serde(default)]
    #[schemars(
        description = "Request that the plugin use asynchronous TestService APIs when available"
    )]
    run_async: Option<bool>,
    #[serde(default)]
    #[schemars(description = "Include the captured Studio log history in the response payload")]
    include_log_history: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct TestAndPlayControl {
    #[schemars(description = "Action that should be applied to the current Studio session")]
    action: TestAndPlayAction,
    #[serde(default)]
    #[schemars(description = "Tuning parameters that control how the action is executed")]
    options: Option<TestAndPlayControlOptions>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
enum InstanceOperationAction {
    Create,
    Update,
    Delete,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct InstanceOperation {
    #[schemars(description = "Operation to perform against the instance path")]
    action: InstanceOperationAction,
    #[schemars(description = "Ordered list of instance names to resolve the target path")]
    path: Vec<String>,
    #[serde(default)]
    #[schemars(description = "Optional class name, required for create actions")]
    class_name: Option<String>,
    #[serde(default)]
    #[schemars(description = "Optional explicit instance name override")]
    name: Option<String>,
    #[serde(default)]
    #[schemars(description = "Property bag applied during create/update operations")]
    properties: std::collections::HashMap<String, JsonValue>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct ApplyInstanceOperationsRequest {
    #[schemars(description = "Batch of instance operations that will be processed sequentially")]
    operations: Vec<InstanceOperation>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct InstanceOperationResult {
    #[schemars(description = "Index of the processed operation within the request array")]
    index: usize,
    #[schemars(description = "Resolved operation action")]
    action: InstanceOperationAction,
    #[schemars(description = "Path that was processed for this result")]
    path: Vec<String>,
    #[schemars(description = "True if the operation succeeded, false otherwise")]
    success: bool,
    #[serde(default)]
    #[schemars(description = "Optional detail describing the outcome of the operation")]
    message: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct ApplyInstanceOperationsResponse {
    #[schemars(description = "Per-operation results returned from Studio")]
    results: Vec<InstanceOperationResult>,
    #[serde(default)]
    #[schemars(description = "High level summary of the batch execution")]
    summary: Option<String>,
}

fn default_true() -> bool {
    true
}

fn default_service_list() -> Vec<String> {
    vec![
        "Workspace".to_string(),
        "Players".to_string(),
        "Lighting".to_string(),
        "ReplicatedStorage".to_string(),
        "ServerScriptService".to_string(),
        "StarterGui".to_string(),
    ]
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct InspectSelectionScope {
    #[serde(default = "default_true")]
    #[schemars(description = "Include instance names in the response")]
    include_names: bool,
    #[serde(default = "default_true")]
    #[schemars(description = "Include ClassName metadata in the response")]
    include_class_names: bool,
    #[serde(default = "default_true")]
    #[schemars(description = "Include Instance:GetFullName() in the response")]
    include_full_names: bool,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct InspectCameraScope {
    #[serde(default = "default_true")]
    #[schemars(description = "Include the camera CFrame vectors")]
    include_cframe: bool,
    #[serde(default = "default_true")]
    #[schemars(description = "Include the camera focus CFrame vectors")]
    include_focus: bool,
    #[serde(default = "default_true")]
    #[schemars(description = "Include the camera field of view")]
    include_field_of_view: bool,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct InspectServicesScope {
    #[serde(default = "default_true")]
    #[schemars(description = "Include descendant counts for each requested service")]
    include_counts: bool,
    #[serde(default = "default_service_list")]
    #[schemars(description = "Specific services to inspect; defaults to common Roblox services")]
    services: Vec<String>,
}

impl Default for InspectServicesScope {
    fn default() -> Self {
        Self {
            include_counts: default_true(),
            services: default_service_list(),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct InspectEnvironment {
    #[schemars(description = "Selection inspection options")]
    selection: Option<InspectSelectionScope>,
    #[schemars(description = "Camera inspection options")]
    camera: Option<InspectCameraScope>,
    #[schemars(description = "Service inspection options")]
    services: Option<InspectServicesScope>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct ScriptMetadataSelection {
    #[schemars(description = "Include the class name of the resolved script instance")]
    include_class_name: bool,
    #[schemars(description = "Include the full name of the resolved script instance")]
    include_full_name: bool,
    #[schemars(description = "Include the normalised parent path for the script instance")]
    include_parent_path: bool,
    #[schemars(description = "Include all attributes returned by Instance:GetAttributes()")]
    include_attributes: bool,
    #[schemars(description = "Include the script RunContext when available")]
    include_run_context: bool,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct ManageScriptsRequest {
    #[schemars(description = "Batch of script management operations to process sequentially")]
    operations: Vec<ScriptOperation>,
    #[schemars(description = "Metadata selection applied when operations omit an override")]
    default_metadata: Option<ScriptMetadataSelection>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct ManageScriptsResponse {
    #[schemars(description = "Per-operation results summarising the managed scripts work")]
    results: Vec<ScriptOperationResult>,
    #[serde(default)]
    #[schemars(description = "High level summary string describing the batch outcome")]
    summary: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct ScriptOperationResult {
    #[schemars(description = "Operation type that was processed")]
    action: ScriptOperationKind,
    #[schemars(description = "Normalised path that was targeted for this operation")]
    path: Vec<String>,
    #[schemars(description = "True if the operation succeeded, false if it failed")]
    success: bool,
    #[serde(default)]
    #[schemars(description = "Optional human readable message about the result")]
    message: Option<String>,
    #[serde(default)]
    #[schemars(description = "Source code returned for get_source operations")]
    source: Option<String>,
    #[serde(default)]
    #[schemars(description = "Metadata blob requested by the caller, if any")]
    metadata: Option<JsonValue>,
    #[serde(default)]
    #[schemars(description = "Structured details about the processed operation")]
    details: Option<JsonValue>,
    #[serde(default)]
    #[schemars(
        description = "Collection of diagnostics (lint, syntax errors, etc.) for the request"
    )]
    diagnostics: Vec<ScriptDiagnostic>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct ScriptDiagnostic {
    #[schemars(description = "Diagnostic category, e.g. syntax or lint")]
    #[serde(default)]
    kind: Option<String>,
    #[schemars(description = "Human readable diagnostic message")]
    message: String,
    #[serde(default)]
    #[schemars(description = "1-indexed line number if provided by Studio")]
    line: Option<u32>,
    #[serde(default)]
    #[schemars(description = "1-indexed column number if provided by Studio")]
    column: Option<u32>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "snake_case")]
enum ScriptOperationKind {
    #[schemars(description = "Create a new script at the requested location")]
    Create,
    #[schemars(description = "Fetch the source for an existing script")]
    GetSource,
    #[schemars(description = "Replace the source on an existing script")]
    SetSource,
    #[schemars(description = "Rename an existing script instance")]
    Rename,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
enum ScriptOperation {
    #[serde(rename = "create")]
    Create {
        #[schemars(description = "Target path for the script, including the desired script name")]
        path: Vec<String>,
        #[schemars(
            description = "Roblox class of the script to create (Script, LocalScript, ModuleScript)"
        )]
        #[serde(rename = "scriptType")]
        script_type: ScriptType,
        #[serde(default)]
        #[schemars(description = "Optional source assigned to the script upon creation")]
        source: Option<String>,
        #[serde(default)]
        #[schemars(description = "Optional run context, e.g. Server, Client, or Legacy")]
        run_context: Option<String>,
        #[serde(default)]
        #[schemars(description = "Attributes applied via Instance:SetAttribute")]
        attributes: HashMap<String, JsonValue>,
        #[serde(default)]
        #[schemars(description = "Metadata selection override for this operation")]
        metadata: Option<ScriptMetadataSelection>,
    },
    #[serde(rename = "get_source")]
    GetSource {
        #[schemars(description = "Path to the existing script to inspect")]
        path: Vec<String>,
        #[serde(default)]
        #[schemars(description = "Metadata selection override for this operation")]
        metadata: Option<ScriptMetadataSelection>,
    },
    #[serde(rename = "set_source")]
    SetSource {
        #[schemars(description = "Path to the existing script to update")]
        path: Vec<String>,
        #[schemars(
            description = "New source code that should replace the current script contents"
        )]
        source: String,
        #[serde(default)]
        #[schemars(description = "Metadata selection override for this operation")]
        metadata: Option<ScriptMetadataSelection>,
    },
    #[serde(rename = "rename")]
    Rename {
        #[schemars(description = "Path to the existing script to rename")]
        path: Vec<String>,
        #[schemars(description = "Replacement name for the script instance")]
        new_name: String,
        #[serde(default)]
        #[schemars(description = "Metadata selection override for this operation")]
        metadata: Option<ScriptMetadataSelection>,
    },
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
enum ScriptType {
    #[serde(rename = "Script")]
    Script,
    #[serde(rename = "LocalScript")]
    LocalScript,
    #[serde(rename = "ModuleScript")]
    ModuleScript,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "tool", content = "params")]
enum ToolArgumentValues {
    RunCode(RunCode),
    InsertModel(InsertModel),
    InspectEnvironment(InspectEnvironment),
    ApplyInstanceOperations(ApplyInstanceOperationsRequest),
    ManageScripts(ManageScriptsRequest),
    TestAndPlayControl(TestAndPlayControl),
}
#[tool_router]
impl RBXStudioServer {
    pub fn new(state: PackedState) -> Self {
        Self {
            state,
            tool_router: Self::tool_router(),
        }
    }

    #[tool(
        description = "Runs a command in Roblox Studio and returns the printed output. Can be used to both make changes and retrieve information"
    )]
    async fn run_code(
        &self,
        Parameters(args): Parameters<RunCode>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::RunCode(args))
            .await
    }

    #[tool(
        description = "Inserts a model from the Roblox marketplace into the workspace. Returns the inserted model name."
    )]
    async fn insert_model(
        &self,
        Parameters(args): Parameters<InsertModel>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::InsertModel(args))
            .await
    }

    #[tool(
        description = "Inspects the current Studio environment and returns JSON summarising selection, camera and service state."
    )]
    async fn inspect_environment(
        &self,
        Parameters(args): Parameters<InspectEnvironment>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::InspectEnvironment(args))
            .await
    }

    #[tool(
        description = "Applies a batch of create/update/delete operations against instances in the open Studio session."
    )]
    async fn apply_instance_operations(
        &self,
        Parameters(args): Parameters<ApplyInstanceOperationsRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::ApplyInstanceOperations(args))
            .await
    }

    #[tool(
        description = "Creates, inspects, and edits Script/LocalScript/ModuleScript instances in the current Studio session."
    )]
    async fn manage_scripts(
        &self,
        Parameters(args): Parameters<ManageScriptsRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::ManageScripts(args))
            .await
    }

    #[tool(
        description = "Controls Studio play/test sessions and TestService runs. Supports play_solo, stop, run_tests, and run_playtest."
    )]
    async fn test_and_play_control(
        &self,
        Parameters(args): Parameters<TestAndPlayControl>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::TestAndPlayControl(args))
            .await
    }

    async fn generic_tool_run(
        &self,
        args: ToolArgumentValues,
    ) -> Result<CallToolResult, ErrorData> {
        let (command, id) = ToolArguments::new(args);
        tracing::debug!("Running command: {:?}", command);
        let (tx, mut rx) = mpsc::unbounded_channel::<Result<String>>();
        let trigger = {
            let mut state = self.state.lock().await;
            state.process_queue.push_back(command);
            state.output_map.insert(id, tx);
            state.trigger.clone()
        };
        trigger
            .send(())
            .map_err(|e| ErrorData::internal_error(format!("Unable to trigger send {e}"), None))?;
        let result = rx
            .recv()
            .await
            .ok_or(ErrorData::internal_error("Couldn't receive response", None))?;
        {
            let mut state = self.state.lock().await;
            state.output_map.remove_entry(&id);
        }
        tracing::debug!("Sending to MCP: {result:?}");
        match result {
            Ok(result) => Ok(CallToolResult::success(vec![Content::text(result)])),
            Err(err) => Ok(CallToolResult::error(vec![Content::text(err.to_string())])),
        }
    }
}

pub async fn request_handler(State(state): State<PackedState>) -> Result<impl IntoResponse> {
    let timeout = tokio::time::timeout(LONG_POLL_DURATION, async {
        loop {
            let mut waiter = {
                let mut state = state.lock().await;
                if let Some(task) = state.process_queue.pop_front() {
                    return Ok::<ToolArguments, Error>(task);
                }
                state.waiter.clone()
            };
            waiter.changed().await?
        }
    })
    .await;
    match timeout {
        Ok(result) => Ok(Json(result?).into_response()),
        _ => Ok((StatusCode::LOCKED, String::new()).into_response()),
    }
}

pub async fn response_handler(
    State(state): State<PackedState>,
    Json(payload): Json<RunCommandResponse>,
) -> Result<impl IntoResponse> {
    tracing::debug!("Received reply from studio {payload:?}");
    let mut state = state.lock().await;
    let tx = state
        .output_map
        .remove(&payload.id)
        .ok_or_eyre("Unknown ID")?;
    Ok(tx.send(Ok(payload.response))?)
}

pub async fn proxy_handler(
    State(state): State<PackedState>,
    Json(command): Json<ToolArguments>,
) -> Result<impl IntoResponse> {
    let id = command.id.ok_or_eyre("Got proxy command with no id")?;
    tracing::debug!("Received request to proxy {command:?}");
    let (tx, mut rx) = mpsc::unbounded_channel();
    {
        let mut state = state.lock().await;
        state.process_queue.push_back(command);
        state.output_map.insert(id, tx);
    }
    let response = rx.recv().await.ok_or_eyre("Couldn't receive response")??;
    {
        let mut state = state.lock().await;
        state.output_map.remove_entry(&id);
    }
    tracing::debug!("Sending back to dud: {response:?}");
    Ok(Json(RunCommandResponse { response, id }))
}

pub async fn dud_proxy_loop(state: PackedState, exit: Receiver<()>) {
    let client = reqwest::Client::new();

    let mut waiter = { state.lock().await.waiter.clone() };
    while exit.is_empty() {
        let entry = { state.lock().await.process_queue.pop_front() };
        if let Some(entry) = entry {
            let res = client
                .post(format!("http://127.0.0.1:{STUDIO_PLUGIN_PORT}/proxy"))
                .json(&entry)
                .send()
                .await;
            if let Ok(res) = res {
                let tx = {
                    state
                        .lock()
                        .await
                        .output_map
                        .remove(&entry.id.unwrap())
                        .unwrap()
                };
                let res = res
                    .json::<RunCommandResponse>()
                    .await
                    .map(|r| r.response)
                    .map_err(Into::into);
                tx.send(res).unwrap();
            } else {
                tracing::error!("Failed to proxy: {res:?}");
            };
        } else {
            waiter.changed().await.unwrap();
        }
    }
}
