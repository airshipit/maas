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

function check_for_download {

    while [[ ${JOB_TIMEOUT} -gt 0 ]]; do
        if maas ${ADMIN_USERNAME} boot-resources is-importing | grep -q 'true';
        then
            echo -e '\nBoot resources currently importing\n'
            let TIMEOUT-=${RETRY_TIMER}
            sleep ${RETRY_TIMER}
        else
            echo 'Boot resources have completed importing'
            # TODO(sthussey) Need to check synced images exist - could be a import failure
            exit 0
        fi
    done
    exit 1

}

function configure_proxy {
  maas ${ADMIN_USERNAME} maas set-config name=enable_http_proxy value=${MAAS_PROXY_ENABLED}
  maas ${ADMIN_USERNAME} maas set-config name=http_proxy value=${MAAS_PROXY_SERVER}
}

function configure_ntp {
  maas ${ADMIN_USERNAME} maas set-config name=ntp_servers value=${MAAS_NTP_SERVERS}
  maas ${ADMIN_USERNAME} maas set-config name=ntp_external_only value=${MAAS_NTP_EXTERNAL_ONLY}
}

function configure_dns {
  maas ${ADMIN_USERNAME} maas set-config name=dnssec_validation value=${MAAS_DNS_DNSSEC_REQUIRED}
  maas ${ADMIN_USERNAME} maas set-config name=upstream_dns value=${MAAS_DNS_SERVERS}
}

function configure_boot_sources {
  if [[ $USE_IMAGE_CACHE == 'true' ]]
  then
    maas ${ADMIN_USERNAME} boot-source update 1 url=http://localhost:8888/maas/images/ephemeral-v3/daily/
  fi
}

KEY=$(maas-region apikey --username=${ADMIN_USERNAME})
maas login ${ADMIN_USERNAME} ${MAAS_ENDPOINT} $KEY

configure_proxy
configure_ntp
configure_dns

# make call to import images
configure_boot_sources
maas ${ADMIN_USERNAME} boot-resources import
# see if we can find > 0 images
sleep ${RETRY_TIMER}
check_for_download
