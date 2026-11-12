package email

import (
	"bufio"
	"context"
	"errors"
	"net"
	"strings"
	"sync"
	"testing"

	"github.com/rishi1930/proofhire/backend/config"
)

// startFakeSMTP accepts one message and records the DATA payload.
func startFakeSMTP(t *testing.T) (address string, port int, messages *[]string, done chan struct{}) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	collected := []string{}
	mutex := sync.Mutex{}
	finished := make(chan struct{})

	go func() {
		defer close(finished)
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		defer connection.Close()
		reader := bufio.NewReader(connection)
		writer := bufio.NewWriter(connection)
		write := func(line string) {
			_, _ = writer.WriteString(line + "\r\n")
			_ = writer.Flush()
		}
		write("220 fake.local ESMTP")
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				return
			}
			command := strings.ToUpper(strings.TrimSpace(line))
			switch {
			case strings.HasPrefix(command, "EHLO"), strings.HasPrefix(command, "HELO"):
				write("250-fake.local")
				write("250 OK")
			case strings.HasPrefix(command, "MAIL FROM"), strings.HasPrefix(command, "RCPT TO"):
				write("250 OK")
			case command == "DATA":
				write("354 End data with <CR><LF>.<CR><LF>")
				var body strings.Builder
				for {
					dataLine, err := reader.ReadString('\n')
					if err != nil {
						return
					}
					if dataLine == ".\r\n" {
						break
					}
					body.WriteString(dataLine)
				}
				mutex.Lock()
				collected = append(collected, body.String())
				mutex.Unlock()
				write("250 Queued")
			case command == "QUIT":
				write("221 Bye")
				return
			default:
				write("250 OK")
			}
		}
	}()

	host, portText, _ := net.SplitHostPort(listener.Addr().String())
	portValue := 0
	for _, character := range portText {
		portValue = portValue*10 + int(character-'0')
	}
	return host, portValue, &collected, finished
}

func TestSMTPSenderDeliversMultipartMessage(t *testing.T) {
	host, port, messages, done := startFakeSMTP(t)
	sender, err := NewSMTPSender(config.Config{
		EmailFromAddress: "hiring@proofhire.test",
		EmailFromName:    "ProofHire Hiring",
		SMTPHost:         host,
		SMTPPort:         port,
		SMTPSecurity:     "none",
	})
	if err != nil {
		t.Fatalf("sender: %v", err)
	}

	accepted, err := sender.Send(context.Background(), Message{
		To:      "candidate@example.test",
		Subject: "Your ProofHire interview",
		HTML:    "<p>Hello <strong>Candidate</strong></p>",
		Text:    "Hello Candidate",
	})
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	if accepted.MessageID == "" {
		t.Fatal("expected a generated Message-ID")
	}
	<-done
	if len(*messages) != 1 {
		t.Fatalf("messages = %d, want 1", len(*messages))
	}
	body := (*messages)[0]
	for _, expected := range []string{
		"To: candidate@example.test",
		"Message-ID: " + accepted.MessageID,
		"multipart/alternative",
		"Hello Candidate",
		"<strong>Candidate</strong>",
	} {
		if !strings.Contains(body, expected) {
			t.Errorf("message missing %q\n%s", expected, body)
		}
	}
}

func TestSMTPSenderRejectsHeaderInjection(t *testing.T) {
	sender, err := NewSMTPSender(config.Config{
		EmailFromAddress: "hiring@proofhire.test",
		EmailFromName:    "ProofHire",
		SMTPHost:         "127.0.0.1",
		SMTPPort:         2525,
		SMTPSecurity:     "none",
	})
	if err != nil {
		t.Fatalf("sender: %v", err)
	}
	_, err = sender.Send(context.Background(), Message{
		To:      "candidate@example.test\r\nBcc: other@example.test",
		Subject: "Hello",
		Text:    "Body",
	})
	var deliveryError *DeliveryError
	if !errors.As(err, &deliveryError) || deliveryError.Code != "invalid_recipient" {
		t.Fatalf("expected invalid_recipient, got %v", err)
	}
}

func TestSMTPSenderRequiresMatchingCredentials(t *testing.T) {
	_, err := NewSMTPSender(config.Config{
		EmailFromAddress: "hiring@proofhire.test",
		SMTPHost:         "smtp.example.test",
		SMTPPort:         587,
		SMTPUsername:     "user",
	})
	if err == nil {
		t.Fatal("expected a credential pairing error")
	}
}

func TestValidateEmailAcceptsSMTPWithoutResendKey(t *testing.T) {
	configuration := config.Config{
		EmailProvider:    "smtp",
		EmailFromAddress: "hiring@proofhire.test",
		EmailFromName:    "ProofHire",
		SMTPHost:         "smtp.example.test",
		SMTPPort:         587,
		SMTPSecurity:     "starttls",
	}
	if err := configuration.ValidateEmail(); err != nil {
		t.Fatalf("smtp configuration rejected: %v", err)
	}
	configuration.SMTPPort = 0
	if err := configuration.ValidateEmail(); err == nil {
		t.Fatal("expected a port error")
	}
}
