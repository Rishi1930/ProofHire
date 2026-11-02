package resume

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

const docxMIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

func TestExtractDOCX(t *testing.T) {
	input := makeDOCX(t, `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Experienced engineer</w:t></w:r></w:p><w:p><w:r><w:t>Go and PostgreSQL</w:t></w:r></w:p></w:body></w:document>`)

	result, err := NewExtractor(Options{}).Extract(
		context.Background(),
		"candidate.docx",
		docxMIME,
		bytes.NewReader(input),
	)
	if err != nil {
		t.Fatalf("Extract() error = %v", err)
	}
	if result.Text != "Experienced engineer\nGo and PostgreSQL" {
		t.Fatalf("text = %q", result.Text)
	}
	if result.Format != "docx" || result.Version != extractionVersion || len(result.SHA256) != 64 {
		t.Fatalf("unexpected result metadata: %+v", result)
	}
}

func TestExtractPDFUsesBoundedConverter(t *testing.T) {
	extractor := NewExtractor(Options{Tools: Tools{PDFToText: "pdftotext-test"}})
	extractor.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name != "pdftotext-test" || len(args) != 5 {
			t.Fatalf("unexpected command: %q %v", name, args)
		}
		return []byte("  Resume text\n"), nil
	}

	result, err := extractor.Extract(
		context.Background(),
		"candidate.pdf",
		"application/pdf",
		strings.NewReader("%PDF-1.7"),
	)
	if err != nil {
		t.Fatalf("Extract() error = %v", err)
	}
	if result.Text != "Resume text" || result.Format != "pdf" {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestExtractDOCUsesAntiword(t *testing.T) {
	extractor := NewExtractor(Options{Tools: Tools{Antiword: "antiword-test"}})
	extractor.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		if name != "antiword-test" || len(args) != 1 {
			t.Fatalf("unexpected command: %q %v", name, args)
		}
		return []byte("Legacy Word resume"), nil
	}

	result, err := extractor.Extract(
		context.Background(),
		"candidate.doc",
		"application/msword",
		bytes.NewReader([]byte{0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1}),
	)
	if err != nil {
		t.Fatalf("Extract() error = %v", err)
	}
	if result.Text != "Legacy Word resume" {
		t.Fatalf("text = %q", result.Text)
	}
}

func TestExtractRejectsInvalidInputs(t *testing.T) {
	tests := []struct {
		name        string
		filename    string
		contentType string
		content     []byte
		options     Options
		want        error
	}{
		{
			name:        "unsupported extension",
			filename:    "candidate.rtf",
			contentType: "application/rtf",
			content:     []byte("resume"),
			want:        ErrUnsupportedFormat,
		},
		{
			name:        "mime mismatch",
			filename:    "candidate.pdf",
			contentType: "application/msword",
			content:     []byte("%PDF-1.7"),
			want:        ErrMIMETypeMismatch,
		},
		{
			name:        "invalid signature",
			filename:    "candidate.pdf",
			contentType: "application/pdf",
			content:     []byte("not a PDF"),
			want:        ErrInvalidDocument,
		},
		{
			name:        "empty",
			filename:    "candidate.pdf",
			contentType: "application/pdf",
			want:        ErrEmptyFile,
		},
		{
			name:        "oversized",
			filename:    "candidate.pdf",
			contentType: "application/pdf",
			content:     []byte("%PDF-1.7"),
			options:     Options{MaxFileBytes: 4},
			want:        ErrFileTooLarge,
		},
		{
			name:        "corrupt DOCX",
			filename:    "candidate.docx",
			contentType: docxMIME,
			content:     []byte("PK\x03\x04corrupt"),
			want:        ErrInvalidDocument,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := NewExtractor(test.options).Extract(
				context.Background(),
				test.filename,
				test.contentType,
				bytes.NewReader(test.content),
			)
			if !errors.Is(err, test.want) {
				t.Fatalf("error = %v, want errors.Is(_, %v)", err, test.want)
			}
		})
	}
}

func TestExtractReportsMissingConverter(t *testing.T) {
	extractor := NewExtractor(Options{})
	extractor.options.Tools.PDFToText = ""
	_, err := extractor.Extract(
		context.Background(),
		"candidate.pdf",
		"application/pdf",
		strings.NewReader("%PDF-1.7"),
	)
	if !errors.Is(err, ErrToolUnavailable) {
		t.Fatalf("error = %v, want missing-tool error", err)
	}
}

func TestExtractClassifiesMissingConfiguredConverter(t *testing.T) {
	extractor := NewExtractor(Options{
		Tools: Tools{PDFToText: "proofhire-definitely-not-installed-cmd"},
	})
	_, err := extractor.Extract(
		context.Background(),
		"candidate.pdf",
		"application/pdf",
		strings.NewReader("%PDF-1.7"),
	)
	if !errors.Is(err, ErrToolUnavailable) {
		t.Fatalf("error = %v, want missing-tool error", err)
	}
}

