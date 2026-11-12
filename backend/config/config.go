package config

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/joho/godotenv"
)

type SupabaseCredentialType string

const (
	SupabaseSecretCredential      SupabaseCredentialType = "secret"
	SupabaseServiceRoleCredential SupabaseCredentialType = "service_role"
)

type Config struct {
	SupabaseURL            string
	SupabaseAnonKey        string
	SupabaseSecretKey      string
	SupabaseServiceRoleKey string
	EmailProvider          string
	EmailAPIKey            string
	EmailWebhookSecret     string
	EmailFromAddress       string
	EmailFromName          string
	AppBaseURL             string
	SMTPHost               string
	SMTPPort               int
	SMTPUsername           string
	SMTPPassword           string
	SMTPSecurity           string
	ResumeOCREnabled       bool
	CodeRunnerEnabled      bool
	RunnerPrewarmLanguages []string
	ScreeningConcurrency   int
	ScreeningPollInterval  time.Duration
}

func LoadBackendEnv() error {
	envFile := strings.TrimSpace(os.Getenv("PROOFHIRE_ENV_FILE"))
	if envFile == "" {
		envFile = ".env.backend"
	}
	if _, err := os.Stat(envFile); err != nil {
		if os.IsNotExist(err) && os.Getenv("PROOFHIRE_ENV_FILE") == "" {
			return nil
		}
		if os.IsNotExist(err) {
			return fmt.Errorf("configured backend environment file does not exist")
		}
		return fmt.Errorf("backend environment file cannot be accessed")
	}
	if err := godotenv.Load(envFile); err != nil {
		return fmt.Errorf("backend environment file is invalid")
	}
	return nil
}

func FromEnvironment() (Config, error) {
	config := Config{
		SupabaseURL:            strings.TrimSpace(os.Getenv("SUPABASE_URL")),
		SupabaseAnonKey:        strings.TrimSpace(os.Getenv("SUPABASE_ANON_KEY")),
		SupabaseSecretKey:      strings.TrimSpace(os.Getenv("SUPABASE_SECRET_KEY")),
		SupabaseServiceRoleKey: strings.TrimSpace(os.Getenv("SUPABASE_SERVICE_ROLE_KEY")),
		EmailProvider:          strings.TrimSpace(os.Getenv("EMAIL_PROVIDER")),
		EmailAPIKey:            strings.TrimSpace(os.Getenv("EMAIL_API_KEY")),
		EmailWebhookSecret:     strings.TrimSpace(os.Getenv("RESEND_WEBHOOK_SECRET")),
		EmailFromAddress:       strings.TrimSpace(os.Getenv("EMAIL_FROM_ADDRESS")),
		EmailFromName:          strings.TrimSpace(os.Getenv("EMAIL_FROM_NAME")),
		AppBaseURL:             strings.TrimRight(strings.TrimSpace(os.Getenv("APP_BASE_URL")), "/"),
		SMTPHost:               strings.TrimSpace(os.Getenv("SMTP_HOST")),
		SMTPUsername:           strings.TrimSpace(os.Getenv("SMTP_USERNAME")),
		SMTPPassword:           os.Getenv("SMTP_PASSWORD"),
		SMTPSecurity:           strings.ToLower(strings.TrimSpace(os.Getenv("SMTP_SECURITY"))),
		CodeRunnerEnabled:      true,
		ScreeningConcurrency:   1,
		ScreeningPollInterval:  2 * time.Second,
	}
	if value := strings.TrimSpace(os.Getenv("CODE_RUNNER_ENABLED")); value != "" {
		enabled, err := strconv.ParseBool(value)
		if err != nil {
			return Config{}, fmt.Errorf("CODE_RUNNER_ENABLED must be a boolean")
		}
		config.CodeRunnerEnabled = enabled
	}
	if value := strings.TrimSpace(os.Getenv("RUNNER_PREWARM_LANGUAGES")); value != "" {
		for _, name := range strings.Split(value, ",") {
			trimmed := strings.ToLower(strings.TrimSpace(name))
			if trimmed == "" {
				continue
			}
			config.RunnerPrewarmLanguages = append(config.RunnerPrewarmLanguages, trimmed)
		}
	}
	if value := strings.TrimSpace(os.Getenv("SMTP_PORT")); value != "" {
		port, err := strconv.Atoi(value)
		if err != nil || port < 1 || port > 65535 {
			return Config{}, fmt.Errorf("SMTP_PORT must be a valid port number")
		}
		config.SMTPPort = port
	}
	if value := strings.TrimSpace(os.Getenv("RESUME_OCR_ENABLED")); value != "" {
		enabled, err := strconv.ParseBool(value)
		if err != nil {
			return Config{}, fmt.Errorf("RESUME_OCR_ENABLED must be a boolean")
		}
		config.ResumeOCREnabled = enabled
	}
	if value := strings.TrimSpace(os.Getenv("SCREENING_WORKER_CONCURRENCY")); value != "" {
		concurrency, err := strconv.Atoi(value)
		if err != nil || concurrency < 1 || concurrency > 16 {
			return Config{}, fmt.Errorf("SCREENING_WORKER_CONCURRENCY must be between 1 and 16")
		}
		config.ScreeningConcurrency = concurrency
	}
	if value := strings.TrimSpace(os.Getenv("SCREENING_POLL_INTERVAL")); value != "" {
		interval, err := time.ParseDuration(value)
		if err != nil || interval < 250*time.Millisecond || interval > 5*time.Minute {
			return Config{}, fmt.Errorf("SCREENING_POLL_INTERVAL must be between 250ms and 5m")
		}
		config.ScreeningPollInterval = interval
	}
	if err := config.Validate(); err != nil {
		return Config{}, err
	}
	return config, nil
}

