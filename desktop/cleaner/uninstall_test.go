//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/tw93/mole/desktop/pathbinding"
)

func uninstallFixture(t *testing.T) engine {
	t.Helper()
	e := fixture(t)
	e.uninstall = true
	e.script = filepath.Join(e.root, "desktop/Engine/uninstall.sh")
	apps := filepath.Join(e.home, "Applications")
	if err := os.MkdirAll(apps, 0700); err != nil {
		t.Fatal(err)
	}
	e.appRoots = []string{apps}
	e.env = append(e.env, "MOLE_DASHBOARD_UNINSTALL_GATE="+uninstallTestGate, "MOLE_DASHBOARD_FIXTURE_APPS="+apps)
	bin := strings.TrimPrefix(strings.Split(e.env[1], ":")[0], "PATH=")
	for name, body := range map[string]string{
		"pgrep":   "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$HOME/pgrep-trace\"\n[[ ! -e \"$HOME/running\" ]] || { echo 123; exit 0; }\n[[ ! -e \"$HOME/process-unknown\" ]] || { echo unknown >&2; exit 2; }\nexit 1\n",
		"pkgutil": "#!/bin/bash\nexit 0\n",
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0700); err != nil {
			t.Fatal(err)
		}
	}
	return e
}
func makeApplication(t *testing.T, e engine, name, id string) application {
	t.Helper()
	path := filepath.Join(e.home, "Applications", name+".app")
	if err := os.MkdirAll(filepath.Join(path, "Contents/MacOS"), 0700); err != nil {
		t.Fatal(err)
	}
	plist := fmt.Sprintf(`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleName</key><string>Disposable App</string><key>CFBundleExecutable</key><string>MoleUninstallFixture</string><key>CFBundleShortVersionString</key><string>1.2</string></dict></plist>`, id)
	if err := os.WriteFile(filepath.Join(path, "Contents/Info.plist"), []byte(plist), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "Contents/MacOS/MoleUninstallFixture"), []byte("fixture"), 0700); err != nil {
		t.Fatal(err)
	}
	a, err := readApplication(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	return a
}
func appData(t *testing.T, e engine, a application) string {
	t.Helper()
	path := filepath.Join(e.home, "Library/Preferences", a.BundleID+".plist")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("disposable settings"), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}
func reviewApp(t *testing.T, e engine, a application) *plan {
	t.Helper()
	p := e.reviewApplication(context.Background(), "review", a, func(ev event) {
		if ev.Kind == "refused" {
			t.Logf("review refusal: %s: %s", ev.Path, ev.Message)
		}
	})
	if p == nil {
		t.Fatal("review did not complete")
	}
	return p
}
func appItems(p *plan) []item {
	var out []item
	for _, v := range p.items {
		out = append(out, v)
	}
	return out
}

func TestUninstallApplePolicy(t *testing.T) {
	cases := []struct {
		id      string
		allowed bool
	}{
		{"com.apple.garageband10", true},
		{"com.apple.iMovie", true},
		{"com.apple.iWork.Pages", true},
		{"com.apple.finder", false},
		{"com.apple.unknownfixture", false},
		{"com.apple.garageban", false},
		{"COM.APPLE.garageband10", false},
		{"local.hui.mole-dashboard", false},
	}
	for _, c := range cases {
		t.Run(c.id, func(t *testing.T) {
			e := uninstallFixture(t)
			makeApplication(t, e, "ApplePolicy", c.id)
			p := e.applications(context.Background(), "inventory", func(event) {})
			if p == nil || len(p.apps) != 1 {
				t.Fatalf("incomplete inventory: %+v", p)
			}
			var a application
			for _, candidate := range p.apps {
				if candidate.BundleID == c.id {
					a = candidate
				}
			}
			if a.Path == "" || (a.Reason == "") != c.allowed {
				t.Fatalf("inventory policy: allowed=%v app=%+v", c.allowed, a)
			}
			// Bypass the inventory reason to exercise the actual review/sink policy.
			a.Reason = ""
			data := appData(t, e, a)
			review := reviewApp(t, e, a)
			if !c.allowed {
				if len(review.items) != 0 {
					t.Fatalf("protected app entered review: %+v", review.items)
				}
				assertExists(t, a.Path, true)
				assertExists(t, data, true)
				return
			}
			if len(review.items) != 2 {
				t.Fatalf("optional Apple app/data refused: %+v", review.items)
			}
			if c.id == "com.apple.garageband10" {
				ordered, err := uninstallOrder(appItems(review))
				if err != nil {
					t.Fatal(err)
				}
				events := collectClean(e, ordered)
				for _, ev := range events {
					if ev.Kind == "result" && ev.Status != "trashed" {
						t.Fatalf("optional Apple app move refused: %+v", events)
					}
				}
				assertExists(t, a.Path, false)
				assertExists(t, data, false)
			}
		})
	}
}

