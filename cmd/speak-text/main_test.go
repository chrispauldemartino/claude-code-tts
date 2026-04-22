package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestValidateCLIOptions(t *testing.T) {
	if err := validateCLIOptions("", false); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if err := validateCLIOptions("/tmp/out.mp3", true); err != nil {
		t.Fatalf("expected no error with output+no-play, got %v", err)
	}
	if err := validateCLIOptions("", true); err == nil {
		t.Fatal("expected error when -no-play is used without -output")
	}
}

func TestWriteOutputFile(t *testing.T) {
	tmpDir := t.TempDir()
	outPath := filepath.Join(tmpDir, "speech.mp3")
	audioData := []byte("fake-audio")

	if err := writeOutputFile(outPath, audioData); err != nil {
		t.Fatalf("writeOutputFile returned error: %v", err)
	}

	got, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("failed to read output file: %v", err)
	}

	if string(got) != string(audioData) {
		t.Fatalf("unexpected file contents: got %q want %q", got, audioData)
	}
}
