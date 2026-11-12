package main

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

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
		go runWorker(ctx, logger, "interview evaluation worker (needs Docker)", 15*time.Second, interviewWorker.Run)
	}

	go runWorker(ctx, logger, "email worker", 5*time.Second, emailWorker.Run)
	logger.Info(
		"screening, email and interview workers started",
		"engine", "proofhire-deterministic-1",
		"concurrency", environment.ScreeningConcurrency,
		"poll_interval", environment.ScreeningPollInterval.String(),
	)
	runWorker(ctx, logger, "screening worker", 5*time.Second, worker.Run)
}

// runWorker keeps one worker alive without taking the others down with it. A
// missing Docker daemon or a transient database error is retried with backoff
// instead of exiting the process, so screening and email keep delivering.
func runWorker(
	ctx context.Context,
	logger *slog.Logger,
	name string,
	delay time.Duration,
	run func(context.Context) error,
) {
	wait := delay
	for ctx.Err() == nil {
		err := run(ctx)
		if err == nil || errors.Is(err, context.Canceled) || ctx.Err() != nil {
			return
		}
		logger.Error(name+" stopped; retrying", "error", err, "retry_in", wait.String())
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
		if wait < 30*time.Second {
			wait *= 2
			if wait > 30*time.Second {
				wait = 30 * time.Second
			}
		}
	}
}
