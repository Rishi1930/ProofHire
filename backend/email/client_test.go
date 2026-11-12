package email

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestResendSendIncludesIdempotencyAndBothBodies(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/emails" {
			t.Fatalf("unexpected request: %s %s", request.Method, request.URL.Path)
		}
		if request.Header.Get("Authorization") != "Bearer test-key" {
			t.Fatal("provider authorization header was not set")
		}
		if request.Header.Get("Idempotency-Key") != "screening-result:123" {
			t.Fatal("provider idempotency key was not set")
		}
		var payload struct {
			From    string   `json:"from"`
			To      []string `json:"to"`
			Subject string   `json:"subject"`
			HTML    string   `json:"html"`
			Text    string   `json:"text"`
		}
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		if payload.From != "ProofHire <hiring@example.com>" ||
			len(payload.To) != 1 || payload.To[0] != "candidate@example.com" ||
			payload.Subject == "" || payload.HTML == "" || payload.Text == "" {
			t.Fatalf("unexpected provider payload: %#v", payload)
		}
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write([]byte(`{"id":"resend-message-1"}`))
	}))
	defer server.Close()

	provider, err := NewClient(
		"test-key",
		"ProofHire <hiring@example.com>",
		WithHTTPClient(server.Client()),
		WithEndpoint(server.URL+"/emails"),
	)
	if err != nil {
		t.Fatal(err)
	}
	accepted, err := provider.Send(context.Background(), Message{
		To:             "candidate@example.com",
		Subject:        "An invitation",
		HTML:           "<p>Hello</p>",
		Text:           "Hello",
		IdempotencyKey: "screening-result:123",
	})
	if err != nil {
		t.Fatal(err)
	}
	if accepted.MessageID != "resend-message-1" {
		t.Fatalf("unexpected provider message ID: %q", accepted.MessageID)
	}
}

func TestResendSendClassifiesProviderFailures(t *testing.T) {
	for _, testCase := range []struct {
		name        string
		status      int
		retryable   bool
		providerErr string
	}{
		{name: "rate limited", status: http.StatusTooManyRequests, retryable: true, providerErr: "rate_limit_exceeded"},
		{name: "bad request", status: http.StatusBadRequest, retryable: false, providerErr: "validation_error"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
				writer.WriteHeader(testCase.status)
				_, _ = writer.Write([]byte(`{"name":"` + testCase.providerErr + `"}`))
			}))
			defer server.Close()
			provider, err := NewClient(
				"test-key",
				"sender@example.com",
				WithHTTPClient(server.Client()),
				WithEndpoint(server.URL),
			)
			if err != nil {
				t.Fatal(err)
			}
			_, err = provider.Send(context.Background(), Message{
				To: "candidate@example.com", Subject: "Test", HTML: "<p>Test</p>",
				Text: "Test", IdempotencyKey: "idempotency-key",
			})
			var deliveryError *DeliveryError
			if !errors.As(err, &deliveryError) {
				t.Fatalf("expected DeliveryError, got %v", err)
			}
			if deliveryError.Retryable != testCase.retryable ||
				deliveryError.Code == "" {
				t.Fatalf("unexpected failure classification: %#v", deliveryError)
			}
		})
	}
}

func TestResendSendRejectsInvalidMessage(t *testing.T) {
	provider, err := NewClient("test-key", "sender@example.com")
	if err != nil {
		t.Fatal(err)
	}
	_, err = provider.Send(context.Background(), Message{
		To:      "candidate@example.com\r\nBcc: other@example.com",
		Subject: "Test", HTML: "<p>Test</p>", Text: "Test",
		IdempotencyKey: "stable-key",
	})
	if err == nil {
		t.Fatal("expected invalid recipient to be rejected")
	}
}

func TestInterviewTemplateSupportsScheduledAndUnscheduledInvitations(t *testing.T) {
	input := InterviewInvitation{
		CandidateName: "Candidate",
		JobTitle:      "Designer",
		CompanyName:   "Example Co",
		InterviewType: "Video",
		InterviewURL:  "https://proofhire.example/interview/token",
	}
	rendered, err := RenderInterviewInvitation(input)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rendered.HTML, "Start Interview") ||
		strings.Contains(rendered.HTML, "Scheduled:") ||
		!strings.Contains(rendered.Text, "interview/token") {
		t.Fatal("unscheduled interview template is incorrect")
	}

	scheduled := mustTime(t, "2026-12-01T10:00:00Z")
	input.ScheduledAt = &scheduled
	input.Duration = 45 * time.Minute
	rendered, err = RenderInterviewInvitation(input)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(rendered.HTML, "45 minutes") ||
		!strings.Contains(rendered.HTML, "Scheduled:") {
		t.Fatal("scheduled interview details are missing")
	}
}

func mustTime(t *testing.T, value string) time.Time {
	t.Helper()
	parsed, err := time.Parse(time.RFC3339, value)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}
