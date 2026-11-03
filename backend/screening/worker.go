package screening

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/rishi1930/proofhire/backend/config"
	"github.com/rishi1930/proofhire/backend/resume"
	"github.com/rishi1930/proofhire/backend/screeningengine"
)

const (
	maxStorageDownloadBytes = resume.DefaultMaxFileBytes
	claimLeaseSeconds       = 600
)

var safeUUID = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)
var safeResumeFilename = regexp.MustCompile(`^[A-Za-z0-9_-]+\.(pdf|doc|docx)$`)
var emailPattern = regexp.MustCompile(`(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b`)
var phonePattern = regexp.MustCompile(`(?:\+?\d[\d(). -]{7,}\d)`)

var (
	ErrSuperseded    = errors.New("screening inputs changed while the job was processing")
	ErrMissingResume = errors.New("application has no attached resume")
)

type Options struct {
	SupabaseURL            string
	SupabaseSecretKey      string
	SupabaseServiceRoleKey string
	Extractor              *resume.Extractor
	Concurrency            int
	PollInterval           time.Duration
	HTTPClient             *http.Client
	Logger                 *slog.Logger
}

type Worker struct {
	baseURL               string
	serviceKey            string
	serviceCredentialType config.SupabaseCredentialType
	extractor             *resume.Extractor
	concurrency           int
	pollInterval          time.Duration
	httpClient            *http.Client
	logger                *slog.Logger
}

type screeningJob struct {
	ID               string `json:"id"`
	WorkspaceID      string `json:"workspace_id"`
	ApplicationID    string `json:"application_id"`
	InputFingerprint string `json:"input_fingerprint"`
	Attempts         int    `json:"attempts"`
	LeaseToken       string `json:"lease_token"`
}

type application struct {
	ID          string  `json:"id"`
	WorkspaceID string  `json:"workspace_id"`
	JobID       string  `json:"job_id"`
	CandidateID string  `json:"candidate_id"`
	ResumePath  *string `json:"resume_path"`
}

type candidate struct {
	ID       string `json:"id"`
	FullName string `json:"full_name"`
}

type job struct {
	ID                         string                       `json:"id"`
	WorkspaceID                string                       `json:"workspace_id"`
	Title                      string                       `json:"title"`
	Department                 string                       `json:"department"`
	Description                string                       `json:"description"`
	RequiredSkills             []string                     `json:"required_skills"`
	PreferredSkills            []string                     `json:"preferred_skills"`
	MinimumExperience          *float64                     `json:"minimum_experience"`
	MinimumScreeningPercentage *float64                     `json:"minimum_screening_percentage"`
	ScreeningWeights           screeningengine.WeightConfig `json:"screening_weights"`
	EmploymentType             string                       `json:"employment_type"`
	WorkplaceType              string                       `json:"workplace_type"`
}

type configuredRequirement struct {
	ID          string  `json:"id"`
	Key         string  `json:"requirement_key"`
	Name        string  `json:"name"`
	Description string  `json:"description"`
	Priority    string  `json:"priority"`
	Category    string  `json:"category"`
	Weight      float64 `json:"weight"`
}

type serviceError struct {
	StatusCode int
	retryable  bool
}

func (serviceError *serviceError) Error() string {
	return "Supabase screening operation failed"
}

