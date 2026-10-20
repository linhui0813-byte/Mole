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
	rel, err := filepath.Rel(home, path)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, "../") {
		return false
	}
	first := strings.Split(rel, string(filepath.Separator))[0]
	if strings.HasPrefix(first, ".") || strings.EqualFold(first, "Library") {
		return false
	}
	for _, entry := range []struct {
		name string
		dir  bool
	}{{"", true}, {".git", true}, {".git/objects", true}, {".git/HEAD", false}} {
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
