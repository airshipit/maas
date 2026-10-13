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
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	defaultListenAddr = ":8248"
	overlayPath       = "/genesis-overlay.cpio.gz"
	bondOverlayPath   = "/bond-overlay.cpio.gz"
	genericISOPath    = "/generic-boot.iso"

	defaultIPXEEFIPath = "/ipxe.efi"

	defaultReloadInterval = 5 * time.Second
	missPollInterval      = 500 * time.Millisecond
)

var (
	ipxeRe  = regexp.MustCompile(`ipxe\.cfg-([0-9A-Fa-f:.-]+)$`)
	isoRe   = regexp.MustCompile(`^/iso/([0-9A-Fa-f:.-]+?)(?:\.iso)?$`)
	ipCmdRe = regexp.MustCompile(`ip=\S*BOOTIF`)
)

// Server represents the Smart Boot Proxy HTTP server.
type Server struct {
	cfg        Config
	cfgMu      sync.RWMutex
	cfgPath    string
	cfgHash    [sha256.Size]byte
	cfgLoaded  bool
	overrides  Config // env-provided values; win over the config file
	nodes      *NodeStore
	missWait   time.Duration
	isoCache   *ISOCache
	ipxeEFI    []byte // iPXE UEFI binary the boot ISOs are composed from
	httpClient *http.Client
	bootTime   time.Time
}

// NewServer creates a new instance of the Server. nodesPath is the hot-reloaded
// nodes file (may be empty).
func NewServer(cfg Config, cfgPath, nodesPath string, ttl, sweepInterval time.Duration) *Server {
	return &Server{
		cfg:        cfg,
		cfgPath:    cfgPath,
		nodes:      NewNodeStore(nodesPath),
		isoCache:   NewISOCache(ttl, sweepInterval),
		httpClient: &http.Client{Timeout: 0}, // no timeout: large image streams
		bootTime:   time.Now().Truncate(time.Second),
	}
}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func loadConfigFile(path string) (Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return Config{}, err
	}
	c.Nodes = normalizeNodeKeys(c.Nodes)
	return c, nil
}

func (s *Server) getConfig() Config {
	s.cfgMu.RLock()
	defer s.cfgMu.RUnlock()
	return s.cfg
}

// applyOverrides lets environment-provided settings win over the config file.
func applyOverrides(c *Config, o Config) {
	if o.RackUpstream != "" {
		c.RackUpstream = o.RackUpstream
	}
	if o.ProxyBase != "" {
		c.ProxyBase = o.ProxyBase
	}
	if o.OverlayURL != "" {
		c.OverlayURL = o.OverlayURL
	}
}

// reloadConfig re-reads the config file when its content changed. Errors keep
// the previous configuration.
func (s *Server) reloadConfig() {
	if s.cfgPath == "" {
		return
	}
	b, err := os.ReadFile(s.cfgPath)
	if err != nil {
		return
	}
	sum := sha256.Sum256(b)
	s.cfgMu.RLock()
	same := s.cfgLoaded && sum == s.cfgHash
	s.cfgMu.RUnlock()
	if same {
		return
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		log.Printf("ignoring invalid config file %s (keeping previous config): %v", s.cfgPath, err)
		return
	}
	c.Nodes = normalizeNodeKeys(c.Nodes)
	s.cfgMu.Lock()
	applyOverrides(&c, s.overrides)
	s.cfg = c
	s.cfgHash = sum
	s.cfgLoaded = true
	s.cfgMu.Unlock()
	log.Printf("config reloaded: %d static node(s), %d rewrite(s)", len(c.Nodes), len(c.Rewrites))
}

// Reload re-reads the config and nodes files.
func (s *Server) Reload() {
	s.reloadConfig()
	_, _ = s.nodes.Reload()
}

// Watch polls the config and nodes files until ctx is done, picking up changes
// (including ConfigMap symlink swaps) without a restart.
func (s *Server) Watch(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = defaultReloadInterval
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.Reload()
		}
	}
}

// resolveNode looks up node data by MAC: the hot-reloaded nodes file first, then
// nodes embedded in the static config. On a miss it re-reads the files right
// away and, if configured, keeps retrying for missWait.
func (s *Server) resolveNode(ctx context.Context, mac string) (Node, bool) {
	norm := normalizeKey(mac)
	if norm == "" {
		return Node{}, false
	}

	deadline := time.Now().Add(s.missWait)
	for {
		if node, ok := s.lookup(norm); ok {
			return node, true
		}
		s.Reload()
		if node, ok := s.lookup(norm); ok {
			return node, true
		}
		if !time.Now().Before(deadline) {
			break
		}
		select {
		case <-ctx.Done():
			return Node{}, false
		case <-time.After(missPollInterval):
		}
	}

	log.Printf("unable to resolve node for MAC %s (checked nodes file and static config)", norm)
	return Node{}, false
}

