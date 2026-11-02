package resume

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"mime"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	DefaultMaxFileBytes = 5 << 20
	DefaultMaxTextBytes = 1 << 20
	DefaultTimeout      = 30 * time.Second
	extractionVersion   = "1"
	wordNamespace       = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
	contentTypesNS      = "http://schemas.openxmlformats.org/package/2006/content-types"
	documentContentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
	maxDOCXEntries      = 2000
	maxDOCXExpandedSize = 64 << 20
	maxDOCXEntrySize    = 20 << 20
	maxCompressionRatio = 200
)

var (
	ErrEmptyFile         = errors.New("resume file is empty")
	ErrFileTooLarge      = errors.New("resume file exceeds the configured size limit")
	ErrUnsupportedFormat = errors.New("resume format is not supported")
	ErrMIMETypeMismatch  = errors.New("resume extension and MIME type do not match")
	ErrInvalidDocument   = errors.New("resume document is invalid or corrupt")
	ErrNoText            = errors.New("resume contains no extractable text")
	ErrToolUnavailable   = errors.New("required document processing tool is unavailable")
	ErrExtractionTimeout = errors.New("resume extraction timed out")
	ErrOutputTooLarge    = errors.New("extracted resume text exceeds the configured size limit")
	ErrPageLimit         = errors.New("scanned PDF exceeds the configured OCR page limit")
)

type Tools struct {
	PDFToText string
	PDFInfo   string
	PDFToPPM  string
	Tesseract string
	Antiword  string
}

type Options struct {
	MaxFileBytes int64
	MaxTextBytes int
	Timeout      time.Duration
	EnableOCR    bool
	OCRMaxPages  int
	Tools        Tools
}

type Result struct {
	Text    string `json:"text"`
	SHA256  string `json:"sha256"`
	Format  string `json:"format"`
	Version string `json:"version"`
}

type Extractor struct {
	options Options
	run     func(context.Context, string, ...string) ([]byte, error)
}

type limitedBuffer struct {
	buffer bytes.Buffer
	limit  int
}

func (buffer *limitedBuffer) Write(value []byte) (int, error) {
	remaining := buffer.limit - buffer.buffer.Len()
	if remaining <= 0 {
		return 0, ErrOutputTooLarge
	}
	if len(value) > remaining {
		_, _ = buffer.buffer.Write(value[:remaining])
		return remaining, ErrOutputTooLarge
	}
	return buffer.buffer.Write(value)
}

func (buffer *limitedBuffer) Bytes() []byte {
	return buffer.buffer.Bytes()
}

func NewExtractor(options Options) *Extractor {
	if options.MaxFileBytes <= 0 {
		options.MaxFileBytes = DefaultMaxFileBytes
	}
	if options.MaxTextBytes <= 0 {
		options.MaxTextBytes = DefaultMaxTextBytes
	}
	if options.Timeout <= 0 {
		options.Timeout = DefaultTimeout
	}
	if options.OCRMaxPages <= 0 {
		options.OCRMaxPages = 20
	}
	options.Tools = detectTools(options.Tools)
	return &Extractor{options: options, run: runCommand}
}

