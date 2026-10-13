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
	"encoding/hex"
	"fmt"
	"log"
	"strings"
)

// ComputeNodeConfigHash computes a deterministic hash of the node networking fields and proxy base.
func ComputeNodeConfigHash(n Node, mac, proxyBase string) string {
	h := sha256.New()
	fmt.Fprintf(h, "mac=%s\n", mac)
	fmt.Fprintf(h, "ip=%s\n", n.IP)
	fmt.Fprintf(h, "netmask=%s\n", n.Netmask)
	fmt.Fprintf(h, "gw=%s\n", n.GW)
	fmt.Fprintf(h, "vlan=%s\n", n.VLAN)
	fmt.Fprintf(h, "dev=%s\n", n.Dev)
	fmt.Fprintf(h, "hostname=%s\n", n.Hostname)
	fmt.Fprintf(h, "dns=%s\n", n.DNS)
	fmt.Fprintf(h, "dns2=%s\n", n.DNS2)
	fmt.Fprintf(h, "bond_members=%s\n", strings.Join(n.BondMembers, ","))
	fmt.Fprintf(h, "bond_name=%s\n", n.BondName)
	fmt.Fprintf(h, "bond_mode=%s\n", n.BondMode)
	fmt.Fprintf(h, "lacp_rate=%s\n", n.LACPRate)
	fmt.Fprintf(h, "hash_policy=%s\n", n.HashPolicy)
	fmt.Fprintf(h, "kernel_net=%s\n", n.KernelNet)
	fmt.Fprintf(h, "proxy_base=%s\n", strings.TrimRight(proxyBase, "/"))
	return hex.EncodeToString(h.Sum(nil))[:16]
}

// formatIPXEPCI normalizes a PCI address to match iPXE's ${netX/busloc:busdevfn} format ("0000:bb:dd.f").
func formatIPXEPCI(pci string) string {
	pci = strings.TrimSpace(pci)
	var seg, bus, dev, fn uint32
	if strings.Count(pci, ":") == 2 {
		// domain:bus:dev.fn (e.g. 0000:3b:00.0)
		n, _ := fmt.Sscanf(pci, "%x:%x:%x.%x", &seg, &bus, &dev, &fn)
		if n == 4 {
			return fmt.Sprintf("%04x:%02x:%02x.%x", seg, bus, dev, fn)
		}
	} else if strings.Count(pci, ":") == 1 && strings.Contains(pci, ".") {
		// bus:dev.fn (e.g. 5e:00.1)
		n, _ := fmt.Sscanf(pci, "%x:%x.%x", &bus, &dev, &fn)
		if n == 3 {
			return fmt.Sprintf("%04x:%02x:%02x.%x", 0, bus, dev, fn)
		}
	}
	return strings.ToLower(pci)
}

