package main

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

type newcEntry struct {
	name string
	mode uint64
	data []byte
}

func parseNewc(t *testing.T, raw []byte) []newcEntry {
	t.Helper()
	var out []newcEntry
	off := 0
	for {
		if off+110 > len(raw) || string(raw[off:off+6]) != "070701" {
			t.Fatalf("bad newc header at offset %d", off)
		}
		field := func(i int) uint64 {
			v, err := strconv.ParseUint(string(raw[off+6+8*i:off+14+8*i]), 16, 32)
			if err != nil {
				t.Fatalf("bad header field %d: %v", i, err)
			}
			return v
		}
		mode, size, namesize := field(1), int(field(6)), int(field(11))
		nameStart := off + 110
		name := string(raw[nameStart : nameStart+namesize-1])
		dataStart := (nameStart + namesize + 3) &^ 3
		if name == "TRAILER!!!" {
			if (dataStart) != len(raw) {
				t.Fatalf("trailing bytes after TRAILER: %d", len(raw)-dataStart)
			}
			return out
		}
		out = append(out, newcEntry{name, mode, raw[dataStart : dataStart+size]})
		off = (dataStart + size + 3) &^ 3
	}
}

func gunzip(t *testing.T, b []byte) []byte {
	t.Helper()
	zr, err := gzip.NewReader(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := io.ReadAll(zr)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestOverlayCPIOContents(t *testing.T) {
	entries := parseNewc(t, gunzip(t, overlayCPIO))
	want := []string{"scripts", "scripts/init-premount", "scripts/init-premount/ORDER", "scripts/init-premount/bond"}
	if len(entries) != len(want) {
		t.Fatalf("got %d entries, want %d", len(entries), len(want))
	}
	for i, e := range entries {
		if e.name != want[i] {
			t.Errorf("entry %d = %q, want %q", i, e.name, want[i])
		}
		if !strings.HasSuffix(e.name, "ORDER") && !strings.HasSuffix(e.name, "bond") {
			if e.mode != 040755 {
				t.Errorf("%s mode %o, want 040755", e.name, e.mode)
			}
			continue
		}
		src, err := overlayScripts.ReadFile(overlayRoot + "/" + e.name)
		if err != nil || !bytes.Equal(src, e.data) {
			t.Errorf("%s content differs from embedded source", e.name)
		}
	}
	if entries[3].mode != 0100755 || entries[2].mode != 0100644 {
		t.Errorf("modes bond=%o ORDER=%o, want 0100755 / 0100644", entries[3].mode, entries[2].mode)
	}
}

func TestOverlayCPIODeterministic(t *testing.T) {
	again, err := BuildOverlayCPIO(overlayScripts, overlayRoot)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(again, overlayCPIO) {
		t.Error("overlay generation is not deterministic")
	}
}

// Cross-check with the system cpio, when available, that a real implementation can read it.
func TestOverlayCPIOReadableBySystemCpio(t *testing.T) {
	cpio, err := exec.LookPath("cpio")
	if err != nil {
		t.Skip("cpio not installed")
	}
	dir := t.TempDir()
	cmd := exec.Command(cpio, "-id", "--quiet")
	cmd.Dir = dir
	cmd.Stdin = bytes.NewReader(gunzip(t, overlayCPIO))
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("cpio failed: %v: %s", err, out)
	}
	fi, err := os.Stat(filepath.Join(dir, "scripts/init-premount/bond"))
	if err != nil || fi.Mode()&0o111 == 0 {
		t.Fatalf("bond hook missing or not executable: %v", err)
	}
}
