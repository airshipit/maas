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
# Fix AppArmor preventing rsyslogd from reading /var/lib/maas/rsyslog.conf.
# On Noble the profile was renamed from usr.sbin.rsyslogd to rsyslogd, so
# maas-common.postinst (which only checks the old path) never reloads it.
# Reload the profile from the container filesystem (which has the MAAS rules
# in rsyslog.d/maas) into the shared AppArmor securityfs before systemd starts.
# --skip-read-cache forces recompile from source, bypassing a cached binary
# profile that may predate the MAAS rules installation.
if [ -d /sys/kernel/security/apparmor ] && command -v apparmor_parser >/dev/null 2>&1; then
  for _p in /etc/apparmor.d/rsyslogd /etc/apparmor.d/usr.sbin.rsyslogd; do
    [ -f "$_p" ] && { apparmor_parser --replace --skip-read-cache --write-cache "$_p" || true; break; }
  done
  unset _p
fi

# Enable the maas-rackd watchdog unit when it is mounted into the container.
if [[ -f /etc/systemd/system/maas-rackd-watchdog.service ]]; then
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /etc/systemd/system/maas-rackd-watchdog.service \
    /etc/systemd/system/multi-user.target.wants/maas-rackd-watchdog.service
fi

exec /sbin/init --log-target=console 3>&1