func NewWorker(options Options) (*Worker, error) {
	if strings.TrimSpace(options.SupabaseURL) == "" {
		return nil, errors.New("SUPABASE_URL is required for the screening worker")
	}
	serviceKey, credentialType, err := config.ResolveSupabasePrivilegedCredential(
		options.SupabaseSecretKey,
		options.SupabaseServiceRoleKey,
	)
	if err != nil {
		return nil, err
	}
	if options.Concurrency <= 0 {
		options.Concurrency = 1
	}
	if options.Concurrency > 16 {
		return nil, errors.New("screening worker concurrency must not exceed 16")
	}
	if options.PollInterval <= 0 {
		options.PollInterval = 2 * time.Second
	}
	if options.PollInterval < 250*time.Millisecond {
		return nil, errors.New("screening worker poll interval must be at least 250ms")
	}
	if options.Extractor == nil {
		options.Extractor = resume.NewExtractor(resume.Options{})
	}
	if options.HTTPClient == nil {
		options.HTTPClient = &http.Client{Timeout: 30 * time.Second}
	}
	if options.Logger == nil {
		options.Logger = slog.Default()
	}
	return &Worker{
		baseURL:               strings.TrimRight(options.SupabaseURL, "/"),
		serviceKey:            serviceKey,
		serviceCredentialType: credentialType,
		extractor:             options.Extractor,
		concurrency:           options.Concurrency,
		pollInterval:          options.PollInterval,
		httpClient:            options.HTTPClient,
		logger:                options.Logger,
	}, nil
}

func (worker *Worker) Run(ctx context.Context) error {
	if ctx == nil {
		return errors.New("worker context is required")
	}
	if _, err := worker.rpc(ctx, "resume_application_screening_jobs", map[string]any{}); err != nil {
		return fmt.Errorf("resume queued screening work: %w", err)
	}

	var workers sync.WaitGroup
	for index := 0; index < worker.concurrency; index++ {
		workers.Add(1)
		go func(workerIndex int) {
			defer workers.Done()
			worker.runLoop(ctx, workerIndex)
		}(index)
	}
	workers.Wait()
	return ctx.Err()
}

func (worker *Worker) runLoop(ctx context.Context, workerIndex int) {
	workerID := fmt.Sprintf("screening-%d-%d", time.Now().UnixNano(), workerIndex)
	for {
		if ctx.Err() != nil {
			return
		}
		job, err := worker.claim(ctx, workerID)
		if err != nil {
			worker.logger.Error("could not claim screening job", "error", err)
			if !worker.wait(ctx, worker.pollInterval) {
				return
			}
			continue
		}
		if job == nil {
			if !worker.wait(ctx, worker.pollInterval) {
				return
			}
			continue
		}
		if err := worker.process(ctx, *job); err != nil {
			if errors.Is(err, ErrSuperseded) {
				worker.logger.Info("screening job superseded by newer inputs", "screening_job_id", job.ID)
				continue
			}
			worker.logger.Error(
				"screening job failed",
				"screening_job_id", job.ID,
				"error_code", failureCode(err),
			)
			if failErr := worker.fail(ctx, *job, err); failErr != nil {
				worker.logger.Error(
					"could not persist screening failure",
					"screening_job_id", job.ID,
					"error", failErr,
				)
			}
			continue
		}
		worker.logger.Info("screening job completed", "screening_job_id", job.ID)
	}
}

func (worker *Worker) claim(ctx context.Context, workerID string) (*screeningJob, error) {
	response, err := worker.rpc(ctx, "claim_application_screening_job", map[string]any{
		"worker_id":     workerID,
		"lease_seconds": claimLeaseSeconds,
	})
	if err != nil {
		return nil, err
	}
	var jobs []screeningJob
	if err := json.Unmarshal(response, &jobs); err != nil {
		return nil, fmt.Errorf("decode screening job claim: %w", err)
	}
	if len(jobs) == 0 {
		return nil, nil
	}
	if len(jobs) != 1 || !validID(jobs[0].ID) || !validID(jobs[0].WorkspaceID) ||
		!validID(jobs[0].ApplicationID) || !validID(jobs[0].LeaseToken) {
		return nil, errors.New("Supabase returned an invalid screening job")
	}
	return &jobs[0], nil
}

