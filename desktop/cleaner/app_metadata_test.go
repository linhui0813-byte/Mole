//go:build darwin

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAppMetadataParsersKeepUnknownDistinctFromZero(t *testing.T) {
	path := "/Applications/App ' quote 测试.app"
	for _, test := range []struct {
		raw  string
		want *uint64
	}{
		{"123\t" + path + "\n", new(uint64(123 * 1024))},
		{"0\t" + path + "\n", new(uint64(0))},
		{"123\t/Applications/Other.app\n", nil},
		{"123\t" + path + "\ndu: unreadable\n", nil},
		{"-1\t" + path + "\n", nil},
		{"18446744073709551615\t" + path + "\n", nil},
		{"", nil},
	} {
		got := appSize([]byte(test.raw), path)
		if (got == nil) != (test.want == nil) || (got != nil && *got != *test.want) {
			t.Fatalf("size %q: %v, wanted %v", test.raw, got, test.want)
		}
	}
	now := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	expected := time.Date(2026, 10, 25, 12, 30, 0, 0, time.UTC).Unix()
	got := appLastActive([]byte("2026-10-25 20:30:00 +0800\x00"), now)
	if got == nil || *got != expected {
		t.Fatalf("valid date lost its timezone: %v", got)
	}
	for _, raw := range []string{"(null)", "", "0", "not a date", "1990-01-01 00:00:00 +0000", "2027-01-01 00:00:00 +0000"} {
		if got := appLastActive([]byte(raw), now); got != nil {
			t.Fatalf("unknown date %q fabricated %d", raw, *got)
		}
	}
}

func TestAppMetadataFreshBoundedAndFailureAware(t *testing.T) {
	for _, condition := range []string{"success", "size-error", "date-error", "changed", "cancelled"} {
		t.Run(condition, func(t *testing.T) {
			e := uninstallFixture(t)
			a := makeApplication(t, e, "Metadata", "com.molefixture.metadata")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			run := func(commandCtx context.Context, name string, args ...string) ([]byte, error) {
				calls++
				deadline, ok := commandCtx.Deadline()
				if !ok || time.Until(deadline) > 5*time.Second {
					t.Fatal("metadata command has no bounded deadline")
				}
				if args[len(args)-1] != a.Path {
					t.Fatal("metadata command addressed another app")
				}
				if condition == "cancelled" {
					cancel()
				}
				if name == "/usr/bin/du" {
					out := []byte("8\t" + a.Path + "\n")
					if condition == "size-error" {
						return out, errors.New("incomplete du")
					}
					return out, nil
				}
				if name != "/usr/bin/mdls" {
					t.Fatalf("unexpected metadata command %s", name)
				}
				if condition == "changed" {
					stamp := time.Now().Add(time.Hour)
					if err := os.Chtimes(a.Path, stamp, stamp); err != nil {
						t.Fatal(err)
					}
				}
				out := []byte("2026-01-01 00:00:00 +0000")
				if condition == "date-error" {
					return out, errors.New("Spotlight unavailable")
				}
				return out, nil
			}
			a.MetadataPending = true
			got := readAppMetadata(ctx, a, run)
			if got.MetadataPending || calls != 2 {
				t.Fatal("metadata did not settle both measurements")
			}
			wantSize := condition == "success" || condition == "date-error"
			wantDate := condition == "success" || condition == "size-error"
			if (got.SizeBytes != nil) != wantSize || (got.LastActive != nil) != wantDate {
				t.Fatalf("%s returned size=%v date=%v", condition, got.SizeBytes, got.LastActive)
			}
			if got.SizeBytes != nil && *got.SizeBytes != 8192 {
				t.Fatal("size units changed")
			}
		})
	}
}

func TestAppInventoryPublishesMetadataUpdatesAndRemeasures(t *testing.T) {
	e := uninstallFixture(t)
	a := makeApplication(t, e, "InventoryMetadata", "com.molefixture.inventorymetadata")
	pending, measured := 0, 0
	p := e.applications(context.Background(), "inventory", func(ev event) {
		if ev.App != nil {
			if ev.App.MetadataPending {
				pending++
			} else if ev.App.SizeBytes != nil {
				measured++
			}
		}
	})
	if len(p.apps) != 1 || pending != 1 || measured != 1 {
		t.Fatalf("inventory did not publish one row and its measurement: apps=%d pending=%d measured=%d", len(p.apps), pending, measured)
	}
	var before uint64
	for _, app := range p.apps {
		before = *app.SizeBytes
	}
	if err := os.WriteFile(filepath.Join(a.Path, "Contents/payload"), make([]byte, 256*1024), 0600); err != nil {
		t.Fatal(err)
	}
	p = e.applications(context.Background(), "refresh", func(event) {})
	for _, app := range p.apps {
		if app.SizeBytes == nil || *app.SizeBytes <= before {
			t.Fatal("refresh reused an old directory size")
		}
	}
}
