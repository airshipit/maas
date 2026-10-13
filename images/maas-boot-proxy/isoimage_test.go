// Copyright 2026 The Airship Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"bytes"
	"encoding/binary"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf16"
)

func testIPXEEFI() []byte {
	b := make([]byte, 1<<20+37)
	for i := range b {
		b[i] = byte(i * 7)
	}
	return b
}

// readFAT12 returns the data of the file at path (long or short names) in a
// FAT12 image, independently of the builder.
func readFAT12(t *testing.T, img []byte, path ...string) []byte {
	t.Helper()
	bps := int(binary.LittleEndian.Uint16(img[11:]))
	spc := int(img[13])
	reserved := int(binary.LittleEndian.Uint16(img[14:]))
	nfats := int(img[16])
	rootEntries := int(binary.LittleEndian.Uint16(img[17:]))
	fatSectors := int(binary.LittleEndian.Uint16(img[22:]))
	if string(img[54:62]) != "FAT12   " || img[510] != 0x55 || img[511] != 0xAA {
		t.Fatalf("bad boot sector")
	}
	fat := img[reserved*bps:]
	rootStart := (reserved + nfats*fatSectors) * bps
	dataStart := rootStart + rootEntries*32
	next := func(c int) int {
		off := c * 3 / 2
		v := int(binary.LittleEndian.Uint16(fat[off:]))
		if c%2 == 0 {
			return v & 0xFFF
		}
		return v >> 4
	}
	readChain := func(first, size int) []byte {
		var out []byte
		for c := first; c < 0xFF8 && len(out) < size; c = next(c) {
			o := dataStart + (c-2)*spc*bps
			out = append(out, img[o:o+spc*bps]...)
		}
		return out[:size]
	}
	lookup := func(dir []byte, name string) (first, size int, isDir bool, ok bool) {
		long := ""
		var lfnSum byte
		for i := 0; i+32 <= len(dir) && dir[i] != 0; i += 32 {
			e := dir[i : i+32]
			if e[11] == attrLFN {
				var u []uint16
				for _, r := range [][2]int{{1, 5}, {14, 6}, {28, 2}} {
					for k := 0; k < r[1]; k++ {
						c := binary.LittleEndian.Uint16(e[r[0]+2*k:])
						if c == 0 || c == 0xFFFF {
							break
						}
						u = append(u, c)
					}
				}
				long = string(utf16.Decode(u))
				lfnSum = e[13]
				continue
			}
			short := string(bytes.TrimRight(e[:8], " "))
			if ext := string(bytes.TrimRight(e[8:11], " ")); ext != "" {
				short += "." + ext
			}
			if long != "" {
				var sum byte
				for _, c := range e[:11] {
					sum = (sum&1)<<7 + sum>>1 + c
				}
				if sum != lfnSum {
					t.Fatalf("LFN checksum %#x does not match short name (%#x)", lfnSum, sum)
				}
			}
			if short == name || long == name {
				return int(binary.LittleEndian.Uint16(e[26:])), int(binary.LittleEndian.Uint32(e[28:])), e[11]&attrDir != 0, true
			}
			long = ""
		}
		return 0, 0, false, false
	}
	dir := img[rootStart : rootStart+rootEntries*32]
	for i, name := range path {
		first, size, isDir, ok := lookup(dir, name)
		if !ok {
			t.Fatalf("%q not found in FAT image", name)
		}
		if i == len(path)-1 {
			return readChain(first, size)
		}
		if !isDir {
			t.Fatalf("%q is not a directory", name)
		}
		dir = readChain(first, fatClusterSize)
	}
	return nil
}

func TestESPImageRoundTrip(t *testing.T) {
	efi := testIPXEEFI()
	script := []byte("#!ipxe\necho hello\n")
	img, err := buildESPImage(efi, script)
	if err != nil {
		t.Fatal(err)
	}
	if got := readFAT12(t, img, "EFI", "BOOT", "BOOTX64.EFI"); !bytes.Equal(got, efi) {
		t.Errorf("BOOTX64.EFI mismatch")
	}
	if got := readFAT12(t, img, autoexecName); !bytes.Equal(got, script) {
		t.Errorf("autoexec.ipxe mismatch: %q", got)
	}
}

func TestESPImageTooLarge(t *testing.T) {
	if _, err := buildESPImage(make([]byte, 9<<20), []byte("#!ipxe\n")); err == nil {
		t.Fatal("expected error for oversized EFI binary")
	}
}

