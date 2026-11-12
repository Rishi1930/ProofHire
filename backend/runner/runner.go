// Package runner executes untrusted candidate code inside a disposable Docker
// container and compares its output with the expected test output.
//
// Isolation model, per execution:
//   - a fresh container, removed on exit;
//   - no network namespace access (--network none);
//   - read-only root filesystem with a small writable tmpfs for build output;
//   - CPU, memory, process-count and file-size limits;
//   - the source is bind-mounted read-only, never written into the image;
//   - a wall-clock deadline enforced by the parent process.
//
// The engine never receives database credentials, never mounts the workspace,
// and never runs on the same host path as application data.
package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ErrUnsupportedLanguage is returned when the requested language has no
// configured runtime.
var ErrUnsupportedLanguage = errors.New("runner: unsupported language")

// ErrOutputTooLarge is returned when a program writes more than the capture
// limit. The program is killed and the submission is marked failed.
var ErrOutputTooLarge = errors.New("runner: output limit exceeded")

// Language describes how to compile and run a source file inside its image.
type Language struct {
	Name     string
	Image    string
	Filename string
	// Compile is run before Run when non-empty. Both commands execute with the
	// read-only source mounted at /box and a writable /tmp.
	Compile string
	Run     string
}

// Languages is the execution catalogue. Adding a language means adding an
// image, a filename and the two commands.
var Languages = map[string]Language{
	"python": {
		Name:     "python",
		Image:    "python:3.12-alpine",
		Filename: "main.py",
		Run:      "python3 /box/main.py",
	},
	"javascript": {
		Name:     "javascript",
		Image:    "node:22-alpine",
		Filename: "main.js",
		Run:      "node /box/main.js",
	},
	"go": {
		Name:     "go",
		Image:    "golang:1.23-alpine",
		Filename: "main.go",
		Run:      "GOCACHE=/tmp/gocache GOPATH=/tmp/gopath GOFLAGS=-mod=mod go run /box/main.go",
	},
	"cpp": {
		Name:     "cpp",
		Image:    "gcc:14-bookworm",
		Filename: "main.cpp",
		Compile:  "g++ -O2 -std=c++17 -o /tmp/program /box/main.cpp",
		Run:      "/tmp/program",
	},
	"java": {
		Name:     "java",
		Image:    "eclipse-temurin:21-jdk-alpine",
		Filename: "Main.java",
		Compile:  "javac -d /tmp /box/Main.java",
		Run:      "java -Xmx192m -cp /tmp Main",
	},
}

// Request is one program execution with one standard-input payload.
type Request struct {
	Language      string
	Source        string
	Stdin         string
	TimeLimit     time.Duration
	MemoryLimitMB int
	CPULimit      int
}

// Result captures everything the evaluator needs to score one execution.
type Result struct {
	Stdout    string
	Stderr    string
	ExitCode  int
	TimedOut  bool
	Duration  time.Duration
	Truncated bool
}

// Engine runs code through a container runtime.
type Engine struct {
	DockerPath   string
	MaxOutput    int
	MemoryMB     int
	CPULimit     int
	DefaultTime  time.Duration
	KeepTempDirs bool
}

func NewEngine() *Engine {
	return &Engine{
		DockerPath:  "docker",
		MaxOutput:   64 << 10,
		MemoryMB:    256,
		CPULimit:    1,
		DefaultTime: 10 * time.Second,
	}
}

// Available reports whether the container runtime answers.
func (engine *Engine) Available(ctx context.Context) error {
	command := exec.CommandContext(ctx, engine.binary(), "version", "--format", "{{.Server.Version}}")
	if output, err := command.CombinedOutput(); err != nil {
		return fmt.Errorf("runner: docker is unavailable: %s", strings.TrimSpace(string(output)))
	}
	return nil
}

// Prewarm pulls the images for the given languages. It is safe to call more
// than once and is intended for worker startup.
func (engine *Engine) Prewarm(ctx context.Context, languages []string) error {
	for _, name := range languages {
		language, ok := Languages[strings.ToLower(strings.TrimSpace(name))]
		if !ok {
			return fmt.Errorf("%w: %s", ErrUnsupportedLanguage, name)
		}
		command := exec.CommandContext(ctx, engine.binary(), "image", "inspect", language.Image)
		if err := command.Run(); err == nil {
			continue
		}
		pull := exec.CommandContext(ctx, engine.binary(), "pull", language.Image)
		if output, err := pull.CombinedOutput(); err != nil {
			return fmt.Errorf("runner: could not pull %s: %s", language.Image, strings.TrimSpace(string(output)))
		}
	}
	return nil
}

func (engine *Engine) binary() string {
	if strings.TrimSpace(engine.DockerPath) == "" {
		return "docker"
	}
	return engine.DockerPath
}

