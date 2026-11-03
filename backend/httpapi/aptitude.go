package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/rishi1930/proofhire/backend/aptitude"
	"github.com/rishi1930/proofhire/backend/email"
	"github.com/rishi1930/proofhire/backend/supabaseauth"
)

var aptitudeUUID = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)

type createAptitudeInvitationRequest struct {
	WorkspaceID   string    `json:"workspace_id"`
	ApplicationID string    `json:"application_id"`
	VersionID     string    `json:"test_version_id"`
	ExpiresAt     time.Time `json:"expires_at"`
	MaxAttempts   int       `json:"max_attempts"`
}

type candidateSessionRequest struct {
	Token string `json:"token"`
}

type candidateAnswerRequest struct {
	Token      string          `json:"token"`
	AttemptID  string          `json:"attempt_id"`
	QuestionID string          `json:"question_id"`
	Answer     json.RawMessage `json:"answer"`
}

type candidateProgressRequest struct {
	Token         string          `json:"token"`
	AttemptID     string          `json:"attempt_id"`
	QuestionID    string          `json:"question_id"`
	QuestionIndex int             `json:"question_index"`
	Answer        json.RawMessage `json:"answer"`
}

type candidateSubmitRequest struct {
	Token     string `json:"token"`
	AttemptID string `json:"attempt_id"`
}

type candidateEventRequest struct {
	Token     string          `json:"token"`
	AttemptID string          `json:"attempt_id"`
	EventType string          `json:"event_type"`
	EventData json.RawMessage `json:"event_data"`
}

type emailDeliveryActionRequest struct {
	WorkspaceID string `json:"workspace_id"`
	Action      string `json:"action"`
	RequestID   string `json:"request_id"`
}

