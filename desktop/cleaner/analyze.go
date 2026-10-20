//go:build darwin

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"slices"
	"strings"
	"time"

	"github.com/tw93/mole/desktop/pathbinding"
)

func inspectionReason(err error) string {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		for _, line := range strings.Split(string(exit.Stderr), "\n") {
			if reason, ok := strings.CutPrefix(line, "CLEAN_REASON:"); ok {
				return reason
			}
		}
	}
	return "The item could not be fully verified within the review budget; choose a smaller item or reveal it in Finder."
}

func (e engine) review(ctx context.Context, requestID string, candidates []pathbinding.Binding, emit func(event)) *plan {
	if len(candidates) == 0 || len(candidates) > 200 {
		emit(event{Kind: "scan_done", RequestID: requestID, Status: "failed", Message: "Select between 1 and 200 items to review."})
		return nil
	}
	candidates = slices.Clone(candidates)
	slices.SortFunc(candidates, func(a, b pathbinding.Binding) int { return strings.Compare(a.Path, b.Path) })
	p := &plan{items: make(map[string]item)}
	seen := map[string]bool{}
	kept := 0
	for index, b := range candidates {
		if ctx.Err() != nil {
			break
		}
		emit(event{Kind: "progress", RequestID: requestID, Checked: index, Total: len(candidates), Message: b.Path})
		reason := ""
		covered := false
		if seen[b.Path] || !b.Matches() {
			reason = "The item or its parent changed since the scan. Scan again."
		}
		seen[b.Path] = true
		for _, parent := range p.items {
			if strings.HasPrefix(b.Path, parent.Path+"/") {
				reason = "No separate move: included only if you confirm its reviewed parent folder: " + parent.Path
				covered = true
				break
			}
		}
		var v item
		if reason == "" {
			serialized, _ := json.Marshal(b)
			v = item{ID: token(), Category: "analyze", Path: b.Path, binding: string(serialized)}
			var err error
			v, err = e.inspect(ctx, v)
			if err != nil {
				reason = inspectionReason(err)
			}
			if reason == "" && (!b.Matches() || v.identity != b.Identity || v.parent != b.Parent || v.parentID != b.ParentID || v.targetID != b.TargetID) {
				reason = "The item changed while it was being reviewed. Scan again."
			}
		}
		if ctx.Err() != nil {
			break
		}
		if reason != "" {
			status := "kept"
			if covered {
				status = "covered"
			} else {
				kept++
			}
			emit(event{Kind: "refused", RequestID: requestID, Path: b.Path, Status: status, Message: reason})
			continue
		}
		p.items[v.ID] = v
		copy := v
		emit(event{Kind: "item", RequestID: requestID, Item: &copy})
	}
	if ctx.Err() != nil {
		emit(event{Kind: "scan_done", RequestID: requestID, Status: "cancelled", Message: "Review stopped. No selection is authorized; review again."})
		return nil
	}
	p.created = time.Now()
	emit(event{Kind: "scan_done", RequestID: requestID, Status: "ready", Kept: kept, Total: len(p.items), Message: "Review the exact items below. Only checked items will move to Trash."})
	return p
}
