#!/bin/sh

set -ex

# deploy cert-manager
helm upgrade --install cert-manager cert-manager \
  --repo=https://charts.jetstack.io \
  --namespace=cert-manager \
  --create-namespace \
  --set installCRDs=true

./openstack-helm-infra/tools/deployment/common/wait-for-pods.sh cert-manager

# generate ca cert
openssl req -x509 \
  -sha256 -days 356 \
  -nodes \
  -newkey rsa:2048 \
  -subj "/CN=MAAS CA" \
  -keyout /tmp/tls.key \
  -out /tmp/tls.crt

kubectl create secret generic \
  --namespace=cert-manager \
  --from-file=/tmp/tls.key \
  --from-file=/tmp/tls.crt \
  ca-clusterissuer-creds \
  --dry-run=client -o yaml | kubectl apply -f -

# deploy cluster-ca-issuer
helm dependency update ./openstack-helm-infra/ca-clusterissuer
helm upgrade --install cluster-issuer \
  --namespace=cert-manager \
  ./openstack-helm-infra/ca-clusterissuer \
  --set conf.ca.issuer.name=ca-issuer \
  --set conf.ca.secret.name=ca-clusterissuer-creds \
  --set manifests.secret_ca=false
