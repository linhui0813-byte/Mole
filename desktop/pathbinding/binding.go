//go:build darwin

// Package pathbinding binds a displayed item to its physical parent and object.
package pathbinding

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"unicode"
)

type Binding struct {
	Path     string `json:"path"`
	Identity string `json:"identity"`
	Parent   string `json:"parent"`
	ParentID string `json:"parent_id"`
	TargetID string `json:"target_id"`
	Stamp    string `json:"stamp"`
}

func Read(path string) (Binding, error) {
	var b Binding
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return b, errors.New("invalid path")
	}
	for _, c := range path {
		if unicode.IsControl(c) {
			return b, errors.New("control character in path")
		}
	}
	info, err := os.Lstat(path)
	if err != nil {
		return b, err
	}
	if !info.Mode().IsRegular() && !info.IsDir() {
		return b, errors.New("links and special files are kept")
	}
	for p := filepath.Dir(path); ; p = filepath.Dir(p) {
		parent, err := os.Lstat(p)
		if err != nil {
			return b, err
		}
		if parent.Mode()&os.ModeSymlink != 0 && p != "/var" && p != "/tmp" && p != "/etc" {
			return b, errors.New("redirected ancestor is kept")
		}
		if p == "/" {
			break
		}
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(path))
	if err != nil {
		return b, err
	}
	pi, err := os.Stat(parent)
	if err != nil {
		return b, err
	}
	s, ok := info.Sys().(*syscall.Stat_t)
	ps, pok := pi.Sys().(*syscall.Stat_t)
	if !ok || !pok {
		return b, errors.New("identity unavailable")
	}
	id := fmt.Sprintf("%d:%d", uint32(s.Dev), s.Ino)
	b = Binding{Path: path, Identity: fmt.Sprintf("%s:%d", id, s.Mtimespec.Sec), Parent: parent,
		ParentID: fmt.Sprintf("%d:%d", uint32(ps.Dev), ps.Ino), TargetID: id,
		Stamp: fmt.Sprintf("%d:%d:%d:%d:%d:%d", s.Mtimespec.Sec, s.Mtimespec.Nsec, s.Ctimespec.Sec, s.Ctimespec.Nsec, s.Size, s.Mode)}
	return b, nil
}

func (b Binding) Matches() bool {
	current, err := Read(b.Path)
	return err == nil && b == current
}
