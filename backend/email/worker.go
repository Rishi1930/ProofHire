package email

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/rishi1930/proofhire/backend/config"
)

type deliveryJob struct {
	ID             string `json:"id"`
	EmailType      string `json:"email_type"`
	RecipientEmail string `json:"recipient_email"`
	IdempotencyKey string `json:"idempotency_key"`
	LeaseToken     string `json:"lease_token"`
}

type deliveryContext struct {
	CandidateName string `json:"candidate_name"`
	JobTitle      string `json:"job_title"`
	CompanyName   string `json:"company_name"`
	Passed        bool   `json:"passed"`
}

type Worker struct {
	baseURL    string
	serviceKey string
	credential config.SupabaseCredentialType
	provider   Sender
	httpClient *http.Client
	logger     *slog.Logger
	workerID   string
	pollEvery  time.Duration
	appBaseURL string
}

func NewWorker(environment config.Config, logger *slog.Logger) (*Worker, error) {
	key, credential, err := config.ResolveSupabasePrivilegedCredential(
		environment.SupabaseSecretKey,
		environment.SupabaseServiceRoleKey,
	)
	if err != nil {
		return nil, errors.New("email worker requires a privileged Supabase credential")
	}
	if strings.TrimSpace(environment.SupabaseURL) == "" {
		return nil, errors.New("email worker requires SUPABASE_URL")
	}
	if logger == nil {
		logger = slog.Default()
	}
	worker := &Worker{
		baseURL:    strings.TrimRight(environment.SupabaseURL, "/"),
		serviceKey: key,
		credential: credential,
		httpClient: &http.Client{Timeout: 15 * time.Second},
		logger:     logger,
		workerID:   "proofhire-email-" + randomWorkerID(),
		pollEvery:  2 * time.Second,
		appBaseURL: strings.TrimRight(environment.AppBaseURL, "/"),
	}
	if err := environment.ValidateEmail(); err == nil {
		var sender Sender
		if strings.EqualFold(environment.EmailProvider, "smtp") {
			smtpSender, smtpErr := NewSMTPSender(environment)
			if smtpErr != nil {
				worker.logger.Warn("email delivery is disabled", "reason", smtpErr.Error())
			} else {
				sender = smtpSender
			}
		} else {
			provider, providerErr := NewClient(
				environment.EmailAPIKey,
				environment.EmailFromName+" <"+environment.EmailFromAddress+">",
			)
			if providerErr != nil {
				worker.logger.Warn("email delivery is disabled", "reason", providerErr.Error())
			} else {
				sender = provider
			}
		}
		worker.provider = sender
	} else {
		worker.logger.Warn("email delivery is disabled", "reason", err.Error())
	}
	return worker, nil
}

func (worker *Worker) Run(ctx context.Context) error {
	if err := worker.configureProvider(ctx); err != nil {
		worker.logger.Error("email delivery configuration could not be updated", "error", err)
	}
	ticker := time.NewTicker(worker.pollEvery)
	defer ticker.Stop()
	for {
		if worker.provider != nil {
			if err := worker.deliverOne(ctx); err != nil && !errors.Is(err, context.Canceled) {
				worker.logger.Error("email delivery job failed", "error", err)
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func (worker *Worker) configureProvider(ctx context.Context) error {
	available := worker.provider != nil
	var updated int
	if err := worker.call(ctx, "set_email_delivery_configuration", map[string]any{
		"target_available": available,
	}, &updated); err != nil {
		return err
	}
	return nil
}

func (worker *Worker) deliverOne(ctx context.Context) error {
	var jobs []deliveryJob
	if err := worker.call(ctx, "claim_email_delivery_jobs", map[string]any{
		"worker_id":     worker.workerID,
		"lease_seconds": 120,
	}, &jobs); err != nil {
		return err
	}
	if len(jobs) == 0 {
		return nil
	}
	job := jobs[0]
	if job.EmailType != "screening_result" {
		return worker.fail(ctx, job, "unsupported_email_type", false)
	}

	var data deliveryContext
	if err := worker.call(ctx, "get_email_delivery_context", map[string]any{
		"target_job_id":      job.ID,
		"target_lease_token": job.LeaseToken,
	}, &data); err != nil {
		return worker.fail(ctx, job, "email_context_unavailable", true)
	}
	rendered, err := RenderScreeningResult(ScreeningResult{
		CandidateName: data.CandidateName,
		JobTitle:      data.JobTitle,
		CompanyName:   data.CompanyName,
		Passed:        data.Passed,
	})
	if err != nil {
		return worker.fail(ctx, job, "email_context_invalid", false)
	}
	accepted, err := worker.provider.Send(ctx, Message{
		To:             job.RecipientEmail,
		Subject:        rendered.Subject,
		HTML:           rendered.HTML,
		Text:           rendered.Text,
		IdempotencyKey: job.IdempotencyKey,
	})
	if err != nil {
		var deliveryError *DeliveryError
		if errors.As(err, &deliveryError) {
			return worker.fail(ctx, job, deliveryError.Code, deliveryError.Retryable)
		}
		return worker.fail(ctx, job, "email_delivery_failed", false)
	}
	var completed string
	return worker.call(ctx, "complete_email_delivery_job", map[string]any{
		"target_job_id":              job.ID,
		"target_lease_token":         job.LeaseToken,
		"target_provider_message_id": accepted.MessageID,
	}, &completed)
}

func (worker *Worker) fail(ctx context.Context, job deliveryJob, code string, retryable bool) error {
	var status string
	return worker.call(ctx, "fail_email_delivery_job", map[string]any{
		"target_job_id":      job.ID,
		"target_lease_token": job.LeaseToken,
		"target_error_code":  code,
		"retryable":          retryable,
	}, &status)
}

func (worker *Worker) call(
	ctx context.Context,
	function string,
	payload any,
	result any,
) error {
	body, err := json.Marshal(payload)
	if err != nil {
		return errors.New("could not prepare email delivery request")
	}
	request, err := http.NewRequestWithContext(
		ctx,
		http.MethodPost,
		worker.baseURL+"/rest/v1/rpc/"+function,
		bytes.NewReader(body),
	)
	if err != nil {
		return errors.New("could not create email delivery request")
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("apikey", worker.serviceKey)
	if worker.credential == config.SupabaseServiceRoleCredential {
		request.Header.Set("Authorization", "Bearer "+worker.serviceKey)
	}
	response, err := worker.httpClient.Do(request)
	if err != nil {
		return errors.New("Supabase email delivery service is unavailable")
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
		return errors.New("Supabase email delivery request failed")
	}
	if result == nil || len(responseBody) == 0 {
		return nil
	}
	if err := json.Unmarshal(responseBody, result); err != nil {
		return errors.New("Supabase returned an invalid email delivery response")
	}
	return nil
}

func randomWorkerID() string {
	var data [8]byte
	if _, err := rand.Read(data[:]); err == nil {
		return hex.EncodeToString(data[:])
	}
	return strings.ReplaceAll(time.Now().UTC().Format("150405.000000000"), ".", "")
}
