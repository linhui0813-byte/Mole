//go:build darwin

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T) engine {
	t.Helper()
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(t.TempDir(), "home")
	bin := filepath.Join(t.TempDir(), "bin")
	for _, dir := range []string{home, bin, filepath.Join(home, "Library/Caches"), filepath.Join(home, "Library/Logs/DiagnosticReports")} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	// Prove complete visibility in fixtures only. Every actual probe is traced;
	// no sudo, Finder, launchctl, or real Trash is reachable from this harness.
	stub := `#!/bin/bash
printf '%s\n' "$*" >> "$HOME/lsof-trace"
if [[ "$*" == *'-p 1'* ]]; then printf 'p1\nu0\n'; exit 0; fi
if [[ "$*" == *'late-busy-cache'* && -e "$HOME/open-now" ]]; then printf 'p123\nf4\nnfixture\n'; exit 0; fi
if [[ "$*" == *'unknown-cache'* ]]; then echo 'visibility unavailable' >&2; exit 1; fi
if [[ "$*" == *'open-cache'* ]]; then printf 'p123\nf4\nnfixture\n'; exit 0; fi
exit 1
`
	if err := os.WriteFile(filepath.Join(bin, "lsof"), []byte(stub), 0700); err != nil {
		t.Fatal(err)
	}
	ps := "#!/bin/bash\nif [[ \"$*\" == *'pid=,comm='* ]]; then printf '1 /sbin/launchd\\n'; else printf 'PID PPID COMMAND ARGS\\n1 0 /sbin/launchd /sbin/launchd\\n'; fi\n"
	if err := os.WriteFile(filepath.Join(bin, "ps"), []byte(ps), 0700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"sudo", "osascript", "launchctl"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("#!/bin/sh\necho UNEXPECTED_AUTH >&2\nexit 97\n"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	return engine{root: root, script: filepath.Join(root, "desktop/Engine/clean.sh"), home: home,
		env: []string{"HOME=" + home, "PATH=" + bin + ":/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "TERM=xterm-256color",
			"MOLE_TEST_NO_AUTH=1", "MOLE_TEST_TRASH_DIR=" + filepath.Join(home, "fixture-trash")}}
}

func TestFinalGuardKeepsFileOpenedDuringSizing(t *testing.T) {
	e := fixture(t)
	path := filepath.Join(e.home, "Library/Caches/com.molefixture.late-busy-cache")
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "payload.db"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	v := inspect(t, e, item{Category: "caches", Path: path})
	bin := strings.TrimPrefix(strings.Split(e.env[1], ":")[0], "PATH=")
	du := "#!/bin/bash\ntouch \"$HOME/open-now\"\nexec /usr/bin/du \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "du"), []byte(du), 0700); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{v})
	if events[1].Status == "trashed" {
		t.Fatalf("late-open file was moved: %+v", events)
	}
	assertExists(t, v.Path, true)
	assertExists(t, filepath.Join(e.home, "open-now"), true)
}

func cacheFile(t *testing.T, e engine, name string) item {
	t.Helper()
	path := filepath.Join(e.home, "Library/Caches", name)
	if err := os.WriteFile(path, []byte(strings.Repeat("fixture", 1024)), 0600); err != nil {
		t.Fatal(err)
	}
	return item{Category: "caches", Path: path}
}

func inspect(t *testing.T, e engine, v item) item {
	t.Helper()
	value, err := e.inspect(context.Background(), v)
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			t.Fatalf("positive inspection failed: %v: %s", err, exit.Stderr)
		}
		t.Fatalf("positive inspection failed: %v", err)
	}
	value.ID = token()
	return value
}

func collectClean(e engine, items []item) []event {
	var events []event
	e.clean(context.Background(), "test", items, func(v event) { events = append(events, v) })
	return events
}

func assertExists(t *testing.T, path string, exists bool) {
	t.Helper()
	_, err := os.Lstat(path)
	if (err == nil) != exists {
		t.Fatalf("existence of %q: %v, wanted %v", path, err, exists)
	}
}

