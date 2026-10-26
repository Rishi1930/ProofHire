package supabaseauth

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/rishi1930/proofhire/backend/config"
)

func TestVerifyAccessToken(t *testing.T) {
	const userID = "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae"
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/auth/v1/user" {
			t.Errorf("request path = %q", request.URL.Path)
		}
		if request.Header.Get("apikey") != "public-key" {
			t.Errorf("unexpected apikey header")
		}
		if request.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("unexpected authorization header")
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"id":"` + userID + `"}`))
	}))
	defer server.Close()

	client := NewClient(config.Config{
		SupabaseURL:     server.URL,
		SupabaseAnonKey: "public-key",
	})
	user, err := client.VerifyAccessToken(context.Background(), "test-token")
	if err != nil {
		t.Fatalf("VerifyAccessToken() error = %v", err)
	}
	if user.ID != userID {
		t.Fatalf("VerifyAccessToken() ID = %q, want %q", user.ID, userID)
	}
}

func TestVerifyAccessTokenMapsUpstreamErrors(t *testing.T) {
	tests := []struct {
		name       string
		statusCode int
		wantError  error
	}{
		{name: "expired token", statusCode: http.StatusUnauthorized, wantError: ErrUnauthenticated},
		{name: "provider failure", statusCode: http.StatusBadGateway, wantError: ErrUnavailable},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(
				writer http.ResponseWriter,
				_ *http.Request,
			) {
				writer.WriteHeader(test.statusCode)
				_, _ = writer.Write([]byte(`{"message":"private provider details"}`))
			}))
			defer server.Close()

			client := NewClient(config.Config{
				SupabaseURL:     server.URL,
				SupabaseAnonKey: "public-key",
			})
			_, err := client.VerifyAccessToken(context.Background(), "test-token")
			if !errors.Is(err, test.wantError) {
				t.Fatalf("VerifyAccessToken() error = %v, want %v", err, test.wantError)
			}
			if err != test.wantError {
				t.Fatalf("VerifyAccessToken() exposed a provider error: %v", err)
			}
		})
	}
}

func TestGetWorkspaceRoleUsesCallerTokenAndWorkspaceFilters(t *testing.T) {
	const (
		userID      = "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae"
		workspaceID = "82ef1fb1-47c7-4c5e-8118-e78d33b58e1d"
	)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/rest/v1/workspace_members" {
			t.Errorf("request path = %q", request.URL.Path)
		}
		if request.URL.Query().Get("user_id") != "eq."+userID {
			t.Errorf("user_id filter = %q", request.URL.Query().Get("user_id"))
		}
		if request.URL.Query().Get("workspace_id") != "eq."+workspaceID {
			t.Errorf("workspace_id filter = %q", request.URL.Query().Get("workspace_id"))
		}
		if request.Header.Get("Authorization") != "Bearer caller-token" {
			t.Error("membership query must use the caller's token")
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`[{"role":"recruiter"}]`))
	}))
	defer server.Close()

	client := NewClient(config.Config{
		SupabaseURL:     server.URL,
		SupabaseAnonKey: "public-key",
	})
	role, err := client.GetWorkspaceRole(context.Background(), "caller-token", userID, workspaceID)
	if err != nil {
		t.Fatalf("GetWorkspaceRole() error = %v", err)
	}
	if role != "recruiter" {
		t.Fatalf("role = %q, want recruiter", role)
	}
}

func TestGetWorkspaceRoleRejectsMissingMembership(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`[]`))
	}))
	defer server.Close()

	client := NewClient(config.Config{
		SupabaseURL:     server.URL,
		SupabaseAnonKey: "public-key",
	})
	_, err := client.GetWorkspaceRole(
		context.Background(),
		"caller-token",
		"f3d2f2c1-f597-4a72-8e7d-8dfe814662ae",
		"82ef1fb1-47c7-4c5e-8118-e78d33b58e1d",
	)
	if !errors.Is(err, ErrForbidden) {
		t.Fatalf("GetWorkspaceRole() error = %v, want ErrForbidden", err)
	}
}

func TestGetWorkspaceRoleRejectsInvalidIDsBeforeNetworkRequest(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("invalid IDs must not cause a request")
	}))
	defer server.Close()

	client := NewClient(config.Config{
		SupabaseURL:     server.URL,
		SupabaseAnonKey: "public-key",
	})
	_, err := client.GetWorkspaceRole(context.Background(), "caller-token", "bad-id", "bad-id")
	if !errors.Is(err, ErrForbidden) {
		t.Fatalf("GetWorkspaceRole() error = %v, want ErrForbidden", err)
	}
}
