//! Persistent SSH connection to the router, serialized behind a mutex.
//!
//! Design constraint (deliberate, see router-agent/rust/README.md): we do
//! NOT reconnect per request. One SSH transport is dialed at startup (and
//! redialed with backoff after a failure); each request opens a fresh
//! `exec` channel over that same connection. The `tokio::sync::Mutex`
//! guarding the connection handle serializes command execution — only one
//! exec is ever in flight, which matches the forced-command dispatcher's
//! expectation of one command per invocation and avoids unbounded
//! concurrent channels against a small embedded SSH server (dropbear).

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use russh::ChannelMsg;
use russh::client::{self, Handle};
use russh::keys::{PrivateKeyWithHashAlg, PublicKeyOrCertificate, load_secret_key};
use tokio::sync::Mutex;
use tracing::{error, info, warn};

/// Standard SSH extended-data code for stderr (RFC 4254 §5.2).
const SSH_EXTENDED_DATA_STDERR: u32 = 1;

/// Number of redial attempts (including the first) before giving up on a
/// single request. Delays are applied *before* attempts after the first.
const RECONNECT_BACKOFF: [Duration; 3] = [
    Duration::from_millis(0),
    Duration::from_millis(200),
    Duration::from_millis(800),
];

#[derive(Debug, Clone)]
pub struct ExecOutput {
    pub stdout: String,
    pub stderr: String,
    pub exit_status: Option<u32>,
}

#[derive(Debug, thiserror::Error)]
pub enum SshError {
    #[error("router unreachable: {0}")]
    Unreachable(String),
    #[error("SSH command timed out")]
    Timeout,
    #[error("internal SSH client error: {0}")]
    Internal(String),
}

struct ClientHandler {
    host: String,
    port: u16,
    known_hosts_path: PathBuf,
}

impl client::Handler for ClientHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let key = match server_public_key {
            PublicKeyOrCertificate::PublicKey { key, .. } => key,
            PublicKeyOrCertificate::Certificate(_) => {
                error!(
                    "router presented an SSH certificate instead of a plain host key; rejecting"
                );
                return Ok(false);
            }
        };

        match russh::keys::check_known_hosts_path(
            &self.host,
            self.port,
            key,
            &self.known_hosts_path,
        ) {
            Ok(true) => Ok(true),
            Ok(false) => {
                error!(
                    host = %self.host,
                    known_hosts = %self.known_hosts_path.display(),
                    "router's SSH host key does not match the pinned known_hosts entry"
                );
                Ok(false)
            }
            Err(e) => {
                error!(error = %e, "failed to verify router host key against pinned known_hosts");
                Ok(false)
            }
        }
    }
}

pub struct SshClient {
    host: String,
    port: u16,
    user: String,
    key_path: PathBuf,
    known_hosts_path: PathBuf,
    timeout: Duration,
    conn: Mutex<Option<Handle<ClientHandler>>>,
}

impl SshClient {
    pub fn new(
        host: String,
        port: u16,
        user: String,
        key_path: PathBuf,
        known_hosts_path: PathBuf,
        timeout: Duration,
    ) -> Self {
        Self {
            host,
            port,
            user,
            key_path,
            known_hosts_path,
            timeout,
            conn: Mutex::new(None),
        }
    }

