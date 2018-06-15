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

# MAAS must be able to ssh to libvirt hypervisors
# to control VMs

if [[ -d ~maas/keys ]]
then
  mkdir -p ~maas/.ssh
  cp ~maas/keys/* ~maas/.ssh/
  chown -R maas:maas ~maas/.ssh
  chmod 700 ~maas/.ssh
  chmod 600 ~maas/.ssh/*
fi

chsh -s /bin/bash maas

exec /sbin/init --log-target=console 3>&1
