package config

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func TestFromEnvironmentDefaultsScreeningConfiguration(t *testing.T) {
	t.Setenv("SUPABASE_URL", "https://project.supabase.co")
	t.Setenv("SUPABASE_ANON_KEY", "public-key")
	t.Setenv("SUPABASE_SECRET_KEY", "")
	t.Setenv("SUPABASE_SERVICE_ROLE_KEY", "")
	t.Setenv("RESUME_OCR_ENABLED", "")
	t.Setenv("SCREENING_WORKER_CONCURRENCY", "")
	t.Setenv("SCREENING_POLL_INTERVAL", "")

	environment, err := FromEnvironment()
	if err != nil {
		t.Fatalf("FromEnvironment() error = %v", err)
	}
	if environment.ScreeningConcurrency != 1 || environment.ScreeningPollInterval != 2*time.Second {
		t.Fatalf("unexpected worker defaults: %+v", environment)
	}
	if environment.SupabaseSecretKey != "" ||
		environment.SupabaseServiceRoleKey != "" ||
		environment.ResumeOCREnabled {
		t.Fatalf("optional settings have unexpected defaults: %+v", environment)
	}
}

func TestFromEnvironmentPrefersSupabaseSecretKey(t *testing.T) {
	t.Setenv("SUPABASE_URL", "https://project.supabase.co")
	t.Setenv("SUPABASE_ANON_KEY", "public-key")
	t.Setenv("SUPABASE_SECRET_KEY", "sb_secret_new-key")
	t.Setenv("SUPABASE_SERVICE_ROLE_KEY", legacyServiceRoleJWT())

	environment, err := FromEnvironment()
	if err != nil {
		t.Fatalf("FromEnvironment() error = %v", err)
	}
	key, kind, err := ResolveSupabasePrivilegedCredential(
		environment.SupabaseSecretKey,
		environment.SupabaseServiceRoleKey,
	)
	if err != nil {
		t.Fatalf("ResolveSupabasePrivilegedCredential() error = %v", err)
	}
	if key != "sb_secret_new-key" || kind != SupabaseSecretCredential {
		t.Fatalf("selected credential = (%q, %q), want new secret key", key, kind)
	}
}

func TestFromEnvironmentRejectsInvalidWorkerConfiguration(t *testing.T) {
	t.Setenv("SUPABASE_URL", "https://project.supabase.co")
	t.Setenv("SUPABASE_ANON_KEY", "public-key")
	t.Setenv("SUPABASE_SECRET_KEY", "")
	t.Setenv("SUPABASE_SERVICE_ROLE_KEY", "")
	t.Setenv("SCREENING_WORKER_CONCURRENCY", "17")
	t.Setenv("SCREENING_POLL_INTERVAL", "10ms")

	if _, err := FromEnvironment(); err == nil {
		t.Fatal("invalid worker concurrency should be rejected")
	}
	t.Setenv("SCREENING_WORKER_CONCURRENCY", "1")
	if _, err := FromEnvironment(); err == nil {
		t.Fatal("poll interval below the minimum should be rejected")
	}
}

func TestEmailConfigurationRequiresCompleteResendSettings(t *testing.T) {
	tests := []struct {
		name      string
		config    Config
		wantError bool
	}{
		{
			name: "email disabled",
			config: Config{
				SupabaseURL: "https://project.supabase.co", SupabaseAnonKey: "public-key",
			},
			wantError: true,
		},
		{
			name: "valid Resend configuration",
			config: Config{
				SupabaseURL: "https://project.supabase.co", SupabaseAnonKey: "public-key",
				EmailProvider: "resend", EmailAPIKey: "re_test", EmailFromAddress: "team@example.com",
				EmailFromName: "ProofHire",
			},
		},
		{
			name: "missing API key",
			config: Config{
				SupabaseURL: "https://project.supabase.co", SupabaseAnonKey: "public-key",
				EmailProvider: "resend", EmailFromAddress: "team@example.com",
				EmailFromName: "ProofHire",
			},
			wantError: true,
		},
		{
			name: "unsupported provider",
			config: Config{
				SupabaseURL: "https://project.supabase.co", SupabaseAnonKey: "public-key",
				EmailProvider: "smtp",
			},
			wantError: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := test.config.ValidateEmail()
			if (err != nil) != test.wantError {
				t.Fatalf("Validate() error = %v, wantError %v", err, test.wantError)
			}
		})
	}
}

