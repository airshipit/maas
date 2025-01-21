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

: "${BASE_IMG:="public.ecr.aws/docker/library/ubuntu:jammy"}"
: "${IMG_PATH:="./images"}"
: "${MAAS_REPO:="quay.io/airshipit"}"
: "${SSTREAM_RELEASE:="jammy"}"

# Build kube-entrypoint image
grep -q "${MAAS_REPO}/kubernetes-entrypoint" <(docker image ls) >/dev/null ||
docker build \
  -t "${MAAS_REPO}/kubernetes-entrypoint:latest-ubuntu_jammy" \
  --network=host \
  -f ../kubernetes-entrypoint/images/Dockerfile.ubuntu_jammy \
  --build-arg MAKE_TARGET=build \
  ../kubernetes-entrypoint

# Build maas images
grep -q "${MAAS_REPO}/maas-region-controller" <(docker image ls) >/dev/null ||
docker build \
  -t "${MAAS_REPO}/maas-region-controller:latest" \
  --network=host \
  -f "${IMG_PATH}/maas-region-controller-jammy/Dockerfile" \
  "${IMG_PATH}/maas-region-controller-jammy"

grep -q "${MAAS_REPO}/maas-rack-controller" <(docker image ls) >/dev/null ||
docker build \
  -t "${MAAS_REPO}/maas-rack-controller:latest" \
  --network=host \
  -f "${IMG_PATH}/maas-rack-controller-jammy/Dockerfile" \
  "${IMG_PATH}/maas-rack-controller-jammy"

grep -q "${MAAS_REPO}/sstream-cache" <(docker image ls) >/dev/null ||
docker build \
  -t "${MAAS_REPO}/sstream-cache:latest" \
  --network=host \
  -f "${IMG_PATH}/sstream-cache/Dockerfile" \
  --build-arg FROM="${BASE_IMG}" \
	--build-arg SSTREAM_IMAGE=https://images.maas.io/ephemeral-v3/stable/ \
  --build-arg SSTREAM_RELEASE="${SSTREAM_RELEASE}" \
  "${IMG_PATH}/sstream-cache"

# Save images to tar files
stat -f /tmp/kubernetes-entrypoint.tar >/dev/null || docker image save "${MAAS_REPO}/kubernetes-entrypoint" -o /tmp/kubernetes-entrypoint.tar
stat -f  /tmp/maas-region-controller.tar >/dev/null || docker image save "${MAAS_REPO}/maas-region-controller:latest" -o /tmp/maas-region-controller.tar
stat -f /tmp/maas-rack-controller.tar >/dev/null || docker image save "${MAAS_REPO}/maas-rack-controller:latest" -o /tmp/maas-rack-controller.tar
stat -f /tmp/sstream-cache.tar >/dev/null || docker image save "${MAAS_REPO}/sstream-cache:latest" -o /tmp/sstream-cache.tar

# Load images to minikube
grep -q "${MAAS_REPO}/kubernetes-entrypoint:latest-ubuntu_jammy" <(sudo -E minikube image ls) >/dev/null || sudo -E minikube image load /tmp/kubernetes-entrypoint.tar
grep -q "${MAAS_REPO}/maas-region-controller:latest" <(sudo -E minikube image ls) >/dev/null || sudo -E minikube image load /tmp/maas-region-controller.tar
grep -q "${MAAS_REPO}/maas-rack-controller:latest" <(sudo -E minikube image ls) >/dev/null || sudo -E minikube image load /tmp/maas-rack-controller.tar
grep -q "${MAAS_REPO}/sstream-cache:latest" <(sudo -E minikube image ls) >/dev/null || sudo -E minikube image load /tmp/sstream-cache.tar
