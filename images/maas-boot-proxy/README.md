# maas-boot-proxy

Small Go reverse proxy that sits in front of the MAAS rack controller's boot HTTP server
(`:5248`) so that bare-metal nodes can be provisioned over an out-of-band (OOB) path, including
nodes whose management uplink is an LACP port-channel member or sits on a tagged VLAN. It

- serves UEFI boot ISOs (for BMC virtual media) that start iPXE on the right uplink,
- rewrites the rack's `ipxe.cfg-<mac>` response with per-node static networking and, for bonded
  nodes, an initramfs overlay that forms the bond,
- rewrites every internal rack URL in the payloads the node fetches (iPXE scripts, preseed,
  cloud-init, curtin archives) to the proxy's public base URL, and streams kernels, initrds and
  images through unchanged.

It is a standalone, stdlib-only Go module (own `go.mod`): no Kubernetes client, no RBAC, no
dependency on any other package of this repository. Everything it knows about a machine comes
from a nodes file.

## Boot flow

1. The BMC mounts `http://<proxy>/iso/<mac>.iso` (or the universal `/generic-boot.iso`) as a
   virtual CD and boots it in UEFI mode. The ISO starts iPXE with an `autoexec.ipxe` script.
2. The script walks the NICs, picks the node's uplink (by PCI `busdevfn` of the bond members,
   otherwise by MAC), creates the VLAN interface (`vcreate`) when a VLAN is set, applies the static
   address and chains to `http://<proxy>/ipxe.cfg-<mac>`; it retries every 3 s until an uplink reaches
   the proxy. The universal script instead tries every NIC with DHCP.
3. The proxy forwards the request to the rack and rewrites the returned iPXE config: the
   `ip=...:BOOTIF` kernel argument becomes the node's static network settings, and for bonded
   nodes an extra `initrd` line for the bond overlay is added before `boot`.
4. The kernel/initrd/squashfs, the preseed and the metadata calls all go through the proxy,
   which rewrites rack URLs in text payloads so that the node never needs to reach the rack
   directly.

## Node data (hot reloaded)

Node records come from a JSON **nodes file** (`NODES_PATH`):

```json
{
  "version": 1,
  "nodes": {
    "aa:bb:cc:dd:ee:01": {
      "hostname": "node-1", "ip": "198.51.100.87", "netmask": "255.255.255.192",
      "gw": "198.51.100.121", "vlan": "120", "dns": "203.0.113.5",
      "bond_name": "bond0", "bond_mode": "802.3ad", "lacp_rate": "fast",
      "hash_policy": "layer3+4", "bond_members": ["0000:3b:00.0", "0000:af:00.1"]
    }
  }
}
```

Keys are MACs (any common notation). The schema is the `Node` type in `types.go`:

| Field | Meaning |
|---|---|
| `hostname`, `ip`, `netmask`, `gw`, `dns`, `dns2` | Static addressing for the node |
| `vlan` | Tagged VLAN id (empty = untagged) |
| `dev` | Interface name for a non-bonded node (used for `ip=` and `vlan=`) |
| `bond_members` | PCI addresses (`0000:3b:00.0`, `3b:00.0`) or interface names; non-empty makes the node *bonded* |
| `bond_name`, `bond_mode`, `lacp_rate`, `hash_policy` | Bond settings, defaulting to `bond0`, `802.3ad`, `fast`, `layer3+4` |
| `kernel_net` | Verbatim kernel argument string; overrides the generated one |

PCI addresses are preferred for bond members because, unlike interface names and MACs, they are
the same in the iPXE environment, the ephemeral initramfs and the deployed OS.

**Reload.** The nodes file and the optional `CONFIG_PATH` file are polled every
`RELOAD_INTERVAL` and compared by content hash, so Kubernetes ConfigMap updates (atomic symlink
swaps) are detected. A lookup for an unknown MAC triggers an immediate re-read, and
`NODE_MISS_WAIT` optionally keeps retrying for that long. An invalid, partial or missing file never
discards the last good data. Lookup order: nodes file, then `nodes` in the config file.

