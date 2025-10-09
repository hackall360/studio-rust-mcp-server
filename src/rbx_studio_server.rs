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
                "Use tools like run_code, insert_model, inspect_environment, environment_control, apply_instance_operations, manage_scripts, test_and_play_control, editor_session_control, terrain_operations, asset_pipeline, collection_and_attributes, physics_and_navigation, diagnostics_and_metrics, and data_model_snapshot. See the README for the complete catalog and usage notes."
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
    #[schemars(description = "Send a sequence of key and mouse events to the active play session")]
    SendInput,
    #[schemars(
        description = "Capture requested telemetry from the active play or playtest session"
    )]
    CaptureStats,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct TestAndPlayTelemetryFlags {
    #[serde(default)]
    #[schemars(description = "Include RunService:IsRunning and IsRunMode values in the payload")]
    include_run_state: Option<bool>,
    #[serde(default)]
    #[schemars(description = "Include the local player's humanoid root position when available")]
    include_local_player_position: Option<bool>,
    #[serde(default)]
    #[schemars(
        description = "Include visibility state for each supplied watch target (e.g. GUI paths)"
    )]
    include_gui_visibility: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum VirtualInputStep {
    #[schemars(
        description = "Send a key press or release using VirtualInputManager::SendKeyEvent"
    )]
    Key {
        #[schemars(description = "Enum.KeyCode name to dispatch (e.g. W, Space, Escape)")]
        key_code: String,
        #[serde(default)]
        #[schemars(description = "True to send a key down event, false for key up")]
        is_down: Option<bool>,
        #[serde(default = "default_false")]
        #[schemars(description = "Mark the key event as a repeat event")]
        is_repeat: bool,
        #[serde(default)]
        #[schemars(description = "Optional text payload delivered with the key event")]
        text: Option<String>,
        #[serde(default)]
        #[schemars(description = "Seconds to wait before running the next input step")]
        delay_seconds: Option<f64>,
    },
    #[schemars(
        description = "Send a mouse button event using VirtualInputManager::SendMouseButtonEvent"
    )]
    MouseButton {
        #[serde(default = "default_zero")]
        #[schemars(description = "Screen X coordinate to associate with the event")]
        x: f64,
        #[serde(default = "default_zero")]
        #[schemars(description = "Screen Y coordinate to associate with the event")]
        y: f64,
        #[schemars(description = "Enum.UserInputType name for the button (e.g. MouseButton1)")]
        button: String,
        #[serde(default = "default_true")]
        #[schemars(description = "True to press the button, false to release")]
        is_down: bool,
        #[serde(default = "default_false")]
        #[schemars(
            description = "If true, Roblox will treat the event as a mouse move while clicking"
        )]
        move_mouse: bool,
        #[serde(default)]
        #[schemars(description = "Seconds to wait before running the next input step")]
        delay_seconds: Option<f64>,
    },
    #[schemars(description = "Send a mouse move using VirtualInputManager::SendMouseMoveEvent")]
    MouseMove {
        #[serde(default = "default_zero")]
        #[schemars(description = "Target absolute screen X coordinate")]
        x: f64,
        #[serde(default = "default_zero")]
        #[schemars(description = "Target absolute screen Y coordinate")]
        y: f64,
        #[serde(default = "default_zero")]
        #[schemars(description = "Delta X applied with the move event")]
        delta_x: f64,
        #[serde(default = "default_zero")]
        #[schemars(description = "Delta Y applied with the move event")]
        delta_y: f64,
        #[serde(default)]
        #[schemars(description = "Seconds to wait before running the next input step")]
        delay_seconds: Option<f64>,
    },
    #[schemars(description = "Pause execution before running the next input step")]
    Wait {
        #[schemars(description = "Seconds to wait before continuing")]
        seconds: f64,
    },
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
    #[serde(default)]
    #[schemars(
        description = "Sequence of key, mouse, and wait steps executed for send_input actions"
    )]
    input_sequence: Vec<VirtualInputStep>,
    #[serde(default)]
    #[schemars(description = "Named watch targets (e.g. GUI instance paths) used for telemetry")]
    watch_targets: Vec<String>,
    #[serde(default)]
    #[schemars(
        description = "Telemetry capture flags applied to send_input or capture_stats runs"
    )]
    telemetry: Option<TestAndPlayTelemetryFlags>,
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
#[serde(rename_all = "snake_case")]
enum InstanceOperationAction {
    Create,
    Update,
    Delete,
    Reparent,
    Clone,
    BulkSetProperties,
}

type InstancePropertyMap = std::collections::HashMap<String, JsonValue>;

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct CreateInstanceOperation {
    #[schemars(
        description = "Ordered list of instance names to resolve the destination parent path"
    )]
    path: Vec<String>,
    #[schemars(description = "Class name for the instance that should be created")]
    class_name: String,
    #[serde(default)]
    #[schemars(description = "Optional explicit instance name override")]
    name: Option<String>,
    #[serde(default)]
    #[schemars(description = "Property bag applied after the instance is created")]
    properties: InstancePropertyMap,
    #[serde(default)]
    #[schemars(description = "Attributes applied after the instance is created")]
    attributes: InstancePropertyMap,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct UpdateInstanceOperation {
    #[schemars(description = "Ordered list of instance names to resolve the target path")]
    path: Vec<String>,
    #[serde(default)]
    #[schemars(description = "Property bag applied to the resolved instance")]
    properties: InstancePropertyMap,
    #[serde(default)]
    #[schemars(
        description = "Attributes applied to the resolved instance. Use JSON null to remove an attribute."
    )]
    attributes: InstancePropertyMap,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct DeleteInstanceOperation {
    #[schemars(description = "Ordered list of instance names to resolve the target path")]
    path: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct ReparentInstanceOperation {
    #[schemars(description = "Ordered list of instance names to resolve the target path")]
    path: Vec<String>,
    #[schemars(description = "Ordered list of instance names describing the new parent location")]
    new_parent_path: Vec<String>,
    #[serde(default)]
    #[schemars(description = "Optional explicit instance name override applied after reparenting")]
    name: Option<String>,
    #[serde(default)]
    #[schemars(description = "Property bag applied after the instance is reparented")]
    properties: InstancePropertyMap,
    #[serde(default)]
    #[schemars(description = "Attributes applied after the instance is reparented")]
    attributes: InstancePropertyMap,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct CloneInstanceOperation {
    #[schemars(
        description = "Ordered list of instance names to resolve the target that should be cloned"
    )]
    path: Vec<String>,
    #[schemars(description = "Number of clones that should be produced (defaults to 1)")]
    clone_count: Option<u32>,
    #[serde(default)]
    #[schemars(description = "Optional destination parent path for the new clones")]
    new_parent_path: Option<Vec<String>>,
    #[serde(default)]
    #[schemars(description = "Optional base name applied to the generated clones")]
    name: Option<String>,
    #[serde(default)]
    #[schemars(description = "Property bag applied to each generated clone")]
    properties: InstancePropertyMap,
    #[serde(default)]
    #[schemars(description = "Attributes applied to each generated clone")]
    attributes: InstancePropertyMap,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct BulkSetPropertiesOperation {
    #[schemars(
        description = "Ordered list of instance paths that should receive the property updates"
    )]
    target_paths: Vec<Vec<String>>,
    #[schemars(description = "Property bag applied to each resolved target instance")]
    properties: InstancePropertyMap,
    #[schemars(description = "Attributes applied to each resolved target instance")]
    attributes: InstancePropertyMap,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "action", rename_all = "snake_case")]