func (extractor *Extractor) Extract(
	ctx context.Context,
	filename string,
	contentType string,
	source io.Reader,
) (Result, error) {
	if source == nil {
		return Result{}, fmt.Errorf("%w: no file data was provided", ErrEmptyFile)
	}
	if ctx == nil {
		return Result{}, errors.New("extraction context is required")
	}

	content, err := io.ReadAll(io.LimitReader(source, extractor.options.MaxFileBytes+1))
	if err != nil {
		return Result{}, fmt.Errorf("read resume: %w", err)
	}
	if len(content) == 0 {
		return Result{}, ErrEmptyFile
	}
	if int64(len(content)) > extractor.options.MaxFileBytes {
		return Result{}, ErrFileTooLarge
	}
	if err := ctx.Err(); err != nil {
		return Result{}, classifyContextError(err)
	}

	format, err := validateFile(filename, contentType, content)
	if err != nil {
		return Result{}, err
	}

	extractionContext, cancel := context.WithTimeout(ctx, extractor.options.Timeout)
	defer cancel()

	var text string
	switch format {
	case "docx":
		text, err = extractDOCX(content, extractor.options.MaxTextBytes)
	case "pdf":
		text, err = extractor.extractPDF(extractionContext, content)
	case "doc":
		text, err = extractor.extractDOC(extractionContext, content)
	default:
		err = ErrUnsupportedFormat
	}
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return Result{}, fmt.Errorf("%w: %w", ErrExtractionTimeout, err)
		}
		if errors.Is(err, context.Canceled) {
			return Result{}, err
		}
		return Result{}, err
	}
	if !utf8.ValidString(text) {
		return Result{}, fmt.Errorf("%w: extracted text is not valid UTF-8", ErrInvalidDocument)
	}
	text = strings.TrimSpace(strings.ReplaceAll(text, "\x00", ""))
	if text == "" {
		return Result{}, ErrNoText
	}
	if len(text) > extractor.options.MaxTextBytes {
		return Result{}, ErrOutputTooLarge
	}

	checksum := sha256.Sum256(content)
	return Result{
		Text:    text,
		SHA256:  hex.EncodeToString(checksum[:]),
		Format:  format,
		Version: extractionVersion,
	}, nil
}

func validateFile(filename, contentType string, content []byte) (string, error) {
	extension := strings.ToLower(filepath.Ext(filename))
	mediaType, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		return "", fmt.Errorf("%w: invalid content type", ErrMIMETypeMismatch)
	}

	switch extension {
	case ".pdf":
		if mediaType != "application/pdf" {
			return "", ErrMIMETypeMismatch
		}
		if !bytes.HasPrefix(content, []byte("%PDF-")) {
			return "", fmt.Errorf("%w: PDF signature is missing", ErrInvalidDocument)
		}
		return "pdf", nil
	case ".doc":
		if mediaType != "application/msword" {
			return "", ErrMIMETypeMismatch
		}
		if !bytes.HasPrefix(content, []byte{0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1}) {
			return "", fmt.Errorf("%w: legacy Word signature is missing", ErrInvalidDocument)
		}
		return "doc", nil
	case ".docx":
		if mediaType != "application/vnd.openxmlformats-officedocument.wordprocessingml.document" {
			return "", ErrMIMETypeMismatch
		}
		if len(content) < 4 || !bytes.Equal(content[:4], []byte{'P', 'K', 3, 4}) {
			return "", fmt.Errorf("%w: DOCX archive signature is missing", ErrInvalidDocument)
		}
		return "docx", nil
	default:
		return "", ErrUnsupportedFormat
	}
}

