//! Auth for every route except `/healthz`: a source-IP allowlist check,
//! then (only if that passes) a constant-time shared-secret token check.
//! The IP check runs first and short-circuits with 403 before the token is
//! even inspected, per the API contract.

use std::net::SocketAddr;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{ConnectInfo, State};
use axum::http::Request;
use axum::middleware::Next;
use axum::response::Response;
use subtle::ConstantTimeEq;

use super::types::ApiError;
use crate::AppState;

const TOKEN_HEADER: &str = "X-Router-Agent-Token";

pub async fn require_ip_and_token(
    State(state): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request<Body>,
    next: Next,
) -> Result<Response, ApiError> {
    if !state.config.ip_allowed(peer.ip()) {
        tracing::warn!(source_ip = %peer.ip(), "rejected request from non-allowlisted source IP");
        return Err(ApiError::forbidden_ip());
    }

    let provided = req
        .headers()
        .get(TOKEN_HEADER)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    if !token_matches(state.config.api_token.as_bytes(), provided.as_bytes()) {
        return Err(ApiError::unauthorized());
    }

    Ok(next.run(req).await)
}

/// Constant-time token comparison. Mirrors Go's
/// `subtle.ConstantTimeCompare`: an upfront length check (itself not
/// constant-time, but it leaks nothing beyond length — the same tradeoff
/// the Go sibling makes) followed by a constant-time comparison of the
/// bytes themselves.
fn token_matches(expected: &[u8], provided: &[u8]) -> bool {
    expected.len() == provided.len() && bool::from(expected.ct_eq(provided))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equal_tokens_match() {
        assert!(token_matches(b"supersecret", b"supersecret"));
    }

    #[test]
    fn different_tokens_do_not_match() {
        assert!(!token_matches(b"supersecret", b"wrongtoken12"));
    }

    #[test]
    fn different_length_tokens_do_not_match() {
        assert!(!token_matches(b"supersecret", b"short"));
        assert!(!token_matches(b"short", b""));
    }
}
