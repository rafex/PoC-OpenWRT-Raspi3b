// Package api implements the router-agent HTTP surface: routing, the
// source-IP + token auth middleware, request validation, and translating
// internal/dispatch results into the exact JSON response shapes the caller
// (an external captive-portal backend) depends on.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"router-agent/internal/dispatch"
	"router-agent/internal/nftjson"
)

var errInvalidRemoteAddr = errors.New("api: could not parse request remote address")

const (
	defaultAllowTimeoutMin = 30
	maxRequestBodyBytes    = 8 << 10 // 8KiB is generous for these tiny JSON bodies
)

// ServerConfig configures a Server.
type ServerConfig struct {
	Token          string
	AllowedCIDRs   []*net.IPNet
	Dispatcher     *dispatch.Dispatcher
	Logger         *slog.Logger
	RequestTimeout time.Duration // bounds each SSH round trip a handler makes
}

// Server holds the dependencies HTTP handlers need and exposes the routed
// http.Handler for the service.
type Server struct {
	token          string
	allowedCIDRs   []*net.IPNet
	dispatcher     *dispatch.Dispatcher
	logger         *slog.Logger
	requestTimeout time.Duration
}

// NewServer builds a Server from cfg.
func NewServer(cfg ServerConfig) *Server {
	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}
	timeout := cfg.RequestTimeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	return &Server{
		token:          cfg.Token,
		allowedCIDRs:   cfg.AllowedCIDRs,
		dispatcher:     cfg.Dispatcher,
		logger:         logger,
		requestTimeout: timeout,
	}
}

// Routes returns the fully wired http.Handler for the service: /healthz is
// unauthenticated liveness only; every /v1/* route goes through the IP
// allowlist + token middleware.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", s.handleHealthz)

	mux.HandleFunc("POST /v1/allow", s.protect(s.handleAllow))
	mux.HandleFunc("POST /v1/block", s.protect(s.handleBlock))
	mux.HandleFunc("GET /v1/list", s.protect(s.handleList))
	mux.HandleFunc("GET /v1/status", s.protect(s.handleStatus))

	return mux
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, HealthResponse{Status: "ok"})
}

func (s *Server) handleAllow(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), s.requestTimeout)
	defer cancel()

	var req AllowRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, ErrCodeInvalidIP, fmt.Sprintf("malformed request body: %v", err))
		return
	}

	if !ValidateIPv4(req.IP) {
		writeError(w, http.StatusBadRequest, ErrCodeInvalidIP, fmt.Sprintf("invalid ip: %q", req.IP))
		return
	}

	timeoutMin := defaultAllowTimeoutMin
	if req.TimeoutMin != "" {
		n, err := req.TimeoutMin.Int64()
		if err != nil || n < 0 || n > math.MaxInt32 {
			writeError(w, http.StatusBadRequest, ErrCodeInvalidTimeout, fmt.Sprintf("invalid timeout_min: %q", req.TimeoutMin.String()))
			return
		}
		timeoutMin = int(n)
	}

	if _, err := s.dispatcher.Allow(ctx, req.IP, timeoutMin); err != nil {
		s.writeDispatchError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, AllowResponse{IP: req.IP, Status: "allowed", TimeoutMin: timeoutMin})
}

