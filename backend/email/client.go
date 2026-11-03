package email

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

const resendEndpoint = "https://api.resend.com/emails"

type Message struct {
	To             string
	Subject        string
	HTML           string
	Text           string
	IdempotencyKey string
}

type Accepted struct {
	MessageID string
}

type Client struct {
	apiKey     string
	from       string
	httpClient *http.Client
	endpoint   string
}

type Option func(*Client)

func WithHTTPClient(client *http.Client) Option {
	return func(provider *Client) {
		if client != nil {
			provider.httpClient = client
		}
	}
}

func WithEndpoint(endpoint string) Option {
	return func(provider *Client) {
		if strings.TrimSpace(endpoint) != "" {
			provider.endpoint = strings.TrimRight(endpoint, "/")
		}
	}
}

func NewClient(apiKey, from string, options ...Option) (*Client, error) {
	apiKey = strings.TrimSpace(apiKey)
	from = strings.TrimSpace(from)
	if apiKey == "" || from == "" || strings.ContainsAny(from, "\r\n") {
		return nil, errors.New("Resend email configuration is incomplete")
	}
	provider := &Client{
		apiKey:     apiKey,
		from:       from,
		httpClient: &http.Client{Timeout: 15 * time.Second},
		endpoint:   resendEndpoint,
	}
	for _, option := range options {
		option(provider)
	}
	return provider, nil
}

func (provider *Client) Send(ctx context.Context, message Message) (Accepted, error) {
	if ctx == nil || strings.TrimSpace(message.To) == "" ||
		strings.ContainsAny(message.To, "\r\n") ||
		strings.TrimSpace(message.Subject) == "" ||
		len(message.Subject) > 250 ||
		strings.TrimSpace(message.HTML) == "" ||
		strings.TrimSpace(message.Text) == "" ||
		len(message.IdempotencyKey) < 1 ||
		len(message.IdempotencyKey) > 200 ||
		strings.ContainsAny(message.IdempotencyKey, "\r\n") {
		return Accepted{}, errors.New("invalid email message")
	}

	body, err := json.Marshal(struct {
		From    string   `json:"from"`
		To      []string `json:"to"`
		Subject string   `json:"subject"`
		HTML    string   `json:"html"`
		Text    string   `json:"text"`
	}{
		From:    provider.from,
		To:      []string{message.To},
		Subject: message.Subject,
		HTML:    message.HTML,
		Text:    message.Text,
	})
	if err != nil {
		return Accepted{}, errors.New("could not encode email request")
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		provider.endpoint,
		bytes.NewReader(body),
	)
	if err != nil {
		return Accepted{}, errors.New("could not create email request")
	}
	request.Header.Set("Authorization", "Bearer "+provider.apiKey)
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Idempotency-Key", message.IdempotencyKey)

	response, err := provider.httpClient.Do(request)
	if err != nil {
		return Accepted{}, &DeliveryError{Retryable: true, Code: "provider_unavailable"}
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, 16<<10))
	if err != nil {
		return Accepted{}, &DeliveryError{Retryable: true, Code: "provider_response_unavailable"}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		retryable := response.StatusCode == http.StatusRequestTimeout ||
			response.StatusCode == http.StatusTooManyRequests ||
			response.StatusCode >= 500
		code := providerErrorCode(responseBody)
		return Accepted{}, &DeliveryError{
			StatusCode: response.StatusCode,
			Retryable:  retryable,
			Code:       code,
		}
	}

	var result struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(responseBody, &result); err != nil ||
		strings.TrimSpace(result.ID) == "" || len(result.ID) > 250 {
		return Accepted{}, &DeliveryError{Retryable: true, Code: "invalid_provider_response"}
	}
	return Accepted{MessageID: result.ID}, nil
}

type DeliveryError struct {
	StatusCode int
	Retryable  bool
	Code       string
}

func (failure *DeliveryError) Error() string {
	if failure.StatusCode != 0 {
		return fmt.Sprintf("email provider rejected the request (status %d)", failure.StatusCode)
	}
	return "email provider delivery failed"
}

func providerErrorCode(body []byte) string {
	var response struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(body, &response); err != nil {
		return "provider_rejected"
	}
	switch strings.ToLower(response.Name) {
	case "validation_error":
		return "validation_error"
	case "rate_limit_exceeded":
		return "rate_limited"
	case "invalid_api_key":
		return "credentials_rejected"
	default:
		return "provider_rejected"
	}
}
