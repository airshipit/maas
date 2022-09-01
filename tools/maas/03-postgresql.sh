#!/bin/sh

set -ex

: ${OSH_INFRA_EXTRA_HELM_ARGS:=""}
: ${OSH_INFRA_EXTRA_HELM_ARGS_POSTGRESQL:="$(./tools/deployment/common/get-values-overrides.sh postgresql)"}

# deploy postgresql
helm dependency update ./openstack-helm-infra/postgresql
helm upgrade --install postgresql ./openstack-helm-infra/postgresql \
  --namespace=ucp \
  --set monitoring.prometheus.enabled=true \
  --set storage.pvc.size=1Gi \
  --set storage.pvc.enabled=true \
  --set pod.replicas.server=1 \
  ${OSH_INFRA_EXTRA_HELM_ARGS} \
  ${OSH_INFRA_EXTRA_HELM_ARGS_POSTGRESQL}

./openstack-helm-infra/tools/deployment/common/wait-for-pods.sh ucp
