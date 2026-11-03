package aptitude

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/rishi1930/proofhire/backend/config"
)

var (
	uuidPattern = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)
	eventTypes  = map[string]struct{}{
		"focus_lost":               {},
		"visibility_hidden":        {},
		"fullscreen_exit":          {},
		"copy_attempt":             {},
		"paste_attempt":            {},
		"network_disconnected":     {},
		"network_reconnected":      {},
		"heartbeat_timeout":        {},
		"candidate_reported_issue": {},
	}
)

type Client struct {
	baseURL    string
	serviceKey string
	credential config.SupabaseCredentialType
	httpClient *http.Client
}

type InvitationInput struct {
	UserID        string
	WorkspaceID   string
	ApplicationID string
	VersionID     string
	ExpiresAt     time.Time
	MaxAttempts   int
}

type Invitation struct {
	ID             string    `json:"id"`
	WorkspaceID    string    `json:"workspace_id"`
	ApplicationID  string    `json:"application_id"`
	TestVersionID  string    `json:"test_version_id"`
	CandidateEmail string    `json:"candidate_email"`
	TestTitle      string    `json:"test_title"`
	Status         string    `json:"status"`
	ExpiresAt      time.Time `json:"expires_at"`
	MaxAttempts    int       `json:"max_attempts"`
	EmailStatus    string    `json:"email_status"`
}

func NewClient(environment config.Config) (*Client, error) {
	key, credential, err := config.ResolveSupabasePrivilegedCredential(
		environment.SupabaseSecretKey,
		environment.SupabaseServiceRoleKey,
	)
	if err != nil {
		return nil, errors.New("aptitude backend requires a valid Supabase privileged credential")
	}
	if strings.TrimSpace(environment.SupabaseURL) == "" {
		return nil, errors.New("aptitude backend requires SUPABASE_URL")
	}
	return &Client{
		baseURL:    strings.TrimRight(environment.SupabaseURL, "/"),
		serviceKey: key,
		credential: credential,
		httpClient: &http.Client{Timeout: 15 * time.Second},
	}, nil
}

func NewClientWithHTTPClient(environment config.Config, httpClient *http.Client) (*Client, error) {
	client, err := NewClient(environment)
	if err != nil {
		return nil, err
	}
	if httpClient != nil {
		client.httpClient = httpClient
	}
	return client, nil
}

func (client *Client) CreateInvitation(
	ctx context.Context,
	input InvitationInput,
) (Invitation, string, error) {
	if !uuidPattern.MatchString(input.UserID) ||
		!uuidPattern.MatchString(input.WorkspaceID) ||
		!uuidPattern.MatchString(input.ApplicationID) ||
		!uuidPattern.MatchString(input.VersionID) ||
		input.MaxAttempts < 1 || input.MaxAttempts > 5 ||
		!input.ExpiresAt.After(time.Now()) {
		return Invitation{}, "", errors.New("invalid aptitude invitation request")
	}

	var tokenBytes [32]byte
	if _, err := rand.Read(tokenBytes[:]); err != nil {
		return Invitation{}, "", errors.New("could not create aptitude invitation")
	}
	token := base64.RawURLEncoding.EncodeToString(tokenBytes[:])
	hash := sha256.Sum256([]byte(token))
	var invitation Invitation
	err := client.call(ctx, "create_automated_aptitude_invitation", map[string]any{
		"target_user_id":         input.UserID,
		"target_workspace_id":    input.WorkspaceID,
		"target_application_id":  input.ApplicationID,
		"target_test_version_id": input.VersionID,
		"target_token":           token,
		"target_token_hash":      hex.EncodeToString(hash[:]),
		"target_expires_at":      input.ExpiresAt.UTC().Format(time.RFC3339),
		"target_max_attempts":    input.MaxAttempts,
	}, &invitation)
	if err != nil {
		return Invitation{}, "", err
	}
	if !uuidPattern.MatchString(invitation.ID) {
		return Invitation{}, "", errors.New("aptitude invitation could not be created")
	}
	return invitation, token, nil
}

func (client *Client) CandidateSession(ctx context.Context, token string) (json.RawMessage, error) {
	if !validToken(token) {
		return nil, errors.New("invalid aptitude invitation")
	}
	var response json.RawMessage
	if err := client.call(ctx, "get_aptitude_candidate_session", map[string]any{
		"target_token_hash": tokenHash(token),
	}, &response); err != nil {
		return nil, err
	}
	return response, nil
}