func (worker *Worker) process(ctx context.Context, queueJob screeningJob) error {
	applications, err := worker.selectRows(ctx, "applications", url.Values{
		"select": {"id,workspace_id,job_id,candidate_id,resume_path"},
		"id":     {"eq." + queueJob.ApplicationID},
		"limit":  {"1"},
	})
	if err != nil {
		return err
	}
	var appRows []application
	if err := json.Unmarshal(applications, &appRows); err != nil {
		return fmt.Errorf("decode screening application: %w", err)
	}
	if len(appRows) != 1 {
		return errors.New("screening application was not found")
	}
	app := appRows[0]
	if app.ID != queueJob.ApplicationID || app.WorkspaceID != queueJob.WorkspaceID ||
		!validID(app.JobID) || !validID(app.CandidateID) {
		return errors.New("screening application does not have a valid resume")
	}
	if app.ResumePath == nil || strings.TrimSpace(*app.ResumePath) == "" {
		return ErrMissingResume
	}

	candidateBody, err := worker.selectRows(ctx, "candidates", url.Values{
		"select":       {"id,full_name"},
		"id":           {"eq." + app.CandidateID},
		"workspace_id": {"eq." + queueJob.WorkspaceID},
		"limit":        {"1"},
	})
	if err != nil {
		return err
	}
	var candidateRows []candidate
	if err := json.Unmarshal(candidateBody, &candidateRows); err != nil {
		return fmt.Errorf("decode screening candidate: %w", err)
	}
	if len(candidateRows) != 1 || candidateRows[0].ID != app.CandidateID {
		return errors.New("screening candidate was not found in the application workspace")
	}

	jobBody, err := worker.selectRows(ctx, "jobs", url.Values{
		"select":       {"id,workspace_id,title,department,description,required_skills,preferred_skills,minimum_experience,minimum_screening_percentage,screening_weights,employment_type,workplace_type"},
		"id":           {"eq." + app.JobID},
		"workspace_id": {"eq." + queueJob.WorkspaceID},
		"limit":        {"1"},
	})
	if err != nil {
		return err
	}
	var jobRows []job
	if err := json.Unmarshal(jobBody, &jobRows); err != nil {
		return fmt.Errorf("decode screening job: %w", err)
	}
	if len(jobRows) != 1 || jobRows[0].ID != app.JobID ||
		jobRows[0].WorkspaceID != queueJob.WorkspaceID {
		return errors.New("screening job was not found in the application workspace")
	}
	currentJob := jobRows[0]
	weights := currentJob.ScreeningWeights
	if weights.Mandatory == 0 {
		weights.Mandatory = 2
	}
	if weights.Preferred == 0 {
		weights.Preferred = 1
	}
	if weights.Experience == 0 {
		weights.Experience = weights.Mandatory
	}
	configuredRows, err := worker.selectRows(ctx, "job_screening_requirements", url.Values{
		"select":       {"id,requirement_key,name,description,priority,category,weight"},
		"workspace_id": {"eq." + app.WorkspaceID},
		"job_id":       {"eq." + currentJob.ID},
		"is_active":    {"eq.true"},
		"order":        {"created_at.asc"},
	})
	if err != nil {
		return err
	}
	var configured []configuredRequirement
	if err := json.Unmarshal(configuredRows, &configured); err != nil {
		return fmt.Errorf("decode configured screening requirements: %w", err)
	}
	requirements := make([]screeningengine.Requirement, 0,
		len(currentJob.RequiredSkills)+len(currentJob.PreferredSkills)+len(configured)+1)
	for index, skill := range currentJob.RequiredSkills {
		skill = strings.TrimSpace(skill)
		if skill == "" {
			continue
		}
		requirements = append(requirements, screeningengine.Requirement{
			Key: fmt.Sprintf("required-skill-%d", index+1), Name: skill,
			Priority: "mandatory", Category: "skill", Weight: weights.Mandatory,
		})
	}
	for index, skill := range currentJob.PreferredSkills {
		skill = strings.TrimSpace(skill)
		if skill == "" {
			continue
		}
		requirements = append(requirements, screeningengine.Requirement{
			Key: fmt.Sprintf("preferred-skill-%d", index+1), Name: skill,
			Priority: "preferred", Category: "skill", Weight: weights.Preferred,
		})
	}
	if currentJob.MinimumExperience != nil && *currentJob.MinimumExperience > 0 {
		requirements = append(requirements, screeningengine.Requirement{
			Key: "minimum-experience", Name: fmt.Sprintf("%g years experience", *currentJob.MinimumExperience),
			Description: strconv.FormatFloat(*currentJob.MinimumExperience, 'f', -1, 64),
			Priority:    "mandatory", Category: "experience", Weight: weights.Experience,
		})
	}
	for _, requirement := range configured {
		requirements = append(requirements, screeningengine.Requirement{
			Key: requirement.Key, Name: requirement.Name, Description: requirement.Description,
			Priority: requirement.Priority, Category: requirement.Category, Weight: requirement.Weight,
		})
	}

	resumePath := *app.ResumePath
	if !validResumePath(resumePath, app.WorkspaceID, currentJob.ID) {
		return errors.New("resume storage path does not match the application")
	}
	resumeContent, contentType, err := worker.downloadResume(ctx, resumePath)
	if err != nil {
		return err
	}
	result, err := worker.extractor.Extract(
		ctx,
		path.Base(resumePath),
		contentType,
		bytes.NewReader(resumeContent),
	)
	if err != nil {
		return err
	}
	resumeText := redactPersonalIdentifiers(result.Text, candidateRows[0].FullName)

	threshold := 70.0
	if currentJob.MinimumScreeningPercentage != nil {
		threshold = *currentJob.MinimumScreeningPercentage
	}
	assessment, err := screeningengine.Assess(
		resumeText,
		requirements,
		weights,
		threshold,
		time.Now().UTC(),
	)
	if err != nil {
		return fmt.Errorf("evaluate deterministic screening requirements: %w", err)
	}
	assessment.Report.ResumeFormat = result.Format
	assessment.Report.ResumeSHA256 = result.SHA256
	criteriaRequirements := make([]map[string]any, 0, len(requirements))
	for _, requirement := range requirements {
		criteriaRequirements = append(criteriaRequirements, map[string]any{
			"key":         requirement.Key,
			"name":        requirement.Name,
			"description": requirement.Description,
			"priority":    requirement.Priority,
			"category":    requirement.Category,
			"weight":      requirement.Weight,
		})
	}
	criteriaJSON, err := json.Marshal(map[string]any{
		"summary": "Requirements configured by the recruiter and evaluated with deterministic resume evidence matching.",
		"experience_mandatory": currentJob.MinimumExperience != nil &&
			*currentJob.MinimumExperience > 0,
		"clarifications":    []string{},
		"requirements":      criteriaRequirements,
		"weighting":         weights,
		"engine_version":    screeningengine.Version,
		"minimum_threshold": threshold,
	})
	if err != nil {
		return fmt.Errorf("encode screening criteria: %w", err)
	}
	criteriaFingerprint, err := fingerprint(json.RawMessage(criteriaJSON))
	if err != nil {
		return fmt.Errorf("fingerprint screening criteria: %w", err)
	}
	reportJSON, err := json.Marshal(assessment.Report)
	if err != nil {
		return fmt.Errorf("encode screening assessment: %w", err)
	}
	var scoreValue any
	if assessment.Score != nil {
		scoreValue = *assessment.Score
	}
	completion, err := worker.rpc(ctx, "complete_application_screening_job", map[string]any{
		"target_job_id":               queueJob.ID,
		"target_lease_token":          queueJob.LeaseToken,
		"target_criteria_fingerprint": criteriaFingerprint,
		"target_criteria":             json.RawMessage(criteriaJSON),
		"target_report":               json.RawMessage(reportJSON),
		"target_match_score":          scoreValue,
		"target_model":                screeningengine.Version,
	})
	if err != nil {
		return err
	}
	if bytes.Equal(bytes.TrimSpace(completion), []byte("null")) {
		return ErrSuperseded
	}
	return nil
}

