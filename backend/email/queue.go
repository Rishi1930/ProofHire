package email

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/rishi1930/proofhire/backend/config"
)

var queueUUIDPattern = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)

type QueueClient struct {
	baseURL    string
	serviceKey string
	credential config.SupabaseCredentialType
	httpClient *http.Client
}

func NewQueueClient(environment config.Config) (*QueueClient, error) {
	key, credential, err := config.ResolveSupabasePrivilegedCredential(
		environment.SupabaseSecretKey,
		environment.SupabaseServiceRoleKey,
	)
	if err != nil {
		return nil, errors.New("email queue requires a privileged Supabase credential")
	}
	if strings.TrimSpace(environment.SupabaseURL) == "" {
		return nil, errors.New("email queue requires SUPABASE_URL")
	}
	return &QueueClient{
		baseURL:    strings.TrimRight(environment.SupabaseURL, "/"),
		serviceKey: key,
		credential: credential,
		httpClient: &http.Client{Timeout: 15 * time.Second},
	}, nil
}

func (client *QueueClient) RequestAction(
	ctx context.Context,
	userID string,
	workspaceID string,
	jobID string,
	action string,
	requestID string,
) (json.RawMessage, error) {
	if !queueUUIDPattern.MatchString(userID) ||
		!queueUUIDPattern.MatchString(workspaceID) ||
		!queueUUIDPattern.MatchString(jobID) ||
		!queueUUIDPattern.MatchString(requestID) ||
		(action != "send" && action != "retry" && action != "resend") {
		return nil, errors.New("invalid email delivery action")
	}
	payload, err := json.Marshal(map[string]string{
		"target_user_id":      userID,
		"target_workspace_id": workspaceID,
		"target_job_id":       jobID,
		"target_action":       action,
		"target_request_id":   requestID,
	})
	if err != nil {
		return nil, errors.New("could not prepare email delivery action")
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		client.baseURL+"/rest/v1/rpc/request_email_delivery_action",
		bytes.NewReader(payload),
	)
	if err != nil {
		return nil, errors.New("could not create email delivery action")
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("apikey", client.serviceKey)
	if client.credential == config.SupabaseServiceRoleCredential {
		request.Header.Set("Authorization", "Bearer "+client.serviceKey)
	}
	response, err := client.httpClient.Do(request)
	if err != nil {
		return nil, errors.New("email delivery service is unavailable")
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, errors.New("email delivery action could not be completed")
	}
	if !json.Valid(responseBody) {
		return nil, errors.New("email delivery service returned an invalid response")
	}
	return json.RawMessage(responseBody), nil
}

func (client *QueueClient) RecordProviderEvent(
	ctx context.Context,
	providerMessageID string,
	eventType string,
) error {
	if strings.TrimSpace(providerMessageID) == "" || len(providerMessageID) > 250 ||
		(eventType != "email.delivered" && eventType != "email.bounced" &&
			eventType != "email.complained" && eventType != "email.failed") {
		return errors.New("invalid email provider event")
	}
	payload, err := json.Marshal(map[string]string{
		"target_provider_message_id": providerMessageID,
		"target_event_type":          eventType,
	})
	if err != nil {
		return errors.New("could not prepare email provider event")
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		client.baseURL+"/rest/v1/rpc/record_email_delivery_provider_event",
		bytes.NewReader(payload),
	)
	if err != nil {
		return errors.New("could not create email provider event")
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("apikey", client.serviceKey)
	if client.credential == config.SupabaseServiceRoleCredential {
		request.Header.Set("Authorization", "Bearer "+client.serviceKey)
	}
	response, err := client.httpClient.Do(request)
	if err != nil {
		return errors.New("email delivery service is unavailable")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return errors.New("email provider event could not be recorded")
	}
	return nil
}
