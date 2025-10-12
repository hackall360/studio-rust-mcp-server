# Tool Catalogue

The Roblox Studio MCP server exposes a broad set of tools through the Model
Context Protocol. This document summarises each tool, the Roblox Studio systems
it touches, and example prompts that highlight common workflows. Refer to the
[official Studio documentation](https://create.roblox.com/docs/en-us/studio) for
in-depth guidance on the underlying services.

## Overview table

| Tool | Purpose | Roblox Studio documentation |
| ---- | ------- | --------------------------- |
| `run_code` | Execute Luau snippets via the plugin | [Command Bar](https://create.roblox.com/docs/en-us/studio/command-bar) |
| `insert_model` | Search and insert Marketplace models | [InsertService](https://create.roblox.com/docs/en-us/reference/engine/classes/InsertService) |
| `inspect_environment` | Gather read-only session metadata | [Studio overview](https://create.roblox.com/docs/en-us/studio/overview/studio-overview) |
| `environment_control` | Adjust lighting, atmosphere, and ambience | [Lighting reference](https://create.roblox.com/docs/en-us/studio/lighting) |
| `apply_instance_operations` | Batch create/update/delete/reparent/clone | [Instance reference](https://create.roblox.com/docs/en-us/reference/engine/classes/Instance) |
| `manage_scripts` | Create and edit script sources | [Script authoring](https://create.roblox.com/docs/en-us/studio/scripts) |
| `test_and_play_control` | Launch/stop playtests and issue virtual input | [Testing overview](https://create.roblox.com/docs/en-us/studio/testing/intro-to-testing) |
| `editor_session_control` | Modify selection/camera/editor focus | [Explorer & viewport](https://create.roblox.com/docs/en-us/studio/manager/using-explorer) |
| `terrain_operations` | Perform voxel edits | [Terrain editor](https://create.roblox.com/docs/en-us/studio/terrain/terrain-editor-overview) |
| `asset_pipeline` | Manage imports and package publication | [Asset Manager](https://create.roblox.com/docs/en-us/studio/assets/asset-manager) |
| `collection_and_attributes` | Sync tags and attributes | [CollectionService](https://create.roblox.com/docs/en-us/reference/engine/classes/CollectionService) |
| `physics_and_navigation` | Configure collision groups and pathfinding | [Collision groups](https://create.roblox.com/docs/en-us/physics/collision-groups), [Pathfinding](https://create.roblox.com/docs/en-us/studio/pathfinding/pathfinding-overview) |
| `diagnostics_and_metrics` | Collect logs, memory, microprofiler data | [Performance guidance](https://create.roblox.com/docs/en-us/studio/performance/optimization-overview) |
| `data_model_snapshot` | Page through DataModel structure | [DataModel class](https://create.roblox.com/docs/en-us/reference/engine/classes/DataModel) |

## Tool details

### `run_code`
* **Description:** Executes Luau snippets using Studio's command bar context.
* **Best practices:** Run code that is idempotent or wraps mutations in
  [`ChangeHistoryService`](https://create.roblox.com/docs/en-us/reference/engine/classes/ChangeHistoryService)
  markers so work can be undone.
* **Sample prompt:** Invoke `run_code` with
  `Workspace:SetAttribute("Weather", "Storm")` and report confirmation.

### `insert_model`
* **Description:** Searches the Marketplace and inserts the best matching asset
  into `Workspace`.
* **Roblox docs:** Review the Marketplace import guidance in the
  [Asset Manager article](https://create.roblox.com/docs/en-us/studio/assets/asset-manager#marketplace).
* **Sample prompt:** `Insert_model` for "Roblox tree" and tell me the instance
  path of the inserted model.

### `inspect_environment`
* **Description:** Returns JSON describing the Explorer selection, current
  camera, and optionally key services.
* **Use it for:** Quick audits before performing destructive operations.
* **Sample prompt:** Request `selection = { includeFullNames = true }` to review
  the exact hierarchy paths for the currently highlighted instances.

### `environment_control`
* **Description:** Adjusts `Lighting`, `Atmosphere`, `Terrain`, and
  `SoundService` properties in one transaction.
* **Roblox docs:** The [lighting guide](https://create.roblox.com/docs/en-us/studio/lighting) and
  [audio reference](https://create.roblox.com/docs/en-us/reference/engine/classes/SoundService)
  provide deeper explanations of the affected fields.
* **Sample prompt:** Change `ClockTime` to 18.5, enable `SunRaysEffect`, and set
  `SoundService.AmbientReverb` to `City`.

### `apply_instance_operations`
* **Description:** Allows batch creation, updates, deletion, reparenting,
  cloning, and bulk property edits with undo support.
* **Roblox docs:** Use the [Explorer manual](https://create.roblox.com/docs/en-us/studio/manager/using-explorer)
  to ensure instance paths mirror the Studio hierarchy.
* **Sample prompt:** Create a new `Sound` under `Workspace.Audio` and set
  `SoundId`, then clone it twice into `ReplicatedStorage`.

### `manage_scripts`
* **Description:** Manipulates script instances and their source code, including
  renames and metadata retrieval.
* **Roblox docs:** Follow the best practices in the
  [script authoring guide](https://create.roblox.com/docs/en-us/studio/scripts#best-practices)
  when generating code.
* **Sample prompt:** Create a `ModuleScript` under `ReplicatedStorage.Modules`
  named `WeatherController` with starter boilerplate.

### `test_and_play_control`
* **Description:** Starts and stops play sessions, runs TestService suites, and
  sends virtual input steps via `VirtualInputManager`.
* **Roblox docs:** Consult the
  [playtesting guide](https://create.roblox.com/docs/en-us/studio/testing/intro-to-testing) and
  [VirtualInputManager reference](https://create.roblox.com/docs/en-us/reference/engine/classes/VirtualInputManager).
* **Sample prompt:** Launch a solo test, wait for completion, then capture stats
  for a list of GUI visibility targets.

### `editor_session_control`
* **Description:** Issues non-destructive editor commands such as focusing the
  camera on specific instances or opening scripts in the editor.
* **Roblox docs:** See the
  [Explorer overview](https://create.roblox.com/docs/en-us/studio/manager/using-explorer) for
  details on selection behaviour.
* **Sample prompt:** Frame the camera around `Workspace.Castle` with tweening
  enabled.

### `terrain_operations`
* **Description:** Performs high-level voxel edits, including fill, replace, and
  conversion operations.
* **Roblox docs:** The
  [terrain editor overview](https://create.roblox.com/docs/en-us/studio/terrain/terrain-editor-overview)
  outlines how these operations map to the built-in toolset.
* **Sample prompt:** Fill a 16×4×16 block of `Mud` relative to the active camera
  pivot, then replace surrounding `Grass` with `Rock`.

### `asset_pipeline`
* **Description:** Supports Marketplace searches, RBXM imports, and package
  publication flows.
* **Roblox docs:** See the
  [Asset Manager article](https://create.roblox.com/docs/en-us/studio/assets/asset-manager#packages)
  for package-specific notes.
* **Sample prompt:** Import a local `castle.rbxm` file into `ReplicatedStorage`
  and return the top-level instance name.

### `collection_and_attributes`
* **Description:** Lists, adds, removes, and synchronises tags and attributes in
  bulk.
* **Roblox docs:** Review
  [CollectionService best practices](https://create.roblox.com/docs/en-us/studio/collectionservice/collectionservice-overview)
  to decide when to use tags versus attributes.
* **Sample prompt:** Tag all guards under `Workspace.NPCs` with `npc` and
  `guard`, then sync their `Level` attribute to 12.

### `physics_and_navigation`
* **Description:** Manages collision groups and executes pathfinding queries in
  one request.
* **Roblox docs:** Combine the
  [collision group guide](https://create.roblox.com/docs/en-us/physics/collision-groups) with the
  [pathfinding overview](https://create.roblox.com/docs/en-us/studio/pathfinding/pathfinding-overview)
  to understand expected parameters.
* **Sample prompt:** Create an `NPCs` collision group, disable collisions against
  `Environment`, assign a door to `Environment`, and compute a path from the
  lobby to the exit.

### `diagnostics_and_metrics`
* **Description:** Collects recent Studio logs, memory usage, task scheduler
  metrics, and optional microprofiler dumps.
* **Roblox docs:** The
  [performance optimisation guide](https://create.roblox.com/docs/en-us/studio/performance/optimization-overview)
  explains how to interpret these metrics.
* **Sample prompt:** Retrieve the last 100 error logs with severity counts and
  include memory statistics grouped by developer tag.

### `data_model_snapshot`
* **Description:** Traverses the DataModel (optionally filtered) and returns
  structured metadata with pagination support.
* **Roblox docs:** Review the [DataModel reference](https://create.roblox.com/docs/en-us/reference/engine/classes/DataModel) and
  [Instance property documentation](https://create.roblox.com/docs/en-us/reference/engine/classes/Instance#Properties)
  to understand available fields.
* **Sample prompt:** Snapshot `Workspace` and `Lighting` up to depth 2, sampling
  `Material`, `Color`, and `ClockTime` along the way.
