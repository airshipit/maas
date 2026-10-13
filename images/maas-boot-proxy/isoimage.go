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
	"encoding/binary"
	"fmt"
	"unicode/utf16"
)

// In-memory UEFI boot ISO composer. The ISO is an ISO 9660 image with a single
// El Torito (platform EFI, no emulation) entry that points at a FAT12 EFI System
// Partition image holding iPXE (/EFI/BOOT/BOOTX64.EFI) and the iPXE script
// (/autoexec.ipxe), which iPXE loads from the volume it was started from.
// Only stdlib is used and nothing is written to disk.

const (
	isoSectorSize = 2048
	espBootPath   = "ESP.IMG;1"

	lbaPVD     = 16
	lbaBoot    = 17
	lbaTerm    = 18
	lbaCatalog = 19
	lbaRoot    = 20
	lbaPathL   = 21
	lbaPathM   = 22
	lbaESP     = 23
)

func putBoth16(b []byte, v uint16) {
	binary.LittleEndian.PutUint16(b, v)
	binary.BigEndian.PutUint16(b[2:], v)
}

func putBoth32(b []byte, v uint32) {
	binary.LittleEndian.PutUint32(b, v)
	binary.BigEndian.PutUint32(b[4:], v)
}

func padText(dst []byte, s string) {
	for i := range dst {
		dst[i] = ' '
	}
	copy(dst, s)
}

// isoDirRecord builds an ISO 9660 directory record (fixed 2000-01-01 timestamp
// to keep the output reproducible).
func isoDirRecord(id []byte, extent, size uint32, flags byte) []byte {
	n := 33 + len(id)
	if n%2 == 1 {
		n++
	}
	r := make([]byte, n)
	r[0] = byte(n)
	putBoth32(r[2:], extent)
	putBoth32(r[10:], size)
	copy(r[18:], []byte{100, 1, 1, 0, 0, 0, 0})
	r[25] = flags
	putBoth16(r[28:], 1)
	r[32] = byte(len(id))
	copy(r[33:], id)
	return r
}

func isoDate(unset bool) []byte {
	d := []byte("2000010100000000\x00")
	if unset {
		d = []byte("0000000000000000\x00")
	}
	return d
}

// buildBootISO composes a UEFI-bootable ISO from the iPXE EFI binary and the
// iPXE script to run.
func buildBootISO(efi, script []byte) ([]byte, error) {
	if len(efi) == 0 {
		return nil, fmt.Errorf("empty iPXE EFI binary")
	}
	esp, err := buildESPImage(efi, script)
	if err != nil {
		return nil, err
	}
	espSectors := (len(esp) + isoSectorSize - 1) / isoSectorSize
	total := lbaESP + espSectors
	img := make([]byte, total*isoSectorSize)
	sector := func(lba int) []byte { return img[lba*isoSectorSize : (lba+1)*isoSectorSize] }

	rootRec := isoDirRecord([]byte{0}, lbaRoot, isoSectorSize, 2)

	pvd := sector(lbaPVD)
	pvd[0] = 1
	copy(pvd[1:], "CD001")
	pvd[6] = 1
	padText(pvd[8:40], "")
	padText(pvd[40:72], "IPXE_BOOT")
	putBoth32(pvd[80:], uint32(total))
	putBoth16(pvd[120:], 1)
	putBoth16(pvd[124:], 1)
	putBoth16(pvd[128:], isoSectorSize)
	pathTable := pathTableBytes(binary.LittleEndian)
	putBoth32(pvd[132:], uint32(len(pathTable)))
	binary.LittleEndian.PutUint32(pvd[140:], lbaPathL)
	binary.BigEndian.PutUint32(pvd[148:], lbaPathM)
	copy(pvd[156:], rootRec)
	padText(pvd[190:318], "")
	padText(pvd[318:446], "")
	padText(pvd[446:574], "")
	padText(pvd[574:702], "")
	padText(pvd[702:739], "")
	padText(pvd[739:776], "")
	padText(pvd[776:813], "")
	copy(pvd[813:], isoDate(false))
	copy(pvd[830:], isoDate(false))
	copy(pvd[847:], isoDate(true))
	copy(pvd[864:], isoDate(false))
	pvd[881] = 1

	br := sector(lbaBoot)
	copy(br[1:], "CD001")
	br[6] = 1
	copy(br[7:], "EL TORITO SPECIFICATION")
	binary.LittleEndian.PutUint32(br[71:], lbaCatalog)

	term := sector(lbaTerm)
	term[0] = 255
	copy(term[1:], "CD001")
	term[6] = 1

	cat := sector(lbaCatalog)
	cat[0] = 1
	cat[1] = 0xEF
	copy(cat[4:28], "IPXE UEFI BOOT")
	cat[30], cat[31] = 0x55, 0xAA
	var sum uint16
	for i := 0; i < 32; i += 2 {
		sum += binary.LittleEndian.Uint16(cat[i:])
	}
	binary.LittleEndian.PutUint16(cat[28:], -sum)
	cat[32] = 0x88
	// The ESP is capped at ~8 MB (FAT12), so the sector count always fits 16 bits.
	binary.LittleEndian.PutUint16(cat[38:], uint16(len(esp)/512))
	binary.LittleEndian.PutUint32(cat[40:], lbaESP)

	root := sector(lbaRoot)
	off := 0
	for _, rec := range [][]byte{
		isoDirRecord([]byte{0}, lbaRoot, isoSectorSize, 2),
		isoDirRecord([]byte{1}, lbaRoot, isoSectorSize, 2),
		isoDirRecord([]byte(espBootPath), lbaESP, uint32(len(esp)), 0),
	} {
		off += copy(root[off:], rec)
	}

	copy(sector(lbaPathL), pathTable)
	copy(sector(lbaPathM), pathTableBytes(binary.BigEndian))

	copy(img[lbaESP*isoSectorSize:], esp)
	return img, nil
}

