package resume

import (
	"bytes"
	"context"
	"errors"
	"os"
	"strings"
	"testing"
)

// Screening must keep working on a machine that has no Poppler installed, so a
// PDF is read in process instead of through pdftotext.
func TestExtractPDFWithoutExternalTool(t *testing.T) {
	content, err := os.ReadFile("testdata/resume.pdf")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	extractor := NewExtractor(Options{})
	result, err := extractor.Extract(
		context.Background(),
		"resume.pdf",
		"application/pdf",
		bytes.NewReader(content),
	)
	if err != nil {
		t.Fatalf("extract without Poppler: %v", err)
	}

	for _, expected := range []string{"Rishi Raj Boora", "SUMMARY", "React", "EDUCATION"} {
		if !strings.Contains(result.Text, expected) {
			t.Fatalf("extracted text is missing %q:\n%s", expected, result.Text)
		}
	}
	if result.Format != "pdf" {
		t.Fatalf("format = %q, want pdf", result.Format)
	}
}

func TestExtractPDFWithoutConverterReportsActionableError(t *testing.T) {
	extractor := NewExtractor(Options{})
	_, err := extractor.Extract(
		context.Background(),
		"resume.pdf",
		"application/pdf",
		bytes.NewReader([]byte("%PDF-1.7 not really a pdf")),
	)
	// The built-in reader cannot parse it and no converter is installed, so the
	// actionable message is still "install Poppler".
	if !errors.Is(err, ErrToolUnavailable) {
		t.Fatalf("err = %v, want ErrToolUnavailable", err)
	}
}