func (s *Server) handleBlock(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), s.requestTimeout)
	defer cancel()

	var req BlockRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, http.StatusBadRequest, ErrCodeInvalidIP, fmt.Sprintf("malformed request body: %v", err))
		return
	}

	if !ValidateIPv4(req.IP) {
		writeError(w, http.StatusBadRequest, ErrCodeInvalidIP, fmt.Sprintf("invalid ip: %q", req.IP))
		return
	}

	// Blocking an IP that isn't currently allowed is idempotent success —
	// internal/dispatch already maps the dispatcher's
	// "OK block <ip> (not present)" response to a normal BlockResult, so
	// there is nothing IP-presence-specific to check here.
	if _, err := s.dispatcher.Block(ctx, req.IP); err != nil {
		s.writeDispatchError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, BlockResponse{IP: req.IP, Status: "blocked"})
}

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), s.requestTimeout)
	defer cancel()

	raw, err := s.dispatcher.List(ctx)
	if err != nil {
		s.writeDispatchError(w, err)
		return
	}

	clients, err := nftjson.Parse([]byte(raw))
	if err != nil {
		s.logger.Error("failed to parse nft list output", "error", err)
		writeError(w, http.StatusBadGateway, ErrCodeRouterCommandFailed, "router returned an nft list payload the agent could not parse")
		return
	}

	writeJSON(w, http.StatusOK, ListResponse{Clients: clients})
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), s.requestTimeout)
	defer cancel()

	start := time.Now()
	result, err := s.dispatcher.Status(ctx)
	elapsed := time.Since(start)

	if err != nil {
		var derr *dispatch.Error
		if errors.As(err, &derr) {
			switch derr.Kind {
			case dispatch.KindRouterUnreachable, dispatch.KindRouterTimeout:
				// Router-side/transport condition: this is a legitimate
				// observed state for /v1/status, never a 5xx.
				writeJSON(w, http.StatusOK, StatusResponse{RouterReachable: false})
				return
			default:
				// The dispatcher answered but in a shape we don't
				// recognize at all — that's an agent-side problem, not a
				// router state we know how to report.
				s.logger.Error("unexpected status dispatch result", "error", derr.Message)
				writeError(w, http.StatusInternalServerError, ErrCodeInternalError, derr.Message)
				return
			}
		}
		s.logger.Error("unexpected status error", "error", err)
		writeError(w, http.StatusInternalServerError, ErrCodeInternalError, err.Error())
		return
	}

	latencyMs := elapsed.Milliseconds()
	tablePresent := result.TablePresent
	writeJSON(w, http.StatusOK, StatusResponse{
		RouterReachable: true,
		NFTTablePresent: &tablePresent,
		SSHLatencyMs:    &latencyMs,
	})
}

// writeDispatchError maps a dispatch.Error's Kind to the HTTP status and
// error code documented in the API contract for the mutating routes
// (/v1/allow, /v1/block, /v1/list): 504 for a timed-out SSH round trip, 502
// for anything else the router side did wrong (unreachable transport or a
// non-conforming/failed dispatcher response).
func (s *Server) writeDispatchError(w http.ResponseWriter, err error) {
	var derr *dispatch.Error
	if errors.As(err, &derr) {
		switch derr.Kind {
		case dispatch.KindRouterTimeout:
			writeError(w, http.StatusGatewayTimeout, ErrCodeRouterTimeout, derr.Message)
		case dispatch.KindRouterUnreachable:
			writeError(w, http.StatusBadGateway, ErrCodeRouterUnreachable, derr.Message)
		case dispatch.KindRouterCommandFailed:
			writeError(w, http.StatusBadGateway, ErrCodeRouterCommandFailed, derr.Message)
		default:
			writeError(w, http.StatusInternalServerError, ErrCodeInternalError, derr.Message)
		}
		return
	}
	s.logger.Error("unclassified dispatch error", "error", err)
	writeError(w, http.StatusInternalServerError, ErrCodeInternalError, err.Error())
}

// ValidateIPv4 replicates, on purpose, the exact semantics of _validate_ip
// in agent-dispatch.sh / setup-captive.sh: exactly four dot-separated
// all-digit octets, each in [0,255]. It intentionally does NOT use
// net.ParseIP, which (since Go 1.17) rejects octets with leading zeros —
// the router-side shell validator accepts them (shell arithmetic comparison
// treats "010" as decimal 10), so using net.ParseIP here would make the
// HTTP layer reject IPs the router would actually have accepted, or vice
// versa. Also rejects IPv6 implicitly, since it requires dot-separated
// decimal octets.
func ValidateIPv4(ip string) bool {
	if ip == "" {
		return false
	}
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if p == "" || len(p) > 3 {
			return false
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				return false
			}
		}
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 || n > 255 {
			return false
		}
	}
	return true
}

func decodeJSON(w http.ResponseWriter, r *http.Request, v any) error {
	defer func() { _, _ = io.Copy(io.Discard, r.Body); _ = r.Body.Close() }()
	body := http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
	dec := json.NewDecoder(body)
	if err := dec.Decode(v); err != nil {
		return err
	}
	return nil
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, ErrorResponse{Error: code, Message: message})
}
