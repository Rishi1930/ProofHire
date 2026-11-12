// Package interview evaluates coding submissions for technical interviews.
//
// The worker is a separate long-lived process. It claims one queued submission
// at a time through a service-role RPC, executes the source against every
// private test case through the sandboxed runner, and reports the aggregate
// score back through a second RPC. It never receives candidate tokens and never
// talks to the browser.
package interview

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/rishi1930/proofhire/backend/config"
	"github.com/rishi1930/proofhire/backend/runner"
)

// Executor runs one program against one input. It exists so the evaluation
// logic can be tested without a container runtime.
type Executor interface {
	Run(ctx context.Context, request runner.Request) (runner.Result, error)
	Available(ctx context.Context) error
}

// TestCase is one private test case for a challenge version.
type TestCase struct {
	DisplayOrder   int     `json:"display_order"`
	InputText      string  `json:"input_text"`
	ExpectedOutput string  `json:"expected_output"`
	Points         float64 `json:"points"`
}

// Claim is one submission leased to this worker.
type Claim struct {
	SubmissionID        string     `json:"submission_id"`
	LeaseToken          string     `json:"lease_token"`
	WorkspaceID         string     `json:"workspace_id"`
	SessionID           string     `json:"session_id"`
	ChallengeVersionID  string     `json:"challenge_version_id"`
	Language            string     `json:"language"`
	Source              string     `json:"source"`
	MaxExecutionSeconds int        `json:"max_execution_seconds"`
	Tests               []TestCase `json:"tests"`
}

// TestOutcome is the stored per-test result. Expected values are not echoed
// back: the recruiter already authored them and the candidate never sees them.
type TestOutcome struct {
	DisplayOrder int    `json:"display_order"`
	Status       string `json:"status"`
	DurationMS   int64  `json:"duration_ms"`
	Stderr       string `json:"stderr,omitempty"`
}

// Worker evaluates interview coding submissions.
type Worker struct {
	baseURL    string
	serviceKey string
	credential config.SupabaseCredentialType
	httpClient *http.Client
	executor   Executor
	logger     *slog.Logger
	workerID   string
	pollEvery  time.Duration
}

