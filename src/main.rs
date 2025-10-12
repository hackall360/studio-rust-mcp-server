//! Binary entry point for the Roblox Studio MCP server.
//!
//! The executable acts as a thin orchestration layer over the installer and
//! stdio-facing MCP server runtime. Documentation for the surrounding
//! architecture and Roblox Studio integration lives in
//! [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) and
//! [`docs/TOOLS.md`](../docs/TOOLS.md).
//!
//! Roblox Studio communicates with plugins over HTTP as described in the
//! [Roblox Studio plugin documentation](https://create.roblox.com/docs/en-us/studio/plugins/intro-to-plugins),
//! while downstream MCP clients connect through stdio.
use axum::routing::{get, post};
use clap::{Parser, Subcommand};
use color_eyre::eyre::Result;
use rbx_studio_server::*;
use rmcp::ServiceExt;
use std::io;
use std::net::Ipv4Addr;
use std::sync::Arc;
use tokio::sync::Mutex;
use tracing_subscriber::{self, EnvFilter};
mod error;
mod install;
mod rbx_studio_server;

/// Command-line interface for installing the Studio plugin or running the MCP server.
///
/// Running the binary without arguments triggers the guided installer. The
/// `server` command, or legacy `--stdio` flag, starts the stdio transport that
/// allows MCP-compatible tools to exchange messages with Roblox Studio.
/// Roblox Studio plugin installation follows the official
/// [plugin deployment guidance](https://create.roblox.com/docs/en-us/studio/plugins/publishing-plugins),
/// ensuring the generated plugin is discoverable under the **Plugins** tab.
#[derive(Parser)]
#[command(version, about, long_about = None)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,

    /// Launch the Studio installer (legacy flag maintained for backwards compatibility)
    #[arg(long = "studio-install", hide = true)]
    legacy_studio_install: bool,

    /// Run the MCP server using stdio transport (legacy flag maintained for backwards compatibility)
    #[arg(long = "stdio")]
    legacy_stdio: bool,
}

#[derive(Subcommand)]
enum Command {
    /// Run the MCP server using stdio transport
    #[command(alias = "stdio")]
    Server,
    /// Launch the interactive Roblox Studio installer
    #[command(name = "studio-install")]
    StudioInstall,
}

#[tokio::main]
async fn main() -> Result<()> {
    color_eyre::install()?;
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_writer(io::stderr)
        .with_target(false)
        .with_thread_ids(true)
        .init();

    let args = Args::parse();
    let command = if args.legacy_studio_install {
        Some(Command::StudioInstall)
    } else if args.legacy_stdio {
        Some(Command::Server)
    } else {
        args.command
    };

    match command {
        Some(Command::Server) => run_server().await,
        Some(Command::StudioInstall) => install::studio_install().await,
        None => install::install().await,
    }
}

/// Start the stdio MCP server and bridge it to the HTTP interface used by the
/// Roblox Studio plugin.
///
/// The function binds an HTTP listener (or falls back to proxy mode when the
/// port is already in use), spins up the `RBXStudioServer`, and blocks until the
/// stdio transport is terminated. Roblox Studio performs long-polling against
/// the `/request` endpoint (matching the
/// [HttpService networking patterns](https://create.roblox.com/docs/en-us/reference/engine/classes/HttpService))
/// while tool responses are posted back to `/response` and `/proxy`.
async fn run_server() -> Result<()> {
    tracing::debug!("Debug MCP tracing enabled");

    let server_state = Arc::new(Mutex::new(AppState::new()));

    let (close_tx, close_rx) = tokio::sync::oneshot::channel();
    let close_signal: CloseSignal = Arc::new(Mutex::new(Some(close_tx)));

    let mut close_rx = Some(close_rx);

    let bind_outcome =
        bind_studio_listener((Ipv4Addr::new(127, 0, 0, 1), STUDIO_PLUGIN_PORT)).await;

    let server_state_clone = Arc::clone(&server_state);
    let server_handle = match bind_outcome {
        Ok(BindOutcome::Listener(listener)) => {
            let close_rx = close_rx.take().expect("close_rx already taken");
            let app = axum::Router::new()
                .route("/request", get(request_handler))
                .route("/response", post(response_handler))
                .route("/proxy", post(proxy_handler))
                .with_state(server_state_clone);
            tracing::info!("This MCP instance is HTTP server listening on {STUDIO_PLUGIN_PORT}");
            let close_signal = Arc::clone(&close_signal);
            let server_future = async move {
                axum::serve(listener, app)
                    .with_graceful_shutdown(async move {
                        _ = close_rx.await;
                    })
                    .await
                    .map_err(ServerError::from)
            };

            spawn_http_server(server_future, close_signal)
        }
        Ok(BindOutcome::AddrInUse) => {
            tracing::info!("This MCP instance will use proxy since port is busy");
            let close_rx = close_rx.take().expect("close_rx already taken");
            let close_signal = Arc::clone(&close_signal);
            tokio::spawn(async move {
                dud_proxy_loop(server_state_clone, close_rx).await;
                signal_shutdown(&close_signal).await;
                Ok::<(), ServerError>(())
            })
        }
        Err(err) => {
            tracing::error!(error = %err, "Failed to bind TCP listener");
            return Err(err.into());
        }
    };

    // Create an instance of our counter router
    let service = RBXStudioServer::new(Arc::clone(&server_state))
        .serve(rmcp::transport::stdio())
        .await
        .inspect_err(|e| {
            tracing::error!("serving error: {:?}", e);
        })?;
    service.waiting().await?;

    signal_shutdown(&close_signal).await;
    tracing::info!("Waiting for web server to gracefully shutdown");
    match server_handle.await {
        Ok(Ok(())) => {
            tracing::info!("Bye!");
            Ok(())
        }
        Ok(Err(err)) => {
            let err_msg = err.to_string();
            tracing::error!(error = %err_msg, "HTTP server exited with error");
            Err(err)
        }
        Err(err) => {
            tracing::error!(error = %err, "HTTP server task panicked");
            Err(err.into())
        }
    }
}

