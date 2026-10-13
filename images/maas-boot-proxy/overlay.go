package main

import (
	"bytes"
	"compress/gzip"
	"embed"
	"fmt"
	"io/fs"
)

// The initramfs bond overlay is a supplementary initrd that adds an init-premount hook
// (forms the LACP bond before the network comes up). The kernel only understands cpio
// ("newc") archives as initramfs, so the archive is generated here from the embedded
// hook files, without any external cpio tool.
//
//go:embed initramfs-bond-overlay/scripts
var overlayScripts embed.FS

const overlayRoot = "initramfs-bond-overlay"

// overlayExecutable lists the overlay files that must be executable (embed.FS does not
// preserve file modes).
var overlayExecutable = map[string]bool{
	"scripts/init-premount/bond": true,
}

// overlayCPIO is the gzip'd newc archive served as the 2nd initrd.
var overlayCPIO = mustBuildOverlay()

func mustBuildOverlay() []byte {
	b, err := BuildOverlayCPIO(overlayScripts, overlayRoot)
	if err != nil {
		panic(fmt.Sprintf("building initramfs bond overlay: %v", err))
	}
	return b
}

// BuildOverlayCPIO renders every directory and file under root of fsys into a gzip'd
// newc cpio archive, with paths relative to root (e.g. scripts/init-premount/bond).
// Output is deterministic: lexical order, zero mtime, root ownership.
func BuildOverlayCPIO(fsys fs.FS, root string) ([]byte, error) {
	var raw bytes.Buffer
	ino := uint32(0)
	err := fs.WalkDir(fsys, root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == root {
			return nil
		}
		name := p[len(root)+1:]
		ino++
		if d.IsDir() {
			return writeNewc(&raw, ino, 040755, 2, name, nil)
		}
		data, err := fs.ReadFile(fsys, p)
		if err != nil {
			return err
		}
		mode := uint32(0100644)
		if overlayExecutable[name] {
			mode = 0100755
		}
		return writeNewc(&raw, ino, mode, 1, name, data)
	})
	if err != nil {
		return nil, err
	}
	if err := writeNewc(&raw, 0, 0, 1, "TRAILER!!!", nil); err != nil {
		return nil, err
	}
	var out bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&out, gzip.BestCompression)
	if _, err := zw.Write(raw.Bytes()); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// writeNewc appends one newc entry: a 110-byte ASCII header, the NUL-terminated name
// (header+name padded to 4 bytes), then the data padded to 4 bytes.
func writeNewc(w *bytes.Buffer, ino, mode, nlink uint32, name string, data []byte) error {
	namesize := uint32(len(name) + 1)
	fmt.Fprintf(w, "070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X",
		ino, mode, 0, 0, nlink, 0, len(data), 0, 0, 0, 0, namesize, 0)
	w.WriteString(name)
	w.WriteByte(0)
	padTo4(w)
	w.Write(data)
	padTo4(w)
	return nil
}

func padTo4(w *bytes.Buffer) {
	for w.Len()%4 != 0 {
		w.WriteByte(0)
	}
}
