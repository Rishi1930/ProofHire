package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/rishi1930/proofhire/backend/aptitude"
	"github.com/rishi1930/proofhire/backend/supabaseauth"
)

type verifierFunc func(context.Context, string) (supabaseauth.User, error)

func (function verifierFunc) VerifyAccessToken(
	ctx context.Context,
	token string,
) (supabaseauth.User, error) {
	return function(ctx, token)
}

func (verifierFunc) GetWorkspaceRole(
	context.Context,
	string,
	string,
	string,
) (string, error) {
	return "recruiter", nil
}

type fakeAptitudeService struct {
	candidateSession json.RawMessage
	createdInput     aptitude.InvitationInput
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

func (service *fakeAptitudeService) CreateInvitation(
	_ context.Context,
	input aptitude.InvitationInput,
) (aptitude.Invitation, string, error) {
	service.createdInput = input
	return aptitude.Invitation{
		ID:             "12345678-1234-1234-1234-123456789abc",
		CandidateEmail: "candidate@example.test",
		TestTitle:      "Test",
	}, "candidate-link-token-abcdefghijklmnopqrstuvwxyz123", nil
}

func (service *fakeAptitudeService) CandidateSession(
	context.Context,
	string,
) (json.RawMessage, error) {
	return service.candidateSession, nil
}

func (*fakeAptitudeService) StartAttempt(context.Context, string) (json.RawMessage, error) {
	return json.RawMessage(`{"attempt_id":"12345678-1234-1234-1234-123456789abc"}`), nil
}

func (*fakeAptitudeService) SaveAnswer(
	context.Context,
	string,
	string,
	string,
	json.RawMessage,
) error {
	return nil
}

func (*fakeAptitudeService) SaveProgress(
	context.Context,
	string,
	string,
	string,
	int,
	json.RawMessage,
) error {
	return nil
}

func (*fakeAptitudeService) SubmitAttempt(context.Context, string, string) (json.RawMessage, error) {
	return json.RawMessage(`{"status":"submitted","score":100}`), nil
}

func (*fakeAptitudeService) RecordEvent(context.Context, string, string, string, json.RawMessage) error {
	return nil
}

func TestHealth(t *testing.T) {
	handler := NewHandler(verifierFunc(func(context.Context, string) (supabaseauth.User, error) {
		t.Fatal("health endpoint must not verify an access token")
		return supabaseauth.User{}, nil
	}), slog.New(slog.NewTextHandler(io.Discard, nil)))

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/health", nil))

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if response.Header().Get("X-Request-ID") == "" {
		t.Fatal("expected request ID header")
	}
}

func TestCreateAptitudeInvitationRequiresAuthorizedRecruiter(t *testing.T) {
	const userID = "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae"
	service := &fakeAptitudeService{}
	handler := NewHandlerWithAptitude(
		verifierFunc(func(_ context.Context, token string) (supabaseauth.User, error) {
			if token != "access-token" {
				t.Fatal("unexpected access token")
			}
			return supabaseauth.User{ID: userID}, nil
		}),
		service,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	body := `{"workspace_id":"82ef1fb1-47c7-4c5e-8118-e78d33b58e1d","application_id":"9ba0fef4-10e6-41f0-81aa-7ec52a7f9e77","test_version_id":"1bfeb683-e931-4ce0-a555-f70f976f4a19","expires_at":"2030-01-01T00:00:00Z","max_attempts":1}`
	request := httptest.NewRequest(http.MethodPost, "/api/v1/aptitude/invitations", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer access-token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d; body: %s", response.Code, http.StatusCreated, response.Body)
	}
	if service.createdInput.UserID != userID ||
		service.createdInput.ApplicationID != "9ba0fef4-10e6-41f0-81aa-7ec52a7f9e77" {
		t.Fatal("authenticated recruiter identity and invitation request were not forwarded")
	}
	if !strings.Contains(response.Body.String(), "candidate-link-token-abcdefghijklmnopqrstuvwxyz123") ||
		!strings.Contains(response.Body.String(), `"delivery":"queued"`) {
		t.Fatal("creator response should contain the one-time token and queued-delivery notice")
	}
}

func TestCandidateAptitudeSessionIsPublicAndUncached(t *testing.T) {
	service := &fakeAptitudeService{
		candidateSession: json.RawMessage(`{"title":"Test","questions":[]}`),
	}

	handler := NewHandlerWithAptitude(
		verifierFunc(func(context.Context, string) (supabaseauth.User, error) {
			t.Fatal("candidate test sessions do not use recruiter authentication")
			return supabaseauth.User{}, nil
		}),
		service,
		slog.New(slog.NewTextHandler(io.Discard, nil)),
	)
	request := httptest.NewRequest(
		http.MethodPost,
		"/api/v1/aptitude/candidate/session",
		strings.NewReader(`{"token":"Abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"}`),
	)
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK ||
		response.Header().Get("Cache-Control") != "no-store" ||
		response.Body.String() != `{"title":"Test","questions":[]}`+"\n" {
		t.Fatalf("unexpected candidate session response: %d %q", response.Code, response.Body.String())
	}
}

func TestCurrentUserRequiresAndVerifiesBearerToken(t *testing.T) {
	const userID = "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae"
	handler := NewHandler(verifierFunc(func(_ context.Context, token string) (supabaseauth.User, error) {
		if token != "valid-token" {
			t.Fatalf("token = %q", token)
		}
		return supabaseauth.User{ID: userID}, nil
	}), slog.New(slog.NewTextHandler(io.Discard, nil)))

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(
		unauthorized,
		httptest.NewRequest(http.MethodGet, "/api/v1/me", nil),
	)
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status = %d", unauthorized.Code)
	}

	request := httptest.NewRequest(http.MethodGet, "/api/v1/me", nil)
	request.Header.Set("Authorization", "Bearer valid-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body: %s", response.Code, http.StatusOK, response.Body)
	}
	var user map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &user); err != nil {
		t.Fatalf("response is not JSON: %v", err)
	}
	if user["id"] != userID {
		t.Fatalf("user ID = %q, want %q", user["id"], userID)
	}
	if strings.Contains(response.Body.String(), "valid-token") {
		t.Fatal("response must not expose the access token")
	}
}

