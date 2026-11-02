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
	GeminiAPIKey           string
	GeminiModel            string
	ResumeOCREnabled       bool
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
		GeminiAPIKey:           strings.TrimSpace(os.Getenv("GEMINI_API_KEY")),
		GeminiModel:            strings.TrimSpace(os.Getenv("GEMINI_MODEL")),
		ScreeningConcurrency:   1,
		ScreeningPollInterval:  2 * time.Second,
	}
	if config.GeminiModel == "" {
		config.GeminiModel = "gemini-3.8-flash"
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
	if config.GeminiModel != "" && !isGeminiModelName(config.GeminiModel) {
		return fmt.Errorf("GEMINI_MODEL must be a model name without a URL path")
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

func isGeminiModelName(value string) bool {
	if len(value) < 1 || len(value) > 120 {
		return false
	}
	for _, character := range value {
		if !((character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			character == '.' || character == '_' || character == '-') {
			return false
		}
	}
	return true
}

func isLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
