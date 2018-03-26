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

import_tries=0

TRY_LIMIT=${TRY_LIMIT:-1}
JOB_TIMEOUT=${JOB_TIMEOUT:-900}
RETRY_TIMER=${RETRY_TIMER:-30}

function start_import {
    while [[ ${import_tries} -lt $TRY_LIMIT ]]
    do
        import_tries=$(($import_tries + 1))
        echo "Starting image import try ${import_tries}..."
        maas ${ADMIN_USERNAME} boot-resources import
        check_for_download
        if [[ $? -eq 0 ]]
        then
            echo "Image import success!"
            return 0
        fi
    done
    return 1
}

function check_for_download {

    while [[ ${JOB_TIMEOUT} -gt 0 ]]; do
        if maas ${ADMIN_USERNAME} boot-resources is-importing | grep -q 'true';
        then
            echo -e '\nBoot resources currently importing\n'
            let JOB_TIMEOUT-=${RETRY_TIMER}
            sleep ${RETRY_TIMER}
        else
            synced_imgs=$(maas ${ADMIN_USERNAME} boot-resources read | tr -d '\n' | grep -oE '{[^}]+}' | grep ubuntu | grep -c Synced)
            if [[ $synced_imgs -gt 0 ]]
            then
                echo 'Boot resources have completed importing'
                return 0
            else
                echo 'Import failed!'
                return 1
            fi
        fi
    done
    echo "Timeout waiting for import!"
    return 1
}

function configure_proxy {
  maas ${ADMIN_USERNAME} maas set-config name=enable_http_proxy value=${MAAS_PROXY_ENABLED}
  maas ${ADMIN_USERNAME} maas set-config name=use_peer_proxy value=${MAAS_PEER_PROXY_ENABLED}
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

function configure_images {
  maas ${ADMIN_USERNAME} maas set-config name=default_osystem value=${MAAS_DEFAULT_OS}
  maas ${ADMIN_USERNAME} maas set-config name=commissioning_distro_series value=${MAAS_DEFAULT_DISTRO}
  maas ${ADMIN_USERNAME} maas set-config name=default_distro_series value=${MAAS_DEFAULT_DISTRO}
  maas ${ADMIN_USERNAME} maas set-config name=default_min_hwe_kernel value=${MAAS_DEFAULT_KERNEL}
}

function configure_boot_sources {
  if [[ $USE_IMAGE_CACHE == 'true' ]]
  then
    maas ${ADMIN_USERNAME} boot-source update 1 url=http://localhost:8888/maas/images/ephemeral-v3/daily/
  fi
  maas ${ADMIN_USERNAME} maas set-config name=http_boot value=${MAAS_HTTP_BOOT}
}

KEY=$(maas-region apikey --username=${ADMIN_USERNAME})
maas login ${ADMIN_USERNAME} ${MAAS_ENDPOINT} $KEY

configure_proxy
configure_ntp
configure_dns

# make call to import images
configure_boot_sources
start_import
if [[ $? -eq 0 ]]
then
    configure_images
else
    echo "Image import FAILED!"
    exit 1
fi
