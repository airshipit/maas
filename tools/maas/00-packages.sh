#!/bin/sh

set -ex

# clone osh-infra
git clone https://opendev.org/openstack/openstack-helm-infra.git

# install packages
./openstack-helm-infra/tools/deployment/common/000-install-packages.sh
./openstack-helm-infra/tools/deployment/common/001-setup-apparmor-profiles.sh