func TestScanSelectAndTrashOnlyReviewedItem(t *testing.T) {
	e := fixture(t)
	a := cacheFile(t, e, "cache space ' quote $(literal) [1] 测试")
	b := cacheFile(t, e, "unselected-cache")
	var final event
	p := e.scan(context.Background(), "scan", func(v event) {
		if v.Kind == "scan_done" {
			final = v
		}
	})
	if p == nil || len(p.items) != 2 || final.Status != "ready" {
		t.Fatalf("scan did not reach both fixtures: %+v, %+v", p, final)
	}
	var id string
	for key, v := range p.items {
		if v.Path == a.Path {
			id = key
		}
	}
	selected, err := selectItems(p, []string{id}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, selected)
	if len(events) != 3 || events[1].Status != "trashed" {
		t.Fatalf("move did not execute: %+v", events)
	}
	assertExists(t, a.Path, false)
	assertExists(t, b.Path, true)
	entries, err := os.ReadDir(filepath.Join(e.home, "fixture-trash"))
	if err != nil || len(entries) != 1 {
		t.Fatalf("recoverable move missing: %v %+v", err, entries)
	}
	logs, err := os.ReadFile(filepath.Join(e.home, "Library/Logs/mole/operations.log"))
	if err != nil || !strings.Contains(string(logs), "TRASHED") || !strings.Contains(string(logs), a.Path) {
		t.Fatalf("operation log missing: %v %s", err, logs)
	}
}

func TestReplacedItemAndParentAreKept(t *testing.T) {
	for _, swapParent := range []bool{false, true} {
		t.Run(map[bool]string{false: "item", true: "parent"}[swapParent], func(t *testing.T) {
			e := fixture(t)
			v := inspect(t, e, cacheFile(t, e, "replacement-cache"))
			if swapParent {
				dir := filepath.Dir(v.Path)
				if err := os.Rename(dir, dir+"-old"); err != nil {
					t.Fatal(err)
				}
				if err := os.Mkdir(dir, 0700); err != nil {
					t.Fatal(err)
				}
			} else if err := os.Rename(v.Path, v.Path+"-old"); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(v.Path, []byte("replacement must survive"), 0600); err != nil {
				t.Fatal(err)
			}
			events := collectClean(e, []item{v})
			if events[1].Status != "kept" || !strings.Contains(events[1].Message, "changed since") {
				t.Fatalf("replacement accepted: %+v", events)
			}
			assertExists(t, v.Path, true)
		})
	}
}

func TestNewWhitelistIsRespectedAtExecution(t *testing.T) {
	e := fixture(t)
	v := inspect(t, e, cacheFile(t, e, "new-whitelist-cache"))
	config := filepath.Join(e.home, ".config/mole")
	if err := os.MkdirAll(config, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(config, "whitelist"), []byte(v.Path+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{v})
	if events[1].Status != "kept" || !strings.Contains(events[1].Message, "whitelist") {
		t.Fatalf("whitelist bypassed: %+v", events)
	}
	assertExists(t, v.Path, true)
}

func TestAuthenticationCacheIsKeptInPreviewAndExecution(t *testing.T) {
	e := fixture(t)
	_ = inspect(t, e, cacheFile(t, e, "ordinary-cache-positive"))
	v := cacheFile(t, e, "aws_credentials_cache.json")
	for _, action := range []string{"inspect", "trash"} {
		_, err := e.invoke(context.Background(), action, v)
		var exit *exec.ExitError
		if !errors.As(err, &exit) || exit.ExitCode() != 65 ||
			!strings.Contains(string(exit.Stderr), "CLEAN_REASON:Authentication cache is kept") {
			t.Fatalf("authentication cache was not protected in %s: %v %+v", action, err, exit)
		}
		assertExists(t, v.Path, true)
	}
	// Aliases of the same object cannot bypass the exact-path protection.
	alias := filepath.Join(e.home, "Library/Caches/auth-cache-alias")
	if err := os.Link(v.Path, alias); err != nil {
		t.Fatal(err)
	}
	if _, err := e.inspect(context.Background(), item{Category: "caches", Path: alias}); err == nil {
		t.Fatal("authentication cache hard link was accepted")
	}
}

func TestAuthenticationAliasAppearingDuringSizingIsKept(t *testing.T) {
	e := fixture(t)
	v := inspect(t, e, cacheFile(t, e, "ordinary-cache"))
	// Inject the external stat dependency after loading the actual adapter.
	// The sizing probe creates an authentication-path hard link after the
	// initial check, so only the final guard can preserve the selected alias.
	data, err := os.ReadFile(e.script)
	if err != nil {
		t.Fatal(err)
	}
	anchor := `source "$engine_root/bin/clean.sh" > /dev/null`
	if strings.Count(string(data), anchor) != 1 {
		t.Fatal("adapter source seam changed")
	}
	e.script = filepath.Join(t.TempDir(), "adapter.sh")
	if err := os.WriteFile(e.script, []byte(strings.Replace(string(data), anchor,
		anchor+"\nSTAT_BSD=\"$HOME/fixture-stat\"", 1)), 0600); err != nil {
		t.Fatal(err)
	}
	stat := `#!/bin/bash
if [[ "$1" == '-f%b' && ! -e "$HOME/Library/Caches/aws_credentials_cache.json" ]]; then
    /bin/ln "$HOME/Library/Caches/ordinary-cache" "$HOME/Library/Caches/aws_credentials_cache.json" || exit 1
fi
exec /usr/bin/stat "$@"
`
	if err := os.WriteFile(filepath.Join(e.home, "fixture-stat"), []byte(stat), 0700); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{v})
	if events[1].Status == "trashed" {
		t.Fatalf("late authentication alias was moved: %+v", events)
	}
	assertExists(t, v.Path, true)
	assertExists(t, filepath.Join(e.home, "Library/Caches/aws_credentials_cache.json"), true)
}