enum BindOutcome {
    Listener(tokio::net::TcpListener),
    AddrInUse,
}

type CloseSignal = Arc<Mutex<Option<tokio::sync::oneshot::Sender<()>>>>;
type ServerError = color_eyre::Report;

/// Notify the HTTP server task that the process is shutting down.
async fn signal_shutdown(close_signal: &CloseSignal) {
    let mut guard = close_signal.lock().await;
    if let Some(tx) = guard.take() {
        let _ = tx.send(());
    }
}

/// Spawn the HTTP server on a background task and mirror failures back to the
/// main loop.
fn spawn_http_server<F>(
    server_future: F,
    close_signal: CloseSignal,
) -> tokio::task::JoinHandle<Result<(), ServerError>>
where
    F: std::future::Future<Output = Result<(), ServerError>> + Send + 'static,
{
    tokio::spawn(async move {
        let result = server_future.await;
        if let Err(ref err) = result {
            tracing::error!(error = %err, "HTTP server failed; initiating shutdown");
            signal_shutdown(&close_signal).await;
        }
        result
    })
}

/// Attempt to bind to the TCP address used by the Roblox Studio plugin.
///
/// When the port is already occupied, the function returns
/// `BindOutcome::AddrInUse` so the caller can fall back to proxy mode.
async fn bind_studio_listener(addr: (Ipv4Addr, u16)) -> Result<BindOutcome, std::io::Error> {
    match tokio::net::TcpListener::bind(addr).await {
        Ok(listener) => Ok(BindOutcome::Listener(listener)),
        Err(err) if err.kind() == io::ErrorKind::AddrInUse => Ok(BindOutcome::AddrInUse),
        Err(err) => Err(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener as StdTcpListener;
    use tracing_test::traced_test;

    #[tokio::test]
    async fn bind_studio_listener_returns_addr_in_use() {
        let std_listener =
            StdTcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind test listener");
        let port = std_listener.local_addr().expect("port").port();

        let outcome = bind_studio_listener((Ipv4Addr::LOCALHOST, port))
            .await
            .expect("bind outcome");

        match outcome {
            BindOutcome::AddrInUse => {}
            BindOutcome::Listener(_) => panic!("expected AddrInUse, got listener"),
        }
    }

    #[tokio::test]
    async fn bind_studio_listener_propagates_other_errors() {
        let result = bind_studio_listener((Ipv4Addr::new(203, 0, 113, 1), 0)).await;

        match result {
            Ok(BindOutcome::Listener(_)) => {
                panic!("expected bind failure, but listener was created");
            }
            Ok(BindOutcome::AddrInUse) => {
                panic!("expected bind failure, but port reported as in use");
            }
            Err(err) => {
                assert_eq!(err.kind(), io::ErrorKind::AddrNotAvailable);
            }
        }
    }

    #[tokio::test]
    #[traced_test]
    async fn spawn_http_server_logs_and_signals_on_error() {
        let (close_tx, close_rx) = tokio::sync::oneshot::channel();
        let close_signal: CloseSignal = Arc::new(Mutex::new(Some(close_tx)));
        let failing_future = async {
            Err::<(), ServerError>(ServerError::from(io::Error::new(
                io::ErrorKind::Other,
                "boom",
            )))
        };

        let handle = spawn_http_server(failing_future, Arc::clone(&close_signal));

        let server_result = handle.await.expect("server task panicked");
        assert!(
            server_result.is_err(),
            "expected server future to return error"
        );
        close_rx
            .await
            .expect("close signal not triggered by server task");

        assert!(logs_contain("HTTP server failed; initiating shutdown"));
    }
}
