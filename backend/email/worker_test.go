package email

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
)

type recordingSender struct {
	mu       sync.Mutex
	messages []Message
	failWith error
}

func (sender *recordingSender) Send(_ context.Context, message Message) (Accepted, error) {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	if sender.failWith != nil {
		return Accepted{}, sender.failWith
	}
	sender.messages = append(sender.messages, message)
	return Accepted{MessageID: "test-provider-message"}, nil
}

func (sender *recordingSender) sent() []Message {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	return append([]Message(nil), sender.messages...)
}

type recordedFailure struct {
	code      string
	retryable bool
}

// fakeDeliveryAPI stands in for the Supabase RPCs the worker calls.
type fakeDeliveryAPI struct {
	mu           sync.Mutex
	jobs         []map[string]any
	context      map[string]any
	completed    []string
	failures     []recordedFailure
	claimCalls   int
	contextCalls int
	apiKeys      []string
}

func (api *fakeDeliveryAPI) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/rest/v1/rpc/claim_email_delivery_jobs", func(w http.ResponseWriter, r *http.Request) {
		api.noteAPIKey(r)
		api.mu.Lock()
		api.claimCalls++
		jobs := api.jobs
		api.mu.Unlock()
		emailTestWriteJSON(w, jobs)
	})
	mux.HandleFunc("/rest/v1/rpc/get_email_delivery_context", func(w http.ResponseWriter, r *http.Request) {
		api.noteAPIKey(r)
		api.mu.Lock()
		api.contextCalls++
		payload := api.context
		api.mu.Unlock()
		emailTestWriteJSON(w, payload)
	})
	mux.HandleFunc("/rest/v1/rpc/complete_email_delivery_job", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			TargetJobID string `json:"target_job_id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		api.mu.Lock()
		api.completed = append(api.completed, body.TargetJobID)
		api.mu.Unlock()
		emailTestWriteJSON(w, "sent")
	})
	mux.HandleFunc("/rest/v1/rpc/fail_email_delivery_job", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			TargetErrorCode string `json:"target_error_code"`
			Retryable       bool   `json:"retryable"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		api.mu.Lock()
		api.failures = append(api.failures, recordedFailure{
			code:      body.TargetErrorCode,
			retryable: body.Retryable,
		})
		api.mu.Unlock()
		emailTestWriteJSON(w, "failed")
	})
	return mux
}

func (api *fakeDeliveryAPI) noteAPIKey(request *http.Request) {
	api.mu.Lock()
	defer api.mu.Unlock()
	api.apiKeys = append(api.apiKeys, request.Header.Get("apikey"))
}

func emailTestWriteJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

func emailTestWorker(t *testing.T, api *fakeDeliveryAPI, sender Sender, appBaseURL string) *Worker {
	t.Helper()
	server := httptest.NewServer(api.handler())
	t.Cleanup(server.Close)
	return &Worker{
		baseURL:    server.URL,
		serviceKey: "test-privileged-key",
		provider:   sender,
		httpClient: server.Client(),
		logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		workerID:   "test-worker",
		pollEvery:  time.Second,
		appBaseURL: appBaseURL,
	}
}

func emailTestJob(emailType string) map[string]any {
	return map[string]any{
		"id":              "11111111-1111-1111-1111-111111111111",
		"email_type":      emailType,
		"recipient_email": "candidate@example.com",
		"idempotency_key": "interview-invitation:1",
		"lease_token":     "22222222-2222-2222-2222-222222222222",
	}
}

func interviewInvitationContext(path string) map[string]any {
	return map[string]any{
		"candidate_name":   "Asha Rao",
		"job_title":        "Backend Engineer",
		"company_name":     "Northwind Labs",
		"interview_type":   "Technical interview",
		"duration_seconds": 4800,
		"interview_path":   path,
	}
}

