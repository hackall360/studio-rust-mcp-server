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

/// Simple MCP proxy for Roblox Studio
/// Run without arguments to install the plugin
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

async fn signal_shutdown(close_signal: &CloseSignal) {
    let mut guard = close_signal.lock().await;
    if let Some(tx) = guard.take() {
        let _ = tx.send(());
    }
}

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