func (worker *Worker) downloadResume(ctx context.Context, resumePath string) ([]byte, string, error) {
	escapedPath := escapeStoragePath(resumePath)
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodGet,
		worker.baseURL+"/storage/v1/object/candidate-resumes/"+escapedPath,
		nil,
	)
	if err != nil {
		return nil, "", fmt.Errorf("create resume download request: %w", err)
	}
	worker.setServiceHeaders(request)
	response, err := worker.httpClient.Do(request)
	if err != nil {
		return nil, "", &serviceError{retryable: true}
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, "", &serviceError{
			StatusCode: response.StatusCode,
			retryable:  retryableStatus(response.StatusCode),
		}
	}
	content, err := io.ReadAll(io.LimitReader(response.Body, maxStorageDownloadBytes+1))
	if err != nil {
		return nil, "", &serviceError{StatusCode: response.StatusCode, retryable: true}
	}
	if int64(len(content)) > maxStorageDownloadBytes {
		return nil, "", resume.ErrFileTooLarge
	}
	return content, response.Header.Get("Content-Type"), nil
}

func (worker *Worker) fail(ctx context.Context, job screeningJob, cause error) error {
	var serviceFailure *serviceError
	retryable := errors.Is(cause, resume.ErrExtractionTimeout) ||
		errors.Is(cause, context.DeadlineExceeded)
	if errors.As(cause, &serviceFailure) {
		retryable = serviceFailure.retryable
	}
	failureCode := failureCode(cause)
	reason := failureReason(cause)
	_, err := worker.rpc(ctx, "fail_application_screening_job", map[string]any{
		"target_job_id":         job.ID,
		"target_lease_token":    job.LeaseToken,
		"target_error_code":     failureCode,
		"target_failure_reason": reason,
		"retryable":             retryable,
	})
	return err
}

