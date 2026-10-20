//go:build darwin

package pathbinding

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBindingRejectsContentChangeWithRestoredMtime(t *testing.T) {
	path := filepath.Join(t.TempDir(), "item")
	if err := os.WriteFile(path, []byte("first"), 0600); err != nil {
		t.Fatal(err)
	}
	original, err := Read(path)
	if err != nil || !original.Matches() {
		t.Fatalf("positive binding: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("other"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, info.ModTime(), info.ModTime()); err != nil {
		t.Fatal(err)
	}
	if original.Matches() {
		t.Fatal("same-inode content mutation inherited review")
	}
}

func TestBindingRejectsNewParentAndUserSymlinkAncestors(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "parent")
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(parent, "item")
	if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	original, err := Read(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(parent, parent+".old"); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(parent, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(filepath.Join(parent+".old", "item"), path); err != nil {
		t.Fatal(err)
	}
	if original.Matches() {
		t.Fatal("new parent inherited the old object's review")
	}
	link := filepath.Join(root, "alias")
	if err := os.Symlink(parent, link); err != nil {
		t.Fatal(err)
	}
	if _, err := Read(filepath.Join(link, "item")); err == nil {
		t.Fatal("redirected ancestor was accepted")
	}
}