func TestExtractTimesOut(t *testing.T) {
	extractor := NewExtractor(Options{
		Timeout: 5 * time.Millisecond,
		Tools:   Tools{PDFToText: "pdftotext-test"},
	})
	extractor.run = func(ctx context.Context, _ string, _ ...string) ([]byte, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	_, err := extractor.Extract(
		context.Background(),
		"candidate.pdf",
		"application/pdf",
		strings.NewReader("%PDF-1.7"),
	)
	if !errors.Is(err, ErrExtractionTimeout) {
		t.Fatalf("error = %v, want extraction timeout", err)
	}
}

func TestExtractRejectsOversizedText(t *testing.T) {
	extractor := NewExtractor(Options{
		MaxTextBytes: 4,
		Tools:        Tools{PDFToText: "pdftotext-test"},
	})
	extractor.run = func(context.Context, string, ...string) ([]byte, error) {
		return []byte("too much text"), nil
	}
	_, err := extractor.Extract(
		context.Background(),
		"candidate.pdf",
		"application/pdf",
		strings.NewReader("%PDF-1.7"),
	)
	if !errors.Is(err, ErrOutputTooLarge) {
		t.Fatalf("error = %v, want output-too-large", err)
	}
}

func TestExtractRejectsEmptyDOCX(t *testing.T) {
	input := makeDOCX(t, `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p/></w:body></w:document>`)
	_, err := NewExtractor(Options{}).Extract(
		context.Background(),
		"candidate.docx",
		docxMIME,
		bytes.NewReader(input),
	)
	if !errors.Is(err, ErrNoText) {
		t.Fatalf("error = %v, want no text", err)
	}
}

func TestExtractOCRScannedPDF(t *testing.T) {
	extractor := NewExtractor(Options{
		EnableOCR: true,
		Tools: Tools{
			PDFToText: "pdftotext-test",
			PDFInfo:   "pdfinfo-test",
			PDFToPPM:  "pdftoppm-test",
			Tesseract: "tesseract-test",
		},
	})
	extractor.run = func(_ context.Context, name string, args ...string) ([]byte, error) {
		switch name {
		case "pdftotext-test":
			return []byte(" \n"), nil
		case "pdfinfo-test":
			return []byte("Pages: 2\n"), nil
		case "pdftoppm-test":
			prefix := args[len(args)-1]
			for _, number := range []string{"1", "2"} {
				if err := os.WriteFile(prefix+"-"+number+".png", []byte("image"), 0o600); err != nil {
					t.Fatalf("WriteFile() error = %v", err)
				}
			}
			return nil, nil
		case "tesseract-test":
			return []byte("Scanned resume"), nil
		default:
			t.Fatalf("unexpected command: %q", name)
			return nil, nil
		}
	}

	result, err := extractor.Extract(
		context.Background(),
		"candidate.pdf",
		"application/pdf",
		strings.NewReader("%PDF-1.7"),
	)
	if err != nil {
		t.Fatalf("Extract() error = %v", err)
	}
	if result.Text != "Scanned resume\nScanned resume" {
		t.Fatalf("OCR text = %q", result.Text)
	}
}

func TestExtractOCREnforcesPageLimit(t *testing.T) {
	extractor := NewExtractor(Options{
		EnableOCR:   true,
		OCRMaxPages: 1,
		Tools: Tools{
			PDFToText: "pdftotext-test",
			PDFInfo:   "pdfinfo-test",
			PDFToPPM:  "pdftoppm-test",
			Tesseract: "tesseract-test",
		},
	})
	extractor.run = func(_ context.Context, name string, _ ...string) ([]byte, error) {
		switch name {
		case "pdftotext-test":
			return nil, nil
		case "pdfinfo-test":
			return []byte("Pages: 2\n"), nil
		default:
			t.Fatalf("unexpected command: %q", name)
			return nil, nil
		}
	}

	_, err := extractor.Extract(
		context.Background(),
		"candidate.pdf",
		"application/pdf",
		strings.NewReader("%PDF-1.7"),
	)
	if !errors.Is(err, ErrPageLimit) {
		t.Fatalf("error = %v, want OCR page-limit error", err)
	}
}

func makeDOCX(t *testing.T, document string) []byte {
	t.Helper()
	var content bytes.Buffer
	writer := zip.NewWriter(&content)
	contentTypes, err := writer.Create("[Content_Types].xml")
	if err != nil {
		t.Fatalf("Create() content types error = %v", err)
	}
	if _, err := io.WriteString(contentTypes, `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>`); err != nil {
		t.Fatalf("WriteString() content types error = %v", err)
	}
	file, err := writer.Create("word/document.xml")
	if err != nil {
		t.Fatalf("Create() error = %v", err)
	}
	if _, err := io.WriteString(file, document); err != nil {
		t.Fatalf("WriteString() error = %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	return content.Bytes()
}
