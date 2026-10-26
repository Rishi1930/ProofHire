package main

import (
	"net/http"

	"github.com/rishi1930/proofhire/backend/vercelhandler"
)

func Handler(writer http.ResponseWriter, request *http.Request) {
	vercelhandler.Serve(writer, request)
}
