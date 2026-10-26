package vercelhandler

import (
	"log/slog"
	"net/http"
	"os"

	"github.com/rishi1930/proofhire/backend/httpapi"
)

func Serve(writer http.ResponseWriter, request *http.Request) {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	handler, err := httpapi.NewHandlerFromEnvironment(logger)
	if err != nil {
		writer.Header().Set("Content-Type", "application/json; charset=utf-8")
		writer.Header().Set("Cache-Control", "no-store")
		writer.WriteHeader(http.StatusServiceUnavailable)
		_, _ = writer.Write([]byte("{\"error\":\"backend_not_configured\"}\n"))
		return
	}
	handler.ServeHTTP(writer, request)
}
