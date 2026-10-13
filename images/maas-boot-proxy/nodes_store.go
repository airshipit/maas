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
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net"
	"os"
	"strings"
	"sync"
)

// NodesFileVersion is the nodes document schema version this proxy understands.
const NodesFileVersion = 1

// NodesFile is the document the operator (or any other producer) writes to the
// nodes file: {"version": 1, "nodes": {"<mac>": {...Node...}}}.
type NodesFile struct {
	Version int             `json:"version"`
	Nodes   map[string]Node `json:"nodes"`
}

// NodeStore holds the node records loaded from a file. The file is re-read on
// demand and only swapped in when its content hash changes, so a bad or
// half-written file never replaces the last good data.
type NodeStore struct {
	path string

	mu      sync.RWMutex
	nodes   map[string]Node
	hash    [sha256.Size]byte
	loaded  bool
	lastErr string
}

// NewNodeStore creates a store backed by path. An empty path yields a store
// that only holds entries added with Put.
func NewNodeStore(path string) *NodeStore {
	return &NodeStore{path: path, nodes: map[string]Node{}}
}

// Get returns the node registered for mac.
func (s *NodeStore) Get(mac string) (Node, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	n, ok := s.nodes[normalizeKey(mac)]
	return n, ok
}

// Put adds an in-memory entry; the next successful file load replaces it.
func (s *NodeStore) Put(mac string, n Node) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.nodes[normalizeKey(mac)] = n
}

// Len returns the number of known nodes.
func (s *NodeStore) Len() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.nodes)
}

// Reload re-reads the file and reports whether the node set changed. On any
// error the previous data is kept.
func (s *NodeStore) Reload() (bool, error) {
	if s.path == "" {
		return false, nil
	}
	b, err := os.ReadFile(s.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			s.noteError("nodes file %s not found; keeping %d known node(s)", s.path, s.Len())
			return false, nil
		}
		s.noteError("reading nodes file %s: %v", s.path, err)
		return false, err
	}

	sum := sha256.Sum256(b)
	s.mu.RLock()
	same := s.loaded && sum == s.hash
	s.mu.RUnlock()
	if same {
		return false, nil
	}

	nodes, err := parseNodes(b)
	if err != nil {
		s.noteError("ignoring invalid nodes file %s (keeping previous data): %v", s.path, err)
		return false, err
	}

	s.mu.Lock()
	old := s.nodes
	s.nodes = nodes
	s.hash = sum
	s.loaded = true
	s.lastErr = ""
	s.mu.Unlock()

	added, removed, changed := diffNodes(old, nodes)
	log.Printf("nodes file %s reloaded: %d node(s) (+%d -%d ~%d)", s.path, len(nodes), added, removed, changed)
	return true, nil
}

// noteError logs a failure once until the file state changes.
func (s *NodeStore) noteError(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	s.mu.Lock()
	repeat := s.lastErr == msg
	s.lastErr = msg
	s.mu.Unlock()
	if !repeat {
		log.Print(msg)
	}
}

func parseNodes(b []byte) (map[string]Node, error) {
	var f NodesFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, err
	}
	if f.Version > NodesFileVersion {
		return nil, fmt.Errorf("unsupported nodes file version %d (max %d)", f.Version, NodesFileVersion)
	}
	out := make(map[string]Node, len(f.Nodes))
	for k, v := range f.Nodes {
		out[normalizeKey(k)] = v
	}
	return out, nil
}

func diffNodes(old, cur map[string]Node) (added, removed, changed int) {
	for k, v := range cur {
		o, ok := old[k]
		switch {
		case !ok:
			added++
		case !nodeEqual(o, v):
			changed++
		}
	}
	for k := range old {
		if _, ok := cur[k]; !ok {
			removed++
		}
	}
	return
}

func nodeEqual(a, b Node) bool {
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return string(x) == string(y)
}

// normalizeKey canonicalizes a MAC; unparsable keys are only lowercased.
func normalizeKey(s string) string {
	if n := normalizeMAC(s); n != "" {
		return n
	}
	return strings.ToLower(strings.TrimSpace(s))
}

func normalizeMAC(s string) string {
	hw, err := net.ParseMAC(strings.TrimSpace(s))
	if err != nil || len(hw) != 6 {
		return ""
	}
	return strings.ToLower(hw.String())
}

func isPCIAddr(s string) bool {
	return strings.Count(s, ":") >= 2 || (strings.Contains(s, ":") && strings.Contains(s, "."))
}
