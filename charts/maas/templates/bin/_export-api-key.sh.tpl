#!/bin/bash

# Copyright 2017 The Openstack-Helm Authors.
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

set -ex

function clear_secret {
    wget \
        --server-response \
        --ca-certificate=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
        --header='Content-Type: application/json' \
        --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        --method=DELETE \
        https://kubernetes.default.svc.cluster.local/api/v1/namespaces/${SECRET_NAMESPACE}/secrets/${SECRET_NAME}
}

function post_secret {
    wget \
        --server-response \
        --ca-certificate=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
        --header='Content-Type: application/json' \
        --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        --method=POST \
        --body-file=/tmp/secret.json \
        https://kubernetes.default.svc.cluster.local/api/v1/namespaces/${SECRET_NAMESPACE}/secrets \
        2>&1
}

KEY=$(maas-region apikey --username=${ADMIN_USERNAME})

if [ "x$KEY" != "x" ]; then
    ENCODED_KEY=$(echo -n $KEY | base64 -w 0)
    cat <<EOS > /tmp/secret.json
{
  "apiVersion": "v1",
  "kind": "Secret",
  "type": "Opaque",
  "metadata": {
    "name": "${SECRET_NAME}"
  },
  "data": {
    "token": "$ENCODED_KEY"
  }
}
EOS
    while true; do
        export result=$(post_secret)
        if [ ! -z "$(echo "$result" | grep -i '201 Created')" ]; then
            echo 'Secret created'
            break
        elif [ ! -z "$(echo "$result" | grep -i '409 Conflict')" ]; then
            echo 'Secret exists, clearing before trying again'
            clear_secret
        else
          echo 'Secret creation failed'
          echo $result
        fi
        sleep 15
    done
else
    echo "Failed to get key from maas."
    exit 1
fi
