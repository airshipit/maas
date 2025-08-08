#!/bin/bash
#
# Copyright 2017 The Openstack-Helm Authors.
# Copyright 2018 AT&T Intellectual Property.  All other rights reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -xe

DEFAULT_IMAGE="${DEFAULT_IMAGE:-jammy}"
DEFAULT_KERNEL="${DEFAULT_KERNEL:-ga-22.04}"
DEFAULT_OS="${DEFAULT_OS:-ubuntu}"

DEP_CHECK_IMG="${DEP_CHECK_IMG:-quay.io/airshipit/kubernetes-entrypoint:latest-ubuntu_jammy}"
REGION_CTL_IMG="${REGION_CTL_IMG:-localhost:5000/airshipit/maas-region-controller-jammy:latest}"
RACK_CTL_IMG="${RACK_CTL_IMG:-localhost:5000/airshipit/maas-rack-controller-jammy:latest}"
CACHE_IMG="${CACHE_IMG:-localhost:5000/airshipit/sstream-cache-jammy:latest}"

# Generate value overrides to deploy maas
cat <<eof >/tmp/values.maas.yaml
labels:
  rack:
    node_selector_key: ucp-control-plane
    node_selector_value: enabled
  region:
    node_selector_key: ucp-control-plane
    node_selector_value: enabled
  ingress:
    node_selector_key: ucp-control-plane
    node_selector_value: enabled
  syslog:
    node_selector_key: ucp-control-plane
    node_selector_value: enabled
  test:
    node_selector_key: ucp-control-plane
    node_selector_value: enabled
images:
  tags:
    db_sync: ${REGION_CTL_IMG}
    maas_rack: ${RACK_CTL_IMG}
    maas_region: ${REGION_CTL_IMG}
    bootstrap: ${REGION_CTL_IMG}
    export_api_key: ${REGION_CTL_IMG}
    maas_cache: ${CACHE_IMG}
    dep_check: ${DEP_CHECK_IMG}
    maas_syslog: ${REGION_CTL_IMG}
    enable_tls: ${REGION_CTL_IMG}
network:
  region_api:
    ingress:
      classes:
        namespace: nginx
        cluster: nginx
      annotations:
        nginx.ingress.kubernetes.io/rewrite-target: /
        nginx.ingress.kubernetes.io/backend-protocol:  HTTPS
    node_port:
      enabled: true
  region_proxy:
    node_port:
      enabled: false
pod:
  replicas:
    rack: 1
    region: 1
    syslog: 1
storage:
  syslog:
    pvc:
      class_name: general
  rackd:
    pvc:
      class_name: general
manifests:
  ingress_region: false
  configmap_ingress: false
  maas_ingress: false
dependencies:
  static:
    rack_controller:
      services:
        - service: maas_region
          endpoint: internal
      jobs:
        - maas-export-api-key
    region_controller:
      jobs:
        - maas-db-sync
      services:
        - service: maas_db
          endpoint: internal
    db_init:
      services:
        - service: maas_db
          endpoint: internal
    db_sync:
      jobs:
        - maas-db-init
    bootstrap_admin_user:
      jobs:
        - maas-db-sync
      services:
        - service: maas_region
          endpoint: internal
        - service: maas_db
          endpoint: internal
    import_resources:
      jobs:
        - maas-bootstrap-admin-user
      services:
        - service: maas_region
          endpoint: internal
        - service: maas_db
          endpoint: internal
    export_api_key:
      jobs:
        - maas-bootstrap-admin-user
      services:
        - service: maas_region
          endpoint: internal
        - service: maas_db
          endpoint: internal
endpoints:
  maas_region:
    host_fqdn_override:
      default: null
      public:
        host: maas-region.ucp.svc.cluster.local
    hosts:
      default: maas-region
    name: maas-region
    path:
      default: /MAAS
    port:
      region_api:
        nodeport: 31900
        nodeporttls: 31901
        public: 443
        internal: 80
    scheme:
      default: https
  maas_syslog:
    host_fqdn_override:
      public:
        host: maas-syslog.ucp.svc.cluster.local
conf:
  # ssh:
  #   private_key: null
  # curtin:
  #   override: false
  #   late_commands:
  #     install_modules_extra: ["curtin", "in-target", "--", "apt-get", "-y", "install", "linux-generic"]
  # cloudconfig:
  #   override: false
  #   sections:
  #     bootcmd:
  #       - rm -fr /var/lib/apt/lists
  #       - sysctl net.ipv6.conf.all.disable_ipv6=1
  #       - sysctl net.ipv6.conf.default.disable_ipv6=1
  #       - sysctl net.ipv6.conf.lo.disable_ipv6=0
  # drydock:
  #   bootaction_url: null
  cache:
    enabled: true
  syslog:
    log_level: DEBUG
  maas:
    cgroups:
      disable_cgroups_region: false
      disable_cgroups_rack: false
    ntp:
      use_external_only: true
      ntp_servers:
        - 138.197.135.239
        - 162.159.200.123
        - 206.108.0.133
        - 217.180.209.214
    dns:
      require_dnssec: "no"
      dns_servers:
        - 8.8.4.4
        - 8.8.8.8
    proxy:
      peer_proxy_enabled: false
      proxy_enabled: false
    images:
      default_os: ${DEFAULT_OS}
      default_image: ${DEFAULT_IMAGE}
      default_kernel: ${DEFAULT_KERNEL}
    credentials:
      secret:
        namespace: ucp
    extra_settings:
      network_discovery: disabled
      active_discovery_interval: 0
      enlist_commissioning: false
      force_v1_network_yaml: true
    system_passwd: null
    system_user: null
    tls:
      enabled: true
      create: true
      insecure: "'true'"
cert_manager:
  enabled: true
  issuer:
    kind: ClusterIssuer
    name: ca-issuer
eof

# Deploy maas
cp -r ../../openstack/openstack-helm/helm-toolkit ./charts/deps/helm-toolkit
helm dependency update ./charts/maas
helm upgrade --install maas ./charts/maas \
  --namespace=ucp \
  --values=/tmp/values.maas.yaml

# Wait for all pods to be running
helm osh wait-for-pods ucp

# Run tests
helm test maas --namespace=ucp
