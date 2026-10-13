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
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDynamicISOGenerationAndRangeRequests(t *testing.T) {
	node := Node{
		Hostname:    "node-a",
		IP:          "198.51.100.87",
		Netmask:     "255.255.255.192",
		GW:          "198.51.100.121",
		VLAN:        "120",
		DNS:         "203.0.113.5",
		BondMembers: []string{"0000:3b:00.0", "0000:af:00.1"},
	}
	mac := "aa:bb:cc:dd:ee:01"

	server := NewServer(Config{ProxyBase: "http://maas.example.com/boot"}, "", "", 30*time.Minute, 0)
	server.ipxeEFI = testIPXEEFI()
	server.nodes.Put(mac, node)

	// 1. Full GET request for /iso/<mac>.iso
	req := httptest.NewRequest(http.MethodGet, "/iso/"+mac+".iso", nil)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)

	res := rec.Result()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK for ISO request, got %d", res.StatusCode)
	}
	fullBody, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatalf("reading body: %v", err)
	}
	if len(fullBody)%isoSectorSize != 0 || len(fullBody) < len(server.ipxeEFI) {
		t.Fatalf("unexpected ISO size %d", len(fullBody))
	}

	// Verify the embedded script inside the returned dynamic ISO matches our node
	if !bytes.Contains(fullBody, []byte(node.Hostname)) {
		t.Errorf("dynamic ISO does not contain node hostname %s", node.Hostname)
	}
	if !bytes.Contains(fullBody, []byte(node.IP)) {
		t.Errorf("dynamic ISO does not contain node IP %s", node.IP)
	}
	if !bytes.Contains(fullBody, []byte("set pci0 0000:3b:00.0")) {
		t.Errorf("dynamic ISO should contain normalized pci0 'set pci0 0000:3b:00.0'")
	}
	if !bytes.Contains(fullBody, []byte("set pci1 0000:af:00.1")) {
		t.Errorf("dynamic ISO should contain normalized pci1 'set pci1 0000:af:00.1'")
	}

	// 2. HTTP Range request (e.g. bytes=0-511 as sent by iDRAC VirtualMedia)
	rangeReq := httptest.NewRequest(http.MethodGet, "/iso/"+mac+".iso", nil)
	rangeReq.Header.Set("Range", "bytes=0-511")
	rangeRec := httptest.NewRecorder()
	server.ServeHTTP(rangeRec, rangeReq)

	rangeRes := rangeRec.Result()
	if rangeRes.StatusCode != http.StatusPartialContent {
		t.Fatalf("expected 206 Partial Content, got %d", rangeRes.StatusCode)
	}
	rangeBody, err := io.ReadAll(rangeRes.Body)
	if err != nil {
		t.Fatalf("reading range body: %v", err)
	}
	if len(rangeBody) != 512 {
		t.Fatalf("expected 512 bytes for range 0-511, got %d", len(rangeBody))
	}
	if !bytes.Equal(rangeBody, fullBody[:512]) {
		t.Fatalf("range content does not match full body slice")
	}

	// 3. Middle range request (e.g. bytes=1024-2047)
	rangeReq2 := httptest.NewRequest(http.MethodGet, "/iso/"+mac+".iso", nil)
	rangeReq2.Header.Set("Range", "bytes=1024-2047")
	rangeRec2 := httptest.NewRecorder()
	server.ServeHTTP(rangeRec2, rangeReq2)

	rangeRes2 := rangeRec2.Result()
	if rangeRes2.StatusCode != http.StatusPartialContent {
		t.Fatalf("expected 206 Partial Content, got %d", rangeRes2.StatusCode)
	}
	rangeBody2, _ := io.ReadAll(rangeRes2.Body)
	if len(rangeBody2) != 1024 {
		t.Fatalf("expected 1024 bytes, got %d", len(rangeBody2))
	}
	if !bytes.Equal(rangeBody2, fullBody[1024:2048]) {
		t.Fatalf("range content mismatch for middle block")
	}
}

func TestGenericBootISOAndOverlayEndpoints(t *testing.T) {
	server := NewServer(Config{ProxyBase: "http://proxy.example/boot"}, "", "", 30*time.Minute, 0)

	// Without an iPXE EFI binary the ISO endpoints cannot compose images.
	noEFI := httptest.NewRecorder()
	server.ServeHTTP(noEFI, httptest.NewRequest(http.MethodGet, "/generic-boot.iso", nil))
	if noEFI.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 without iPXE EFI binary, got %d", noEFI.Code)
	}
	server.ipxeEFI = testIPXEEFI()

	// GET /generic-boot.iso
	req := httptest.NewRequest(http.MethodGet, "/generic-boot.iso", nil)
	rec := httptest.NewRecorder()
	server.ServeHTTP(rec, req)

	res := rec.Result()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK for /generic-boot.iso, got %d", res.StatusCode)
	}
	body, _ := io.ReadAll(res.Body)
	want, err := BuildGenericISO(server.ipxeEFI, "http://proxy.example/boot")
	if err != nil {
		t.Fatalf("BuildGenericISO: %v", err)
	}
	if !bytes.Equal(body, want) {
		t.Errorf("generic ISO differs from the composed image (got %d bytes, want %d)", len(body), len(want))
	}
	if !bytes.Contains(body, []byte("chain --autofree http://proxy.example/boot/ipxe.cfg-")) {
		t.Errorf("generic ISO script does not point at the proxy base")
	}

	// GET /genesis-overlay.cpio.gz
	req2 := httptest.NewRequest(http.MethodGet, "/genesis-overlay.cpio.gz", nil)
	rec2 := httptest.NewRecorder()
	server.ServeHTTP(rec2, req2)

	res2 := rec2.Result()
	if res2.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK for /genesis-overlay.cpio.gz, got %d", res2.StatusCode)
	}
	body2, _ := io.ReadAll(res2.Body)
	if len(body2) != len(overlayCPIO) {
		t.Errorf("expected size %d, got %d", len(overlayCPIO), len(body2))
	}
}

