//go:build darwin

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"

	"github.com/tw93/mole/desktop/pathbinding"
)

type application struct {
	ID              string              `json:"id"`
	Path            string              `json:"path"`
	Name            string              `json:"name"`
	BundleID        string              `json:"bundle_id"`
	Version         string              `json:"version"`
	Reason          string              `json:"reason,omitempty"`
	Binding         pathbinding.Binding `json:"binding"`
	PlistHash       string              `json:"plist_hash"`
	Executable      string              `json:"executable"`
	SizeBytes       *uint64             `json:"size_bytes"`
	LastActive      *int64              `json:"last_active"`
	MetadataPending bool                `json:"metadata_pending"`
}

func cleanText(s string) bool {
	return s != "" && !strings.ContainsFunc(s, unicode.IsControl)
}

func appScope(home, path string) bool {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || !strings.EqualFold(filepath.Ext(path), ".app") {
		return false
	}
	for _, root := range []string{"/Applications", filepath.Join(home, "Applications")} {
		parent := filepath.Dir(path)
		if parent == root || (filepath.Dir(parent) == root && !strings.EqualFold(filepath.Ext(parent), ".app")) {
			return true
		}
	}
	return false
}

func readApplication(ctx context.Context, path string) (application, error) {
	a := application{ID: token(), Path: path, Name: strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))}
	b, err := pathbinding.Read(path)
	if err != nil {
		return a, errors.New("Linked or inaccessible app. Use its installer or package manager to remove it.")
	}
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		return a, errors.New("The app is not a real directory. Refresh the list.")
	}
	plist := filepath.Join(path, "Contents/Info.plist")
	if _, err = pathbinding.Read(plist); err != nil {
		return a, errors.New("App metadata is missing or redirected. Use its official uninstaller.")
	}
	plistInfo, err := os.Stat(plist)
	if err != nil || plistInfo.Size() > 2<<20 {
		return a, errors.New("App metadata exceeds its read limit.")
	}
	plistBinding, err := pathbinding.Read(plist)
	if err != nil {
		return a, err
	}
	file, err := os.OpenFile(plist, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return a, err
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() {
		return a, errors.New("App metadata is not a regular file.")
	}
	data, err := io.ReadAll(io.LimitReader(file, (2<<20)+1))
	if err != nil || len(data) > 2<<20 {
		return a, errors.New("App metadata could not be read within the limit.")
	}
	digest := sha256.Sum256(data)
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "json", "-o", "-", "--", plist)
	raw, err := cmd.Output()
	if err != nil {
		return a, errors.New("App metadata is not a valid property list.")
	}
	var metadata map[string]any
	if json.Unmarshal(raw, &metadata) != nil {
		return a, errors.New("Invalid app metadata.")
	}
	value := func(k string) string { s, _ := metadata[k].(string); return s }
	a.BundleID = value("CFBundleIdentifier")
	a.Version = value("CFBundleShortVersionString")
	a.Executable = value("CFBundleExecutable")
	if name := value("CFBundleDisplayName"); cleanText(name) {
		a.Name = name
	} else if name = value("CFBundleName"); cleanText(name) {
		a.Name = name
	}
	if !regexp.MustCompile(`^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$`).MatchString(a.BundleID) || !cleanText(a.Executable) || strings.ContainsAny(a.Executable, "/\\") || a.Executable == "." || a.Executable == ".." {
		return a, errors.New("App identity is incomplete. Use its official uninstaller.")
	}
	if !b.Matches() || !plistBinding.Matches() {
		return a, errors.New("The app changed while reading its metadata. Refresh the list.")
	}
	a.Binding = b
	a.PlistHash = hex.EncodeToString(digest[:])
	return a, nil
}