func extractDOCX(content []byte, maxTextBytes int) (string, error) {
	reader, err := zip.NewReader(bytes.NewReader(content), int64(len(content)))
	if err != nil {
		return "", fmt.Errorf("%w: invalid DOCX archive", ErrInvalidDocument)
	}
	if len(reader.File) > maxDOCXEntries {
		return "", fmt.Errorf("%w: DOCX archive contains too many entries", ErrInvalidDocument)
	}

	var totalExpanded uint64
	var document *zip.File
	var contentTypes *zip.File
	seen := make(map[string]struct{}, len(reader.File))
	for _, file := range reader.File {
		cleaned := filepath.Clean(filepath.FromSlash(file.Name))
		if filepath.IsAbs(cleaned) || cleaned == ".." ||
			strings.HasPrefix(cleaned, ".."+string(filepath.Separator)) {
			return "", fmt.Errorf("%w: unsafe DOCX archive path", ErrInvalidDocument)
		}
		if _, exists := seen[file.Name]; exists {
			return "", fmt.Errorf("%w: duplicate DOCX archive entry", ErrInvalidDocument)
		}
		seen[file.Name] = struct{}{}
		if file.UncompressedSize64 > maxDOCXEntrySize ||
			file.CompressedSize64 == 0 && file.UncompressedSize64 > 0 {
			return "", fmt.Errorf("%w: DOCX archive entry is too large", ErrInvalidDocument)
		}
		if file.CompressedSize64 > 0 &&
			file.UncompressedSize64 > file.CompressedSize64*maxCompressionRatio {
			return "", fmt.Errorf("%w: DOCX compression ratio is excessive", ErrInvalidDocument)
		}
		totalExpanded += file.UncompressedSize64
		if totalExpanded > maxDOCXExpandedSize {
			return "", fmt.Errorf("%w: DOCX archive expands beyond the safety limit", ErrInvalidDocument)
		}
		if file.Name == "word/document.xml" {
			document = file
		}
		if file.Name == "[Content_Types].xml" {
			contentTypes = file
		}
	}
	if document == nil || contentTypes == nil {
		return "", fmt.Errorf("%w: DOCX document content is missing", ErrInvalidDocument)
	}
	if document.UncompressedSize64 > uint64(maxTextBytes)*4 {
		return "", ErrOutputTooLarge
	}

	file, err := document.Open()
	if err != nil {
		return "", fmt.Errorf("%w: cannot open DOCX document content", ErrInvalidDocument)
	}
	defer file.Close()

	xmlContent, err := io.ReadAll(io.LimitReader(file, int64(maxTextBytes)*4+1))
	if err != nil {
		return "", fmt.Errorf("%w: cannot read DOCX document content", ErrInvalidDocument)
	}
	if len(xmlContent) > maxTextBytes*4 {
		return "", ErrOutputTooLarge
	}
	if err := validateDOCXContentTypes(contentTypes); err != nil {
		return "", err
	}

	decoder := xml.NewDecoder(bytes.NewReader(xmlContent))
	var output strings.Builder
	inText := false
	foundDocument := false
	for {
		token, tokenErr := decoder.Token()
		if errors.Is(tokenErr, io.EOF) {
			break
		}
		if tokenErr != nil {
			return "", fmt.Errorf("%w: malformed DOCX XML", ErrInvalidDocument)
		}
		switch element := token.(type) {
		case xml.StartElement:
			if element.Name.Local == "document" && element.Name.Space == wordNamespace {
				foundDocument = true
			}
			if element.Name.Local == "t" && element.Name.Space == wordNamespace {
				inText = true
			}
			if element.Name.Local == "tab" && element.Name.Space == wordNamespace {
				output.WriteByte('\t')
			}
			if (element.Name.Local == "br" || element.Name.Local == "cr") &&
				element.Name.Space == wordNamespace {
				output.WriteByte('\n')
			}
		case xml.EndElement:
			if element.Name.Local == "t" && element.Name.Space == wordNamespace {
				inText = false
			}
			if element.Name.Local == "p" && element.Name.Space == wordNamespace {
				output.WriteByte('\n')
			}
		case xml.CharData:
			if inText {
				if output.Len()+len(element) > maxTextBytes {
					return "", ErrOutputTooLarge
				}
				output.Write(element)
			}
		}
		if output.Len() > maxTextBytes {
			return "", ErrOutputTooLarge
		}
	}
	if !foundDocument {
		return "", fmt.Errorf("%w: DOCX document root is missing", ErrInvalidDocument)
	}
	return output.String(), nil
}

func validateDOCXContentTypes(file *zip.File) error {
	content, err := readZipEntry(file, 1<<20)
	if err != nil {
		return fmt.Errorf("%w: invalid DOCX content types", ErrInvalidDocument)
	}
	decoder := xml.NewDecoder(bytes.NewReader(content))
	foundTypes := false
	foundDocument := false
	for {
		token, tokenErr := decoder.Token()
		if errors.Is(tokenErr, io.EOF) {
			break
		}
		if tokenErr != nil {
			return fmt.Errorf("%w: malformed DOCX content types", ErrInvalidDocument)
		}
		element, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		if element.Name.Local == "Types" && element.Name.Space == contentTypesNS {
			foundTypes = true
		}
		if element.Name.Local != "Override" {
			continue
		}
		var partName, contentType string
		for _, attribute := range element.Attr {
			switch attribute.Name.Local {
			case "PartName":
				partName = attribute.Value
			case "ContentType":
				contentType = attribute.Value
			}
		}
		if partName == "/word/document.xml" && contentType == documentContentType {
			foundDocument = true
		}
	}
	if !foundTypes || !foundDocument {
		return fmt.Errorf("%w: DOCX document content type is missing", ErrInvalidDocument)
	}
	return nil
}

