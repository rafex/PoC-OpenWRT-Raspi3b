//! Command-string builders and response interpretation for
//! `/etc/captive/agent-dispatch.sh`'s grammar:
//!
//!   allow <ip> [timeout_min]   (default 30; 0 = permanent)
//!   block <ip>
//!   list
//!   status
//!
//! stdout/stderr convention: `OK ...` on stdout with exit 0 on success;
//! `ERR ...` on stderr with exit 2 for a grammar/validation error the
//! dispatcher itself rejected, or exit 1 for an operational failure (e.g.
//! "table missing"). `list` is the one exception: on success it prints raw
//! `nft -j list set` JSON to stdout with no OK/ERR wrapper — callers parse
//! that separately with `crate::nft_json`.
//!
//! This module intentionally mirrors the sibling Go implementation's
//! `internal/dispatch` package: callers (internal/api handlers there,
//! `crate::api::handlers` here) are expected to have already validated
//! `ip`/`timeout_min` against the same grammar the router enforces, so a
//! validation error (exit 2) coming back from the dispatcher is treated
//! defensively as an ordinary `RouterCommandFailed`, exactly like any other
//! non-conforming response, rather than re-derived into a 400. `status` is
//! the one case where a non-zero exit (1, with "table missing") is a
//! legitimate, successful result rather than an error at all.

use crate::ssh_client::{ExecOutput, SshClient, SshError};

/// Classifies a `DispatchError` so the HTTP layer can map it to the right
/// status code and error body without string-matching messages. Mirrors
/// the Go sibling's `dispatch.Kind`.
// Variant names intentionally keep the `Router` prefix to match the Go
// sibling's `dispatch.Kind` constants (`KindRouterUnreachable`, etc.)
// verbatim, which is more valuable here than clippy's naming preference.
#[allow(clippy::enum_variant_names)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DispatchErrorKind {
    /// The SSH transport to the router could not be established or was lost.
    RouterUnreachable,
    /// The SSH connect or exec exceeded the configured timeout.
    RouterTimeout,
    /// We got a response from the dispatcher, but it signalled an
    /// operational failure outside the documented "legitimate" cases, or
    /// returned output that doesn't match the documented grammar at all.
    RouterCommandFailed,
}

#[derive(Debug, thiserror::Error)]
#[error("{message}")]
pub struct DispatchError {
    pub kind: DispatchErrorKind,
    pub message: String,
}

impl DispatchError {
    fn command_failed(op: &str, out: &ExecOutput) -> Self {
        DispatchError {
            kind: DispatchErrorKind::RouterCommandFailed,
            message: format!(
                "dispatcher {op:?} exited {}: stdout={:?} stderr={:?}",
                out.exit_status
                    .map(|c| c.to_string())
                    .unwrap_or_else(|| "?".to_string()),
                out.stdout.trim(),
                out.stderr.trim(),
            ),
        }
    }
}