func TestCurrentUserHidesProviderErrors(t *testing.T) {
	handler := NewHandler(verifierFunc(func(context.Context, string) (supabaseauth.User, error) {
		return supabaseauth.User{}, errors.New("provider response includes private details")
	}), slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodGet, "/api/v1/me", nil)
	request.Header.Set("Authorization", "Bearer valid-token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusBadGateway)
	}
	if strings.Contains(response.Body.String(), "private details") {
		t.Fatal("response must not expose upstream error details")
	}
}

func TestCurrentUserRejectsExpiredToken(t *testing.T) {
	handler := NewHandler(verifierFunc(func(context.Context, string) (supabaseauth.User, error) {
		return supabaseauth.User{}, supabaseauth.ErrUnauthenticated
	}), slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodGet, "/api/v1/me", nil)
	request.Header.Set("Authorization", "Bearer expired-token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusUnauthorized)
	}
}

func TestWorkspaceAccessReturnsRoleForVerifiedMember(t *testing.T) {
	const (
		userID      = "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae"
		workspaceID = "82ef1fb1-47c7-4c5e-8118-e78d33b58e1d"
	)
	handler := NewHandler(verifierFunc(func(_ context.Context, token string) (supabaseauth.User, error) {
		if token != "valid-token" {
			t.Fatalf("token = %q", token)
		}
		return supabaseauth.User{ID: userID}, nil
	}), slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(
		http.MethodGet,
		"/api/v1/workspace-access?workspace_id="+workspaceID,
		nil,
	)
	request.Header.Set("Authorization", "Bearer valid-token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d; body: %s", response.Code, http.StatusOK, response.Body)
	}
	var result map[string]string
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil {
		t.Fatalf("response is not JSON: %v", err)
	}
	if result["workspace_id"] != workspaceID || result["role"] != "recruiter" {
		t.Fatalf("unexpected workspace response: %v", result)
	}
}

func TestWorkspaceAccessRequiresSingleWorkspaceID(t *testing.T) {
	handler := NewHandler(verifierFunc(func(context.Context, string) (supabaseauth.User, error) {
		t.Fatal("invalid workspace query must be rejected before authentication")
		return supabaseauth.User{}, nil
	}), slog.New(slog.NewTextHandler(io.Discard, nil)))
	request := httptest.NewRequest(http.MethodGet, "/api/v1/workspace-access", nil)
	request.Header.Set("Authorization", "Bearer valid-token")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, request)

	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusBadRequest)
	}
}
