//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/tw93/mole/desktop/pathbinding"
)

func folderCollection(t *testing.T, e engine) string {
	t.Helper()
	root := filepath.Join(e.home, "Documents", "collection with apps")
	for _, name := range []string{"first/.git/objects", "second/.git/objects", "first/.build/Demo.app/Contents/Frameworks"} {
		if err := os.MkdirAll(filepath.Join(root, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"first/.git/HEAD", "second/.git/HEAD", "first/.env", "first/.build/Demo.app/Contents/Info.plist"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("disposable bundle and project fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestAnalyzeWholeFolderCollectionTrash(t *testing.T) {
	e := analyzeFixture(t)
	root := folderCollection(t, e)
	control := analyzeFile(t, e, "outside-collection-control.txt")
	linkPath := filepath.Join(root, "first/.build/Demo.app/Contents/Frameworks/linked-control")
	if err := os.Symlink(control, linkPath); err != nil {
		t.Fatal(err)
	}
	p := review(t, e, root)
	var selected item
	for _, v := range p.items {
		selected = v
	}
	if selected.Category != "analyze-folder" {
		t.Fatalf("collection did not receive whole-folder warning: %+v", selected)
	}
	if acknowledgeSelections([]item{selected}, nil) == nil {
		t.Fatal("whole folder allowed without acknowledgement")
	}
	if err := acknowledgeSelections([]item{selected}, []string{selected.ID}); err != nil {
		t.Fatal(err)
	}
	events := collectClean(e, []item{selected})
	if events[1].Status != "trashed" {
		t.Fatalf("collection move failed: %+v", events)
	}
	assertExists(t, root, false)
	assertExists(t, control, true)
	moves, err := filepath.Glob(filepath.Join(e.home, "fixture-trash", filepath.Base(root)+".*"))
	if err != nil || len(moves) != 1 {
		t.Fatalf("expected exactly one collection in fixture Trash: %v %v", moves, err)
	}
	moved := moves[0]
	for _, name := range []string{"first/.git/HEAD", "second/.git/HEAD", "first/.env", "first/.build/Demo.app/Contents/Info.plist"} {
		data, err := os.ReadFile(filepath.Join(moved, name))
		if err != nil || string(data) != "disposable bundle and project fixture" {
			t.Fatalf("bundle/project contents changed: %s %v", name, err)
		}
	}
	link, err := os.Readlink(filepath.Join(moved, "first/.build/Demo.app/Contents/Frameworks/linked-control"))
	if err != nil || link != control {
		t.Fatalf("bundle link changed or was followed: %q %v", link, err)
	}
}

func TestAnalyzeWholeFolderStillKeepsInstalledAppsAndPersonalRoots(t *testing.T) {
	e := analyzeFixture(t)
	for _, name := range []string{"Applications/Utilities/Installed.app/Contents", "Documents", "Downloads"} {
		if err := os.MkdirAll(filepath.Join(e.home, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"Applications/Utilities", "Applications/Utilities/Installed.app", "Documents", "Downloads"} {
		p := e.review(t.Context(), "kept", []pathbinding.Binding{binding(t, filepath.Join(e.home, name))}, func(event) {})
		if p == nil || len(p.items) != 0 {
			t.Fatalf("installed-app or personal collection root was allowed: %s %+v", name, p)
		}
	}
}
