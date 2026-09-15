// Package sshclient maintains a single, persistent SSH connection to the
// OpenWRT router and serializes exec requests over it. It deliberately does
// NOT dial a fresh TCP+SSH connection per HTTP request: SSH handshakes are
// comparatively expensive and the router is a constrained embedded device,
// so router-agent instead keeps one connection alive, opening a new "exec"
// channel per command, and reconnects with backoff only when the
// connection is observed to be dead.
package sshclient

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

// Sentinel errors that callers (internal/dispatch) can match on with
// errors.Is to distinguish "router unreachable" from "command timed out"
// from an ordinary command failure.
var (
	// ErrUnreachable indicates the SSH transport itself could not be
	// established or was lost (dial failure, connection reset, EOF, etc.)
	// after retries.
	ErrUnreachable = errors.New("sshclient: router unreachable")

	// ErrTimeout indicates the connect or exec exceeded the configured
	// SSH timeout.
	ErrTimeout = errors.New("sshclient: command timed out")
)

// Config configures a Client.
type Config struct {
	Host           string
	Port           int
	User           string
	KeyPath        string        // path to the restricted SSH private key
	KnownHostsPath string        // path to a known_hosts file used for host key verification
	Timeout        time.Duration // applies to both connect and per-command exec
	Logger         *slog.Logger
}

// Client is a persistent, mutex-serialized SSH connection to the router.
// All exported methods are safe for concurrent use; internally, at most one
// exec channel is ever open at a time (never unbounded concurrent
// channels), which keeps resource usage on the embedded router predictable.
type Client struct {
	cfg       Config
	addr      string
	clientCfg *ssh.ClientConfig
	logger    *slog.Logger

	mu   sync.Mutex // serializes Exec calls and guards conn
	conn *ssh.Client
}

// New builds a Client from cfg. It parses the restricted private key and
// the known_hosts file eagerly (so a misconfigured deployment fails fast at
// startup) but does NOT dial the router yet — the first call to Exec will
// establish the connection lazily. This matters because the router may
// still be booting when router-agent starts.
func New(cfg Config) (*Client, error) {
	keyBytes, err := os.ReadFile(cfg.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("sshclient: reading private key %q: %w", cfg.KeyPath, err)
	}
	signer, err := ssh.ParsePrivateKey(keyBytes)
	if err != nil {
		return nil, fmt.Errorf("sshclient: parsing private key %q: %w", cfg.KeyPath, err)
	}

	// knownhosts.New parses a standard OpenSSH known_hosts file and returns
	// an ssh.HostKeyCallback that verifies the presented host key against
	// it. We deliberately never use ssh.InsecureIgnoreHostKey().
	hostKeyCallback, err := knownhosts.New(cfg.KnownHostsPath)
	if err != nil {
		return nil, fmt.Errorf("sshclient: loading known_hosts %q: %w", cfg.KnownHostsPath, err)
	}

	logger := cfg.Logger
	if logger == nil {
		logger = slog.Default()
	}

	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Second
	}

	c := &Client{
		cfg:    cfg,
		addr:   net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port)),
		logger: logger,
		clientCfg: &ssh.ClientConfig{
			User:            cfg.User,
			Auth:            []ssh.AuthMethod{ssh.PublicKeys(signer)},
			HostKeyCallback: hostKeyCallback,
			Timeout:         cfg.Timeout,
		},
	}
	return c, nil
}

// Exec runs cmd as the SSH "exec" request over the persistent connection,
// establishing (or re-establishing) that connection first if needed. It
// returns the command's stdout, stderr and exit code. A non-nil error means
// the command's result could not be determined at all (transport failure or
// timeout) — as opposed to the command itself failing, which is reported via
// a non-zero exitCode with err == nil.
func (c *Client) Exec(ctx context.Context, cmd string) (stdout, stderr string, exitCode int, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.ensureConnectedLocked(ctx); err != nil {
		return "", "", 0, err
	}

	session, err := c.conn.NewSession()
	if err != nil {
		// The persistent connection looked alive but could not open a new
		// channel — treat it as dead and try exactly once more after a
		// reconnect before giving up on this request.
		c.logger.Warn("ssh session open failed, reconnecting", "error", err)
		c.closeLocked()
		if err2 := c.ensureConnectedLocked(ctx); err2 != nil {
			return "", "", 0, err2
		}
		session, err = c.conn.NewSession()
		if err != nil {
			c.closeLocked()
			return "", "", 0, fmt.Errorf("%w: opening session: %v", ErrUnreachable, err)
		}
	}
	defer session.Close()

	var stdoutBuf, stderrBuf bytes.Buffer
	session.Stdout = &stdoutBuf
	session.Stderr = &stderrBuf

	deadline := time.Now().Add(c.cfg.Timeout)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	wait := time.Until(deadline)
	if wait < 0 {
		wait = 0
	}

	done := make(chan error, 1)
	go func() {
		done <- session.Run(cmd)
	}()

	select {
	case runErr := <-done:
		if runErr == nil {
			return stdoutBuf.String(), stderrBuf.String(), 0, nil
		}
		var exitErr *ssh.ExitError
		if errors.As(runErr, &exitErr) {
			// The dispatcher ran and exited non-zero — this is a normal,
			// well-formed result, not a transport error.
			return stdoutBuf.String(), stderrBuf.String(), exitErr.ExitStatus(), nil
		}
		// Anything else (ssh.ExitMissingError from a dropped connection,
		// channel errors, etc.) means we can't trust the connection.
		c.logger.Warn("ssh command failed at transport level, marking connection dead", "error", runErr)
		c.closeLocked()
		return "", "", 0, fmt.Errorf("%w: %v", ErrUnreachable, runErr)
	case <-time.After(wait):
		_ = session.Signal(ssh.SIGKILL)
		session.Close()
		// Conservative: a wedged command may have left the connection in an
		// inconsistent state, so drop it and force a reconnect next time.
		c.closeLocked()
		return "", "", 0, fmt.Errorf("%w: exceeded %s", ErrTimeout, c.cfg.Timeout)
	case <-ctx.Done():
		session.Close()
		return "", "", 0, fmt.Errorf("%w: %v", ErrTimeout, ctx.Err())
	}
}

// Close releases the underlying SSH connection, if any.
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.closeLocked()
	return nil
}

func (c *Client) closeLocked() {
	if c.conn != nil {
		_ = c.conn.Close()
		c.conn = nil
	}
}