func (config Config) Validate() error {
	if config.SupabaseAnonKey == "" {
		return fmt.Errorf("SUPABASE_ANON_KEY is required")
	}
	if config.SupabaseSecretKey != "" || config.SupabaseServiceRoleKey != "" {
		if _, _, err := ResolveSupabasePrivilegedCredential(
			config.SupabaseSecretKey,
			config.SupabaseServiceRoleKey,
		); err != nil {
			return err
		}
	}
	parsedURL, err := url.Parse(config.SupabaseURL)
	if err != nil || parsedURL.Hostname() == "" {
		return fmt.Errorf("SUPABASE_URL must be an absolute URL")
	}
	if parsedURL.User != nil || parsedURL.RawQuery != "" || parsedURL.Fragment != "" {
		return fmt.Errorf("SUPABASE_URL must not contain credentials, a query, or a fragment")
	}

	if parsedURL.Scheme == "https" {
		return nil
	}
	if parsedURL.Scheme == "http" && isLoopback(parsedURL.Hostname()) {
		return nil
	}
	return fmt.Errorf("SUPABASE_URL must use HTTPS except for a loopback development URL")
}

func (config Config) ValidateEmail() error {
	if config.EmailProvider == "" && config.EmailAPIKey == "" &&
		config.EmailFromAddress == "" && config.EmailFromName == "" &&
		config.AppBaseURL == "" {
		return fmt.Errorf("email delivery is not configured")
	}
	switch strings.ToLower(config.EmailProvider) {
	case "smtp":
		if config.SMTPHost == "" {
			return fmt.Errorf("SMTP_HOST is required for the smtp provider")
		}
		if config.SMTPPort < 1 || config.SMTPPort > 65535 {
			return fmt.Errorf("SMTP_PORT must be a valid port number")
		}
		switch config.SMTPSecurity {
		case "", "starttls", "tls", "none":
		default:
			return fmt.Errorf("SMTP_SECURITY must be starttls, tls or none")
		}
		if (config.SMTPUsername == "") != (config.SMTPPassword == "") {
			return fmt.Errorf("SMTP_USERNAME and SMTP_PASSWORD must be set together")
		}
		if config.SMTPSecurity == "tls" && config.SMTPPort == 0 {
			return fmt.Errorf("SMTP_PORT is required")
		}
	case "resend":
		if config.EmailAPIKey == "" {
			return fmt.Errorf("EMAIL_API_KEY is required")
		}
	default:
		return fmt.Errorf("EMAIL_PROVIDER must be smtp or resend")
	}
	if err := validateAppBaseURL(config.AppBaseURL); err != nil {
		return err
	}
	if !validEmailAddress(config.EmailFromAddress) {
		return fmt.Errorf("EMAIL_FROM_ADDRESS must be a valid email address")
	}
	if config.EmailFromName == "" || len(config.EmailFromName) > 120 {
		return fmt.Errorf("EMAIL_FROM_NAME must contain 1 to 120 characters")
	}
	return nil
}

func validatePublicHTTPSURL(value, name string) error {
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" ||
		parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return fmt.Errorf("%s must be an absolute HTTPS URL without credentials, query, or fragment", name)
	}
	return nil
}

// validateAppBaseURL accepts an empty value, because links are only built when
// a notification is sent. HTTPS is required everywhere except loopback, so the
// worker can be run locally against `npm run dev`.
func validateAppBaseURL(value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Hostname() == "" || parsed.User != nil ||
		parsed.RawQuery != "" || parsed.Fragment != "" {
		return fmt.Errorf("APP_BASE_URL must be an absolute URL without credentials, query, or fragment")
	}
	if parsed.Scheme == "https" {
		return nil
	}
	host := parsed.Hostname()
	if parsed.Scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1") {
		return nil
	}
	return fmt.Errorf("APP_BASE_URL must use HTTPS; plain HTTP is only allowed on localhost")
}

func validEmailAddress(value string) bool {
	if len(value) < 3 || len(value) > 320 || strings.ContainsAny(value, "\r\n <>") {
		return false
	}
	at := strings.LastIndexByte(value, '@')
	return at > 0 && at < len(value)-1 && strings.Contains(value[at+1:], ".")
}

func ResolveSupabasePrivilegedCredential(secretKey, serviceRoleKey string) (string, SupabaseCredentialType, error) {
	secretKey = strings.TrimSpace(secretKey)
	if secretKey != "" {
		if !strings.HasPrefix(secretKey, "sb_secret_") || len(secretKey) == len("sb_secret_") {
			return "", "", fmt.Errorf("SUPABASE_SECRET_KEY must use the sb_secret_ key format")
		}
		return secretKey, SupabaseSecretCredential, nil
	}

	serviceRoleKey = strings.TrimSpace(serviceRoleKey)
	if serviceRoleKey == "" {
		return "", "", fmt.Errorf("SUPABASE_SECRET_KEY or SUPABASE_SERVICE_ROLE_KEY is required")
	}
	if !isServiceRoleJWT(serviceRoleKey) {
		return "", "", fmt.Errorf("SUPABASE_SERVICE_ROLE_KEY must be a service_role JWT")
	}
	return serviceRoleKey, SupabaseServiceRoleCredential, nil
}

func isServiceRoleJWT(value string) bool {
	parts := strings.Split(value, ".")
	if len(parts) != 3 || parts[0] == "" || parts[2] == "" {
		return false
	}

	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		payload, err = base64.URLEncoding.DecodeString(parts[1])
	}
	if err != nil {
		return false
	}
	var claims struct {
		Role string `json:"role"`
	}
	return json.Unmarshal(payload, &claims) == nil && claims.Role == "service_role"
}

func isLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
