package runner

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestNormalizeOutputIgnoresTrailingWhitespaceAndLineEndings(t *testing.T) {
	cases := []struct {
		expected string
		actual   string
		match    bool
	}{
		{"1\n2\n3\n", "1\n2\n3", true},
		{"1\r\n2\r\n", "1\n2\n", true},
		{"answer   \n42\n", "answer\n42", true},
		{"42\n", "43\n", false},
		{"Case\n", "case\n", false},
	}
	for _, testCase := range cases {
		if got := OutputMatches(testCase.expected, testCase.actual); got != testCase.match {
			t.Errorf("OutputMatches(%q, %q) = %v, want %v",
				testCase.expected, testCase.actual, got, testCase.match)
		}
	}
}

func TestIsSuccessfulRejectsTimeoutsAndFailures(t *testing.T) {
	if IsSuccessful(Result{Stdout: "ok\n"}, "ok", nil) != true {
		t.Fatal("matching output with a zero exit must pass")
	}
	if IsSuccessful(Result{Stdout: "ok\n", TimedOut: true}, "ok", nil) {
		t.Fatal("a timeout must not pass")
	}
	if IsSuccessful(Result{Stdout: "ok\n", ExitCode: 1}, "ok", nil) {
		t.Fatal("a non-zero exit must not pass")
	}
	if IsSuccessful(Result{Stdout: "ok\n", Truncated: true}, "ok", nil) {
		t.Fatal("truncated output must not pass")
	}
	if IsSuccessful(Result{Stdout: "ok\n"}, "ok", ErrOutputTooLarge) {
		t.Fatal("an execution error must not pass")
	}
}

func TestLanguageCatalogueIsComplete(t *testing.T) {
	for name, language := range Languages {
		if language.Image == "" || language.Filename == "" || language.Run == "" {
			t.Errorf("language %q is missing image, filename or run command", name)
		}
		if !strings.HasPrefix(language.Run, "/") && language.Run == "" {
			t.Errorf("language %q has an empty run command", name)
		}
	}
	if _, ok := Languages["python"]; !ok {
		t.Fatal("python must be available")
	}
}

func TestRunRejectsUnsupportedLanguage(t *testing.T) {
	engine := NewEngine()
	_, err := engine.Run(context.Background(), Request{
		Language: "brainfuck",
		Source:   "++++",
	})
	if err == nil {
		t.Fatal("expected an unsupported-language error")
	}
}

func TestLimitedBufferTruncates(t *testing.T) {
	buffer := limitedBuffer{limit: 4}
	_, _ = buffer.Write([]byte("abcdef"))
	if !buffer.truncated || buffer.String() != "abcd" {
		t.Fatalf("buffer = %q truncated=%v", buffer.String(), buffer.truncated)
	}
}

// TestPythonExecution runs a real container when Docker is reachable. It is
// skipped in -short mode so unit tests stay fast and portable.
func TestPythonExecution(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping container execution in short mode")
	}
	engine := NewEngine()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	if err := engine.Available(ctx); err != nil {
		t.Skipf("docker is unavailable: %v", err)
	}
	if err := engine.Prewarm(ctx, []string{"python"}); err != nil {
		t.Skipf("could not prepare the python image: %v", err)
	}

	result, err := engine.Run(ctx, Request{
		Language:  "python",
		Source:    "import sys\nvalues = [int(v) for v in sys.stdin.read().split()]\nprint(sum(values))\n",
		Stdin:     "2 3 5\n",
		TimeLimit: 10 * time.Second,
	})
	if err != nil {
		t.Fatalf("run failed: %v", err)
	}
	if !IsSuccessful(result, "10\n", nil) {
		t.Fatalf("unexpected result: exit=%d stdout=%q stderr=%q timedOut=%v",
			result.ExitCode, result.Stdout, result.Stderr, result.TimedOut)
	}

	// Network must be unreachable from the sandbox.
	network, err := engine.Run(ctx, Request{
		Language: "python",
		Source: "import socket\n" +
			"try:\n" +
			"    socket.create_connection(('1.1.1.1', 80), timeout=2)\n" +
			"    print('connected')\n" +
			"except Exception:\n" +
			"    print('blocked')\n",
		TimeLimit: 10 * time.Second,
	})
	if err != nil {
		t.Fatalf("network probe failed: %v", err)
	}
	if !OutputMatches("blocked\n", network.Stdout) {
		t.Fatalf("sandbox allowed outbound network: %q", network.Stdout)
	}

	// An infinite loop must be killed by the wall-clock limit.
	timeoutResult, err := engine.Run(ctx, Request{
		Language:  "python",
		Source:    "while True:\n    pass\n",
		TimeLimit: 3 * time.Second,
	})
	if err != nil {
		t.Fatalf("timeout probe failed: %v", err)
	}
	if !timeoutResult.TimedOut {
		t.Fatalf("expected a timeout, got exit=%d duration=%s",
			timeoutResult.ExitCode, timeoutResult.Duration)
	}
}
