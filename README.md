# Roblox Studio MCP Server

This repository contains a reference implementation of the Model Context Protocol (MCP) that enables
communication between Roblox Studio via a plugin and [Claude Desktop](https://claude.ai/download) or [Cursor](https://www.cursor.com/).
It consists of the following Rust-based components, which communicate through internal shared
objects.

- A web server built on `axum` that a Studio plugin long polls.
- A `rmcp` server that talks to Claude via `stdio` transport.

When LLM requests to run a tool, the plugin will get a request through the long polling and post a
response. It will cause responses to be sent to the Claude app.

**Please note** that this MCP server will be accessed by third-party tools, allowing them to modify
and read the contents of your opened place. Third-party data handling and privacy practices are
subject to their respective terms and conditions.

![Scheme](MCP-Server.png)

The setup process also contains a short plugin installation and Claude Desktop configuration script.

## Setup

### Install with release binaries

This MCP Server supports pretty much any MCP Client but will automatically set up only [Claude Desktop](https://claude.ai/download) and [Cursor](https://www.cursor.com/) if found.

To set up automatically:

1. Ensure you have [Roblox Studio](https://create.roblox.com/docs/en-us/studio/setup),
   and [Claude Desktop](https://claude.ai/download)/[Cursor](https://www.cursor.com/) installed and started at least once.
1. Exit MCP Clients and Roblox Studio if they are running.
1. Download and run the installer:
   1. Go to the [releases](https://github.com/Roblox/studio-rust-mcp-server/releases) page and
      download the latest release for your platform.
   1. Unzip the downloaded file if necessary and run the installer.
   1. Restart Claude/Cursor and Roblox Studio if they are running.

### Setting up manually

To set up manually add following to your MCP Client config:

```json
{
  "mcpServers": {
    "Roblox Studio": {
      "args": [
        "--stdio"
      ],
      "command": "Path-to-downloaded\\rbx-studio-mcp.exe"
    }
  }
}
```

On macOS the path would be something like `"/Applications/RobloxStudioMCP.app/Contents/MacOS/rbx-studio-mcp"` if you move the app to the Applications directory.

### Build from source

To build and install the MCP reference implementation from this repository's source code:

1. Ensure you have [Roblox Studio](https://create.roblox.com/docs/en-us/studio/setup) and
   [Claude Desktop](https://claude.ai/download) installed and started at least once.
1. Exit Claude and Roblox Studio if they are running.
1. [Install](https://www.rust-lang.org/tools/install) Rust.
1. Download or clone this repository.
1. Run the following command from the root of this repository.
   ```sh
   cargo run
   ```
   This command carries out the following actions:
      - Builds the Rust MCP server app.
      - Sets up Claude to communicate with the MCP server.
      - Builds and installs the Studio plugin to communicate with the MCP server.

After the command completes, the Studio MCP Server is installed and ready for your prompts from
Claude Desktop.

## Verify setup

To make sure everything is set up correctly, follow these steps:

1. In Roblox Studio, click on the **Plugins** tab and verify that the MCP plugin appears. Clicking on
   the icon toggles the MCP communication with Claude Desktop on and off, which you can verify in
   the Roblox Studio console output.
1. In the console, verify that `The MCP Studio plugin is ready for prompts.` appears in the output.
   Clicking on the plugin's icon toggles MCP communication with Claude Desktop on and off,
   which you can also verify in the console output.
1. Verify that Claude Desktop is correctly configured by clicking on the hammer icon for MCP tools
   beneath the text field where you enter prompts. This should open a window with the list of
   available Roblox Studio tools (`insert_model`, `inspect_environment`, and `run_code`).

**Note**: You can fix common issues with setup by restarting Studio and Claude Desktop. Claude
sometimes is hidden in the system tray, so ensure you've exited it completely.

## Send requests

1. Open a place in Studio.
1. Type a prompt in Claude Desktop and accept any permissions to communicate with Studio.
1. Verify that the intended action is performed in Studio by checking the console, inspecting the
   data model in Explorer, or visually confirming the desired changes occurred in your place.

## Available MCP tools

Claude Desktop and Cursor expose the following Roblox Studio tooling through this server:

- **`run_code`** – Execute Luau snippets directly in Studio and stream any printed output or return
  values back to the client.
- **`insert_model`** – Search for a marketplace model by name, insert the best match into the
  workspace, and report the name of the created instance.
- **`inspect_environment`** – Collect read-only information about the current Studio session. The
  tool accepts an object with optional sections that let you tailor the response:
  - `selection`: Controls which properties of selected instances are reported. `includeNames`,
    `includeClassNames`, and `includeFullNames` default to `true` and determine whether those fields
    are present in the response.
  - `camera`: Describes what camera details to emit. Toggle `includeCFrame`, `includeFocus`, and
    `includeFieldOfView` (all default `true`) to adjust the payload.
  - `services`: Allows you to inspect key services without mutating the place. Provide
    `services = { "Workspace", "Players", ... }` to customize the list and set `includeCounts`
    (default `true`) to gather descendant totals. The plugin serializes the results with
    `HttpService:JSONEncode`, so responses are safe to parse directly in Claude/Cursor prompts.
- **`apply_instance_operations`** – Perform bulk instance edits (create/update/delete) in a single
  checkpointed ChangeHistory batch. Each operation supplies an `action`, an instance `path`
  (`{"Workspace", "Building", "Door"}`), and optional `properties` to write. Create operations
  additionally require a `className`, and you can override the terminal name with `name` when needed.
- **`manage_scripts`** – Scaffold and maintain `Script`, `LocalScript`, and `ModuleScript`
  instances. Combine `create`, `get_source`, `set_source`, and `rename` operations in a single
  request to build new automation, retrieve existing code, or apply edits. Each operation works with
  array-based paths (e.g. `{ "ServerScriptService", "NPC", "Brain" }`) and can opt into metadata such
  as class names, parent paths, attributes, or run contexts. Source updates are syntax-checked before
  Studio applies them, and responses include diagnostics when a change fails.
- **`test_and_play_control`** – Coordinate Studio play sessions and automated tests. The
  `play_solo` and `run_playtest` subcommands drive `StudioService` to start gameplay while
  continuously streaming console output until the run ends or a timeout is reached. `run_tests`
  executes `TestService` suites, recording status transitions, diagnostics, and captured errors.
  The `stop` subcommand issues best-effort shutdown requests for any active play or test run. Each
  response is encoded as JSON so MCP clients can inspect structured fields such as
  `statusUpdates`, `summary`, `chunks`, and `logs`.
- **`asset_pipeline`** – Search the marketplace, insert specific asset versions, import local RBXM
  files, and publish packages without leaving Claude or Cursor. Each operation reports structured
  status including resolved instance paths, collision handling decisions, placement adjustments, and
  optional package metadata.
- **`terrain_operations`** – Execute batches of voxel edits without leaving the chat. Supported
  operations include `fill_block`, `fill_region`, `replace_material`, `clear_region`, and
  `convert_to_terrain`. Each subcommand accepts numeric payloads (CFrame component arrays, Region3int16
  corners, and material enum names) and returns a JSON summary describing whether terrain was mutated,
  the resolved pivots, and any failures. Optional `pivotRelative` flags combine with
  `pivot = { mode = "active_camera", offset = { dx, dy, dz } }` to position edits in front of the
  viewport, making it easy to paint terrain relative to the current shot.
- **`collection_and_attributes`** – Manage CollectionService metadata alongside Instance attributes.
  Chain `list_tags`, `add_tags`, `remove_tags`, `sync_attributes`, and `query_by_tag` operations to audit
  or mutate large sets of instances. Tag operations accept arrays of instance paths and tag strings,
  automatically skip duplicates, and report per-instance outcomes. Attribute syncs accept key/value
  maps (numbers, strings, booleans, Color3 dictionaries, etc.) and optionally prune attributes that
  are missing from the request. The response includes JSON summaries with `writeOccurred` and
  `affectedInstances` fields so you can condition undo checkpoints on whether anything actually
  changed.
- **`diagnostics_and_metrics`** – Gather troubleshooting data from Studio in a single response. The
  tool can stream recent error and warning logs in timestamped chunks, capture memory usage
  (including DeveloperMemoryTag breakdowns), summarise TaskScheduler and service health, and
  optionally return a MicroProfiler snapshot when you have diagnostics permissions enabled.

> **Safety notice:** Starting a play session or running the test harness will execute scripts and
> may mutate workspace state that has not been saved. Ensure critical changes are committed to
> source control or saved locally before invoking the play or test tools, and avoid relying on
> temporary state that might be reset when Studio reloads the environment.

### Inspecting the Studio environment

You can ask Claude or Cursor to sample the current environment by calling:

```json
{
  "tool": "InspectEnvironment",
  "params": {
    "selection": { "includeFullNames": false },
    "camera": { "includeFocus": false },
    "services": { "services": ["Workspace", "Players"], "includeCounts": true }
  }
}
```

The response is JSON with the following sections:

- `selection`: Total selected instances plus per-item `name`, `className`, and `fullName` (opt-in).
- `camera`: Indicates whether `Workspace.CurrentCamera` exists, and includes the CFrame/focus
  vectors and field of view when requested.
- `services`: Reports requested service availability, optionally including descendant counts.
- `metadata.generatedAt`: Timestamp (ISO 8601) that the plugin recorded for traceability.

These payloads are ideal for prompts such as "summarise the selected models" or "describe the camera
setup" without mutating the place or creating ChangeHistory checkpoints.

### Terrain authoring workflow

`terrain_operations` requests look like the following:

```json
{
  "tool": "TerrainOperations",
  "params": {
    "pivot": {
      "mode": "active_camera",
      "offset": [0, -4, -40]
    },
    "operations": [
      {
        "operation": "fill_block",
        "cframeComponents": [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
        "size": [16, 4, 16],
        "material": "Grass",
        "pivotRelative": true
      },
      {
        "operation": "replace_material",
        "cornerMin": [-48, -32, -48],
        "cornerMax": [48, 16, 48],
        "resolution": 4,
        "sourceMaterial": "Grass",
        "targetMaterial": "Mud"
      }
    ]
  }
}
```

Each response is JSON-encoded and includes an array of per-operation results plus a
`writeOccurred` flag. The Studio plugin records undo checkpoints only when `writeOccurred` is true,
so read-only inspections or failed conversions can be issued safely without cluttering the change
history. Terrain edits still modify live data; save frequently, keep backups before running bulk
operations, and double-check the resolved coordinates (reported in the `details` field) before
running destructive actions such as `clear_region`.

### Tag and attribute workflows

Use `collection_and_attributes` when you want to inspect or mutate CollectionService tags and
Instance attributes in bulk. Operations accept arrays of instance paths, tag strings, and attribute
maps, and they produce structured JSON summaries that call out per-instance successes, skips, or
errors. A typical request might look like:

```json
{
  "tool": "CollectionAndAttributes",
  "params": {
    "operations": [
      {
        "operation": "list_tags",
        "paths": [
          ["Workspace", "NPCs", "Guard"],
          ["Workspace", "NPCs", "Merchant"]
        ],
        "includeAttributes": true
      },
      {
        "operation": "add_tags",
        "paths": [["Workspace", "NPCs", "Guard"]],
        "tags": ["npc", "guard", "vendor"]
      },
      {
        "operation": "sync_attributes",
        "paths": [["Workspace", "NPCs", "Guard"]],
        "attributes": {
          "Level": 12,
          "Faction": "CityWatch",
          "PatrolRadius": 48
        }
      },
      {
        "operation": "query_by_tag",
        "tag": "vendor",
        "includePaths": true,
        "includeAttributes": true
      }
    ]
  }
}
```

Best practices when working with tags and attributes:

- **Adopt consistent naming.** Prefer lowercase, hyphenated tags (`npc-guard`) or scoped prefixes
  (`quest.giver`) so collaborators can scan related metadata quickly.
- **Reserve tags for membership, attributes for data.** Tags should answer yes/no questions ("is this
  an interactable?") while attributes store numbers, strings, or booleans that scripts consume.
- **Keep attribute types predictable.** Stick to primitives and common Roblox datatypes (Color3, CFrame
  arrays, Vector3 dictionaries). Mixing types under the same key makes scripted consumers brittle.
- **Prune stale metadata deliberately.** Set `clearMissing = true` on `sync_attributes` when you want
  the plugin to remove attributes that are no longer present in your source of truth.
- **Audit before bulk edits.** Chain `list_tags` before mutating operations so the response clearly
  shows what changed and lets you catch typos before they propagate.

Because the response reports `writeOccurred` and `affectedInstances`, the Studio plugin only commits a
ChangeHistory checkpoint when at least one instance was updated. Read-only batches (for example, only
`list_tags` or `query_by_tag`) avoid polluting the undo stack.

### Example prompts

You can ask Claude or Cursor to stage multiple changes at once. For example, the following prompt
creates a lighting rig and tweaks an existing part in one tool call:

### Bulk instance editing

Use `apply_instance_operations` when you need to touch multiple instances in a single, undoable
batch. The assistant can resolve instance paths, validate allowed property writes, and surface
per-operation errors.

Example natural-language prompt for Claude or Cursor:

```
Use apply_instance_operations to:
1. Create a PointLight at Workspace/LightingRig/PointLight with Brightness 3 and Range 18.
2. Update Workspace/SetPiece/SpotlightCube so its Color is (1, 0.8, 0.6) and Transparency is 0.25.
3. Delete Workspace/Temporary/DebugFolder.
Summarize which edits succeeded and report any validation errors.
```

The MCP client expands that request into JSON similar to:

```json
{
  "tool": "ApplyInstanceOperations",
  "params": {
    "operations": [
      {
        "action": "create",
        "path": ["Workspace", "LightingRig", "PointLight"],
        "className": "PointLight",
        "properties": {
          "Brightness": 3,
          "Range": 18
        }
      },
      {
        "action": "update",
        "path": ["Workspace", "SetPiece", "SpotlightCube"],
        "properties": {
          "Color": { "__type": "Color3", "r": 1, "g": 0.8, "b": 0.6 },
          "Transparency": 0.25
        }
      },
      {
        "action": "delete",
        "path": ["Workspace", "Temporary", "DebugFolder"]
      }
    ]
  }
}
```

Every property write is wrapped in `pcall` and checked against a conservative allowlist (for example,
lights expose `Brightness`, `Color`, and `Range`; base parts allow `Anchored`, `CFrame`, and `Size`).
Create operations are limited to safe classes, and delete operations refuse to destroy the `DataModel`
root or services parented directly under it. Successful batches automatically wrap the work inside
`ChangeHistoryService` waypoints, and the response includes a `writeOccurred` flag so callers can
decide whether to keep or discard the undo checkpoint.

To label a group of instances and synchronise designer-authored metadata, try a prompt like:

```
Use collection_and_attributes to:
1. list_tags for Workspace/Levels/Hub/MerchantStand and Workspace/Levels/Hub/Blacksmith with attributes.
2. add_tags to those same paths with ["shop", "hub-service"].
3. sync_attributes on Workspace/Levels/Hub/MerchantStand with { "OpensAt": 6, "ClosesAt": 22, "Currency": "Gold" } and clearMissing true.
4. query_by_tag for "hub-service" including paths and attributes.
Summarize any skips or errors in the response.
```

### Requesting diagnostics

The `diagnostics_and_metrics` tool accepts a payload that lets you tailor what Studio collects. For
example:

```
{
  "logs": { "maxEntries": 120, "chunkSize": 40 },
  "includeMemoryStats": true,
  "includeTaskScheduler": true,
  "includeMicroProfiler": false,
  "serviceSelection": { "services": ["Workspace", "Players"] }
}
```

Set `includeMicroProfiler` to `true` only after enabling the MicroProfiler in Studio (View →
MicroProfiler or File → Studio Settings → Diagnostics → Allow MicroProfiler). Roblox requires that
permission to be granted per-user; without it the tool will return a note explaining that the dump
is unavailable. Error and warning logs are chunked for long sessions so MCP clients can page through
them without hitting token limits.

To run the automated test suite from Claude or Cursor, you can request:

```
Use test_and_play_control to run_tests with a 90 second timeout and include the full log history.
If any tests fail, summarize the failing cases in the response.
```

## Asset pipeline workflows

The `asset_pipeline` tool extends the plugin with a suite of asset-centric operations that execute in
sequence. Each operation runs inside a single ChangeHistory checkpoint and produces a JSON response
containing a `results` array with per-step status, messages, and structured `details` objects.

### Prerequisites

- You must be signed into Studio with an account that has permission to load the requested asset
  versions and to publish packages (for example, group upload permissions when targeting a group).
- Asset publishing requires a Studio build that exposes `AssetService:CreatePackageUpload`. When the
  API is unavailable, the tool returns a descriptive error without mutating your place.
- Marketplace insertions respect Studio permissions and may fail when content is moderated or
  restricted to certain experiences.

### Supported operations

- `search_marketplace` – Query the Roblox marketplace and return asset metadata (name, creator,
  asset and version IDs). Use `limit` to cap the number of results (default `10`, max `50`).
- `insert_asset_version` – Load a specific asset version via `InsertService:LoadAssetVersion`, handle
  naming collisions (`rename`, `overwrite`, or `skip`), place the instance in a target parent, pivot
  it (`camera`, `origin`, `preserve`, or `custom_cframe`), and optionally publish the inserted
  instance as a package.
- `import_rbxm` – Load a local RBXM/RBXLX file via `InsertService:LoadLocalAsset` and apply the same
  collision, placement, and optional package publishing workflow as marketplace insertions.
- `publish_package` – Resolve an existing instance by path and publish it as a package using the
  provided metadata (name, description, tags, group, overwrite/comments flags).

### Example prompts

Ask Claude or Cursor to chain multiple asset operations in one request:

```
Use asset_pipeline to:
1. search_marketplace for "modular sci-fi corridor" and limit results to 5 entries.
2. insert_asset_version with assetVersionId 1234567890 into Workspace/Level using rename collisions
   and camera placement.
3. publish_package for the newly inserted instance named "Corridor" with packageName "SciFiCorridor"
   and allowOverwrite true.
```

Import from the filesystem and publish immediately:

```
Use asset_pipeline with defaultParentPath ["ServerStorage", "Imported"] and defaultCollisionStrategy
"rename" to run:
- import_rbxm from "C:/Projects/Roblox/Prefabs/ControlPanel.rbxm" placing at origin.
- publish_package for ["ServerStorage", "Imported", "ControlPanel"] with packageName
  "ControlPanelPrefab", description "Control room UI elements", allowComments false.
```

To verify gameplay flows end-to-end, ask the assistant to playtest and stream logs back:

```
Use test_and_play_control to run_playtest with a 120 second timeout.
Watch for replication or runtime errors while the session is active and stop the run afterwards.
```

You can also ask Claude or Cursor to scaffold and iterate on scripts without leaving the chat. For
example, the following prompt creates a server script, updates an existing LocalScript after linting
the new source, and renames a module:

```
Use manage_scripts to:
1. Create ServerScriptService/MCP/EventRouter as a Script with RunContext "Server" and initial source that listens for the "SpawnNPC" RemoteEvent and logs received payloads.
2. Update StarterPlayerScripts/UIBoot/HotbarController (LocalScript) so it requires "ReplicatedStorage/Controllers/EventBus" and forwards button presses through the RemoteEvent.
3. Rename ReplicatedStorage/Controllers/oldEventBus module to EventBus.
Include class names and run contexts in the response metadata.
```

The resulting tool call looks like:

```json
{
  "tool": "ManageScripts",
  "params": {
    "defaultMetadata": {
      "includeClassName": true,
      "includeRunContext": true
    },
    "operations": [
      {
        "action": "create",
        "path": ["ServerScriptService", "MCP", "EventRouter"],
        "scriptType": "Script",
        "runContext": "Server",
        "source": "local event = game.ReplicatedStorage.SpawnNPC\nlocal function onSpawn(player, payload)\n\tprint(\"[MCP] SpawnNPC\", player, payload)\nend\nevent.OnServerEvent:Connect(onSpawn)",
        "metadata": {
          "includeAttributes": true,
          "includeParentPath": true
        }
      },
      {
        "action": "set_source",
        "path": ["StarterPlayer", "StarterPlayerScripts", "UIBoot", "HotbarController"],
        "source": "local ReplicatedStorage = game:GetService('ReplicatedStorage')\nlocal event = ReplicatedStorage.SpawnNPC\nlocal EventBus = require(ReplicatedStorage.Controllers.EventBus)\n\nlocal function onButtonPressed(buttonId)\n\tEventBus.publish('hotbar', buttonId)\n\tevent:FireServer(buttonId)\nend\n\nscript.Parent.ButtonPressed:Connect(onButtonPressed)",
        "metadata": {
          "includeFullName": true
        }
      },
      {
        "action": "rename",
        "path": ["ReplicatedStorage", "Controllers", "oldEventBus"],
        "newName": "EventBus",
        "metadata": {
          "includeParentPath": true
        }
      }
    ]
  }
}
```

Studio replies with a JSON payload that summarises each operation, echoes the requested metadata, and
provides diagnostics (such as syntax errors) whenever a change is rejected. That makes it easy to keep
Claude/Cursor in the loop while iteratively refining gameplay scripts. LocalScripts are guarded from
being created under server-only containers, and server Scripts are kept out of client-only parents so
the plugin will fail fast with a readable diagnostic instead of leaving the instance in an unusable
state.