func TestUninstallExactBundleAndOptionalData(t *testing.T) {
	e := uninstallFixture(t)
	a := makeApplication(t, e, "Fixture space ' quote $(literal)", "com.molefixture.uninstall")
	data := appData(t, e, a)
	control := filepath.Join(e.home, "Library/Preferences", a.BundleID+".neighbor.plist")
	if err := os.WriteFile(control, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	p := reviewApp(t, e, a)
	if len(p.items) != 2 {
		t.Fatalf("expected bundle and exact data, got %+v", p.items)
	}
	ordered, err := uninstallOrder(appItems(p))
	if err != nil {
		t.Fatal(err)
	}
	if err := acknowledgeSelections(ordered, nil); err == nil {
		t.Fatal("data lacked acknowledgement")
	}
	events := collectClean(e, ordered)
	for _, ev := range events {
		if ev.Kind == "result" && ev.Status != "trashed" {
			t.Fatalf("positive move failed: %+v", events)
		}
	}
	assertExists(t, a.Path, false)
	assertExists(t, data, false)
	assertExists(t, control, true)
	log, err := os.ReadFile(filepath.Join(e.home, "Library/Logs/mole/operations.log"))
	if err != nil || !strings.Contains(string(log), "uninstall") || !strings.Contains(string(log), data) {
		t.Fatalf("missing audit: %v %s", err, log)
	}
	trace, err := os.ReadFile(filepath.Join(e.home, "pgrep-trace"))
	if err != nil || !strings.Contains(string(trace), "-x MoleUninstallFixture") {
		t.Fatalf("production process gate did not run: %v %s", err, trace)
	}
}

func TestUninstallBundleOnlyKeepsUncheckedData(t *testing.T) {
	e := uninstallFixture(t)
	a := makeApplication(t, e, "OnlyBundle", "com.molefixture.bundleonly")
	data := appData(t, e, a)
	p := reviewApp(t, e, a)
	var selected []item
	for _, v := range p.items {
		if v.Category == "uninstall-bundle" {
			selected = append(selected, v)
		}
	}
	if len(selected) != 1 {
		t.Fatalf("bundle missing: %+v", p)
	}
	events := collectClean(e, selected)
	if events[1].Status != "trashed" {
		t.Fatalf("bundle failed: %+v", events)
	}
	assertExists(t, a.Path, false)
	assertExists(t, data, true)
}

func TestUninstallRefusesRunningChangedAndOfficialApps(t *testing.T) {
	for _, condition := range []string{"running", "unknown", "changed", "official", "whitelist", "descendant-whitelist"} {
		t.Run(condition, func(t *testing.T) {
			e := uninstallFixture(t)
			id := "com.molefixture.refusal"
			if condition == "official" {
				id = "com.eset.endpoint"
			}
			a := makeApplication(t, e, "Refusal", id)
			data := appData(t, e, a)
			if condition == "official" {
				if len(reviewApp(t, e, a).items) != 0 {
					t.Fatal("official uninstaller app accepted")
				}
				return
			}
			p := reviewApp(t, e, a)
			ordered, err := uninstallOrder(appItems(p))
			if err != nil {
				t.Fatal(err)
			}
			switch condition {
			case "running":
				err = os.WriteFile(filepath.Join(e.home, "running"), nil, 0600)
			case "unknown":
				err = os.WriteFile(filepath.Join(e.home, "process-unknown"), nil, 0600)
			case "changed":
				err = os.WriteFile(filepath.Join(a.Path, "Contents/Info.plist"), []byte("changed metadata"), 0600)
			case "whitelist", "descendant-whitelist":
				dir := filepath.Join(e.home, ".config/mole")
				err = os.MkdirAll(dir, 0700)
				if err == nil {
					path := a.Path
					if condition == "descendant-whitelist" {
						path = filepath.Join(a.Path, "Contents/MacOS/MoleUninstallFixture")
					}
					err = os.WriteFile(filepath.Join(dir, "whitelist"), []byte(path+"\n"), 0600)
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			events := collectClean(e, ordered)
			if len(events) != 3 || events[1].Status == "trashed" {
				t.Fatalf("refusal did not stop later data: %+v", events)
			}
			assertExists(t, a.Path, true)
			assertExists(t, data, true)
		})
	}
}

func TestUninstallSharedOwnerAndReappearedAppKeepData(t *testing.T) {
	for _, late := range []bool{false, true} {
		t.Run(fmt.Sprint(late), func(t *testing.T) {
			e := uninstallFixture(t)
			a := makeApplication(t, e, "Owner", "com.molefixture.owner")
			data := appData(t, e, a)
			if !late {
				makeApplication(t, e, "Owner Beta", "com.molefixture.owner.beta")
				p := reviewApp(t, e, a)
				if len(p.items) != 1 {
					t.Fatalf("shared data was offered: %+v", p.items)
				}
				assertExists(t, data, true)
				return
			}
			p := reviewApp(t, e, a)
			ordered, err := uninstallOrder(appItems(p))
			if err != nil {
				t.Fatal(err)
			}
			events := collectClean(e, ordered[:1])
			if events[1].Status != "trashed" {
				t.Fatalf("bundle positive failed: %+v", events)
			}
			makeApplication(t, e, "Owner", "com.molefixture.owner")
			events = collectClean(e, ordered[1:])
			if events[1].Status == "trashed" {
				t.Fatal("reappeared owner lost data")
			}
			assertExists(t, data, true)
		})
	}
}

func TestUninstallInventoryAndProtocolBoundaries(t *testing.T) {
	e := uninstallFixture(t)
	a := makeApplication(t, e, "Inventory", "com.molefixture.inventory")
	linked := filepath.Join(e.home, "Applications/Linked.app")
	if err := os.Symlink(a.Path, linked); err != nil {
		t.Fatal(err)
	}
	p := e.applications(context.Background(), "apps", func(event) {})
	if len(p.apps) != 2 {
		t.Fatalf("inventory lost real/link rows: %+v", p.apps)
	}
	for _, app := range p.apps {
		if app.Path == linked && app.Reason == "" {
			t.Fatal("linked app removable")
		}
	}
	review := reviewApp(t, e, a)
	selected := appItems(review)
	if _, err := uninstallOrder([]item{{Category: "uninstall-data", owner: &a}}); err == nil {
		t.Fatal("data-only plan accepted")
	}
	// Gate receives only the bound owner and an exact reviewed object.
	outside := filepath.Join(e.home, "outside")
	if err := os.WriteFile(outside, nil, 0600); err != nil {
		t.Fatal(err)
	}
	b, err := pathbinding.Read(outside)
	if err != nil {
		t.Fatal(err)
	}
	owner, _ := json.Marshal(a)
	binding, _ := json.Marshal(b)
	t.Setenv("HOME", e.home)
	if err := checkUninstall(string(owner), string(binding), "inspect"); err == nil {
		t.Fatal("arbitrary app-data path accepted")
	}
	if len(selected) != 1 {
		t.Fatal("positive app review missing")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	events := []event{}
	e.clean(ctx, "cancel", selected, func(ev event) { events = append(events, ev) })
	for _, ev := range events {
		if ev.Kind == "result" {
			t.Fatal("cancelled operation touched an app")
		}
	}
	assertExists(t, a.Path, true)
}

func TestUninstallCaskReverseLinkIsKept(t *testing.T) {
	e := uninstallFixture(t)
	a := makeApplication(t, e, "Managed", "com.molefixture.managed")
	room := filepath.Join(t.TempDir(), "Caskroom")
	version := filepath.Join(room, "fixture", "1.2")
	if err := os.MkdirAll(version, 0700); err != nil {
		t.Fatal(err)
	}
	if err := checkCaskOwner(context.Background(), a.Path, []string{room}); err != nil {
		t.Fatalf("unmanaged positive refused: %v", err)
	}
	unrelated := makeApplication(t, e, "Unrelated", "com.molefixture.unrelated")
	if err := os.Symlink(unrelated.Path, filepath.Join(version, "Unrelated.app")); err != nil {
		t.Fatal(err)
	}
	if err := checkCaskOwner(context.Background(), a.Path, []string{room}); err != nil {
		t.Fatalf("unrelated app link refused removal: %v", err)
	}
	if err := os.Symlink(a.Path, filepath.Join(version, "Managed.app")); err != nil {
		t.Fatal(err)
	}
	if err := checkCaskOwner(context.Background(), a.Path, []string{room}); err == nil || !strings.Contains(err.Error(), "Homebrew manages") {
		t.Fatalf("reverse link ignored: %v", err)
	}
	assertExists(t, a.Path, true)
}

func TestUninstallFinalGuardKeepsAppLaunchedDuringSizing(t *testing.T) {
	e := uninstallFixture(t)
	a := makeApplication(t, e, "LateRunning", "com.molefixture.late")
	p := reviewApp(t, e, a)
	selected, err := uninstallOrder(appItems(p))
	if err != nil {
		t.Fatal(err)
	}
	bin := strings.TrimPrefix(strings.Split(e.env[1], ":")[0], "PATH=")
	script := "#!/bin/bash\ntouch \"$HOME/running\"\nexec /usr/bin/du \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "du"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, selected)
	if events[1].Status == "trashed" {
		t.Fatalf("late running app moved: %+v", events)
	}
	assertExists(t, filepath.Join(e.home, "running"), true)
	assertExists(t, a.Path, true)
}
