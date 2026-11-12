package email

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"mime"
	"net"
	"net/smtp"
	"strings"
	"time"

	"github.com/rishi1930/proofhire/backend/config"
)

// Sender is the delivery transport used by the email worker. Both the HTTP
// provider client and the SMTP client satisfy it.
type Sender interface {
	Send(ctx context.Context, message Message) (Accepted, error)
}

// SMTPSender delivers mail over the owner's own SMTP server. It supports
// implicit TLS (port 465 style), STARTTLS and plain connections for a trusted
// relay, and authenticates only when credentials are configured.
type SMTPSender struct {
	host     string
	port     string
	username string
	password string
	security string
	from     string
	fromName string
	timeout  time.Duration
}

// NewSMTPSender builds a sender from backend configuration.
func NewSMTPSender(environment config.Config) (*SMTPSender, error) {
	if strings.TrimSpace(environment.SMTPHost) == "" {
		return nil, errors.New("SMTP_HOST is required for the smtp provider")
	}
	if environment.SMTPPort < 1 || environment.SMTPPort > 65535 {
		return nil, errors.New("SMTP_PORT must be between 1 and 65535")
	}
	if strings.TrimSpace(environment.EmailFromAddress) == "" {
		return nil, errors.New("EMAIL_FROM_ADDRESS is required")
	}
	security := strings.ToLower(strings.TrimSpace(environment.SMTPSecurity))
	switch security {
	case "", "starttls", "tls", "none":
	default:
		return nil, errors.New("SMTP_SECURITY must be starttls, tls or none")
	}
	if security == "" {
		security = "starttls"
	}
	if (environment.SMTPUsername == "") != (environment.SMTPPassword == "") {
		return nil, errors.New("SMTP_USERNAME and SMTP_PASSWORD must be set together")
	}
	return &SMTPSender{
		host:     strings.TrimSpace(environment.SMTPHost),
		port:     fmt.Sprintf("%d", environment.SMTPPort),
		username: environment.SMTPUsername,
		password: environment.SMTPPassword,
		security: security,
		from:     strings.TrimSpace(environment.EmailFromAddress),
		fromName: strings.TrimSpace(environment.EmailFromName),
		timeout:  20 * time.Second,
	}, nil
}

// Send delivers one message and returns the locally generated Message-ID.
// SMTP gives no provider acceptance receipt, so a successful DATA exchange is
// the delivery confirmation the worker records.
func (sender *SMTPSender) Send(ctx context.Context, message Message) (Accepted, error) {
	recipient := strings.TrimSpace(message.To)
	if !validRecipient(recipient) {
		return Accepted{}, &DeliveryError{Code: "invalid_recipient", Retryable: false}
	}
	if strings.ContainsAny(message.Subject, "\r\n") {
		return Accepted{}, &DeliveryError{Code: "invalid_subject", Retryable: false}
	}

	messageID := newMessageID(sender.from)
	payload, err := buildMIME(sender.from, sender.fromName, recipient, message, messageID)
	if err != nil {
		return Accepted{}, &DeliveryError{Code: "invalid_message", Retryable: false}
	}

	address := net.JoinHostPort(sender.host, sender.port)
	dialer := &net.Dialer{Timeout: sender.timeout}
	var connection net.Conn
	if sender.security == "tls" {
		connection, err = tls.DialWithDialer(dialer, "tcp", address, &tls.Config{
			ServerName: sender.host,
			MinVersion: tls.VersionTLS12,
		})
	} else {
		connection, err = dialer.DialContext(ctx, "tcp", address)
	}
	if err != nil {
		return Accepted{}, &DeliveryError{Code: "smtp_connect_failed", Retryable: true}
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(sender.timeout))

	client, err := smtp.NewClient(connection, sender.host)
	if err != nil {
		return Accepted{}, &DeliveryError{Code: "smtp_handshake_failed", Retryable: true}
	}
	defer client.Close()

	if sender.security == "starttls" {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return Accepted{}, &DeliveryError{Code: "smtp_starttls_unsupported", Retryable: false}
		}
		if err := client.StartTLS(&tls.Config{
			ServerName: sender.host,
			MinVersion: tls.VersionTLS12,
		}); err != nil {
			return Accepted{}, &DeliveryError{Code: "smtp_starttls_failed", Retryable: true}
		}
	}

	if sender.username != "" {
		if ok, _ := client.Extension("AUTH"); !ok {
			return Accepted{}, &DeliveryError{Code: "smtp_auth_unsupported", Retryable: false}
		}
		if err := client.Auth(smtp.PlainAuth("", sender.username, sender.password, sender.host)); err != nil {
			return Accepted{}, &DeliveryError{Code: "smtp_auth_failed", Retryable: false}
		}
	}

	if err := client.Mail(sender.from); err != nil {
		return Accepted{}, &DeliveryError{Code: "smtp_sender_rejected", Retryable: false}
	}
	if err := client.Rcpt(recipient); err != nil {
		return Accepted{}, &DeliveryError{Code: "smtp_recipient_rejected", Retryable: false}
	}
	writer, err := client.Data()
	if err != nil {
		return Accepted{}, &DeliveryError{Code: "smtp_data_rejected", Retryable: true}
	}
	if _, err := writer.Write(payload); err != nil {
		return Accepted{}, &DeliveryError{Code: "smtp_write_failed", Retryable: true}
	}
	if err := writer.Close(); err != nil {
		return Accepted{}, &DeliveryError{Code: "smtp_delivery_failed", Retryable: true}
	}
	if err := client.Quit(); err != nil {
		// The message was already accepted; a failed QUIT is not a delivery
		// failure, and retrying would duplicate the email.
		return Accepted{MessageID: messageID}, nil
	}
	return Accepted{MessageID: messageID}, nil
}

