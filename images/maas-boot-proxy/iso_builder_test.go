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
	"regexp"
	"strings"
	"testing"
)

func TestRenderNodeIPXEScriptPCI(t *testing.T) {
	node := Node{
		Hostname:    "node-c",
		IP:          "198.51.100.103",
		Netmask:     "255.255.255.192",
		GW:          "198.51.100.121",
		VLAN:        "120",
		DNS:         "203.0.113.5",
		BondMembers: []string{"0000:3b:00.0", "af:00.1"},
	}
	mac := "02:5e:1c:9a:47:d3"
	proxyBase := "http://maas.example.com/boot"

	script := RenderNodeIPXEScript(node, mac, proxyBase)

	// PCI addresses should be formatted as 0000:bus:dev.fn to match iPXE's ${netX/busloc:busdevfn}
	expectedPci0 := "set pci0 0000:3b:00.0\n"
	expectedPci1 := "set pci1 0000:af:00.1\n"
	if !strings.Contains(script, expectedPci0) {
		t.Errorf("expected script to contain %q, got:\n%s", expectedPci0, script)
	}
	if !strings.Contains(script, expectedPci1) {
		t.Errorf("expected script to contain %q, got:\n%s", expectedPci1, script)
	}
	// When PCI addresses are specified, target_mac should NOT be set or matched
	if strings.Contains(script, "set target_mac") {
		t.Errorf("expected script NOT to contain target_mac when PCI members are present, got:\n%s", script)
	}
	expectedChain := "chain --autofree http://maas.example.com/boot/ipxe.cfg-${net${nic}/mac} && goto os_done ||\n"
	if !strings.Contains(script, expectedChain) {
		t.Errorf("expected script to contain %q, got:\n%s", expectedChain, script)
	}
}

func TestRenderNodeIPXEScriptTargetMACFallback(t *testing.T) {
	node := Node{
		Hostname: "node-c",
		IP:       "192.0.2.23",
		Netmask:  "255.255.255.128",
		GW:       "192.0.2.254",
	}
	mac := "02:5e:1c:9a:47:d3"
	proxyBase := "http://maas.example.com/boot"

	script := RenderNodeIPXEScript(node, mac, proxyBase)

	expectedMac := "set target_mac 02:5e:1c:9a:47:d3\n"
	expectedMatch := "iseq ${net${nic}/mac} ${target_mac} && goto hit ||\n"
	if !strings.Contains(script, expectedMac) {
		t.Errorf("expected script to contain %q, got:\n%s", expectedMac, script)
	}
	if !strings.Contains(script, expectedMatch) {
		t.Errorf("expected script to contain %q, got:\n%s", expectedMatch, script)
	}
	expectedChain := "chain --autofree http://maas.example.com/boot/ipxe.cfg-${net${nic}/mac} && goto os_done ||\n"
	if !strings.Contains(script, expectedChain) {
		t.Errorf("expected script to contain %q, got:\n%s", expectedChain, script)
	}
}