    /// Dial and authenticate a brand new SSH transport.
    async fn dial(&self) -> Result<Handle<ClientHandler>, SshError> {
        let key_pair = load_secret_key(&self.key_path, None).map_err(|e| {
            SshError::Internal(format!(
                "failed to load SSH private key from {}: {e}",
                self.key_path.display()
            ))
        })?;

        let config = Arc::new(client::Config {
            inactivity_timeout: Some(self.timeout),
            ..Default::default()
        });

        let handler = ClientHandler {
            host: self.host.clone(),
            port: self.port,
            known_hosts_path: self.known_hosts_path.clone(),
        };

        let addr = format!("{}:{}", self.host, self.port);

        let mut session =
            tokio::time::timeout(self.timeout, client::connect(config, addr.clone(), handler))
                .await
                .map_err(|_| SshError::Timeout)?
                .map_err(|e| SshError::Unreachable(format!("connect to {addr} failed: {e}")))?;

        let best_hash = session
            .best_supported_rsa_hash()
            .await
            .map_err(|e| SshError::Internal(format!("failed to negotiate auth params: {e}")))?
            .flatten();

        let auth_res = tokio::time::timeout(
            self.timeout,
            session.authenticate_publickey(
                self.user.clone(),
                PrivateKeyWithHashAlg::new(Arc::new(key_pair), best_hash),
            ),
        )
        .await
        .map_err(|_| SshError::Timeout)?
        .map_err(|e| SshError::Unreachable(format!("SSH authentication failed: {e}")))?;

        if !auth_res.success() {
            return Err(SshError::Unreachable(
                "router rejected SSH publickey authentication".to_string(),
            ));
        }

        Ok(session)
    }

    /// Ensure `*guard` holds a live connection, redialing with backoff if
    /// necessary. Caller must already hold the connection mutex.
    async fn ensure_connected(
        &self,
        guard: &mut Option<Handle<ClientHandler>>,
    ) -> Result<(), SshError> {
        if let Some(handle) = guard.as_ref() {
            if !handle.is_closed() {
                return Ok(());
            }
            warn!("SSH connection to router was closed; reconnecting");
        }

        let mut last_err = None;
        for (attempt, delay) in RECONNECT_BACKOFF.iter().enumerate() {
            if !delay.is_zero() {
                tokio::time::sleep(*delay).await;
            }
            match self.dial().await {
                Ok(handle) => {
                    info!(attempt, "established SSH connection to router");
                    *guard = Some(handle);
                    return Ok(());
                }
                Err(e) => {
                    warn!(attempt, error = %e, "SSH connect attempt failed");
                    last_err = Some(e);
                }
            }
        }

        *guard = None;
        Err(last_err.unwrap_or_else(|| SshError::Unreachable("unknown dial error".to_string())))
    }

    /// Run one dispatcher command over the persistent connection, opening a
    /// fresh `exec` channel for it. The connection mutex guarantees only
    /// one exec is ever in flight (serialized, not per-request reconnects).
    pub async fn exec(&self, command: &str) -> Result<ExecOutput, SshError> {
        let mut guard = self.conn.lock().await;
        self.ensure_connected(&mut guard).await?;

        let handle = guard
            .as_ref()
            .expect("ensure_connected guarantees a connection on Ok(())");

        match tokio::time::timeout(self.timeout, run_exec(handle, command)).await {
            Ok(Ok(output)) => Ok(output),
            Ok(Err(e)) => {
                // Transport-level failure: assume the connection is dead so
                // the next request redials instead of reusing a bad handle.
                *guard = None;
                Err(e)
            }
            Err(_) => Err(SshError::Timeout),
        }
    }
}

async fn run_exec(handle: &Handle<ClientHandler>, command: &str) -> Result<ExecOutput, SshError> {
    let mut channel = handle
        .channel_open_session()
        .await
        .map_err(|e| SshError::Unreachable(format!("failed to open SSH channel: {e}")))?;

    channel
        .exec(true, command)
        .await
        .map_err(|e| SshError::Unreachable(format!("failed to exec over SSH: {e}")))?;

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut exit_status = None;

    while let Some(msg) = channel.wait().await {
        match msg {
            ChannelMsg::Data { data } => stdout.extend_from_slice(&data),
            ChannelMsg::ExtendedData { data, ext } if ext == SSH_EXTENDED_DATA_STDERR => {
                stderr.extend_from_slice(&data);
            }
            ChannelMsg::ExitStatus { exit_status: code } => {
                exit_status = Some(code);
            }
            _ => {}
        }
    }

    Ok(ExecOutput {
        stdout: String::from_utf8_lossy(&stdout).to_string(),
        stderr: String::from_utf8_lossy(&stderr).to_string(),
        exit_status,
    })
}
