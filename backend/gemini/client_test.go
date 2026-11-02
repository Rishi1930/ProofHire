package gemini

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestAnalyzeAndAssessUseStructuredOutput(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		calls.Add(1)
		if request.Method != http.MethodPost || request.URL.Path != "/models/gemini-test:generateContent" {
			t.Errorf("unexpected request %s %s", request.Method, request.URL.Path)
		}
		if request.Header.Get("x-goog-api-key") != "test-secret" {
			t.Error("API key was not sent in the request header")
		}
		if request.URL.Query().Has("key") {
			t.Error("API key must not be sent in the URL")
		}
		var body map[string]any
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Fatalf("Decode() request error = %v", err)
		}
		generation, ok := body["generationConfig"].(map[string]any)
		if !ok || generation["responseMimeType"] != "application/json" || generation["responseSchema"] == nil {
			t.Errorf("request does not use a structured JSON response: %v", body["generationConfig"])
		}

		var response string
		if calls.Load() == 1 {
			response = `{"summary":"Software role","requirements":[{"key":"go","name":"Go","description":"Demonstrated Go","priority":"essential","category":"skill"}],"clarifications":[],"experience_mandatory":false}`
		} else {
			response = `{"summary":"Project evidence supports the requirement.","recommendation":"review","confidence":"medium","strengths":["Built a Go service"],"potential_gaps":[],"missing_evidence":[],"follow_up_questions":[],"findings":[{"requirement_key":"go","status":"supported","explanation":"A project demonstrates Go.","evidence":[{"excerpt":"Built a Go service","source":"Projects"}],"confidence":"medium"}]}`
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"candidates":[{"content":{"parts":[{"text":` + mustJSON(response) + `}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":101,"candidatesTokenCount":44}}`))
	}))
	defer server.Close()

	client := NewClient("test-secret", "gemini-test", WithBaseURL(server.URL))
	criteria, err := client.AnalyzeJob(context.Background(), JobInput{
		Title:       "Software engineer",
		Description: "Build Go services.",
	})
	if err != nil {
		t.Fatalf("AnalyzeJob() error = %v", err)
	}
	if criteria.Value.Requirements[0].Key != "go" || criteria.Usage.InputTokens != 101 {
		t.Fatalf("unexpected criteria response: %+v", criteria)
	}

	assessment, err := client.AssessCandidate(context.Background(), criteria.Value, "Built a Go service")
	if err != nil {
		t.Fatalf("AssessCandidate() error = %v", err)
	}
	if assessment.Value.Findings[0].Status != "supported" || assessment.Usage.OutputTokens != 44 {
		t.Fatalf("unexpected assessment response: %+v", assessment)
	}
	if calls.Load() != 2 {
		t.Fatalf("call count = %d, want 2", calls.Load())
	}
}

func TestProviderRetriesRateLimitOnlyWithinBound(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) < 3 {
			writer.WriteHeader(http.StatusTooManyRequests)
			return
		}
		_, _ = writer.Write([]byte(`{"candidates":[{"content":{"parts":[{"text":"{\"summary\":\"No criteria\",\"requirements\":[],\"clarifications\":[\"Clarify role\"],\"experience_mandatory\":false}"}]},"finishReason":"STOP"}]}`))
	}))
	defer server.Close()
	client := NewClient("key", "model", WithBaseURL(server.URL))
	client.sleep = func(context.Context, time.Duration) error { return nil }
	result, err := client.AnalyzeJob(context.Background(), JobInput{Title: "Role"})
	if err != nil {
		t.Fatalf("AnalyzeJob() error = %v", err)
	}
	if len(result.Value.Requirements) != 0 || len(result.Value.Clarifications) != 1 {
		t.Fatalf("unexpected criteria: %+v", result.Value)
	}
	if calls.Load() != 3 {
		t.Fatalf("call count = %d, want three attempts", calls.Load())
	}
}

func TestProviderDoesNotRetryPermanentErrors(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		writer.WriteHeader(http.StatusBadRequest)
	}))
	defer server.Close()
	client := NewClient("key", "model", WithBaseURL(server.URL))
	client.sleep = func(context.Context, time.Duration) error { return nil }
	_, err := client.AnalyzeJob(context.Background(), JobInput{Title: "Role"})
	if err == nil || IsRetryable(err) {
		t.Fatalf("error = %v, want permanent provider error", err)
	}
	if calls.Load() != 1 {
		t.Fatalf("call count = %d, want 1", calls.Load())
	}
}

