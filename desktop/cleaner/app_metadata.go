//go:build darwin

package main

import (
	"context"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type appMetadataRunner func(context.Context, string, ...string) ([]byte, error)

func appMetadataCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.WaitDelay = time.Second
	return cmd.CombinedOutput()
}

func appSize(output []byte, path string) *uint64 {
	fields := strings.SplitN(strings.TrimSuffix(string(output), "\n"), "\t", 2)
	if len(fields) != 2 || fields[1] != path {
		return nil
	}
	kb, err := strconv.ParseUint(fields[0], 10, 54)
	if err != nil {
		return nil
	}
	bytes := kb * 1024
	return &bytes
}

func appLastActive(output []byte, now time.Time) *int64 {
	value := strings.Trim(string(output), "\x00 \t\r\n")
	date, err := time.Parse("2006-01-02 15:04:05 -0700", value)
	if err != nil || date.Before(time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)) || date.After(now.Add(5*time.Minute)) {
		return nil
	}
	epoch := date.Unix()
	return &epoch
}

// Display measurements never authorize removal. Every inventory measures fresh;
// the separate removal review retains its own sizing and identity checks.
func readAppMetadata(ctx context.Context, app application, run appMetadataRunner) application {
	app.MetadataPending = false
	app.SizeBytes, app.LastActive = nil, nil
	if !app.Binding.Matches() {
		return app
	}
	sizeCtx, stopSize := context.WithTimeout(ctx, 5*time.Second)
	output, err := run(sizeCtx, "/usr/bin/du", "-skP", app.Path)
	stopSize()
	if err == nil {
		app.SizeBytes = appSize(output, app.Path)
	}
	dateCtx, stopDate := context.WithTimeout(ctx, time.Second)
	output, err = run(dateCtx, "/usr/bin/mdls", "-name", "kMDItemLastUsedDate", "-raw", app.Path)
	stopDate()
	if err == nil {
		app.LastActive = appLastActive(output, time.Now())
	}
	if ctx.Err() != nil || !app.Binding.Matches() {
		app.SizeBytes, app.LastActive = nil, nil
	}
	return app
}
