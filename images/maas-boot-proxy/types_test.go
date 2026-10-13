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
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestNodeBonded(t *testing.T) {
	if (Node{}).bonded() {
		t.Error("node without members must not be bonded")
	}
	if !(Node{BondMembers: []string{"0000:3b:00.0"}}).bonded() {
		t.Error("node with members must be bonded")
	}
}

func TestNodeJSONOmitsOptionalFields(t *testing.T) {
	b, err := json.Marshal(Node{IP: "198.51.100.87", Hostname: "node-a"})
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"dns", "dns2", "bond_members", "bond_name", "bond_mode", "lacp_rate", "hash_policy", "kernel_net"} {
		if strings.Contains(string(b), `"`+key+`"`) {
			t.Errorf("optional field %q should be omitted: %s", key, b)
		}
	}
}

func TestConfigJSONRoundTrip(t *testing.T) {
	in := `{
	  "rack_upstream": "http://192.0.2.57:5248",
	  "proxy_base": "http://maas.example.com/boot",
	  "overlay_url": "http://maas.example.com/boot/genesis-overlay.cpio.gz",
	  "rewrites": [{"from": "a", "to": "b"}],
	  "nodes": {"aa:bb:cc:dd:ee:01": {"hostname": "node-a", "ip": "198.51.100.87", "bond_members": ["0000:3b:00.0"], "lacp_rate": "fast"}}
	}`
	var c Config
	if err := json.Unmarshal([]byte(in), &c); err != nil {
		t.Fatal(err)
	}
	if c.RackUpstream != "http://192.0.2.57:5248" || c.ProxyBase != "http://maas.example.com/boot" || len(c.Rewrites) != 1 {
		t.Fatalf("unexpected config: %+v", c)
	}
	n := c.Nodes["aa:bb:cc:dd:ee:01"]
	if n.Hostname != "node-a" || !n.bonded() || n.LACPRate != "fast" {
		t.Fatalf("unexpected node: %+v", n)
	}
	out, err := json.Marshal(c)
	if err != nil {
		t.Fatal(err)
	}
	var again Config
	if err := json.Unmarshal(out, &again); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(c, again) {
		t.Errorf("config changed over a JSON round trip:\n%+v\n%+v", c, again)
	}
}
