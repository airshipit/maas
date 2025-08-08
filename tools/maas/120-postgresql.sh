#!/bin/bash

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

#NOTE: Deploy command
: ${OSH_HELM_REPO:="../../openstack/openstack-helm"}
: ${OSH_VALUES_OVERRIDES_PATH:="../../openstack/openstack-helm/values_overrides"}
: ${OSH_EXTRA_HELM_ARGS:=""}
: ${OSH_EXTRA_HELM_ARGS_POSTGRESQL:="$(helm osh get-values-overrides -p ${OSH_VALUES_OVERRIDES_PATH} -c postgresql ${FEATURES})"}

DEP_CHECK_IMG="${DEP_CHECK_IMG:-quay.io/airshipit/kubernetes-entrypoint:latest-ubuntu_jammy}"

# Generate value overrides to deploy postgresql
cat <<EOF >/tmp/values.postgres.yaml
labels:
  server:
    node_selector_key: ucp-control-plane
    node_selector_value: enabled
  test:
    node_selectory_key: ucp-control-plane
    node_selector_value: enabled
  prometheus_postgresql_exporter:
    node_selector_key: ucp-control-plane
    node_selector_value: enabled
  job:
    node_selector_key: ucp-control-plane
    node_selector_value: enabled
images:
  tags:
    dep_check: ${DEP_CHECK_IMG}
pod:
  replicas:
    server: 1
    prometheus_postgresql_exporter: 0
storage:
  pvc:
    class_name: general
  archive_pvc:
    class_name: general
monitoring:
  prometheus:
    postgresql_exporter:
      scrape: false
volume:
  backup:
    enabled: false
    class_name: general
manifests:
  secret_admin: true
  secret_backup_restore: true
  cron_job_postgresql_backup: false
  pvc_backup: true
  monitoring:
    prometheus:
      configmap_bin: false
      configmap_etc: false
      deployment_exporter: false
      job_user_create: false
      secret_etc: false
      service_exporter: false
EOF


helm dependency build ${OSH_HELM_REPO}/postgresql

helm upgrade --install postgresql ${OSH_HELM_REPO}/postgresql \
    --namespace=ucp \
    --values=/tmp/values.postgres.yaml \
    ${OSH_EXTRA_HELM_ARGS} \
    ${OSH_EXTRA_HELM_ARGS_POSTGRESQL}

#NOTE: Wait for deploy
helm osh wait-for-pods ucp
