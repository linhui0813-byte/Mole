//go:build darwin

// Shared native selection protocol. Review binds candidates to objects;
// execution accepts only opaque IDs from the private, expiring plan.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/tw93/mole/desktop/pathbinding"
)

type item struct {
	ID                                   string `json:"id"`
	Category                             string `json:"category"`
	Path                                 string `json:"path"`
	Bytes                                uint64 `json:"bytes"`
	identity, parent, parentID, targetID string
	binding                              string
}

type command struct {
	Action     string                `json:"action"`
	ID         string                `json:"request_id"`
	IDs        []string              `json:"ids"`
	Candidates []pathbinding.Binding `json:"candidates"`
}

type event struct {
	Path      string `json:"path,omitempty"`
	Kind      string `json:"kind"`
	RequestID string `json:"request_id"`
	Item      *item  `json:"item,omitempty"`
	ItemID    string `json:"item_id,omitempty"`
	Status    string `json:"status,omitempty"`
	Message   string `json:"message,omitempty"`
	Checked   int    `json:"checked,omitempty"`
	Total     int    `json:"total,omitempty"`
	Kept      int    `json:"kept,omitempty"`
	Partial   bool   `json:"partial,omitempty"`
}

type engine struct {
	root, script, home, trashBin string
	analyze                      bool
	env                          []string
}

type plan struct {
	items   map[string]item
	created time.Time
}

func token() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}

func main() {
	analyze := len(os.Args) == 2 && os.Args[1] == "--analyze-actions"
	if len(os.Args) != 1 && !analyze {
		os.Exit(64)
	}
	if os.Geteuid() == 0 {
		fmt.Fprintln(os.Stderr, "Run the dashboard as your regular user.")
		os.Exit(1)
	}
	exe, err := os.Executable()
	if err != nil {
		os.Exit(1)
	}
	helperDir := filepath.Dir(exe)
	resources := filepath.Join(helperDir, "../Resources")
	home, err := os.UserHomeDir()
	if err != nil || !filepath.IsAbs(home) || home == "/" {
		os.Exit(1)
	}
	e := engine{root: filepath.Join(resources, ".MoleEngine"), script: filepath.Join(resources, ".Clean/clean.sh"),
		home: home, trashBin: filepath.Join(helperDir, "TrashTool")}
	if analyze {
		e.analyze = true
		e.script = filepath.Join(resources, ".Analyze/actions.sh")
	}
	e.env = []string{"HOME=" + home, "PATH=" + e.trashBin + ":/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C", "LANG=C", "TERM=xterm-256color"}
	if analyze {
		e.env = append(e.env, "MOLE_DASHBOARD_ANALYZE_GATE="+filepath.Join(helperDir, "mole-dashboard-analyzer"))
	}
	if deno := os.Getenv("DENO_DIR"); deno != "" {
		e.env = append(e.env, "DENO_DIR="+deno)
	}
	// Honor no-auth as a refusal, never expose fixture Trash routing through
	// the packaged helper. Unit tests inject it into their isolated engine.
	if os.Getenv("MOLE_TEST_NO_AUTH") == "1" {
		e.env = append(e.env, "MOLE_TEST_NO_AUTH=1")
	}
	run(os.Stdin, os.Stdout, e)
}