func readZipEntry(file *zip.File, maximum int64) ([]byte, error) {
	if file.UncompressedSize64 > uint64(maximum) {
		return nil, ErrOutputTooLarge
	}
	reader, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	content, err := io.ReadAll(io.LimitReader(reader, maximum+1))
	if err != nil {
		return nil, err
	}
	if int64(len(content)) > maximum {
		return nil, ErrOutputTooLarge
	}
	return content, nil
}

func (extractor *Extractor) extractPDF(ctx context.Context, content []byte) (string, error) {
	if extractor.options.Tools.PDFToText == "" {
		return "", fmt.Errorf("%w: install Poppler's pdftotext", ErrToolUnavailable)
	}
	path, cleanup, err := writeTemporaryFile(".pdf", content)
	if err != nil {
		return "", err
	}
	defer cleanup()

	text, err := extractor.run(ctx, extractor.options.Tools.PDFToText, "-layout", "-enc", "UTF-8", path, "-")
	if err != nil {
		if errors.Is(err, ErrOutputTooLarge) {
			return "", err
		}
		if ctx.Err() != nil {
			return "", classifyContextError(ctx.Err())
		}
		if errors.Is(err, exec.ErrNotFound) {
			return "", fmt.Errorf("%w: install Poppler's pdftotext", ErrToolUnavailable)
		}
		return "", fmt.Errorf("%w: Poppler could not read the PDF", ErrInvalidDocument)
	}
	normalized := strings.TrimSpace(string(text))
	if normalized != "" {
		return normalized, nil
	}
	if !extractor.options.EnableOCR {
		return "", ErrNoText
	}
	return extractor.ocrPDF(ctx, path)
}

func (extractor *Extractor) extractDOC(ctx context.Context, content []byte) (string, error) {
	if extractor.options.Tools.Antiword == "" {
		return "", fmt.Errorf("%w: install antiword to process legacy DOC files", ErrToolUnavailable)
	}
	path, cleanup, err := writeTemporaryFile(".doc", content)
	if err != nil {
		return "", err
	}
	defer cleanup()

	text, err := extractor.run(ctx, extractor.options.Tools.Antiword, path)
	if err != nil {
		if errors.Is(err, ErrOutputTooLarge) {
			return "", err
		}
		if ctx.Err() != nil {
			return "", classifyContextError(ctx.Err())
		}
		if errors.Is(err, exec.ErrNotFound) {
			return "", fmt.Errorf("%w: install antiword to process legacy DOC files", ErrToolUnavailable)
		}
		return "", fmt.Errorf("%w: antiword could not read the DOC file", ErrInvalidDocument)
	}
	if strings.TrimSpace(string(text)) == "" {
		return "", ErrNoText
	}
	return string(text), nil
}