func TestValidationRejectsInventedEvidenceAndUnknownRequirements(t *testing.T) {
	criteria := Criteria{Requirements: []Requirement{{
		Key: "sql", Name: "SQL", Priority: "essential", Category: "skill",
	}}}
	assessment := Assessment{
		Summary:        "Candidate has SQL experience.",
		Recommendation: "review",
		Confidence:     "medium",
		Findings: []Finding{{
			RequirementKey: "sql",
			Status:         "supported",
			Explanation:    "The resume states SQL experience.",
			Confidence:     "medium",
			Evidence:       []Evidence{{Excerpt: "Expert SQL developer", Source: "Skills"}},
		}},
	}
	if err := ValidateAssessment(criteria, assessment, "Some unrelated resume text"); err == nil {
		t.Fatal("invented evidence should be rejected")
	}
	assessment.Findings[0].RequirementKey = "unknown"
	if err := ValidateAssessment(criteria, assessment, "Expert SQL developer"); err == nil {
		t.Fatal("unknown requirement should be rejected")
	}
}

func TestMissingEvidenceDoesNotBecomeARequirementFailure(t *testing.T) {
	criteria := Criteria{
		ExperienceMandatory: false,
		Requirements: []Requirement{
			{Key: "project", Name: "Project use", Priority: "essential", Category: "responsibility"},
			{Key: "industry", Name: "Industry experience", Priority: "preferred", Category: "experience"},
		},
	}
	assessment := Assessment{
		Findings: []Finding{
			{RequirementKey: "project", Status: "supported"},
			{RequirementKey: "industry", Status: "evidence_missing"},
		},
	}
	score, coverage := CalculateScore(criteria, assessment)
	if score == nil || *score != 100 || coverage < 66.6 || coverage > 66.7 {
		t.Fatalf("score = %v, coverage = %v", score, coverage)
	}
}

func TestEmptyAssessmentScoreIsNotFabricated(t *testing.T) {
	score, coverage := CalculateScore(Criteria{}, Assessment{})
	if score != nil || coverage != 0 {
		t.Fatalf("score = %v, coverage = %v; want nil, 0", score, coverage)
	}
}

func TestMissingAPIKeyFailsExplicitly(t *testing.T) {
	client := NewClient("", "")
	_, err := client.AnalyzeJob(context.Background(), JobInput{Title: "Role"})
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("error = %v, want ErrNotConfigured", err)
	}
}

func TestVerifyModelRequiresGenerateContentSupport(t *testing.T) {
	tests := []struct {
		name        string
		status      int
		response    string
		wantErrCode string
	}{
		{
			name:     "available generation model",
			status:   http.StatusOK,
			response: `{"name":"models/gemini-test","supportedGenerationMethods":["generateContent"]}`,
		},
		{
			name:        "model not found",
			status:      http.StatusNotFound,
			response:    `{"error":"not found"}`,
			wantErrCode: "model_unavailable",
		},
		{
			name:        "model does not support generation",
			status:      http.StatusOK,
			response:    `{"name":"models/gemini-test","supportedGenerationMethods":["embedContent"]}`,
			wantErrCode: "model_does_not_support_generate_content",
		},
		{
			name:        "invalid metadata",
			status:      http.StatusOK,
			response:    `{`,
			wantErrCode: "Gemini model metadata is invalid",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if request.Method != http.MethodGet ||
					request.URL.Path != "/models/gemini-test" {
					t.Errorf("unexpected model verification request %s %s", request.Method, request.URL.Path)
				}
				if request.Header.Get("x-goog-api-key") != "test-secret" ||
					request.URL.Query().Has("key") {
					t.Error("API key must only be sent in the request header")
				}
				writer.WriteHeader(test.status)
				_, _ = writer.Write([]byte(test.response))
			}))
			defer server.Close()

			client := NewClient(
				"test-secret",
				"gemini-test",
				WithBaseURL(server.URL),
			)
			err := client.VerifyModel(context.Background())
			if test.wantErrCode == "" {
				if err != nil {
					t.Fatalf("VerifyModel() error = %v", err)
				}
				return
			}
			if err == nil {
				t.Fatal("VerifyModel() error = nil")
			}
			var providerError *ProviderError
			if errors.As(err, &providerError) {
				if providerError.Code != test.wantErrCode {
					t.Fatalf("error code = %q, want %q", providerError.Code, test.wantErrCode)
				}
				return
			}
			if err.Error() != test.wantErrCode {
				t.Fatalf("error = %q, want %q", err, test.wantErrCode)
			}
		})
	}
}

func mustJSON(value string) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return string(encoded)
}
