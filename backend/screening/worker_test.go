package screening

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/rishi1930/proofhire/backend/gemini"
	"github.com/rishi1930/proofhire/backend/resume"
)

const (
	testWorkspaceID   = "82ef1fb1-47c7-4c5e-8118-e78d33b58e1d"
	testJobID         = "1bfeb683-e931-4ce0-a555-f70f976f4a19"
	testApplicationID = "9ba0fef4-10e6-41f0-81aa-7ec52a7f9e77"
	testScreeningID   = "12345678-1234-1234-1234-123456789abc"
	testLeaseToken    = "abcdefab-cdef-abcd-efab-cdefabcdefab"
)

type fakeProvider struct {
	criteria   gemini.Criteria
	assessment gemini.Assessment
}

func (provider fakeProvider) Model() string {
	return "gemini-test"
}

func (provider fakeProvider) AnalyzeJob(context.Context, gemini.JobInput) (gemini.Result[gemini.Criteria], error) {
	return gemini.Result[gemini.Criteria]{
		Value: provider.criteria,
		Usage: gemini.Usage{InputTokens: 10, OutputTokens: 5},
	}, nil
}

func (provider fakeProvider) AssessCandidate(
	_ context.Context,
	_ gemini.Criteria,
	resumeText string,
) (gemini.Result[gemini.Assessment], error) {
	if !strings.Contains(resumeText, "Go service") {
		return gemini.Result[gemini.Assessment]{}, errors.New("resume text was not extracted")
	}
	if strings.Contains(resumeText, "Rishi Candidate") ||
		strings.Contains(resumeText, "rishi@example.test") ||
		strings.Contains(resumeText, "9876543210") {
		return gemini.Result[gemini.Assessment]{}, errors.New("personal identifiers were not redacted")
	}
	return gemini.Result[gemini.Assessment]{
		Value: provider.assessment,
		Usage: gemini.Usage{InputTokens: 20, OutputTokens: 8},
	}, nil
}