func TestEmailWorkerDeliversInterviewInvitation(t *testing.T) {
	api := &fakeDeliveryAPI{
		jobs:    []map[string]any{emailTestJob("interview_invitation")},
		context: interviewInvitationContext("/interview/token-abc123"),
	}
	sender := &recordingSender{}
	worker := emailTestWorker(t, api, sender, "https://proofhire.example")

	if err := worker.deliverOne(context.Background()); err != nil {
		t.Fatalf("deliverOne returned an error: %v", err)
	}

	messages := sender.sent()
	if len(messages) != 1 {
		t.Fatalf("expected one delivered message, got %d", len(messages))
	}
	message := messages[0]
	if message.To != "candidate@example.com" {
		t.Fatalf("unexpected recipient: %q", message.To)
	}
	if message.Subject != "Your interview invitation for Backend Engineer" {
		t.Fatalf("unexpected subject: %q", message.Subject)
	}
	const link = "https://proofhire.example/interview/token-abc123"
	for _, body := range []string{message.Text, message.HTML} {
		if !strings.Contains(body, link) {
			t.Fatalf("message body does not contain the interview link: %q", body)
		}
	}
	if !strings.Contains(message.Text, "Asha Rao") || !strings.Contains(message.Text, "Northwind Labs") {
		t.Fatalf("message body is missing candidate or company details: %q", message.Text)
	}
	if !strings.Contains(message.Text, "Technical interview") {
		t.Fatalf("message body is missing the interview type: %q", message.Text)
	}
	if len(api.completed) != 1 || api.completed[0] != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("expected the delivery to be completed, got %v", api.completed)
	}
	if len(api.failures) != 0 {
		t.Fatalf("expected no recorded failures, got %v", api.failures)
	}
	for _, key := range api.apiKeys {
		if key != "test-privileged-key" {
			t.Fatalf("worker did not send its privileged key: %q", key)
		}
	}
}

func TestEmailWorkerRequiresAppBaseURLForInterviewInvitation(t *testing.T) {
	api := &fakeDeliveryAPI{
		jobs:    []map[string]any{emailTestJob("interview_invitation")},
		context: interviewInvitationContext("/interview/token-abc123"),
	}
	sender := &recordingSender{}
	worker := emailTestWorker(t, api, sender, "")

	if err := worker.deliverOne(context.Background()); err != nil {
		t.Fatalf("deliverOne returned an error: %v", err)
	}

	if sent := sender.sent(); len(sent) != 0 {
		t.Fatalf("expected no email without APP_BASE_URL, got %d", len(sent))
	}
	if len(api.completed) != 0 {
		t.Fatalf("expected no completion, got %v", api.completed)
	}
	if len(api.failures) != 1 {
		t.Fatalf("expected one recorded failure, got %v", api.failures)
	}
	failure := api.failures[0]
	if failure.code != "email_context_unavailable" {
		t.Fatalf("unexpected failure code: %q", failure.code)
	}
	if !failure.retryable {
		t.Fatal("a missing APP_BASE_URL is configuration, so the job must stay retryable")
	}
}

func TestEmailWorkerRequiresInterviewLinkPath(t *testing.T) {
	api := &fakeDeliveryAPI{
		jobs:    []map[string]any{emailTestJob("interview_invitation")},
		context: interviewInvitationContext("   "),
	}
	sender := &recordingSender{}
	worker := emailTestWorker(t, api, sender, "https://proofhire.example")

	if err := worker.deliverOne(context.Background()); err != nil {
		t.Fatalf("deliverOne returned an error: %v", err)
	}

	if sent := sender.sent(); len(sent) != 0 {
		t.Fatalf("expected no email without a link path, got %d", len(sent))
	}
	if api.contextCalls != 1 {
		t.Fatalf("expected the context to be read once, got %d", api.contextCalls)
	}
	if len(api.completed) != 0 {
		t.Fatalf("expected no completion, got %v", api.completed)
	}
	if len(api.failures) != 1 {
		t.Fatalf("expected one recorded failure, got %v", api.failures)
	}
	failure := api.failures[0]
	if failure.code != "email_context_unavailable" {
		t.Fatalf("unexpected failure code: %q", failure.code)
	}
	if !failure.retryable {
		t.Fatal("a missing link path must stay retryable while the queue is fixed")
	}
}

func TestEmailWorkerRejectsUnsupportedEmailType(t *testing.T) {
	api := &fakeDeliveryAPI{
		jobs:    []map[string]any{emailTestJob("offer")},
		context: interviewInvitationContext("/interview/unused"),
	}
	sender := &recordingSender{}
	worker := emailTestWorker(t, api, sender, "https://proofhire.example")

	if err := worker.deliverOne(context.Background()); err != nil {
		t.Fatalf("deliverOne returned an error: %v", err)
	}

	if sent := sender.sent(); len(sent) != 0 {
		t.Fatalf("expected no email for an unsupported type, got %d", len(sent))
	}
	if api.contextCalls != 0 {
		t.Fatalf("unsupported types must not read context, got %d reads", api.contextCalls)
	}
	if len(api.failures) != 1 {
		t.Fatalf("expected one recorded failure, got %v", api.failures)
	}
	if api.failures[0].code != "unsupported_email_type" {
		t.Fatalf("unexpected failure code: %q", api.failures[0].code)
	}
	if api.failures[0].retryable {
		t.Fatal("an unsupported type is not fixable by retrying, so it must not be retryable")
	}
}