enum InstanceOperation {
    Create(CreateInstanceOperation),
    Update(UpdateInstanceOperation),
    Delete(DeleteInstanceOperation),
    Reparent(ReparentInstanceOperation),
    Clone(CloneInstanceOperation),
    BulkSetProperties(BulkSetPropertiesOperation),
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
    #[serde(default)]
    #[schemars(description = "Optional collection of instance paths affected by the operation")]
    paths: Vec<Vec<String>>,
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
    #[serde(default)]
    #[schemars(description = "True when at least one operation mutated the DataModel")]
    write_occurred: bool,
}

fn default_true() -> bool {
    true
}

fn default_false() -> bool {
    false
}

fn default_zero() -> f64 {
    0.0
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
struct EditorSessionControlRequest {
    #[schemars(
        description = "Action that should be executed against the current Studio editor session"
    )]
    action: EditorSessionControlAction,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "action", rename_all = "snake_case")]
enum EditorSessionControlAction {
    #[schemars(
        description = "Replace the current Studio selection with the provided instance paths"
    )]
    SetSelection {
        #[schemars(description = "Array of instance paths that will be selected in Studio")]
        paths: Vec<Vec<String>>,
    },
    #[schemars(description = "Apply camera transforms such as CFrame, Focus, or FieldOfView")]
    FocusCamera {
        #[serde(default)]
        #[schemars(description = "Optional Camera.CFrame components (12 numbers) to apply")]
        cframe_components: Option<[f64; 12]>,
        #[serde(default)]
        #[schemars(description = "Optional Camera.Focus components (12 numbers) to apply")]
        focus_components: Option<[f64; 12]>,
        #[serde(default)]
        #[schemars(description = "Optional camera field of view in degrees")]
        field_of_view: Option<f64>,
    },
    #[schemars(description = "Frame one or more instances within the viewport camera")]
    FrameInstances {
        #[schemars(description = "Instance paths that should be framed by the camera")]
        paths: Vec<Vec<String>>,
        #[serde(default)]
        #[schemars(description = "Optional tween duration in seconds when moving the camera")]
        tween_seconds: Option<f64>,
    },
    #[schemars(
        description = "Open a script in Studio, optionally focusing a specific line or column"
    )]
    OpenScript {
        #[schemars(
            description = "Instance path resolving to the target Script/LocalScript/ModuleScript"
        )]
        path: Vec<String>,
        #[serde(default)]
        #[schemars(description = "Optional 1-indexed line number to focus in the opened script")]
        line: Option<u32>,
        #[serde(default)]
        #[schemars(description = "Optional 1-indexed column number to focus in the opened script")]
        column: Option<u32>,
        #[serde(default)]
        #[schemars(description = "Request that Studio focus the opened script tab when supported")]
        focus: Option<bool>,
    },
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct EditorSessionControlResponse {
    #[schemars(description = "Identifier of the executed action")]
    action: String,
    #[schemars(description = "True when the editor session control action succeeded")]
    success: bool,
    #[serde(default)]
    #[schemars(description = "Optional message that summarises the action outcome")]
    message: Option<String>,
    #[serde(default)]
    #[schemars(description = "Number of instances affected by the action, when applicable")]
    affected_instances: Option<usize>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(rename_all = "snake_case")]
