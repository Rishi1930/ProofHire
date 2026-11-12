package httpapi

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/json"
	"encoding/base64"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/rishi1930/proofhire/backend/supabaseauth"
)

func TestEmailDeliveryActionRequiresRecruiterAndForwardsRequest(t *testing.T) {
	const userID = "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae"
	const workspaceID = "82ef1fb1-47c7-4c5e-8118-e78d33b58e1d"
	const jobID = "9ba0fef4-10e6-41f0-81aa-7ec52a7f9e77"
	const requestID = "1bfeb683-e931-4ce0-a555-f70f976f4a19"
	queue := &fakeEmailQueueService{}
	handler := NewHandlerWithIntegrations(
		verifierFunc(func(context.Context, string) (supabaseauth.User, error) {
			return supabaseauth.User{ID: userID}, nil
		}),
		queue,
		"",
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	request := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/email-delivery/"+jobID+"/action",
		strings.NewReader(`{"workspace_id":"`+workspaceID+`","action":"retry","request_id":"`+requestID+`"}`),
	)
	request.Header.Set("Authorization", "Bearer access-token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body: %s", response.Code, http.StatusOK, response.Body)
	}
	want := []string{userID, workspaceID, jobID, "retry", requestID}
	if len(queue.actionArgs) != len(want) {
		t.Fatalf("forwarded action args = %#v", queue.actionArgs)
	}
	for index := range want {
		if queue.actionArgs[index] != want[index] {
			t.Fatalf("forwarded action args = %#v, want %#v", queue.actionArgs, want)
		}
	}
}

func TestResendWebhookRecordsVerifiedDeliveryEvent(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	secretBytes := []byte("webhook-secret-for-test")
	secret := "whsec_" + base64.StdEncoding.EncodeToString(secretBytes)
	eventID := "event-123"
	timestamp := strconv.FormatInt(now.Unix(), 10)
	body := []byte(`{"type":"email.delivered","data":{"email_id":"provider-message-1"}}`)
	mac := hmac.New(sha256.New, secretBytes)
	_, _ = mac.Write([]byte(eventID + "." + timestamp + "." + string(body)))
	queue := &fakeEmailQueueService{}
	handler := NewHandlerWithIntegrations(
		verifierFunc(func(context.Context, string) (supabaseauth.User, error) {
			return supabaseauth.User{}, errors.New("authentication is not used")
		}),
		queue,
		secret,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	request := httptest.NewRequest(
		http.MethodPost,
		"/api/webhooks/resend",
		strings.NewReader(string(body)),
	)
	request.Header.Set("svix-id", eventID)
	request.Header.Set("svix-timestamp", timestamp)
	request.Header.Set(
		"svix-signature",
		"v1,"+base64.StdEncoding.EncodeToString(mac.Sum(nil)),
	)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want %d; body: %s", response.Code, http.StatusNoContent, response.Body)
	}
	if len(queue.eventArgs) != 2 || queue.eventArgs[0] != "provider-message-1" ||
		queue.eventArgs[1] != "email.delivered" {
		t.Fatalf("recorded event = %#v", queue.eventArgs)
	}
}

func TestResendWebhookRejectsInvalidSignature(t *testing.T) {
	queue := &fakeEmailQueueService{}
	handler := NewHandlerWithIntegrations(
		verifierFunc(func(context.Context, string) (supabaseauth.User, error) {
			return supabaseauth.User{}, errors.New("authentication is not used")
		}),
		queue,
		"whsec_"+base64.StdEncoding.EncodeToString([]byte("webhook-secret-for-test")),
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	request := httptest.NewRequest(
		http.MethodPost,
		"/api/webhooks/resend",
		strings.NewReader(`{"type":"email.delivered","data":{"email_id":"provider-message-1"}}`),
	)
	request.Header.Set("svix-id", "event-123")
	request.Header.Set("svix-timestamp", strconv.FormatInt(time.Now().Unix(), 10))
	request.Header.Set("svix-signature", "v1,invalid")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusUnauthorized || len(queue.eventArgs) != 0 {
		t.Fatalf("invalid webhook was not rejected: status=%d events=%#v", response.Code, queue.eventArgs)
	}
}

type fakeEmailQueueService struct {
	actionArgs []string
	eventArgs  []string
}

func (service *fakeEmailQueueService) RequestAction(
	_ context.Context,
	userID string,
	workspaceID string,
	jobID string,
	action string,
	requestID string,
) (json.RawMessage, error) {
	service.actionArgs = []string{userID, workspaceID, jobID, action, requestID}
	return json.RawMessage(`{"id":"job-id","status":"queued"}`), nil
}

func (service *fakeEmailQueueService) RecordProviderEvent(
	_ context.Context,
	messageID string,
	eventType string,
) error {
	service.eventArgs = []string{messageID, eventType}
	return nil
}
