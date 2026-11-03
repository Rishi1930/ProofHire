package aptitude

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rishi1930/proofhire/backend/config"
)

func TestCreateInvitationUsesServerOnlyCredentialAndStoresTokenHash(t *testing.T) {
	tests := []struct {
		name       string
		secretKey  string
		serviceKey string
		wantAPIKey string
		wantBearer string
	}{
		{
			name:       "new secret",
			secretKey:  "sb_secret_aptitude-test",
			wantAPIKey: "sb_secret_aptitude-test",
		},
		{
			name:       "legacy service role",
			serviceKey: legacyServiceRoleKey(),
			wantAPIKey: legacyServiceRoleKey(),
			wantBearer: "Bearer " + legacyServiceRoleKey(),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if request.URL.Path != "/rest/v1/rpc/create_automated_aptitude_invitation" {
					t.Errorf("request path = %q", request.URL.Path)
				}
				if request.Header.Get("apikey") != test.wantAPIKey ||
					request.Header.Get("Authorization") != test.wantBearer {
					t.Error("unexpected privileged credential headers")
				}
				var payload map[string]any
				if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
					t.Errorf("decode RPC payload: %v", err)
				}
				hash, ok := payload["target_token_hash"].(string)
				rawToken, tokenOK := payload["target_token"].(string)
				if !ok || len(hash) != 64 || !tokenOK || len(rawToken) != 43 {
					t.Error("request should contain the token and its hash for private storage")
				} else {
					sum := sha256.Sum256([]byte(rawToken))
					if hash != hex.EncodeToString(sum[:]) {
						t.Error("invitation token hash does not match the token")
					}
				}
				_, _ = io.WriteString(writer, `{"id":"12345678-1234-1234-1234-123456789abc","workspace_id":"82ef1fb1-47c7-4c5e-8118-e78d33b58e1d","application_id":"9ba0fef4-10e6-41f0-81aa-7ec52a7f9e77","test_version_id":"1bfeb683-e931-4ce0-a555-f70f976f4a19","candidate_email":"candidate@example.test","test_title":"Test","status":"pending","expires_at":"2030-01-01T00:00:00Z","max_attempts":1,"email_status":"failed"}`)
			}))
			defer server.Close()

			client, err := NewClient(config.Config{
				SupabaseURL:            server.URL,
				SupabaseSecretKey:      test.secretKey,
				SupabaseServiceRoleKey: test.serviceKey,
			})
			if err != nil {
				t.Fatalf("NewClient() error = %v", err)
			}
			invitation, token, err := client.CreateInvitation(
				context.Background(),
				InvitationInput{
					UserID:        "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae",
					WorkspaceID:   "82ef1fb1-47c7-4c5e-8118-e78d33b58e1d",
					ApplicationID: "9ba0fef4-10e6-41f0-81aa-7ec52a7f9e77",
					VersionID:     "1bfeb683-e931-4ce0-a555-f70f976f4a19",
					ExpiresAt:     time.Now().Add(time.Hour),
					MaxAttempts:   1,
				},
			)
			if err != nil {
				t.Fatalf("CreateInvitation() error = %v", err)
			}
			if invitation.ID == "" || len(token) != 43 {
				t.Fatal("invitation response or candidate token was invalid")
			}
		})
	}
}

func TestCandidateSessionHashesInvitationToken(t *testing.T) {
	const token = "Abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var payload map[string]string
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Errorf("decode RPC payload: %v", err)
		}
		sum := sha256.Sum256([]byte(token))
		if payload["target_token_hash"] != hex.EncodeToString(sum[:]) {
			t.Error("RPC did not receive the SHA-256 invitation token hash")
		}
		if strings.Contains(request.URL.String(), token) {
			t.Error("invitation token was included in request URL")
		}
		_, _ = io.WriteString(writer, `{"title":"Test","questions":[]}`)
	}))
	defer server.Close()

	client, err := NewClient(config.Config{
		SupabaseURL:       server.URL,
		SupabaseSecretKey: "sb_secret_aptitude-test",
	})
	if err != nil {
		t.Fatalf("NewClient() error = %v", err)
	}
	response, err := client.CandidateSession(context.Background(), token)
	if err != nil {
		t.Fatalf("CandidateSession() error = %v", err)
	}
	if !json.Valid(response) || strings.Contains(string(response), token) {
		t.Fatal("candidate response is invalid or echoed the invitation token")
	}
}

func TestSaveProgressPersistsAnswerAndQuestionPosition(t *testing.T) {
	const token = "Abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/rest/v1/rpc/save_aptitude_candidate_progress" {
			t.Errorf("request path = %q", request.URL.Path)
		}
		var payload map[string]any
		if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
			t.Errorf("decode RPC payload: %v", err)
		}
		if payload["target_question_index"] != float64(2) ||
			payload["target_question_id"] != "1bfeb683-e931-4ce0-a555-f70f976f4a19" ||
			payload["target_answer"] == nil {
			t.Errorf("unexpected progress payload: %#v", payload)
		}
		_, _ = io.WriteString(writer, "true")
	}))
	defer server.Close()
	client, err := NewClient(config.Config{
		SupabaseURL:       server.URL,
		SupabaseSecretKey: "sb_secret_test",
	})
	if err != nil {
		t.Fatal(err)
	}
	err = client.SaveProgress(
		context.Background(),
		token,
		"12345678-1234-1234-1234-123456789abc",
		"1bfeb683-e931-4ce0-a555-f70f976f4a19",
		2,
		json.RawMessage(`{"option_ids":["abc"]}`),
	)
	if err != nil {
		t.Fatalf("SaveProgress() error = %v", err)
	}
}

func TestCandidateSessionRejectsMalformedToken(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		t.Fatal("invalid invitation token must not make a Supabase request")
	}))
	defer server.Close()

	client, err := NewClient(config.Config{
		SupabaseURL:       server.URL,
		SupabaseSecretKey: "sb_secret_aptitude-test",
	})
	if err != nil {
		t.Fatalf("NewClient() error = %v", err)
	}
	if _, err := client.CandidateSession(context.Background(), "not-a-token"); err == nil {
		t.Fatal("CandidateSession() should reject malformed tokens")
	}
}

func legacyServiceRoleKey() string {
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"role":"service_role"}`))
	return "eyJhbGciOiJub25lIn0." + payload + ".signature"
}