func TestResolveSupabasePrivilegedCredential(t *testing.T) {
	validLegacyKey := legacyServiceRoleJWT()
	tests := []struct {
		name       string
		secretKey  string
		serviceKey string
		wantKey    string
		wantKind   SupabaseCredentialType
		wantError  bool
	}{
		{
			name:      "new secret",
			secretKey: "sb_secret_new-key",
			wantKey:   "sb_secret_new-key",
			wantKind:  SupabaseSecretCredential,
		},
		{
			name:       "legacy service role JWT",
			serviceKey: validLegacyKey,
			wantKey:    validLegacyKey,
			wantKind:   SupabaseServiceRoleCredential,
		},
		{
			name:       "new secret takes precedence",
			secretKey:  "sb_secret_preferred",
			serviceKey: "not-a-jwt",
			wantKey:    "sb_secret_preferred",
			wantKind:   SupabaseSecretCredential,
		},
		{
			name:      "missing",
			wantError: true,
		},
		{
			name:       "new key in legacy variable rejected",
			serviceKey: "sb_secret_misclassified",
			wantError:  true,
		},
		{
			name:       "legacy key in new variable rejected",
			secretKey:  validLegacyKey,
			serviceKey: validLegacyKey,
			wantError:  true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			key, kind, err := ResolveSupabasePrivilegedCredential(test.secretKey, test.serviceKey)
			if (err != nil) != test.wantError {
				t.Fatalf("ResolveSupabasePrivilegedCredential() error = %v, wantError %v", err, test.wantError)
			}
			if err == nil && (key != test.wantKey || kind != test.wantKind) {
				t.Fatalf("credential = (%q, %q), want (%q, %q)", key, kind, test.wantKey, test.wantKind)
			}
			if err != nil && ((test.secretKey != "" && strings.Contains(err.Error(), test.secretKey)) ||
				(test.serviceKey != "" && strings.Contains(err.Error(), test.serviceKey))) {
				t.Fatalf("error exposed a credential: %v", err)
			}
		})
	}
}

func TestValidate(t *testing.T) {
	tests := []struct {
		name      string
		config    Config
		wantError bool
	}{
		{
			name:   "production HTTPS",
			config: Config{SupabaseURL: "https://project.supabase.co", SupabaseAnonKey: "public-key"},
		},
		{
			name:   "local HTTP",
			config: Config{SupabaseURL: "http://127.0.0.1:54321", SupabaseAnonKey: "public-key"},
		},
		{
			name: "new secret",
			config: Config{
				SupabaseURL:       "https://project.supabase.co",
				SupabaseAnonKey:   "public-key",
				SupabaseSecretKey: "sb_secret_new-key",
			},
		},
		{
			name: "legacy service-role JWT",
			config: Config{
				SupabaseURL:            "https://project.supabase.co",
				SupabaseAnonKey:        "public-key",
				SupabaseServiceRoleKey: legacyServiceRoleJWT(),
			},
		},
		{
			name: "new secret takes precedence over legacy value",
			config: Config{
				SupabaseURL:            "https://project.supabase.co",
				SupabaseAnonKey:        "public-key",
				SupabaseSecretKey:      "sb_secret_preferred",
				SupabaseServiceRoleKey: "not-a-jwt",
			},
		},
		{
			name: "misclassified new secret",
			config: Config{
				SupabaseURL:       "https://project.supabase.co",
				SupabaseAnonKey:   "public-key",
				SupabaseSecretKey: "not-a-secret-key",
			},
			wantError: true,
		},
		{
			name:      "remote HTTP rejected",
			config:    Config{SupabaseURL: "http://supabase.example.test", SupabaseAnonKey: "public-key"},
			wantError: true,
		},
		{
			name:      "missing key",
			config:    Config{SupabaseURL: "https://project.supabase.co"},
			wantError: true,
		},
		{
			name: "URL credentials rejected",
			config: Config{
				SupabaseURL:     "https://user:password@project.supabase.co",
				SupabaseAnonKey: "public-key",
			},
			wantError: true,
		},
		{
			name: "URL query rejected",
			config: Config{
				SupabaseURL:     "https://project.supabase.co?token=secret",
				SupabaseAnonKey: "public-key",
			},
			wantError: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := test.config.Validate()
			if (err != nil) != test.wantError {
				t.Fatalf("Validate() error = %v, wantError %v", err, test.wantError)
			}
		})
	}
}

func legacyServiceRoleJWT() string {
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"role":"service_role"}`))
	return "eyJhbGciOiJub25lIn0." + payload + ".signature"
}