func TestFormatIPXEPCI(t *testing.T) {
	cases := map[string]string{
		"0000:3b:00.0":   "0000:3b:00.0",
		"0000:3B:00.0":   "0000:3b:00.0",
		" 0000:af:00.1 ": "0000:af:00.1",
		"0001:3b:1f.7":   "0001:3b:1f.7",
		"3b:00.1":        "0000:3b:00.1",
		"AF:00.1":        "0000:af:00.1",
		"ens2f1":         "ens2f1",
		"ENS2F1":         "ens2f1",
		"0000:zz:00.0":   "0000:zz:00.0", // not hex: passed through lower-cased
		"3b:zz.1":        "3b:zz.1",
	}
	for in, want := range cases {
		if got := formatIPXEPCI(in); got != want {
			t.Errorf("formatIPXEPCI(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestComputeNodeConfigHash(t *testing.T) {
	base := Node{
		IP: "198.51.100.87", Netmask: "255.255.255.192", GW: "198.51.100.121", VLAN: "120",
		Dev: "eno1", Hostname: "node-a", DNS: "203.0.113.5", DNS2: "203.0.113.6",
		BondMembers: []string{"0000:3b:00.0"}, BondName: "bond0", BondMode: "802.3ad",
		LACPRate: "fast", HashPolicy: "layer3+4", KernelNet: "x",
	}
	const mac, proxy = "02:5e:1c:9a:47:d3", "http://maas.example.com/boot"
	ref := ComputeNodeConfigHash(base, mac, proxy)
	if !regexp.MustCompile(`^[0-9a-f]{16}$`).MatchString(ref) {
		t.Fatalf("hash %q is not 16 hex characters", ref)
	}
	if ComputeNodeConfigHash(base, mac, proxy) != ref {
		t.Error("hash is not stable")
	}
	if ComputeNodeConfigHash(base, mac, proxy+"/") != ref {
		t.Error("a trailing slash on the proxy base must not change the hash")
	}

	mutators := map[string]func(n *Node){
		"IP":          func(n *Node) { n.IP = "198.51.100.99" },
		"Netmask":     func(n *Node) { n.Netmask = "255.255.255.0" },
		"GW":          func(n *Node) { n.GW = "198.51.100.1" },
		"VLAN":        func(n *Node) { n.VLAN = "121" },
		"Dev":         func(n *Node) { n.Dev = "eno2" },
		"Hostname":    func(n *Node) { n.Hostname = "node-z" },
		"DNS":         func(n *Node) { n.DNS = "203.0.113.50" },
		"DNS2":        func(n *Node) { n.DNS2 = "203.0.113.60" },
		"BondMembers": func(n *Node) { n.BondMembers = []string{"0000:af:00.1"} },
		"BondName":    func(n *Node) { n.BondName = "bond1" },
		"BondMode":    func(n *Node) { n.BondMode = "active-backup" },
		"LACPRate":    func(n *Node) { n.LACPRate = "slow" },
		"HashPolicy":  func(n *Node) { n.HashPolicy = "layer2" },
		"KernelNet":   func(n *Node) { n.KernelNet = "y" },
	}
	for field, mutate := range mutators {
		n := base
		mutate(&n)
		if ComputeNodeConfigHash(n, mac, proxy) == ref {
			t.Errorf("changing %s did not change the hash", field)
		}
	}
	if ComputeNodeConfigHash(base, "02:00:00:00:00:01", proxy) == ref {
		t.Error("changing the MAC did not change the hash")
	}
	if ComputeNodeConfigHash(base, mac, "http://other.example.com/boot") == ref {
		t.Error("changing the proxy base did not change the hash")
	}
}

func TestRenderGenericIPXEScript(t *testing.T) {
	script := RenderGenericIPXEScript("http://maas.example.com/boot/")
	if !strings.HasPrefix(script, "#!ipxe\n") {
		t.Fatalf("script must start with #!ipxe, got %q", script[:10])
	}
	if !strings.Contains(script, "chain --autofree http://maas.example.com/boot/ipxe.cfg-${net${nic}/mac} && exit 0 ||\n") {
		t.Errorf("missing chain to the proxy (single slash expected):\n%s", script)
	}
	if strings.Contains(script, "boot//ipxe") {
		t.Errorf("proxy base slash was not trimmed:\n%s", script)
	}
	// Every goto target must exist as a label.
	for _, m := range regexp.MustCompile(`goto (\w+)`).FindAllStringSubmatch(script, -1) {
		if !strings.Contains(script, "\n:"+m[1]+"\n") {
			t.Errorf("goto %s has no matching label", m[1])
		}
	}
	for _, want := range []string{"ifopen net${nic}", "dhcp net${nic}", "ifclose net${nic}", "inc nic", "sleep 3"} {
		if !strings.Contains(script, want) {
			t.Errorf("generic script lacks %q", want)
		}
	}
}

func TestGenericConfigHash(t *testing.T) {
	a := GenericConfigHash("http://maas.example.com/boot")
	if !regexp.MustCompile(`^[0-9a-f]{16}$`).MatchString(a) {
		t.Fatalf("hash %q is not 16 hex characters", a)
	}
	if GenericConfigHash("http://maas.example.com/boot/") != a {
		t.Error("a trailing slash must not change the hash")
	}
	if GenericConfigHash("http://other.example.com/boot") == a {
		t.Error("different proxy bases must hash differently")
	}
	if GenericConfigHash("http://maas.example.com/boot") != a {
		t.Error("hash is not stable")
	}
}