// NewWorker builds the evaluation worker from backend configuration.
func NewWorker(environment config.Config, executor Executor, logger *slog.Logger) (*Worker, error) {
	key, credential, err := config.ResolveSupabasePrivilegedCredential(
		environment.SupabaseSecretKey,
		environment.SupabaseServiceRoleKey,
	)
	if err != nil {
		return nil, errors.New("interview worker requires a privileged Supabase credential")
	}
	if strings.TrimSpace(environment.SupabaseURL) == "" {
		return nil, errors.New("interview worker requires SUPABASE_URL")
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Worker{
		baseURL:    strings.TrimRight(environment.SupabaseURL, "/"),
		serviceKey: key,
		credential: credential,
		httpClient: &http.Client{Timeout: 60 * time.Second},
		executor:   executor,
		logger:     logger,
		workerID:   "proofhire-interview-" + randomWorkerID(),
		pollEvery:  2 * time.Second,
	}, nil
}

// Run evaluates submissions until the context is cancelled.
func (worker *Worker) Run(ctx context.Context) error {
	if err := worker.executor.Available(ctx); err != nil {
		return fmt.Errorf("interview worker: %w", err)
	}
	ticker := time.NewTicker(worker.pollEvery)
	defer ticker.Stop()
	for {
		evaluated, err := worker.EvaluateOnce(ctx)
		if err != nil && !errors.Is(err, context.Canceled) {
			worker.logger.Error("interview code evaluation failed", "error", err)
		}
		if evaluated {
			continue
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

// EvaluateOnce claims and evaluates a single submission. It reports whether any
// work was done so the caller can decide between looping and waiting.
func (worker *Worker) EvaluateOnce(ctx context.Context) (bool, error) {
	var claims []Claim
	if err := worker.call(ctx, "claim_interview_code_submissions", map[string]any{
		"p_worker_id":     worker.workerID,
		"p_lease_seconds": 300,
	}, &claims); err != nil {
		return false, err
	}
	if len(claims) == 0 {
		return false, nil
	}
	claim := claims[0]

	outcomes, passed, total, points, passedPoints, err := worker.evaluate(ctx, claim)
	if err != nil {
		worker.logger.Error(
			"interview submission could not be executed",
			"submission_id", claim.SubmissionID,
			"error", err,
		)
		return true, worker.complete(ctx, claim, "failed", nil, 0, 0, nil, "runner_unavailable")
	}

	score := 0.0
	if total > 0 {
		score = roundScore(passedPoints / points * 100)
	}
	worker.logger.Info(
		"interview submission evaluated",
		"submission_id", claim.SubmissionID,
		"language", claim.Language,
		"passed", passed,
		"total", total,
		"score", score,
	)
	return true, worker.complete(ctx, claim, "completed", &score, passed, total, outcomes, "")
}

func (worker *Worker) evaluate(
	ctx context.Context,
	claim Claim,
) ([]TestOutcome, int, int, float64, float64, error) {
	if len(claim.Tests) == 0 {
		return nil, 0, 0, 0, 0, errors.New("challenge has no test cases")
	}
	timeLimit := time.Duration(claim.MaxExecutionSeconds) * time.Second
	if timeLimit <= 0 {
		timeLimit = 10 * time.Second
	}

	outcomes := make([]TestOutcome, 0, len(claim.Tests))
	passed := 0
	total := 0
	points := 0.0
	passedPoints := 0.0

	for _, testCase := range claim.Tests {
		if err := ctx.Err(); err != nil {
			return outcomes, passed, total, points, passedPoints, err
		}
		total++
		weight := testCase.Points
		if weight <= 0 {
			weight = 1
		}
		points += weight

		result, err := worker.executor.Run(ctx, runner.Request{
			Language:  claim.Language,
			Source:    claim.Source,
			Stdin:     testCase.InputText,
			TimeLimit: timeLimit,
		})
		if err != nil && !errors.Is(err, runner.ErrUnsupportedLanguage) &&
			!errors.Is(err, runner.ErrOutputTooLarge) {
			return outcomes, passed, total, points, passedPoints, err
		}

		status := outcomeStatus(result, err)
		if runner.IsSuccessful(result, testCase.ExpectedOutput, normalizationError(err)) {
			status = "passed"
			passed++
			passedPoints += weight
		}

		outcomes = append(outcomes, TestOutcome{
			DisplayOrder: testCase.DisplayOrder,
			Status:       status,
			DurationMS:   result.Duration.Milliseconds(),
			Stderr:       truncate(result.Stderr, 500),
		})
	}
	return outcomes, passed, total, points, passedPoints, nil
}

func outcomeStatus(result runner.Result, err error) string {
	switch {
	case errors.Is(err, runner.ErrUnsupportedLanguage):
		return "unsupported_language"
	case errors.Is(err, runner.ErrOutputTooLarge):
		return "output_limit"
	case result.TimedOut:
		return "timeout"
	case result.ExitCode != 0:
		return "runtime_error"
	default:
		return "wrong_answer"
	}
}

// normalizationError keeps ErrOutputTooLarge from being treated as a pass: the
// program produced too much output, so the comparison is meaningless.
func normalizationError(err error) error {
	if errors.Is(err, runner.ErrOutputTooLarge) {
		return err
	}
	return nil
}

func (worker *Worker) complete(
	ctx context.Context,
	claim Claim,
	status string,
	score *float64,
	passed int,
	total int,
	outcomes []TestOutcome,
	errorCode string,
) error {
	results, err := json.Marshal(outcomes)
	if err != nil {
		results = []byte("[]")
	}
	payload := map[string]any{
		"p_submission_id": claim.SubmissionID,
		"p_lease_token":   claim.LeaseToken,
		"p_status":        status,
		"p_score":         nil,
		"p_passed_tests":  passed,
		"p_total_tests":   total,
		"p_results":       json.RawMessage(results),
		"p_error_code":    nil,
	}
	if score != nil {
		payload["p_score"] = *score
	}
	if errorCode != "" {
		payload["p_error_code"] = errorCode
	}
	return worker.call(ctx, "complete_interview_code_submission", payload, nil)
}

func (worker *Worker) call(ctx context.Context, function string, payload any, result any) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return errors.New("could not prepare an interview evaluation request")
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		worker.baseURL+"/rest/v1/rpc/"+function,
		bytes.NewReader(body),
	)
	if err != nil {
		return errors.New("could not create an interview evaluation request")
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("apikey", worker.serviceKey)
	if worker.credential == config.SupabaseServiceRoleCredential {
		request.Header.Set("Authorization", "Bearer "+worker.serviceKey)
	}
	response, err := worker.httpClient.Do(request)
	if err != nil {
		return errors.New("Supabase interview evaluation service is unavailable")
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("Supabase interview evaluation request failed: %s", truncate(string(responseBody), 300))
	}
	if result == nil || len(responseBody) == 0 || string(responseBody) == "null" {
		return nil
	}
	if err := json.Unmarshal(responseBody, result); err != nil {
		return errors.New("Supabase returned an invalid interview evaluation response")
	}
	return nil
}

func roundScore(value float64) float64 {
	rounded := float64(int(value*100+0.5)) / 100
	if rounded < 0 {
		return 0
	}
	if rounded > 100 {
		return 100
	}
	return rounded
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit]
}

func randomWorkerID() string {
	var data [8]byte
	if _, err := rand.Read(data[:]); err == nil {
		return hex.EncodeToString(data[:])
	}
	return strings.ReplaceAll(time.Now().UTC().Format("150405.000000000"), ".", "")
}
