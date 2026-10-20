//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tw93/mole/desktop/pathbinding"
)

var analyzeTestGate string

func TestMain(m *testing.M) {
	wd, _ := os.Getwd()
	root := filepath.Dir(filepath.Dir(wd))
	temp, err := os.MkdirTemp("", "mole-analyze-gate-")
	if err != nil {
		panic(err)
	}
	for _, args := range [][]string{
		{"python3", filepath.Join(root, "desktop/Tools/analyzer_overlay.py"), temp},
		{"go", "build", "-overlay", filepath.Join(temp, "analyzer-overlay.json"), "-o", filepath.Join(temp, "gate"), "./cmd/analyze"},
	} {
		cmd := exec.Command(args[0], args[1:]...)
		cmd.Dir = root
		if out, err := cmd.CombinedOutput(); err != nil {
			fmt.Fprintf(os.Stderr, "gate build: %v\n%s", err, out)
			os.Exit(1)
		}
	}
	analyzeTestGate = filepath.Join(temp, "gate")
	code := m.Run()
	_ = os.RemoveAll(temp)
	os.Exit(code)
}

func analyzeFixture(t *testing.T) engine {
	t.Helper()
	e := fixture(t)
	e.analyze = true
	e.script = filepath.Join(e.root, "desktop/Engine/analyze.sh")
	e.env = append(e.env, "MOLE_DASHBOARD_ANALYZE_GATE="+analyzeTestGate)
	return e
}

