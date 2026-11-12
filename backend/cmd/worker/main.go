package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/rishi1930/proofhire/backend/config"
	"github.com/rishi1930/proofhire/backend/email"
	"github.com/rishi1930/proofhire/backend/interview"
	"github.com/rishi1930/proofhire/backend/resume"
	"github.com/rishi1930/proofhire/backend/runner"
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

	worker, err := screening.NewWorker(screening.Options{
		SupabaseURL:            environment.SupabaseURL,
		SupabaseSecretKey:      environment.SupabaseSecretKey,
		SupabaseServiceRoleKey: environment.SupabaseServiceRoleKey,
		Extractor:              resume.NewExtractor(resume.Options{MaxTextBytes: 100 << 10, EnableOCR: environment.ResumeOCREnabled}),
		Concurrency:            environment.ScreeningConcurrency,
		PollInterval:           environment.ScreeningPollInterval,
		Logger:                 logger,
	})
	if err != nil {
		logger.Error("screening worker could not start", "error", err)
		os.Exit(1)
	}
	emailWorker, err := email.NewWorker(environment, logger)
	if err != nil {
		logger.Error("email worker could not start", "error", err)
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if environment.CodeRunnerEnabled {
		codeRunner := runner.NewEngine()
		if len(environment.RunnerPrewarmLanguages) > 0 {
			if err := codeRunner.Prewarm(ctx, environment.RunnerPrewarmLanguages); err != nil {
				logger.Error("code runner images could not be prepared", "error", err)
			}
		}
		interviewWorker, err := interview.NewWorker(environment, codeRunner, logger)
		if err != nil {
			logger.Error("interview evaluation worker could not start", "error", err)
			os.Exit(1)
		}
		go func() {
			if err := interviewWorker.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
				logger.Error("interview evaluation worker stopped unexpectedly", "error", err)
				stop()
			}
		}()
	}

	go func() {
		if err := emailWorker.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
			logger.Error("email worker stopped unexpectedly", "error", err)
			stop()
		}
	}()
	logger.Info(
		"screening, email and interview workers started",
		"engine", "proofhire-deterministic-1",
		"concurrency", environment.ScreeningConcurrency,
		"poll_interval", environment.ScreeningPollInterval.String(),
	)
	if err := worker.Run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		logger.Error("screening worker stopped unexpectedly", "error", err)
		os.Exit(1)
	}
}