enum TerrainPivotMode {
    #[default]
    #[schemars(description = "Position operations relative to the active camera pivot")]
    ActiveCamera,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct TerrainPivotPlacement {
    #[schemars(description = "Strategy used to resolve the placement pivot")]
    mode: TerrainPivotMode,
    #[schemars(description = "Optional XYZ offset (studs) applied after resolving the pivot")]
    offset: Option<[f64; 3]>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct TerrainFillBlockOperation {
    #[schemars(description = "CFrame components used when filling the block (12 numbers)")]
    cframe_components: [f64; 12],
    #[schemars(description = "XYZ size of the block in studs")]
    size: [f64; 3],
    #[schemars(description = "Material applied to the filled voxels")]
    material: String,
    #[serde(default)]
    #[schemars(description = "Optional occupancy value clamped between 0 and 1")]
    occupancy: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Treat the translation component as relative to the resolved pivot")]
    pivot_relative: bool,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct TerrainFillRegionOperation {
    #[schemars(description = "Minimum Region3int16 corner (XYZ integers)")]
    corner_min: [i16; 3],
    #[schemars(description = "Maximum Region3int16 corner (XYZ integers)")]
    corner_max: [i16; 3],
    #[schemars(description = "Material applied to the filled region")]
    material: String,
    #[serde(default)]
    #[schemars(description = "Region resolution to use when filling (defaults to 4)")]
    resolution: Option<u32>,
    #[serde(default)]
    #[schemars(
        description = "Treat the voxel coordinates as offsets from the resolved pivot cell"
    )]
    pivot_relative: bool,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct TerrainReplaceMaterialOperation {
    #[schemars(description = "Source material that should be replaced")]
    source_material: String,
    #[schemars(description = "Target material that will be written into the region")]
    target_material: String,
    #[schemars(description = "Minimum Region3int16 corner (XYZ integers)")]
    corner_min: [i16; 3],
    #[schemars(description = "Maximum Region3int16 corner (XYZ integers)")]
    corner_max: [i16; 3],
    #[serde(default)]
    #[schemars(description = "Region resolution to use when replacing (defaults to 4)")]
    resolution: Option<u32>,
    #[serde(default)]
    #[schemars(
        description = "Treat the voxel coordinates as offsets from the resolved pivot cell"
    )]
    pivot_relative: bool,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct TerrainClearRegionOperation {
    #[schemars(description = "Optional minimum Region3int16 corner (XYZ integers)")]
    corner_min: Option<[i16; 3]>,
    #[schemars(description = "Optional maximum Region3int16 corner (XYZ integers)")]
    corner_max: Option<[i16; 3]>,
    #[serde(default)]
    #[schemars(description = "Region resolution to use when clearing (defaults to 4)")]
    resolution: Option<u32>,
    #[serde(default)]
    #[schemars(
        description = "Treat the voxel coordinates as offsets from the resolved pivot cell"
    )]
    pivot_relative: bool,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct TerrainConvertToTerrainOperation {
    #[schemars(description = "Paths to BasePart instances that should be converted to terrain")]
    paths: Vec<Vec<String>>,
    #[serde(default)]
    #[schemars(description = "Resolution to use when converting parts to terrain")]
    resolution: Option<u32>,
    #[serde(default)]
    #[schemars(description = "Optional material override applied to converted voxels")]
    target_material: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum TerrainOperation {
    FillBlock(TerrainFillBlockOperation),
    FillRegion(TerrainFillRegionOperation),
    ReplaceMaterial(TerrainReplaceMaterialOperation),
    ClearRegion(TerrainClearRegionOperation),
    ConvertToTerrain(TerrainConvertToTerrainOperation),
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct TerrainOperationsRequest {
    #[schemars(description = "Ordered set of terrain operations that should be processed")]
    operations: Vec<TerrainOperation>,
    #[schemars(
        description = "Optional placement pivot resolved before applying relative operations"
    )]
    pivot: Option<TerrainPivotPlacement>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct TerrainOperationResult {
    #[schemars(description = "Index of the processed terrain operation")]
    index: usize,
    #[schemars(description = "Operation identifier that was attempted")]
    operation: String,
    #[schemars(description = "True when the operation completed successfully")]
    success: bool,
    #[serde(default)]
    #[schemars(description = "Optional details describing the outcome")]
    message: Option<String>,
    #[serde(default)]
    #[schemars(description = "Structured data returned for the processed operation")]
    details: Option<JsonValue>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct TerrainOperationsResponse {
    #[schemars(description = "Results emitted for each processed terrain operation")]
    results: Vec<TerrainOperationResult>,
    #[serde(default)]
    #[schemars(description = "Optional human readable summary of the batch")]
    summary: Option<String>,
    #[schemars(description = "True when at least one operation wrote to terrain")]
    write_occurred: bool,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "snake_case")]
enum AssetCollisionStrategy {
    #[schemars(description = "Automatically rename the inserted instance to avoid collisions")]
    Rename,
    #[schemars(description = "Remove any conflicting instance before insertion")]
    Overwrite,
    #[schemars(description = "Skip the operation when a conflicting instance exists")]
    Skip,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(rename_all = "snake_case")]
enum AssetPlacementMode {
    #[default]
    #[schemars(description = "Keep the original pivot returned by the asset loader")]
    Preserve,
    #[schemars(description = "Pivot the instance in front of the active Studio camera")]
    Camera,
    #[schemars(description = "Place the instance at the world origin (0, 0, 0)")]
    Origin,
    #[schemars(description = "Use a custom CFrame supplied by the caller")]
    CustomCframe,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct AssetPlacement {
    #[schemars(description = "Placement strategy for spatially-aware instances")]
    mode: AssetPlacementMode,
    #[serde(default)]
    #[schemars(description = "Twelve-number array describing a CFrame when mode is custom_cframe")]
    cframe_components: Option<[f64; 12]>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct PackagePublishRequest {
    #[schemars(description = "Asset name used when publishing the package")]
    package_name: String,
    #[serde(default)]
    #[schemars(description = "Description text to attach to the package upload")]
    description: Option<String>,
    #[serde(default)]
    #[schemars(description = "Roblox group ID to publish under when applicable")]
    group_id: Option<u64>,
    #[serde(default)]
    #[schemars(description = "Allow overwriting an existing package asset with the same name")]
    allow_overwrite: bool,
    #[serde(default)]
    #[schemars(description = "Allow comments on the resulting package asset")]
    allow_comments: bool,
    #[serde(default)]
    #[schemars(description = "Optional tags applied to the published package")]
    tags: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "snake_case")]
enum AssetPipelineOperationKind {
    SearchMarketplace,
    InsertAssetVersion,
    ImportRbxm,
    PublishPackage,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct AssetPipelineOperationResult {
    #[schemars(description = "Operation processed by Studio")]
    action: AssetPipelineOperationKind,
    #[schemars(description = "True when the operation completed successfully")]
    success: bool,
    #[schemars(description = "High level status string such as completed, error, or skipped")]
    status: String,
    #[serde(default)]
    #[schemars(description = "Optional human readable message describing the outcome")]
    message: Option<String>,
    #[serde(default)]
    #[schemars(description = "Structured metadata about the processed operation")]
    details: Option<JsonValue>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct AssetPipelineResponse {
    #[schemars(description = "Per-operation outcomes for the asset pipeline request")]
    results: Vec<AssetPipelineOperationResult>,
    #[serde(default)]
    #[schemars(description = "Optional summary string for the batch execution")]
    summary: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "action", rename_all = "snake_case")]
enum AssetPipelineOperation {
    #[schemars(
        description = "Search the Roblox marketplace for assets matching the provided query"
    )]
    SearchMarketplace {
        #[schemars(description = "Search query used against the marketplace")]
        query: String,
        #[serde(default)]
        #[schemars(description = "Maximum number of results to request (1-50)")]
        limit: Option<u32>,
        #[serde(default)]
        #[schemars(description = "Optional creator name filter when supported")]
        creator_name: Option<String>,
    },
    #[schemars(description = "Insert a specific asset version into the Studio session")]
    InsertAssetVersion {
        #[serde(default)]
        #[schemars(description = "Asset ID used for reference in responses")]
        asset_id: Option<u64>,
        #[schemars(description = "Specific asset version ID to load via InsertService")]
        asset_version_id: u64,
        #[serde(default)]
        #[schemars(description = "Desired name to assign to the inserted root instance")]
        desired_name: Option<String>,
        #[serde(default)]
        #[schemars(description = "Parent path where the inserted instance should be placed")]
        target_parent_path: Option<Vec<String>>,
        #[serde(default)]
        #[schemars(description = "Collision handling strategy for this operation")]
        collision_strategy: Option<AssetCollisionStrategy>,
        #[serde(default)]
        #[schemars(description = "Placement options for PVInstances and Models")]
        placement: Option<AssetPlacement>,
        #[serde(default)]
        #[schemars(description = "Optional package publishing request for the inserted instance")]
        save_as_package: Option<PackagePublishRequest>,
    },
    #[schemars(description = "Import an RBXM/RBXLX file from the local filesystem into Studio")]
    ImportRbxm {
        #[schemars(description = "Absolute filesystem path to the RBXM or RBXLX file")]
        file_path: String,
        #[serde(default)]
        #[schemars(description = "Desired name to assign to the imported root instance")]
        desired_name: Option<String>,
        #[serde(default)]
        #[schemars(description = "Parent path where the imported instance should be placed")]
        target_parent_path: Option<Vec<String>>,
        #[serde(default)]
        #[schemars(description = "Collision handling strategy for this operation")]
        collision_strategy: Option<AssetCollisionStrategy>,
        #[serde(default)]
        #[schemars(description = "Placement options for PVInstances and Models")]
        placement: Option<AssetPlacement>,
        #[serde(default)]
        #[schemars(description = "Optional package publishing request for the imported instance")]
        save_as_package: Option<PackagePublishRequest>,
    },
    #[schemars(description = "Publish an existing instance in the place as a package")]
    PublishPackage {
        #[schemars(description = "Path pointing to the instance that should be published")]
        instance_path: Vec<String>,
        #[schemars(description = "Package publishing configuration")]
        publish: PackagePublishRequest,
    },
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct AssetPipelineRequest {
    #[schemars(description = "Operations to execute sequentially within the asset pipeline")]
    operations: Vec<AssetPipelineOperation>,
    #[serde(default)]
    #[schemars(description = "Fallback parent path applied when operations omit a destination")]
    default_parent_path: Option<Vec<String>>,
    #[serde(default)]
    #[schemars(description = "Default collision strategy when not supplied per operation")]
    default_collision_strategy: Option<AssetCollisionStrategy>,
    #[serde(default)]
    #[schemars(description = "Default placement behaviour when not supplied per operation")]
    default_placement: Option<AssetPlacement>,
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
#[serde(default, rename_all = "camelCase")]
struct DiagnosticsLogOptions {
    #[schemars(description = "Include log entries with error severity")]
    include_errors: bool,
    #[schemars(description = "Include log entries with warning severity")]
    include_warnings: bool,
    #[schemars(description = "Include informational log entries in the response")]
    include_info: bool,
    #[serde(default)]
    #[schemars(description = "Maximum number of log entries to return (most recent first)")]
    max_entries: Option<u32>,
    #[serde(default)]
    #[schemars(description = "Maximum number of log entries per chunk in the response payload")]
    chunk_size: Option<u32>,
}

impl Default for DiagnosticsLogOptions {
    fn default() -> Self {
        Self {
            include_errors: true,
            include_warnings: true,
            include_info: false,
            max_entries: Some(200),
            chunk_size: Some(100),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(default, rename_all = "camelCase")]
struct DiagnosticsServiceSelection {
    #[schemars(description = "Services to inspect for metrics and descendant counts")]
    services: Vec<String>,
    #[schemars(description = "Include descendant counts for each requested service")]
    include_descendant_counts: bool,
    #[schemars(description = "Include memory tag usage when available for the requested services")]
    include_memory_tags: bool,
}

impl Default for DiagnosticsServiceSelection {
    fn default() -> Self {
        Self {
            services: vec![
                "Workspace".to_string(),
                "Players".to_string(),
                "Lighting".to_string(),
                "ReplicatedStorage".to_string(),
                "ServerScriptService".to_string(),
            ],
            include_descendant_counts: true,
            include_memory_tags: true,
        }
    }
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(default, rename_all = "camelCase")]
struct DiagnosticsAndMetricsRequest {
    #[serde(default)]
    #[schemars(description = "Configuration for collecting recent log history")]
    logs: Option<DiagnosticsLogOptions>,
    #[schemars(description = "Include a microprofiler snapshot when permissions allow")]
    include_micro_profiler: bool,
    #[schemars(description = "Collect overall memory statistics for the current Studio session")]
    include_memory_stats: bool,
    #[schemars(description = "Collect task scheduler metrics when available")]
    include_task_scheduler: bool,
    #[serde(default)]
    #[schemars(description = "Selection of services to gather metrics for")]
    service_selection: Option<DiagnosticsServiceSelection>,
}

impl Default for DiagnosticsAndMetricsRequest {
    fn default() -> Self {
        Self {
            logs: Some(DiagnosticsLogOptions::default()),
            include_micro_profiler: false,
            include_memory_stats: true,
            include_task_scheduler: true,
            service_selection: Some(DiagnosticsServiceSelection::default()),
        }
    }
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct CollectionAndAttributesRequest {
    #[schemars(description = "Ordered set of tag or attribute operations to execute")]
    operations: Vec<CollectionAndAttributesOperation>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum CollectionAndAttributesOperation {
    #[schemars(
        description = "Return CollectionService tags (and optional attributes) for specific instances"
    )]
    ListTags {
        #[schemars(description = "Instance paths to inspect for tag metadata")]
        paths: Vec<Vec<String>>,
        #[serde(default)]
        #[schemars(description = "Include Instance:GetAttributes() output for each path")]
        include_attributes: bool,
    },
    #[schemars(description = "Apply CollectionService tags to one or more instances")]
    AddTags {
        #[schemars(description = "Instance paths that will receive the provided tags")]
        paths: Vec<Vec<String>>,
        #[schemars(description = "Tags that should be added to every resolved instance")]
        tags: Vec<String>,
    },
    #[schemars(description = "Remove CollectionService tags from one or more instances")]
    RemoveTags {
        #[schemars(description = "Instance paths that will have the provided tags removed")]
        paths: Vec<Vec<String>>,
        #[schemars(description = "Tags that should be removed from every resolved instance")]
        tags: Vec<String>,
    },
    #[schemars(description = "Synchronise Instance attributes with the provided key/value map")]
    SyncAttributes {
        #[schemars(description = "Instance paths whose attributes will be updated")]
        paths: Vec<Vec<String>>,
        #[schemars(description = "Attributes that should be written via Instance:SetAttribute")]
        attributes: HashMap<String, JsonValue>,
        #[serde(default)]
        #[schemars(
            description = "Remove existing attributes that are not present in the provided map"
        )]
        clear_missing: bool,
    },
    #[schemars(description = "Return all instances that currently have the requested tag")]
    QueryByTag {
        #[schemars(description = "CollectionService tag that should be queried")]
        tag: String,
        #[serde(default)]
        #[schemars(
            description = "Include Instance:GetAttributes() output for each tagged instance"
        )]
        include_attributes: bool,
        #[serde(default)]
        #[schemars(description = "Include Instance path segments for each tagged instance")]
        include_paths: bool,
    },
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct CollectionAndAttributesOperationResult {
    #[schemars(description = "Index of the processed operation within the request array")]
    index: usize,
    #[schemars(description = "Identifier of the executed operation")]
    operation: String,
    #[schemars(description = "True when the operation completed successfully")]
    success: bool,
    #[serde(default)]
    #[schemars(description = "Optional message describing the outcome of the operation")]
    message: Option<String>,
    #[serde(default)]
    #[schemars(description = "Structured details describing the per-instance outcome")]
    details: Option<JsonValue>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct CollectionAndAttributesResponse {
    #[schemars(description = "Per-operation results describing the batch execution")]
    results: Vec<CollectionAndAttributesOperationResult>,
    #[serde(default)]
    #[schemars(description = "Optional human readable summary of the batch")]
    summary: Option<String>,
    #[serde(default)]
    #[schemars(description = "True when at least one operation mutated tags or attributes")]
    write_occurred: bool,
    #[serde(default)]
    #[schemars(description = "Count of instances that were modified during the batch")]
    affected_instances: Option<usize>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
struct PhysicsVector3Components {
    #[schemars(description = "X component in studs")]
    x: f64,
    #[schemars(description = "Y component in studs")]
    y: f64,
    #[schemars(description = "Z component in studs")]
    z: f64,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct PhysicsAgentParameters {
    #[schemars(description = "Agent radius passed to PathfindingService:CreatePath")]
    agent_radius: Option<f64>,
    #[schemars(description = "Agent height passed to PathfindingService:CreatePath")]
    agent_height: Option<f64>,
    #[schemars(description = "Agent jump capability passed to PathfindingService:CreatePath")]
    agent_can_jump: Option<bool>,
    #[schemars(description = "Agent max slope passed to PathfindingService:CreatePath")]
    agent_max_slope: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct PhysicsCollisionGroupCreation {
    #[schemars(description = "Name of the collision group to create")]
    group_name: String,
    #[serde(default)]
    #[schemars(
        description = "Remove an existing collision group with the same name before creating"
    )]
    replace_existing: bool,
    #[serde(default)]
    #[schemars(description = "Optional active state applied after the group is created")]
    active: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct PhysicsCollisionPairTuning {
    #[schemars(description = "Name of the first collision group in the pair")]
    group_a: String,
    #[schemars(description = "Name of the second collision group in the pair")]
    group_b: String,
    #[schemars(description = "Whether the two groups should be collidable")]
    collidable: bool,
    #[serde(default)]
    #[schemars(
        description = "Optional active state override applied to group_a before updating the pair"
    )]
    group_a_active: Option<bool>,
    #[serde(default)]
    #[schemars(
        description = "Optional active state override applied to group_b before updating the pair"
    )]
    group_b_active: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct PhysicsAssignPartRequest {
    #[schemars(description = "Instance path segments that should resolve to a BasePart")]
    path: Vec<String>,
    #[schemars(description = "Collision group that the resolved BasePart will be assigned to")]
    group_name: String,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct PhysicsComputePathOperation {
    #[schemars(description = "World position where the path should begin")]
    start_position: PhysicsVector3Components,
    #[schemars(description = "World position where the path should end")]
    target_position: PhysicsVector3Components,
    #[serde(default)]
    #[schemars(description = "Optional pathfinding parameters forwarded to CreatePath")]
    agent_parameters: Option<PhysicsAgentParameters>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum PhysicsAndNavigationOperation {
    #[schemars(
        description = "Create a PhysicsService collision group if it does not already exist"
    )]
    CreateCollisionGroup(PhysicsCollisionGroupCreation),
    #[schemars(
        description = "Update collidability and optional active state for a collision group pair"
    )]
    SetCollisionEnabled(PhysicsCollisionPairTuning),
    #[schemars(description = "Assign a resolved BasePart to a PhysicsService collision group")]
    AssignPartToGroup(PhysicsAssignPartRequest),
    #[schemars(description = "Compute a navigation path between two world positions")]
    ComputePath(PhysicsComputePathOperation),
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct PhysicsAndNavigationRequest {
    #[schemars(description = "Batch of physics/pathfinding operations to run sequentially")]
    operations: Vec<PhysicsAndNavigationOperation>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct Color3Components {
    #[schemars(description = "Red channel intensity between 0 and 1")]
    r: f64,
    #[schemars(description = "Green channel intensity between 0 and 1")]
    g: f64,
    #[schemars(description = "Blue channel intensity between 0 and 1")]
    b: f64,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct LightingSettings {
    #[serde(default)]
    #[schemars(description = "Ambient light color applied to the scene")]
    ambient: Option<Color3Components>,
    #[serde(default)]
    #[schemars(description = "Outdoor ambient light color")]
    outdoor_ambient: Option<Color3Components>,
    #[serde(default)]
    #[schemars(description = "Brightness applied to all lighting")]
    brightness: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Time of day represented as hours (0-24)")]
    clock_time: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Fog color tint")]
    fog_color: Option<Color3Components>,
    #[serde(default)]
    #[schemars(description = "Fog start distance")]
    fog_start: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Fog end distance")]
    fog_end: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Lighting technology override (e.g. Future, ShadowMap)")]
    technology: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct AtmosphereSettings {
    #[serde(default)]
    #[schemars(description = "Atmospheric density value")]
    density: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Atmosphere height offset")]
    offset: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Atmosphere color tint")]
    color: Option<Color3Components>,
    #[serde(default)]
    #[schemars(description = "Decay color controlling horizon falloff")]
    decay: Option<Color3Components>,
    #[serde(default)]
    #[schemars(description = "Glare intensity")]
    glare: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Haze contribution")]
    haze: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct SkySettings {
    #[serde(default)]
    #[schemars(description = "Skybox asset id for the back face")]
    skybox_bk: Option<String>,
    #[serde(default)]
    #[schemars(description = "Skybox asset id for the bottom face")]
    skybox_dn: Option<String>,
    #[serde(default)]
    #[schemars(description = "Skybox asset id for the front face")]
    skybox_ft: Option<String>,
    #[serde(default)]
    #[schemars(description = "Skybox asset id for the left face")]
    skybox_lf: Option<String>,
    #[serde(default)]
    #[schemars(description = "Skybox asset id for the right face")]
    skybox_rt: Option<String>,
    #[serde(default)]
    #[schemars(description = "Skybox asset id for the top face")]
    skybox_up: Option<String>,
    #[serde(default)]
    #[schemars(description = "Sun texture asset id")]
    sun_texture_id: Option<String>,
    #[serde(default)]
    #[schemars(description = "Moon texture asset id")]
    moon_texture_id: Option<String>,
    #[serde(default)]
    #[schemars(description = "Number of stars visible in the sky")]
    star_count: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Toggle celestial bodies visibility")]
    celestial_bodies_shown: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct TerrainWaterSettings {
    #[serde(default)]
    #[schemars(description = "Water color override")]
    water_color: Option<Color3Components>,
    #[serde(default)]
    #[schemars(description = "Water transparency value (0-1)")]
    water_transparency: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Water wave size")]
    water_wave_size: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Water wave speed")]
    water_wave_speed: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct SoundServiceSettings {
    #[serde(default)]
    #[schemars(description = "Ambient reverb preset name")]
    ambient_reverb: Option<String>,
    #[serde(default)]
    #[schemars(description = "Respect FilteringEnabled flag for descendant sounds")]
    respect_filtering_enabled: Option<bool>,
    #[serde(default)]
    #[schemars(description = "Doppler scale factor applied to 3D sounds")]
    doppler_scale: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Roll-off scale for sound attenuation")]
    rolloff_scale: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct SoundInstanceControl {
    #[schemars(description = "Path to the Sound instance that should be modified")]
    path: Vec<String>,
    #[serde(default)]
    #[schemars(description = "Sound asset id to assign")]
    sound_id: Option<String>,
    #[serde(default)]
    #[schemars(description = "Volume level for the sound")]
    volume: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Playback speed multiplier")]
    playback_speed: Option<f64>,
    #[serde(default)]
    #[schemars(description = "Looped toggle")]
    looped: Option<bool>,
    #[serde(default)]
    #[schemars(description = "If true, play() will be triggered after applying property changes")]
    play: Option<bool>,
    #[serde(default)]
    #[schemars(description = "If true, stop() will be triggered after applying property changes")]
    stop: Option<bool>,
    #[serde(default)]
    #[schemars(description = "Optional playback position to seek to before applying play/stop")]
    time_position: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "effect", rename_all = "snake_case")]
enum PostProcessingEffectEdit {
    Bloom {
        #[serde(default)]
        #[schemars(description = "Optional instance name override to match or assign")]
        name: Option<String>,
        #[serde(default)]
        #[schemars(description = "Enable or disable the effect")]
        enabled: Option<bool>,
        #[serde(default)]
        #[schemars(description = "Bloom intensity value")]
        intensity: Option<f64>,
        #[serde(default)]
        #[schemars(description = "Bloom size value")]
        size: Option<f64>,
        #[serde(default)]
        #[schemars(description = "Bloom threshold value")]
        threshold: Option<f64>,
    },
    ColorCorrection {
        #[serde(default)]
        #[schemars(description = "Optional instance name override to match or assign")]
        name: Option<String>,
        #[serde(default)]
        #[schemars(description = "Enable or disable the effect")]
        enabled: Option<bool>,
        #[serde(default)]
        #[schemars(description = "Brightness offset (-1 to 1)")]
        brightness: Option<f64>,
        #[serde(default)]
        #[schemars(description = "Contrast multiplier (-1 to 1)")]
        contrast: Option<f64>,
        #[serde(default)]
        #[schemars(description = "Saturation offset (-1 to 1)")]
        saturation: Option<f64>,
        #[serde(default)]
        #[schemars(description = "Tint color for the correction")]
        tint_color: Option<Color3Components>,
    },
    DepthOfField {
        #[serde(default)]
        #[schemars(description = "Optional instance name override to match or assign")]
        name: Option<String>,
        #[serde(default)]
        #[schemars(description = "Enable or disable the effect")]
        enabled: Option<bool>,
        #[serde(default)]
        #[schemars(description = "Focus distance for the depth of field")]
        focus_distance: Option<f64>,
        #[serde(default)]
        #[schemars(description = "Radius of the in focus region")]
        in_focus_radius: Option<f64>,
        #[serde(default)]
        #[schemars(description = "Intensity applied to near blur")]
        near_intensity: Option<f64>,
        #[serde(default)]
        #[schemars(description = "Intensity applied to far blur")]
        far_intensity: Option<f64>,
    },
    SunRays {
        #[serde(default)]
        #[schemars(description = "Optional instance name override to match or assign")]
        name: Option<String>,
        #[serde(default)]
        #[schemars(description = "Enable or disable the effect")]
        enabled: Option<bool>,
        #[serde(default)]
        #[schemars(description = "Sun rays intensity")]
        intensity: Option<f64>,
        #[serde(default)]
        #[schemars(description = "Sun rays spread")]
        spread: Option<f64>,
    },
    Blur {
        #[serde(default)]
        #[schemars(description = "Optional instance name override to match or assign")]
        name: Option<String>,
        #[serde(default)]
        #[schemars(description = "Enable or disable the effect")]
        enabled: Option<bool>,
        #[serde(default)]
        #[schemars(description = "Blur size value")]
        size: Option<f64>,
    },
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct EnvironmentControlRequest {
    #[serde(default)]
    #[schemars(description = "Lighting property overrides applied to the current place")]
    lighting: Option<LightingSettings>,
    #[serde(default)]
    #[schemars(description = "Atmosphere overrides created under Lighting if needed")]
    atmosphere: Option<AtmosphereSettings>,
    #[serde(default)]
    #[schemars(description = "Skybox overrides created under Lighting if needed")]
    sky: Option<SkySettings>,
    #[serde(default)]
    #[schemars(description = "Post processing edits applied under Lighting")]
    post_processing: Vec<PostProcessingEffectEdit>,
    #[serde(default)]
    #[schemars(description = "Workspace terrain water configuration")]
    terrain_water: Option<TerrainWaterSettings>,
    #[serde(default)]
    #[schemars(description = "SoundService level configuration")]
    sound_service: Option<SoundServiceSettings>,
    #[serde(default)]
    #[schemars(description = "Targeted sound instance adjustments")]
    sounds: Vec<SoundInstanceControl>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct EnvironmentControlResponse {
    #[schemars(description = "True if all requested adjustments were applied successfully")]
    success: bool,
    #[serde(default)]
    #[schemars(description = "Human readable summary of the applied environment edits")]
    summary: Option<String>,
    #[serde(default)]
    #[schemars(description = "List of granular property changes that were applied")]
    changes: Vec<String>,
    #[serde(default)]
    #[schemars(description = "Validation or runtime issues encountered while applying edits")]
    errors: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct PhysicsAndNavigationOperationResult {
    #[schemars(description = "Index of the processed operation within the batch")]
    index: usize,
    #[schemars(description = "Identifier of the executed operation")]
    operation: String,
    #[schemars(description = "True when the operation completed successfully")]
    success: bool,
    #[serde(default)]
    #[schemars(description = "Optional human readable status message")]
    message: Option<String>,
    #[serde(default)]
    #[schemars(description = "Structured details returned by the operation (such as waypoints)")]
    details: Option<JsonValue>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(rename_all = "camelCase")]
struct PhysicsAndNavigationResponse {
    #[schemars(description = "Per-operation results describing the batch execution")]
    results: Vec<PhysicsAndNavigationOperationResult>,
    #[serde(default)]
    #[schemars(description = "Optional summary of the applied operations")]
    summary: Option<String>,
    #[serde(default)]
    #[schemars(description = "True when at least one operation mutated collision data")]
    write_occurred: bool,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct DataModelSnapshotPropertyPick {
    #[schemars(
        description = "Classes this property pick applies to. When empty the pick applies to every instance."
    )]
    classes: Vec<String>,
    #[schemars(description = "Property names to capture when the pick applies.")]
    properties: Vec<String>,
    #[serde(default)]
    #[schemars(description = "Optional limit on the number of properties sampled from this pick.")]
    sample_count: Option<u32>,
    #[serde(default)]
    #[schemars(description = "Randomise property sampling order when sample_count is set.")]
    randomize: Option<bool>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct DataModelSnapshotRequest {
    #[schemars(
        description = "Instance paths to use as traversal roots. Defaults to the DataModel when omitted."
    )]
    root_paths: Vec<Vec<String>>,
    #[serde(default)]
    #[schemars(
        description = "Maximum traversal depth relative to each root. Depth 0 only returns the root instance."
    )]
    max_depth: Option<u32>,
    #[serde(default)]
    #[schemars(description = "Allow list of class names that should be included in the response.")]
    class_allow_list: Vec<String>,
    #[serde(default)]
    #[schemars(description = "Block list of class names that should be skipped entirely.")]
    class_block_list: Vec<String>,
    #[serde(default)]
    #[schemars(description = "Include Instance:GetAttributes() in the response for each entry.")]
    include_attributes: Option<bool>,
    #[serde(default)]
    #[schemars(
        description = "Include property values in the response. Defaults to true when property picks are supplied."
    )]
    include_properties: Option<bool>,
    #[serde(default)]
    #[schemars(description = "Property selection directives applied while reading instances.")]
    property_picks: Vec<DataModelSnapshotPropertyPick>,
    #[serde(default)]
    #[schemars(description = "Sort children by name before traversal for deterministic ordering.")]
    sort_children_by_name: Option<bool>,
    #[serde(default)]
    #[schemars(description = "Maximum number of entries to return in a single response.")]
    page_size: Option<u32>,
    #[serde(default)]
    #[schemars(
        description = "Cursor identifying the next entry offset when paging through large snapshots."
    )]
    page_cursor: Option<String>,
    #[serde(default)]
    #[schemars(description = "Include Instance:GetFullName() for every returned entry.")]
    include_full_name: Option<bool>,
    #[serde(default)]
    #[schemars(description = "Seed used when randomising sampled property lists.")]
    random_seed: Option<u64>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct DataModelSnapshotInstance {
    #[schemars(description = "Path of the instance relative to the DataModel.")]
    path: Vec<String>,
    #[schemars(description = "Name of the instance.")]
    name: String,
    #[schemars(description = "Class name of the instance.")]
    class_name: String,
    #[serde(default)]
    #[schemars(description = "Full name returned by Instance::GetFullName().")]
    full_name: Option<String>,
    #[schemars(description = "Zero-based depth for the entry relative to the traversal root.")]
    depth: u32,
    #[serde(default)]
    #[schemars(description = "Total number of direct children discovered for the instance.")]
    child_count: Option<u32>,
    #[serde(default)]
    #[schemars(description = "Instance attributes captured for the snapshot entry.")]
    attributes: HashMap<String, JsonValue>,
    #[serde(default)]
    #[schemars(description = "Property values captured for the snapshot entry.")]
    properties: HashMap<String, JsonValue>,
    #[serde(default)]
    #[schemars(description = "Errors encountered while reading requested properties.")]
    property_errors: Vec<DataModelSnapshotPropertyError>,
    #[serde(default)]
    #[schemars(description = "Error message captured when attribute access failed.")]
    attribute_error: Option<String>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct DataModelSnapshotPropertyError {
    #[schemars(description = "Name of the property that failed to read.")]
    property: String,
    #[schemars(
        description = "Error message returned by Studio when attempting to read the property."
    )]
    message: String,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone, Default)]
#[serde(default, rename_all = "camelCase")]
struct DataModelSnapshotResponse {
    #[schemars(description = "Snapshot entries captured for this response page.")]
    entries: Vec<DataModelSnapshotInstance>,
    #[serde(default)]
    #[schemars(description = "Cursor for requesting the next page when pagination is enabled.")]
    next_cursor: Option<String>,
    #[schemars(description = "Number of instances that matched the supplied filters.")]
    total_matched: u64,
    #[schemars(
        description = "Number of instances visited during traversal including filtered entries."
    )]
    total_visited: u64,
    #[schemars(description = "True when traversal was truncated due to depth or paging limits.")]
    truncated: bool,
    #[serde(default)]
    #[schemars(description = "Metadata describing the snapshot execution.")]
    metadata: HashMap<String, JsonValue>,
}