// Run executes the program and returns its captured output.
func (engine *Engine) Run(ctx context.Context, request Request) (Result, error) {
	language, ok := Languages[strings.ToLower(strings.TrimSpace(request.Language))]
	if !ok {
		return Result{}, fmt.Errorf("%w: %s", ErrUnsupportedLanguage, request.Language)
	}
	if strings.TrimSpace(request.Source) == "" {
		return Result{}, errors.New("runner: source is empty")
	}

	directory, err := os.MkdirTemp("", "proofhire-run-")
	if err != nil {
		return Result{}, fmt.Errorf("runner: could not create a workspace: %w", err)
	}
	if !engine.KeepTempDirs {
		defer os.RemoveAll(directory)
	}
	if err := os.WriteFile(filepath.Join(directory, language.Filename), []byte(request.Source), 0o444); err != nil {
		return Result{}, fmt.Errorf("runner: could not stage the source: %w", err)
	}

	timeLimit := request.TimeLimit
	if timeLimit <= 0 {
		timeLimit = engine.DefaultTime
	}
	memory := request.MemoryLimitMB
	if memory <= 0 {
		memory = engine.MemoryMB
	}
	cpus := request.CPULimit
	if cpus <= 0 {
		cpus = engine.CPULimit
	}

	script := language.Run
	if language.Compile != "" {
		script = language.Compile + " && " + language.Run
	}

	args := []string{
		"run", "--rm", "--interactive",
		"--network", "none",
		"--memory", fmt.Sprintf("%dm", memory),
		"--memory-swap", fmt.Sprintf("%dm", memory),
		"--cpus", fmt.Sprintf("%d", cpus),
		"--pids-limit", "128",
		"--read-only",
		"--tmpfs", "/tmp:rw,noexec,nosuid,size=64m",
		"--user", "65534:65534",
		"--workdir", "/box",
		"--volume", directory + ":/box:ro",
		"--env", "HOME=/tmp",
		language.Image,
		"sh", "-lc", script,
	}

	runContext, cancel := context.WithTimeout(ctx, timeLimit+time.Second)
	defer cancel()

	command := exec.CommandContext(runContext, engine.binary(), args...)
	command.Stdin = strings.NewReader(request.Stdin)
	command.WaitDelay = time.Second

	var stdout, stderr limitedBuffer
	stdout.limit = engine.maxOutput()
	stderr.limit = engine.maxOutput()
	command.Stdout = &stdout
	command.Stderr = &stderr
	command.Env = []string{}

	started := time.Now()
	runErr := command.Run()
	elapsed := time.Since(started)

	result := Result{
		Stdout:    stdout.String(),
		Stderr:    stderr.String(),
		Duration:  elapsed,
		Truncated: stdout.truncated || stderr.truncated,
	}
	if stdout.truncated || stderr.truncated {
		return result, ErrOutputTooLarge
	}

	if runContext.Err() == context.DeadlineExceeded || errors.Is(runErr, context.DeadlineExceeded) {
		result.TimedOut = true
		result.ExitCode = -1
		return result, nil
	}
	if runErr != nil {
		var exitError *exec.ExitError
		if errors.As(runErr, &exitError) {
			result.ExitCode = exitError.ExitCode()
			return result, nil
		}
		return result, fmt.Errorf("runner: execution failed: %w", runErr)
	}
	return result, nil
}

func (engine *Engine) maxOutput() int {
	if engine.MaxOutput <= 0 {
		return 64 << 10
	}
	return engine.MaxOutput
}

// NormalizeOutput makes comparisons independent of trailing spaces, CRLF line
// endings and the final newline.
func NormalizeOutput(value string) string {
	value = strings.ReplaceAll(value, "\r\n", "\n")
	value = strings.ReplaceAll(value, "\r", "\n")
	lines := strings.Split(value, "\n")
	for index, line := range lines {
		lines[index] = strings.TrimRight(line, " \t")
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// OutputMatches reports whether the program produced the expected answer.
func OutputMatches(expected, actual string) bool {
	return NormalizeOutput(expected) == NormalizeOutput(actual)
}

// IsSuccessful reports whether one execution should be scored as a pass.
func IsSuccessful(result Result, expected string, runErr error) bool {
	if runErr != nil || result.TimedOut || result.Truncated {
		return false
	}
	if result.ExitCode != 0 {
		return false
	}
	return OutputMatches(expected, result.Stdout)
}

// limitedBuffer stores at most limit bytes and remembers that it overflowed.
type limitedBuffer struct {
	buffer    bytes.Buffer
	limit     int
	truncated bool
}

func (writer *limitedBuffer) Write(data []byte) (int, error) {
	remaining := writer.limit - writer.buffer.Len()
	if remaining <= 0 {
		writer.truncated = true
		return len(data), nil
	}
	if len(data) > remaining {
		_, _ = writer.buffer.Write(data[:remaining])
		writer.truncated = true
		return len(data), nil
	}
	return writer.buffer.Write(data)
}

func (writer *limitedBuffer) String() string { return writer.buffer.String() }
