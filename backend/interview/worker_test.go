package interview

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rishi1930/proofhire/backend/config"
	"github.com/rishi1930/proofhire/backend/runner"
)

type fakeExecutor struct {
	outputs map[string]runner.Result
	calls   int
	err     error
}

func (executor *fakeExecutor) Available(context.Context) error { return nil }

func (executor *fakeExecutor) Run(
	_ context.Context,
	request runner.Request,
) (runner.Result, error) {
	executor.calls++
	if executor.err != nil {
		return runner.Result{}, executor.err
	}
	if result, ok := executor.outputs[request.Stdin]; ok {
		return result, nil
	}
	return runner.Result{Stdout: "unexpected\n", ExitCode: 1}, nil
}

func newTestWorker(t *testing.T, executor Executor, handler http.HandlerFunc) (*Worker, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	worker, err := NewWorker(config.Config{
		SupabaseURL:       server.URL,
		SupabaseSecretKey: "sb_secret_test_key",
	}, executor, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatalf("worker: %v", err)
	}
	return worker, server
}

func TestEvaluateOnceScoresPassedTests(t *testing.T) {
	var (
		mutex    sync.Mutex
		complete map[string]any
	)
	executor := &fakeExecutor{outputs: map[string]runner.Result{
		"2 3\n": {Stdout: "5\n"},
		"4 6\n": {Stdout: "11\n", ExitCode: 1},
	}}
	worker, _ := newTestWorker(t, executor, func(writer http.ResponseWriter, request *http.Request) {
		switch {
		case strings.HasSuffix(request.URL.Path, "/claim_interview_code_submissions"):
			_, _ = writer.Write([]byte(`[{
				"submission_id":"11111111-1111-1111-1111-111111111111",
				"lease_token":"22222222-2222-2222-2222-222222222222",
				"workspace_id":"33333333-3333-3333-3333-333333333333",
				"session_id":"44444444-4444-4444-4444-444444444444",
				"challenge_version_id":"55555555-5555-5555-5555-555555555555",
				"language":"python",
				"source":"print(sum(map(int, input().split())))",
				"max_execution_seconds":5,
				"tests":[
					{"display_order":1,"input_text":"2 3\n","expected_output":"5\n","points":2},
					{"display_order":2,"input_text":"4 6\n","expected_output":"10\n","points":1}
				]
			}]`))
		case strings.HasSuffix(request.URL.Path, "/complete_interview_code_submission"):
			body, _ := io.ReadAll(request.Body)
			var payload map[string]any
			if err := json.Unmarshal(body, &payload); err != nil {
				t.Errorf("invalid completion payload: %v", err)
			}
			mutex.Lock()
			complete = payload
			mutex.Unlock()
			_, _ = writer.Write([]byte(`null`))
		default:
			t.Errorf("unexpected request: %s", request.URL.Path)
		}
	})

	evaluated, err := worker.EvaluateOnce(context.Background())
	if err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	if !evaluated {
		t.Fatal("expected one submission to be evaluated")
	}
	if executor.calls != 2 {
		t.Fatalf("executor calls = %d, want 2", executor.calls)
	}

	mutex.Lock()
	defer mutex.Unlock()
	if complete == nil {
		t.Fatal("completion RPC was not called")
	}
	if complete["p_status"] != "completed" {
		t.Errorf("status = %v", complete["p_status"])
	}
	if complete["p_passed_tests"] != float64(1) || complete["p_total_tests"] != float64(2) {
		t.Errorf("test counts = %v/%v", complete["p_passed_tests"], complete["p_total_tests"])
	}
	// One of three points passed, weighted by the per-test points.
	if complete["p_score"] != float64(66.67) {
		t.Errorf("score = %v, want 66.67", complete["p_score"])
	}
	if complete["p_lease_token"] != "22222222-2222-2222-2222-222222222222" {
		t.Errorf("lease token = %v", complete["p_lease_token"])
	}
}

func TestEvaluateOnceReportsRunnerFailure(t *testing.T) {
	var complete map[string]any
	worker, _ := newTestWorker(t, &fakeExecutor{err: context.DeadlineExceeded},
		func(writer http.ResponseWriter, request *http.Request) {
			if strings.HasSuffix(request.URL.Path, "/claim_interview_code_submissions") {
				_, _ = writer.Write([]byte(`[{
					"submission_id":"11111111-1111-1111-1111-111111111111",
					"lease_token":"22222222-2222-2222-2222-222222222222",
					"language":"python","source":"print(1)",
					"max_execution_seconds":5,
					"tests":[{"display_order":1,"input_text":"","expected_output":"1\n","points":1}]
				}]`))
				return
			}
			body, _ := io.ReadAll(request.Body)
			_ = json.Unmarshal(body, &complete)
			_, _ = writer.Write([]byte(`null`))
		})

	evaluated, err := worker.EvaluateOnce(context.Background())
	if err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	if !evaluated {
		t.Fatal("expected an evaluation attempt")
	}
	if complete["p_status"] != "failed" || complete["p_error_code"] != "runner_unavailable" {
		t.Fatalf("unexpected completion: %v", complete)
	}
	if complete["p_score"] != nil {
		t.Fatalf("failed submission must not carry a score: %v", complete["p_score"])
	}
}

func TestEvaluateOnceDoesNothingWhenQueueIsEmpty(t *testing.T) {
	worker, _ := newTestWorker(t, &fakeExecutor{}, func(writer http.ResponseWriter, request *http.Request) {
		_, _ = writer.Write([]byte(`[]`))
	})
	evaluated, err := worker.EvaluateOnce(context.Background())
	if err != nil {
		t.Fatalf("evaluate: %v", err)
	}
	if evaluated {
		t.Fatal("expected no work")
	}
}

func TestWorkerRejectsMissingPrivilegedCredential(t *testing.T) {
	_, err := NewWorker(config.Config{SupabaseURL: "https://example.supabase.co"}, &fakeExecutor{},
		slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err == nil {
		t.Fatal("expected a credential error")
	}
}

func TestRoundScore(t *testing.T) {
	if got := roundScore(66.666666); got != 66.67 {
		t.Fatalf("roundScore = %v", got)
	}
	if got := roundScore(-5); got != 0 {
		t.Fatalf("negative score = %v", got)
	}
	if got := roundScore(120); got != 100 {
		t.Fatalf("score above 100 = %v", got)
	}
}

func TestEvaluateHonoursContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	worker, _ := newTestWorker(t, &fakeExecutor{}, func(writer http.ResponseWriter, request *http.Request) {
		_, _ = writer.Write([]byte(`[{
			"submission_id":"11111111-1111-1111-1111-111111111111",
			"lease_token":"22222222-2222-2222-2222-222222222222",
			"language":"python","source":"print(1)","max_execution_seconds":5,
			"tests":[{"display_order":1,"input_text":"","expected_output":"1\n","points":1}]
		}]`))
	})
	started := time.Now()
	if _, err := worker.EvaluateOnce(ctx); err == nil {
		t.Fatal("expected the cancelled context to surface")
	}
	if time.Since(started) > 5*time.Second {
		t.Fatal("cancelled evaluation should return promptly")
	}
}