func pathTableBytes(order binary.ByteOrder) []byte {
	t := make([]byte, 10)
	t[0] = 1
	order.PutUint32(t[2:], lbaRoot)
	order.PutUint16(t[6:], 1)
	return t
}

// ---- FAT12 EFI System Partition image ----

const (
	fatSectorSize     = 512
	fatClusterSectors = 4
	fatClusterSize    = fatSectorSize * fatClusterSectors
	fatRootEntries    = 512
	fatRootSectors    = fatRootEntries * 32 / fatSectorSize
	fatMaxClusters    = 4084 // above this the volume would no longer be FAT12

	// Fixed 2000-01-01 timestamp for reproducible images.
	fatDate = (2000-1980)<<9 | 1<<5 | 1

	attrDir = 0x10
	attrLFN = 0x0F

	autoexecName = "autoexec.ipxe"
)

// shortName converts an 8.3 name such as "BOOTX64.EFI" to its 11-byte form.
func shortName(base, ext string) [11]byte {
	var n [11]byte
	for i := range n {
		n[i] = ' '
	}
	copy(n[:8], base)
	copy(n[8:], ext)
	return n
}

func fatDirEntry(name [11]byte, attr byte, first uint16, size uint32) []byte {
	e := make([]byte, 32)
	copy(e, name[:])
	e[11] = attr
	binary.LittleEndian.PutUint16(e[16:], fatDate)
	binary.LittleEndian.PutUint16(e[18:], fatDate)
	binary.LittleEndian.PutUint16(e[24:], fatDate)
	binary.LittleEndian.PutUint16(e[26:], first)
	binary.LittleEndian.PutUint32(e[28:], size)
	return e
}

// fatLFNEntry builds the single long-file-name entry for a name of at most 13
// characters; "autoexec.ipxe" has no valid 8.3 form, and firmware looks it up by
// its long name.
func fatLFNEntry(long string, short [11]byte) []byte {
	var sum byte
	for _, c := range short {
		sum = (sum&1)<<7 + sum>>1 + c
	}
	u := utf16.Encode([]rune(long))
	chars := make([]uint16, 13)
	for i := range chars {
		switch {
		case i < len(u):
			chars[i] = u[i]
		case i == len(u):
			chars[i] = 0
		default:
			chars[i] = 0xFFFF
		}
	}
	e := make([]byte, 32)
	e[0] = 0x41
	e[11] = attrLFN
	e[13] = sum
	slots := [][2]int{{1, 5}, {14, 6}, {28, 2}}
	k := 0
	for _, s := range slots {
		for i := 0; i < s[1]; i++ {
			binary.LittleEndian.PutUint16(e[s[0]+2*i:], chars[k])
			k++
		}
	}
	return e
}

func setFAT12(fat []byte, i int, v uint16) {
	off := i * 3 / 2
	if i%2 == 0 {
		fat[off] = byte(v)
		fat[off+1] = fat[off+1]&0xF0 | byte(v>>8)&0x0F
	} else {
		fat[off] = fat[off]&0x0F | byte(v&0x0F)<<4
		fat[off+1] = byte(v >> 4)
	}
}

