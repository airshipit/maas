#!/bin/sh

set -ex

# create cluster
sed -i 's/timeout=240s/timeout=900s/g' ./openstack-helm-infra/tools/deployment/common/005-deploy-k8s.sh
sed -i 's/make all/#make all/g' ./openstack-helm-infra/tools/deployment/common/005-deploy-k8s.sh

./openstack-helm-infra/tools/deployment/common/005-deploy-k8s.sh
sleep 5

# add node labels
kubectl label node --all openstack-control-plane=enabled --overwrite
kubectl label node --all ucp-control-plane=enabled --overwrite

# create maas namespace
kubectl create namespace ucp --dry-run=client -o yaml | kubectl apply -f -

# configure storageclass
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: general
  labels:
    addonmanager.kubernetes.io/mode: EnsureExists
provisioner: k8s.io/minikube-hostpath
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF

# deploy ingress
cat <<EOF >/tmp/ingress.yaml
controller:
  admissionWebhooks:
    enabled: false
  config:
    enable-underscores-in-headers: "true"
    ssl-reject-handshake: "true"
  ingressClass: maas-ingress
  ingressClassByName: true
  ingressClassResource:
    controllerValue: k8s.io/maas-ingress
    enabled: true
    name: maas-ingress
  kind: DaemonSet
  nodeSelector:
    ucp-control-plane: enabled
defaultBackend:
  enabled: true
  nodeSelector:
    ucp-control-plane: enabled
fullnameOverride: maas-ingress
udp:
  "53": ucp/maas-region:region-dns
  "514": ucp/maas-syslog:syslog
EOF

helm dependency update ./openstack-helm-infra/ingress
helm upgrade --install ingress-ucp ./openstack-helm-infra/ingress \
  --namespace=ucp \
  --values /tmp/ingress.yaml \
  ${OSH_INFRA_EXTRA_HELM_ARGS} \
  ${OSH_INFRA_EXTRA_HELM_ARGS_INGRESS_OPENSTACK}

./openstack-helm-infra/tools/deployment/common/wait-for-pods.sh ucp