func TestUnsafeScopesAndOpenOrUnknownItemsAreKept(t *testing.T) {
	e := fixture(t)
	positive := cacheFile(t, e, "positive-cache")
	_ = inspect(t, e, positive)
	_ = inspect(t, e, cacheFile(t, e, "idle-positive.db"))
	trace, _ := os.ReadFile(filepath.Join(e.home, "lsof-trace"))
	if !strings.Contains(string(trace), "idle-positive.db") {
		t.Fatal("positive control: SQLite handle probe never ran")
	}
	open := cacheFile(t, e, "open-cache.db")
	unknown := cacheFile(t, e, "unknown-cache.db")
	for _, v := range []item{open, unknown, {Category: "caches", Path: filepath.Dir(positive.Path)},
		{Category: "logs", Path: positive.Path}, {Category: "caches", Path: filepath.Join(e.home, "Library/Caches/..")}} {
		if _, err := e.inspect(context.Background(), v); err == nil {
			t.Fatalf("unsafe candidate accepted: %+v", v)
		}
	}
	assertExists(t, positive.Path, true)
}

func TestRedirectedRootAndDenoAreKept(t *testing.T) {
	e := fixture(t)
	v := inspect(t, e, cacheFile(t, e, "bound-cache"))
	root := filepath.Dir(v.Path)
	if err := os.Rename(root, root+"-old"); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(root+"-old", root); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{v})
	if events[1].Status != "kept" || !strings.Contains(events[1].Message, "Redirected") {
		t.Fatalf("redirect accepted: %+v", events)
	}
	assertExists(t, v.Path, true)
	p := e.scan(context.Background(), "scan", func(event) {})
	if p == nil || len(p.items) != 0 {
		t.Fatalf("scan followed symlink: %+v", p)
	}
	e = fixture(t)
	deno := cacheFile(t, e, "deno-state")
	e.env = append(e.env, "DENO_DIR="+deno.Path)
	if _, err := e.inspect(context.Background(), deno); err == nil {
		t.Fatal("Deno owner root accepted")
	}
}

func TestCancellationStopsNextEligibleItem(t *testing.T) {
	e := fixture(t)
	a := inspect(t, e, cacheFile(t, e, "first-cache"))
	b := inspect(t, e, cacheFile(t, e, "later-eligible-cache")) // Positive control for the later item.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var results []event
	e.clean(ctx, "clean", []item{a, b}, func(v event) {
		if v.Kind == "result" {
			results = append(results, v)
			cancel()
		}
	})
	if len(results) != 1 || results[0].Status != "trashed" {
		t.Fatalf("positive move missing: %+v", results)
	}
	assertExists(t, a.Path, false)
	assertExists(t, b.Path, true)
}

func TestUnverifiedMoveStopsBeforeLaterEligibleItem(t *testing.T) {
	e := fixture(t)
	a := inspect(t, e, cacheFile(t, e, "first-cache"))
	b := inspect(t, e, cacheFile(t, e, "later-cache"))
	trash := filepath.Join(e.home, "fixture-trash")
	if err := os.WriteFile(trash, []byte("block fixture Trash"), 0600); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{a, b})
	if len(events) != 3 || events[1].Status != "unverified" {
		t.Fatalf("uncertain move did not stop: %+v", events)
	}
	assertExists(t, a.Path, true)
	assertExists(t, b.Path, true)
	if err := os.Remove(trash); err != nil {
		t.Fatal(err)
	}
	positive := collectClean(e, []item{b})
	if positive[1].Status != "trashed" {
		t.Fatalf("later item was not otherwise eligible: %+v", positive)
	}
}