func TestKernelNetAndIPXEInjection(t *testing.T) {
	node := Node{
		Hostname:    "node-a",
		IP:          "198.51.100.87",
		Netmask:     "255.255.255.192",
		GW:          "198.51.100.121",
		VLAN:        "120",
		DNS:         "203.0.113.5",
		DNS2:        "203.0.113.6",
		BondMembers: []string{"0000:3b:00.0", "0000:af:00.1"},
		BondName:    "bond0",
		BondMode:    "802.3ad",
		LACPRate:    "fast",
		HashPolicy:  "layer3+4",
	}

	netStr := buildKernelNet(node)
	expectedNet := "ip=198.51.100.87::198.51.100.121:255.255.255.192:node-a:bond0.120:none:203.0.113.5:203.0.113.6 gen_bond=bond0 gen_members=0000:3b:00.0,0000:af:00.1 gen_mode=802.3ad gen_rate=fast gen_hash=layer3+4 gen_vlan=120 network-config=disabled"
	if netStr != expectedNet {
		t.Errorf("buildKernelNet mismatch:\nExpected: %s\nGot:      %s", expectedNet, netStr)
	}

	// Test non-bonded node kernel net
	nonBondedNode := Node{
		Hostname: "node-b",
		IP:       "198.51.100.98",
		Netmask:  "255.255.255.192",
		GW:       "198.51.100.121",
		Dev:      "eno1",
		VLAN:     "120",
		DNS:      "203.0.113.5",
	}
	expectedNonBondedNet := "ip=198.51.100.98::198.51.100.121:255.255.255.192:node-b:eno1.120:none:203.0.113.5 vlan=eno1.120:eno1 network-config=disabled"
	if got := buildKernelNet(nonBondedNode); got != expectedNonBondedNet {
		t.Errorf("buildKernelNet non-bonded mismatch:\nExpected: %s\nGot:      %s", expectedNonBondedNet, got)
	}

	// Test upstream proxying with cmdline injection
	upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ipxeTemplate := `#!ipxe
kernel http://192.0.2.57:5248/images/ubuntu/boot-kernel
imgargs boot-kernel ip=dhcp:BOOTIF ro
initrd http://192.0.2.57:5248/images/ubuntu/boot-initrd
boot
`
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(ipxeTemplate))
	}))
	defer upstreamServer.Close()

	proxyServer := NewServer(Config{
		RackUpstream: upstreamServer.URL,
		ProxyBase:    "http://maas.example.com/boot",
	}, "", "", 30*time.Minute, 0)

	mac := "aa:bb:cc:dd:ee:01"
	proxyServer.nodes.Put(mac, node)

	req := httptest.NewRequest(http.MethodGet, "/ipxe.cfg-"+mac, nil)
	rec := httptest.NewRecorder()
	proxyServer.ServeHTTP(rec, req)

	res := rec.Result()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", res.StatusCode)
	}
	body, _ := io.ReadAll(res.Body)
	bodyStr := string(body)

	if strings.Contains(bodyStr, ":5248") {
		t.Errorf("upstream :5248 not rewritten in output:\n%s", bodyStr)
	}
	if !strings.Contains(bodyStr, expectedNet) {
		t.Errorf("expected static net in cmdline, got:\n%s", bodyStr)
	}
	if !strings.Contains(bodyStr, "initrd http://maas.example.com/boot/genesis-overlay.cpio.gz\nboot") {
		t.Errorf("expected overlay initrd before boot, got:\n%s", bodyStr)
	}
}

func TestBinaryStreaming(t *testing.T) {
	binaryData := []byte("dummy-kernel-binary-stream-data-without-modifications-http://192.0.2.57:5248")
	upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusOK)
		w.Write(binaryData)
	}))
	defer upstreamServer.Close()

	proxyServer := NewServer(Config{
		RackUpstream: upstreamServer.URL,
		ProxyBase:    "http://maas.example.com/boot",
	}, "", "", 30*time.Minute, 0)

	req := httptest.NewRequest(http.MethodGet, "/images/ubuntu/boot-kernel", nil)
	rec := httptest.NewRecorder()
	proxyServer.ServeHTTP(rec, req)

	res := rec.Result()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 OK, got %d", res.StatusCode)
	}
	body, _ := io.ReadAll(res.Body)
	if !bytes.Equal(body, binaryData) {
		t.Errorf("binary stream was altered!")
	}
}
