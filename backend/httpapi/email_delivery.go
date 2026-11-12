package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/rishi1930/proofhire/backend/email"
	"github.com/rishi1930/proofhire/backend/supabaseauth"
)

var emailDeliveryUUID = regexp.MustCompile(
	`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`,
)

type emailDeliveryActionRequest struct {
	WorkspaceID string `json:"workspace_id"`
	Action      string `json:"action"`
	RequestID   string `json:"request_id"`
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
		!emailDeliveryUUID.MatchString(input.WorkspaceID) ||
		!emailDeliveryUUID.MatchString(request.PathValue("jobID")) ||
		!emailDeliveryUUID.MatchString(input.RequestID) ||
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
	return decoder.Decode(&trailing) == io.EOF
}