func (s *Server) lookup(norm string) (Node, bool) {
	if node, ok := s.nodes.Get(norm); ok {
		log.Printf("resolved node for MAC %s from nodes file (hostname=%s, IP=%s)", norm, node.Hostname, node.IP)
		return node, true
	}
	if node, ok := s.getConfig().Nodes[norm]; ok {
		log.Printf("resolved node for MAC %s from static config (hostname=%s, IP=%s)", norm, node.Hostname, node.IP)
		return node, true
	}
	return Node{}, false
}

func normalizeNodeKeys(in map[string]Node) map[string]Node {
	out := make(map[string]Node, len(in))
	for k, v := range in {
		out[normalizeKey(k)] = v
	}
	return out
}

// buildKernelNet renders the static network kernel parameters.
func buildKernelNet(n Node) string {
	if n.KernelNet != "" {
		return n.KernelNet
	}

	dnss := ""
	if n.DNS != "" && n.DNS2 != "" {
		dnss = ":" + n.DNS + ":" + n.DNS2
	} else if n.DNS != "" {
		dnss = ":" + n.DNS
	}

	if n.bonded() {
		bond := n.BondName
		if bond == "" {
			bond = "bond0"
		}
		vdev := bond
		if n.VLAN != "" {
			vdev = bond + "." + n.VLAN
		}
		mode := def(n.BondMode, "802.3ad")
		rate := def(n.LACPRate, "fast")
		hash := def(n.HashPolicy, "layer3+4")

		s := fmt.Sprintf("ip=%s::%s:%s:%s:%s:none%s", n.IP, n.GW, n.Netmask, n.Hostname, vdev, dnss)
		s += " gen_bond=" + bond
		s += " gen_members=" + strings.Join(n.BondMembers, ",")
		s += " gen_mode=" + mode
		s += " gen_rate=" + rate
		s += " gen_hash=" + hash
		if n.VLAN != "" {
			s += " gen_vlan=" + n.VLAN
		}
		s += " network-config=disabled"
		return s
	}

	dev := n.Dev
	vdev := dev
	if n.VLAN != "" {
		vdev = dev + "." + n.VLAN
	}
	s := fmt.Sprintf("ip=%s::%s:%s:%s:%s:none%s", n.IP, n.GW, n.Netmask, n.Hostname, vdev, dnss)
	if n.VLAN != "" {
		s += " vlan=" + vdev + ":" + dev
	}
	s += " network-config=disabled"
	return s
}