// buildESPImage builds a FAT12 EFI System Partition image containing
// /EFI/BOOT/BOOTX64.EFI and /autoexec.ipxe.
func buildESPImage(efi, script []byte) ([]byte, error) {
	if len(script) == 0 {
		return nil, fmt.Errorf("empty iPXE script")
	}
	chainLen := func(n int) int {
		c := (n + fatClusterSize - 1) / fatClusterSize
		if c == 0 {
			c = 1
		}
		return c
	}
	// Cluster layout: 2 = /EFI, 3 = /EFI/BOOT, then the two files.
	efiCl := chainLen(len(efi))
	scriptCl := chainLen(len(script))
	const efiDir, bootDir = 2, 3
	efiFirst := 4
	scriptFirst := efiFirst + efiCl
	clusters := scriptFirst + scriptCl - 2
	if clusters > fatMaxClusters {
		return nil, fmt.Errorf("ESP content needs %d clusters, FAT12 limit is %d", clusters, fatMaxClusters)
	}

	fatBytes := ((clusters+2)*3 + 1) / 2
	fatSectors := (fatBytes + fatSectorSize - 1) / fatSectorSize
	rootStart := 1 + 2*fatSectors
	dataStart := rootStart + fatRootSectors
	totalSectors := dataStart + clusters*fatClusterSectors
	img := make([]byte, totalSectors*fatSectorSize)

	bs := img[:fatSectorSize]
	copy(bs, []byte{0xEB, 0x3C, 0x90})
	copy(bs[3:], "IPXEBOOT")
	binary.LittleEndian.PutUint16(bs[11:], fatSectorSize)
	bs[13] = fatClusterSectors
	binary.LittleEndian.PutUint16(bs[14:], 1)
	bs[16] = 2
	binary.LittleEndian.PutUint16(bs[17:], fatRootEntries)
	binary.LittleEndian.PutUint16(bs[19:], uint16(totalSectors))
	bs[21] = 0xF8
	binary.LittleEndian.PutUint16(bs[22:], uint16(fatSectors))
	binary.LittleEndian.PutUint16(bs[24:], 32)
	binary.LittleEndian.PutUint16(bs[26:], 64)
	bs[36] = 0x80
	bs[38] = 0x29
	binary.LittleEndian.PutUint32(bs[39:], 0x1A2B3C4D)
	copy(bs[43:], "IPXEBOOT   ")
	copy(bs[54:], "FAT12   ")
	bs[510], bs[511] = 0x55, 0xAA

	fat := make([]byte, fatSectors*fatSectorSize)
	setFAT12(fat, 0, 0xFF8)
	setFAT12(fat, 1, 0xFFF)
	setFAT12(fat, efiDir, 0xFFF)
	setFAT12(fat, bootDir, 0xFFF)
	chain := func(first, n int) {
		for i := 0; i < n; i++ {
			next := uint16(first + i + 1)
			if i == n-1 {
				next = 0xFFF
			}
			setFAT12(fat, first+i, next)
		}
	}
	chain(efiFirst, efiCl)
	chain(scriptFirst, scriptCl)
	copy(img[fatSectorSize:], fat)
	copy(img[(1+fatSectors)*fatSectorSize:], fat)

	cluster := func(n int) []byte {
		o := (dataStart + (n-2)*fatClusterSectors) * fatSectorSize
		return img[o:]
	}
	dot := shortName(".", "")
	dotdot := shortName("..", "")
	put := func(dst []byte, entries ...[]byte) {
		for _, e := range entries {
			dst = dst[copy(dst, e):]
		}
	}

	scriptShort := shortName("AUTOEXEC", "IPX")
	put(img[rootStart*fatSectorSize:],
		fatLFNEntry(autoexecName, scriptShort),
		fatDirEntry(scriptShort, 0x20, uint16(scriptFirst), uint32(len(script))),
		fatDirEntry(shortName("EFI", ""), attrDir, efiDir, 0))
	put(cluster(efiDir),
		fatDirEntry(dot, attrDir, efiDir, 0),
		fatDirEntry(dotdot, attrDir, 0, 0),
		fatDirEntry(shortName("BOOT", ""), attrDir, bootDir, 0))
	put(cluster(bootDir),
		fatDirEntry(dot, attrDir, bootDir, 0),
		fatDirEntry(dotdot, attrDir, efiDir, 0),
		fatDirEntry(shortName("BOOTX64", "EFI"), 0x20, uint16(efiFirst), uint32(len(efi))))

	copy(cluster(efiFirst), efi)
	copy(cluster(scriptFirst), script)
	return img, nil
}