func TestProcessPersistsJobSpecificAssessment(t *testing.T) {
	resumeFile := makeTestDOCX(t, `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Rishi Candidate rishi@example.test 9876543210 Built a Go service</w:t></w:r></w:p></w:body></w:document>`)
	serviceRoleKey := legacyServiceRoleTestKey()
	var completed map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer "+serviceRoleKey ||
			request.Header.Get("apikey") != serviceRoleKey {
			t.Error("service role was not sent in server-side request headers")
		}
		switch {
		case request.Method == http.MethodGet && request.URL.Path == "/rest/v1/applications":
			writeRows(writer, []application{{
				ID:          testApplicationID,
				WorkspaceID: testWorkspaceID,
				JobID:       testJobID,
				CandidateID: "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae",
				ResumePath:  ptr(testWorkspaceID + "/" + testJobID + "/resume.docx"),
			}})
		case request.Method == http.MethodGet && request.URL.Path == "/rest/v1/candidates":
			writeRows(writer, []candidate{{
				ID:       "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae",
				FullName: "Rishi Candidate",
			}})
		case request.Method == http.MethodGet && request.URL.Path == "/rest/v1/jobs":
			writeRows(writer, []job{{
				ID:             testJobID,
				WorkspaceID:    testWorkspaceID,
				Title:          "Software Engineer",
				Description:    "Build backend services using Go.",
				RequiredSkills: []string{"Go"},
			}})
		case request.Method == http.MethodGet && request.URL.Path == "/rest/v1/job_screening_criteria":
			writeRows(writer, []cachedCriteria{})
		case request.Method == http.MethodGet && strings.HasPrefix(request.URL.Path, "/storage/v1/object/candidate-resumes/"):
			writer.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
			_, _ = writer.Write(resumeFile)
		case request.Method == http.MethodPost && request.URL.Path == "/rest/v1/rpc/complete_application_screening_job":
			if err := json.NewDecoder(request.Body).Decode(&completed); err != nil {
				t.Fatalf("Decode() completion request: %v", err)
			}
			_, _ = writer.Write([]byte(`"assessment-id"`))
		default:
			t.Errorf("unexpected request: %s %s", request.Method, request.URL.String())
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	provider := fakeProvider{
		criteria: gemini.Criteria{
			Summary: "Go backend role",
			Requirements: []gemini.Requirement{{
				Key: "go", Name: "Go", Description: "Build Go services",
				Priority: "essential", Category: "skill",
			}},
		},
		assessment: gemini.Assessment{
			Summary:        "Resume evidence supports the Go requirement.",
			Recommendation: "review",
			Confidence:     "high",
			Strengths:      []string{"Built a Go service"},
			Findings: []gemini.Finding{{
				RequirementKey: "go",
				Status:         "supported",
				Explanation:    "The project demonstrates the required skill.",
				Evidence:       []gemini.Evidence{{Excerpt: "Built a Go service", Source: "Projects"}},
				Confidence:     "high",
			}},
		},
	}
	worker, err := NewWorker(Options{
		SupabaseURL:            server.URL,
		SupabaseServiceRoleKey: serviceRoleKey,
		Provider:               provider,
		Extractor:              resume.NewExtractor(resume.Options{}),
		Logger:                 slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatalf("NewWorker() error = %v", err)
	}
	err = worker.process(context.Background(), screeningJob{
		ID:               testScreeningID,
		WorkspaceID:      testWorkspaceID,
		ApplicationID:    testApplicationID,
		InputFingerprint: strings.Repeat("a", 64),
		LeaseToken:       testLeaseToken,
	})
	if err != nil {
		t.Fatalf("process() error = %v", err)
	}
	if completed["target_match_score"] != float64(100) {
		t.Fatalf("score = %v, want 100", completed["target_match_score"])
	}
	if completed["target_input_tokens"] != float64(30) || completed["target_output_tokens"] != float64(13) {
		t.Fatalf("usage was not accumulated: %v %v", completed["target_input_tokens"], completed["target_output_tokens"])
	}
	var report assessmentEnvelope
	reportJSON, err := json.Marshal(completed["target_report"])
	if err != nil {
		t.Fatalf("Marshal() report: %v", err)
	}
	if err := json.Unmarshal(reportJSON, &report); err != nil {
		t.Fatalf("Unmarshal() report: %v", err)
	}
	if report.Summary != "Resume evidence supports the Go requirement." || report.EvidenceCoverage != 100 {
		t.Fatalf("unexpected assessment report: %+v", report)
	}
}

func TestProcessMissingResumeStopsBeforeStorageOrGemini(t *testing.T) {
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests++
		if request.Method != http.MethodGet || request.URL.Path != "/rest/v1/applications" {
			t.Errorf("unexpected request before resume check: %s %s", request.Method, request.URL.Path)
			writer.WriteHeader(http.StatusNotFound)
			return
		}
		writeRows(writer, []application{{
			ID:          testApplicationID,
			WorkspaceID: testWorkspaceID,
			JobID:       testJobID,
			CandidateID: "f3d2f2c1-f597-4a72-8e7d-8dfe814662ae",
		}})
	}))
	defer server.Close()

	worker, err := NewWorker(Options{
		SupabaseURL:            server.URL,
		SupabaseServiceRoleKey: legacyServiceRoleTestKey(),
		Provider:               fakeProvider{},
	})
	if err != nil {
		t.Fatalf("NewWorker() error = %v", err)
	}
	err = worker.process(context.Background(), screeningJob{
		ID:            testScreeningID,
		WorkspaceID:   testWorkspaceID,
		ApplicationID: testApplicationID,
		LeaseToken:    testLeaseToken,
	})
	if !errors.Is(err, ErrMissingResume) {
		t.Fatalf("process() error = %v, want ErrMissingResume", err)
	}
	if requests != 1 {
		t.Fatalf("request count = %d, want no storage or Gemini requests", requests)
	}
	if got := failureReason(err); got != "No resume is attached to this application. Upload a resume before requesting screening." {
		t.Fatalf("failureReason() = %q", got)
	}
	if got := failureCode(err); got != "missing_resume" {
		t.Fatalf("failureCode() = %q, want missing_resume", got)
	}
}

