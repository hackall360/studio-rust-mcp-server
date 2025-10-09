# Roblox MCP Studio Plugin

The Roblox MCP Studio plugin bridges Roblox Studio with the local MCP server by polling for
requests, invoking Luau tools, and responding with serialized results. This README focuses on
the plugin-only workflow: how its modules are organized, how they correspond to MCP tools, and
how to iterate on the plugin outside of the Rust server runtime.

## Module structure

### Core entrypoint

| Module | Responsibilities |
| --- | --- |
| `src/Main.server.luau` | Creates the HTTP-polling client, receives MCP requests, dispatches them to the tool modules, and streams serialized responses back through `MockWebSocketService`. It also decides when to wrap operations in `ChangeHistoryService:TryBeginRecording`/`FinishRecording` so Studio undo history stays clean for tool calls that mutate the place. |
| `src/MockWebSocketService.luau` | Provides a lightweight shim that mimics Roblox's `WebSocketService` using `HttpService:RequestAsync` to poll `/request` and post to `/response` on the local MCP server. The dispatcher in `Main.server.luau` depends on this shim when running the plugin standalone. |
| `src/Types.luau` | Centralizes all request/response records that every tool module shares (tool argument payloads, result shapes, helper enums). Keep this file in sync with the MCP server schemas to avoid JSON encoding mismatches. |

### Tool dispatchers

Every file under `src/Tools` exports a `Types.ToolFunction` and maps 1:1 with an MCP tool name. The
router in `Main.server.luau` calls each function until one returns a response string.

| Module | MCP tool | High-level responsibilities |
| --- | --- | --- |
| `Tools/ApplyInstanceOperations.luau` | `ApplyInstanceOperations` | Creates, updates, deletes, reparents, clones, and bulk-edits properties/attributes on Instances while enforcing allow-lists and reporting per-path warnings. |
| `Tools/AssetPipeline.luau` | `AssetPipeline` | Loads marketplace, local, or versioned assets via `InsertService`, resolves naming collisions, and drops the resulting instances at target paths. |
| `Tools/CollectionAndAttributes.luau` | `CollectionAndAttributes` | Wraps `CollectionService` and attribute sync operations: list/add/remove tags, synchronize attribute dictionaries, and run tag queries. |
| `Tools/DataModelSnapshot.luau` | `DataModelSnapshot` | Traverses the DataModel from requested roots, gathering structure, properties, attributes, and pagination metadata for snapshot/inspection workflows. |
| `Tools/DiagnosticsAndMetrics.luau` | `DiagnosticsAndMetrics` | Collects log history, memory usage, network/microprofiler stats, and execution trace chunks from `LogService`, `Stats`, and `MicroProfiler` APIs. |
| `Tools/EditorSessionControl.luau` | `EditorSessionControl` | Manages Studio editor ergonomics: select Instances, focus/tween the camera, frame geometry, and report missing targets during collaborative sessions. |
| `Tools/EnvironmentControl.luau` | `EnvironmentControl` | Applies lighting, atmosphere, sky, terrain water, `SoundService`, and post-processing adjustments, emitting change summaries per section. |
| `Tools/InspectEnvironment.luau` | `InspectEnvironment` | Serializes the current selection, camera state, and service availability/counts for environment inspection prompts. |
| `Tools/InsertModel.luau` | `InsertModel` | Searches Roblox marketplace assets, loads the best match into Workspace, and positions the model in front of the camera. |
| `Tools/ManageScripts.luau` | `ManageScripts` | Fetches script source/metadata, validates placement, creates or mutates scripts, and records diagnostics for script operations. |
| `Tools/PhysicsAndNavigation.luau` | `PhysicsAndNavigation` | Handles collision-group CRUD, assignment, physics settings, and pathfinding/navmesh queries for selected parts. |
| `Tools/RunCode.luau` | `RunCode` | Executes arbitrary Luau with sandboxed `print/warn/error` capture, returning serialized output, errors, and return values. |
| `Tools/TerrainOperations.luau` | `TerrainOperations` | Executes voxel terrain fills, replacements, clears, and conversions using region, block, or pivot-driven operations. |
| `Tools/TestAndPlayControl.luau` | `TestAndPlayControl` | Coordinates play solo/server/test sessions, triggers automated tests, proxies user input events, and streams captured run statistics. |

## Standalone Rojo workflow

1. Install the tooling defined in `foreman.toml` (recommended via
   [`foreman`](https://github.com/Roblox/foreman)):
   ```sh
   cd plugin
   foreman install
   ```
2. Build the plugin model without running the Rust MCP server:
   ```sh
   rojo build default.project.json --output MCPStudioPlugin.rbxm
   ```
   This produces a distributable `.rbxm` that you can load directly into Studio.
3. For live iteration with an open Studio session, run Rojo in serve mode:
   ```sh
   rojo serve default.project.json
   ```
   Attach the running project through the Rojo Studio plugin to hot-reload edits under `plugin/src`.
4. When testing outside the main repo pipeline, start Studio, insert the built model, and ensure the
   companion MCP server is reachable at `http://localhost:44755` (or adjust `URI` in
   `Main.server.luau`).

## Debugging tips

- **Verbose logging**: flip the guard in `Main.server.luau`’s local `log` function from `if false`
  to `if true` (or call `warn` directly) to see connection events, request routing, and payload
  validation messages in the Studio output window.
- **HTTP inspection**: because `MockWebSocketService` polls JSON endpoints, you can capture
  `/request` and `/response` traffic with a local proxy (e.g., `mitmproxy`) when diagnosing
  serialization issues.
- **Change history**: the dispatcher wraps mutating tool calls with
  `ChangeHistoryService:TryBeginRecording("StudioMCP")`. If you need to double-check undo stacks,
  search for `shouldRecordHistoryForRequest` in `Main.server.luau` to see which tools are excluded
  and adjust as needed during experiments.
- **Per-tool diagnostics**: many tools accumulate warnings in their responses (for example,
  `ManageScripts` returns placement errors, `EnvironmentControl` summarizes edited sections, and
  `ApplyInstanceOperations` reports unresolved paths). Surface these messages in your MCP client UI
  to accelerate debugging sessions.
- **Console logging in tools**: several modules (such as `EditorSessionControl`) already call
  `print`/`warn` with contextual tags. Augment these logs during development; undo them before
  shipping if they become noisy.

## Roblox API references

These APIs power most of the plugin’s behavior:

- [`ChangeHistoryService`](https://create.roblox.com/docs/reference/engine/classes/ChangeHistoryService)
- [`HttpService:RequestAsync`](https://create.roblox.com/docs/reference/engine/classes/HttpService#RequestAsync)
- [`Selection`](https://create.roblox.com/docs/reference/engine/classes/Selection)
- [`InsertService`](https://create.roblox.com/docs/reference/engine/classes/InsertService)
- [`LogService`](https://create.roblox.com/docs/reference/engine/classes/LogService)
- [`Stats`](https://create.roblox.com/docs/reference/engine/classes/Stats)
- [`Workspace.Terrain`](https://create.roblox.com/docs/reference/engine/classes/Terrain)
- [`RunService`](https://create.roblox.com/docs/reference/engine/classes/RunService)
- [`TweenService`](https://create.roblox.com/docs/reference/engine/classes/TweenService)

Consult the Roblox developer hub for any additional services you call from the tool modules.
