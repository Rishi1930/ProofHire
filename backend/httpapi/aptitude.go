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
		"delivery":   "manual",
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