On Kubernetes, mount the ConfigMap as a directory, not with `subPath` (kubelet never updates
`subPath` mounts). Kubelet propagates edits with a delay (typically up to 60-90 s) and a ConfigMap
is limited to 1 MiB, so create machines ahead of booting them.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `LISTEN_ADDR` | `:8248` | Listen address |
| `NODES_PATH` | `/etc/maas-boot-proxy/nodes/nodes.json` | Hot-reloaded nodes file |
| `CONFIG_PATH` | `/etc/genesis/config.json` | Optional hot-reloaded settings file (JSON: `rack_upstream`, `proxy_base`, `overlay_url`, `rewrites`, `nodes`) |
| `RACK_UPSTREAM` | – | Rack boot server to proxy to, e.g. `http://192.0.2.57:5248`; overrides the config file. Without it, proxied requests return `503` |
| `PROXY_BASE` | derived from the request `Host` | Public base URL the node uses to reach the proxy, e.g. `http://maas.example.com/boot`; overrides the config file |
| `OVERLAY_URL` | `<proxy_base>/genesis-overlay.cpio.gz` | URL injected as the bond overlay `initrd`; overrides the config file |
| `RELOAD_INTERVAL` | `5s` | File polling interval |
| `NODE_MISS_WAIT` | `0s` | Retry window for an unknown MAC |
| `IPXE_EFI_PATH` | `/ipxe.efi` | iPXE UEFI binary the ISOs are composed from |

`rewrites` in the config file is a list of `{"from": "...", "to": "..."}` literal replacements applied
to text payloads in addition to the rack-URL rewrite.

## Endpoints

| Path | Behaviour |
|---|---|
| `GET /iso/<mac>.iso` | Per-node UEFI boot ISO. `404` for an unknown MAC |
| `GET /generic-boot.iso` | Universal UEFI boot ISO (node-independent discovery script) |
| `GET /genesis-overlay.cpio.gz`, `/bond-overlay.cpio.gz` | The initramfs bond overlay |
| any other path | Proxied to `RACK_UPSTREAM` |

For proxied requests: `/images/...`, `/machine-resources/...`, `maas-scripts` and non-`GET` requests
are streamed unchanged; other `GET` responses are rewritten. `ipxe.cfg*` responses additionally get
the node's kernel arguments and overlay (the node is identified by the MAC in the path, or by a
`?genesis=<mac>` query parameter, which is removed before forwarding). Upstream failures return
`502`.

Both ISO endpoints return `503` if the iPXE binary could not be loaded. ISOs are served with
`http.ServeContent`, so `Range`, `HEAD` and `If-Modified-Since` work, as BMC virtual media needs.

## Boot ISOs

ISOs are composed in memory on demand (nothing is built at image-build time or written to disk)
and cached in RAM for 30 minutes since last use, keyed by a hash of the node data, so a changed
node gets a fresh ISO. Each ISO is a UEFI-only El Torito image whose FAT12 EFI System Partition
holds the iPXE binary as `EFI/BOOT/BOOTX64.EFI` and the iPXE script as `autoexec.ipxe`, which iPXE
loads from the volume it was started from. The composer is pure Go (`isoimage.go`, `iso_builder.go`).

The ISOs are meant for BMC virtual media (a virtual CD). They have no BIOS boot path and no hybrid
MBR/GPT, so they cannot be written to a USB stick.

## Bond overlay

`genesis-overlay.cpio.gz` is a gzip'd newc cpio containing an initramfs-tools `init-premount` hook
(`initramfs-bond-overlay/scripts/init-premount/bond`) and an `ORDER` file that runs it first. The
hook forms the in-kernel 802.3ad bond from the `gen_*` kernel arguments (`gen_bond`, `gen_members`,
`gen_mode`, `gen_rate`, `gen_hash`, `gen_vlan`) before the network is configured, so a node whose
management link is a switch port-channel member is not black-holed by the switch.

The archive is generated by Go code at startup (`overlay.go`) from the hook files embedded with
`go:embed` and is kept in memory only: no `cpio` tool and no prebuilt artifact are needed. Files that
must be executable are listed in `overlayExecutable`.

## Build and test

From the repository root (builds `quay.io/airshipit/maas-boot-proxy:latest`):

```bash
make maas-boot-proxy
```

The Dockerfile builds the Go binary and downloads the stock iPXE UEFI binary from upstream's
rolling build (`IPXE_EFI_URL`, default `https://boot.ipxe.org/x86_64-efi/ipxe.efi`; not
checksum-pinned). The build fails if the binary lacks `autoexec.ipxe`, VLAN (`vcreate`), PCI
`busloc` or HTTPS support, which the generated scripts rely on; some distribution packages of
iPXE are built without them. The runtime image is `quay.io/airshipit/ubuntu:<distro>` with only
`ca-certificates` added, and runs as `nobody`.

Unit tests need no setup (they use a synthetic iPXE binary):

```bash
cd images/maas-boot-proxy
go test ./...
```

The generated ISOs have been validated structurally (independent ISO 9660 and FAT12 readers in the
tests, `bsdtar`) but not on real firmware or BMCs.
