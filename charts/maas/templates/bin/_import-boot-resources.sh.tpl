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

function timer {
	retry_wait=$1
	shift

	while [[ ${JOB_TIMEOUT} -gt 0 ]]; do
		"$@"
		rc=$?
		if [ $rc -eq 0 ]; then
			return $rc
		else
			JOB_TIMEOUT=$((JOB_TIMEOUT - retry_wait))
			sleep $retry_wait
		fi
	done

	return 124
}

function import_resources {
	check_for_download
	rc=$?

	if [ $rc -ne 0 ]; then
		echo "Starting image import try ${import_tries}..."
		maas ${ADMIN_USERNAME} boot-resources import
		sleep 30
		check_for_download
		rc=$?
	fi

	return $rc
}

function start_import {
	timer "$RETRY_TIMER" import_resources
}

function check_for_download {
	if maas ${ADMIN_USERNAME} boot-resources is-importing | grep -q 'true'; then
		echo -e '\nBoot resources currently importing\n'
		return 1
	else
		synced_imgs=$(maas ${ADMIN_USERNAME} boot-resources read | tail -n +1 | jq '.[] | select( .type | contains("Synced")) | .name ' | grep -c $MAAS_DEFAULT_DISTRO)
		if [[ $synced_imgs -gt 0 ]]; then
			echo 'Boot resources have completed importing'
			return 0
		else
			echo 'Import failed!'
			return 1
		fi
	fi
}

function check_then_set_single {
	option="$1"
	value="$2"

	cur_val=$(maas ${ADMIN_USERNAME} maas get-config name=${option} | tail -1 | tr -d '"')
	desired_val=$(echo ${value} | tr -d '"')

	if [[ $cur_val != $desired_val ]]; then
		echo "Setting MAAS option ${option} to ${desired_val}"
		maas ${ADMIN_USERNAME} maas set-config name=${option} value=${desired_val}
		return $?
	else
		echo "MAAS option ${option} already set to ${cur_val}"
		return 0
	fi
}

function check_then_set {
	option=$1
	value=$2

	timer "$RETRY_TIMER" check_then_set_single "$option" "$value"
}

# Get rack controllers reporting a healthy rackd
function get_active_rack_controllers {
	maas ${ADMIN_USERNAME} rack-controllers read | jq -r 'map({"system_id":.system_id,"service_set":(.service_set[] | select(.name=="rackd"))}) | map(select(.service_set.status == "running")) | .[] | .system_id'
}

function check_for_rack_sync_single {
	sync_list=""

	rack_list=$(get_active_rack_controllers)
	for rack_id in ${rack_list}; do
		selected_imgs=$(maas ${ADMIN_USERNAME} rack-controller list-boot-images ${rack_id} | tail -n +1 | jq ".images[] | select( .name | contains(\"${MAAS_DEFAULT_DISTRO}\")) | .name")
		synced_ctlr=$(maas ${ADMIN_USERNAME} rack-controller list-boot-images ${rack_id} | tail -n +1 | jq '.status == "synced"')
		if [[ $synced_ctlr == "true" && -n ${selected_imgs} ]]; then
			sync_list=$(echo -e "${sync_list}\n${rack_id}" | sort | uniq)
		else
			maas ${ADMIN_USERNAME} rack-controller import-boot-images ${rack_id}
		fi
		if [[ $(echo -e "${rack_list}" | sort | uniq | grep -v '^$') == $(echo -e "${sync_list}" | sort | uniq | grep -v '^$') ]]; then
			return 0
		fi
	done

	return 1
}

function check_for_rack_sync {
	timer "$RETRY_TIMER" check_for_rack_sync_single
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

function configure_syslog {
	check_then_set remote_syslog ${MAAS_REMOTE_SYSLOG}
}

function configure_images {
	check_for_rack_sync

	if [[ $? -eq 124 ]]; then
		echo "Timed out waiting for rack controller sync."
		return 1
	fi

	check_then_set default_osystem ${MAAS_DEFAULT_OS}
	check_then_set commissioning_distro_series ${MAAS_DEFAULT_DISTRO}
	check_then_set default_distro_series ${MAAS_DEFAULT_DISTRO}
	check_then_set default_min_hwe_kernel ${MAAS_DEFAULT_KERNEL}
}

function configure_boot_sources {
	if [[ $USE_IMAGE_CACHE == 'true' ]]; then
		maas ${ADMIN_USERNAME} boot-source update 1 url=http://localhost:8888/maas/images/ephemeral-v3/daily/
	fi

	selected_releases="$(maas ${ADMIN_USERNAME} boot-source-selections read 1 | jq -r '.[] | .release')"

	if ! echo "${selected_releases}" | grep -q "${MAAS_DEFAULT_DISTRO}"; then
		# Need to start an import to get the availability data
		maas "$ADMIN_USERNAME" boot-resources import
		if ! maas ${ADMIN_USERNAME} boot-source-selections create 1 os="${MAAS_DEFAULT_OS}" \
			release="${MAAS_DEFAULT_DISTRO}" arches="amd64" subarches='*' labels='*' | grep -q 'Success'; then
			return 1
		fi
	fi
}

function create_extra_commissioning_script {
  cat > /tmp/script.sh << 'EOF'
#!/bin/bash
set -e

output=""
for net_iface in /sys/class/net/ens*
do
  if [ -z "$output" ]; then output="{"; else output+=","; fi
  output+=" \"$(basename "$net_iface")\": \"$(udevadm test-builtin net_id "$net_iface" 2>/dev/null | grep ID_NET_NAME_PATH | awk -F '=' '{print $2}')\""
done
if [ -z "$output" ]; then output="{}"; else output+=" }"; fi

echo $output

EOF

  maas "${ADMIN_USERNAME}" commissioning-scripts create name='99-netiface-names.sh' content@=/tmp/script.sh

  rm /tmp/script.sh
}

function configure_extra_settings {
	{{- range $k, $v := .Values.conf.maas.extra_settings }}
	check_then_set {{$k}} {{$v}}
	{{- else }}
	: No additional MAAS config
	{{- end }}
}

function maas_login {
	KEY=$(maas-region apikey --username=${ADMIN_USERNAME})
	if [ -z "$KEY" ]; then
		return 1
	fi
	{{- if (and .Values.conf.maas.tls.enabled .Values.conf.maas.tls.insecure) }}
	maas login --insecure ${ADMIN_USERNAME} ${MAAS_ENDPOINT} $KEY
  {{- else if .Values.conf.maas.tls.enabled }}
	maas login --cacerts /usr/local/share/ca-certificates/maas-ca.crt ${ADMIN_USERNAME} ${MAAS_ENDPOINT} $KEY
	{{- else }}
	maas login ${ADMIN_USERNAME} ${MAAS_ENDPOINT} $KEY
	{{- end }}
	return $?
}

timer "$RETRY_TIMER" maas_login

configure_proxy
configure_ntp
configure_dns
configure_syslog
configure_extra_settings
create_extra_commissioning_script

# make call to import images
timer "$RETRY_TIMER" configure_boot_sources
start_import

if [[ $? -eq 0 ]]; then
	configure_images
else
	echo "Image import FAILED!"
	exit 1
fi
