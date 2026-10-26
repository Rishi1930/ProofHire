package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"github.com/rishi1930/proofhire/backend/config"
	"github.com/rishi1930/proofhire/backend/supabaseauth"
)

type accessVerifier interface {
	VerifyAccessToken(ctx context.Context, accessToken string) (supabaseauth.User, error)
	GetWorkspaceRole(
		ctx context.Context,
		accessToken string,
		userID string,
		workspaceID string,
	) (string, error)
}

type apiHandler struct {
	verifier accessVerifier
	logger   *slog.Logger
}

func NewHandler(verifier accessVerifier, logger *slog.Logger) http.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	handler := &apiHandler{verifier: verifier, logger: logger}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", handler.health)
	mux.HandleFunc("GET /api/v1/me", handler.currentUser)
	mux.HandleFunc("GET /api/v1/workspace-access", handler.workspaceAccess)
	return handler.withRequestID(mux)
}

func NewHandlerFromEnvironment(logger *slog.Logger) (http.Handler, error) {
	environment, err := config.FromEnvironment()
	if err != nil {
		return nil, err
	}
	return NewHandler(supabaseauth.NewClient(environment), logger), nil
}

func (handler *apiHandler) health(writer http.ResponseWriter, _ *http.Request) {
	writeJSON(writer, http.StatusOK, map[string]string{"status": "ok"})
}

func (handler *apiHandler) currentUser(writer http.ResponseWriter, request *http.Request) {
	token, ok := bearerToken(request.Header.Get("Authorization"))
	if !ok {
		writeError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}

	user, err := handler.verifier.VerifyAccessToken(request.Context(), token)
	if errors.Is(err, supabaseauth.ErrUnauthenticated) {
		writeError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil || strings.TrimSpace(user.ID) == "" {
		requestID := requestIDFromContext(request.Context())
		handler.logger.Error(
			"Supabase authentication verification failed",
			"request_id",
			requestID,
		)
		writeError(writer, http.StatusBadGateway, "authentication_unavailable")
		return
	}

	writeJSON(writer, http.StatusOK, map[string]string{"id": user.ID})
}

func (handler *apiHandler) workspaceAccess(writer http.ResponseWriter, request *http.Request) {
	token, ok := bearerToken(request.Header.Get("Authorization"))
	if !ok {
		writeError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	workspaceIDs := request.URL.Query()["workspace_id"]
	if len(workspaceIDs) != 1 || strings.TrimSpace(workspaceIDs[0]) == "" {
		writeError(writer, http.StatusBadRequest, "workspace_id_required")
		return
	}

	user, err := handler.verifier.VerifyAccessToken(request.Context(), token)
	if errors.Is(err, supabaseauth.ErrUnauthenticated) {
		writeError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err != nil || strings.TrimSpace(user.ID) == "" {
		handler.logger.Error(
			"Supabase authentication verification failed",
			"request_id",
			requestIDFromContext(request.Context()),
		)
		writeError(writer, http.StatusBadGateway, "authentication_unavailable")
		return
	}

	role, err := handler.verifier.GetWorkspaceRole(
		request.Context(),
		token,
		user.ID,
		workspaceIDs[0],
	)
	if errors.Is(err, supabaseauth.ErrUnauthenticated) {
		writeError(writer, http.StatusUnauthorized, "unauthorized")
		return
	}
	if errors.Is(err, supabaseauth.ErrForbidden) {
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

	writeJSON(writer, http.StatusOK, map[string]string{
		"workspace_id": workspaceIDs[0],
		"role":         role,
	})
}

func (handler *apiHandler) withRequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requestID := request.Header.Get("X-Request-ID")
		if len(requestID) > 80 || strings.TrimSpace(requestID) != requestID {
			requestID = ""
		}
		for _, character := range requestID {
			if !(character >= 'a' && character <= 'z') &&
				!(character >= 'A' && character <= 'Z') &&
				!(character >= '0' && character <= '9') &&
				character != '-' && character != '_' {
				requestID = ""
				break
			}
		}
		if requestID == "" {
			requestID = newRequestID()
		}
		writer.Header().Set("X-Request-ID", requestID)
		writer.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(writer, request.WithContext(
			context.WithValue(request.Context(), requestIDContextKey{}, requestID),
		))
	})
}

type requestIDContextKey struct{}

func requestIDFromContext(ctx context.Context) string {
	requestID, _ := ctx.Value(requestIDContextKey{}).(string)
	return requestID
}

func newRequestID() string {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "unavailable"
	}
	return hex.EncodeToString(bytes[:])
}

func bearerToken(header string) (string, bool) {
	parts := strings.Fields(header)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || parts[1] == "" {
		return "", false
	}
	return parts[1], true
}

func writeJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

func writeError(writer http.ResponseWriter, status int, code string) {
	writeJSON(writer, status, map[string]string{"error": code})
}
