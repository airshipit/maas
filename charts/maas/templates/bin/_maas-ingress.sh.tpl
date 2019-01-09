#!/bin/bash

{{/*
 Copyright 2018 The Openstack-Helm Authors.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.*/}}

set -ex

COMMAND="${1:-start}"

function start () {
  exec /usr/bin/dumb-init \
      /nginx-ingress-controller \
      --http-port="${HTTP_PORT}" \
      --watch-namespace="${POD_NAMESPACE}" \
      --https-port="${HTTPS_PORT}" \
      --status-port="${STATUS_PORT}" \
      --healthz-port="${HEALTHZ_PORT}" \
      --election-id=${RELEASE_NAME} \
      --default-server-port=${DEFAULT_ERROR_PORT} \
      --ingress-class=maas-ingress \
      --default-backend-service=${POD_NAMESPACE}/${ERROR_PAGE_SERVICE} \
      --configmap=${POD_NAMESPACE}/maas-ingress-config \
      --tcp-services-configmap=${POD_NAMESPACE}/maas-ingress-services-tcp \
      --udp-services-configmap=${POD_NAMESPACE}/maas-ingress-services-udp
}

function stop () {
  kill -TERM 1
}

$COMMAND
