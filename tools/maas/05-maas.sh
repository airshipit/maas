#!/bin/sh

set -ex

# maas
cat <<EOF >/tmp/maas.yaml
conf:
  cache:
    enabled: true
  cloudconfig:
    override: true
    sections:
      bootcmd:
      - rm -fr /var/lib/apt/lists
      - sysctl net.ipv6.conf.all.disable_ipv6=1
      - sysctl net.ipv6.conf.default.disable_ipv6=1
      - sysctl net.ipv6.conf.lo.disable_ipv6=0
  maas:
    url:
      maas_url: http://maas-region.ucp.svc.cluster.local/MAAS
    credentials:
      secret:
        namespace: ucp
    dns:
      require_dnssec: "no"
      dns_servers:
        - 10.96.0.10
        - 8.8.8.8
        - 8.8.4.4
    extra_settings:
      active_discovery_interval: 0
      enlist_commissioning: false
      force_v1_network_yaml: true
      network_discovery: disabled
    images:
      default_os: ubuntu
      default_image: focal
      default_kernel: ga-20.04
    ntp:
      disable_ntpd_rack: true
      disable_ntpd_region: true
      use_external_only: "true"
      ntp_servers:
        - 209.115.181.110
        - 216.197.228.230
        - 207.210.46.249
        - 216.232.132.95
    proxy:
      peer_proxy_enabled: false
      proxy_enabled: false
    system_passwd: null
    system_user: null
  syslog:
    log_level: DEBUG
  maas_region:
    host_fqdn_override:
      default: null
      public:
        host: maas.ucp.svc.cluster.local
    hosts:
      default: maas-region
    name: maas-region
    path:
      default: /MAAS
    port:
      region_api:
        default: 80
        nodeport: 31900
        podport: 5240
        public: 80
      region_proxy:
        default: 8000
    scheme:
      default: http
  maas_syslog:
    host_fqdn_override:
      public:
        host: maas.ucp.svc.cluster.local
manifests:
  configmap_ingress: false
  maas_ingress: false
network:
  proxy:
    node_port:
      enabled: false
pod:
  replicas:
    rack: 1
    region: 1
    syslog: 1
endpoints:
  maas_ingress:
    hosts:
      default: ingress
      error_pages: ingress-error-pages
      monitor: ingress-exporter
EOF

# deploy maas
helm upgrade --install maas \
  --namespace=ucp \
  --values /tmp/maas.yaml \
  ./charts/maas

./openstack-helm-infra/tools/deployment/common/wait-for-pods.sh ucp