func TestWorkerCredentialHeadersForRESTAndStorage(t *testing.T) {
	tests := []struct {
		name       string
		secretKey  string
		serviceKey string
		wantAPIKey string
		wantBearer string
	}{
		{
			name:       "new secret",
			secretKey:  "sb_secret_worker-test",
			wantAPIKey: "sb_secret_worker-test",
		},
		{
			name:       "legacy service role JWT",
			serviceKey: legacyServiceRoleTestKey(),
			wantAPIKey: legacyServiceRoleTestKey(),
			wantBearer: "Bearer " + legacyServiceRoleTestKey(),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				if request.Header.Get("apikey") != test.wantAPIKey {
					t.Errorf("apikey header did not contain the selected credential")
				}
				if request.Header.Get("Authorization") != test.wantBearer {
					t.Errorf("Authorization header did not match the selected credential format")
				}
				switch {
				case strings.HasPrefix(request.URL.Path, "/rest/v1/"):
					writer.Header().Set("Content-Type", "application/json")
					_, _ = writer.Write([]byte(`[]`))
				case strings.HasPrefix(request.URL.Path, "/storage/v1/object/"):
					writer.Header().Set("Content-Type", "application/pdf")
					_, _ = writer.Write([]byte("resume"))
				default:
					t.Errorf("unexpected request path %q", request.URL.Path)
					writer.WriteHeader(http.StatusNotFound)
				}
			}))
			defer server.Close()

			worker, err := NewWorker(Options{
				SupabaseURL:            server.URL,
				SupabaseSecretKey:      test.secretKey,
				SupabaseServiceRoleKey: test.serviceKey,
				Provider:               fakeProvider{},
			})
			if err != nil {
				t.Fatalf("NewWorker() error = %v", err)
			}
			if _, err := worker.selectRows(context.Background(), "applications", url.Values{}); err != nil {
				t.Fatalf("selectRows() error = %v", err)
			}
			if _, _, err := worker.downloadResume(
				context.Background(),
				testWorkspaceID+"/"+testJobID+"/resume.pdf",
			); err != nil {
				t.Fatalf("downloadResume() error = %v", err)
			}
		})
	}
}

func TestWorkerErrorsDoNotExposeSupabaseCredentials(t *testing.T) {
	const secretKey = "sb_secret_do-not-leak"
	var logs bytes.Buffer
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		http.Error(writer, secretKey, http.StatusInternalServerError)
	}))
	defer server.Close()

	worker, err := NewWorker(Options{
		SupabaseURL:       server.URL,
		SupabaseSecretKey: secretKey,
		Provider:          fakeProvider{},
		Logger:            slog.New(slog.NewTextHandler(&logs, nil)),
	})
	if err != nil {
		t.Fatalf("NewWorker() error = %v", err)
	}
	_, requestErr := worker.selectRows(context.Background(), "applications", url.Values{})
	if requestErr == nil {
		t.Fatal("selectRows() should fail for an upstream error")
	}
	if strings.Contains(requestErr.Error(), secretKey) || strings.Contains(logs.String(), secretKey) {
		t.Fatal("Supabase secret key was exposed in an error or log")
	}
}

func legacyServiceRoleTestKey() string {
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"role":"service_role"}`))
	return "eyJhbGciOiJub25lIn0." + payload + ".signature"
}

func TestWorkerRejectsCrossJobResumePath(t *testing.T) {
	if validResumePath(testWorkspaceID+"/"+testJobID+"/resume.pdf", testWorkspaceID, testJobID) != true {
		t.Fatal("expected scoped resume path to be accepted")
	}
	if validResumePath(testWorkspaceID+"/"+testApplicationID+"/resume.pdf", testWorkspaceID, testJobID) {
		t.Fatal("resume path from another job should be rejected")
	}
	if validResumePath(testWorkspaceID+"/"+testJobID+"/../resume.pdf", testWorkspaceID, testJobID) {
		t.Fatal("path traversal should be rejected")
	}
}

func TestNewWorkerRequiresPrivilegedCredential(t *testing.T) {
	_, err := NewWorker(Options{
		SupabaseURL: "https://project.supabase.co",
		Provider:    fakeProvider{},
	})
	if err == nil || !strings.Contains(err.Error(), "SUPABASE_SECRET_KEY") {
		t.Fatalf("NewWorker() error = %v, want missing privileged credential error", err)
	}
}

func writeRows[T any](writer http.ResponseWriter, rows []T) {
	writer.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(writer).Encode(rows)
}

func makeTestDOCX(t *testing.T, document string) []byte {
	t.Helper()
	var content bytes.Buffer
	writer := zip.NewWriter(&content)
	types, err := writer.Create("[Content_Types].xml")
	if err != nil {
		t.Fatal(err)
	}
	_, err = io.WriteString(types, `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>`)
	if err != nil {
		t.Fatal(err)
	}
	documentFile, err := writer.Create("word/document.xml")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.WriteString(documentFile, document); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	return content.Bytes()
}

func ptr(value string) *string {
	return &value
}