#[derive(Debug, Deserialize, Serialize, schemars::JsonSchema, Clone)]
#[serde(tag = "tool", content = "params")]
enum ToolArgumentValues {
    RunCode(RunCode),
    InsertModel(InsertModel),
    InspectEnvironment(InspectEnvironment),
    EnvironmentControl(EnvironmentControlRequest),
    ApplyInstanceOperations(ApplyInstanceOperationsRequest),
    ManageScripts(ManageScriptsRequest),
    TestAndPlayControl(TestAndPlayControl),
    EditorSessionControl(EditorSessionControlRequest),
    TerrainOperations(TerrainOperationsRequest),
    AssetPipeline(AssetPipelineRequest),
    CollectionAndAttributes(CollectionAndAttributesRequest),
    PhysicsAndNavigation(PhysicsAndNavigationRequest),
    DiagnosticsAndMetrics(DiagnosticsAndMetricsRequest),
    DataModelSnapshot(DataModelSnapshotRequest),
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
        description = "Configures lighting, atmosphere, post processing, terrain water, and ambient soundscape settings."
    )]
    async fn environment_control(
        &self,
        Parameters(args): Parameters<EnvironmentControlRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::EnvironmentControl(args))
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

    #[tool(
        description = "Controls editor session state such as selection, camera transforms, framing, and opening scripts."
    )]
    async fn editor_session_control(
        &self,
        Parameters(args): Parameters<EditorSessionControlRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::EditorSessionControl(args))
            .await
    }

    #[tool(
        description = "Applies bulk terrain authoring operations such as fill_block, fill_region, replace_material, clear_region, and convert_to_terrain."
    )]
    async fn terrain_operations(
        &self,
        Parameters(args): Parameters<TerrainOperationsRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::TerrainOperations(args))
            .await
    }

    #[tool(
        description = "Executes asset pipeline workflows including marketplace search, insertion, filesystem import, and package publishing."
    )]
    async fn asset_pipeline(
        &self,
        Parameters(args): Parameters<AssetPipelineRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::AssetPipeline(args))
            .await
    }

    #[tool(
        description = "Manages CollectionService tags and instance attributes, supporting list_tags, add_tags, remove_tags, sync_attributes, and query_by_tag."
    )]
    async fn collection_and_attributes(
        &self,
        Parameters(args): Parameters<CollectionAndAttributesRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::CollectionAndAttributes(args))
            .await
    }

    #[tool(
        description = "Coordinates PhysicsService collision groups and PathfindingService navigation queries."
    )]
    async fn physics_and_navigation(
        &self,
        Parameters(args): Parameters<PhysicsAndNavigationRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::PhysicsAndNavigation(args))
            .await
    }

    #[tool(
        description = "Collects diagnostics such as recent log history (chunked), memory usage, optional microprofiler dumps, and scheduler stats."
    )]
    async fn diagnostics_and_metrics(
        &self,
        Parameters(args): Parameters<DiagnosticsAndMetricsRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::DiagnosticsAndMetrics(args))
            .await
    }

    #[tool(
        description = "Collects read-only snapshots of the DataModel with optional class filters, property sampling, and pagination."
    )]
    async fn data_model_snapshot(
        &self,
        Parameters(args): Parameters<DataModelSnapshotRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        self.generic_tool_run(ToolArgumentValues::DataModelSnapshot(args))
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