func (handler *apiHandler) createAptitudeInvitation(
	writer http.ResponseWriter,
	request *http.Request,
) {
	if handler.aptitude == nil {
		writeError(writer, http.StatusServiceUnavailable, "aptitude_service_unavailable")
		return
	}
	user, token, ok := handler.authenticatedUser(writer, request)
	if !ok {
		return
	}
	var input createAptitudeInvitationRequest
	if !decodeJSONBody(writer, request, &input, 16<<10) ||
		!aptitudeUUID.MatchString(input.WorkspaceID) ||
		!aptitudeUUID.MatchString(input.ApplicationID) ||
		!aptitudeUUID.MatchString(input.VersionID) ||
		input.MaxAttempts < 1 || input.MaxAttempts > 5 ||
		!input.ExpiresAt.After(time.Now()) {
		writeError(writer, http.StatusBadRequest, "invalid_invitation_request")
		return
	}
	role, err := handler.verifier.GetWorkspaceRole(
		request.Context(),
		token,
		user.ID,
		input.WorkspaceID,
	)
	if errors.Is(err, supabaseauth.ErrUnauthenticated) {
		writeError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	if errors.Is(err, supabaseauth.ErrForbidden) ||
		(err == nil && role != "owner" && role != "admin" && role != "recruiter") {
		writeError(writer, http.StatusForbidden, "workspace_access_denied")
		return
	}
	if err != nil {
		handler.logger.Error(
			"Supabase workspace authorization check failed",
			"request_id",
			requestIDFromContext(request.Context()),
		)
		writeError(writer, http.StatusBadGateway, "authorization_unavailable")
		return
	}

	invitation, rawToken, err := handler.aptitude.CreateInvitation(
		request.Context(),
		aptitude.InvitationInput{
			UserID:        user.ID,
			WorkspaceID:   input.WorkspaceID,
			ApplicationID: input.ApplicationID,
			VersionID:     input.VersionID,
			ExpiresAt:     input.ExpiresAt,
			MaxAttempts:   input.MaxAttempts,
		},
	)
	if err != nil {
		handler.logger.Error(
			"aptitude invitation creation failed",
			"request_id",
			requestIDFromContext(request.Context()),
		)
		writeError(writer, http.StatusBadGateway, "invitation_creation_failed")
		return
	}
	writeJSON(writer, http.StatusCreated, map[string]any{
		"invitation": invitation,
		"token":      rawToken,
		"delivery":   "queued",
	})
}

func (handler *apiHandler) getAptitudeCandidateSession(
	writer http.ResponseWriter,
	request *http.Request,
) {
	var input candidateSessionRequest
	if !decodeJSONBody(writer, request, &input, 8<<10) || len(input.Token) != 43 {
		writeError(writer, http.StatusBadRequest, "invalid_invitation")
		return
	}
	response, ok := handler.candidateRequest(
		writer,
		request,
		func() (json.RawMessage, error) {
			return handler.aptitude.CandidateSession(request.Context(), input.Token)
		},
	)
	if ok {
		writeJSON(writer, http.StatusOK, response)
	}
}

func (handler *apiHandler) startAptitudeCandidateAttempt(
	writer http.ResponseWriter,
	request *http.Request,
) {
	var input candidateSessionRequest
	if !decodeJSONBody(writer, request, &input, 8<<10) || len(input.Token) != 43 {
		writeError(writer, http.StatusBadRequest, "invalid_invitation")
		return
	}
	response, ok := handler.candidateRequest(
		writer,
		request,
		func() (json.RawMessage, error) {
			return handler.aptitude.StartAttempt(request.Context(), input.Token)
		},
	)
	if ok {
		writeJSON(writer, http.StatusOK, response)
	}
}

func (handler *apiHandler) saveAptitudeCandidateAnswer(
	writer http.ResponseWriter,
	request *http.Request,
) {
	if handler.aptitude == nil {
		writeError(writer, http.StatusServiceUnavailable, "aptitude_service_unavailable")
		return
	}
	var input candidateAnswerRequest
	if !decodeJSONBody(writer, request, &input, 16<<10) || len(input.Token) != 43 {
		writeError(writer, http.StatusBadRequest, "invalid_answer")
		return
	}
	if err := handler.aptitude.SaveAnswer(
		request.Context(),
		input.Token,
		input.AttemptID,
		input.QuestionID,
		input.Answer,
	); err != nil {
		handler.logAptitudeFailure(request, "aptitude answer could not be saved")
		writeError(writer, http.StatusBadGateway, "answer_save_failed")
		return
	}
	writeJSON(writer, http.StatusOK, map[string]bool{"saved": true})
}

func (handler *apiHandler) saveAptitudeCandidateProgress(
	writer http.ResponseWriter,
	request *http.Request,
) {
	if handler.aptitude == nil {
		writeError(writer, http.StatusServiceUnavailable, "aptitude_service_unavailable")
		return
	}
	var input candidateProgressRequest
	if !decodeJSONBody(writer, request, &input, 16<<10) ||
		len(input.Token) != 43 || input.QuestionIndex < 0 {
		writeError(writer, http.StatusBadRequest, "invalid_progress")
		return
	}
	if err := handler.aptitude.SaveProgress(
		request.Context(),
		input.Token,
		input.AttemptID,
		input.QuestionID,
		input.QuestionIndex,
		input.Answer,
	); err != nil {
		handler.logAptitudeFailure(request, "aptitude progress could not be saved")
		writeError(writer, http.StatusBadGateway, "progress_save_failed")
		return
	}
	writeJSON(writer, http.StatusOK, map[string]bool{"saved": true})
}

func (handler *apiHandler) submitAptitudeCandidateAttempt(
	writer http.ResponseWriter,
	request *http.Request,
) {
	var input candidateSubmitRequest
	if !decodeJSONBody(writer, request, &input, 8<<10) || len(input.Token) != 43 {
		writeError(writer, http.StatusBadRequest, "invalid_submission")
		return
	}
	response, ok := handler.candidateRequest(
		writer,
		request,
		func() (json.RawMessage, error) {
			return handler.aptitude.SubmitAttempt(
				request.Context(),
				input.Token,
				input.AttemptID,
			)
		},
	)
	if ok {
		writeJSON(writer, http.StatusOK, response)
	}
}

func (handler *apiHandler) recordAptitudeCandidateEvent(
	writer http.ResponseWriter,
	request *http.Request,
) {
	if handler.aptitude == nil {
		writeError(writer, http.StatusServiceUnavailable, "aptitude_service_unavailable")
		return
	}
	var input candidateEventRequest
	if !decodeJSONBody(writer, request, &input, 8<<10) || len(input.Token) != 43 {
		writeError(writer, http.StatusBadRequest, "invalid_monitoring_event")
		return
	}
	if err := handler.aptitude.RecordEvent(
		request.Context(),
		input.Token,
		input.AttemptID,
		input.EventType,
		input.EventData,
	); err != nil {
		handler.logAptitudeFailure(request, "aptitude monitoring event could not be recorded")
		writeError(writer, http.StatusBadGateway, "monitoring_event_failed")
		return
	}
	writeJSON(writer, http.StatusAccepted, map[string]bool{"recorded": true})
}

func (handler *apiHandler) requestEmailDeliveryAction(
	writer http.ResponseWriter,
	request *http.Request,
) {
	if handler.emailQueue == nil {
		writeError(writer, http.StatusServiceUnavailable, "email_delivery_unavailable")
		return
	}
	user, accessToken, ok := handler.authenticatedUser(writer, request)
	if !ok {
		return
	}
	var input emailDeliveryActionRequest
	if !decodeJSONBody(writer, request, &input, 8<<10) ||
		!aptitudeUUID.MatchString(input.WorkspaceID) ||
		!aptitudeUUID.MatchString(request.PathValue("jobID")) ||
		!aptitudeUUID.MatchString(input.RequestID) ||
		(input.Action != "send" && input.Action != "retry" && input.Action != "resend") {
		writeError(writer, http.StatusBadRequest, "invalid_email_delivery_action")
		return
	}
	role, err := handler.verifier.GetWorkspaceRole(
		request.Context(),
		accessToken,
		user.ID,
		input.WorkspaceID,
	)
	if errors.Is(err, supabaseauth.ErrUnauthenticated) {
		writeError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	if errors.Is(err, supabaseauth.ErrForbidden) ||
		(err == nil && role != "owner" && role != "admin" && role != "recruiter") {
		writeError(writer, http.StatusForbidden, "workspace_access_denied")
		return
	}
	if err != nil {
		handler.logger.Error(
			"Supabase workspace authorization check failed",
			"request_id",
			requestIDFromContext(request.Context()),
		)
		writeError(writer, http.StatusBadGateway, "authorization_unavailable")
		return
	}
	result, err := handler.emailQueue.RequestAction(
		request.Context(),
		user.ID,
		input.WorkspaceID,
		request.PathValue("jobID"),
		input.Action,
		input.RequestID,
	)
	if err != nil {
		handler.logger.Error(
			"email delivery action failed",
			"request_id",
			requestIDFromContext(request.Context()),
		)
		writeError(writer, http.StatusBadGateway, "email_delivery_action_failed")
		return
	}
	writeJSON(writer, http.StatusOK, result)
}

func (handler *apiHandler) resendWebhook(
	writer http.ResponseWriter,
	request *http.Request,
) {
	if handler.emailQueue == nil || handler.resendWebhookSecret == "" {
		writeError(writer, http.StatusServiceUnavailable, "email_webhook_unavailable")
		return
	}
	if request.ContentLength > 1<<20 {
		writeError(writer, http.StatusRequestEntityTooLarge, "invalid_provider_webhook")
		return
	}
	body, err := io.ReadAll(io.LimitReader(request.Body, (1<<20)+1))
	if err != nil || len(body) > 1<<20 {
		writeError(writer, http.StatusBadRequest, "invalid_provider_webhook")
		return
	}
	event, err := email.VerifyResendWebhook(
		handler.resendWebhookSecret,
		request.Header,
		body,
		time.Now(),
	)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "invalid_provider_webhook")
		return
	}
	if event.Message == "" {
		writer.WriteHeader(http.StatusNoContent)
		return
	}
	if err := handler.emailQueue.RecordProviderEvent(
		request.Context(),
		event.Message,
		event.Type,
	); err != nil {
		handler.logger.Error(
			"Resend delivery event could not be recorded",
			"request_id",
			requestIDFromContext(request.Context()),
		)
		writeError(writer, http.StatusBadGateway, "provider_webhook_record_failed")
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (handler *apiHandler) candidateRequest(
	writer http.ResponseWriter,
	request *http.Request,
	call func() (json.RawMessage, error),
) (json.RawMessage, bool) {
	if handler.aptitude == nil {
		writeError(writer, http.StatusServiceUnavailable, "aptitude_service_unavailable")
		return nil, false
	}
	response, err := call()
	if err != nil || len(response) == 0 || !json.Valid(response) {
		handler.logAptitudeFailure(request, "aptitude candidate request failed")
		writeError(writer, http.StatusBadGateway, "aptitude_session_unavailable")
		return nil, false
	}
	return response, true
}

func (handler *apiHandler) authenticatedUser(
	writer http.ResponseWriter,
	request *http.Request,
) (supabaseauth.User, string, bool) {
	token, ok := bearerToken(request.Header.Get("Authorization"))
	if !ok {
		writeError(writer, http.StatusUnauthorized, "unauthorized")
		return supabaseauth.User{}, "", false
	}
	user, err := handler.verifier.VerifyAccessToken(request.Context(), token)
	if errors.Is(err, supabaseauth.ErrUnauthenticated) {
		writeError(writer, http.StatusUnauthorized, "unauthorized")
		return supabaseauth.User{}, "", false
	}
	if err != nil || strings.TrimSpace(user.ID) == "" {
		handler.logger.Error(
			"Supabase authentication verification failed",
			"request_id",
			requestIDFromContext(request.Context()),
		)
		writeError(writer, http.StatusBadGateway, "authentication_unavailable")
		return supabaseauth.User{}, "", false
	}
	return user, token, true
}

func (handler *apiHandler) logAptitudeFailure(request *http.Request, message string) {
	handler.logger.Error(
		message,
		"request_id",
		requestIDFromContext(request.Context()),
	)
}

func decodeJSONBody(
	writer http.ResponseWriter,
	request *http.Request,
	target any,
	maxBytes int64,
) bool {
	request.Body = http.MaxBytesReader(writer, request.Body, maxBytes)
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return false
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return false
	}
	return true
}