func (extractor *Extractor) ocrPDF(ctx context.Context, pdfPath string) (string, error) {
	tools := extractor.options.Tools
	if tools.PDFInfo == "" || tools.PDFToPPM == "" || tools.Tesseract == "" {
		return "", fmt.Errorf(
			"%w: OCR requires Poppler's pdfinfo and pdftoppm plus Tesseract",
			ErrToolUnavailable,
		)
	}
	info, err := extractor.run(ctx, tools.PDFInfo, pdfPath)
	if err != nil {
		if ctx.Err() != nil {
			return "", classifyContextError(ctx.Err())
		}
		if errors.Is(err, exec.ErrNotFound) {
			return "", fmt.Errorf("%w: install Poppler's pdfinfo", ErrToolUnavailable)
		}
		return "", fmt.Errorf("%w: cannot inspect PDF pages for OCR", ErrInvalidDocument)
	}
	pageCount, err := pdfPageCount(string(info))
	if err != nil {
		return "", fmt.Errorf("%w: PDF page count is unavailable", ErrInvalidDocument)
	}
	if pageCount > extractor.options.OCRMaxPages {
		return "", ErrPageLimit
	}

	directory, err := os.MkdirTemp("", "proofhire-resume-ocr-*")
	if err != nil {
		return "", fmt.Errorf("create OCR temporary directory: %w", err)
	}
	defer os.RemoveAll(directory)
	prefix := filepath.Join(directory, "page")
	if _, err := extractor.run(
		ctx,
		tools.PDFToPPM,
		"-f", "1",
		"-l", strconv.Itoa(extractor.options.OCRMaxPages),
		"-r", "120",
		"-png",
		pdfPath,
		prefix,
	); err != nil {
		if ctx.Err() != nil {
			return "", classifyContextError(ctx.Err())
		}
		if errors.Is(err, exec.ErrNotFound) {
			return "", fmt.Errorf("%w: install Poppler's pdftoppm", ErrToolUnavailable)
		}
		return "", fmt.Errorf("%w: PDF page rendering failed", ErrInvalidDocument)
	}
	images, err := filepath.Glob(prefix + "-*.png")
	if err != nil {
		return "", fmt.Errorf("find OCR page images: %w", err)
	}
	sort.Slice(images, func(left, right int) bool {
		return pageNumber(images[left]) < pageNumber(images[right])
	})
	if len(images) != pageCount {
		return "", fmt.Errorf("%w: OCR could not render every PDF page", ErrInvalidDocument)
	}

	var output strings.Builder
	for _, image := range images {
		pageText, runErr := extractor.run(ctx, tools.Tesseract, image, "stdout", "-l", "eng")
		if runErr != nil {
			if ctx.Err() != nil {
				return "", classifyContextError(ctx.Err())
			}
			if errors.Is(runErr, exec.ErrNotFound) {
				return "", fmt.Errorf("%w: install Tesseract", ErrToolUnavailable)
			}
			return "", fmt.Errorf("%w: Tesseract OCR failed", ErrInvalidDocument)
		}
		if output.Len()+len(pageText) > extractor.options.MaxTextBytes {
			return "", ErrOutputTooLarge
		}
		output.Write(pageText)
		output.WriteByte('\n')
	}
	if strings.TrimSpace(output.String()) == "" {
		return "", ErrNoText
	}
	return output.String(), nil
}

func pdfPageCount(info string) (int, error) {
	for _, line := range strings.Split(info, "\n") {
		name, value, found := strings.Cut(line, ":")
		if found && strings.TrimSpace(name) == "Pages" {
			pageCount, err := strconv.Atoi(strings.TrimSpace(value))
			if err == nil && pageCount > 0 {
				return pageCount, nil
			}
		}
	}
	return 0, errors.New("PDF page count was not found")
}

func pageNumber(path string) int {
	base := strings.TrimSuffix(filepath.Base(path), ".png")
	_, suffix, found := strings.Cut(base, "-")
	if !found {
		return 0
	}
	page, _ := strconv.Atoi(suffix)
	return page
}

func writeTemporaryFile(extension string, content []byte) (string, func(), error) {
	file, err := os.CreateTemp("", "proofhire-resume-*"+extension)
	if err != nil {
		return "", nil, fmt.Errorf("create resume temporary file: %w", err)
	}
	path := file.Name()
	if _, err := file.Write(content); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return "", nil, fmt.Errorf("write resume temporary file: %w", err)
	}
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		return "", nil, fmt.Errorf("close resume temporary file: %w", err)
	}
	return path, func() { _ = os.Remove(path) }, nil
}

func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, name, args...)
	stdout := &limitedBuffer{limit: DefaultMaxTextBytes}
	command.Stdout = stdout
	command.Stderr = io.Discard
	if err := command.Run(); err != nil {
		if errors.Is(err, ErrOutputTooLarge) {
			return nil, ErrOutputTooLarge
		}
		return nil, err
	}
	return append([]byte(nil), stdout.Bytes()...), nil
}

func detectTools(tools Tools) Tools {
	tools.PDFToText = findTool(tools.PDFToText, "pdftotext")
	tools.PDFInfo = findTool(tools.PDFInfo, "pdfinfo")
	tools.PDFToPPM = findTool(tools.PDFToPPM, "pdftoppm")
	tools.Tesseract = findTool(tools.Tesseract, "tesseract")
	tools.Antiword = findTool(tools.Antiword, "antiword")
	return tools
}

func findTool(configured, name string) string {
	if configured != "" {
		return configured
	}
	path, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	return path
}

func classifyContextError(err error) error {
	if errors.Is(err, context.DeadlineExceeded) {
		return fmt.Errorf("%w: %w", ErrExtractionTimeout, err)
	}
	return err
}
