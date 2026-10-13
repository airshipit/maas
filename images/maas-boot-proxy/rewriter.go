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
	"regexp"
	"strings"
)

var (
	defaultRackURLRe = regexp.MustCompile(`http://[^/:[:space:]"'\x60]+:5248`)
	md5SumRe         = regexp.MustCompile(`(?m)^MD5SUM=['"][a-fA-F0-9]{32}['"]`)
	payloadMarkerRe  = regexp.MustCompile(`(?m)^_____PAYLOAD_____\r?$`)
)

// rewriteData rewrites plain text bodies or unpacks and modifies self-extracting shell archives.
func rewriteData(input []byte, baseURL string, rewrites []Rewrite) ([]byte, error) {
	if len(input) == 0 {
		return input, nil
	}

	baseURL = strings.TrimRight(baseURL, "/")

	applySubs := func(data []byte) []byte {
		if baseURL != "" {
			data = defaultRackURLRe.ReplaceAll(data, []byte(baseURL))
		}
		for _, r := range rewrites {
			if r.From != "" {
				data = []byte(strings.ReplaceAll(string(data), r.From, r.To))
			}
		}
		return data
	}

	// Check if this is a self-extracting shell archive (e.g. data.golden / curtin payload).
	markerLoc := payloadMarkerRe.FindIndex(input)
	if markerLoc == nil {
		// Plain text stream (e.g. ipxe.cfg, standard YAML preseed, cloud-config).
		return applySubs(input), nil
	}

	header := input[:markerLoc[0]]
	rawPayload := input[markerLoc[1]:]

	// Strip whitespace and newlines from base64 payload
	b64Clean := bytes.Map(func(r rune) rune {
		if r == ' ' || r == '\t' || r == '\r' || r == '\n' {
			return -1
		}
		return r
	}, rawPayload)

	decoded, err := base64.StdEncoding.DecodeString(string(b64Clean))
	if err != nil || len(decoded) < 2 || decoded[0] != 0x1f || decoded[1] != 0x8b {
		// Not a valid base64-encoded gzip archive; fall back to simple text replacement.
		return applySubs(input), nil
	}

	// Decompress gzip tar archive
	gzr, err := gzip.NewReader(bytes.NewReader(decoded))
	if err != nil {
		return applySubs(input), nil
	}
	defer gzr.Close()

	tr := tar.NewReader(gzr)
	var newGzBuf bytes.Buffer
	gzw, err := gzip.NewWriterLevel(&newGzBuf, gzip.BestCompression)
	if err != nil {
		gzw = gzip.NewWriter(&newGzBuf)
	}
	tw := tar.NewWriter(gzw)

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return applySubs(input), nil
		}

		var fileContent bytes.Buffer
		if _, err := io.Copy(&fileContent, tr); err != nil {
			return applySubs(input), nil
		}

		rawBytes := fileContent.Bytes()
		if hdr.Typeflag == tar.TypeReg || hdr.Typeflag == tar.TypeRegA {
			newBytes := applySubs(rawBytes)
			hdr.Size = int64(len(newBytes))
			if err := tw.WriteHeader(hdr); err != nil {
				return applySubs(input), nil
			}
			if _, err := tw.Write(newBytes); err != nil {
				return applySubs(input), nil
			}
		} else {
			if err := tw.WriteHeader(hdr); err != nil {
				return applySubs(input), nil
			}
			if len(rawBytes) > 0 {
				if _, err := tw.Write(rawBytes); err != nil {
					return applySubs(input), nil
				}
			}
		}
	}

	if err := tw.Close(); err != nil {
		return applySubs(input), nil
	}
	if err := gzw.Close(); err != nil {
		return applySubs(input), nil
	}

	newGzBytes := newGzBuf.Bytes()
	newMD5 := fmt.Sprintf("%x", md5.Sum(newGzBytes))

	// Rewrite header
	header = applySubs(header)
	header = md5SumRe.ReplaceAll(header, []byte("MD5SUM='"+newMD5+"'"))

	// Base64 encode with 76 characters per line
	var b64Buf bytes.Buffer
	encoder := base64.NewEncoder(base64.StdEncoding, &lineWrapWriter{w: &b64Buf, lineLen: 76})
	if _, err := encoder.Write(newGzBytes); err != nil {
		return applySubs(input), nil
	}
	if err := encoder.Close(); err != nil {
		return applySubs(input), nil
	}

	var result bytes.Buffer
	result.Write(header)
	if !bytes.HasSuffix(header, []byte("\n")) {
		result.WriteByte('\n')
	}
	result.WriteString("_____PAYLOAD_____")
	result.WriteByte('\n')
	result.Write(b64Buf.Bytes())
	if !bytes.HasSuffix(result.Bytes(), []byte("\n")) {
		result.WriteByte('\n')
	}

	return result.Bytes(), nil
}

type lineWrapWriter struct {
	w       io.Writer
	lineLen int
	col     int
}

func (l *lineWrapWriter) Write(p []byte) (int, error) {
	n := len(p)
	for len(p) > 0 {
		remain := l.lineLen - l.col
		if len(p) < remain {
			if _, err := l.w.Write(p); err != nil {
				return 0, err
			}
			l.col += len(p)
			break
		}
		if _, err := l.w.Write(p[:remain]); err != nil {
			return 0, err
		}
		if _, err := l.w.Write([]byte("\n")); err != nil {
			return 0, err
		}
		p = p[remain:]
		l.col = 0
	}
	return n, nil
}
