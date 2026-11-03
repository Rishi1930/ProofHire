package email

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"strconv"
	"testing"
	"time"
)

func TestVerifyResendWebhook(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	body := []byte(`{"type":"email.delivered","data":{"email_id":"provider-message-1"}}`)
	secretBytes := []byte("webhook-secret-for-test")
	secret := "whsec_" + base64.StdEncoding.EncodeToString(secretBytes)
	eventID := "event-123"
	timestamp := strconv.FormatInt(now.Unix(), 10)
	mac := hmac.New(sha256.New, secretBytes)
	_, _ = mac.Write([]byte(eventID + "." + timestamp + "." + string(body)))
	headers := make(http.Header)
	headers.Set("svix-id", eventID)
	headers.Set("svix-timestamp", timestamp)
	headers.Set("svix-signature", "v1,"+base64.StdEncoding.EncodeToString(mac.Sum(nil)))

	event, err := VerifyResendWebhook(secret, headers, body, now)
	if err != nil {
		t.Fatalf("VerifyResendWebhook() error = %v", err)
	}
	if event.Type != "email.delivered" || event.Message != "provider-message-1" {
		t.Fatalf("unexpected event: %#v", event)
	}
}

func TestVerifyResendWebhookRejectsInvalidAndExpiredSignatures(t *testing.T) {
	now := time.Date(2026, 11, 3, 12, 0, 0, 0, time.UTC)
	body := []byte(`{"type":"email.delivered","data":{"email_id":"provider-message-1"}}`)
	secret := "whsec_" + base64.StdEncoding.EncodeToString([]byte("webhook-secret"))
	headers := make(http.Header)
	headers.Set("svix-id", "event-123")
	headers.Set("svix-timestamp", strconv.FormatInt(now.Unix(), 10))
	headers.Set("svix-signature", "v1,invalid-signature")
	if _, err := VerifyResendWebhook(secret, headers, body, now); err == nil {
		t.Fatal("invalid signature was accepted")
	}
	headers.Set("svix-timestamp", strconv.FormatInt(now.Add(-6*time.Minute).Unix(), 10))
	if _, err := VerifyResendWebhook(secret, headers, body, now); err == nil {
		t.Fatal("expired webhook was accepted")
	}
}