func TestBootISOStructure(t *testing.T) {
	efi := testIPXEEFI()
	script := []byte(RenderNodeIPXEScript(Node{Hostname: "h1", IP: "10.0.0.2"}, "aa:bb:cc:dd:ee:ff", "http://p/boot"))
	iso, err := buildBootISO(efi, script)
	if err != nil {
		t.Fatal(err)
	}
	sector := func(n int) []byte { return iso[n*isoSectorSize : (n+1)*isoSectorSize] }

	pvd := sector(lbaPVD)
	if pvd[0] != 1 || string(pvd[1:6]) != "CD001" {
		t.Fatalf("bad primary volume descriptor")
	}
	if got := int(binary.LittleEndian.Uint32(pvd[80:])); got*isoSectorSize != len(iso) {
		t.Errorf("volume space size %d sectors, image has %d bytes", got, len(iso))
	}
	if term := sector(lbaTerm); term[0] != 255 || string(term[1:6]) != "CD001" {
		t.Errorf("missing volume descriptor set terminator")
	}

	br := sector(lbaBoot)
	if br[0] != 0 || string(br[7:30]) != "EL TORITO SPECIFICATION" {
		t.Fatalf("bad El Torito boot record")
	}
	catLBA := int(binary.LittleEndian.Uint32(br[71:]))
	cat := sector(catLBA)
	if cat[0] != 1 || cat[1] != 0xEF || cat[30] != 0x55 || cat[31] != 0xAA {
		t.Fatalf("bad validation entry")
	}
	var sum uint16
	for i := 0; i < 32; i += 2 {
		sum += binary.LittleEndian.Uint16(cat[i:])
	}
	if sum != 0 {
		t.Errorf("validation entry checksum: words sum to %#x", sum)
	}
	if cat[32] != 0x88 || cat[33] != 0 {
		t.Fatalf("expected bootable no-emulation entry, got %#x/%#x", cat[32], cat[33])
	}
	espLBA := int(binary.LittleEndian.Uint32(cat[40:]))
	esp := iso[espLBA*isoSectorSize:]
	if got := readFAT12(t, esp, "EFI", "BOOT", "BOOTX64.EFI"); !bytes.Equal(got, efi) {
		t.Errorf("boot image does not carry the iPXE EFI binary")
	}
	if got := readFAT12(t, esp, autoexecName); !bytes.Equal(got, script) {
		t.Errorf("boot image does not carry the node script")
	}

	// The ESP is also exposed as a regular file in the ISO 9660 root.
	root := sector(lbaRoot)
	if !bytes.Contains(root, []byte(espBootPath)) {
		t.Errorf("root directory does not list %s", espBootPath)
	}
}

func TestBuildNodeISOReproducibleAndNodeSpecific(t *testing.T) {
	efi := testIPXEEFI()
	n := Node{Hostname: "node-c", IP: "198.51.100.103", VLAN: "120", BondMembers: []string{"0000:3b:00.0", "0000:af:00.1"}}
	a, err := BuildNodeISO(efi, n, "02:5e:1c:9a:47:d3", "http://p/boot")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := BuildNodeISO(efi, n, "02:5e:1c:9a:47:d3", "http://p/boot")
	if !bytes.Equal(a, b) {
		t.Errorf("ISO composition is not deterministic")
	}
	n.Hostname = "other"
	c, _ := BuildNodeISO(efi, n, "02:5e:1c:9a:47:d3", "http://p/boot")
	if bytes.Equal(a, c) {
		t.Errorf("different nodes produced identical ISOs")
	}
	if _, err := BuildNodeISO(nil, n, "aa", "http://p/boot"); err == nil {
		t.Errorf("expected error without an iPXE EFI binary")
	}
}

func TestESPImageClusterBoundaries(t *testing.T) {
	sizes := []int{1, fatClusterSize - 1, fatClusterSize, fatClusterSize + 1, 5*fatClusterSize + 123}
	for _, es := range sizes {
		for _, ss := range sizes {
			efi := bytes.Repeat([]byte{0xA5}, es)
			script := bytes.Repeat([]byte("x"), ss)
			img, err := buildESPImage(efi, script)
			if err != nil {
				t.Fatalf("efi=%d script=%d: %v", es, ss, err)
			}
			if got := readFAT12(t, img, "EFI", "BOOT", "BOOTX64.EFI"); !bytes.Equal(got, efi) {
				t.Errorf("efi=%d script=%d: BOOTX64.EFI mismatch", es, ss)
			}
			if got := readFAT12(t, img, autoexecName); !bytes.Equal(got, script) {
				t.Errorf("efi=%d script=%d: autoexec.ipxe mismatch", es, ss)
			}
		}
	}
}

func TestESPImageFAT12Limit(t *testing.T) {
	script := []byte("#!ipxe\n")
	// clusters = efiClusters + 3 (two directories, one script cluster) must stay <= fatMaxClusters.
	atLimit := bytes.Repeat([]byte{0x5A}, (fatMaxClusters-3)*fatClusterSize)
	img, err := buildESPImage(atLimit, script)
	if err != nil {
		t.Fatalf("image at the FAT12 limit rejected: %v", err)
	}
	if got := readFAT12(t, img, "EFI", "BOOT", "BOOTX64.EFI"); !bytes.Equal(got, atLimit) {
		t.Errorf("BOOTX64.EFI mismatch at the FAT12 limit")
	}
	if got := readFAT12(t, img, autoexecName); !bytes.Equal(got, script) {
		t.Errorf("autoexec.ipxe mismatch at the FAT12 limit")
	}
	if _, err := buildESPImage(append(atLimit, 0), script); err == nil {
		t.Errorf("expected error one cluster over the FAT12 limit")
	}
}