func (e engine) applications(ctx context.Context, id string, emit func(event)) *plan {
	p := &plan{apps: map[string]application{}, items: map[string]item{}}
	partial := false
	count := 0
	var metadata []application
	var scan func(string, int)
	scan = func(root string, depth int) {
		if ctx.Err() != nil {
			return
		}
		// Never follow a redirected discovery root or a linked category directory.
		if _, err := pathbinding.Read(root); err != nil {
			if !os.IsNotExist(err) {
				partial = true
			}
			return
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			partial = true
			return
		}
		for _, entry := range entries {
			if ctx.Err() != nil {
				return
			}
			count++
			if count > 2000 {
				partial = true
				return
			}
			path := filepath.Join(root, entry.Name())
			if strings.EqualFold(filepath.Ext(path), ".app") {
				emit(event{Kind: "progress", RequestID: id, Message: entry.Name()})
				app, err := readApplication(ctx, path)
				if err != nil {
					app.Reason = err.Error()
				}
				if app.Reason == "" && (strings.HasPrefix(strings.ToLower(app.BundleID), "com.apple.") || app.BundleID == "local.hui.mole-dashboard") {
					if _, err := e.invoke(ctx, "policy", item{Category: "uninstall-bundle", Path: app.Path, owner: &app}); err != nil {
						app.Reason = inspectionReason(err)
					}
				}
				app.MetadataPending = app.Binding.Path != ""
				if app.MetadataPending {
					metadata = append(metadata, app)
				}
				p.apps[app.ID] = app
				copy := app
				emit(event{Kind: "app", RequestID: id, App: &copy})
			} else if depth > 0 && entry.IsDir() && !strings.HasPrefix(entry.Name(), ".") {
				scan(path, depth-1)
			}
		}
	}
	roots := e.appRoots
	if roots == nil {
		roots = []string{"/Applications", filepath.Join(e.home, "Applications")}
	}
	for _, root := range roots {
		scan(root, 1)
	}
	jobs := make(chan application)
	results := make(chan application, 4)
	var workers sync.WaitGroup
	for range 4 {
		workers.Go(func() {
			for app := range jobs {
				results <- readAppMetadata(ctx, app, appMetadataCommand)
			}
		})
	}
	go func() {
		defer close(jobs)
		for _, app := range metadata {
			select {
			case jobs <- app:
			case <-ctx.Done():
				return
			}
		}
	}()
	go func() { workers.Wait(); close(results) }()
	checked := 0
	for app := range results {
		if ctx.Err() != nil {
			continue
		}
		checked++
		p.apps[app.ID] = app
		copy := app
		emit(event{Kind: "app", RequestID: id, App: &copy})
		emit(event{Kind: "progress", RequestID: id, Checked: checked, Total: len(metadata), Message: app.Name})
	}
	if ctx.Err() != nil {
		emit(event{Kind: "scan_done", RequestID: id, Status: "cancelled", Message: "App scan stopped. Refresh before reviewing."})
		return nil
	}
	p.created = time.Now()
	emit(event{Kind: "scan_done", RequestID: id, Status: "ready", Partial: partial, Message: fmt.Sprintf("%d apps found. Choose an app to review; scanning does not remove files.", len(p.apps))})
	return p
}

func dataPaths(home, id string) []string {
	var paths []string
	for _, root := range []string{"Caches", "Logs", "Application Support", "WebKit", "HTTPStorages"} {
		paths = append(paths, filepath.Join(home, "Library", root, id))
	}
	return append(paths, filepath.Join(home, "Library/Preferences", id+".plist"), filepath.Join(home, "Library/Saved Application State", id+".savedState"))
}