impl From<SshError> for DispatchError {
    fn from(e: SshError) -> Self {
        let kind = match &e {
            SshError::Timeout => DispatchErrorKind::RouterTimeout,
            // A key-load/negotiation failure (Internal) means we can't even
            // start a session with the router — from the caller's point of
            // view that's indistinguishable from "unreachable".
            SshError::Unreachable(_) | SshError::Internal(_) => {
                DispatchErrorKind::RouterUnreachable
            }
        };
        DispatchError {
            kind,
            message: e.to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct AllowResult {
    pub ip: String,
    pub timeout_min: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BlockResult {
    pub ip: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct StatusResult {
    pub table_present: bool,
}

fn build_allow(ip: &str, timeout_min: i64) -> String {
    format!("allow {ip} {timeout_min}")
}

fn build_block(ip: &str) -> String {
    format!("block {ip}")
}

fn interpret_allow(
    ip: &str,
    timeout_min: i64,
    out: &ExecOutput,
) -> Result<AllowResult, DispatchError> {
    if out.exit_status == Some(0) && out.stdout.trim().starts_with("OK allow ") {
        Ok(AllowResult {
            ip: ip.to_string(),
            timeout_min,
        })
    } else {
        Err(DispatchError::command_failed("allow", out))
    }
}

fn interpret_block(ip: &str, out: &ExecOutput) -> Result<BlockResult, DispatchError> {
    // "OK block <ip> (not present)" also matches this prefix: blocking an
    // IP that isn't currently allowed is idempotent success.
    if out.exit_status == Some(0) && out.stdout.trim().starts_with("OK block ") {
        Ok(BlockResult { ip: ip.to_string() })
    } else {
        Err(DispatchError::command_failed("block", out))
    }
}

fn interpret_list(out: &ExecOutput) -> Result<String, DispatchError> {
    // The dispatcher always exits 0 for "list" (it falls back to
    // `{"nftables":[]}` on its own if nft fails), so any non-zero exit here
    // is unexpected.
    if out.exit_status == Some(0) {
        Ok(out.stdout.clone())
    } else {
        Err(DispatchError::command_failed("list", out))
    }
}

fn interpret_status(out: &ExecOutput) -> Result<StatusResult, DispatchError> {
    let stdout_trim = out.stdout.trim();
    if out.exit_status == Some(0) && stdout_trim.starts_with("OK table=") {
        return Ok(StatusResult {
            table_present: true,
        });
    }
    if out.exit_status == Some(1) && out.stderr.contains("table missing") {
        return Ok(StatusResult {
            table_present: false,
        });
    }
    Err(DispatchError::command_failed("status", out))
}

pub async fn allow(
    ssh: &SshClient,
    ip: &str,
    timeout_min: i64,
) -> Result<AllowResult, DispatchError> {
    let out = ssh.exec(&build_allow(ip, timeout_min)).await?;
    interpret_allow(ip, timeout_min, &out)
}

pub async fn block(ssh: &SshClient, ip: &str) -> Result<BlockResult, DispatchError> {
    let out = ssh.exec(&build_block(ip)).await?;
    interpret_block(ip, &out)
}

pub async fn list(ssh: &SshClient) -> Result<String, DispatchError> {
    let out = ssh.exec("list").await?;
    interpret_list(&out)
}

pub async fn status(ssh: &SshClient) -> Result<StatusResult, DispatchError> {
    let out = ssh.exec("status").await?;
    interpret_status(&out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn out(stdout: &str, stderr: &str, exit_status: Option<u32>) -> ExecOutput {
        ExecOutput {
            stdout: stdout.to_string(),
            stderr: stderr.to_string(),
            exit_status,
        }
    }

    #[test]
    fn build_allow_formats_ip_and_timeout() {
        assert_eq!(build_allow("192.168.1.146", 30), "allow 192.168.1.146 30");
        assert_eq!(build_allow("192.168.1.146", 0), "allow 192.168.1.146 0");
    }

    #[test]
    fn build_block_formats_ip() {
        assert_eq!(build_block("192.168.1.146"), "block 192.168.1.146");
    }

    #[test]
    fn interpret_allow_success() {
        let o = out("OK allow 192.168.1.146 30m\n", "", Some(0));
        assert_eq!(
            interpret_allow("192.168.1.146", 30, &o).unwrap(),
            AllowResult {
                ip: "192.168.1.146".to_string(),
                timeout_min: 30
            }
        );
    }

    #[test]
    fn interpret_allow_validation_error_is_command_failed() {
        let o = out("", "ERR invalid timeout\n", Some(2));
        let err = interpret_allow("192.168.1.146", -1, &o).unwrap_err();
        assert_eq!(err.kind, DispatchErrorKind::RouterCommandFailed);
    }

    #[test]
    fn interpret_block_idempotent_not_present_is_success() {
        let o = out("OK block 192.168.1.50 (not present)\n", "", Some(0));
        assert_eq!(
            interpret_block("192.168.1.50", &o).unwrap(),
            BlockResult {
                ip: "192.168.1.50".to_string()
            }
        );
    }

    #[test]
    fn interpret_list_passes_through_raw_stdout_on_exit_0() {
        let o = out(r#"{"nftables":[]}"#, "", Some(0));
        assert_eq!(interpret_list(&o).unwrap(), r#"{"nftables":[]}"#);
    }

    #[test]
    fn interpret_list_nonzero_exit_is_command_failed() {
        let o = out("", "boom", Some(1));
        assert!(interpret_list(&o).is_err());
    }

    #[test]
    fn interpret_status_table_present() {
        let o = out("OK table=ip captive present\n", "", Some(0));
        assert_eq!(
            interpret_status(&o).unwrap(),
            StatusResult {
                table_present: true
            }
        );
    }

    #[test]
    fn interpret_status_table_missing_is_a_successful_result_not_an_error() {
        let o = out("", "ERR table missing\n", Some(1));
        assert_eq!(
            interpret_status(&o).unwrap(),
            StatusResult {
                table_present: false
            }
        );
    }

    #[test]
    fn interpret_status_malformed_output_is_command_failed() {
        let o = out("garbage\n", "", Some(0));
        let err = interpret_status(&o).unwrap_err();
        assert_eq!(err.kind, DispatchErrorKind::RouterCommandFailed);
    }

    #[test]
    fn ssh_timeout_maps_to_router_timeout_kind() {
        let derr: DispatchError = SshError::Timeout.into();
        assert_eq!(derr.kind, DispatchErrorKind::RouterTimeout);
    }

    #[test]
    fn ssh_unreachable_maps_to_router_unreachable_kind() {
        let derr: DispatchError = SshError::Unreachable("dial failed".to_string()).into();
        assert_eq!(derr.kind, DispatchErrorKind::RouterUnreachable);
    }
}
