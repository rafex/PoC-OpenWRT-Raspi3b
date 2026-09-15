pub mod handlers;
pub mod middleware;
pub mod types;

use std::sync::Arc;

use axum::Router;
use axum::extract::DefaultBodyLimit;
use axum::routing::{get, post};

use crate::AppState;

/// 8KiB is generous for these tiny JSON bodies; matches the Go sibling's
/// `http.MaxBytesReader` limit.
const MAX_REQUEST_BODY_BYTES: usize = 8 << 10;

/// Builds the fully wired axum `Router`: `/healthz` is unauthenticated
/// liveness only; every `/v1/*` route goes through the IP allowlist +
/// token middleware.
pub fn build_router(state: Arc<AppState>) -> Router {
    let protected = Router::new()
        .route("/v1/allow", post(handlers::allow))
        .route("/v1/block", post(handlers::block))
        .route("/v1/list", get(handlers::list))
        .route("/v1/status", get(handlers::status))
        .route_layer(axum::middleware::from_fn_with_state(
            state.clone(),
            middleware::require_ip_and_token,
        ));

    Router::new()
        .route("/healthz", get(handlers::healthz))
        .merge(protected)
        .layer(DefaultBodyLimit::max(MAX_REQUEST_BODY_BYTES))
        .with_state(state)
}
