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
	"bytes"
	"testing"
	"time"
)

func TestISOCacheTTLAndReaping(t *testing.T) {
	cache := NewISOCache(50*time.Millisecond, 0)
	defer cache.Close()

	mac := "aa:bb:cc:dd:ee:ff"
	data := []byte("fake-iso-bytes")
	hash := "hash123"

	cache.Set(mac, hash, data)
	if cache.Len() != 1 {
		t.Errorf("expected cache len 1, got %d", cache.Len())
	}

	entry, ok := cache.Get(mac)
	if !ok || entry.ConfigHash != hash || !bytes.Equal(entry.Data, data) {
		t.Fatalf("expected cache hit, got ok=%v, entry=%+v", ok, entry)
	}

	time.Sleep(70 * time.Millisecond)

	_, ok = cache.Get(mac)
	if ok {
		t.Errorf("expected cache miss after TTL expiration")
	}

	cache.Set(mac, hash, data)
	time.Sleep(70 * time.Millisecond)
	evicted := cache.Reap()
	if evicted != 1 {
		t.Errorf("expected 1 evicted entry, got %d", evicted)
	}
}

func TestISOCacheKeyIsCaseAndSpaceInsensitive(t *testing.T) {
	c := NewISOCache(time.Minute, 0)
	defer c.Close()
	c.Set(" AA:BB:CC:DD:EE:FF ", "h", []byte("x"))
	if _, ok := c.Get("aa:bb:cc:dd:ee:ff"); !ok {
		t.Fatal("expected a hit for a differently-cased, padded key")
	}
	if c.Len() != 1 {
		t.Errorf("expected a single entry, got %d", c.Len())
	}
}

func TestISOCacheSetReplacesEntry(t *testing.T) {
	c := NewISOCache(time.Minute, 0)
	defer c.Close()
	c.Set("aa", "old", []byte("1"))
	c.Set("aa", "new", []byte("22"))
	got, ok := c.Get("aa")
	if !ok || got.ConfigHash != "new" || !bytes.Equal(got.Data, []byte("22")) {
		t.Fatalf("expected the replaced entry, got ok=%v %+v", ok, got)
	}
	if c.Len() != 1 {
		t.Errorf("expected a single entry, got %d", c.Len())
	}
}

func TestISOCacheGetRefreshesLastAccess(t *testing.T) {
	c := NewISOCache(200*time.Millisecond, 0)
	defer c.Close()
	c.Set("aa", "h", []byte("x"))
	for i := 0; i < 3; i++ {
		time.Sleep(120 * time.Millisecond)
		if _, ok := c.Get("aa"); !ok {
			t.Fatalf("entry expired after %d refreshes although it was accessed within the TTL", i)
		}
	}
}

func TestISOCacheDefaultTTL(t *testing.T) {
	c := NewISOCache(0, 0)
	defer c.Close()
	if c.ttl != 30*time.Minute {
		t.Errorf("default TTL = %v, want 30m", c.ttl)
	}
}

func TestISOCacheBackgroundReaper(t *testing.T) {
	c := NewISOCache(20*time.Millisecond, 10*time.Millisecond)
	defer c.Close()
	c.Set("aa", "h", []byte("x"))
	deadline := time.Now().Add(2 * time.Second)
	for c.Len() != 0 {
		if time.Now().After(deadline) {
			t.Fatal("background reaper did not evict the expired entry")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestISOCacheCloseIsIdempotent(t *testing.T) {
	c := NewISOCache(time.Minute, 5*time.Millisecond)
	c.Close()
	c.Close()
}
