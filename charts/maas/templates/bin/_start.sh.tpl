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

# show env
env > /tmp/env

# Ensure PVC volumes have correct ownership
# Also restore the subdirectory structure and any default files
# that are not overridden

chown maas:maas ~maas/
chown maas:maas /etc/maas
[[ -r /opt/maas/var-lib-maas.tgz ]] && tar -C/ -xvzf /opt/maas/var-lib-maas.tgz || true
[[ -d ~maas/boot-resources ]] && chown -R maas:maas ~maas/boot-resources

# MAAS must be able to ssh to libvirt hypervisors
# to control VMs

if [[ -r ~maas/id_rsa ]]
then
  mkdir -p ~maas/.ssh
  cp ~maas/id_rsa ~maas/.ssh/
  chown -R maas:maas ~maas/.ssh/
  chmod 700 ~maas/.ssh
  chmod 600 ~maas/.ssh/*
fi

set +e
sh_set=false
for (( c=0; c<=10; c++ )); do
  if chsh -s /bin/bash maas; then
    sh_set=true
    break
  elif usermod -s /bin/bash maas; then
    sh_set=true
    break
  else
    sleep 2
  fi
done
if [[ $sh_set = false ]]; then
  exit 1
fi
set -e
exec /sbin/init --log-target=console 3>&1