func def(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

func isBinary(path string) bool {
	if strings.HasPrefix(path, "/images/") || strings.HasPrefix(path, "/machine-resources/") {
		return true
	}
	if strings.Contains(path, "maas-scripts") {
		return true
	}
	return false
}

const genericISOKey = "generic"

func isoErrorStatus(ipxeEFI []byte) int {
	if len(ipxeEFI) == 0 {
		return http.StatusServiceUnavailable
	}
	return http.StatusInternalServerError
}

// cachedISO returns the cached ISO for key when its config hash matches
// wantHash, composing and caching it otherwise.
func (s *Server) cachedISO(key, wantHash string, build func() ([]byte, error)) (*CachedISO, error) {
	if c, ok := s.isoCache.Get(key); ok && c.ConfigHash == wantHash {
		return c, nil
	}
	data, err := build()
	if err != nil {
		return nil, err
	}
	log.Printf("composed ISO %s (hash=%s, size=%d bytes)", key, wantHash, len(data))
	return s.isoCache.Set(key, wantHash, data), nil
}

func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if i := strings.IndexByte(xff, ','); i > 0 {
			return strings.TrimSpace(xff[:i])
		}
		return strings.TrimSpace(xff)
	}
	return r.RemoteAddr
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	cfg := s.getConfig()

	// 1. Universal Generic Boot ISO (composed in memory)
	if r.URL.Path == genericISOPath {
		proxyBase := cfg.ProxyBase
		if proxyBase == "" {
			proxyBase = "http://" + r.Host
		}
		cached, err := s.cachedISO(genericISOKey, GenericConfigHash(proxyBase), func() ([]byte, error) {
			return BuildGenericISO(s.ipxeEFI, proxyBase)
		})
		if err != nil {
			log.Printf("failed to build generic ISO: %v", err)
			http.Error(w, "failed to build ISO", isoErrorStatus(s.ipxeEFI))
			return
		}
		log.Printf("GET %s from=%s -> serving generic boot ISO (%d bytes)", r.URL.Path, clientIP(r), len(cached.Data))
		w.Header().Set("Content-Type", "application/x-iso9660-image")
		http.ServeContent(w, r, "generic-boot.iso", cached.ModTime, bytes.NewReader(cached.Data))
		return
	}

	// 2. Embedded Bond Overlay
	if r.URL.Path == overlayPath || r.URL.Path == bondOverlayPath {
		log.Printf("GET %s from=%s -> serving embedded overlay (%d bytes)", r.URL.Path, clientIP(r), len(overlayCPIO))
		w.Header().Set("Content-Type", "application/x-gzip")
		http.ServeContent(w, r, "genesis-overlay.cpio.gz", s.bootTime, bytes.NewReader(overlayCPIO))
		return
	}

	// 3. Dynamic Node ISO endpoint: /iso/<mac>.iso
	if m := isoRe.FindStringSubmatch(r.URL.Path); m != nil {
		rawMAC := m[1]
		normMAC := normalizeMAC(rawMAC)
		if normMAC == "" {
			normMAC = strings.ToLower(rawMAC)
		}

		log.Printf("GET %s from=%s -> handling dynamic ISO request for MAC %s", r.URL.Path, clientIP(r), rawMAC)

		node, found := s.resolveNode(r.Context(), normMAC)
		if !found {
			log.Printf("dynamic ISO request failed for MAC %s from=%s: node not found", rawMAC, clientIP(r))
			http.Error(w, fmt.Sprintf("node with MAC %s not found", rawMAC), http.StatusNotFound)
			return
		}

		proxyBase := cfg.ProxyBase
		if proxyBase == "" {
			proxyBase = "http://" + r.Host
		}

		cachedISO, err := s.cachedISO(normMAC, ComputeNodeConfigHash(node, normMAC, proxyBase), func() ([]byte, error) {
			return BuildNodeISO(s.ipxeEFI, node, normMAC, proxyBase)
		})
		if err != nil {
			log.Printf("failed to build dynamic ISO for %s: %v", normMAC, err)
			http.Error(w, "failed to build ISO", isoErrorStatus(s.ipxeEFI))
			return
		}

		filename := fmt.Sprintf("ipxe-%s.iso", normMAC)
		w.Header().Set("Content-Type", "application/x-iso9660-image")
		http.ServeContent(w, r, filename, cachedISO.ModTime, bytes.NewReader(cachedISO.Data))
		return
	}

	// 4. Reverse Proxying to MAAS Rack Upstream
	if cfg.RackUpstream == "" {
		log.Printf("%s %s from=%s -> upstream rack proxy not configured", r.Method, r.URL.Path, clientIP(r))
		http.Error(w, "upstream rack proxy not configured", http.StatusServiceUnavailable)
		return
	}

	genesisMAC := ""
	upPath := r.URL.Path
	upQuery := r.URL.RawQuery
	if r.URL.RawQuery != "" {
		q := r.URL.Query()
		if g := q.Get("genesis"); g != "" {
			genesisMAC = strings.ToLower(g)
			q.Del("genesis")
			upQuery = q.Encode()
		}
	}

	upURL := strings.TrimRight(cfg.RackUpstream, "/") + upPath
	if upQuery != "" {
		upURL += "?" + upQuery
	}

	log.Printf("proxying request %s %s from=%s to upstream %s", r.Method, r.URL.Path, clientIP(r), upURL)

	upReq, err := http.NewRequestWithContext(r.Context(), r.Method, upURL, r.Body)
	if err != nil {
		http.Error(w, "bad upstream request", http.StatusInternalServerError)
		return
	}
	for k, vs := range r.Header {
		if strings.EqualFold(k, "Accept-Encoding") {
			continue
		}
		for _, v := range vs {
			upReq.Header.Add(k, v)
		}
	}
	upReq.Header.Set("Accept-Encoding", "identity")

	resp, err := s.httpClient.Do(upReq)
	if err != nil {
		log.Printf("upstream error %s: %v", upURL, err)
		http.Error(w, "upstream unreachable", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	stream := isBinary(r.URL.Path) || r.Method != http.MethodGet

	mode := "rewrite"
	if stream {
		mode = "stream"
	}
	log.Printf("%s %s from=%s -> upstream %s returned %d (%s)", r.Method, r.URL.Path, clientIP(r), upURL, resp.StatusCode, mode)

	copyHeaders := func(skipLen bool) {
		for k, vs := range resp.Header {
			if skipLen && strings.EqualFold(k, "Content-Length") {
				continue
			}
			for _, v := range vs {
				w.Header().Add(k, v)
			}
		}
	}

	if stream {
		copyHeaders(false)
		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
		return
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "read error from upstream", http.StatusBadGateway)
		return
	}

	proxyBase := cfg.ProxyBase
	if proxyBase == "" {
		proxyBase = "http://" + r.Host
	}

	rewrittenBody, err := rewriteData(body, proxyBase, cfg.Rewrites)
	if err == nil {
		body = rewrittenBody
	}

	// For iPXE configs: dynamically inject static network cmdline and bond overlay
	if strings.Contains(r.URL.Path, "ipxe.cfg") {
		mac := ""
		if m := ipxeRe.FindStringSubmatch(r.URL.Path); m != nil {
			mac = m[1]
		} else if genesisMAC != "" {
			mac = genesisMAC
		}

		if mac != "" {
			if node, ok := s.resolveNode(r.Context(), mac); ok {
				net := buildKernelNet(node)
				if ipCmdRe.Match(body) {
					body = ipCmdRe.ReplaceAll(body, []byte(net))
					log.Printf("ipxe.cfg %s: injected net (%s)", mac, net)
				}
				if node.bonded() {
					overlayURL := cfg.OverlayURL
					if overlayURL == "" {
						overlayURL = strings.TrimRight(proxyBase, "/") + overlayPath
					}
					body = injectOverlayInitrd(body, overlayURL)
					log.Printf("ipxe.cfg %s: added bond overlay initrd (%s)", mac, overlayURL)
				}
			}
		}
	}

	copyHeaders(true)
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
	w.WriteHeader(resp.StatusCode)
	w.Write(body)
}