// RenderNodeIPXEScript generates an iPXE chainload script for the given node and MAC.
func RenderNodeIPXEScript(n Node, mac, proxyBase string) string {
	base := strings.TrimRight(proxyBase, "/")
	var b strings.Builder

	b.WriteString("#!ipxe\n")
	fmt.Fprintf(&b, "# Dynamic boot script for %s (%s)\n", n.Hostname, mac)

	effIface := "net${nic}"
	if n.VLAN != "" {
		fmt.Fprintf(&b, "set vlan %s\n", n.VLAN)
		effIface = "net${nic}-${vlan}"
	}
	// If PCI members are specified, match exclusively by PCI address.
	// Otherwise, fallback to matching by target MAC.
	hasPCIs := false
	for i, member := range n.BondMembers {
		if isPCIAddr(member) {
			hasPCIs = true
			fmt.Fprintf(&b, "set pci%d %s\n", i, formatIPXEPCI(member))
		}
	}
	if !hasPCIs && mac != "" {
		fmt.Fprintf(&b, "set target_mac %s\n", strings.ToLower(mac))
	}

	b.WriteString(":top\n")
	b.WriteString("set nic:int32 0\n")
	b.WriteString(":loop\n")
	b.WriteString("isset ${net${nic}/mac} || goto endpass\n")
	b.WriteString("echo Checking net${nic} (${net${nic}/mac} ${net${nic}/busloc:busdevfn})...\n")

	if hasPCIs {
		for i, member := range n.BondMembers {
			if isPCIAddr(member) {
				fmt.Fprintf(&b, "iseq ${net${nic}/busloc:busdevfn} ${pci%d} && goto hit ||\n", i)
			}
		}
		b.WriteString("goto next\n")
		b.WriteString(":hit\n")
	} else if mac != "" {
		b.WriteString("iseq ${net${nic}/mac} ${target_mac} && goto hit ||\n")
		b.WriteString("goto next\n")
		b.WriteString(":hit\n")
	}

	b.WriteString("echo Configuring net${nic} (${net${nic}/mac})...\n")
	b.WriteString("ifclose net${nic} ||\n")
	b.WriteString("ifopen net${nic} ||\n")
	if n.VLAN != "" {
		b.WriteString("vcreate --tag ${vlan} net${nic} ||\n")
	}

	if n.IP != "" {
		fmt.Fprintf(&b, "set %s/ip %s\n", effIface, n.IP)
	}
	if n.Netmask != "" {
		fmt.Fprintf(&b, "set %s/netmask %s\n", effIface, n.Netmask)
	}
	if n.GW != "" {
		fmt.Fprintf(&b, "set %s/gateway %s\n", effIface, n.GW)
	}
	if n.DNS != "" {
		fmt.Fprintf(&b, "set %s/dns %s\n", effIface, n.DNS)
	}
	fmt.Fprintf(&b, "ifopen %s ||\n", effIface)

	// Chainload to proxy per-MAC URL using the discovered interface's MAC
	chainURL := fmt.Sprintf("%s/ipxe.cfg-${net${nic}/mac}", base)
	fmt.Fprintf(&b, "chain --autofree %s && goto os_done ||\n", chainURL)

	if n.VLAN != "" {
		fmt.Fprintf(&b, "ifclose %s ||\n", effIface)
		fmt.Fprintf(&b, "vdestroy %s ||\n", effIface)
	}
	b.WriteString("ifclose net${nic} ||\n")

	if hasPCIs || mac != "" {
		b.WriteString(":next\n")
	}
	b.WriteString("inc nic && goto loop\n")
	b.WriteString(":endpass\n")
	b.WriteString("echo no matching uplink reached proxy; retry in 3s\n")
	b.WriteString("sleep 3\n")
	b.WriteString("goto top\n")
	b.WriteString(":os_done\n")
	b.WriteString("exit 0\n")

	script := b.String()
	log.Printf("rendered iPXE script for node %s (%s):\n%s", n.Hostname, mac, script)
	return script
}

// BuildNodeISO composes, in memory, the UEFI boot ISO for a node: the iPXE EFI
// binary plus the node-specific iPXE script.
func BuildNodeISO(ipxeEFI []byte, n Node, mac, proxyBase string) ([]byte, error) {
	return buildBootISO(ipxeEFI, []byte(RenderNodeIPXEScript(n, mac, proxyBase)))
}

// RenderGenericIPXEScript generates the node-independent discovery script: it
// tries every uplink in turn until one reaches the proxy.
func RenderGenericIPXEScript(proxyBase string) string {
	base := strings.TrimRight(proxyBase, "/")
	var b strings.Builder
	b.WriteString("#!ipxe\n")
	b.WriteString("# Generic discovery & boot script\n")
	b.WriteString(":top\n")
	b.WriteString("set nic:int32 0\n")
	b.WriteString(":loop\n")
	b.WriteString("isset ${net${nic}/mac} || goto endpass\n")
	b.WriteString("ifclose net${nic} ||\n")
	b.WriteString("ifopen net${nic} ||\n")
	b.WriteString("dhcp net${nic} || goto next\n")
	fmt.Fprintf(&b, "chain --autofree %s/ipxe.cfg-${net${nic}/mac} && exit 0 ||\n", base)
	b.WriteString(":next\n")
	b.WriteString("ifclose net${nic} ||\n")
	b.WriteString("inc nic && goto loop\n")
	b.WriteString(":endpass\n")
	b.WriteString("echo no uplink reached proxy; retrying in 3s\n")
	b.WriteString("sleep 3\n")
	b.WriteString("goto top\n")
	return b.String()
}

// BuildGenericISO composes the universal boot ISO for the given proxy base.
func BuildGenericISO(ipxeEFI []byte, proxyBase string) ([]byte, error) {
	return buildBootISO(ipxeEFI, []byte(RenderGenericIPXEScript(proxyBase)))
}

// GenericConfigHash identifies the generic ISO content for the given proxy base.
func GenericConfigHash(proxyBase string) string {
	h := sha256.Sum256([]byte("generic\nproxy_base=" + strings.TrimRight(proxyBase, "/")))
	return hex.EncodeToString(h[:])[:16]
}
