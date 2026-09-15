//! Wire types for the HTTP API. Field names and shapes must match the
//! sibling Go implementation exactly — see router-agent/rust/README.md and
//! the API contract in the task spec this crate was built from.

use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};

use crate::nft_json::ClientEntry;

/// Raw request body for `POST /v1/allow`. Fields are captured as
/// `serde_json::Value` (rather than `String`/`i64` directly) so handlers
/// can distinguish "field absent" from "field present but wrong
/// type/negative/non-integer" and return the precise `invalid_ip` /
/// `invalid_timeout` error the spec calls for, instead of a generic body
/// rejection.
#[derive(Debug, Deserialize)]
pub struct AllowRequestRaw {
    pub ip: Option<serde_json::Value>,
    #[serde(default)]
    pub timeout_min: Option<serde_json::Value>,
}

/// Raw request body for `POST /v1/block`.
#[derive(Debug, Deserialize)]
pub struct BlockRequestRaw {
    pub ip: Option<serde_json::Value>,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct AllowResponse {
    pub ip: String,
    pub status: &'static str,
    pub timeout_min: i64,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct BlockResponse {
    pub ip: String,
    pub status: &'static str,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct ListResponse {
    pub clients: Vec<ClientEntry>,
}

#[derive(Debug, Serialize, PartialEq, Default)]
pub struct StatusResponse {
    pub router_reachable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub nft_table_present: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ssh_latency_ms: Option<u64>,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct HealthzResponse {
    pub status: &'static str,
}

/// Error body shape for every non-2xx JSON response.
#[derive(Debug, Serialize, PartialEq)]
pub struct ErrorBody {
    pub error: &'static str,
    pub message: String,
}

/// One of the fixed error codes from the API contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    InvalidIp,
    InvalidTimeout,
    Unauthorized,
    ForbiddenIp,
    RouterUnreachable,
    RouterCommandFailed,
    RouterTimeout,
    InternalError,
}

impl ErrorCode {
    fn as_str(self) -> &'static str {
        match self {
            ErrorCode::InvalidIp => "invalid_ip",
            ErrorCode::InvalidTimeout => "invalid_timeout",
            ErrorCode::Unauthorized => "unauthorized",
            ErrorCode::ForbiddenIp => "forbidden_ip",
            ErrorCode::RouterUnreachable => "router_unreachable",
            ErrorCode::RouterCommandFailed => "router_command_failed",
            ErrorCode::RouterTimeout => "router_timeout",
            ErrorCode::InternalError => "internal_error",
        }
    }

    fn status(self) -> StatusCode {
        match self {
            ErrorCode::InvalidIp | ErrorCode::InvalidTimeout => StatusCode::BAD_REQUEST,
            ErrorCode::Unauthorized => StatusCode::UNAUTHORIZED,
            ErrorCode::ForbiddenIp => StatusCode::FORBIDDEN,
            ErrorCode::RouterUnreachable | ErrorCode::RouterCommandFailed => {
                StatusCode::BAD_GATEWAY
            }
            ErrorCode::RouterTimeout => StatusCode::GATEWAY_TIMEOUT,
            ErrorCode::InternalError => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }
}

#[derive(Debug)]
pub struct ApiError {
    pub code: ErrorCode,
    pub message: String,
}

impl ApiError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn invalid_ip(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::InvalidIp, message)
    }

    pub fn invalid_timeout(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::InvalidTimeout, message)
    }

    pub fn unauthorized() -> Self {
        Self::new(ErrorCode::Unauthorized, "missing or invalid API token")
    }

    pub fn forbidden_ip() -> Self {
        Self::new(
            ErrorCode::ForbiddenIp,
            "source IP is not in the allowed CIDR list",
        )
    }

    pub fn router_unreachable(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::RouterUnreachable, message)
    }

    pub fn router_command_failed(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::RouterCommandFailed, message)
    }

    pub fn router_timeout() -> Self {
        Self::new(
            ErrorCode::RouterTimeout,
            "SSH command to router exceeded the configured timeout",
        )
    }

    pub fn internal_error(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::InternalError, message)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = self.code.status();
        let body = ErrorBody {
            error: self.code.as_str(),
            message: self.message,
        };
        (status, Json(body)).into_response()
    }
}
