package sshclient

import (
	"context"
	"fmt"
	"net"
	"time"

	"golang.org/x/crypto/ssh"
)

// A handful of quick retries with exponential backoff is enough to ride out
// a brief blip (e.g. the router's dropbear restarting) without holding an
// HTTP request open indefinitely — anything longer than that should surface
// to the caller as router_unreachable so the caller can retry later.
const (
	maxDialAttempts = 3
	baseBackoff     = 200 * time.Millisecond
)

// ensureConnectedLocked dials (or redials) the router if there is no live
// connection. Callers must hold c.mu.
func (c *Client) ensureConnectedLocked(ctx context.Context) error {
	if c.conn != nil {
		return nil
	}

	var lastErr error
	for attempt := 1; attempt <= maxDialAttempts; attempt++ {
		if attempt > 1 {
			backoff := baseBackoff * time.Duration(1<<uint(attempt-2))
			timer := time.NewTimer(backoff)
			select {
			case <-timer.C:
			case <-ctx.Done():
				timer.Stop()
				return fmt.Errorf("%w: %v", ErrUnreachable, ctx.Err())
			}
		}

		dialCtx, cancel := context.WithTimeout(ctx, c.cfg.Timeout)
		conn, err := c.dialOnce(dialCtx)
		cancel()
		if err == nil {
			c.conn = conn
			c.logger.Info("ssh connection established", "host", c.cfg.Host, "port", c.cfg.Port, "attempt", attempt)
			return nil
		}
		lastErr = err
		c.logger.Warn("ssh dial attempt failed", "attempt", attempt, "of", maxDialAttempts, "error", err)
	}

	return fmt.Errorf("%w: %v", ErrUnreachable, lastErr)
}

// dialOnce performs a single TCP dial + SSH handshake attempt.
func (c *Client) dialOnce(ctx context.Context) (*ssh.Client, error) {
	var d net.Dialer
	netConn, err := d.DialContext(ctx, "tcp", c.addr)
	if err != nil {
		return nil, fmt.Errorf("tcp dial %s: %w", c.addr, err)
	}

	// ssh.NewClientConn does its own auth-and-handshake timeout via
	// clientCfg.Timeout for the initial banner exchange, but does not
	// itself honor ctx; the outer dial context still bounds the TCP
	// connect above, which is the dominant failure mode for an
	// unreachable/rebooting router.
	sshConn, chans, reqs, err := ssh.NewClientConn(netConn, c.addr, c.clientCfg)
	if err != nil {
		_ = netConn.Close()
		return nil, fmt.Errorf("ssh handshake %s: %w", c.addr, err)
	}

	return ssh.NewClient(sshConn, chans, reqs), nil
}