func binding(t *testing.T, path string) pathbinding.Binding {
	t.Helper()
	b, err := pathbinding.Read(path)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func analyzeFile(t *testing.T, e engine, name string) string {
	t.Helper()
	path := filepath.Join(e.home, "Downloads", name)
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("disposable Analyze fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func review(t *testing.T, e engine, paths ...string) *plan {
	t.Helper()
	var candidates []pathbinding.Binding
	for _, path := range paths {
		candidates = append(candidates, binding(t, path))
	}
	var events []event
	p := e.review(context.Background(), "review", candidates, func(v event) { events = append(events, v) })
	if p == nil || len(p.items) == 0 {
		t.Fatalf("positive review failed: %+v", events)
	}
	return p
}

func TestAnalyzeSelectedOnlyTrashAndAudit(t *testing.T) {
	e := analyzeFixture(t)
	a, b := analyzeFile(t, e, "selected ' 分析.txt"), analyzeFile(t, e, "keep.txt")
	p := review(t, e, a, b)
	var selected item
	for _, v := range p.items {
		if v.Path == a {
			selected = v
		}
	}
	events := collectClean(e, []item{selected})
	if events[1].Status != "trashed" {
		t.Fatalf("selected move failed: %+v", events)
	}
	assertExists(t, a, false)
	assertExists(t, b, true)
	log, err := os.ReadFile(filepath.Join(e.home, "Library/Logs/mole/operations.log"))
	if err != nil || !strings.Contains(string(log), "analyze") || !strings.Contains(string(log), a) {
		t.Fatalf("audit missing: %v %s", err, log)
	}
}

func TestAnalyzeAllRefusedReviewSummary(t *testing.T) {
	e := analyzeFixture(t)
	secret := analyzeFile(t, e, "profile/.env")
	var final event
	p := e.review(context.Background(), "all-kept", []pathbinding.Binding{binding(t, filepath.Dir(secret))}, func(v event) {
		if v.Kind == "scan_done" {
			final = v
		}
	})
	if p != nil && len(p.items) != 0 {
		t.Fatal("refused review created an executable selection")
	}
	if final.Total != 0 || final.Kept != 1 || !strings.Contains(final.Message, "None of the selected items") {
		t.Fatalf("all-refused review still invites a move: %+v", final)
	}
	assertExists(t, secret, true)
}

func TestAnalyzeBrowserProfileAppearsAtFinalSink(t *testing.T) {
	e := analyzeFixture(t)
	file := analyzeFile(t, e, "browser-fixture/Default/cache.txt")
	root := filepath.Dir(filepath.Dir(file))
	if err := os.WriteFile(filepath.Join(root, "Local State"), []byte("dummy fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	b := binding(t, root)
	p := review(t, e, root)
	var selected item
	for _, v := range p.items {
		selected = v
	}
	bin := strings.TrimPrefix(strings.Split(e.env[1], ":")[0], "PATH=")
	stub := "#!/bin/bash\nfor name in Preferences Cookies 'Login Data'; do printf fixture > \"$HOME/Downloads/browser-fixture/Default/$name\"; done\nexec /usr/bin/du \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "du"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{selected})
	if events[1].Status == "trashed" {
		t.Fatalf("late browser credentials passed the final guard: %+v", events)
	}
	assertExists(t, filepath.Join(root, "Default/Cookies"), true)
	if !b.Matches() {
		t.Fatal("fixture changed the root identity instead of exercising the final descendant guard")
	}
}

func TestAnalyzeReviewRejectsChangedBindingAndParentOverlap(t *testing.T) {
	e := analyzeFixture(t)
	child := analyzeFile(t, e, "folder/child.txt")
	parent := filepath.Dir(child)
	p := review(t, e, parent, child)
	if len(p.items) != 1 {
		t.Fatal("overlapping selections were not collapsed")
	}
	covered := false
	e.review(context.Background(), "overlap", []pathbinding.Binding{binding(t, parent), binding(t, child)}, func(v event) {
		if v.Kind == "refused" && v.Path == child && v.Status == "covered" && strings.Contains(v.Message, parent) {
			covered = true
		}
	})
	if !covered {
		t.Fatal("overlapping child was described as kept instead of covered by its parent")
	}
	b := binding(t, child)
	if err := os.Rename(child, child+".old"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(child, []byte("replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	p = e.review(context.Background(), "stale", []pathbinding.Binding{b}, func(event) {})
	if p == nil || len(p.items) != 0 {
		t.Fatal("changed object became executable")
	}
}

func TestAnalyzeFolderKeepsRecognizedCredentialsAndLinks(t *testing.T) {
	e := analyzeFixture(t)
	path := analyzeFile(t, e, "folder/.env")
	var events []event
	p := e.review(context.Background(), "blocked", []pathbinding.Binding{binding(t, filepath.Dir(path))}, func(v event) { events = append(events, v) })
	if p == nil || len(p.items) != 0 || !strings.Contains(events[1].Message, "credentials") {
		t.Fatalf("credentials allowed: %+v", events)
	}
	assertExists(t, path, true)
	if err := os.Rename(path, filepath.Join(filepath.Dir(path), "normal.txt")); err != nil {
		t.Fatal(err)
	}
	// A symlink subtree is kept, with a distinct useful refusal.
	if err := os.Symlink(e.home, filepath.Join(filepath.Dir(path), "link")); err != nil {
		t.Fatal(err)
	}
	var linkedEvents []event
	p = e.review(context.Background(), "linked", []pathbinding.Binding{binding(t, filepath.Dir(path))}, func(v event) { linkedEvents = append(linkedEvents, v) })
	if p == nil || len(p.items) != 0 || !strings.Contains(linkedEvents[1].Message, "symbolic link") {
		t.Fatal("linked subtree became executable")
	}
}

func TestAnalyzeNativeTransportFailureNeverFallsBack(t *testing.T) {
	e := analyzeFixture(t)
	a, b := analyzeFile(t, e, "transport-first.txt"), analyzeFile(t, e, "transport-next.txt")
	p := review(t, e, a, b)
	var entries []item
	for _, path := range []string{a, b} {
		for _, v := range p.items {
			if v.Path == path {
				entries = append(entries, v)
			}
		}
	}
	var env []string
	for _, value := range e.env {
		if !strings.HasPrefix(value, "MOLE_TEST_NO_AUTH=") && !strings.HasPrefix(value, "MOLE_TEST_TRASH_DIR=") {
			env = append(env, value)
		}
	}
	e.env = env
	bin := strings.TrimPrefix(strings.Split(e.env[1], ":")[0], "PATH=")
	if err := os.WriteFile(filepath.Join(bin, "trash"), []byte("#!/bin/bash\nprintf native >> \"$HOME/transport-trace\"\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "osascript"), []byte("#!/bin/bash\nprintf FORBIDDEN_FINDER >> \"$HOME/transport-trace\"\nexit 97\n"), 0700); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, entries)
	assertExists(t, a, true)
	assertExists(t, b, true)
	trace, err := os.ReadFile(filepath.Join(e.home, "transport-trace"))
	if err != nil || string(trace) != "native" {
		t.Fatalf("native transport fallback or retry: %v %s", err, trace)
	}
	if len(events) != 3 || events[1].Status != "unverified" {
		t.Fatalf("uncertain move did not stop next item: %+v", events)
	}
}

func TestAnalyzeWhitelistChangesAndParentReplacementAreKept(t *testing.T) {
	e := analyzeFixture(t)
	path := analyzeFile(t, e, "rebind/file.txt")
	p := review(t, e, path)
	var v item
	for _, entry := range p.items {
		v = entry
	}
	dir := filepath.Dir(path)
	if err := os.Rename(dir, dir+".old"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(filepath.Join(dir+".old", "file.txt"), path); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{v})
	if events[1].Status == "trashed" {
		t.Fatal("replacement parent inherited approval")
	}
	assertExists(t, path, true)
	normal := analyzeFile(t, e, "new-whitelist.txt")
	p = review(t, e, normal)
	for _, entry := range p.items {
		v = entry
	}
	config := filepath.Join(e.home, ".config/mole")
	if err := os.MkdirAll(config, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config, "whitelist"), []byte(normal+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	events = collectClean(e, []item{v})
	if events[1].Status == "trashed" {
		t.Fatal("new whitelist was ignored")
	}
	assertExists(t, normal, true)
}

func TestAnalyzeNewProtectionAtFinalSinkAndCancellation(t *testing.T) {
	e := analyzeFixture(t)
	child := analyzeFile(t, e, "late-folder/nested/normal.txt")
	parent := filepath.Dir(filepath.Dir(child))
	p := review(t, e, parent)
	var v item
	for _, entry := range p.items {
		v = entry
	}
	bin := strings.TrimPrefix(strings.Split(e.env[1], ":")[0], "PATH=")
	stub := "#!/bin/bash\nprintf fixture > \"$HOME/Downloads/late-folder/nested/.env\"\nexec /usr/bin/du \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "du"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{v})
	if events[1].Status == "trashed" {
		t.Fatalf("late credentials passed final sink: %+v", events)
	}
	assertExists(t, parent, true)
	if err := os.Remove(filepath.Join(bin, "du")); err != nil {
		t.Fatal(err)
	}
	a, b := analyzeFile(t, e, "cancel-first.txt"), analyzeFile(t, e, "cancel-second.txt")
	p = review(t, e, a, b)
	var entries []item
	for _, path := range []string{a, b} {
		for _, entry := range p.items {
			if entry.Path == path {
				entries = append(entries, entry)
			}
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	e.clean(ctx, "cancel", entries, func(v event) {
		if v.Kind == "result" {
			cancel()
		}
	})
	assertExists(t, a, false)
	assertExists(t, b, true)
}

func TestAnalyzeCleanProtocolCannotAcceptPaths(t *testing.T) {
	e := fixture(t)
	path := analyzeFile(t, e, "kept.txt")
	input, _ := json.Marshal(command{Action: "review", ID: "wrong", Candidates: []pathbinding.Binding{binding(t, path)}})
	var output strings.Builder
	run(strings.NewReader(string(input)+"\n"), &output, e)
	if !strings.Contains(output.String(), "unavailable in Clean") {
		t.Fatal(output.String())
	}
	assertExists(t, path, true)
}
