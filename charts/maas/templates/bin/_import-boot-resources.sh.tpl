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

set -x

import_tries=0

TRY_LIMIT=${TRY_LIMIT:-1}
JOB_TIMEOUT=${JOB_TIMEOUT:-900}
RETRY_TIMER=${RETRY_TIMER:-30}

function start_import {
    check_for_download

    if [[ $? -eq 0 ]]
    then
      echo "Already have images, skipping import."
      return 0
    fi

    while [[ ${import_tries} -lt $TRY_LIMIT ]]
    do
        import_tries=$(($import_tries + 1))
        echo "Starting image import try ${import_tries}..."
        maas ${ADMIN_USERNAME} boot-resources import
        sleep 30  # Seems MAAS needs time to sync up
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
            synced_imgs=$(maas ${ADMIN_USERNAME} boot-resources read | tail -n +1 | jq ".[] | select( .type | contains(\"Synced\")) | .name " | grep -c $MAAS_DEFAULT_DISTRO)
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

function check_then_set {
  option=$1
  value=$2

  cur_val=$(maas ${ADMIN_USERNAME} maas get-config name=${option} | tail -1 | tr -d '"')
  desired_val=$(echo ${value} | tr -d '"')

  if [[ $cur_val != $desired_val ]]
  then
    echo "Setting MAAS option ${option} to ${desired_val}"
    maas ${ADMIN_USERNAME} maas set-config name=${option} value=${desired_val}
    return $?
  else
    echo "MAAS option ${option} already set to ${cur_val}"
    return 0
  fi
}

function check_for_rack_sync {
  rack_list=$(maas ${ADMIN_USERNAME} rack-controllers read | tail -n +1 | jq -r '.[] | .system_id')
  sync_list=""

  while [[ ${JOB_TIMEOUT} -gt 0 ]]
  do
      for rack_id in ${rack_list}
      do
        selected_imgs=$(maas ${ADMIN_USERNAME} rack-controller list-boot-images ${rack_id} | tail -n +1 | jq ".images[] | select( .name | contains(\"${MAAS_DEFAULT_DISTRO}\")) | .name")
        synced_ctlr=$(maas ${ADMIN_USERNAME} rack-controller list-boot-images ${rack_id} | tail -n +1 | jq '.status == "synced"')
        if [[ $synced_ctlr == "true" && ! -z ${selected_imgs} ]]
        then
          sync_list=$(echo -e "${sync_list}\n${rack_id}" | sort | uniq)
        fi
        if [[ $(echo -e "${rack_list}" | sort | uniq | grep -v '^$' ) == $(echo -e "${sync_list}" | sort | uniq | grep -v '^$') ]]
        then
          return 0
        fi
      done
      let JOB_TIMEOUT-=${RETRY_TIMER}
      sleep ${RETRY_TIMER}
  done
  return 1
}

function configure_proxy {
  check_then_set enable_http_proxy ${MAAS_PROXY_ENABLED}
  check_then_set use_peer_proxy ${MAAS_PEER_PROXY_ENABLED}
  check_then_set http_proxy ${MAAS_PROXY_SERVER}
  check_then_set maas_proxy_port ${MAAS_INTERNAL_PROXY_PORT}
}

function configure_ntp {
  check_then_set ntp_servers ${MAAS_NTP_SERVERS}
  check_then_set ntp_external_only ${MAAS_NTP_EXTERNAL_ONLY}
}

function configure_dns {
  check_then_set dnssec_validation ${MAAS_DNS_DNSSEC_REQUIRED}
  check_then_set upstream_dns ${MAAS_DNS_SERVERS}
}

function configure_images {
  check_for_rack_sync

  if [[ $? -eq 1 ]]
  then
    echo "Timed out waiting for rack controller sync."
    return 1
  fi

  check_then_set default_osystem ${MAAS_DEFAULT_OS}
  check_then_set commissioning_distro_series ${MAAS_DEFAULT_DISTRO}
  check_then_set default_distro_series ${MAAS_DEFAULT_DISTRO}
  check_then_set default_min_hwe_kernel ${MAAS_DEFAULT_KERNEL}
}

function configure_boot_sources {
  if [[ $USE_IMAGE_CACHE == 'true' ]]
  then
    maas ${ADMIN_USERNAME} boot-source update 1 url=http://localhost:8888/maas/images/ephemeral-v3/daily/
  fi

  check_then_set http_boot ${MAAS_HTTP_BOOT}

  selected_releases=$(maas ${ADMIN_USERNAME} boot-source-selections read 1 | tail -n +1 | jq -r '.[] | .release')

  if [[ -z $(echo "${selected_releases}" | grep "${MAAS_DEFAULT_DISTRO}") ]]
  then
    maas ${ADMIN_USERNAME} boot-source-selections create 1 os="${MAAS_DEFAULT_OS}" \
      release="${MAAS_DEFAULT_DISTRO}" arches="amd64" subarches='*' labels='*'
  fi
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
