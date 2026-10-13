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
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeNodes(t *testing.T, path, body string) {
	t.Helper()
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

func TestNodeStoreHotReload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nodes.json")
	s := NewNodeStore(path)

	// Missing file is not an error and yields no nodes.
	if changed, err := s.Reload(); changed || err != nil {
		t.Fatalf("missing file: changed=%v err=%v", changed, err)
	}

	writeNodes(t, path, `{"version":1,"nodes":{"AA:BB:CC:DD:EE:01":{"hostname":"n1","ip":"10.0.0.1"}}}`)
	if changed, err := s.Reload(); !changed || err != nil {
		t.Fatalf("first load: changed=%v err=%v", changed, err)
	}
	if n, ok := s.Get("aa-bb-cc-dd-ee-01"); !ok || n.Hostname != "n1" {
		t.Fatalf("lookup failed: %+v %v", n, ok)
	}
	if changed, _ := s.Reload(); changed {
		t.Fatal("unchanged content must not report a change")
	}

	// Updated content replaces the old data, including removals.
	writeNodes(t, path, `{"version":1,"nodes":{"aa:bb:cc:dd:ee:02":{"hostname":"n2"}}}`)
	if changed, _ := s.Reload(); !changed {
		t.Fatal("expected change")
	}
	if _, ok := s.Get("aa:bb:cc:dd:ee:01"); ok {
		t.Fatal("removed node still present")
	}
	if _, ok := s.Get("aa:bb:cc:dd:ee:02"); !ok {
		t.Fatal("new node missing")
	}

	// Invalid and removed files keep the last good data.
	writeNodes(t, path, `{not json`)
	if _, err := s.Reload(); err == nil {
		t.Fatal("expected parse error")
	}
	if _, ok := s.Get("aa:bb:cc:dd:ee:02"); !ok {
		t.Fatal("last good data lost after invalid file")
	}
	os.Remove(path)
	_, _ = s.Reload()
	if _, ok := s.Get("aa:bb:cc:dd:ee:02"); !ok {
		t.Fatal("last good data lost after file removal")
	}

	// A newer schema version is rejected.
	writeNodes(t, path, `{"version":99,"nodes":{}}`)
	if _, err := s.Reload(); err == nil {
		t.Fatal("expected unsupported version error")
	}
}

func TestResolveNodeSeesFileUpdateWithoutRestart(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nodes.json")
	srv := NewServer(Config{}, "", path, time.Minute, 0)

	if _, ok := srv.resolveNode(context.Background(), "aa:bb:cc:dd:ee:01"); ok {
		t.Fatal("unexpected node")
	}
	writeNodes(t, path, `{"version":1,"nodes":{"aa:bb:cc:dd:ee:01":{"hostname":"n1"}}}`)
	if n, ok := srv.resolveNode(context.Background(), "AA:BB:CC:DD:EE:01"); !ok || n.Hostname != "n1" {
		t.Fatalf("expected immediate reload on miss, got %+v %v", n, ok)
	}

	// Edits to an already-known node are served after the background watcher runs.
	writeNodes(t, path, `{"version":1,"nodes":{"aa:bb:cc:dd:ee:01":{"hostname":"n1-new"}}}`)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.Watch(ctx, 10*time.Millisecond)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if n, _ := srv.nodes.Get("aa:bb:cc:dd:ee:01"); n.Hostname == "n1-new" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("watcher did not pick up the edit")
}

func TestResolveNodeMissWait(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nodes.json")
	srv := NewServer(Config{}, "", path, time.Minute, 0)
	srv.missWait = 3 * time.Second

	go func() {
		time.Sleep(700 * time.Millisecond)
		writeNodes(t, path, `{"version":1,"nodes":{"aa:bb:cc:dd:ee:09":{"hostname":"late"}}}`)
	}()
	if n, ok := srv.resolveNode(context.Background(), "aa:bb:cc:dd:ee:09"); !ok || n.Hostname != "late" {
		t.Fatalf("expected late node, got %+v %v", n, ok)
	}
}

func TestConfigReloadKeepsEnvOverrides(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.json")
	writeNodes(t, path, `{"rack_upstream":"http://file:5248","proxy_base":"http://file/boot","nodes":{"AA:BB:CC:DD:EE:03":{"hostname":"static"}}}`)
	srv := NewServer(Config{}, path, "", time.Minute, 0)
	srv.overrides = Config{ProxyBase: "http://env/boot"}
	srv.Reload()

	cfg := srv.getConfig()
	if cfg.RackUpstream != "http://file:5248" || cfg.ProxyBase != "http://env/boot" {
		t.Fatalf("unexpected merge: %+v", cfg)
	}
	if n, ok := srv.resolveNode(context.Background(), "aa:bb:cc:dd:ee:03"); !ok || n.Hostname != "static" {
		t.Fatalf("static node not resolved: %+v %v", n, ok)
	}

	writeNodes(t, path, `{"rack_upstream":"http://file2:5248"}`)
	srv.Reload()
	if got := srv.getConfig().RackUpstream; got != "http://file2:5248" {
		t.Fatalf("config not hot reloaded: %s", got)
	}
	writeNodes(t, path, `garbage`)
	srv.Reload()
	if got := srv.getConfig().RackUpstream; got != "http://file2:5248" {
		t.Fatalf("invalid config replaced good one: %s", got)
	}
}