func (worker *Worker) rpc(ctx context.Context, name string, payload any) (json.RawMessage, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("encode Supabase RPC payload: %w", err)
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		worker.baseURL+"/rest/v1/rpc/"+name,
		bytes.NewReader(body),
	)
	if err != nil {
		return nil, fmt.Errorf("create Supabase RPC request: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	worker.setServiceHeaders(request)
	return worker.doJSON(request)
}

func (worker *Worker) selectRows(ctx context.Context, table string, query url.Values) (json.RawMessage, error) {
	requestURL := worker.baseURL + "/rest/v1/" + table + "?" + query.Encode()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, requestURL, nil)
	if err != nil {
		return nil, fmt.Errorf("create Supabase query: %w", err)
	}
	worker.setServiceHeaders(request)
	return worker.doJSON(request)
}

func (worker *Worker) doJSON(request *http.Request) (json.RawMessage, error) {
	response, err := worker.httpClient.Do(request)
	if err != nil {
		return nil, &serviceError{retryable: true}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 2<<20))
	if err != nil {
		return nil, &serviceError{StatusCode: response.StatusCode, retryable: true}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, &serviceError{
			StatusCode: response.StatusCode,
			retryable:  retryableStatus(response.StatusCode),
		}
	}
	if len(body) == 0 {
		return json.RawMessage("null"), nil
	}
	if !json.Valid(body) {
		return nil, errors.New("Supabase returned invalid JSON")
	}
	return json.RawMessage(body), nil
}

func (worker *Worker) setServiceHeaders(request *http.Request) {
	request.Header.Set("apikey", worker.serviceKey)
	if worker.serviceCredentialType == config.SupabaseServiceRoleCredential {
		request.Header.Set("Authorization", "Bearer "+worker.serviceKey)
	}
}