func injectOverlayInitrd(body []byte, url string) []byte {
	if url == "" {
		return body
	}
	line := "initrd " + url + "\n"
	s := string(body)
	if i := strings.LastIndex(s, "\nboot"); i >= 0 {
		return []byte(s[:i+1] + line + s[i+1:])
	}
	return []byte(s + line)
}

func main() {
	configPath := env("CONFIG_PATH", "/etc/genesis/config.json")
	nodesPath := env("NODES_PATH", "/etc/maas-boot-proxy/nodes/nodes.json")
	listenAddr := env("LISTEN_ADDR", defaultListenAddr)

	overrides := Config{
		RackUpstream: env("RACK_UPSTREAM", ""),
		ProxyBase:    env("PROXY_BASE", ""),
		OverlayURL:   env("OVERLAY_URL", ""),
	}
	reloadInterval := envDuration("RELOAD_INTERVAL", defaultReloadInterval)
	missWait := envDuration("NODE_MISS_WAIT", 0)

	var cfg Config
	if c, err := loadConfigFile(configPath); err == nil {
		cfg = c
		log.Printf("loaded static config: %d node(s)", len(c.Nodes))
	}
	applyOverrides(&cfg, overrides)

	srv := NewServer(cfg, configPath, nodesPath, 30*time.Minute, 2*time.Minute)
	srv.overrides = overrides
	srv.missWait = missWait
	ipxePath := env("IPXE_EFI_PATH", defaultIPXEEFIPath)
	if b, err := os.ReadFile(ipxePath); err == nil {
		srv.ipxeEFI = b
		log.Printf("loaded iPXE EFI binary %s (%d bytes)", ipxePath, len(b))
	} else {
		log.Printf("WARNING: cannot read iPXE EFI binary %s: %v (ISO endpoints will return 503)", ipxePath, err)
	}
	srv.Reload()
	go srv.Watch(context.Background(), reloadInterval)

	log.Printf("maas-boot-proxy listening on %s (upstream=%s, base=%s, nodes=%s, reload=%s)", listenAddr, cfg.RackUpstream, cfg.ProxyBase, nodesPath, reloadInterval)
	log.Fatal(http.ListenAndServe(listenAddr, srv))
}

func envDuration(k string, d time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if p, err := time.ParseDuration(v); err == nil && p >= 0 {
			return p
		}
		log.Printf("ignoring invalid duration %s=%q", k, v)
	}
	return d
}