// Casks commonly leave a reverse symlink in Caskroom after moving the real
// bundle to Applications. Inspect those exact links without invoking brew.
func checkCaskOwner(ctx context.Context, app string, roots []string) error {
	info, err := os.Stat(app)
	if err != nil {
		return err
	}
	for _, root := range roots {
		if _, err := os.Lstat(root); os.IsNotExist(err) {
			continue
		}
		count := 0
		err := filepath.WalkDir(root, func(path string, entry os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			count++
			if ctx.Err() != nil || count > 10000 {
				return errors.New("Homebrew ownership scan was incomplete. Check the app with Homebrew before removing it.")
			}
			if path == root && !entry.IsDir() {
				return errors.New("Homebrew ownership root is redirected. Check the app with Homebrew.")
			}
			if strings.EqualFold(filepath.Ext(path), ".app") {
				other, err := os.Stat(path)
				if err != nil && !os.IsNotExist(err) {
					return errors.New("Homebrew app ownership is unknown. Inspect the app with mo uninstall.")
				}
				if err == nil && os.SameFile(info, other) {
					return errors.New("Homebrew manages this app. Use mo uninstall or brew uninstall --cask to keep its package records consistent.")
				}
				if entry.IsDir() {
					return filepath.SkipDir
				}
				return nil // An examined app link is not a redirected version directory.
			}
			if entry.Type()&os.ModeSymlink != 0 {
				other, err := os.Stat(path)
				if err != nil && !os.IsNotExist(err) {
					return err
				}
				if err == nil && other.IsDir() {
					return errors.New("Homebrew ownership includes a linked directory. Inspect this app with mo uninstall.")
				}
			}
			rel, _ := filepath.Rel(root, path)
			if entry.IsDir() && strings.Count(rel, string(os.PathSeparator)) >= 2 {
				return filepath.SkipDir
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	return nil
}

func (e engine) reviewApplication(ctx context.Context, id string, a application, emit func(event)) *plan {
	p := &plan{items: map[string]item{}, created: time.Now()}
	refuse := func(path, reason string) { emit(event{Kind: "refused", RequestID: id, Path: path, Message: reason}) }
	if a.Reason != "" {
		refuse(a.Path, a.Reason)
		emit(event{Kind: "scan_done", RequestID: id, Status: "ready", Message: "This app cannot use generic uninstall. Nothing was moved."})
		return p
	}
	paths := append([]string{a.Path}, dataPaths(e.home, a.BundleID)...)
	kept := 0
	for index, path := range paths {
		if ctx.Err() != nil {
			break
		}
		emit(event{Kind: "progress", RequestID: id, Checked: index, Total: len(paths), Message: filepath.Base(path)})
		b, err := pathbinding.Read(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			refuse(path, "The path is inaccessible or redirected; inspect it in Finder.")
			kept++
			continue
		}
		binding, _ := json.Marshal(b)
		category := "uninstall-data"
		if index == 0 {
			category = "uninstall-bundle"
		}
		v := item{ID: token(), Category: category, Path: path, binding: string(binding), owner: &a}
		v, err = e.inspect(ctx, v)
		if err != nil {
			refuse(path, inspectionReason(err))
			kept++
			if index == 0 {
				break
			}
			continue
		}
		p.items[v.ID] = v
		copy := v
		emit(event{Kind: "item", RequestID: id, Item: &copy})
	}
	if ctx.Err() != nil {
		emit(event{Kind: "scan_done", RequestID: id, Status: "cancelled", Message: "Review stopped. Review again before uninstalling."})
		return nil
	}
	p.created = time.Now()
	message := "Review the app bundle and optional app data. Unchecked data stays on this Mac."
	if len(p.items) == 0 {
		message = "Nothing eligible. Nothing was moved. Inspect the kept app below."
	}
	emit(event{Kind: "scan_done", RequestID: id, Status: "ready", Kept: kept, Message: message})
	return p
}

func uninstallOrder(selected []item) ([]item, error) {
	var bundles []item
	var data []item
	for _, v := range selected {
		if v.owner == nil {
			return nil, errors.New("Missing app ownership. Review again.")
		}
		switch v.Category {
		case "uninstall-bundle":
			bundles = append(bundles, v)
		case "uninstall-data":
			data = append(data, v)
		default:
			return nil, errors.New("Unsupported uninstall selection.")
		}
	}
	if len(bundles) != 1 {
		return nil, errors.New("Select the reviewed app bundle before removing its data.")
	}
	for _, v := range data {
		if v.owner.Path != bundles[0].Path || v.owner.BundleID != bundles[0].owner.BundleID {
			return nil, errors.New("App data belongs to another review.")
		}
	}
	slices.SortFunc(data, func(a, b item) int { return strings.Compare(a.Path, b.Path) })
	return append(bundles, data...), nil
}

// Called again inside the shell's final Trash guard. Input is the helper's
// private plan, never an arbitrary path accepted by the GUI protocol.
func checkUninstall(ownerJSON, bindingJSON, stage string) error {
	if os.Geteuid() == 0 {
		return errors.New("Run uninstall as your regular user.")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	var a application
	var b pathbinding.Binding
	if json.Unmarshal([]byte(ownerJSON), &a) != nil || json.Unmarshal([]byte(bindingJSON), &b) != nil || !appScope(home, a.Path) || !b.Matches() {
		return errors.New("The app, selected item, or physical parent changed. Refresh and review again.")
	}
	if stage != "inspect" && stage != "trash" {
		return errors.New("Invalid review stage.")
	}
	if b.Path == a.Path || stage == "inspect" {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		current, err := readApplication(ctx, a.Path)
		if err != nil || current.Binding != a.Binding || current.PlistHash != a.PlistHash || current.BundleID != a.BundleID || current.Executable != a.Executable {
			return errors.New("App identity changed. Refresh and review again.")
		}
		if b.Path == a.Path {
			if err := checkCaskOwner(ctx, a.Path, []string{"/opt/homebrew/Caskroom", "/usr/local/Caskroom"}); err != nil {
				return err
			}
		}
	} else {
		if _, err := os.Lstat(a.Path); !os.IsNotExist(err) {
			return errors.New("The app is still present or has reappeared. App data is kept.")
		}
	}
	if b.Path != a.Path && !slices.Contains(dataPaths(home, a.BundleID), b.Path) {
		return errors.New("Outside the exact app-data scope.")
	}
	// Apple eligibility belongs to the shared shell policy, repeated inside the
	// final Trash guard. This gate owns object identity and literal process state.
	if a.BundleID == "local.hui.mole-dashboard" {
		return errors.New("This dashboard cannot uninstall itself. Quit it and remove it in Finder.")
	}
	// A literal executable-name probe conservatively retains shared runtime names.
	// Unexpected status and diagnostic output mean unknown, never absence.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "pgrep", "-x", regexp.QuoteMeta(a.Executable))
	output, err := cmd.CombinedOutput()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 || len(output) != 0 {
		return errors.New("The app is running or its process state is unknown. Quit it and its helpers, then review again.")
	}
	return nil
}
