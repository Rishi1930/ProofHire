package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/rishi1930/proofhire/backend/httpapi"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	handler, err := httpapi.NewHandlerFromEnvironment(logger)
	if err != nil {
		logger.Error("backend configuration is invalid", "error", err)
		os.Exit(1)
	}

	address := os.Getenv("BACKEND_ADDR")
	if address == "" {
		address = ":8080"
	}
	server := &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	shutdown, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-shutdown.Done()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			logger.Error("backend shutdown failed", "error", err)
		}
	}()

	logger.Info("ProofHire backend listening", "address", address)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("backend stopped unexpectedly", "error", err)
		os.Exit(1)
	}
}