func buildMIME(from, fromName, recipient string, message Message, messageID string) ([]byte, error) {
	boundary := "proofhire-" + strings.TrimPrefix(messageID, "<")
	fromHeader := from
	if fromName != "" {
		fromHeader = mime.QEncoding.Encode("utf-8", fromName) + " <" + from + ">"
	}
	subject := mime.QEncoding.Encode("utf-8", message.Subject)

	var builder strings.Builder
	builder.WriteString("From: " + fromHeader + "\r\n")
	builder.WriteString("To: " + recipient + "\r\n")
	builder.WriteString("Subject: " + subject + "\r\n")
	builder.WriteString("Message-ID: " + messageID + "\r\n")
	builder.WriteString("Date: " + time.Now().UTC().Format(time.RFC1123Z) + "\r\n")
	builder.WriteString("MIME-Version: 1.0\r\n")
	builder.WriteString("Content-Type: multipart/alternative; boundary=\"" + boundary + "\"\r\n")
	builder.WriteString("\r\n")
	builder.WriteString("--" + boundary + "\r\n")
	builder.WriteString("Content-Type: text/plain; charset=utf-8\r\n")
	builder.WriteString("Content-Transfer-Encoding: 8bit\r\n\r\n")
	builder.WriteString(strings.ReplaceAll(message.Text, "\n", "\r\n"))
	builder.WriteString("\r\n--" + boundary + "\r\n")
	builder.WriteString("Content-Type: text/html; charset=utf-8\r\n")
	builder.WriteString("Content-Transfer-Encoding: 8bit\r\n\r\n")
	builder.WriteString(strings.ReplaceAll(message.HTML, "\n", "\r\n"))
	builder.WriteString("\r\n--" + boundary + "--\r\n")
	return []byte(builder.String()), nil
}

func validRecipient(value string) bool {
	if len(value) < 3 || len(value) > 320 || strings.ContainsAny(value, "\r\n <>,;") {
		return false
	}
	at := strings.LastIndexByte(value, '@')
	return at > 0 && at < len(value)-1 && strings.Contains(value[at+1:], ".")
}

func newMessageID(from string) string {
	domain := "proofhire.local"
	if at := strings.LastIndexByte(from, '@'); at >= 0 && at < len(from)-1 {
		domain = from[at+1:]
	}
	var data [12]byte
	if _, err := rand.Read(data[:]); err != nil {
		return "<" + hex.EncodeToString([]byte(time.Now().UTC().Format("20060102150405"))) + "@" + domain + ">"
	}
	return "<" + hex.EncodeToString(data[:]) + "@" + domain + ">"
}
