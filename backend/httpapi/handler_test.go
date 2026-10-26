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
