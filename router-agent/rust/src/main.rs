//! router-agent: a narrow HTTP-to-SSH bridge that lets an external
//! captive-portal backend authorize/revoke client IPs on an OpenWRT router
//! without ever holding SSH credentials to the router itself.
//!
//! See router-agent/rust/README.md for the SSH crate decision (russh vs.
//! system-ssh-shellout) and other implementation notes.

mod api;
mod config;
mod dispatch;
mod nft_json;
mod ssh_client;

use std::net::SocketAddr;
use std::sync::Arc;

use config::Config;
use ssh_client::SshClient;

/// Shared application state handed to every handler via axum's `State`
/// extractor.
pub struct AppState {
    pub config: Config,
    pub ssh: SshClient,
}

#[tokio::main]
async fn main() {
    let cfg = match Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            // Config isn't loaded yet, so there's no log level to honor —
            // fail fast on stderr before tracing is even initialized.
            eprintln!("router-agent: invalid configuration: {e}");
            std::process::exit(1);
        }
    };

    init_tracing(&cfg.log_level);

    tracing::info!(
        listen_addr = %cfg.listen_addr,
        ssh_host = %cfg.ssh_host,
        ssh_port = cfg.ssh_port,
        ssh_user = %cfg.ssh_user,
        ssh_timeout_ms = cfg.ssh_timeout.as_millis() as u64,
        "starting router-agent"
    );

    let ssh = SshClient::new(
        cfg.ssh_host.clone(),
        cfg.ssh_port,
        cfg.ssh_user.clone(),
        cfg.ssh_key_path.clone(),
        cfg.ssh_known_hosts_path.clone(),
        cfg.ssh_timeout,
    );

    let listen_addr = cfg.listen_addr;
    let state = Arc::new(AppState { config: cfg, ssh });
    let app = api::build_router(state);

    let listener = match tokio::net::TcpListener::bind(listen_addr).await {
        Ok(l) => l,
        Err(e) => {
            tracing::error!(error = %e, addr = %listen_addr, "failed to bind listen address");
            std::process::exit(1);
        }
    };

    tracing::info!(addr = %listen_addr, "router-agent listening");

    // The SSH connection to the router is established lazily on first use
    // (see ssh_client::SshClient), not here — the router may still be
    // booting when router-agent starts, and refusing to serve /healthz in
    // that window would defeat its purpose as a liveness probe.
    let result = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await;

    if let Err(e) = result {
        tracing::error!(error = %e, "server error");
        std::process::exit(1);
    }
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }

    tracing::info!("shutdown signal received, draining in-flight requests");
}

fn init_tracing(level: &str) {
    use tracing_subscriber::EnvFilter;

    let filter = EnvFilter::try_new(level).unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .json()
        .init();
}
