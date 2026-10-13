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
	"time"
)

// Node represents the network and identity configuration of a bare metal machine.
type Node struct {
	IP          string   `json:"ip"`
	Netmask     string   `json:"netmask"`
	GW          string   `json:"gw"`
	VLAN        string   `json:"vlan"`
	Dev         string   `json:"dev"`
	Hostname    string   `json:"hostname"`
	DNS         string   `json:"dns,omitempty"`
	DNS2        string   `json:"dns2,omitempty"`
	BondMembers []string `json:"bond_members,omitempty"`
	BondName    string   `json:"bond_name,omitempty"`
	BondMode    string   `json:"bond_mode,omitempty"`
	LACPRate    string   `json:"lacp_rate,omitempty"`
	HashPolicy  string   `json:"hash_policy,omitempty"`
	KernelNet   string   `json:"kernel_net,omitempty"`
}

func (n Node) bonded() bool {
	return len(n.BondMembers) > 0
}

// CachedNode wraps a Node record with TTL access tracking.
type CachedNode struct {
	Node       Node
	LastAccess time.Time
	CreatedAt  time.Time
}

// CachedISO holds in-memory ISO image bytes with metadata and TTL access tracking.
type CachedISO struct {
	Data       []byte
	ConfigHash string
	ModTime    time.Time
	LastAccess time.Time
}

// Rewrite holds static string replacement rules.
type Rewrite struct {
	From string `json:"from"`
	To   string `json:"to"`
}

// Config represents the proxy configuration (optionally populated from config file or env).
type Config struct {
	RackUpstream string          `json:"rack_upstream"` // e.g. http://192.0.2.57:5248
	ProxyBase    string          `json:"proxy_base"`    // e.g. http://maas.example.com/boot
	OverlayURL   string          `json:"overlay_url"`   // URL for initrd overlay (defaults to ProxyBase + /genesis-overlay.cpio.gz)
	Rewrites     []Rewrite       `json:"rewrites"`      // additional constant rewrites
	Nodes        map[string]Node `json:"nodes"`         // statically configured nodes, keyed by lowercase MAC
}
