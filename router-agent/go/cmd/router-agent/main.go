// Command router-agent is a narrow HTTP-to-SSH bridge: it lets an external
// captive-portal backend authorize or revoke client IPs on an OpenWRT
// router by calling a small HTTP API, without ever holding SSH credentials
// to the router itself. See router-agent/go/README.md for the full API
// contract and configuration reference.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"router-agent/internal/api"
	"router-agent/internal/config"
	"router-agent/internal/dispatch"
	"router-agent/internal/sshclient"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "router-agent: "+err.Error())
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	logger := newLogger(cfg.LogLevel)
	slog.SetDefault(logger)

	sshClient, err := sshclient.New(sshclient.Config{
		Host:           cfg.SSHHost,
		Port:           cfg.SSHPort,
		User:           cfg.SSHUser,
		KeyPath:        cfg.SSHKeyPath,
		KnownHostsPath: cfg.SSHKnownHosts,
		Timeout:        cfg.SSHTimeout,
		Logger:         logger,
	})
	if err != nil {
		return fmt.Errorf("initializing ssh client: %w", err)
	}
	defer sshClient.Close()

	// Best-effort warm connect at startup. The router may still be
	// rebooting when router-agent starts, so this is logged but never
	// fatal — Exec() will lazily (re)connect on the first real request.
	warmUp(logger, sshClient, cfg.SSHTimeout)

	dispatcher := dispatch.New(sshClient)

	server := api.NewServer(api.ServerConfig{
		Token:          cfg.APIToken,
		AllowedCIDRs:   cfg.AllowedCIDRs,
		Dispatcher:     dispatcher,
		Logger:         logger,
		RequestTimeout: cfg.SSHTimeout,
	})

	httpServer := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           server.Routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	serveErr := make(chan error, 1)
	go func() {
		logger.Info("router-agent listening", "addr", cfg.ListenAddr)
		serveErr <- httpServer.ListenAndServe()
	}()

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	select {
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("http server: %w", err)
		}
		return nil
	case <-ctx.Done():
		logger.Info("shutdown signal received, draining connections")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("http server shutdown: %w", err)
		}
		return nil
	}
}

func warmUp(logger *slog.Logger, client *sshclient.Client, timeout time.Duration) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	if _, _, _, err := client.Exec(ctx, "status"); err != nil {
		logger.Warn("initial ssh connection not yet established, will retry lazily on first request", "error", err)
		return
	}
	logger.Info("initial ssh connection established")
}

func newLogger(level string) *slog.Logger {
	var lvl slog.Level
	switch level {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}
	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl})
	return slog.New(handler)
}
