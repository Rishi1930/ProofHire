package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/rishi1930/proofhire/backend/config"
	"github.com/rishi1930/proofhire/backend/gemini"
	"github.com/rishi1930/proofhire/backend/resume"
	"github.com/rishi1930/proofhire/backend/screening"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := config.LoadBackendEnv(); err != nil {
		logger.Error("screening worker environment file could not be loaded", "error", err)
		os.Exit(1)
	}
	environment, err := config.FromEnvironment()
	if err != nil {
		logger.Error("screening worker configuration is invalid", "error", err)
		os.Exit(1)
	}

	provider := gemini.NewClient(
		environment.GeminiAPIKey,
		environment.GeminiModel,
		gemini.WithLogger(logger),
	)
	worker, err := screening.NewWorker(screening.Options{
		SupabaseURL:            environment.SupabaseURL,
		SupabaseSecretKey:      environment.SupabaseSecretKey,
		SupabaseServiceRoleKey: environment.SupabaseServiceRoleKey,
		Provider:               provider,
		Extractor:              resume.NewExtractor(resume.Options{MaxTextBytes: 100 << 10, EnableOCR: environment.ResumeOCREnabled}),
		Concurrency:            environment.ScreeningConcurrency,
		PollInterval:           environment.ScreeningPollInterval,
		Logger:                 logger,
	})
	if err != nil {
		logger.Error("screening worker could not start", "error", err)
		os.Exit(1)
	}
	if environment.GeminiAPIKey == "" {
		if err := worker.PauseForMissingGemini(context.Background()); err != nil {
			logger.Error("could not pause screening jobs without Gemini configuration", "error", err)
			os.Exit(1)
		}
		logger.Warn("screening jobs are waiting for GEMINI_API_KEY configuration")
		return
	}
	if err := provider.VerifyModel(context.Background()); err != nil {
		if pauseErr := worker.PauseForMissingGemini(context.Background()); pauseErr != nil {
			logger.Error("screening jobs could not be paused after Gemini model verification failed", "error", pauseErr)
		}
		logger.Error("configured Gemini model is unavailable or cannot generate content", "error", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	logger.Info(
		"screening worker started",
		"model", environment.GeminiModel,
		"concurrency", environment.ScreeningConcurrency,
		"poll_interval", environment.ScreeningPollInterval.String(),
	)
	if err := worker.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		logger.Error("screening worker stopped unexpectedly", "error", err)
		os.Exit(1)
	}
}