func (client *Client) StartAttempt(ctx context.Context, token string) (json.RawMessage, error) {
	if !validToken(token) {
		return nil, errors.New("invalid aptitude invitation")
	}
	var response json.RawMessage
	if err := client.call(ctx, "start_aptitude_candidate_attempt", map[string]any{
		"target_token_hash": tokenHash(token),
	}, &response); err != nil {
		return nil, err
	}
	return response, nil
}

func (client *Client) SaveAnswer(
	ctx context.Context,
	token string,
	attemptID string,
	questionID string,
	answer json.RawMessage,
) error {
	if !validToken(token) || !uuidPattern.MatchString(attemptID) || !uuidPattern.MatchString(questionID) ||
		len(answer) == 0 || len(answer) > 10<<10 || !json.Valid(answer) {
		return errors.New("invalid aptitude answer")
	}
	var response bool
	if err := client.call(ctx, "save_aptitude_candidate_answer", map[string]any{
		"target_token_hash":  tokenHash(token),
		"target_attempt_id":  attemptID,
		"target_question_id": questionID,
		"target_answer":      answer,
	}, &response); err != nil {
		return err
	}
	if !response {
		return errors.New("aptitude answer was not saved")
	}
	return nil
}

func (client *Client) SaveProgress(
	ctx context.Context,
	token string,
	attemptID string,
	questionID string,
	questionIndex int,
	answer json.RawMessage,
) error {
	if !validToken(token) || !uuidPattern.MatchString(attemptID) ||
		!uuidPattern.MatchString(questionID) || questionIndex < 0 || questionIndex > 1000 ||
		len(answer) > 10<<10 || (len(answer) > 0 && !json.Valid(answer)) {
		return errors.New("invalid aptitude progress")
	}
	var answerValue any
	if len(answer) > 0 {
		answerValue = answer
	}
	var response bool
	if err := client.call(ctx, "save_aptitude_candidate_progress", map[string]any{
		"target_token_hash":     tokenHash(token),
		"target_attempt_id":     attemptID,
		"target_question_id":    questionID,
		"target_question_index": questionIndex,
		"target_answer":         answerValue,
	}, &response); err != nil {
		return err
	}
	if !response {
		return errors.New("aptitude progress was not saved")
	}
	return nil
}

func (client *Client) SubmitAttempt(
	ctx context.Context,
	token string,
	attemptID string,
) (json.RawMessage, error) {
	if !validToken(token) || !uuidPattern.MatchString(attemptID) {
		return nil, errors.New("invalid aptitude attempt")
	}
	var response json.RawMessage
	if err := client.call(ctx, "submit_aptitude_candidate_attempt", map[string]any{
		"target_token_hash": tokenHash(token),
		"target_attempt_id": attemptID,
	}, &response); err != nil {
		return nil, err
	}
	return response, nil
}

func (client *Client) RecordEvent(
	ctx context.Context,
	token string,
	attemptID string,
	eventType string,
	eventData json.RawMessage,
) error {
	if !validToken(token) || !uuidPattern.MatchString(attemptID) {
		return errors.New("invalid aptitude monitoring event")
	}
	if _, ok := eventTypes[eventType]; !ok {
		return errors.New("invalid aptitude monitoring event")
	}
	if len(eventData) == 0 {
		eventData = json.RawMessage(`{}`)
	}
	if len(eventData) > 2048 || !json.Valid(eventData) {
		return errors.New("invalid aptitude monitoring event")
	}
	var response string
	if err := client.call(ctx, "record_aptitude_candidate_event", map[string]any{
		"target_token_hash": tokenHash(token),
		"target_attempt_id": attemptID,
		"target_event_type": eventType,
		"target_event_data": eventData,
	}, &response); err != nil {
		return err
	}
	return nil
}

func (client *Client) call(
	ctx context.Context,
	function string,
	payload any,
	result any,
) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return errors.New("could not prepare aptitude request")
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		client.baseURL+"/rest/v1/rpc/"+function,
		bytes.NewReader(body),
	)
	if err != nil {
		return errors.New("could not create aptitude request")
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("apikey", client.serviceKey)
	if client.credential == config.SupabaseServiceRoleCredential {
		request.Header.Set("Authorization", "Bearer "+client.serviceKey)
	}
	response, err := client.httpClient.Do(request)
	if err != nil {
		return errors.New("aptitude service is unavailable")
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
		return errors.New("aptitude service could not complete the request")
	}
	if result == nil || len(responseBody) == 0 {
		return nil
	}
	if err := json.Unmarshal(responseBody, result); err != nil {
		return fmt.Errorf("aptitude service returned an invalid response")
	}
	return nil
}

func tokenHash(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}

func validToken(token string) bool {
	if len(token) != 43 {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	return err == nil && len(decoded) == 32
}