func TestLogsAndReportsKeepTheirDirectoriesAndMoleHistory(t *testing.T) {
	e := fixture(t)
	paths := []string{"Library/Logs/example.log", "Library/Logs/DiagnosticReports/example.ips", "Library/DiagnosticReports/other.ips", "Library/Logs/mole/history.log"}
	for _, relative := range paths {
		path := filepath.Join(e.home, relative)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	p := e.scan(context.Background(), "scan", func(event) {})
	if p == nil || len(p.items) != 3 {
		t.Fatalf("wrong log/report scope: %+v", p)
	}
	var selected []item
	for _, v := range p.items {
		selected = append(selected, v)
	}
	events := collectClean(e, selected)
	for _, v := range events {
		if v.Kind == "result" && v.Status != "trashed" {
			t.Fatalf("log/report move failed: %+v", v)
		}
	}
	assertExists(t, filepath.Join(e.home, "Library/Logs/DiagnosticReports"), true)
	assertExists(t, filepath.Join(e.home, "Library/DiagnosticReports"), true)
	assertExists(t, filepath.Join(e.home, paths[3]), true)
}

func TestPlanRejectsExpiredUnknownDuplicateAndEmptySelection(t *testing.T) {
	p := &plan{items: map[string]item{"a": {ID: "a"}}, created: time.Now()}
	for _, ids := range [][]string{nil, {"unknown"}, {"a", "a"}, {"a", "unknown"}} {
		if _, err := selectItems(p, ids, time.Now()); err == nil {
			t.Fatalf("invalid selection accepted: %v", ids)
		}
	}
	if _, err := selectItems(p, []string{"a"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := selectItems(p, []string{"a"}, time.Now().Add(16*time.Minute)); err == nil {
		t.Fatal("expired plan accepted")
	}
}

func TestCancelledScanCannotAuthorizeAndDeadlineIsPartial(t *testing.T) {
	e := fixture(t)
	_ = cacheFile(t, e, "otherwise-eligible")
	positive := e.scan(context.Background(), "positive", func(event) {})
	if positive == nil || len(positive.items) != 1 {
		t.Fatal("positive scan failed")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if p := e.scan(ctx, "cancelled", func(event) {}); p != nil {
		t.Fatal("cancelled scan authorized cleaning")
	}
	ctx, cancel = context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	var final event
	p := e.scan(ctx, "deadline", func(v event) {
		if v.Kind == "scan_done" {
			final = v
		}
	})
	if p == nil || !final.Partial || final.Status != "ready" || len(p.items) != 0 {
		t.Fatalf("deadline misreported: %+v %+v", p, final)
	}
}

func TestProtocolUsesServerPlanAndConsumesIt(t *testing.T) {
	e := fixture(t)
	_ = cacheFile(t, e, "protocol-cache")
	inputReader, inputWriter := io.Pipe()
	outputReader, outputWriter := io.Pipe()
	finished := make(chan struct{})
	go func() { run(inputReader, outputWriter, e); outputWriter.Close(); close(finished) }()
	defer inputWriter.Close()
	responses := make(chan event)
	go func() {
		s := bufio.NewScanner(outputReader)
		for s.Scan() {
			var v event
			if json.Unmarshal(s.Bytes(), &v) == nil {
				responses <- v
			}
		}
	}()
	encoder := json.NewEncoder(inputWriter)
	next := func(kind string) event {
		for {
			select {
			case v := <-responses:
				if v.Kind == kind {
					return v
				}
			case <-time.After(30 * time.Second):
				t.Fatalf("no %s response", kind)
				return event{}
			}
		}
	}
	if err := encoder.Encode(command{Action: "scan", ID: "s1"}); err != nil {
		t.Fatal(err)
	}
	v := next("item")
	if v.Item == nil {
		t.Fatal("missing real candidate")
	}
	_ = next("scan_done")
	if err := encoder.Encode(command{Action: "clean", ID: "c1", IDs: []string{v.Item.ID}}); err != nil {
		t.Fatal(err)
	}
	result := next("result")
	if result.Status != "trashed" {
		t.Fatalf("protocol execution failed: %+v", result)
	}
	_ = next("clean_done")
	if err := encoder.Encode(command{Action: "clean", ID: "c2", IDs: []string{v.Item.ID}}); err != nil {
		t.Fatal(err)
	}
	if stale := next("error"); !strings.Contains(stale.Message, "expired") {
		t.Fatalf("plan reusable: %+v", stale)
	}
	inputWriter.Close()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("helper did not exit on EOF")
	}
}
