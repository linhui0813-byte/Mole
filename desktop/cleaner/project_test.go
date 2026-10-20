//go:build darwin

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/tw93/mole/desktop/pathbinding"
)

func projectFixture(t *testing.T, e engine) string {
	t.Helper()
	root := filepath.Join(e.home, "Downloads", "whole-project")
	if err := os.MkdirAll(filepath.Join(root, ".git/objects"), 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{".git/HEAD", ".env", "source.txt"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("disposable project fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func projectItem(t *testing.T, e engine, root string) item {
	t.Helper()
	for _, v := range review(t, e, root).items {
		if v.Category != "analyze-project" {
			t.Fatal("project warning absent from private plan")
		}
		return v
	}
	t.Fatal("missing project")
	return item{}
}

func TestAnalyzeWholeProjectLargeAndLinks(t *testing.T) {
	e := analyzeFixture(t)
	root := projectFixture(t, e)
	outside := analyzeFile(t, e, "outside-control.txt")
	if err := os.Symlink(outside, filepath.Join(root, "linked-control")); err != nil {
		t.Fatal(err)
	}
	build := filepath.Join(root, "target")
	if err := os.Mkdir(build, 0700); err != nil {
		t.Fatal(err)
	}
	for i := range 10001 {
		if err := os.WriteFile(filepath.Join(build, fmt.Sprintf("%05d", i)), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	v := projectItem(t, e, root)
	if err := acknowledgeSelections([]item{v}, nil); err == nil {
		t.Fatal("project executable without acknowledgement")
	}
	if err := acknowledgeSelections([]item{v}, []string{v.ID}); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{v})
	if events[1].Status != "trashed" {
		t.Fatalf("large project move failed: %+v", events)
	}
	assertExists(t, outside, true)
	assertExists(t, root, false)
	moves, err := filepath.Glob(filepath.Join(e.home, "fixture-trash", filepath.Base(root)+".*"))
	if err != nil || len(moves) != 1 {
		t.Fatalf("expected one project in fixture Trash: %v %v", moves, err)
	}
	moved := moves[0]
	link, err := os.Readlink(filepath.Join(moved, "linked-control"))
	if err != nil || link != outside {
		t.Fatalf("internal link was followed or lost: %v %q", err, link)
	}
	assertExists(t, filepath.Join(moved, ".git/HEAD"), true)
	assertExists(t, filepath.Join(moved, ".env"), true)
}

func TestAnalyzeProjectFinalWhitelistGlobAndDatabase(t *testing.T) {
	for _, guard := range []string{"whitelist", "database", "unknown-database", "git-lock"} {
		t.Run(guard, func(t *testing.T) {
			e := analyzeFixture(t)
			root := projectFixture(t, e)
			if err := os.Mkdir(filepath.Join(root, "nested"), 0700); err != nil {
				t.Fatal(err)
			}
			v := projectItem(t, e, root)
			switch guard {
			case "whitelist":
				if err := os.MkdirAll(filepath.Join(e.home, ".config/mole"), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(e.home, ".config/mole/whitelist"), []byte(e.home+"/Downloads/*/nested/keep[0-9]?.txt\n"), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(root, "nested/keep12.txt"), nil, 0600); err != nil {
					t.Fatal(err)
				}
			case "database":
				if err := os.WriteFile(filepath.Join(root, "nested/open-cache.DB-wal"), nil, 0600); err != nil {
					t.Fatal(err)
				}
			case "unknown-database":
				if err := os.WriteFile(filepath.Join(root, "nested/unknown-cache.sqlite3-shm"), nil, 0600); err != nil {
					t.Fatal(err)
				}
			case "git-lock":
				if err := os.WriteFile(filepath.Join(root, ".git/index.lock"), nil, 0600); err != nil {
					t.Fatal(err)
				}
			}
			events := collectClean(e, []item{v})
			if events[1].Status == "trashed" {
				t.Fatalf("late %s allowed: %+v", guard, events)
			}
			assertExists(t, root, true)
		})
	}
}

func TestAnalyzeProjectWhitelistAppearsDuringFinalSizing(t *testing.T) {
	e := analyzeFixture(t)
	root := projectFixture(t, e)
	if err := os.Mkdir(filepath.Join(root, "nested"), 0700); err != nil {
		t.Fatal(err)
	}
	v := projectItem(t, e, root)
	b := binding(t, root)
	if err := os.MkdirAll(filepath.Join(e.home, ".config/mole"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(e.home, ".config/mole/whitelist"), []byte(e.home+"/Downloads/*/nested/keep[0-9]?.txt\n"), 0600); err != nil {
		t.Fatal(err)
	}
	bin := strings.TrimPrefix(strings.Split(e.env[1], ":")[0], "PATH=")
	stub := "#!/bin/bash\nprintf fixture > \"$HOME/Downloads/whole-project/nested/keep12.txt\"\nexec /usr/bin/du \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "du"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{v})
	if events[1].Status == "trashed" {
		t.Fatalf("late whitelisted descendant passed the final guard: %+v", events)
	}
	assertExists(t, filepath.Join(root, "nested/keep12.txt"), true)
	if !b.Matches() {
		t.Fatal("fixture changed root identity instead of reaching the descendant guard")
	}
}

func TestAnalyzeProjectAccountScopeDoesNotRequireAdminVisibility(t *testing.T) {
	e := analyzeFixture(t)
	root := projectFixture(t, e)
	if err := os.WriteFile(filepath.Join(root, "fixture.sqlite"), []byte("disposable fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	bin := strings.TrimPrefix(strings.Split(e.env[1], ":")[0], "PATH=")
	stub := "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$HOME/project-handle-trace\"\n[[ \"$*\" == *'-a -u '* ]] || exit 97\nexit 1\n"
	if err := os.WriteFile(filepath.Join(bin, "lsof"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	v := projectItem(t, e, root)
	events := collectClean(e, []item{v})
	if events[1].Status != "trashed" {
		t.Fatalf("idle account-scoped project was blocked by unrelated administrator visibility: %+v", events)
	}
	trace, err := os.ReadFile(filepath.Join(e.home, "project-handle-trace"))
	if err != nil || !strings.Contains(string(trace), "fixture.sqlite") || strings.Contains(string(trace), "-p 1") {
		t.Fatalf("account probe absent or unexpectedly elevated: %v %s", err, trace)
	}
}

func TestAnalyzeProjectProbeSignalStopsNextEligibleItem(t *testing.T) {
	e := analyzeFixture(t)
	root := projectFixture(t, e)
	if err := os.WriteFile(filepath.Join(root, "fixture.sqlite-journal"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	project := projectItem(t, e, root)
	control := analyzeFile(t, e, "otherwise-eligible.txt")
	var next item
	for _, v := range review(t, e, control).items {
		next = v
	}
	bin := strings.TrimPrefix(strings.Split(e.env[1], ":")[0], "PATH=")
	stub := "#!/bin/bash\nprintf signal-probed > \"$HOME/project-signal-trace\"\nexit 130\n"
	if err := os.WriteFile(filepath.Join(bin, "lsof"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{project, next})
	if len(events) != 3 || events[1].ItemID != project.ID || events[1].Status != "unverified" {
		t.Fatalf("probe signal did not stop the batch: %+v", events)
	}
	assertExists(t, filepath.Join(e.home, "project-signal-trace"), true)
	assertExists(t, control, true)
	assertExists(t, root, true)
}

func TestAnalyzeProjectProtocolRequiresAcknowledgementAndConsumesPlan(t *testing.T) {
	e := analyzeFixture(t)
	root := projectFixture(t, e)
	in, writer := io.Pipe()
	reader, out := io.Pipe()
	finished := make(chan struct{})
	go func() { run(in, out, e); out.Close(); close(finished) }()
	defer func() { writer.Close(); reader.Close(); <-finished }()
	encoder := json.NewEncoder(writer)
	responses := make(chan event, 64)
	go func() {
		scanner := bufio.NewScanner(reader)
		for scanner.Scan() {
			var ev event
			if json.Unmarshal(scanner.Bytes(), &ev) == nil {
				responses <- ev
			}
		}
		close(responses)
	}()
	read := func(kind string) event {
		t.Helper()
		deadline := time.After(15 * time.Second)
		for {
			select {
			case ev, ok := <-responses:
				if !ok {
					t.Fatal("helper exited before " + kind)
				}
				if ev.Kind == kind {
					return ev
				}
				if ev.Kind == "refused" || ev.Kind == "error" {
					t.Fatalf("unexpected refusal waiting for %s: %+v", kind, ev)
				}
			case <-deadline:
				t.Fatal("helper timed out before " + kind)
			}
		}
	}
	if err := encoder.Encode(command{Action: "review", ID: "review", Candidates: []pathbinding.Binding{binding(t, root)}}); err != nil {
		t.Fatal(err)
	}
	v := read("item").Item
	read("scan_done")
	if err := encoder.Encode(command{Action: "clean", ID: "without-ack", IDs: []string{v.ID}}); err != nil {
		t.Fatal(err)
	}
	if ev := read("error"); !strings.Contains(ev.Message, "Acknowledge") {
		t.Fatalf("missing acknowledgement accepted: %+v", ev)
	}
	assertExists(t, root, true)
	if err := encoder.Encode(command{Action: "clean", ID: "replay", IDs: []string{v.ID}, AcknowledgedItems: []string{v.ID}}); err != nil {
		t.Fatal(err)
	}
	if ev := read("error"); !strings.Contains(ev.Message, "expired") {
		t.Fatal("failed execution did not consume plan")
	}
	assertExists(t, root, true)
	if err := encoder.Encode(command{Action: "review", ID: "new-review", Candidates: []pathbinding.Binding{binding(t, root)}}); err != nil {
		t.Fatal(err)
	}
	v = read("item").Item
	read("scan_done")
	if err := encoder.Encode(command{Action: "clean", ID: "with-ack", IDs: []string{v.ID}, AcknowledgedItems: []string{v.ID}}); err != nil {
		t.Fatal(err)
	}
	read("clean_done")
	assertExists(t, root, false)
}
