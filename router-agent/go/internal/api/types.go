package api

import (
	"encoding/json"

	"router-agent/internal/nftjson"
)

// AllowRequest is the body of POST /v1/allow.
type AllowRequest struct {
	IP string `json:"ip"`
	// TimeoutMin is optional; a json.Number lets us tell "absent" (empty
	// string) apart from "0" and reject non-integer values (e.g. "30.5")
	// without floating-point round-tripping.
	TimeoutMin json.Number `json:"timeout_min"`
}

// AllowResponse is the body of a successful POST /v1/allow.
type AllowResponse struct {
	IP         string `json:"ip"`
	Status     string `json:"status"`
	TimeoutMin int    `json:"timeout_min"`
}

// BlockRequest is the body of POST /v1/block.
type BlockRequest struct {
	IP string `json:"ip"`
}

// BlockResponse is the body of a successful POST /v1/block.
type BlockResponse struct {
	IP     string `json:"ip"`
	Status string `json:"status"`
}

// ListResponse is the body of a successful GET /v1/list.
type ListResponse struct {
	Clients []nftjson.Client `json:"clients"`
}

// StatusResponse is the body of GET /v1/status. This endpoint always
// answers 200 for router-side conditions (unreachable, table missing); the
// pointer fields are nil (omitted from JSON) when RouterReachable is false.
type StatusResponse struct {
	RouterReachable bool   `json:"router_reachable"`
	NFTTablePresent *bool  `json:"nft_table_present,omitempty"`
	SSHLatencyMs    *int64 `json:"ssh_latency_ms,omitempty"`
}

// HealthResponse is the body of GET /healthz.
type HealthResponse struct {
	Status string `json:"status"`
}

// ErrorResponse is the body of every non-2xx JSON response.
type ErrorResponse struct {
	Error   string `json:"error"`
	Message string `json:"message"`
}

// Error codes used in ErrorResponse.Error, per the API contract.
const (
	ErrCodeInvalidIP           = "invalid_ip"
	ErrCodeInvalidTimeout      = "invalid_timeout"
	ErrCodeUnauthorized        = "unauthorized"
	ErrCodeForbiddenIP         = "forbidden_ip"
	ErrCodeRouterUnreachable   = "router_unreachable"
	ErrCodeRouterCommandFailed = "router_command_failed"
	ErrCodeRouterTimeout       = "router_timeout"
	ErrCodeInternalError       = "internal_error"
)
