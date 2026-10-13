/*
Copyright 2026 The Airship Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/md5"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testBase = "http://maas.example.com/boot"
	testRack = "http://192.0.2.57:5248"
)

func TestRewriteDataPlainText(t *testing.T) {
	in := []byte("kernel " + testRack + "/images/kernel\ncloud-config-url=" + testRack + "/MAAS/metadata/latest/?op=get_preseed\n")
	out, err := rewriteData(in, testBase, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := "kernel " + testBase + "/images/kernel\ncloud-config-url=" + testBase + "/MAAS/metadata/latest/?op=get_preseed\n"
	if string(out) != want {
		t.Errorf("got:\n%s\nwant:\n%s", out, want)
	}
}

func TestRewriteDataEmptyAndNoBase(t *testing.T) {
	if out, err := rewriteData(nil, testBase, nil); err != nil || len(out) != 0 {
		t.Errorf("empty input: out=%q err=%v", out, err)
	}
	in := []byte("http://192.0.2.57:5248/x")
	out, _ := rewriteData(in, "", nil)
	if !bytes.Equal(out, in) {
		t.Errorf("with no base URL and no rules the body must be unchanged, got %q", out)
	}
}

func TestRewriteDataTrimsTrailingSlashOfBase(t *testing.T) {
	out, _ := rewriteData([]byte(testRack+"/a"), testBase+"/", nil)
	if string(out) != testBase+"/a" {
		t.Errorf("got %q", out)
	}
}

func TestRewriteDataOnlyRewritesPort5248HTTP(t *testing.T) {
	in := "http://192.0.2.57:5240/MAAS https://192.0.2.57:5248/x http://192.0.2.57:5248"
	out, _ := rewriteData([]byte(in), testBase, nil)
	for _, keep := range []string{"http://192.0.2.57:5240/MAAS", "https://192.0.2.57:5248/x"} {
		if !strings.Contains(string(out), keep) {
			t.Errorf("%q must be left untouched, got %q", keep, out)
		}
	}
	if strings.HasSuffix(string(out), ":5248") {
		t.Errorf("the plain http rack URL at the end must be rewritten, got %q", out)
	}
}

func TestRewriteDataExtraRules(t *testing.T) {
	rules := []Rewrite{{From: "old.example.com", To: "new.example.com"}, {From: "", To: "ignored"}}
	out, _ := rewriteData([]byte("host old.example.com and "+testRack), testBase, rules)
	if string(out) != "host new.example.com and "+testBase {
		t.Errorf("got %q", out)
	}
}

type tarEntry struct {
	hdr  tar.Header
	data string
}

// buildPayload creates a self-extracting curtin-style script: a shell header with an
// MD5SUM line, the payload marker, then a base64 (76 columns) tar.gz.
func buildPayload(t *testing.T, header string, entries []tarEntry) []byte {
	t.Helper()
	var gz bytes.Buffer
	gw := gzip.NewWriter(&gz)
	tw := tar.NewWriter(gw)
	for _, e := range entries {
		h := e.hdr
		h.Size = int64(len(e.data))
		if err := tw.WriteHeader(&h); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write([]byte(e.data)); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gw.Close(); err != nil {
		t.Fatal(err)
	}
	return []byte(header + "_____PAYLOAD_____\n" + wrap76(base64.StdEncoding.EncodeToString(gz.Bytes())) + "\n")
}

func wrap76(s string) string {
	var out []string
	for len(s) > 76 {
		out = append(out, s[:76])
		s = s[76:]
	}
	return strings.Join(append(out, s), "\n")
}

// unpackPayload reverses buildPayload and returns the header, gz bytes and tar entries.
func unpackPayload(t *testing.T, b []byte) (header string, gz []byte, files map[string]string, hdrs map[string]tar.Header) {
	t.Helper()
	loc := payloadMarkerRe.FindIndex(b)
	if loc == nil {
		t.Fatalf("payload marker missing")
	}
	raw := bytes.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, b[loc[1]:])
	gz, err := base64.StdEncoding.DecodeString(string(raw))
	if err != nil {
		t.Fatalf("base64: %v", err)
	}
	zr, err := gzip.NewReader(bytes.NewReader(gz))
	if err != nil {
		t.Fatal(err)
	}
	files, hdrs = map[string]string{}, map[string]tar.Header{}
	tr := tar.NewReader(zr)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(tr)
		files[h.Name], hdrs[h.Name] = string(data), *h
	}
	return string(b[:loc[0]]), gz, files, hdrs
}

func TestRewriteDataSelfExtractingArchive(t *testing.T) {
	header := "#!/bin/sh\nURL=" + testRack + "/curtin\nMD5SUM='00000000000000000000000000000000'\nSIZE=1\n"
	in := buildPayload(t, header, []tarEntry{
		{tar.Header{Name: "curtin/", Typeflag: tar.TypeDir, Mode: 0o755}, ""},
		{tar.Header{Name: "curtin/a.yaml", Typeflag: tar.TypeReg, Mode: 0o644}, "url: " + testRack + "/a\n"},
		{tar.Header{Name: "curtin/b.txt", Typeflag: tar.TypeReg, Mode: 0o600}, "nothing to rewrite\n"},
		{tar.Header{Name: "curtin/link", Typeflag: tar.TypeSymlink, Linkname: "a.yaml", Mode: 0o777}, ""},
		{tar.Header{Name: "curtin/big.txt", Typeflag: tar.TypeReg, Mode: 0o644}, strings.Repeat("line "+testRack+"\n", 2000)},
	})
	out, err := rewriteData(in, testBase, nil)
	if err != nil {
		t.Fatal(err)
	}
	gotHeader, gz, files, hdrs := unpackPayload(t, out)

	if !strings.Contains(gotHeader, "URL="+testBase+"/curtin") || strings.Contains(gotHeader, ":5248") {
		t.Errorf("header URL not rewritten:\n%s", gotHeader)
	}
	if want := fmt.Sprintf("MD5SUM='%x'", md5.Sum(gz)); !strings.Contains(gotHeader, want) {
		t.Errorf("header MD5SUM not updated to %s:\n%s", want, gotHeader)
	}
	if !strings.Contains(gotHeader, "SIZE=1\n") {
		t.Errorf("unrelated header lines must be preserved:\n%s", gotHeader)
	}
	if files["curtin/a.yaml"] != "url: "+testBase+"/a\n" {
		t.Errorf("a.yaml = %q", files["curtin/a.yaml"])
	}
	if files["curtin/b.txt"] != "nothing to rewrite\n" {
		t.Errorf("b.txt = %q", files["curtin/b.txt"])
	}
	if want := strings.Repeat("line "+testBase+"\n", 2000); files["curtin/big.txt"] != want {
		t.Errorf("big.txt was not fully rewritten (len %d, want %d)", len(files["curtin/big.txt"]), len(want))
	}
	if hdrs["curtin/"].Typeflag != tar.TypeDir || hdrs["curtin/link"].Typeflag != tar.TypeSymlink || hdrs["curtin/link"].Linkname != "a.yaml" {
		t.Errorf("directory/symlink entries were not preserved: %+v %+v", hdrs["curtin/"], hdrs["curtin/link"])
	}
	if hdrs["curtin/b.txt"].Mode != 0o600 {
		t.Errorf("file mode not preserved: %o", hdrs["curtin/b.txt"].Mode)
	}
	if hdrs["curtin/a.yaml"].Size != int64(len(files["curtin/a.yaml"])) {
		t.Errorf("tar header size not updated")
	}

	// Payload is wrapped at 76 columns and the file ends with a newline.
	loc := payloadMarkerRe.FindIndex(out)
	for i, line := range strings.Split(strings.TrimRight(string(out[loc[1]:]), "\n"), "\n") {
		if len(line) > 76 {
			t.Fatalf("payload line %d is %d columns", i, len(line))
		}
	}
	if !bytes.HasSuffix(out, []byte("\n")) {
		t.Errorf("output must end with a newline")
	}
}

func TestRewriteDataInvalidPayloadFallsBackToTextReplacement(t *testing.T) {
	notBase64 := "#!/bin/sh\nURL=" + testRack + "/x\n_____PAYLOAD_____\n!!! not base64 !!!\n"
	notGzip := "#!/bin/sh\nURL=" + testRack + "/x\n_____PAYLOAD_____\n" + base64.StdEncoding.EncodeToString([]byte("plain bytes")) + "\n"
	var gz bytes.Buffer
	gw := gzip.NewWriter(&gz)
	gw.Write(bytes.Repeat([]byte{0x01}, 600)) // gzip of data that is not a tar stream
	gw.Close()
	notTar := "#!/bin/sh\nURL=" + testRack + "/x\n_____PAYLOAD_____\n" + base64.StdEncoding.EncodeToString(gz.Bytes()) + "\n"

	for name, in := range map[string]string{"not-base64": notBase64, "not-gzip": notGzip, "not-tar": notTar} {
		out, err := rewriteData([]byte(in), testBase, nil)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		want := strings.ReplaceAll(in, testRack, testBase)
		if string(out) != want {
			t.Errorf("%s: expected plain text substitution only.\ngot:  %q\nwant: %q", name, out, want)
		}
	}
}

func TestLineWrapWriter(t *testing.T) {
	data := strings.Repeat("abcdefghij", 20) // 200 bytes
	for _, chunk := range []int{1, 7, 76, 77, 200} {
		var buf bytes.Buffer
		w := &lineWrapWriter{w: &buf, lineLen: 76}
		for i := 0; i < len(data); i += chunk {
			end := i + chunk
			if end > len(data) {
				end = len(data)
			}
			n, err := w.Write([]byte(data[i:end]))
			if err != nil || n != end-i {
				t.Fatalf("chunk %d: n=%d err=%v", chunk, n, err)
			}
		}
		for _, line := range strings.Split(strings.TrimRight(buf.String(), "\n"), "\n") {
			if len(line) > 76 {
				t.Errorf("chunk %d: line of %d columns", chunk, len(line))
			}
		}
		if got := strings.ReplaceAll(buf.String(), "\n", ""); got != data {
			t.Errorf("chunk %d: content changed by wrapping", chunk)
		}
	}
}

type failingWriter struct{ after int }

func (f *failingWriter) Write(p []byte) (int, error) {
	if f.after <= 0 {
		return 0, io.ErrClosedPipe
	}
	f.after--
	return len(p), nil
}

func TestLineWrapWriterPropagatesErrors(t *testing.T) {
	// Fail on the data write, then on the newline write, then on a short trailing write.
	for after := 0; after < 2; after++ {
		w := &lineWrapWriter{w: &failingWriter{after: after}, lineLen: 4}
		if _, err := w.Write([]byte("abcdefgh")); err == nil {
			t.Errorf("after=%d: expected the underlying write error", after)
		}
	}
	w := &lineWrapWriter{w: &failingWriter{}, lineLen: 10}
	if _, err := w.Write([]byte("abc")); err == nil {
		t.Error("expected the underlying write error for a partial line")
	}
}

// Optional check against a real curtin payload, when one is present next to the repo.
func TestRewriteDataGoldenArchive(t *testing.T) {
	baseURL := "http://maas.example.com/boot"
	// 2. data.golden self-extracting archive test
	goldenPath := filepath.Join("..", "..", "data.golden")
	data, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Skipf("skipping self-extracting archive test: data.golden not found at %s", goldenPath)
	}

	rewrittenGolden, err := rewriteData(data, baseURL, nil)
	if err != nil {
		t.Fatalf("rewriteData on data.golden failed: %v", err)
	}

	markerLoc := payloadMarkerRe.FindIndex(rewrittenGolden)
	if markerLoc == nil {
		t.Fatalf("payload marker not found in rewritten output")
	}

	rawB64 := rewrittenGolden[markerLoc[1]:]
	b64Clean := bytes.Map(func(r rune) rune {
		if r == ' ' || r == '\t' || r == '\r' || r == '\n' {
			return -1
		}
		return r
	}, rawB64)

	decodedGz, err := base64.StdEncoding.DecodeString(string(b64Clean))
	if err != nil {
		t.Fatalf("base64 decode failed: %v", err)
	}

	expectedMD5 := fmt.Sprintf("%x", md5.Sum(decodedGz))
	headerStr := string(rewrittenGolden[:markerLoc[0]])
	if !strings.Contains(headerStr, "MD5SUM='"+expectedMD5+"'") {
		t.Errorf("header MD5SUM mismatch: expected %s, got:\n%s", expectedMD5, headerStr[:200])
	}

	gzr, err := gzip.NewReader(bytes.NewReader(decodedGz))
	if err != nil {
		t.Fatalf("gzip reader failed: %v", err)
	}
	defer gzr.Close()

	tr := tar.NewReader(gzr)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar reading error: %v", err)
		}
		var buf bytes.Buffer
		if _, err := io.Copy(&buf, tr); err != nil {
			t.Fatalf("copying tar entry: %v", err)
		}
		if strings.Contains(buf.String(), ":5248") {
			t.Errorf("tar entry %s contains :5248", hdr.Name)
		}
	}
}
