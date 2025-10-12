# Architecture Overview

This document explains how the Roblox Studio MCP server stitches together its Rust
components, the Roblox Studio plugin, and downstream Model Context Protocol (MCP)
clients.

## High-level flow

1. An MCP-compatible desktop client (Claude Desktop, Cursor, LM Studio, etc.)
   launches `rbx-studio-mcp` with the `--stdio` flag or equivalent configuration.
2. The binary initialises the [`RBXStudioServer`](../src/rbx_studio_server.rs) and
   binds an HTTP listener on `127.0.0.1:44755`. Roblox Studio will connect to
   this port using [`HttpService`](https://create.roblox.com/docs/en-us/reference/engine/classes/HttpService)
   long polling.
3. The Roblox Studio plugin issues a `GET /request` long poll every 15 seconds.
   When the MCP client has queued work, the server serialises it to JSON and
   returns it to the plugin.
4. The plugin performs the requested work inside Studio using the appropriate
   services (for example `InsertService`, `PathfindingService`, or
   `CollectionService`).
5. The plugin posts the result back to the server via `POST /response`. The
   payload is streamed through the MCP transport to the waiting client.
6. In environments where the port is already occupied, the server falls back to
   proxy mode by relaying requests through `POST /proxy` to the active instance.

This flow lets the Studio plugin stay sandboxed while still granting MCP clients
rich access to Studio tooling.

## Components

### CLI (`src/main.rs`)

* Parses command-line arguments using [`clap`](https://docs.rs/clap).
* Provides three execution modes:
  * Default installer flow (`install::install`).
  * Interactive Studio installer (`install::studio_install`).
  * MCP stdio server (`run_server`).
* Configures logging, colourised error handling, and gracefully shuts down the
  HTTP server when the MCP transport ends.

### Server bridge (`src/rbx_studio_server.rs`)

* Maintains shared [`AppState`](../src/rbx_studio_server.rs) with pending tool
  invocations and active response channels.
* Exposes the MCP tools catalogue by implementing `ServerHandler` from the
  [`rmcp`](https://docs.rs/rmcp) crate.
* Implements the HTTP endpoints consumed by the Studio plugin:
  * `GET /request` – long poll for outstanding work.
  * `POST /response` – deliver tool results.
  * `POST /proxy` – optional proxy loop for secondary processes.
* Uses Tokio primitives (`Mutex`, `mpsc`, `watch`) to coordinate concurrent
  requests and long-poll wake-ups.

### Installer (`src/install.rs`)

* Automates plugin deployment by copying packaged assets to the directories
  expected by Roblox Studio according to the
  [plugin publishing guidance](https://create.roblox.com/docs/en-us/studio/plugins/publishing-plugins).
* Configures MCP clients such as Claude Desktop, Cursor, and LM Studio by
  writing the appropriate manifests to their extension folders.

### Plugin (under `plugin/`)

* Implements the Roblox Studio side of the bridge in Luau.
* Uses `HttpService` to communicate with the Rust server and surfaces tools via
  Studio's [Plugin API](https://create.roblox.com/docs/en-us/reference/engine/classes/Plugin).
* Executes tooling operations against core engine services:
  * [`InsertService`](https://create.roblox.com/docs/en-us/reference/engine/classes/InsertService) for
    Marketplace lookups.
  * [`Terrain`](https://create.roblox.com/docs/en-us/reference/engine/classes/Terrain) for voxel edits.
  * [`PathfindingService`](https://create.roblox.com/docs/en-us/reference/engine/classes/PathfindingService)
    for navigation queries.
  * [`VirtualInputManager`](https://create.roblox.com/docs/en-us/reference/engine/classes/VirtualInputManager)
    for synthesised playtest input.

## Error handling

* The server surfaces JSON-formatted errors back to MCP clients using
  `CallToolResult::error` so they can appear inline in the chat interface.
* The HTTP server logs failures using [`tracing`](https://docs.rs/tracing) and
  triggers shutdown via `signal_shutdown` to avoid leaving orphaned listeners.

## Concurrency and shutdown

* HTTP handlers acquire the shared `AppState` lock briefly to push/pull work,
  minimising contention even when Studio is issuing high-frequency polls.
* The oneshot shutdown channel ensures the HTTP server exits when the MCP
  transport terminates or when an error occurs.

## Extending the server

1. Define a new request/response schema inside `rbx_studio_server.rs`.
2. Register the tool within the `ToolArgumentValues` enum and
   `#[tool_handler]` implementation.
3. Update the Studio plugin so it understands the new tool payload and reports
   results back via `HttpService`.
4. Document the new behaviour in [`docs/TOOLS.md`](./TOOLS.md) and reference the
   relevant Roblox Studio documentation.

Following this flow keeps the bridge aligned with Roblox's official
recommendations for network communication and plugin behaviour.
