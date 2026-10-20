//go:build darwin

package pathbinding

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// WholeProject recognizes a selected, user-owned checkout, not an ancestor
// containing repositories. Linked worktrees and redirected Git state stay out.
// No Git commands, configuration, hooks, or credential contents are evaluated.
func WholeProject(path string) bool {
	home, err := os.UserHomeDir()
	if err != nil {
		return false
	}
	return WholeProjectIn(home, path)
}

// WholeProjectIn uses the helper's fixed home, also used by isolated tests.
func WholeProjectIn(home, path string) bool {
	if !WholeFolderIn(home, path) {
		return false
	}
	for _, entry := range []struct {
		name string
		dir  bool
	}{{".git", true}, {".git/objects", true}, {".git/HEAD", false}} {
		info, err := os.Lstat(filepath.Join(path, entry.name))
		if err != nil || info.IsDir() != entry.dir || !entry.dir && !info.Mode().IsRegular() {
			return false
		}
		s, ok := info.Sys().(*syscall.Stat_t)
		if !ok || s.Uid != uint32(os.Geteuid()) {
			return false
		}
	}
	return true
}

// WholeFolderIn classifies user-data folder moves, independently of Git layout.
// Actual path/root protection and a complete physical review remain mandatory.
func WholeFolderIn(home, path string) bool {
	rel, ok := ownedFolderRelative(home, path)
	if !ok {
		return false
	}
	first := strings.Split(rel, string(filepath.Separator))[0]
	if strings.HasPrefix(first, ".") || strings.EqualFold(first, "Library") || strings.EqualFold(first, "Applications") {
		return false
	}
	if rel == first {
		switch strings.ToLower(first) {
		case "desktop", "documents", "downloads", "pictures", "movies", "music", "public":
			return false
		}
	}
	return true
}

// Library subfolders use a separate review class that retains upstream
// live-cache and database visibility checks. The Library root is never a target.
func WholeLibraryFolderIn(home, path string) bool {
	rel, ok := ownedFolderRelative(home, path)
	parts := strings.SplitN(rel, string(filepath.Separator), 2)
	return ok && len(parts) == 2 && strings.EqualFold(parts[0], "Library")
}

func ownedFolderRelative(home, path string) (string, bool) {
	rel, err := filepath.Rel(home, path)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, "../") {
		return "", false
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() {
		return "", false
	}
	s, ok := info.Sys().(*syscall.Stat_t)
	return rel, ok && s.Uid == uint32(os.Geteuid())
}
