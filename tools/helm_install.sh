#!/bin/bash
# Copyright 2018 AT&T Intellectual Property.  All other rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -x

HELM=$1
HELM_ARTIFACT_URL=${HELM_ARTIFACT_URL:-"https://get.helm.sh/helm-v3.9.4-linux-amd64.tar.gz"}


function install_helm_binary {
  if [[ -z "${HELM}" ]]
  then
    echo "No Helm binary target location."
    exit -1
  fi

  if [[ -w "$(dirname ${HELM})" ]]
  then
    TMP_DIR=$(dirname ${HELM})
    curl -o "${TMP_DIR}/helm.tar.gz" "${HELM_ARTIFACT_URL}"
    cd ${TMP_DIR}
    tar -xvzf helm.tar.gz
    cp "${TMP_DIR}/linux-amd64/helm" "${HELM}"
  else
    echo "Cannot write to ${HELM}"
    exit -1
  fi
}

install_helm_binary
