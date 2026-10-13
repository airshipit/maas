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
	"log"
	"strings"
	"sync"
	"time"
)

// ISOCache is a thread-safe in-memory cache for dynamic ISO images with TTL expiration.
type ISOCache struct {
	mu     sync.RWMutex
	isos   map[string]*CachedISO
	ttl    time.Duration
	stopCh chan struct{}
}

// NewISOCache creates a new ISOCache with the given TTL and reaper interval.
func NewISOCache(ttl time.Duration, reaperInterval time.Duration) *ISOCache {
	if ttl <= 0 {
		ttl = 30 * time.Minute
	}
	ic := &ISOCache{
		isos:   make(map[string]*CachedISO),
		ttl:    ttl,
		stopCh: make(chan struct{}),
	}
	if reaperInterval > 0 {
		go ic.startReaper(reaperInterval)
	}
	return ic
}

// Get retrieves a cached ISO by MAC if present and unexpired, updating its LastAccess time.
func (c *ISOCache) Get(mac string) (*CachedISO, bool) {
	key := strings.ToLower(strings.TrimSpace(mac))
	c.mu.Lock()
	defer c.mu.Unlock()

	entry, ok := c.isos[key]
	if !ok {
		return nil, false
	}
	if time.Since(entry.LastAccess) > c.ttl {
		delete(c.isos, key)
		return nil, false
	}
	entry.LastAccess = time.Now()
	return entry, true
}

// Set stores a generated ISO in the cache.
func (c *ISOCache) Set(mac string, configHash string, data []byte) *CachedISO {
	key := strings.ToLower(strings.TrimSpace(mac))
	now := time.Now()
	c.mu.Lock()
	defer c.mu.Unlock()

	entry := &CachedISO{
		Data:       data,
		ConfigHash: configHash,
		ModTime:    now,
		LastAccess: now,
	}
	c.isos[key] = entry
	return entry
}

// Len returns the count of active ISO entries in the cache.
func (c *ISOCache) Len() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.isos)
}

// Reap sweeps the cache and deletes entries that haven't been accessed within the TTL.
func (c *ISOCache) Reap() int {
	c.mu.Lock()
	defer c.mu.Unlock()

	evicted := 0
	now := time.Now()
	for mac, entry := range c.isos {
		if now.Sub(entry.LastAccess) > c.ttl {
			delete(c.isos, mac)
			evicted++
		}
	}
	return evicted
}

func (c *ISOCache) startReaper(interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			if evicted := c.Reap(); evicted > 0 {
				log.Printf("ISOCache reaper: evicted %d expired ISO(s)", evicted)
			}
		case <-c.stopCh:
			return
		}
	}
}

// Close stops the reaper goroutine.
func (c *ISOCache) Close() {
	select {
	case <-c.stopCh:
	default:
		close(c.stopCh)
	}
}
