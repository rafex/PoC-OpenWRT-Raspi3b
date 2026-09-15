//! axum handlers for the router-agent HTTP surface.

use std::sync::Arc;
use std::time::Instant;

use axum::Json;
use axum::body::Bytes;
use axum::extract::State;
use serde_json::Value;

use crate::AppState;
use crate::dispatch::{self, DispatchError, DispatchErrorKind};
use crate::nft_json;

use super::types::{
    AllowRequestRaw, AllowResponse, ApiError, BlockRequestRaw, BlockResponse, HealthzResponse,
    ListResponse, StatusResponse,
};

const DEFAULT_ALLOW_TIMEOUT_MIN: i64 = 30;
/// Matches the Go sibling's `math.MaxInt32` bound on `timeout_min`.
const MAX_TIMEOUT_MIN: i64 = i32::MAX as i64;

pub async fn healthz() -> Json<HealthzResponse> {
    Json(HealthzResponse { status: "ok" })
}

pub async fn allow(
    State(state): State<Arc<AppState>>,
    body: Bytes,
) -> Result<Json<AllowResponse>, ApiError> {
    let req = parse_body::<AllowRequestRaw>(&body)?;

    let ip = extract_ip(req.ip)?;
    let timeout_min = extract_timeout_min(req.timeout_min)?;

    let result = dispatch::allow(&state.ssh, &ip, timeout_min)
        .await
        .map_err(map_dispatch_error)?;

    Ok(Json(AllowResponse {
        ip: result.ip,
        status: "allowed",
        timeout_min: result.timeout_min,
    }))
}

pub async fn block(
    State(state): State<Arc<AppState>>,
    body: Bytes,
) -> Result<Json<BlockResponse>, ApiError> {
    let req = parse_body::<BlockRequestRaw>(&body)?;

    let ip = extract_ip(req.ip)?;

    // Blocking an IP that isn't currently allowed is idempotent success —
    // dispatch::block already maps the dispatcher's own
    // "OK block <ip> (not present)" response to an ordinary BlockResult, so
    // there is nothing IP-presence-specific to check here.
    let result = dispatch::block(&state.ssh, &ip)
        .await
        .map_err(map_dispatch_error)?;

    Ok(Json(BlockResponse {
        ip: result.ip,
        status: "blocked",
    }))
}

pub async fn list(State(state): State<Arc<AppState>>) -> Result<Json<ListResponse>, ApiError> {
    let raw = dispatch::list(&state.ssh)
        .await
        .map_err(map_dispatch_error)?;

    let clients = nft_json::parse_nft_list_json(&raw).map_err(|e| {
        tracing::error!(error = %e, "failed to parse nft list output");
        ApiError::router_command_failed(
            "router returned an nft list payload the agent could not parse",
        )
    })?;

    Ok(Json(ListResponse { clients }))
}

/// `GET /v1/status` never 5xxs for a router-side condition — an
/// unreachable router or a timed-out SSH round trip is a legitimate
/// observed state, reported as `router_reachable:false` with HTTP 200.
/// Only a genuinely unrecognized dispatcher response (the agent's own
/// inability to interpret what it got back) is treated as an internal
/// error.
pub async fn status(State(state): State<Arc<AppState>>) -> Result<Json<StatusResponse>, ApiError> {
    let start = Instant::now();
    let result = dispatch::status(&state.ssh).await;
    let elapsed = start.elapsed();

    match result {
        Ok(r) => Ok(Json(StatusResponse {
            router_reachable: true,
            nft_table_present: Some(r.table_present),
            ssh_latency_ms: Some(elapsed.as_millis() as u64),
        })),
        Err(DispatchError {
            kind: DispatchErrorKind::RouterUnreachable | DispatchErrorKind::RouterTimeout,
            ..
        }) => Ok(Json(StatusResponse {
            router_reachable: false,
            nft_table_present: None,
            ssh_latency_ms: None,
        })),
        Err(e) => {
            tracing::error!(error = %e.message, "unexpected status dispatch result");
            Err(ApiError::internal_error(e.message))
        }
    }
}

/// Deserializes a JSON request body without regard to the `Content-Type`
/// header — deliberately, to match the Go sibling's `json.NewDecoder`,
/// which reads whatever bytes the request carries regardless of headers.
/// Using axum's `Json<T>` extractor directly would reject any request
/// missing an exact `Content-Type: application/json`, which the Go side
/// does not require; for a caller-facing contract that must be
/// interchangeable between the two implementations, this is the behavior
/// that matches.
fn parse_body<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, ApiError> {
    serde_json::from_slice(body)
        .map_err(|e| ApiError::invalid_ip(format!("malformed request body: {e}")))
}

fn map_dispatch_error(e: DispatchError) -> ApiError {
    match e.kind {
        DispatchErrorKind::RouterTimeout => ApiError::router_timeout(),
        DispatchErrorKind::RouterUnreachable => ApiError::router_unreachable(e.message),
        DispatchErrorKind::RouterCommandFailed => ApiError::router_command_failed(e.message),
    }
}

