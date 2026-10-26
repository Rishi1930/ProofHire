package config

import "testing"

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
