package email

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

type ProviderEvent struct {
	Type    string
	Message string
}

func VerifyResendWebhook(
	secret string,
	headers http.Header,
	body []byte,
	now time.Time,
) (ProviderEvent, error) {
	secret = strings.TrimSpace(secret)
	if !strings.HasPrefix(secret, "whsec_") || len(body) == 0 || len(body) > 1<<20 {
		return ProviderEvent{}, errors.New("invalid provider webhook")
	}
	secretBytes, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(secret, "whsec_"))
	if err != nil || len(secretBytes) == 0 {
		return ProviderEvent{}, errors.New("invalid provider webhook")
	}

	eventID := headers.Get("svix-id")
	timestamp := headers.Get("svix-timestamp")
	signatures := headers.Get("svix-signature")
	unixTimestamp, err := strconv.ParseInt(timestamp, 10, 64)
	if eventID == "" || err != nil || signatures == "" {
		return ProviderEvent{}, errors.New("invalid provider webhook")
	}
	eventTime := time.Unix(unixTimestamp, 0)
	if eventTime.Before(now.Add(-5*time.Minute)) || eventTime.After(now.Add(5*time.Minute)) {
		return ProviderEvent{}, errors.New("expired provider webhook")
	}
	signedContent := eventID + "." + timestamp + "." + string(body)
	mac := hmac.New(sha256.New, secretBytes)
	_, _ = mac.Write([]byte(signedContent))
	expected := mac.Sum(nil)
	verified := false
	for _, signature := range strings.Fields(signatures) {
		version, encoded, found := strings.Cut(signature, ",")
		if !found || version != "v1" {
			continue
		}
		provided, decodeErr := base64.StdEncoding.DecodeString(encoded)
		if decodeErr == nil && hmac.Equal(expected, provided) {
			verified = true
			break
		}
	}
	if !verified {
		return ProviderEvent{}, errors.New("invalid provider webhook")
	}

	var payload struct {
		Type string `json:"type"`
		Data struct {
			EmailID string `json:"email_id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &payload); err != nil || payload.Type == "" {
		return ProviderEvent{}, errors.New("invalid provider webhook")
	}
	switch payload.Type {
	case "email.delivered", "email.bounced", "email.complained", "email.failed":
		if payload.Data.EmailID == "" || len(payload.Data.EmailID) > 250 {
			return ProviderEvent{}, errors.New("invalid provider webhook")
		}
		return ProviderEvent{Type: payload.Type, Message: payload.Data.EmailID}, nil
	default:
		return ProviderEvent{Type: payload.Type}, nil
	}
}