func (worker *Worker) wait(ctx context.Context, duration time.Duration) bool {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func fingerprint(value any) (string, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(encoded)
	return hex.EncodeToString(sum[:]), nil
}

func validResumePath(value, workspaceID, jobID string) bool {
	parts := strings.Split(value, "/")
	if len(parts) != 3 || parts[0] != workspaceID || parts[1] != jobID {
		return false
	}
	filename := parts[2]
	extension := strings.ToLower(path.Ext(filename))
	if !safeResumeFilename.MatchString(filename) {
		return false
	}
	return extension == ".pdf" || extension == ".doc" || extension == ".docx"
}

func escapeStoragePath(value string) string {
	parts := strings.Split(value, "/")
	for index, part := range parts {
		parts[index] = url.PathEscape(part)
	}
	return strings.Join(parts, "/")
}

func redactPersonalIdentifiers(value, fullName string) string {
	if strings.TrimSpace(fullName) != "" {
		pattern := regexp.MustCompile(
			`(?i)(?:^|[^\p{L}\p{N}])` + regexp.QuoteMeta(strings.TrimSpace(fullName)) +
				`(?:$|[^\p{L}\p{N}])`,
		)
		value = pattern.ReplaceAllString(value, "[candidate name]")
	}
	value = emailPattern.ReplaceAllString(value, "[redacted email]")
	return phonePattern.ReplaceAllString(value, "[redacted phone]")
}

func validID(value string) bool {
	return safeUUID.MatchString(value)
}

func retryableStatus(status int) bool {
	return status == http.StatusRequestTimeout ||
		status == http.StatusTooManyRequests ||
		status == http.StatusBadGateway ||
		status == http.StatusServiceUnavailable ||
		status == http.StatusGatewayTimeout ||
		status >= 500
}

func failureCode(err error) string {
	var storageFailure *serviceError
	if errors.As(err, &storageFailure) {
		if storageFailure.StatusCode >= 400 {
			return fmt.Sprintf("supabase_http_%d", storageFailure.StatusCode)
		}
		return "supabase_unavailable"
	}
	switch {
	case errors.Is(err, ErrMissingResume):
		return "missing_resume"
	case errors.Is(err, resume.ErrToolUnavailable):
		return "document_tool_unavailable"
	case errors.Is(err, resume.ErrExtractionTimeout), errors.Is(err, context.DeadlineExceeded):
		return "extraction_timeout"
	case errors.Is(err, resume.ErrInvalidDocument):
		return "invalid_resume"
	case errors.Is(err, resume.ErrNoText):
		return "no_extractable_text"
	default:
		return "screening_failed"
	}
}

func failureReason(err error) string {
	switch {
	case errors.Is(err, ErrMissingResume):
		return "No resume is attached to this application. Upload a resume before requesting screening."
	case errors.Is(err, resume.ErrToolUnavailable):
		return err.Error()
	case errors.Is(err, resume.ErrExtractionTimeout):
		return "Resume extraction timed out; retry is available."
	case errors.Is(err, resume.ErrInvalidDocument):
		return "The stored resume could not be read as a valid document."
	case errors.Is(err, resume.ErrNoText):
		return "No text could be extracted. The resume may be scanned or empty."
	case errors.Is(err, resume.ErrFileTooLarge):
		return "The stored resume exceeds the supported file size."
	case errors.Is(err, resume.ErrUnsupportedFormat):
		return "The stored resume format is not supported."
	case errors.Is(err, resume.ErrMIMETypeMismatch):
		return "The stored resume extension and MIME type do not match."
	default:
		var storageFailure *serviceError
		if errors.As(err, &storageFailure) {
			if storageFailure.StatusCode == http.StatusNotFound ||
				storageFailure.StatusCode == http.StatusForbidden {
				return "The stored resume is unavailable to the screening worker."
			}
			return "A temporary database or storage service error occurred."
		}
		return "Screening could not be completed. Review the worker logs using the screening job ID."
	}
}