func run(input io.Reader, output io.Writer, e engine) {
	var writeMu sync.Mutex
	encoder := json.NewEncoder(output)
	emit := func(v event) { writeMu.Lock(); defer writeMu.Unlock(); _ = encoder.Encode(v) }
	commands := make(chan command)
	go func() {
		defer close(commands)
		scanner := bufio.NewScanner(input)
		scanner.Buffer(make([]byte, 4096), 1<<20)
		for scanner.Scan() {
			var c command
			if json.Unmarshal(scanner.Bytes(), &c) != nil || c.ID == "" {
				continue
			}
			commands <- c
		}
	}()
	type completion struct {
		p     *plan
		final event
	}
	done := make(chan completion, 1)
	launch := func(operation func(func(event)) *plan) {
		go func() {
			var final event
			p := operation(func(v event) {
				if v.Kind == "scan_done" || v.Kind == "clean_done" {
					final = v
				} else {
					emit(v)
				}
			})
			done <- completion{p, final}
		}()
	}
	var cancel context.CancelFunc
	var current *plan
	parent := os.Getppid()
	watch := time.NewTicker(time.Second)
	defer watch.Stop()
	for {
		select {
		case <-watch.C:
			if os.Getppid() != parent {
				if cancel != nil {
					cancel()
					select {
					case <-done:
					case <-time.After(2 * time.Second):
					}
				}
				return
			}
		case result := <-done:
			cancel()
			cancel = nil
			current = result.p
			emit(result.final)
		case c, ok := <-commands:
			if !ok {
				if cancel != nil {
					cancel()
					<-done
				}
				return
			}
			if c.Action == "cancel" {
				if cancel != nil {
					cancel()
				}
				continue
			}
			if cancel != nil {
				emit(event{Kind: "error", RequestID: c.ID, Message: "An operation is still running."})
				continue
			}
			var ctx context.Context
			switch c.Action {
			case "review":
				if !e.analyze {
					emit(event{Kind: "error", RequestID: c.ID, Message: "Analyze review is unavailable in Clean."})
					continue
				}
				current = nil
				ctx, cancel = context.WithTimeout(context.Background(), 2*time.Minute)
				launch(func(events func(event)) *plan { return e.review(ctx, c.ID, c.Candidates, events) })
			case "scan":
				if e.analyze {
					emit(event{Kind: "error", RequestID: c.ID, Message: "Select Analyze items and review them first."})
					continue
				}
				current = nil
				ctx, cancel = context.WithTimeout(context.Background(), 2*time.Minute)
				launch(func(events func(event)) *plan { return e.scan(ctx, c.ID, events) })
			case "clean":
				selected, err := selectItems(current, c.IDs, time.Now())
				current = nil // Every execution attempt consumes the plan, including refusals.
				if err != nil {
					emit(event{Kind: "error", RequestID: c.ID, Message: err.Error()})
					continue
				}
				ctx, cancel = context.WithTimeout(context.Background(), 10*time.Minute)
				launch(func(events func(event)) *plan { e.clean(ctx, c.ID, selected, events); return nil })
			default:
				emit(event{Kind: "error", RequestID: c.ID, Message: "Unsupported Clean request."})
			}
		}
	}
}

func selectItems(p *plan, ids []string, now time.Time) ([]item, error) {
	if p == nil || now.Sub(p.created) > 15*time.Minute {
		return nil, errors.New("The scan has expired. Scan again before cleaning.")
	}
	if len(ids) == 0 {
		return nil, errors.New("Select at least one item.")
	}
	selected := make([]item, 0, len(ids))
	seen := make(map[string]bool)
	for _, id := range ids {
		v, ok := p.items[id]
		if !ok || seen[id] {
			return nil, errors.New("The selection does not match this scan. Scan again.")
		}
		seen[id] = true
		selected = append(selected, v)
	}
	return selected, nil
}

func (e engine) scan(ctx context.Context, requestID string, emit func(event)) *plan {
	type root struct{ category, path string }
	roots := []root{{"caches", "Library/Caches"}, {"logs", "Library/Logs"},
		{"reports", "Library/Logs/DiagnosticReports"}, {"reports", "Library/DiagnosticReports"}}
	var candidates []item
	partial, kept := false, 0
	for _, r := range roots {
		if ctx.Err() != nil {
			break
		}
		path := filepath.Join(e.home, r.path)
		if err := safeAncestors(e.home, path); err != nil {
			if !os.IsNotExist(err) {
				partial = true
			}
			continue
		}
		entries, err := os.ReadDir(path)
		if err != nil {
			if !os.IsNotExist(err) {
				partial = true
			}
			continue
		}
		// Discard incomplete roots instead of feeding a partial listing to cleanup.
		for _, entry := range entries {
			if len(candidates) >= 1000 {
				partial = true
				break
			}
			if r.category == "logs" && (entry.Name() == "DiagnosticReports" || entry.Name() == "mole") {
				continue
			}
			if entry.Type()&os.ModeSymlink != 0 || !utf8.ValidString(entry.Name()) {
				kept++
				continue
			}
			candidates = append(candidates, item{Category: r.category, Path: filepath.Join(path, entry.Name())})
		}
	}
	p := &plan{items: make(map[string]item)}
	type inspection struct {
		value item
		err   error
	}
	jobs := make(chan item)
	results := make(chan inspection, 4)
	var workers sync.WaitGroup
	for range 4 {
		workers.Go(func() {
			for candidate := range jobs {
				value, err := e.inspect(ctx, candidate)
				results <- inspection{value, err}
			}
		})
	}
	go func() {
		defer close(jobs)
		for _, candidate := range candidates {
			select {
			case jobs <- candidate:
			case <-ctx.Done():
				return
			}
		}
	}()
	go func() { workers.Wait(); close(results) }()
	checked := 0
	emit(event{Kind: "progress", RequestID: requestID, Total: len(candidates), Message: "Preparing item checks"})
	for result := range results {
		checked++
		value, err := result.value, result.err
		emit(event{Kind: "progress", RequestID: requestID, Checked: checked, Total: len(candidates), Message: filepath.Base(value.Path)})
		if err != nil {
			kept++
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 65 {
				partial = true
			}
			continue
		}
		if value.Bytes == 0 {
			kept++
			continue
		}
		value.ID = token()
		p.items[value.ID] = value
		emit(event{Kind: "item", RequestID: requestID, Item: &value})
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		emit(event{Kind: "scan_done", RequestID: requestID, Status: "cancelled", Partial: true,
			Message: "Scan stopped. Scan again before cleaning."})
		return nil
	}
	message := ""
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		partial = true
		message = "Scan reached its time limit. Review the completed item checks."
	}
	p.created = time.Now()
	emit(event{Kind: "scan_done", RequestID: requestID, Status: "ready", Total: len(p.items), Kept: kept, Partial: partial, Message: message})
	return p
}

