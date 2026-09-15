// Package dispatch builds the exact command strings accepted by the
// router-side forced-command dispatcher (router-agent/shared/router-dispatch/
// agent-dispatch.sh) and translates its stdout/stderr/exit-code convention
// into typed results or errors.
//
// Dispatcher grammar (see agent-dispatch.sh for the ground truth):
//
//	allow <ip> [timeout_min]   -> "OK allow <ip> <ntf-timeout>" on stdout, exit 0
//	block <ip>                 -> "OK block <ip>[ (not present)]" on stdout, exit 0 (idempotent)
//	list                       -> `nft -j list set` JSON on stdout, exit 0
//	status                     -> "OK table=... present" on stdout (exit 0), or
//	                              "ERR table missing" on stderr (exit 1)
//	anything else              -> "ERR ..." on stderr, exit 2 (validation error)
package dispatch

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"router-agent/internal/sshclient"
)

// Kind classifies a DispatchError so the HTTP layer can map it to the right
// status code and error body without string-matching messages.
type Kind string

const (
	// KindRouterUnreachable means the SSH transport to the router could not
	// be established or was lost.
	KindRouterUnreachable Kind = "router_unreachable"
	// KindRouterTimeout means the SSH connect or exec exceeded the
	// configured timeout.
	KindRouterTimeout Kind = "router_timeout"
	// KindRouterCommandFailed means we got a response from the dispatcher
	// but it signalled an operational failure (non-zero exit outside the
	// documented "legitimate" cases) or returned output that doesn't match
	// the documented grammar at all.
	KindRouterCommandFailed Kind = "router_command_failed"
)

// Error is returned by every Dispatcher method on failure.
type Error struct {
	Kind    Kind
	Message string
}

func (e *Error) Error() string { return e.Message }

// Execer is the minimal surface Dispatcher needs from the SSH layer; it is
// satisfied by *sshclient.Client, and lets tests substitute a fake.
type Execer interface {
	Exec(ctx context.Context, cmd string) (stdout, stderr string, exitCode int, err error)
}

// Dispatcher sends validated commands to the router's forced-command
// dispatcher over an Execer (in production, a persistent *sshclient.Client)
// and interprets the results.
type Dispatcher struct {
	exec Execer
}

// New builds a Dispatcher around the given command executor.
func New(exec Execer) *Dispatcher {
	return &Dispatcher{exec: exec}
}

// AllowResult is the outcome of a successful "allow" command.
type AllowResult struct {
	IP         string
	TimeoutMin int
}

// BlockResult is the outcome of a successful "block" command.
type BlockResult struct {
	IP string
}

// StatusResult is the outcome of a successful "status" command. A false
// TablePresent reflects the dispatcher's own "ERR table missing" response,
// which is a legitimate observed router state, not a dispatch failure.
type StatusResult struct {
	TablePresent bool
}

func buildAllowCmd(ip string, timeoutMin int) string {
	return fmt.Sprintf("allow %s %d", ip, timeoutMin)
}

func buildBlockCmd(ip string) string {
	return fmt.Sprintf("block %s", ip)
}

// Allow sends "allow <ip> <timeoutMin>". Callers are expected to have
// already validated ip/timeoutMin against the same grammar the router
// enforces (see internal/api), so a validation error (exit 2) coming back
// here is treated defensively as KindRouterCommandFailed rather than
// re-derived into a 400.
func (d *Dispatcher) Allow(ctx context.Context, ip string, timeoutMin int) (*AllowResult, error) {
	stdout, stderr, exitCode, err := d.run(ctx, buildAllowCmd(ip, timeoutMin))
	if err != nil {
		return nil, err
	}
	if exitCode != 0 || !strings.HasPrefix(strings.TrimSpace(stdout), "OK allow ") {
		return nil, commandFailed("allow", stdout, stderr, exitCode)
	}
	return &AllowResult{IP: ip, TimeoutMin: timeoutMin}, nil
}

// Block sends "block <ip>". A dispatcher response of
// "OK block <ip> (not present)" is treated the same as an ordinary success —
// blocking an IP that isn't currently allowed is idempotent.
func (d *Dispatcher) Block(ctx context.Context, ip string) (*BlockResult, error) {
	stdout, stderr, exitCode, err := d.run(ctx, buildBlockCmd(ip))
	if err != nil {
		return nil, err
	}
	if exitCode != 0 || !strings.HasPrefix(strings.TrimSpace(stdout), "OK block ") {
		return nil, commandFailed("block", stdout, stderr, exitCode)
	}
	return &BlockResult{IP: ip}, nil
}

// List sends "list" and returns the raw `nft -j list set` JSON stdout for
// internal/nftjson to parse. The dispatcher always exits 0 for "list" (it
// falls back to `{"nftables":[]}` on its own if nft fails), so any non-zero
// exit here is unexpected.
func (d *Dispatcher) List(ctx context.Context) (string, error) {
	stdout, stderr, exitCode, err := d.run(ctx, "list")
	if err != nil {
		return "", err
	}
	if exitCode != 0 {
		return "", commandFailed("list", stdout, stderr, exitCode)
	}
	return stdout, nil
}

// Status sends "status". Per the dispatcher grammar, exit 0 with
// "OK table=... present" means the table exists; exit 1 with
// "ERR table missing" on stderr means it doesn't — both are well-formed,
// successful dispatch results from Status's point of view. Anything else is
// reported as KindRouterCommandFailed so the HTTP layer can distinguish
// "router told us something legitimate" from "the agent doesn't understand
// what the router just said".
func (d *Dispatcher) Status(ctx context.Context) (*StatusResult, error) {
	stdout, stderr, exitCode, err := d.run(ctx, "status")
	if err != nil {
		return nil, err
	}
	switch {
	case exitCode == 0 && strings.HasPrefix(strings.TrimSpace(stdout), "OK table="):
		return &StatusResult{TablePresent: true}, nil
	case exitCode == 1 && strings.Contains(stderr, "table missing"):
		return &StatusResult{TablePresent: false}, nil
	default:
		return nil, commandFailed("status", stdout, stderr, exitCode)
	}
}

// run executes cmd and translates transport-level sshclient errors into
// dispatch.Error, preserving Kind so the HTTP layer doesn't need to know
// about sshclient's sentinel errors at all.
func (d *Dispatcher) run(ctx context.Context, cmd string) (stdout, stderr string, exitCode int, derr error) {
	stdout, stderr, exitCode, err := d.exec.Exec(ctx, cmd)
	if err != nil {
		switch {
		case errors.Is(err, sshclient.ErrTimeout):
			return "", "", 0, &Error{Kind: KindRouterTimeout, Message: err.Error()}
		case errors.Is(err, sshclient.ErrUnreachable):
			return "", "", 0, &Error{Kind: KindRouterUnreachable, Message: err.Error()}
		default:
			return "", "", 0, &Error{Kind: KindRouterCommandFailed, Message: err.Error()}
		}
	}
	return stdout, stderr, exitCode, nil
}

func commandFailed(op, stdout, stderr string, exitCode int) *Error {
	return &Error{
		Kind: KindRouterCommandFailed,
		Message: fmt.Sprintf(
			"dispatcher %q exited %d: stdout=%q stderr=%q",
			op, exitCode, strings.TrimSpace(stdout), strings.TrimSpace(stderr),
		),
	}
}
