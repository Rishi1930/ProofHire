package config

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
)

type Config struct {
	SupabaseURL     string
	SupabaseAnonKey string
}

func FromEnvironment() (Config, error) {
	config := Config{
		SupabaseURL:     strings.TrimSpace(os.Getenv("SUPABASE_URL")),
		SupabaseAnonKey: strings.TrimSpace(os.Getenv("SUPABASE_ANON_KEY")),
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

func isLoopback(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
