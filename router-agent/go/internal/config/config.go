// Package config loads and validates router-agent configuration from
// environment variables. All values are read once at startup; the process
// fails fast with a single, clear error listing every missing/invalid
// variable rather than dying on the first one found.
package config

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds the fully validated runtime configuration for router-agent.
type Config struct {
	ListenAddr string

	APIToken string

	AllowedCIDRs []*net.IPNet

	SSHHost       string
	SSHPort       int
	SSHUser       string
	SSHKeyPath    string
	SSHKnownHosts string
	SSHTimeout    time.Duration

	LogLevel string
}

const (
	envListenAddr    = "ROUTER_AGENT_LISTEN_ADDR"
	envAPIToken      = "ROUTER_AGENT_API_TOKEN"
	envAllowedCIDRs  = "ROUTER_AGENT_ALLOWED_CIDRS"
	envSSHHost       = "ROUTER_AGENT_SSH_HOST"
	envSSHPort       = "ROUTER_AGENT_SSH_PORT"
	envSSHUser       = "ROUTER_AGENT_SSH_USER"
	envSSHKeyPath    = "ROUTER_AGENT_SSH_KEY_PATH"
	envSSHKnownHosts = "ROUTER_AGENT_SSH_KNOWN_HOSTS_PATH"
	envSSHTimeoutMs  = "ROUTER_AGENT_SSH_TIMEOUT_MS"
	envLogLevel      = "ROUTER_AGENT_LOG_LEVEL"

	defaultListenAddr = "0.0.0.0:8443"
	defaultSSHPort    = 22
	defaultSSHUser    = "root"
	defaultSSHTimeout = 5000 * time.Millisecond
	defaultLogLevel   = "info"
)

// Load reads and validates configuration from the process environment.
// It returns a single aggregated error describing every problem found, so
// an operator can fix a misconfigured deployment in one pass.
func Load() (*Config, error) {
	var problems []string

	cfg := &Config{
		ListenAddr: getOrDefault(envListenAddr, defaultListenAddr),
		SSHUser:    getOrDefault(envSSHUser, defaultSSHUser),
		LogLevel:   getOrDefault(envLogLevel, defaultLogLevel),
	}

	cfg.APIToken = os.Getenv(envAPIToken)
	if cfg.APIToken == "" {
		problems = append(problems, fmt.Sprintf("%s is required", envAPIToken))
	}

	cidrRaw := os.Getenv(envAllowedCIDRs)
	if cidrRaw == "" {
		problems = append(problems, fmt.Sprintf("%s is required", envAllowedCIDRs))
	} else {
		nets, err := parseCIDRList(cidrRaw)
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s: %v", envAllowedCIDRs, err))
		} else {
			cfg.AllowedCIDRs = nets
		}
	}

	cfg.SSHHost = os.Getenv(envSSHHost)
	if cfg.SSHHost == "" {
		problems = append(problems, fmt.Sprintf("%s is required", envSSHHost))
	}

	cfg.SSHPort = defaultSSHPort
	if raw := os.Getenv(envSSHPort); raw != "" {
		port, err := strconv.Atoi(raw)
		if err != nil || port <= 0 || port > 65535 {
			problems = append(problems, fmt.Sprintf("%s must be a valid TCP port, got %q", envSSHPort, raw))
		} else {
			cfg.SSHPort = port
		}
	}

	cfg.SSHKeyPath = os.Getenv(envSSHKeyPath)
	if cfg.SSHKeyPath == "" {
		problems = append(problems, fmt.Sprintf("%s is required", envSSHKeyPath))
	}

	cfg.SSHKnownHosts = os.Getenv(envSSHKnownHosts)
	if cfg.SSHKnownHosts == "" {
		problems = append(problems, fmt.Sprintf("%s is required", envSSHKnownHosts))
	}

	cfg.SSHTimeout = defaultSSHTimeout
	if raw := os.Getenv(envSSHTimeoutMs); raw != "" {
		ms, err := strconv.Atoi(raw)
		if err != nil || ms <= 0 {
			problems = append(problems, fmt.Sprintf("%s must be a positive integer (milliseconds), got %q", envSSHTimeoutMs, raw))
		} else {
			cfg.SSHTimeout = time.Duration(ms) * time.Millisecond
		}
	}

	switch cfg.LogLevel {
	case "debug", "info", "warn", "error":
	default:
		problems = append(problems, fmt.Sprintf("%s must be one of debug/info/warn/error, got %q", envLogLevel, cfg.LogLevel))
	}

	if len(problems) > 0 {
		return nil, fmt.Errorf("invalid router-agent configuration:\n  - %s", strings.Join(problems, "\n  - "))
	}

	return cfg, nil
}

func getOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func parseCIDRList(raw string) ([]*net.IPNet, error) {
	parts := strings.Split(raw, ",")
	nets := make([]*net.IPNet, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		_, ipnet, err := net.ParseCIDR(p)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR %q: %w", p, err)
		}
		nets = append(nets, ipnet)
	}
	if len(nets) == 0 {
		return nil, fmt.Errorf("no valid CIDRs found")
	}
	return nets, nil
}