func TestESPImageEmptyScript(t *testing.T) {
	if _, err := buildESPImage(testIPXEEFI(), nil); err == nil {
		t.Fatal("expected error for an empty script")
	}
}

func TestFATLFNEntryLayout(t *testing.T) {
	short := shortName("A", "IPX")
	e := fatLFNEntry("a.ipx", short)
	if e[0] != 0x41 || e[11] != attrLFN {
		t.Fatalf("bad LFN header: seq=%#x attr=%#x", e[0], e[11])
	}
	var sum byte
	for _, c := range short {
		sum = (sum&1)<<7 + sum>>1 + c
	}
	if e[13] != sum {
		t.Errorf("checksum %#x, want %#x", e[13], sum)
	}
	var got []uint16
	for _, r := range [][2]int{{1, 5}, {14, 6}, {28, 2}} {
		for k := 0; k < r[1]; k++ {
			got = append(got, binary.LittleEndian.Uint16(e[r[0]+2*k:]))
		}
	}
	want := []uint16{'a', '.', 'i', 'p', 'x', 0}
	for len(want) < 13 {
		want = append(want, 0xFFFF)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("char slot %d = %#x, want %#x", i, got[i], want[i])
		}
	}
}

func TestISODirRecordLengthIsEven(t *testing.T) {
	for _, id := range []string{"\x00", "AB", "ESP.IMG;1", "ABC"} {
		r := isoDirRecord([]byte(id), 20, 2048, 0)
		if len(r)%2 != 0 || int(r[0]) != len(r) {
			t.Errorf("id %q: record len %d, length byte %d", id, len(r), r[0])
		}
	}
}

func TestBuildBootISOErrors(t *testing.T) {
	if _, err := buildBootISO(testIPXEEFI(), nil); err == nil {
		t.Error("expected error for an empty script")
	}
	if _, err := buildBootISO(make([]byte, 9<<20), []byte("#!ipxe\n")); err == nil {
		t.Error("expected error for an oversized EFI binary")
	}
}

func TestBootISOCatalogAndRootEntry(t *testing.T) {
	efi, script := testIPXEEFI(), []byte("#!ipxe\necho x\n")
	iso, err := buildBootISO(efi, script)
	if err != nil {
		t.Fatal(err)
	}
	if len(iso)%isoSectorSize != 0 {
		t.Errorf("ISO length %d is not sector aligned", len(iso))
	}
	esp, _ := buildESPImage(efi, script)
	cat := iso[lbaCatalog*isoSectorSize:]
	if got := int(binary.LittleEndian.Uint16(cat[38:])); got != len(esp)/512 {
		t.Errorf("El Torito sector count %d, want %d (512-byte units)", got, len(esp)/512)
	}
	root := iso[lbaRoot*isoSectorSize : (lbaRoot+1)*isoSectorSize]
	idx := bytes.Index(root, []byte(espBootPath))
	if idx < 33 {
		t.Fatalf("%s not listed in root directory", espBootPath)
	}
	rec := root[idx-33:]
	if extent := int(binary.LittleEndian.Uint32(rec[2:])); extent != lbaESP {
		t.Errorf("ESP.IMG extent %d, want %d", extent, lbaESP)
	}
	if size := int(binary.LittleEndian.Uint32(rec[10:])); size != len(esp) {
		t.Errorf("ESP.IMG size %d, want %d", size, len(esp))
	}
	if !bytes.Equal(iso[lbaESP*isoSectorSize:lbaESP*isoSectorSize+len(esp)], esp) {
		t.Errorf("ESP image bytes in ISO differ from the standalone ESP image")
	}
}

// Cross-check with an independent ISO 9660 reader, when available.
func TestBootISOReadableBySystemTar(t *testing.T) {
	bsdtar, err := exec.LookPath("bsdtar")
	if err != nil {
		t.Skip("bsdtar not installed")
	}
	iso, err := buildBootISO(testIPXEEFI(), []byte("#!ipxe\necho x\n"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "boot.iso")
	if err := os.WriteFile(path, iso, 0o600); err != nil {
		t.Fatal(err)
	}
	out, err := exec.Command(bsdtar, "-tf", path).CombinedOutput()
	if err != nil {
		t.Fatalf("bsdtar failed: %v: %s", err, out)
	}
	if !strings.Contains(strings.ToUpper(string(out)), "ESP.IMG") {
		t.Errorf("bsdtar listing lacks ESP.IMG: %s", out)
	}
}

func TestESPImageEmptyEFIStillBuilds(t *testing.T) {
	script := []byte("#!ipxe\n")
	img, err := buildESPImage(nil, script)
	if err != nil {
		t.Fatal(err)
	}
	if got := readFAT12(t, img, autoexecName); !bytes.Equal(got, script) {
		t.Errorf("autoexec.ipxe mismatch with an empty EFI file")
	}
}