/// Pulls `ip` out of a raw JSON body and validates it, distinguishing
/// "missing" / "wrong type" / "fails grammar" so the error message stays
/// useful without needing a generic body-rejection code.
fn extract_ip(raw: Option<Value>) -> Result<String, ApiError> {
    let value = raw.ok_or_else(|| ApiError::invalid_ip("missing required field \"ip\""))?;
    let ip = value
        .as_str()
        .ok_or_else(|| ApiError::invalid_ip(format!("invalid ip: {value}")))?;

    if !validate_ipv4(ip) {
        return Err(ApiError::invalid_ip(format!("invalid ip: {ip:?}")));
    }

    Ok(ip.to_string())
}

/// Pulls the optional `timeout_min` out of a raw JSON body. Absent or
/// explicit `null` defaults to 30; anything else must be a non-negative
/// JSON integer within `i32` range (0 = permanent).
fn extract_timeout_min(raw: Option<Value>) -> Result<i64, ApiError> {
    match raw {
        None | Some(Value::Null) => Ok(DEFAULT_ALLOW_TIMEOUT_MIN),
        Some(v) => {
            let n = v
                .as_i64()
                .ok_or_else(|| ApiError::invalid_timeout(format!("invalid timeout_min: {v}")))?;
            if !(0..=MAX_TIMEOUT_MIN).contains(&n) {
                return Err(ApiError::invalid_timeout(format!(
                    "invalid timeout_min: {v}"
                )));
            }
            Ok(n)
        }
    }
}

/// Mirrors `_validate_ip` in agent-dispatch.sh / setup-captive.sh exactly:
/// exactly four dot-separated all-digit octets, each in `[0,255]`.
///
/// This deliberately does NOT use `std::net::Ipv4Addr::from_str`, which
/// rejects octets with leading zeros (e.g. "192.168.001.010") — the
/// router-side shell validator accepts them, since POSIX shell arithmetic
/// comparison treats "010" as decimal 10, not octal. Using the stdlib
/// parser here would make the HTTP layer reject an IP literal the router's
/// own dispatcher would happily accept (or, for other inputs, vice versa).
/// This mirrors the identical, deliberate choice made in the Go sibling's
/// `ValidateIPv4` — see router-agent/rust/README.md for why this is a
/// documented departure from an earlier literal reading of this service's
/// spec that named `Ipv4Addr::from_str` directly: true behavioral parity
/// between the two HTTP implementations matters more than which stdlib
/// function got named first, since the whole point is that a caller can't
/// tell them apart.
fn validate_ipv4(ip: &str) -> bool {
    if ip.is_empty() {
        return false;
    }
    let parts: Vec<&str> = ip.split('.').collect();
    if parts.len() != 4 {
        return false;
    }
    for p in parts {
        if p.is_empty() || p.len() > 3 || !p.bytes().all(|b| b.is_ascii_digit()) {
            return false;
        }
        match p.parse::<u32>() {
            Ok(n) if n <= 255 => {}
            _ => return false,
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_ipv4_accepts_plain_addresses() {
        assert!(validate_ipv4("192.168.1.146"));
        assert!(validate_ipv4("0.0.0.0"));
        assert!(validate_ipv4("255.255.255.255"));
    }

    #[test]
    fn validate_ipv4_accepts_leading_zeros_matching_shell_grammar() {
        // The router's shell validator (and the Go sibling) accept these.
        assert!(validate_ipv4("192.168.001.010"));
        assert!(validate_ipv4("010.010.010.010"));
    }

    #[test]
    fn validate_ipv4_rejects_bad_shapes() {
        assert!(!validate_ipv4(""));
        assert!(!validate_ipv4("192.168.1"));
        assert!(!validate_ipv4("192.168.1.1.1"));
        assert!(!validate_ipv4("192.168.1.256"));
        assert!(!validate_ipv4("192.168.1.-1"));
        assert!(!validate_ipv4("192.168.1.abc"));
        assert!(!validate_ipv4("::1"));
        assert!(!validate_ipv4("192.168..1"));
    }

    #[test]
    fn extract_ip_missing_field_is_invalid_ip() {
        assert!(extract_ip(None).is_err());
    }

    #[test]
    fn extract_ip_wrong_type_is_invalid_ip() {
        assert!(extract_ip(Some(Value::from(146))).is_err());
    }

    #[test]
    fn extract_timeout_min_absent_defaults_to_30() {
        assert_eq!(extract_timeout_min(None).unwrap(), 30);
        assert_eq!(extract_timeout_min(Some(Value::Null)).unwrap(), 30);
    }

    #[test]
    fn extract_timeout_min_accepts_zero_as_permanent() {
        assert_eq!(extract_timeout_min(Some(Value::from(0))).unwrap(), 0);
    }

    #[test]
    fn extract_timeout_min_rejects_negative() {
        assert!(extract_timeout_min(Some(Value::from(-1))).is_err());
    }

    #[test]
    fn extract_timeout_min_rejects_non_integer() {
        assert!(extract_timeout_min(Some(Value::from(30.5))).is_err());
        assert!(extract_timeout_min(Some(Value::from("30"))).is_err());
    }

    #[test]
    fn extract_timeout_min_rejects_above_i32_max() {
        assert!(extract_timeout_min(Some(Value::from(i64::from(i32::MAX) + 1))).is_err());
    }
}