func safeAncestors(home, path string) error {
	if !strings.HasPrefix(path, home+string(os.PathSeparator)) {
		return errors.New("outside HOME")
	}
	for path != home {
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("redirected ancestor")
		}
		path = filepath.Dir(path)
	}
	return nil
}

func (e engine) invoke(ctx context.Context, action string, v item, extra ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if e.analyze {
		extra = append(extra, v.binding)
	}
	args := append([]string{e.script, e.root, action, v.Category, v.Path}, extra...)
	cmd := exec.CommandContext(ctx, "/bin/bash", args...)
	cmd.Env = e.env
	if e.analyze {
		scratch, err := os.MkdirTemp("", "mole-analyze-invoke-")
		if err != nil {
			return nil, err
		}
		defer os.RemoveAll(scratch) // Only this invocation's private scratch directory.
		cmd.Env = append(slices.Clone(e.env), "TMPDIR="+scratch)
	}
	cmd.Stdin = nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = time.Second
	// The shell's stdout is a private NUL-delimited contract, never TUI text.
	return cmd.Output()
}

func (e engine) inspect(ctx context.Context, v item) (item, error) {
	output, err := e.invoke(ctx, "inspect", v)
	if err != nil {
		return v, err
	}
	fields := strings.Split(string(output), "\x00")
	if len(fields) != 6 || fields[5] != "" {
		return v, errors.New("invalid inspection response")
	}
	kb, err := strconv.ParseUint(fields[0], 10, 54)
	if err != nil {
		return v, err
	}
	v.Bytes = kb * 1024
	v.identity, v.parent, v.parentID, v.targetID = fields[1], fields[2], fields[3], fields[4]
	if v.identity == "" || v.parent == "" || v.parentID == "" || v.targetID == "" {
		return v, errors.New("missing identity")
	}
	return v, nil
}

func (e engine) clean(ctx context.Context, requestID string, selected []item, emit func(event)) {
	for index, v := range selected {
		if ctx.Err() != nil {
			break
		}
		emit(event{Kind: "progress", RequestID: requestID, Checked: index, Total: len(selected), Message: filepath.Base(v.Path)})
		_, err := e.invoke(ctx, "trash", v, v.identity, v.parent, v.parentID, v.targetID)
		status, message := "trashed", "Moved to Trash"
		if err != nil {
			status, message = "kept", "Kept: protected, active, changed, or not accessible. Scan again to review it."
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() != 65 {
				status, message = "unverified", "Move was not confirmed. Check the original item and Trash before retrying."
			}
			if exit != nil {
				for _, line := range strings.Split(string(exit.Stderr), "\n") {
					if reason, ok := strings.CutPrefix(line, "CLEAN_REASON:"); ok {
						message = reason + ". Scan again to review the current item."
					}
				}
			}
		}
		emit(event{Kind: "result", RequestID: requestID, ItemID: v.ID, Status: status, Message: message})
		// An uncertain result stops later mutations rather than guessing.
		if status == "unverified" {
			break
		}
	}
	status := "finished"
	if ctx.Err() != nil {
		status = "cancelled"
	}
	emit(event{Kind: "clean_done", RequestID: requestID, Status: status})
}
